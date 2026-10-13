import fs from "node:fs";
import { join } from "node:path";
import { networkInterfaces } from "node:os";
import { loadConfig, CONFIG_PATH, CONFIG_DIR } from "./config.js";
import { createBridge } from "./server.js";
import { spawn } from "node:child_process";

const cfg = loadConfig();
const lan = Object.values(networkInterfaces())
  .flat()
  .filter((i) => i && i.family === "IPv4" && !i.internal)
  .map((i) => i.address);
const bridge = createBridge(cfg, { lanIp: lan[0] || null });
const server = bridge.start();

console.log(`claude-watch-bridge listening on http://${cfg.host}:${server.port}`);
for (const ip of lan) console.log(`  LAN:   http://${ip}:${server.port}`);
console.log(`  config: ${CONFIG_PATH}`);
console.log(`  claude: ${cfg.claudeBin || "NOT FOUND (ask disabled)"}`);
console.log(`  pair code: ${cfg.pairCode}   (type this on the watch)`);
console.log(`  ntfy: ${cfg.ntfy.topic ? `${cfg.ntfy.url}/${cfg.ntfy.topic}` : "disabled"}   (subscribe in the ntfy iOS app)`);
console.log(`  away: after ${cfg.away.afterSec}s idle; reply window ${cfg.hold.replyWindowSec}s`);
console.log(`  sessions indexed: ${bridge.store.index.size}, live: ${bridge.listSessions().filter((s) => s.status.live).length}`);

// Bonjour advertisement via macOS dns-sd (no native mDNS in Bun). The watch browses _claude-watch._tcp.
let dnssd = null;
if (cfg.bonjour && process.platform === "darwin") {
  const name = `${cfg.deviceLabel || "Claude Watch Bridge"}`;
  dnssd = spawn("dns-sd", ["-R", name, "_claude-watch._tcp", ".", String(server.port), "path=/api"], { stdio: "ignore" });
  dnssd.on("error", (e) => console.error("[bonjour] dns-sd failed:", e.message));
  console.log(`  bonjour: ${name} (_claude-watch._tcp)`);
}

// Free Apple ID signing lasts 7 days: remind via ntfy on day 6 (scripts/deploy.sh writes the stamp).
function signingReminder() {
  try {
    const stampFile = join(CONFIG_DIR, "last-deploy");
    if (!fs.existsSync(stampFile)) return;
    const installed = Number(fs.readFileSync(stampFile, "utf8").trim()) * 1000;
    const ageDays = (Date.now() - installed) / 86_400_000;
    const remindedFile = join(CONFIG_DIR, "last-deploy-reminded");
    const reminded = fs.existsSync(remindedFile) ? fs.readFileSync(remindedFile, "utf8").trim() : "";
    if (ageDays >= 6 && reminded !== String(installed)) {
      fs.writeFileSync(remindedFile, String(installed));
      bridge.ntfy.send({
        title: "Claude Watch imzası doluyor",
        message: "Yarın saat uygulaması açılmaz olacak. iPhone'u tak ve `watch/scripts/deploy.sh` çalıştır (veya Xcode'da Run).",
        priority: 4,
        tags: ["hourglass"],
      });
    }
  } catch (e) {
    console.error("[reminder]", e.message);
  }
}
signingReminder();
setInterval(signingReminder, 6 * 60 * 60 * 1000);

process.on("SIGINT", () => {
  dnssd?.kill();
  bridge.store.stop();
  server.stop(true);
  process.exit(0);
});
process.on("SIGTERM", () => {
  dnssd?.kill();
  process.exit(0);
});
