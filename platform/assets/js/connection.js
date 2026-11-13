// The connection's state, drawn on the bars themselves (docs/design/ui.md § Connection state).
//
// Losing the connection adds no row and no button: the top bar turns red-hatched under a 2px red
// rule and reads "Not connected", its second line counting down to the next retry and saying
// when the page last heard anything; everything that sends greys out in place; on the way back
// the bar shows green briefly. The state is an attribute on <html>, outside every LiveView, so
// the rejoin's re-render cannot take it away before the hook does.
//
// The socket's retry intervals are given here rather than left to Phoenix, because the countdown
// has to name the moment the socket will try: each interval it hands out is recorded as it is
// scheduled.

const root = document.documentElement

const heard = {next: null, last: Date.now()}

const schedule = (ms) => {
  heard.next = Date.now() + ms
  return ms
}

// Quick at first, for a blip, then every five seconds — Phoenix's own last interval.
export const reconnectAfterMs = (tries) => schedule([250, 1000, 2000][tries - 1] || 5000)

// A view the server crashed is joined again on Phoenix's own steps.
export const rejoinAfterMs = (tries) => schedule([1000, 2000, 5000][tries - 1] || 10000)

// Anything the socket receives — a reply, a diff, a heartbeat's answer — is hearing from it.
export const listen = (socket) => socket.onMessage(() => { heard.last = Date.now() })

// What sends something to the server: a server event on a click, a submit of a LiveView form, or
// whatever is marked `data-sends`. A `phx-click` holding JS commands (`[[…`) is the browser's own
// and stays usable. A submit button drawn outside its form and naming it with `form=` — the
// docks' *Retry*, *Move to*, *Start the chat* — submits it just the same, and is one too.
const SENDERS = [
  "[data-sends]",
  "button[phx-click]:not([phx-click^='['])",
  "form[phx-submit] button:not([type=button])",
  "button[form]:not([type=button]):not([type=reset])",
].join(", ")

const seconds = (ms) => `${Math.max(0, Math.floor(ms / 1000))}s`

const line = () => {
  const now = Date.now()
  const wait = heard.next ? heard.next - now : 0
  const retry = wait > 0 ? `retrying in ${Math.ceil(wait / 1000)}s` : "retrying"
  return `${retry} · last heard ${seconds(now - heard.last)} ago`
}

const write = () => {
  const text = line()
  for (const el of document.querySelectorAll("[data-connection-line]")) el.textContent = text
}

export const Connection = {
  mounted() {
    this.lost = () => this.goOffline()
    this.back = () => this.goOnline()
    this.el.addEventListener("forge:connection-lost", this.lost)
    this.el.addEventListener("forge:connection-back", this.back)
  },

  destroyed() {
    clearInterval(this.tick)
  },

  goOffline() {
    if (root.dataset.connection === "lost") return
    root.dataset.connection = "lost"

    // Disabled where it stands: the same element, the same size and place. Only what this
    // disabled is enabled again — a button the server drew disabled stays so.
    // `if (el.disabled) continue` is an equivalent mutant for the same reason as the loop in
    // `goOnline`: without it a server-disabled button is marked too and enabled on the way
    // back, but the rejoin's re-render draws it disabled again, so nothing a test can see
    // changes while no sender is drawn inside a `phx-update="ignore"` subtree.
    for (const el of document.querySelectorAll(SENDERS)) {
      if (el.disabled) continue
      el.dataset.offline = ""
      if ("disabled" in el) el.disabled = true
    }

    write()
    this.tick = setInterval(write, 1000)
  },

  goOnline() {
    if (root.dataset.connection !== "lost") return
    clearInterval(this.tick)

    // The rejoin's re-render already takes both attributes away from everything it patches,
    // so today this is an equivalent mutant: no page draws a sender inside a
    // `phx-update="ignore"` subtree, which the re-render leaves alone and only this restores.
    for (const el of document.querySelectorAll("[data-offline]")) {
      delete el.dataset.offline
      if ("disabled" in el) el.disabled = false
    }

    root.dataset.connection = "back"
    setTimeout(() => {
      if (root.dataset.connection === "back") delete root.dataset.connection
    }, 1500)
  },
}
