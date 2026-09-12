// forge service worker: shows pushed notifications and opens the page they point at.
self.addEventListener("push", (event) => {
  let data = { title: "forge", body: "", url: "/", tag: undefined };
  try { data = Object.assign(data, event.data.json()); } catch (_e) {}
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      tag: data.tag,
      renotify: !!data.tag,
      data: { url: data.url },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || "/", self.location.origin).href;
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      const open = list.find((c) => c.url === url && "focus" in c);
      return open ? open.focus() : clients.openWindow(url);
    })
  );
});
