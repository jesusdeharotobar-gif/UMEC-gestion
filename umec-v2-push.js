self.addEventListener("push", event => {
  let data;
  try { data = event.data?.json(); } catch { return; }
  if (!data || typeof data.body !== "string") return;
  event.waitUntil(self.registration.showNotification("UMEC Gestión", {
    body: data.body,
    icon: new URL("umec-v2-icon.png", self.registration.scope).href,
    tag: "umec-" + data.id,
    data: { target: data.kind === "booking" ? "web-bookings" : data.kind === "request" ? "requests" : "services" },
  }));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target = new URL("./", self.registration.scope);
  const destination = event.notification.data?.target;
  target.hash = ["web-bookings", "requests", "services"].includes(destination) ? destination : "services";
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const existing = windows.find(client => {
      const url = new URL(client.url);
      return url.origin === target.origin && (url.pathname === target.pathname || url.pathname === target.pathname + "index.html");
    });
    if (existing) {
      await existing.focus();
      existing.postMessage({ umecNotification: target.hash });
    } else {
      await self.clients.openWindow(target.href);
    }
  })());
});
