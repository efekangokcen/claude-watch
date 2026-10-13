// Pending questions that a blocking Claude Code hook is waiting on:
//   permission – PermissionRequest (allow / deny)
//   question   – AskUserQuestion via PreToolUse (pick options)
//   reply      – Stop hook reply window (free text → Claude continues)
import { EventEmitter } from "node:events";
import { randomUUID, randomBytes } from "node:crypto";

export class PendingQuestions extends EventEmitter {
  constructor() {
    super();
    /** @type {Map<string, any>} */
    this.map = new Map();
  }

  create({ kind, sessionId, title, body, payload = {}, ttlMs }) {
    const id = randomUUID();
    let resolve;
    const promise = new Promise((r) => (resolve = r));
    const q = {
      id,
      nonce: randomBytes(8).toString("hex"),
      kind,
      sessionId,
      title,
      body,
      payload,
      createdAt: Date.now(),
      expiresAt: Date.now() + ttlMs,
      status: "pending",
      answer: null,
      resolvedAt: null,
      resolvedBy: null,
      resolve,
      promise,
      timer: setTimeout(() => this.#finish(q, "expired", null, "timeout"), ttlMs),
    };
    this.map.set(id, q);
    this.emit("new", this.view(q));
    return q;
  }

  /** Answer from the watch (token auth) or from an ntfy action button (per-question nonce). */
  answer(id, answer, { nonce } = {}) {
    const q = this.map.get(id);
    if (!q || q.status !== "pending") return null;
    if (nonce !== undefined && nonce !== q.nonce) return null;
    this.#finish(q, "answered", answer, "watch");
    return q;
  }

  cancel(id, by = "cancelled") {
    const q = this.map.get(id);
    if (!q || q.status !== "pending") return null;
    this.#finish(q, "cancelled", null, by);
    return q;
  }

  #finish(q, status, answer, by) {
    clearTimeout(q.timer);
    q.status = status;
    q.answer = answer;
    q.resolvedAt = Date.now();
    q.resolvedBy = by;
    q.resolve({ status, answer });
    this.emit("resolved", this.view(q));
    setTimeout(() => this.map.delete(q.id), 60_000);
  }

  pending() {
    return [...this.map.values()].filter((q) => q.status === "pending").map((q) => this.view(q));
  }

  pendingFor(sessionId, kind) {
    return [...this.map.values()].find((q) => q.status === "pending" && q.sessionId === sessionId && (!kind || q.kind === kind)) || null;
  }

  get(id) {
    return this.map.get(id) || null;
  }

  view(q) {
    const { resolve, promise, timer, nonce, ...rest } = q;
    return rest;
  }
}
