import fs from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

export const HOME = homedir();
export const CLAUDE_DIR = process.env.CLAUDE_DIR || join(HOME, ".claude");
export const PROJECTS_DIR = join(CLAUDE_DIR, "projects");
export const SESSIONS_DIR = join(CLAUDE_DIR, "sessions");
export const CONFIG_DIR = process.env.CLAUDE_WATCH_DIR || join(HOME, ".claude-watch");
export const CONFIG_PATH = join(CONFIG_DIR, "config.json");

const DEFAULTS = {
  port: 7788,
  host: "0.0.0.0",
  token: null,
  // 6-digit code typed on the watch once; it exchanges the code for the token (POST /api/pair).
  pairCode: null,
  // Advertise on the LAN via Bonjour (_claude-watch._tcp) so the watch finds the Mac automatically.
  bonjour: true,
  claudeBin: null,
  // Tools the watch-triggered `claude -p` runs may use without asking.
  // Empty = read-only answers only (no tool execution). Example: ["Read", "Grep", "Glob"]
  allowedTools: [],
  // Model for watch-triggered questions (keeps cost down). null = Claude Code default.
  askModel: "sonnet",
  // How many recent sessions to show in the list (live sessions are always included).
  recentLimit: 40,
  // Max messages kept in memory per session.
  maxMessagesPerSession: 400,
  // Kill a watch-triggered claude run after this many ms.
  runTimeoutMs: 10 * 60 * 1000,
  // "Away" = no keyboard/mouse input on the Mac for this long. Hooks are only held (and pushes only
  // sent) while away; at the Mac, the desktop dialogs show as usual. `force` is toggled from the watch.
  away: { afterSec: 90, force: false },
  // How long a blocking hook may wait for the watch (seconds). Must stay below the hook timeouts
  // written by scripts/install-hooks.js.
  hold: { permissionSec: 540, questionSec: 540, replyWindowSec: 60 },
  // Push notifications through ntfy. Subscribe to `topic` in the ntfy iOS app; iPhone mirrors to the watch.
  ntfy: { url: "https://ntfy.sh", topic: null, token: null, onlyWhenAway: true },
};

function findClaudeBin() {
  const candidates = [
    process.env.CLAUDE_BIN,
    join(HOME, ".bun", "bin", "claude"),
    join(HOME, ".local", "bin", "claude"),
    join(HOME, ".claude", "local", "claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      fs.accessSync(c, fs.constants.X_OK);
      return c;
    } catch {}
  }
  return null;
}

export function loadConfig() {
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  let saved = {};
  if (fs.existsSync(CONFIG_PATH)) {
    try {
      saved = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
    } catch (e) {
      console.error(`[config] ${CONFIG_PATH} is not valid JSON, using defaults:`, e.message);
    }
  }
  const cfg = { ...DEFAULTS, ...saved };
  let dirty = false;
  if (!cfg.token) {
    cfg.token = randomBytes(24).toString("hex");
    dirty = true;
  }
  // deep-merge the nested defaults so new keys appear in old config files
  for (const k of ["away", "hold", "ntfy"]) cfg[k] = { ...DEFAULTS[k], ...(saved[k] || {}) };
  if (!cfg.ntfy.topic) {
    cfg.ntfy.topic = "claude-watch-" + randomBytes(10).toString("hex");
    dirty = true;
  }
  if (!cfg.pairCode) {
    cfg.pairCode = String(100000 + (randomBytes(4).readUInt32BE(0) % 900000));
    dirty = true;
  }
  if (!cfg.claudeBin) {
    cfg.claudeBin = findClaudeBin();
    if (cfg.claudeBin) dirty = true;
  }
  if (dirty || !fs.existsSync(CONFIG_PATH)) {
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
  }
  return cfg;
}
