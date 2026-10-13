// Runs `claude -p` (optionally `--resume <sessionId>`) for questions sent from the watch.
// Output is parsed from --output-format stream-json so the caller can stream progress.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

export class RunManager {
  constructor({ bin, allowedTools = [], model = null, timeoutMs = 600000 }) {
    this.bin = bin;
    this.model = model;
    this.allowedTools = allowedTools;
    this.timeoutMs = timeoutMs;
    /** @type {Map<string, Run>} */
    this.runs = new Map();
  }

  get available() {
    return Boolean(this.bin);
  }

  /**
   * @param {{text:string, cwd?:string, sessionId?:string, onEvent?:(ev:object)=>void}} opts
   * @returns {Run}
   */
  start({ text, cwd, sessionId, onEvent }) {
    if (!this.bin) throw new Error("claude CLI not found; set claudeBin in config");
    const runId = randomUUID();
    const args = ["-p", "--output-format", "stream-json", "--verbose"];
    if (sessionId) args.push("--resume", sessionId);
    if (this.model) args.push("--model", this.model);
    if (this.allowedTools.length) args.push("--allowedTools", ...this.allowedTools);

    const run = {
      id: runId,
      sessionId: sessionId || null,
      cwd: cwd || process.env.HOME,
      prompt: text,
      status: "running",
      startedAt: Date.now(),
      finishedAt: null,
      result: null,
      error: null,
      events: [],
    };
    this.runs.set(runId, run);
    const emit = (ev) => {
      run.events.push(ev);
      if (run.events.length > 200) run.events.shift();
      onEvent?.({ runId, ...ev });
    };

    const env = { ...process.env };
    delete env.CLAUDECODE; // allow launching from inside another Claude session
    const child = spawn(this.bin, args, { cwd: run.cwd, env, stdio: ["pipe", "pipe", "pipe"] });
    run.pid = child.pid;
    child.stdin.on("error", () => {});
    child.stdin.end(text);

    const timer = setTimeout(() => {
      run.error = "timeout";
      child.kill("SIGTERM");
    }, this.timeoutMs);

    let buf = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (d) => {
      stderr += d;
      if (stderr.length > 8000) stderr = stderr.slice(-8000);
    });
    child.stdout.on("data", (d) => {
      buf += d;
      const lines = buf.split("\n");
      buf = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.trim()) continue;
        let ev;
        try {
          ev = JSON.parse(line);
        } catch {
          continue;
        }
        this.#handle(run, ev, emit);
      }
    });
    child.on("error", (e) => {
      run.error = e.message;
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (buf.trim()) {
        try {
          this.#handle(run, JSON.parse(buf), emit);
        } catch {}
      }
      run.finishedAt = Date.now();
      if (run.status === "running") {
        if (code === 0 && run.result != null) run.status = "done";
        else {
          run.status = "error";
          run.error = run.error || (stderr.trim() || `exit code ${code}`);
        }
      }
      emit({ type: "run.finished", status: run.status, sessionId: run.sessionId, result: run.result, error: run.error });
    });
    run.child = child;
    emit({ type: "run.started", sessionId: run.sessionId, cwd: run.cwd });
    return run;
  }

  #handle(run, ev, emit) {
    if (ev.session_id && !run.sessionId) run.sessionId = ev.session_id;
    switch (ev.type) {
      case "system":
        if (ev.subtype === "init") emit({ type: "run.init", sessionId: ev.session_id, model: ev.model });
        break;
      case "assistant": {
        const blocks = ev.message?.content || [];
        const text = blocks.filter((b) => b.type === "text").map((b) => b.text).join("\n");
        const tools = blocks.filter((b) => b.type === "tool_use").map((b) => b.name);
        if (text || tools.length) emit({ type: "run.assistant", text, tools });
        break;
      }
      case "result":
        run.result = ev.result ?? null;
        run.status = ev.is_error ? "error" : "done";
        if (ev.is_error) run.error = ev.result || ev.error || "error";
        run.usage = ev.usage;
        run.costUsd = ev.total_cost_usd;
        break;
      default:
        break;
    }
  }

  get(runId) {
    return this.runs.get(runId) || null;
  }

  cancel(runId) {
    const run = this.runs.get(runId);
    if (!run || run.status !== "running") return false;
    run.status = "cancelled";
    run.child?.kill("SIGTERM");
    return true;
  }

  publicView(run) {
    if (!run) return null;
    const { child, ...rest } = run;
    return rest;
  }
}
