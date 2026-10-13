// Incremental reader for Claude Code session transcripts (~/.claude/projects/<cwd>/<sessionId>.jsonl).
// Keeps a compact in-memory view per session (title, cwd, last N messages) and only
// reads bytes appended since the last pass, so multi-megabyte transcripts stay cheap.
import fs from "node:fs";
import { EventEmitter } from "node:events";
import { basename, join } from "node:path";
import { PROJECTS_DIR } from "./config.js";

const PEEK_BYTES = 64 * 1024;
const READ_CHUNK = 1024 * 1024;

function stripSystemBlocks(text) {
  return text
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "")
    .replace(/<pasted_content[^>]*>|<\/pasted_content[^>]*>/g, "")
    .trim();
}

function truncate(s, n) {
  if (!s) return "";
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

class ParsedSession {
  constructor(id, file) {
    this.id = id;
    this.file = file;
    this.offset = 0;
    this.remainder = "";
    this.cwd = null;
    this.title = null;
    this.lastPrompt = null;
    this.summary = null;
    this.firstTs = null;
    this.lastTs = null;
    this.model = null;
    this.messages = [];
    this.msgIndex = new Map();
    this.totalMessages = 0;
    this.pendingTools = false; // last assistant turn ended on a tool call (still working)
    this.mtimeMs = 0;
    this.size = 0;
    this.parsed = false;
  }
}

export class SessionStore extends EventEmitter {
  constructor({ maxMessagesPerSession = 400 } = {}) {
    super();
    this.max = maxMessagesPerSession;
    /** @type {Map<string, {file:string, mtimeMs:number, size:number}>} */
    this.index = new Map();
    /** @type {Map<string, ParsedSession>} */
    this.sessions = new Map();
    this.debounce = new Map();
    this.watcher = null;
  }

  // ---------- indexing ----------

  scanIndex() {
    let dirs = [];
    try {
      dirs = fs.readdirSync(PROJECTS_DIR, { withFileTypes: true });
    } catch (e) {
      console.error("[transcripts] cannot read", PROJECTS_DIR, e.message);
      return;
    }
    const seen = new Set();
    for (const d of dirs) {
      if (!d.isDirectory()) continue;
      const dir = join(PROJECTS_DIR, d.name);
      let files = [];
      try {
        files = fs.readdirSync(dir);
      } catch {
        continue;
      }
      for (const f of files) {
        if (!f.endsWith(".jsonl")) continue;
        const id = f.slice(0, -6);
        const file = join(dir, f);
        let st;
        try {
          st = fs.statSync(file);
        } catch {
          continue;
        }
        seen.add(id);
        const prev = this.index.get(id);
        if (!prev || prev.mtimeMs !== st.mtimeMs || prev.size !== st.size) {
          this.index.set(id, { file, mtimeMs: st.mtimeMs, size: st.size });
        }
      }
    }
    for (const id of [...this.index.keys()]) {
      if (!seen.has(id)) {
        this.index.delete(id);
        this.sessions.delete(id);
        this.emit("removed", id);
      }
    }
  }

  recentIds(limit) {
    return [...this.index.entries()]
      .sort((a, b) => b[1].mtimeMs - a[1].mtimeMs)
      .slice(0, limit)
      .map(([id]) => id);
  }

  has(id) {
    return this.index.has(id);
  }

  fileFor(id) {
    return this.index.get(id)?.file || null;
  }

  // ---------- parsing ----------

  /** Parse any bytes appended since the last call. Returns the ids of messages touched. */
  ensureParsed(id) {
    const entry = this.index.get(id);
    if (!entry) return null;
    let s = this.sessions.get(id);
    if (!s) {
      s = new ParsedSession(id, entry.file);
      this.sessions.set(id, s);
    }
    let st;
    try {
      st = fs.statSync(entry.file);
    } catch {
      return s;
    }
    if (st.size < s.offset) {
      // file was truncated/rewritten: start over
      Object.assign(s, new ParsedSession(id, entry.file));
    }
    const touched = new Set();
    if (st.size > s.offset) {
      const fd = fs.openSync(entry.file, "r");
      try {
        const buf = Buffer.allocUnsafe(READ_CHUNK);
        while (s.offset < st.size) {
          const n = fs.readSync(fd, buf, 0, READ_CHUNK, s.offset);
          if (n <= 0) break;
          s.offset += n;
          const text = s.remainder + buf.toString("utf8", 0, n);
          const lines = text.split("\n");
          s.remainder = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.trim()) continue;
            let obj;
            try {
              obj = JSON.parse(line);
            } catch {
              continue;
            }
            this.#applyEntry(s, obj, touched);
          }
        }
      } finally {
        fs.closeSync(fd);
      }
    }
    s.mtimeMs = st.mtimeMs;
    s.size = st.size;
    s.parsed = true;
    entry.mtimeMs = st.mtimeMs;
    entry.size = st.size;
    return { session: s, touched: [...touched] };
  }

  #applyEntry(s, obj, touched) {
    switch (obj.type) {
      case "custom-title":
        if (obj.customTitle) s.title = obj.customTitle;
        return;
      case "last-prompt":
        if (obj.lastPrompt) s.lastPrompt = obj.lastPrompt;
        return;
      case "summary":
        if (obj.summary) s.summary = obj.summary;
        return;
      case "user":
      case "assistant":
        break;
      default:
        return;
    }
    if (obj.isSidechain || obj.isMeta) return;
    if (!s.cwd && obj.cwd) s.cwd = obj.cwd;
    const ts = obj.timestamp || null;
    if (ts) {
      if (!s.firstTs) s.firstTs = ts;
      s.lastTs = ts;
    }
    const msg = obj.message;
    if (!msg) return;

    if (obj.type === "user") {
      const content = msg.content;
      let text = "";
      let hadToolResult = false;
      if (typeof content === "string") text = content;
      else if (Array.isArray(content)) {
        for (const b of content) {
          if (b.type === "text") text += (text ? "\n" : "") + b.text;
          else if (b.type === "tool_result") hadToolResult = true;
        }
      }
      text = stripSystemBlocks(text);
      if (hadToolResult) {
        const last = s.messages[s.messages.length - 1];
        if (last && last.role === "assistant") {
          last.toolResults = (last.toolResults || 0) + 1;
          touched.add(last.id);
        }
      }
      if (!text) return;
      s.pendingTools = false;
      this.#push(s, { id: obj.uuid, role: "user", text: truncate(text, 4000), ts });
      touched.add(obj.uuid);
      return;
    }

    // assistant: blocks of one API message arrive as separate lines sharing message.id
    const mid = msg.id || obj.uuid;
    if (msg.model) s.model = msg.model;
    let m = s.msgIndex.get(mid);
    if (!m) {
      m = { id: mid, role: "assistant", text: "", tools: [], ts };
      this.#push(s, m);
    }
    const blocks = Array.isArray(msg.content) ? msg.content : [{ type: "text", text: String(msg.content ?? "") }];
    let sawToolUse = false;
    let sawText = false;
    for (const b of blocks) {
      if (b.type === "text" && b.text) {
        m.text += (m.text ? "\n" : "") + b.text;
        sawText = true;
      } else if (b.type === "tool_use") {
        m.tools.push(b.name);
        sawToolUse = true;
      }
    }
    if (m.text.length > 6000) m.text = truncate(m.text, 6000);
    if (sawToolUse) s.pendingTools = true;
    else if (sawText) s.pendingTools = false;
    touched.add(mid);
  }

  #push(s, m) {
    s.messages.push(m);
    s.totalMessages++;
    if (m.role === "assistant") s.msgIndex.set(m.id, m);
    while (s.messages.length > this.max) {
      const old = s.messages.shift();
      if (old.role === "assistant") s.msgIndex.delete(old.id);
    }
  }

  /** Cheap look at the head of an unparsed file: cwd + first user prompt. */
  #peek(file) {
    let fd;
    try {
      fd = fs.openSync(file, "r");
      const buf = Buffer.allocUnsafe(PEEK_BYTES);
      const n = fs.readSync(fd, buf, 0, PEEK_BYTES, 0);
      const lines = buf.toString("utf8", 0, n).split("\n");
      let cwd = null;
      let first = null;
      for (const line of lines) {
        if (!line.includes('"type":"user"') && !line.includes('"cwd"')) continue;
        let o;
        try {
          o = JSON.parse(line);
        } catch {
          continue;
        }
        if (!cwd && o.cwd) cwd = o.cwd;
        if (!first && o.type === "user" && !o.isSidechain && !o.isMeta) {
          const c = o.message?.content;
          const t =
            typeof c === "string" ? c : Array.isArray(c) ? c.filter((b) => b.type === "text").map((b) => b.text).join("\n") : "";
          const clean = stripSystemBlocks(t);
          if (clean) first = clean;
        }
        if (cwd && first) break;
      }
      return { cwd, first };
    } catch {
      return { cwd: null, first: null };
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
    }
  }

  // ---------- views ----------

  summary(id) {
    const entry = this.index.get(id);
    if (!entry) return null;
    const s = this.sessions.get(id);
    if (!s || !s.parsed) {
      const p = this.#peek(entry.file);
      return {
        id,
        title: truncate(p.first, 80) || id.slice(0, 8),
        cwd: p.cwd,
        project: p.cwd ? basename(p.cwd) : null,
        lastActivity: new Date(entry.mtimeMs).toISOString(),
        messageCount: null,
        preview: null,
        lastRole: null,
        pendingTools: false,
        parsed: false,
      };
    }
    const last = s.messages[s.messages.length - 1];
    return {
      id,
      title: s.title || truncate(s.summary, 80) || truncate(s.lastPrompt, 80) || truncate(s.messages.find((m) => m.role === "user")?.text, 80) || id.slice(0, 8),
      cwd: s.cwd,
      project: s.cwd ? basename(s.cwd) : null,
      lastActivity: s.lastTs || new Date(s.mtimeMs).toISOString(),
      messageCount: s.totalMessages,
      preview: last ? truncate(last.text, 160) || (last.tools?.length ? `🔧 ${last.tools.join(", ")}` : "") : null,
      lastRole: last?.role || null,
      pendingTools: s.pendingTools,
      model: s.model,
      parsed: true,
    };
  }

  messages(id, { limit = 50, before = null } = {}) {
    const s = this.sessions.get(id);
    if (!s) return { messages: [], hasMore: false };
    let end = s.messages.length;
    if (before) {
      const i = s.messages.findIndex((m) => m.id === before);
      if (i >= 0) end = i;
    }
    const start = Math.max(0, end - limit);
    return {
      messages: s.messages.slice(start, end),
      hasMore: start > 0 || s.totalMessages > s.messages.length,
    };
  }

  // ---------- watching ----------

  startWatching() {
    try {
      this.watcher = fs.watch(PROJECTS_DIR, { recursive: true }, (_ev, filename) => {
        if (!filename) return;
        const name = String(filename);
        if (!name.endsWith(".jsonl")) return;
        const id = basename(name, ".jsonl");
        if (!this.index.has(id)) this.scanIndex();
        this.#schedule(id);
      });
      this.watcher.on("error", (e) => console.error("[transcripts] watch error:", e.message));
    } catch (e) {
      console.error("[transcripts] recursive watch unavailable, falling back to polling:", e.message);
    }
    // Safety net: re-stat recent files every few seconds (fs.watch can miss events).
    this.poll = setInterval(() => {
      for (const id of this.recentIds(15)) {
        const entry = this.index.get(id);
        const s = this.sessions.get(id);
        if (!entry || !s) continue;
        try {
          const st = fs.statSync(entry.file);
          if (st.size !== s.size) this.#schedule(id);
        } catch {}
      }
    }, 3000);
  }

  #schedule(id) {
    clearTimeout(this.debounce.get(id));
    this.debounce.set(
      id,
      setTimeout(() => {
        this.debounce.delete(id);
        const s = this.sessions.get(id);
        const wasParsed = s?.parsed;
        const r = this.ensureParsed(id);
        if (!r) return;
        if (!wasParsed || r.touched.length) {
          this.emit("update", { id, touched: r.touched });
        }
      }, 200),
    );
  }

  stop() {
    this.watcher?.close();
    clearInterval(this.poll);
  }
}
