self.addEventListener("push", event => {
  let data;
  try { data = event.data?.json(); } catch { return; }
  if (!data || typeof data.body !== "string") return;
  event.waitUntil(self.registration.showNotification("UMEC Gestión", {
    body: data.body,
    icon: new URL("umec-v2-icon.png", self.registration.scope).href,
    tag: "umec-" + data.id,
    data: { target: data.kind === "request" ? "requests" : "services" },
  }));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target = new URL("UMEC_V2_v5.0.2.html", self.registration.scope);
  target.hash = event.notification.data?.target === "requests" ? "requests" : "services";
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const existing = windows.find(client => {
      const url = new URL(client.url);
      return url.origin === target.origin && url.pathname === target.pathname;
    });
    if (existing) {
      await existing.focus();
      existing.postMessage({ umecNotification: target.hash });
    } else {
      await self.clients.openWindow(target.href);
    }
  })());
});
