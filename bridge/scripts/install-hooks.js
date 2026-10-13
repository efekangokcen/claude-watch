// Adds (or removes with --remove) Claude Code hooks that talk to the bridge.
//   fire-and-forget: UserPromptSubmit, Notification, SessionStart, SessionEnd  → status + pushes
//   blocking:        PermissionRequest, PreToolUse(AskUserQuestion), Stop     → the bridge's JSON
//                    response becomes the hook's stdout, i.e. the decision (answered from the watch)
// Hooks are tagged `_claude_watch` so re-running is idempotent. A backup of settings.json is kept.
import fs from "node:fs";
import { join } from "node:path";
import { CLAUDE_DIR, loadConfig } from "../src/config.js";

const SETTINGS = join(CLAUDE_DIR, "settings.json");
const remove = process.argv.includes("--remove");
const cfg = loadConfig();

const base = `curl -s -X POST http://127.0.0.1:${cfg.port}/hook -H 'Content-Type: application/json' --data-binary @-`;
const quiet = (m) => `${base} -m ${m} >/dev/null 2>&1 || true`;
// blocking: print the response body (JSON decision). If the bridge is down curl prints nothing and
// exits non-zero (not 2), which Claude Code treats as a non-blocking error → normal flow continues.
const blocking = (m) => `${base} -m ${m} 2>/dev/null`;

const HOOKS = {
  UserPromptSubmit: { command: quiet(2), timeout: 3 },
  Notification: { command: quiet(2), timeout: 3 },
  SessionStart: { command: quiet(2), timeout: 3 },
  SessionEnd: { command: quiet(2), timeout: 3 },
  PermissionRequest: { command: blocking(cfg.hold.permissionSec + 5), timeout: cfg.hold.permissionSec + 15 },
  PreToolUse: { matcher: "AskUserQuestion", command: blocking(cfg.hold.questionSec + 5), timeout: cfg.hold.questionSec + 15 },
  Stop: { command: blocking(cfg.hold.replyWindowSec + 5), timeout: cfg.hold.replyWindowSec + 15 },
};

let settings = {};
if (fs.existsSync(SETTINGS)) {
  settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
  fs.copyFileSync(SETTINGS, `${SETTINGS}.bak-claude-watch`);
}
settings.hooks ||= {};

for (const [ev, spec] of Object.entries(HOOKS)) {
  const list = Array.isArray(settings.hooks[ev]) ? settings.hooks[ev] : [];
  const kept = list.filter((g) => !g._claude_watch);
  if (!remove) {
    const group = { _claude_watch: true, hooks: [{ type: "command", command: spec.command, timeout: spec.timeout }] };
    if (spec.matcher) group.matcher = spec.matcher;
    kept.push(group);
  }
  if (kept.length) settings.hooks[ev] = kept;
  else delete settings.hooks[ev];
}

fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + "\n");
console.log(`${remove ? "Removed" : "Installed"} claude-watch hooks in ${SETTINGS}`);
console.log(`Backup: ${SETTINGS}.bak-claude-watch`);
if (!remove) console.log("Note: already-open Claude sessions pick hooks up on their next start.");
