/* forge-page.js — the library a page an agent wrote uses to reach its data (docs/design/pages.md).
 *
 *   <script src="forge-page.js"></script>
 *   forge.ready.then(({viewer, readOnly, reason}) => { ... })
 *   forge.get("name")            -> Promise<{value, counter} | null>   (null: no such key)
 *   forge.all()                  -> Promise<{key: {value, counter}}>
 *   forge.set("name", value)     -> Promise, resolved when saved; rejected with Error(reason) and .limit
 *   forge.delete("name")         -> Promise, as set
 *   forge.onChange(fn)           -> fn({key, value, deleted, counter}) when somebody else writes
 *   forge.onReadOnly(fn)         -> fn({readOnly, reason}) when the page becomes read only or writable
 *
 * The page never talks to forge: it sends messages to the forge page around it, which carries each
 * read and write as the person viewing. `forge-page.js` is a reserved name; forge serves this file
 * for it, whatever a page ships. A change the viewer made themself is never reported back.
 */
(function () {
  "use strict"
  if (window.forge) return

  var pending = {}
  var next = 1
  var changeFns = []
  var readOnlyFns = []
  var current = {viewer: null, readOnly: false, reason: null}

  function ask(op, fields) {
    return new Promise(function (resolve, reject) {
      var id = next++
      pending[id] = {resolve: resolve, reject: reject}
      var message = {forge: 1, id: id, op: op}
      for (var name in fields) message[name] = fields[name]
      var send = function () { window.parent.postMessage(message, "*") }
      // The frame can load before the forge page around it has joined its socket, and a message
      // sent then is heard by no one. Only `hello`, which is asked again until it is answered,
      // goes at once; everything else waits for that answer.
      if (op === "hello") send()
      else ready.then(send)
    })
  }

  function failure(answer) {
    var error = new Error(answer.reason || "refused")
    error.reason = answer.reason
    error.limit = answer.limit
    return error
  }

  window.addEventListener("message", function (event) {
    if (event.source !== window.parent) return
    var message = event.data
    if (!message || message.forge !== 1) return

    if (typeof message.id === "number") {
      var waiting = pending[message.id]
      if (!waiting) return
      delete pending[message.id]
      if (message.ok) waiting.resolve(message)
      else waiting.reject(failure(message))
    } else if (message.op === "changed") {
      var change = {key: message.key, value: message.value, deleted: !!message.deleted, counter: message.counter}
      changeFns.forEach(function (fn) { fn(change) })
    } else if (message.op === "readonly") {
      current = {viewer: current.viewer, readOnly: !!message.readOnly, reason: message.reason || null}
      readOnlyFns.forEach(function (fn) { fn({readOnly: current.readOnly, reason: current.reason}) })
    }
  })

  // The forge page may mount after this script runs, so the first message is sent until answered:
  // every 250 ms for the first hundred tries and every two seconds after, and never given up,
  // since every other call waits on the answer and a page that loads while forge is slow to join
  // its socket (a slow connection, a restart) has to be able to save once it has.
  var ready = new Promise(function (resolve) {
    var tries = 0
    var answered = false
    function hello() {
      if (answered) return
      ask("hello", {}).then(function (answer) {
        if (answered) return
        answered = true
        current = {viewer: answer.viewer, readOnly: !!answer.readOnly, reason: answer.reason || null}
        resolve({viewer: current.viewer, readOnly: current.readOnly, reason: current.reason})
      })
      setTimeout(hello, tries++ < 100 ? 250 : 2000)
    }
    hello()
  })

  window.forge = Object.freeze({
    ready: ready,
    get: function (key) {
      return ask("get", {key: key}).then(function (a) {
        return a.counter === null && a.value === null ? null : {value: a.value, counter: a.counter}
      })
    },
    all: function () { return ask("all", {}).then(function (a) { return a.entries }) },
    set: function (key, value) { return ask("set", {key: key, value: value}).then(function () {}) },
    delete: function (key) { return ask("delete", {key: key}).then(function () {}) },
    onChange: function (fn) { changeFns.push(fn) },
    onReadOnly: function (fn) { readOnlyFns.push(fn) },
  })
})()
