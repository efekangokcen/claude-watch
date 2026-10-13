// Push notifications via ntfy (https://ntfy.sh). The ntfy iOS app receives them and the iPhone
// mirrors them to the Apple Watch, so the watch gets alerts even when our watch app is closed.
export function makeNtfy(cfg) {
  const n = cfg.ntfy || {};
  if (!n.topic) return { enabled: false, send: async () => false };
  const url = (n.url || "https://ntfy.sh").replace(/\/+$/, "");

  async function send({ title, message, priority = 3, tags = [], actions = [], click }) {
    const body = { topic: n.topic, title, message, priority, tags };
    if (actions.length) body.actions = actions;
    if (click) body.click = click;
    const headers = { "content-type": "application/json" };
    if (n.token) headers.authorization = `Bearer ${n.token}`;
    try {
      const r = await fetch(url, { method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(8000) });
      if (!r.ok) console.error("[ntfy] publish failed:", r.status, await r.text().catch(() => ""));
      return r.ok;
    } catch (e) {
      console.error("[ntfy] publish error:", e.message);
      return false;
    }
  }

  return { enabled: true, topic: n.topic, url, send };
}
