// forge's service worker (docs/design/ui.md § The installed app). `ForgeWeb.DeviceController`
// serves it with one constant in front, `FORGE`: this release's `version`, the `offline` page's
// address and the `precache` list of exact addresses, so every release's script differs and a
// browser installs it by itself.
//
// Every function takes the worker's global scope, so a test can load this file in a page and call
// them with fakes; the listeners are registered only when this really is a service worker.
//
// What it does, and what it never does:
//   - shows a push, sets the badge from it, and tidies away the notifications that no longer wait;
//   - answers a GET page load that fails, or that a proxy answers 502/503/504, with the offline page;
//   - answers the exact precached files from the network, and from its cache only when that fails;
//   - **answers nothing else**: a POST, the LiveView connection, the API, a download or any other
//     request gets no `respondWith` and goes to the network untouched. It stores no response to any
//     request but the precache's own.
(() => {
  "use strict";

  const PREFIX = "forge-offline-";
  const CACHE = PREFIX + FORGE.version;
  // What a proxy answers when it cannot reach the platform; forge itself sends none of them.
  const GATEWAY = [502, 503, 504];

  // The app icon's badge. Not every device has one (Android draws no number), and a count that is
  // not a number is not drawn. Zero clears it.
  function badge(scope, count) {
    const nav = scope.navigator;
    try {
      if (typeof count !== "number" || !Number.isFinite(count) || count < 0) return Promise.resolve();
      const call = count > 0 ? nav.setAppBadge && nav.setAppBadge(count) : nav.clearAppBadge && nav.clearAppBadge();
      return Promise.resolve(call).catch(() => {});
    } catch (_e) {
      return Promise.resolve();
    }
  }

  // An address a tap may open: forge's own origin, and nothing else. Anything that is not — another
  // site, `//host`, `javascript:`, something that does not parse — opens the queue.
  function target(scope, raw) {
    const origin = scope.location.origin;
    try {
      const url = new URL(raw || "/", origin);
      if (url.origin === origin) return url.href;
    } catch (_e) {}
    return new URL("/", origin).href;
  }

  // Closes the person's notifications that no longer wait, and sets the badge to their true count.
  // The list comes from `GET /push/waiting`, which answers the signed-in person about themselves.
  //
  // A notification is closed only when all three hold: it was shown as an item (`data.item`, which
  // the digest and anything shown by an older worker never carry), its tag is not in the list, and
  // it was shown before this read began (`data.shown < started`), so a slow read cannot close what
  // a newer push has just shown. When the read fails nothing is closed and the badge is left.
  async function tidy(scope, started) {
    const from = typeof started === "number" ? started : Date.now();
    let state;
    try {
      const response = await scope.fetch("/push/waiting", { credentials: "same-origin", cache: "no-store" }); // credentials: the default, said aloud (an equivalent mutant)
      if (!response.ok) return;
      state = await response.json();
    } catch (_e) {
      return;
    }
    if (!state || !Array.isArray(state.tags)) return;

    const waiting = new Set(state.tags);
    for (const note of await scope.registration.getNotifications()) {
      const data = note.data || {};
      // Two of these conditions are equivalent mutants, kept for the reader: `typeof data.shown ===
      // "number"` (an undefined `shown` makes `undefined < from` false anyway) and `item === true`
      // against a truthy test (`received` below writes a boolean and nothing else writes `item`).
      if (data.item === true && note.tag && !waiting.has(note.tag) && typeof data.shown === "number" && data.shown < from) {
        note.close();
      }
    }
    await badge(scope, state.count);
  }

  // A push shows its notification first, whatever else fails: a push that shows nothing costs an
  // iPhone its subscription. The payload's own `badge` is set at once; the read then sets the true one.
  function received(scope, event) {
    const started = Date.now();
    let data = { title: "forge", body: "", url: "/", tag: undefined };
    try {
      data = Object.assign(data, event.data.json());
    } catch (_e) {}

    const shown = scope.registration.showNotification(data.title, {
      body: data.body,
      tag: data.tag,
      renotify: !!data.tag,
      data: { url: data.url, item: data.item === true, shown: Date.now() },
    });
    event.waitUntil(
      Promise.all([shown, badge(scope, data.badge), shown.then(() => tidy(scope, started)).catch(() => {})])
    );
  }

  function opened(scope, event) {
    event.notification.close();
    const url = target(scope, event.notification.data && event.notification.data.url);
    event.waitUntil(
      scope.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
        const open = list.find((c) => c.url === url && "focus" in c);
        return open ? open.focus() : scope.clients.openWindow(url);
      })
    );
  }

  // The page opened or came back into view asks for a tidy.
  function asked(scope, event) {
    if (event.data && event.data.type === "tidy") event.waitUntil(tidy(scope));
  }

  async function navigation(scope, event) {
    let gateway = null;
    try {
      const response = (await event.preloadResponse) || (await scope.fetch(event.request));
      if (!GATEWAY.includes(response.status)) return response;
      gateway = response;
    } catch (_e) {}

    const offline = await scope.caches.match(FORGE.offline, { cacheName: CACHE });
    return offline || gateway || Response.error();
  }

  async function file(scope, request) {
    try {
      return await scope.fetch(request);
    } catch (_e) {
      return (await scope.caches.match(request, { cacheName: CACHE })) || Response.error();
    }
  }

  // The fetch listener. It calls `respondWith` for a GET page load and for the exact precached
  // files, and for nothing else: returning without it leaves the request to the network.
  function page(scope, event) {
    const request = event.request;
    if (request.method !== "GET") return;
    const url = new URL(request.url);
    if (url.origin !== scope.location.origin) return;

    if (request.mode === "navigate") {
      event.respondWith(navigation(scope, event));
    } else if (FORGE.precache.includes(url.pathname + url.search)) {
      event.respondWith(file(scope, request));
    }
  }

  // A new release's worker takes over at once (`skipWaiting`, `claim`) and sweeps what an older one
  // kept: only `forge-offline-*` caches, and only other versions'.
  function install(scope, event) {
    scope.skipWaiting();
    event.waitUntil(scope.caches.open(CACHE).then((cache) => cache.addAll(FORGE.precache)));
  }

  function activate(scope, event) {
    event.waitUntil(
      (async () => {
        for (const name of await scope.caches.keys()) {
          if (name.startsWith(PREFIX) && name !== CACHE) await scope.caches.delete(name);
        }
        if (scope.registration.navigationPreload) await scope.registration.navigationPreload.enable();
        await scope.clients.claim();
      })()
    );
  }

  const api = { badge, target, tidy, received, opened, asked, page, install, activate };

  if (typeof ServiceWorkerGlobalScope !== "undefined" && self instanceof ServiceWorkerGlobalScope) {
    self.addEventListener("install", (event) => install(self, event));
    self.addEventListener("activate", (event) => activate(self, event));
    self.addEventListener("fetch", (event) => page(self, event));
    self.addEventListener("push", (event) => received(self, event));
    self.addEventListener("notificationclick", (event) => opened(self, event));
    self.addEventListener("message", (event) => asked(self, event));
  } else {
    // Loaded into a page by a test: hand the functions over to be called with fakes.
    self.forgeWorker = api;
  }
})();
