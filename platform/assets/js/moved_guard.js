// The moved-button guard (docs/design/ui.md § The moved-button guard): a button whose position
// changed in the last `--moved-guard` (500 ms) ignores a tap. A row that left above it, a panel
// that folded, a list that recounted — each moves what is under a finger at the moment it lands,
// and a tap meant for *Later* lands on *Approve*.
//
// Where each visible button is drawn is recorded once a frame, after anything on the page
// changed; a click on one that moved within the window is swallowed in the capture phase, before
// LiveView or a form sees it. Only the client knows where a thing was drawn, so it is here.
//
// The place is the layout's (the `offsetParent` chain), not the viewport's: scrolling moves
// every button on the screen and is the person's own doing, so it must not arm the guard. A
// button seen for the first time has no earlier place and is not armed either — what appears
// under a finger is the drop panel the person opened.

const TARGETS = "button, a.ui-btn, [role=button], input[type=submit]"

const places = new WeakMap()
let pending = false

const windowMs = () => {
  const value = getComputedStyle(document.documentElement).getPropertyValue("--moved-guard").trim()
  const n = parseFloat(value)
  if (!Number.isFinite(n)) return 500
  return value.endsWith("ms") ? n : n * 1000
}

const place = (el) => {
  let x = 0
  let y = 0
  for (let node = el; node; node = node.offsetParent) {
    x += node.offsetLeft
    y += node.offsetTop
  }
  return {x, y, w: el.offsetWidth, h: el.offsetHeight}
}

const same = (a, b) => a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h

const measure = () => {
  pending = false
  const now = performance.now()

  for (const el of document.querySelectorAll(TARGETS)) {
    // Not drawn: keep where it was, so that coming back somewhere else counts as a move.
    if (el.getClientRects().length === 0) continue

    const here = place(el)
    const was = places.get(el)

    if (!was) places.set(el, {...here, movedAt: -Infinity})
    else if (!same(was, here)) places.set(el, {...here, movedAt: now})
  }
}

const schedule = () => {
  if (pending) return
  pending = true
  requestAnimationFrame(measure)
}

export const guard = () => {
  new MutationObserver(schedule).observe(document.documentElement, {
    attributes: true,
    characterData: true,
    childList: true,
    subtree: true,
  })
  window.addEventListener("resize", schedule)
  schedule()

  document.addEventListener("click", (event) => {
    // A click from the keyboard (`detail` 0) or from a script is aimed by focus, not by where
    // something was drawn.
    if (event.detail === 0) return

    const el = event.target.closest?.(TARGETS)
    if (!el) return
    if (pending) measure()

    const at = places.get(el)
    if (at && performance.now() - at.movedAt < windowMs()) {
      event.preventDefault()
      event.stopImmediatePropagation()
    }
  }, true)
}
