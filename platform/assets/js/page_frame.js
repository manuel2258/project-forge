// The forge page around a page an agent wrote (`docs/design/pages.md`, `docs/design/ui.md` § Pages).
//
// The page runs in a sandboxed frame with no session, no cookie and no way to reach forge: it talks
// to this hook alone, with `postMessage`, and this hook talks to the server over the LiveView's own
// connection, as the person viewing. So **a message is acted on only when its `source` is this
// frame's own window**, only for the five operations below, and none of them names a page, a
// ticket or a project: the LiveView process knows its page and no message can move it.
//
// What the page's script sends:  {forge: 1, id, op: "hello" | "get" | "all" | "set" | "delete", key?, value?}
// What it is answered with:      {forge: 1, id, ok, value?, counter?, entries?, reason?, limit?, ...}
// What it is told unasked:       {forge: 1, op: "changed" | "readonly", ...}
//
// **Typing is sent in batches**, at most every `BATCH_MS`, the last value of each key and no more;
// each batch carries this load's client id and a sequence number, so a batch the server applied
// before the socket dropped is acknowledged and not applied twice when it is sent again on the
// rejoin. A save made while the socket is down is held here, in order, and sent when it is back. A
// reload, a closed tab or another device keeps none (`ui.md` § A reconnect is not a reload).

export const BATCH_MS = 300
export const OPS = ["hello", "get", "all", "set", "delete"]

const clientId = () => {
  const bytes = new Uint8Array(12)
  crypto.getRandomValues(bytes)
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")
}

// A write the page's script made: what to do with the key, and who is waiting to hear it saved.
const entry = (op, value) => ({op, value, waiters: []})

