// Web push: registers the service worker and lets the "Notify me" button, or You's switch,
// subscribe this browser. The LiveView stores the subscription; the platform pushes blocking
// questions.

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
    let on = false;
    try {
      on = !!(await this.current());
    } catch (_e) {
      on = false;
    }
    this.show(on);
  },

  // The queue's button says it in words; You's row is a switch (role="switch"), whose state is
  // this browser's own subscription, which only the browser knows. That element is
  // phx-update="ignore", so a re-render leaves the state set here alone.
  show(on) {
    if (this.label) this.label.textContent = on ? "Notifications on" : "Notify me";
    if (this.el.getAttribute("role") === "switch") {
      this.el.setAttribute("aria-checked", on ? "true" : "false");
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
