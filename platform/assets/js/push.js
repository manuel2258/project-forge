// Web push: registers the service worker and lets the "Notify me" button subscribe this
// browser. The LiveView stores the subscription; the platform pushes blocking questions.

export function registerServiceWorker() {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  }
}

function keyToBytes(base64url) {
  const padding = "=".repeat((4 - (base64url.length % 4)) % 4);
  const base64 = (base64url + padding).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(base64);
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

export const PushSubscribe = {
  async mounted() {
    this.label = this.el.querySelector("[data-label]");
    this.el.addEventListener("click", () => this.toggle());
    await this.refresh();
  },

  async current() {
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) return null;
    const registration = await navigator.serviceWorker.ready;
    return registration.pushManager.getSubscription();
  },

  async refresh() {
    try {
      const subscription = await this.current();
      this.label.textContent = subscription ? "Notifications on" : "Notify me";
    } catch (_e) {
      this.label.textContent = "Notify me";
    }
  },

  async toggle() {
    try {
      if (!("PushManager" in window)) throw new Error("this browser has no push support");
      const existing = await this.current();
      if (existing) {
        await existing.unsubscribe();
        this.pushEvent("push:unsubscribe", { endpoint: existing.endpoint });
      } else {
        const permission = await Notification.requestPermission();
        if (permission !== "granted") throw new Error("permission was not granted");
        const registration = await navigator.serviceWorker.ready;
        const subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: keyToBytes(this.el.dataset.vapidKey),
        });
        this.pushEvent("push:subscribe", subscription.toJSON());
      }
    } catch (error) {
      this.pushEvent("push:error", { reason: error.message || String(error) });
    }
    await this.refresh();
  },
};
