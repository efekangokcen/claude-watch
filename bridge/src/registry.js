// Reads the live-session registry Claude Code keeps in ~/.claude/sessions/<pid>.json.
// Each file describes one running `claude` process: sessionId, cwd, name, status (busy/idle).
import fs from "node:fs";
import { join } from "node:path";
import { SESSIONS_DIR } from "./config.js";

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === "EPERM";
  }
}

/** @returns {Map<string, LiveSession>} keyed by sessionId */
export function readLiveSessions() {
  const out = new Map();
  let files = [];
  try {
    files = fs.readdirSync(SESSIONS_DIR);
  } catch {
    return out;
  }
  for (const f of files) {
    if (!f.endsWith(".json")) continue;
    let j;
    try {
      j = JSON.parse(fs.readFileSync(join(SESSIONS_DIR, f), "utf8"));
    } catch {
      continue;
    }
    if (!j.sessionId || !j.pid) continue;
    if (!pidAlive(j.pid)) continue;
    out.set(j.sessionId, {
      sessionId: j.sessionId,
      pid: j.pid,
      cwd: j.cwd,
      name: j.name || null,
      status: j.status === "busy" ? "busy" : "idle",
      kind: j.kind,
      entrypoint: j.entrypoint,
      version: j.version,
      startedAt: j.startedAt,
      updatedAt: j.updatedAt || j.statusUpdatedAt || j.startedAt,
    });
  }
  return out;
}

/**
 * Calls cb() whenever the registry directory changes (debounced) and every
 * `pollMs` as a safety net (catches dead pids whose files linger).
 */
export function watchRegistry(cb, pollMs = 5000) {
  let t = null;
  const fire = () => {
    clearTimeout(t);
    t = setTimeout(cb, 150);
  };
  let watcher = null;
  try {
    fs.mkdirSync(SESSIONS_DIR, { recursive: true });
    watcher = fs.watch(SESSIONS_DIR, fire);
    watcher.on("error", (e) => console.error("[registry] watch error:", e.message));
  } catch (e) {
    console.error("[registry] cannot watch", SESSIONS_DIR, e.message);
  }
  const iv = setInterval(cb, pollMs);
  return () => {
    watcher?.close();
    clearInterval(iv);
  };
}
