// HTTP + WebSocket API consumed by the watch app, plus the Claude Code hook endpoint. Runs on Bun.
import { hostname } from "node:os";
import { readLiveSessions, watchRegistry } from "./registry.js";
import { SessionStore } from "./transcripts.js";
import { RunManager } from "./claude.js";
import { PendingQuestions } from "./questions.js";
import { Presence } from "./presence.js";
import { makeNtfy } from "./ntfy.js";

const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);
const clip = (s, n) => (s && s.length > n ? s.slice(0, n - 1) + "…" : s || "");

export function createBridge(cfg, { lanIp = null } = {}) {
  const store = new SessionStore({ maxMessagesPerSession: cfg.maxMessagesPerSession });
  const runner = new RunManager({ bin: cfg.claudeBin, allowedTools: cfg.allowedTools, model: cfg.askModel, timeoutMs: cfg.runTimeoutMs });
  const questions = new PendingQuestions();
  const presence = new Presence(cfg.away);
  const ntfy = makeNtfy(cfg);
  let live = new Map();
  /** sessionId -> {state, message, at} set by Claude Code hooks */
  const hookState = new Map();
  const clients = new Set();
  const pairAttempts = []; // timestamps of failed pair attempts (simple rate limit)
  const deviceName = hostname().replace(/\.local$/, "");

  // ---------- status composition ----------

  function statusOf(id) {
    const l = live.get(id);
    const h = hookState.get(id);
    if (!l) return { state: "ended", live: false };
    if (h?.state === "needs_input") return { state: "needs_input", live: true, message: h.message, pid: l.pid };
    return { state: l.status, live: true, pid: l.pid };
  }

  function sessionView(id) {
    const base = store.summary(id);
    const l = live.get(id);
    if (!base && !l) return null;
    const v = base || {
      id,
      title: null,
      cwd: l.cwd,
      project: l.cwd?.split("/").pop() || null,
      lastActivity: new Date(l.updatedAt || l.startedAt).toISOString(),
      messageCount: null,
      preview: null,
      lastRole: null,
      pendingTools: false,
      parsed: false,
    };
    if (l) {
      if (l.name) v.title = l.name;
      if (!v.cwd) v.cwd = l.cwd;
      if (!v.project && l.cwd) v.project = l.cwd.split("/").pop();
      v.startedAt = new Date(l.startedAt).toISOString();
      v.entrypoint = l.entrypoint;
    }
    v.status = statusOf(id);
    return v;
  }

  function sessionLabel(id) {
    const v = sessionView(id);
    return v?.title || v?.project || "Claude Code";
  }

  function listSessions(limit = cfg.recentLimit) {
    const ids = new Set(live.keys());
    for (const id of store.recentIds(limit)) ids.add(id);
    const out = [];
    for (const id of ids) {
      const v = sessionView(id);
      if (v) out.push(v);
    }
    const rank = { needs_input: 0, busy: 1, idle: 2, ended: 3 };
    out.sort((a, b) => {
      const r = rank[a.status.state] - rank[b.status.state];
      if (r) return r;
      return (b.lastActivity || "").localeCompare(a.lastActivity || "");
    });
    return out;
  }

  function snapshot() {
    return { type: "snapshot", sessions: listSessions(), questions: questions.pending(), presence: presence.snapshot(), claude: runner.available, ntfy: ntfy.enabled };
  }

  // ---------- broadcasting ----------

  function broadcast(obj) {
    const data = JSON.stringify(obj);
    for (const ws of clients) {
      try {
        ws.send(data);
      } catch {}
    }
  }

  function refreshLive() {
    const next = readLiveSessions();
    const changed = new Set();
    for (const [id, n] of next) {
      const p = live.get(id);
      if (!p || p.status !== n.status || p.name !== n.name || p.pid !== n.pid) changed.add(id);
    }
    for (const id of live.keys()) if (!next.has(id)) changed.add(id);
    live = next;
    for (const id of changed) {
      if (!live.has(id)) {
        hookState.delete(id);
        for (const q of questions.pending()) if (q.sessionId === id) questions.cancel(q.id, "session_ended");
      }
      const v = sessionView(id);
      if (v) broadcast({ type: "session.update", session: v });
    }
    for (const id of live.keys()) if (store.has(id) && !store.sessions.get(id)?.parsed) store.ensureParsed(id);
  }

  store.on("update", ({ id, touched }) => {
    if (hookState.get(id)?.state === "needs_input") hookState.delete(id); // activity resumed
    const v = sessionView(id);
    if (!v) return;
    const s = store.sessions.get(id);
    const msgs = s ? s.messages.filter((m) => touched.includes(m.id)) : [];
    broadcast({ type: "session.update", session: v, messages: msgs });
  });
  store.on("removed", (id) => broadcast({ type: "session.removed", id }));
  questions.on("new", (q) => broadcast({ type: "question.new", question: q }));
  questions.on("resolved", (q) => broadcast({ type: "question.resolved", question: q }));

  // ---------- pushes ----------

  function shouldPush() {
    if (!ntfy.enabled) return false;
    return cfg.ntfy.onlyWhenAway ? presence.isAway() : true;
  }

  function answerAction(q, label, answer) {
    if (!lanIp) return null;
    return {
      action: "http",
      label,
      url: `http://${lanIp}:${cfg.port}/api/questions/${q.id}/answer`,
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ answer, k: q.nonce }),
      clear: true,
    };
  }

  function push({ sessionId, title, message, priority = 3, tags = [], actions = [] }) {
    broadcast({ type: "notify", sessionId, title, body: message });
    if (!shouldPush()) return;
    ntfy.send({ title, message, priority, tags, actions: actions.filter(Boolean) });
  }

  // ---------- hooks (from Claude Code, loopback only) ----------

  function describeTool(name, input) {
    if (!input || typeof input !== "object") return name;
    if (name === "Bash") return `$ ${clip(input.command, 300)}`;
    if (input.file_path) return `${name}: ${input.file_path}`;
    if (input.command) return `${name}: ${clip(input.command, 300)}`;
    if (input.url) return `${name}: ${input.url}`;
    const keys = Object.keys(input).slice(0, 4);
    return `${name} ${clip(keys.map((k) => `${k}=${JSON.stringify(input[k])}`).join(" "), 300)}`;
  }

  function setHookStatus(payload) {
    const id = payload.session_id;
    const ev = payload.hook_event_name;
    let state = null;
    if (ev === "UserPromptSubmit" || ev === "PreToolUse" || ev === "PostToolUse") state = "busy";
    else if (ev === "Stop" || ev === "SessionStart") state = "idle";
    else if (ev === "Notification" || ev === "PermissionRequest") state = "needs_input";
    else if (ev === "SessionEnd") state = "ended";
    if (state === "needs_input") hookState.set(id, { state, message: payload.message || null, at: Date.now() });
    else hookState.delete(id);
    if (state && live.has(id)) {
      const l = live.get(id);
      if (state === "busy" || state === "idle") l.status = state;
    }
    broadcast({ type: "hook", sessionId: id, event: ev, state, message: payload.message || null });
    const v = sessionView(id);
    if (v) broadcast({ type: "session.update", session: v });
    return state;
  }

  /** Hold the hook until the watch answers, the user returns to the Mac, or the TTL passes. */
  async function hold(q) {
    const r = await Promise.race([q.promise, presence.waitUntilActive(q.promise).then((why) => ({ status: why }))]);
    if (r.status === "active") {
      questions.cancel(q.id, "desktop");
      return { status: "cancelled" };
    }
    return r;
  }

  async function onPermissionRequest(p) {
    const id = p.session_id;
    const body = describeTool(p.tool_name, p.tool_input);
    if (!presence.isAway()) return {}; // at the Mac: let the desktop dialog handle it
    const q = questions.create({
      kind: "permission",
      sessionId: id,
      title: sessionLabel(id),
      body,
      payload: { tool_name: p.tool_name, tool_use_id: p.tool_use_id },
      ttlMs: cfg.hold.permissionSec * 1000,
    });
    push({
      sessionId: id,
      title: `İzin: ${sessionLabel(id)}`,
      message: body,
      priority: 4,
      tags: ["lock"],
      actions: [answerAction(q, "İzin ver", "allow"), answerAction(q, "Reddet", "deny")],
    });
    const r = await hold(q);
    if (r.status !== "answered") return {};
    const behavior = r.answer === "allow" ? "allow" : "deny";
    return { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior } } };
  }

  function normalizeQuestions(input) {
    const qs = Array.isArray(input?.questions) ? input.questions : [];
    return qs.map((x) => ({
      question: String(x.question || ""),
      header: x.header || null,
      multiSelect: Boolean(x.multiSelect),
      options: (Array.isArray(x.options) ? x.options : []).map((o) => ({ label: String(o.label ?? o), description: o.description || null })),
    }));
  }

  async function onAskUserQuestion(p) {
    const id = p.session_id;
    const qs = normalizeQuestions(p.tool_input);
    if (!qs.length) return {};
    if (!presence.isAway()) return {};
    const q = questions.create({
      kind: "question",
      sessionId: id,
      title: sessionLabel(id),
      body: qs.map((x) => x.question).join("\n"),
      payload: { tool_name: "AskUserQuestion", questions: qs },
      ttlMs: cfg.hold.questionSec * 1000,
    });
    push({
      sessionId: id,
      title: `Soru: ${sessionLabel(id)}`,
      message: qs.map((x) => `${x.question}\n${x.options.map((o) => `• ${o.label}`).join("\n")}`).join("\n\n"),
      priority: 4,
      tags: ["question"],
    });
    const r = await hold(q);
    if (r.status !== "answered") return {};
    const answers = Array.isArray(r.answer?.answers) ? r.answer.answers : [r.answer];
    const lines = qs.map((x, i) => {
      const a = answers[i];
      const txt = Array.isArray(a) ? a.join(", ") : String(a ?? "");
      return `Q: ${x.question}\nA: ${txt}`;
    });
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "The user already answered this question from their Apple Watch. Do not ask again; continue with these answers:\n" + lines.join("\n"),
      },
    };
  }

  async function onStop(p) {
    const id = p.session_id;
    if (p.stop_hook_active) return {};
    if (store.has(id)) store.ensureParsed(id);
    const s = store.sessions.get(id);
    const last = s?.messages?.slice().reverse().find((m) => m.role === "assistant" && m.text);
    const summary = clip(last?.text?.replace(/\s+/g, " "), 400) || "Bitti.";
    if (!presence.isAway()) {
      push({ sessionId: id, title: `Bitti: ${sessionLabel(id)}`, message: summary, tags: ["white_check_mark"] });
      return {};
    }
    // Stop can fire more than once for the same turn: share one reply window per session.
    const existing = questions.pendingFor(id, "reply");
    if (existing) {
      const r = await hold(existing);
      if (r.status !== "answered" || !r.answer) return {};
      return { decision: "block", reason: `The user replied from their Apple Watch:\n${String(r.answer)}` };
    }
    const q = questions.create({
      kind: "reply",
      sessionId: id,
      title: sessionLabel(id),
      body: summary,
      payload: {},
      ttlMs: cfg.hold.replyWindowSec * 1000,
    });
    push({
      sessionId: id,
      title: `Bitti: ${sessionLabel(id)}`,
      message: `${summary}\n\n(${cfg.hold.replyWindowSec} sn içinde saatten cevap yazarsan aynı sohbet devam eder)`,
      tags: ["white_check_mark"],
    });
    const r = await hold(q);
    if (r.status !== "answered" || !r.answer) return {};
    return { decision: "block", reason: `The user replied from their Apple Watch:\n${String(r.answer)}` };
  }

  async function onNotification(p) {
    const id = p.session_id;
    const t = p.notification_type;
    if (t === "permission_prompt" || t === "idle_prompt" || t === "agent_needs_input" || t === "elicitation_dialog") {
      // PermissionRequest already pushes for permission prompts while away; avoid a duplicate.
      if (t === "permission_prompt" && questions.pendingFor(id, "permission")) return;
      push({ sessionId: id, title: `Bekliyor: ${sessionLabel(id)}`, message: p.message || "Claude girdi bekliyor", priority: 4, tags: ["bell"] });
    }
  }

  async function handleHook(payload) {
    const ev = payload.hook_event_name;
    setHookStatus(payload);
    try {
      switch (ev) {
        case "PermissionRequest":
          return await onPermissionRequest(payload);
        case "PreToolUse":
          return payload.tool_name === "AskUserQuestion" ? await onAskUserQuestion(payload) : {};
        case "Stop":
          return await onStop(payload);
        case "Notification":
          await onNotification(payload);
          return {};
        default:
          return {};
      }
    } catch (e) {
      console.error(`[hook ${ev}]`, e);
      return {};
    }
  }

  // ---------- http ----------

  const json = (data, status = 200) =>
    new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json; charset=utf-8" } });

  function authorized(req, url) {
    const h = req.headers.get("authorization") || "";
    const t = h.startsWith("Bearer ") ? h.slice(7) : url.searchParams.get("token");
    return t === cfg.token;
  }

  /** Answer a pending question; `nonce` lets an ntfy action button answer without the bearer token. */
  function answerQuestion(id, answer, nonce) {
    const q = questions.answer(id, answer, nonce === undefined ? {} : { nonce });
    if (!q) return json({ error: "not pending" }, 404);
    return json({ question: questions.view(q) });
  }

  async function handle(req, server) {
    const url = new URL(req.url);
    const ip = server.requestIP(req)?.address || "";
    const path = url.pathname.replace(/\/+$/, "") || "/";

    if (path === "/api/health") return json({ ok: true, name: "claude-watch-bridge", device: deviceName, version: "0.2.0", claude: runner.available, ntfy: ntfy.enabled });

    if (path === "/hook" && req.method === "POST") {
      if (!LOOPBACK.has(ip) && !authorized(req, url)) return json({ error: "forbidden" }, 403);
      let payload;
      try {
        payload = await req.json();
      } catch {
        return json({}, 400);
      }
      return json(await handleHook(payload));
    }

    if (path === "/api/pair" && req.method === "POST") {
      const now = Date.now();
      while (pairAttempts.length && now - pairAttempts[0] > 60_000) pairAttempts.shift();
      if (pairAttempts.length >= 5) return json({ error: "too many attempts, wait a minute" }, 429);
      const body = await req.json().catch(() => ({}));
      if (String(body.code || "") !== String(cfg.pairCode)) {
        pairAttempts.push(now);
        return json({ error: "wrong code" }, 403);
      }
      return json({ token: cfg.token, device: deviceName, claude: runner.available, ntfyTopic: ntfy.topic || null, ntfyUrl: ntfy.url || null });
    }

    let m;
    // ntfy action buttons answer with the per-question nonce (no bearer token on the phone)
    if ((m = path.match(/^\/api\/questions\/([^/]+)\/answer$/)) && req.method === "POST" && !authorized(req, url)) {
      const body = await req.json().catch(() => ({}));
      if (!body.k) return json({ error: "unauthorized" }, 401);
      return answerQuestion(m[1], body.answer, String(body.k));
    }

    if (!authorized(req, url)) return json({ error: "unauthorized" }, 401);

    if (path === "/ws") {
      if (server.upgrade(req, { data: {} })) return undefined;
      return json({ error: "upgrade failed" }, 400);
    }

    if (path === "/api/sessions" && req.method === "GET") {
      const limit = Number(url.searchParams.get("limit")) || cfg.recentLimit;
      return json({ sessions: listSessions(limit), claude: runner.available });
    }

    if (path === "/api/questions" && req.method === "GET") return json({ questions: questions.pending() });
    if ((m = path.match(/^\/api\/questions\/([^/]+)\/answer$/)) && req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      return answerQuestion(m[1], body.answer);
    }

    if (path === "/api/presence" && req.method === "GET") return json(presence.snapshot());
    if (path === "/api/presence" && req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      presence.force = Boolean(body.force);
      const snap = presence.snapshot();
      broadcast({ type: "presence", presence: snap });
      return json(snap);
    }

    if ((m = path.match(/^\/api\/sessions\/([^/]+)$/)) && req.method === "GET") {
      const id = decodeURIComponent(m[1]);
      if (!store.has(id) && !live.has(id)) return json({ error: "not found" }, 404);
      if (store.has(id)) store.ensureParsed(id);
      const limit = Number(url.searchParams.get("limit")) || 50;
      const before = url.searchParams.get("before");
      const pq = questions.pendingFor(id);
      return json({ session: sessionView(id), question: pq ? questions.view(pq) : null, ...store.messages(id, { limit, before }) });
    }

    if ((m = path.match(/^\/api\/sessions\/([^/]+)\/ask$/)) && req.method === "POST") {
      const id = decodeURIComponent(m[1]);
      if (!store.has(id) && !live.has(id)) return json({ error: "not found" }, 404);
      const body = await req.json().catch(() => ({}));
      const text = String(body.text || "").trim();
      if (!text) return json({ error: "text required" }, 400);
      // A Stop-hook reply window is open for this session: the text continues the live desktop chat.
      const pendingReply = questions.pendingFor(id, "reply");
      if (pendingReply) {
        questions.answer(pendingReply.id, text);
        return json({ replied: true, question: questions.view(pendingReply) }, 202);
      }
      if (!runner.available) return json({ error: "claude CLI not available on this Mac" }, 503);
      if (live.has(id) && !body.force) {
        return json(
          {
            error: "session_live",
            message: "Bu oturum masaüstünde açık ve cevap penceresi kapalı. force:true ile ayrı bir devam çalıştırabilirsin.",
          },
          409,
        );
      }
      const cwd = sessionView(id)?.cwd || live.get(id)?.cwd || process.env.HOME;
      const run = runner.start({ text, cwd, sessionId: id, onEvent: broadcast });
      return json({ run: runner.publicView(run) }, 202);
    }

    if (path === "/api/ask" && req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      const text = String(body.text || "").trim();
      if (!text) return json({ error: "text required" }, 400);
      if (!runner.available) return json({ error: "claude CLI not available on this Mac" }, 503);
      const run = runner.start({ text, cwd: body.cwd || process.env.HOME, onEvent: broadcast });
      return json({ run: runner.publicView(run) }, 202);
    }

    if ((m = path.match(/^\/api\/runs\/([^/]+)$/)) && req.method === "GET") {
      const run = runner.get(m[1]);
      return run ? json({ run: runner.publicView(run) }) : json({ error: "not found" }, 404);
    }
    if ((m = path.match(/^\/api\/runs\/([^/]+)\/cancel$/)) && req.method === "POST") {
      return json({ cancelled: runner.cancel(m[1]) });
    }

    if (path === "/api/test-push" && req.method === "POST") {
      const ok = await ntfy.send({ title: "Claude Watch", message: "Test bildirimi 👋", tags: ["watch"] });
      return json({ sent: ok, topic: ntfy.topic || null });
    }

    return json({ error: "not found" }, 404);
  }

  // ---------- lifecycle ----------

  function start() {
    store.scanIndex();
    live = readLiveSessions();
    for (const id of live.keys()) if (store.has(id)) store.ensureParsed(id);
    store.startWatching();
    watchRegistry(refreshLive);

    const queue = store.recentIds(cfg.recentLimit).filter((id) => !store.sessions.get(id)?.parsed);
    const tick = () => {
      const id = queue.shift();
      if (!id) return;
      store.ensureParsed(id);
      const v = sessionView(id);
      if (v) broadcast({ type: "session.update", session: v });
      setTimeout(tick, 10);
    };
    setTimeout(tick, 50);

    // presence heartbeat for connected watches
    let lastAway = presence.isAway();
    setInterval(() => {
      const snap = presence.snapshot();
      if (snap.away !== lastAway) {
        lastAway = snap.away;
        broadcast({ type: "presence", presence: snap });
      }
    }, 10_000);

    const server = Bun.serve({
      port: cfg.port,
      hostname: cfg.host,
      idleTimeout: 255, // seconds; blocking hook requests can wait a long time
      fetch: handle,
      websocket: {
        open(ws) {
          clients.add(ws);
          ws.send(JSON.stringify(snapshot()));
        },
        close(ws) {
          clients.delete(ws);
        },
        message(ws, raw) {
          let msg;
          try {
            msg = JSON.parse(String(raw));
          } catch {
            return;
          }
          if (msg.type === "ping") ws.send(JSON.stringify({ type: "pong", t: Date.now() }));
          else if (msg.type === "sessions") ws.send(JSON.stringify(snapshot()));
        },
      },
    });
    return server;
  }

  return { start, listSessions, store, runner, questions, presence, ntfy, handleHook };
}
