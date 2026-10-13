// Is the user at the Mac? Uses the HID idle timer (seconds since last keyboard/mouse input).
import { execFileSync } from "node:child_process";

export function macIdleSeconds() {
  try {
    const out = execFileSync("/usr/sbin/ioreg", ["-c", "IOHIDSystem"], { encoding: "utf8", timeout: 3000 });
    const m = out.match(/"HIDIdleTime"\s*=\s*(\d+)/);
    return m ? Number(m[1]) / 1e9 : null;
  } catch {
    return null;
  }
}

export class Presence {
  constructor({ afterSec = 90, force = false } = {}) {
    this.afterSec = afterSec;
    this.force = force; // watch-side override: "I'm away" even if the Mac looks active
  }

  snapshot() {
    const idle = macIdleSeconds();
    const away = this.force || (idle != null && idle >= this.afterSec);
    return { away, forced: this.force, idleSec: idle == null ? null : Math.round(idle), afterSec: this.afterSec };
  }

  isAway() {
    return this.snapshot().away;
  }

  /**
   * Resolves when the user comes back to the Mac (idle timer resets) or when `until` resolves first.
   * Used to release a held hook so the desktop dialog shows up as soon as the user is back.
   */
  async waitUntilActive(until, pollMs = 2000) {
    let done = false;
    until.then(() => (done = true));
    while (!done) {
      await new Promise((r) => setTimeout(r, pollMs));
      if (done) break;
      if (!this.isAway()) return "active";
    }
    return "done";
  }
}