export const PageFrame = {
  mounted() {
    this.frame = this.el.querySelector("iframe")
    this.status = this.el.querySelector("[data-page-save]")
    this.client = clientId()
    this.seq = 0
    // Writes not yet in a batch: key → {op, value, waiters}. A later write of a key replaces an
    // earlier one that was not sent, and keeps its waiters.
    this.queue = new Map()
    // The batch sent and not yet answered, kept so that a rejoin sends it again under its number.
    this.inflight = null
    this.timer = null
    this.online = true
    this.waitingReads = []
    this.refused = null

    this.onMessage = (event) => this.receive(event)
    window.addEventListener("message", this.onMessage)

    this.handleEvent("page:changed", (change) => this.tell({op: "changed", ...change}))
    this.handleEvent("page:readonly", (state) => this.tell({op: "readonly", ...state}))
    this.pendingSrc = null
    this.handleEvent("page:reload", ({src}) => this.load(src))
    // A page left open for a day is given a new signed address (its old one expires); it is applied
    // once nothing is waiting to be saved, since loading it again drops the page's own state.
    this.handleEvent("page:refresh", ({src}) => {
      this.pendingSrc = src
      this.applyPending()
    })

    this.draw()
  },

  // The frame's address, read again under a freshly signed token, which is a new request for the
  // page under the viewer's outside-access setting as it is now.
  load(src) {
    this.pendingSrc = null
    if (this.frame && typeof src === "string") this.frame.src = src
  },

  applyPending() {
    if (this.pendingSrc && this.online && this.waiting() === 0) this.load(this.pendingSrc)
  },

  destroyed() {
    window.removeEventListener("message", this.onMessage)
    clearTimeout(this.timer)
  },

  disconnected() {
    this.online = false
    this.draw()
  },

  reconnected() {
    this.online = true
    const reads = this.waitingReads
    this.waitingReads = []
    for (const read of reads) read()
    this.send()
  },

  // -- the frame's messages ---------------------------------------------------------------------

  receive(event) {
    // The one check that makes the rest safe: any other window — a nested frame of the page's, a
    // window it opened, another tab — is not this page.
    if (!this.frame || event.source !== this.frame.contentWindow) return
    const message = event.data
    if (!message || message.forge !== 1 || !OPS.includes(message.op)) return
    if (typeof message.id !== "number") return

    const key = typeof message.key === "string" ? message.key : null
    const reply = (fields) => this.tell({id: message.id, ...fields})

    switch (message.op) {
      case "hello":
        this.read(() => this.pushEvent("page:hello", {}, (answer) => reply({ok: true, ...answer})))
        break
      case "get":
        if (key === null) return reply({ok: false, reason: "key"})
        this.get(key, reply)
        break
      case "all":
        this.all(reply)
        break
      case "set":
        if (key === null) return reply({ok: false, reason: "key"})
        this.write(key, entry("set", message.value), reply)
        break
      case "delete":
        if (key === null) return reply({ok: false, reason: "key"})
        this.write(key, entry("delete"), reply)
        break
    }
  },

  // A page's script is told by `postMessage` to a window whose origin is opaque, so the target is
  // `*`; `postMessage` on this frame's own `contentWindow` delivers to that window's document and
  // to no other, whatever the address it has navigated to.
  tell(fields) {
    if (this.frame?.contentWindow)
      this.frame.contentWindow.postMessage({forge: 1, ...fields}, "*")
  },

  // A read waits for the socket when it is down, rather than failing: the page asked once.
  read(run) {
    if (this.online) run()
    else this.waitingReads.push(run)
  },

  // What was written here and not yet saved is what the page reads back of its own key.
  pendingFor(key) {
    return this.queue.get(key) || this.inflight?.ops.get(key) || null
  },

  get(key, reply) {
    const own = this.pendingFor(key)
    if (own) return reply({ok: true, value: own.op === "set" ? own.value : null, counter: null})
    this.read(() =>
      this.pushEvent("page:get", {key}, (answer) => reply({ok: true, ...answer}))
    )
  },

  all(reply) {
    this.read(() =>
      this.pushEvent("page:all", {}, (answer) => {
        const entries = {...(answer.entries || {})}
        for (const layer of [this.inflight?.ops, this.queue]) {
          if (!layer) continue
          for (const [key, write] of layer) {
            if (write.op === "set") entries[key] = {value: write.value, counter: null}
            else delete entries[key]
          }
        }
        reply({ok: true, entries})
      })
    )
  },

  // -- saving -----------------------------------------------------------------------------------

  write(key, write, reply) {
    const earlier = this.queue.get(key)
    if (earlier) write.waiters = earlier.waiters
    write.waiters.push(reply)
    // `delete` then `set` keeps the key's place in the batch: the last value is what is sent.
    this.queue.set(key, write)
    this.draw()
    if (!this.timer) this.timer = setTimeout(() => this.send(), BATCH_MS)
  },

  // Sends the queue as one batch when none is out. A batch still out is sent again on a rejoin
  // under its own number, and the one after it waits.
  send() {
    clearTimeout(this.timer)
    this.timer = null
    if (!this.online) return this.draw()

    if (!this.inflight) {
      if (this.queue.size === 0) return this.draw()
      this.inflight = {seq: ++this.seq, ops: this.queue}
      this.queue = new Map()
    }

    const batch = this.inflight
    const ops = [...batch.ops].map(([key, write]) => ({op: write.op, key, value: write.value}))
    this.draw()

    this.pushEvent("page:batch", {client: this.client, seq: batch.seq, ops}, (answer) => {
      // A reply for a batch that is no longer the one out is a second answer to a batch sent
      // twice across a rejoin; the first settled it.
      if (this.inflight !== batch) return
      this.inflight = null
      const results = answer.results || []
      let index = 0
      this.refused = null
      for (const [, write] of batch.ops) {
        const result = answer.duplicate ? {ok: true} : results[index++] || {ok: false, reason: "lost"}
        if (!result.ok && !this.refused) this.refused = result
        for (const waiter of write.waiters)
          waiter(result.ok ? {ok: true, counter: result.counter ?? null} : {ok: false, reason: result.reason, limit: result.limit})
      }
      this.draw()
      // Whatever was written while the batch was out goes in the next.
      if (this.queue.size > 0) this.timer = setTimeout(() => this.send(), BATCH_MS)
    })
  },

  // -- the bar's words --------------------------------------------------------------------------

  waiting() {
    return (this.inflight ? this.inflight.ops.size : 0) + this.queue.size
  },

  draw() {
    if (!this.status) return
    const waiting = this.waiting()
    let state, text

    if (!this.online) {
      state = "offline"
      text = `offline · ${waiting}`
    } else if (waiting > 0) {
      state = "saving"
      text = "saving"
    } else if (this.refused) {
      state = "refused"
      text = this.refused.limit ? `refused · ${this.refused.reason} (${this.refused.limit})` : `refused · ${this.refused.reason}`
    } else {
      state = "saved"
      text = "saved"
    }

    this.status.dataset.state = state
    this.status.textContent = text
    this.applyPending()
  },
}
