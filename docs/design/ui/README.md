# Handoff: forge operator UI redesign

## Overview

A full redesign of the operator interface for **forge**, a self-hosted platform that
moves software tickets through a per-repository, statechart-defined lifecycle executed
by disposable AI agent jobs. Scope was layout and information architecture, not styling
alone: new routes, a new queue model, the ticket page rebuilt as a state timeline, and
consumption re-modelled from money to provider capacity.

The governing idea, taken from the product's own vision: **the operator's attention is
the scarce resource, and the queue is an inbox, not a dashboard**. Exactly one thing in
the interface is allowed to be loud — an item waiting on a human — and it is marked in
ochre, which is used for nothing else.

## About the design files

The two HTML files in this bundle are **design references**, not production code.
They are built as static HTML with inline styles so they render anywhere; they are not
components and they are not meant to be copied into the app.

The target is **Phoenix LiveView with server-rendered HEEx, Tailwind CSS 4 and daisyUI 5**.
The task is to recreate these designs in that environment using its established patterns:
`phx-click` / `phx-submit` bindings, function components in HEEx, daisyUI theme variables,
and Heroicons via the `hero-<name>` class plugin. Hard constraints from the brief that the
implementation must respect:

- No React/Vue/Svelte and no client-side routing. The DOM is patched by the server over a
  websocket; anything stateful in the client must survive patching.
- Tailwind runs `source(none)` with explicit `@source` globs. daisyUI is loaded
  `themes: false` with hand-authored themes in `assets/css/app.css` as
  `@plugin "daisyui-theme"` blocks. All colour values are oklch.
- Two themes, light and dark, both first class. Root carries `data-theme` and
  `data-theme-source`; theme is applied before first paint.
- Heroicons only. No build step beyond Tailwind + esbuild. **No webfont CDN** — fonts must
  be self-hosted, possibly without internet egress.
- Progressive enhancement; respect `prefers-reduced-motion`.

## Fidelity

**High fidelity.** Colours, type scale, spacing, tap-target sizes and copy are final and
should be reproduced exactly. Every colour in the mockups is oklch and maps to a daisyUI
theme variable listed in `forge Spec.html` §4. The two mockup files disagree with nothing —
where an earlier section of the mockup file is superseded, it says so in its caption.

Read `forge Spec.html` first. It is the specification; `forge Mockups.html` is the
evidence. Where the two ever differ, the spec wins.

## Reading order

1. `forge Spec.html` §1 (IA and measures) and §2 (the three axes) — these two sections
   carry most of the design's value.
2. `forge Mockups.html` turns 4, 3 and 2 at the top of the file — these are the newest
   decisions and they supersede the queue drawn in section 02.
3. `forge Spec.html` §6, the implementation order. It is sequenced cheapest-highest-impact
   first and every step ships on its own.

## The central problem this design solves

Three orthogonal axes currently render as one indistinguishable `badge-sm`. They are given
three different **forms**, not three colours of one badge — form survives greyscale,
colour-blindness and a glance:

| Axis | Form | Rules |
|---|---|---|
| **1 · workflow state** | Plain mono text, leading topology glyph, **no box** | `▸` job state (runs a job on entry) · `●` human state with outgoing transitions · `■` terminal. Never coloured by status, never abbreviated. |
| **2 · ticket status** | Filled uppercase flag, *beside* the state | Only rendered when not `active`. `stuck` = filled accent carrying its age (`STUCK 19h`). Never replaces the state; never a board column. |
| **3 · job outcome** | Bare mono text, coloured, at type scale | The **declared** outcome is the largest thing on the job page (30px). The engine outcome is demoted to smaller mono beside it. |

Outcome colour: `converged` and declared successes → success. `did_not_converge` and
`budget_exhausted` → warning (**`did_not_converge` is not an error** — it is the agent
honestly reporting it could not finish). `error` and declared failures → error.

## The affordance rule

**A border means you can tap it.** This governs every component.

- **Identifier** — states, statuses, outcomes, branches, commits, artifact names: plain mono
  text, no border, no padding.
- **Answer row** — 52px tall, 1px border `oklch(38% 0.01 300)`, background
  `oklch(20.5% 0.009 300)`, radius 6px, label left, `›` right, sends on tap. This is the
  only shape in the queue that commits something.
- **Filled button** — white/base-content fill, only ever "commit what I typed" (the Send
  beside a free-text field).
- **Flag** — filled, uppercase, sharp corners. A label, never a control.

Transition actions carry a verb: `Move to planning ›`, not `→ planning`.

## Screens

### 1. Queue — `/`

**Purpose.** One ordered list of decisions, oldest first, answerable without navigating.
No tabs and no filters — the operator must be able to reach the end and know they are done.

**Layout.** 34rem measure, centred, at *every* viewport — the queue deliberately does not
widen on a laptop, because width only lets a second item compete for the same glance. On a
laptop the extra space buys a 1px rule either side of the column and a capacity readout in
the top bar. Page gutter `px-5` phone / `px-6` laptop. Items separated by a 1px top rule,
not cards.

**The queue item is one interruption, not one question.** A job that stops inside a document
typically stops with several questions; one card per question would turn three decisions into
twenty items with identical timestamps. An item is one job, stopped, against one artifact
version, carrying N questions.

Each item is three lines plus its fast path:
- Mark + kind label (counting: `6 BLOCKING QUESTIONS`) + waiting figure, right-aligned mono 16–17px.
- The decision sentence, 17px on the list / 20px when focused, `font-medium`, `-tracking-[.01em]`.
- One answer row carrying the fast path (`Accept all 6 recommendations`, `Approve v3`, `Move to planning`).
- A mono footer of identifiers: `forge#41 · ▸ planning · plan.md v2`.

**Three marks carry all kinds**, so the vocabulary scales to the ~8 planned kinds without
becoming a colour quiz:
- Filled accent **diamond** — a job is held or the ticket is stuck (blocking questions, stuck; later: experiment requests).
- Hollow primary **square** — advances state or spends capacity (approval; later: promotion decisions).
- Hollow success **circle** — routine (review ready; later: analysis proposals).

The kind is named in words beside the mark. Eight kinds need eight labels but only three marks.

**Header** carries `9 decisions · 4 items` and a filled **Start answering ›** button.

**Non-blocking questions** are a digest below the last actionable item under the heading
*Not waiting on you* — present, never hidden, never competing, and never pushed to the phone.

**The end of the queue is the success state.** A success-coloured `END OF QUEUE` micro-label,
a sentence phrased as completion, and one line of evidence that work happened without you.
The same block, alone, is the empty state.

### 2. Sequence — the primary answering mode on a phone

**Purpose.** One ordered pass over every decision in the queue. Nine decisions across four
items are counted as nine. This is how the design expresses "work through these in order".

**Layout.** Full screen. Header: `✕`, `7 of 9`, `item 3 of 4` right-aligned, and a progress
bar **segmented by item, not by decision** — a six-question interruption is one wide segment
containing six ticks, so you can see both how far through you are and how lumpy the rest is.
Body 22px/20px padding. Footer: a 58px `‹` back button and a full-width `Skip for now`.

**Every kind renders here**, not just questions — an approval, a stuck ticket and a
review-ready ticket are each one screen. A focused screen can afford context the card cannot;
the approval screen states what the work cost to reach that point (`3 jobs in implementing ·
0.9 windows · 2 questions answered`) and links to the document.

**Skip is not dismiss.** It advances and leaves the decision open; the item stays in the queue
until every question has an answer. Nothing can be silently cleared.

**Partial answers are first class.** Each question has a stable `key`, so each answer is its
own idempotent mutation — which is what the offline outbox needs anyway. Four answered and two
open is a real state: the queue item reads `4 OF 6 ANSWERED` with a six-tick progress bar and
a `Continue at question 5 ›` row. The job stays held until all six land.

**Open decision:** whether the pass is frozen at entry or live. Recommendation is to freeze at
entry and show a quiet `1 new since you started` on the closing screen, rather than silently
moving the goalposts at 7 of 9.

### 3. Document with margin questions — laptop

At width the document comes back, because questions were asked *next to a passage*. The anchor
is highlighted in place (accent underline, `oklch(24% 0.035 62)` ground) and the question sits
in a 400px right panel beside it. Only the current question is expanded; answered ones collapse
to their answer with a success `✓ answered`; ones below collapse to their recommendation. Header
offers `Accept the remaining 5 recommendations` — never "all 6" when one is already answered, as
that would overwrite an answer the operator gave.

### 4. Ticket — `/projects/:project/tickets/:number`

**Purpose.** What happened to this ticket, what it cost, and the one thing it may be waiting for.

**Layout.** 74rem cap: a 53rem timeline column and a 21rem facts rail, divided by a 1px rule.
Below `lg` the rail moves under the timeline.

**Header.** `project#number` in mono 12px; title at `text-3xl`, `font-semibold`,
`-tracking-[.03em]`; then the state (plain mono with glyph), the status flag if any, and a
plain-language clause for why it is waiting. Usage is **not** in the header — it is the first
block of the rail, where it can carry its allowance.

**Hoisted decision.** If the ticket has an answerable action it appears **once**, directly under
the header, in an accent-bordered block on `oklch(18.5% 0.014 62)`. Everything below is
reference. This and the current-step dot are the only accent on the page.

**Timeline.** One step per state visit, with a 26px rail column: an 11px dot, a 1px connector.
Each step carries the state name in mono, the topology glyph, a jobs table (attempt, declared
outcome, turns, usage), artifact chips written in that state, and a right-aligned summary
(`3 jobs · 0.67 windows`). The current step's dot is accent with a 4px ring at 18% alpha.
States not yet reached are drawn at 50% opacity; the rail stops at a terminal state.

**Stuck is drawn on the step, never as a step.** There is no `stuck` row in the timeline
because there is no such state.

**Branching and going back** (discussed, not yet drawn — implement when the case arises): order
the spine by **time, not topology**. A step is a *visit* to a state, so a revisit is simply
another step further down with the same name, its head carrying the cause
(`planning · returned from implementing`). Unreached states then collapse into one dimmed *ahead*
block at the foot rather than being interleaved. Fan-out within a state (planned §7 "blocks")
stays inside the jobs table as one level of indent with a rejoin label — **never a drawn graph.
The spine is always linear, because it is a history and history does not branch.**

**Rail.** Usage meter, facts (branch, base, workflow commit, admitted), artifact index with
approval state per version, and the last four events with a link to all of them. The full event
timeline moves off the page into its own disclosure — 200 rows of mono is a post-mortem tool.

### 5. Job — `/projects/:project/tickets/:number/jobs/:job_id`

Same 74rem frame. **The declared outcome is the page headline** at `text-3xl` mono in its
outcome colour, with the engine outcome as smaller mono beside it and a caption naming which is
which. Turns, usage and duration are three figures in a row, turns always against budget.

**Rail = the pinned manifest**: branch, workflow commit, environment, budget, session, then each
input artifact **at its exact version**. When an input has been superseded the row reads
`v2 exists` in warning and a sentence states the platform did not re-run on its own.
Allowed outcomes are listed as plain mono with the taken one coloured and marked `←`.

**Harness stream** is headed `COMPLETE · 212 ENTRIES`, newest first, 50 per page, with a
`Load 50 more` button. **No tailing, no autoscroll, no pulse** — there is deliberately no live
transcript in this product. Rows are a `56px 132px 1fr` grid: elapsed, kind, summary (truncated).

### 6. Board — `/projects/:project/board`

Full viewport width, **no max measure** — the columns are the workflow topology and capping them
destroys the artefact. Columns in workflow-walk order from the initial state, each headed by the
state name, its topology glyph and its count.

**Columns cap at four rows and then say how many remain** (`8 more →`). A column that scrolls
independently hides its own count and breaks the board as a shape. Finding a specific ticket is
`/tickets`, not this page.

Cards are two lines: number in mono 11px, title in sans 13px. A ticket waiting on a human gains a
2px accent left rule and a mono age (`STUCK 19h`). The human-state column gets a tinted ground
(`oklch(17.8% 0.012 285)`). Terminal columns are dimmed. Header carries three figures only: open
count, `2 waiting on you` in accent, capacity.

On a phone the columns become sections in the same order, collapsed except any section containing
work that waits on you.

### 7. Artifacts

The unit is a **chip**: name, version, approval state. **There is no chip without a version and
the word "latest" appears nowhere in the product** — approval attaches to an exact version, and a
human edit creating v3 does not carry v2's approval.

- `✓ approved` in success · `◇ unapproved` in warning · no marker where approval does not apply.
- Chips are bordered because they are links — consistent with the affordance rule.
- Opening a chip discloses a version strip: `v1 · agent → v2 · you, edited → v3 · agent`. This is
  provenance, and it is where multi-user attribution lands later without a redesign.
- A **presentation** is drawn dashed with `VIEW ONLY` and **has no approval slot at all**, so it
  cannot be misread as approvable. Nothing downstream consumes it.

### 8. Auth and settings

Same shell, same type, same buttons, 26rem measure. They must not read as a different product.
Registration stays disabled with its existing copy.

## Capacity, not cost

Consumption is modelled as **consumed capacity, not money**. One unit is one percent of a
five-hour window, and quantities are stated in **windows** to two significant figures
(`1.4 windows`). This survives work that spans four windows and a week, which a percentage
cannot, and it replaces `$0.15562769999999998` everywhere.

Two objects, never drawn the same way:

- **Usage** is absolute and never resets: a job's usage, a step's sum, a ticket's total against
  its allowance. A figure plus a 5px meter filled accent.
- **Capacity** is a live shared pool that refills: the current five-hour window and the week.
  The window is a **twenty-tick gauge** (one tick per five percent) with a mono reset countdown,
  because you are consuming it rather than progressing through it; it compresses to ten ticks in
  the top bar. The week is a thin plain bar beneath and becomes the headline only when it binds.

A ticket allowance stays **absolute** — a cap expressed as a share of a refilling pool would mean
something different on Monday than on Friday.

**Three things can run out, and only one is the operator's:**

| Exhausted | Resolved by | Treatment |
|---|---|---|
| Job turn budget | the engine retries | outcome `budget_exhausted` on the job row, nowhere else |
| Ticket allowance | **a human** — raise it or reroute | sticks the ticket, enters the queue, drawn in **accent** |
| Window / weekly capacity | **time** | `PAUSED · CAPACITY 1h 12m`, neutral, on board and ticket, **never in the queue** |

Keeping the third out of the queue is load-bearing. A paused ticket in the inbox trains the
operator to open items they cannot act on, which is the exact failure the thesis is written
against.

## Message state — the stated differentiator

Four states, **one row shape, always attached to the item acted on — never a toast**, because a
toast that disappears is precisely the failure the vision calls impossible by construction.

| State | Drawing | Copy |
|---|---|---|
| Queued / sending | 14px spinner ring, accent top-border | "Answer queued — sending" / "saved on this device" + **Undo** |
| Retrying | accent diamond, accent-bordered row on `oklch(18.5% 0.014 62)` | "Retrying — attempt 2 of 5" / "next in 8s · offline" + **Retry now** |
| Failed | error dot, error-bordered row on `oklch(19% 0.03 22)` | "Not sent — gave up after 5 tries" / "still saved · tap to try again" |
| Confirmed | success `✓` | "Confirmed by the server" / "19:41 · job resumed" |

The answered item **stays in place and does not reorder**. The answer is never discarded. The
confirmed row names the *consequence* (`job resumed`), so it closes the loop rather than just the
request. An offline banner states how many answers are waiting to send. The two generic reconnect
banners are replaced by one that names the consequence for the operator's own work.

**One tap still sends** — the safety net is the Undo row, not a confirm step. Answering one-handed
in seconds is the product's primary interaction and a confirm step doubles every tap in it.

## Interactions and behaviour

- **Answering never navigates.** Tapping an answer does not move you, open a page, or reorder the
  list. The item changes to its sent state in place.
- **Entering the sequence is not navigation either** — it is the item opening full-screen, and
  leaving returns you to the list at the item you were on, with everything answered already sent.
- **Nav.** Phone: fixed three-item bottom bar (Queue, Board, Tickets), 56px plus safe-area inset,
  each item a full-height tap target. Queue carries a count badge — the only badge in the product.
  Bottom rather than top because answering is a thumb action. Laptop: the same three as a
  hairline-ruled top row after the wordmark. **No hamburger at any width.**
- **Ticket, job and artifact are pushed views** — a back affordance naming where you came from, not
  a tab. A ticket opened from a push notification backs out to the queue.
- **Tap targets** are ≥46px, answer rows 52px, and `btn-sm` does not appear on any operator page.
- **Motion** is minimal and must respect `prefers-reduced-motion`. Nothing pulses, nothing tails.

## State management

Server-side (LiveView assigns): the ordered queue with each item's `since` timestamp; per-question
answer state keyed by the question `key`; ticket timeline grouped by state visit; capacity window
and week with reset times; per-mutation send state.

Client-side, and this is the real engineering in the design: an **outbox** that survives LiveView
DOM patching and page reload. Each answer carries an **idempotency key** (the question `key` plus
the artifact version) so a retry cannot double-apply. The design assumes **no live socket at the
moment of answering** — answers are composed offline and synced. A service worker already exists
for web push and is the natural home for the store.

## Design tokens

Both themes are specified in full as `@plugin "daisyui-theme"` blocks in **`forge Spec.html` §4.1
and §4.2** — copy them verbatim into `assets/css/app.css`. Every variable the current themes set is
covered, in oklch, contrast-checked to WCAG AA for body text.

Hue is constant across both themes (300 neutrals, 290 primary, 62 accent, 240 info, 150 success,
22 error); only lightness and chroma move. Body text is ≥7:1 against its own base in both themes,
muted text ≥4.5:1.

**The accent is deliberately identical in both themes** with dark content text, so the one loud
mark in the product does not shift meaning when the theme does.

**Colour discipline, which matters more than the values:**

- **Accent (ochre) means one thing: a human is being waited on.** The queue mark on a blocking or
  stuck item, the `STUCK` flag, the ticket's current-step dot, the board's left rule, the
  "waiting on you" count, the usage meter fill and the window gauge. **Nothing else may use it** —
  its value is entirely in its scarcity. (Note: the `RECOMMENDED` tag is *outlined*, not accent,
  for exactly this reason.)
- **Primary (indigo)** — links, human states, decisions that advance state or spend capacity.
- **Info (blue)** — the job-state glyph and harness tool calls. Nothing else.
- **Success** — approval and the end of the queue. **Error** — engine errors, declared failures, failed sends.
- **Two surfaces per theme at most**: `base-100` for pages, `base-200` for the one row in a changed
  state. Structure is **rules, not cards** — `--depth: 0`, no shadows.

**Type.** Instrument Sans for language, JetBrains Mono for identifiers. Both OFL and self-hostable,
which is the binding constraint. Ship subsetted woff2 (latin; weights 400/500/600 and 400/500/700)
in `assets/fonts/` with a local `@font-face` block and `font-display: swap` — roughly 90 KB total.
Scale and the full mono-vs-sans rule are in **`forge Spec.html` §3**. The short version:

- **Mono is for things the system named** — states, statuses, outcomes, artifact names and versions,
  branches, commits, session ids, environments, capacity, counts, durations, ages, transition
  targets, micro labels.
- **Mono is never for things a person wrote or reads as language** — ticket titles, question text,
  option labels, anchor quotations, explanatory sentences, empty-state copy, verb button labels.

This rule alone roughly halves the volume of monospace while every identifier still looks like one.

**Spacing.** Base unit 4px. Page gutter `px-5` phone / `px-6`–`px-[30px]` laptop. Queue item
`py-[15px]` collapsed, `py-[18px]` expanded, internal stack gap `gap-[11px]`. Timeline step
`pb-[26px]` laptop / `pb-5` phone. **The existing `py-20` page padding goes** — vertical space on a
phone is the scarcest resource in the product after attention.

**Radii.** `--radius-selector: 0.3125rem`, `--radius-field: 0.375rem`, `--radius-box: 0.5rem`,
`--border: 1px`, `--depth: 0`, `--noise: 0`.

## Assets

None. No images, no illustrations, no custom SVG. Every glyph in the design is either a Heroicon
or a text character (`▸ ● ■ ✓ ◇ › ‹ ✕ ←`) — the topology glyphs are deliberately text so they
inherit colour and size from the identifier they belong to.

## Implementation order

`forge Spec.html` §6 has the full table with reasoning. Sequenced cheapest-highest-impact first;
every step ships on its own and none requires the next:

1. Theme blocks, self-hosted fonts, remove `py-20`, raise tap targets off `btn-sm`. *(Pure CSS.)*
2. Capacity formatter and relative-age helper; show the waiting figure on every queue item.
   *(The `since` value is already loaded and discarded — cheapest real information gain here.)*
3. The three indicator components, replacing every `badge-sm`. *(Every later step consumes them.)*
4. Queue item shape, per-kind marks, the interruption model, the digest, the end-of-queue block.
5. Per-page measures and the phone bottom bar; drop the global `max-w-2xl`.
6. Board: workflow-order columns at full width, row cap, waiting marks, phone sections.
7. Message state: pending / retrying / failed / confirmed, with an idempotency key per mutation.
   *(Visible state and retry first, offline compose second.)*
8. The answering sequence.
9. Ticket page as a state timeline; artifact chips; events behind a disclosure.
10. Job page: declared outcome as headline, manifest rail, paged stream, stale-input notice.
11. Addressable artifact versions, then `/tickets`.

## Semantics that must not be lost

Getting these wrong makes the UI lie. They are the acceptance criteria:

- Approval attaches to an **exact artifact version**. Never imply "approve whatever is latest".
- **Blocking and non-blocking questions are different.** One has halted a job. Only blocking ones
  are pushed to the phone.
- **`stuck` is a flag, not a state.** A stuck ticket is still in its workflow state.
- **Free text is always a valid answer**, alongside any options — a real field with its own Send,
  not an escape hatch behind a link.
- The queue is **one ordered list**. No tabs or filters that can hide an item.
- A **human state with outgoing transitions** waits for a person; one without is terminal. The
  topology glyph is the only thing distinguishing them.
- **`did_not_converge` is not an error.**
- **No live transcript.** Do not build an activity feed, a streaming log, or anything that invites
  watching agents work.
- **Presentations carry no approval semantics.** **Experimental results are advisory** and must
  never read as verified.

## Open decisions — answer before or during implementation

These are design-affecting, not cosmetic. `forge Spec.html` §8 carries the full list.

1. **Can a job resume on a partial answer set?** If yes, the sequence should order questions by
   what unblocks the most and "answer the two that matter" becomes a real affordance. If no, the
   all-or-nothing hold as drawn is correct.
2. **Can two jobs on one ticket be held at once?** If so the queue carries two items for one
   ticket and each must name its job.
3. **Does the provider report a real window boundary and reset time?** Without it the capacity
   countdown is a guess, and a wrong countdown is worse than none.
4. **Does a job at a window edge hibernate and resume, or fail and retry?** The `PAUSED`
   treatment assumes the former; it is where the planned hibernation work surfaces.
5. **Is the answering pass frozen at entry or live?** Recommendation: frozen, with a quiet
   `1 new since you started` on the closing screen.
6. **Can the workflow grammar declare a bucket** (success / non-completion / failure) per allowed
   outcome, so declared-outcome colour is not inferred by string matching? Declared outcomes are
   project-defined; **do not hard-code the list.**
7. **Can the engine report "an input artifact of this job has been superseded"?** The stale-input
   notice needs it.
8. **Is `/tickets` worth the query work now?** Nothing else depends on it; without it the phone
   bar drops to two items.
9. **Do dollars survive anywhere?** Recommendation: they leave every operator surface. A number the
   operator cannot act on is noise.
10. **Retry policy** — five attempts with backoff is assumed by the copy and should match what is
    implemented.
11. **Are self-hosted webfonts acceptable at all?** If not, the system stack is a supported
    fallback; the design depends on the sans/mono *distinction*, not on these two faces.

## Where this design could paint you into a corner

Stated plainly so it is a known trade rather than a surprise:

- **Capping board columns at four rows** assumes the board stays a *shape* rather than becoming a
  workspace. If tickets ever need dragging between states, the cap has to go and columns become
  scrollers.
- **The queue's refusal of tabs and filters** is correct at one operator and a handful of items.
  If multi-user arrives and the list carries items addressed to other people, the honest answer is
  **per-person queues, not filters.**
- **A time-ordered timeline spine** loses the "see where this ticket is going" property that a
  topology-ordered one has. The dimmed *ahead* block recovers most of it, but it cannot show which
  branch of a conditional the ticket will take — and it should not guess.

## Files

| File | What it is |
|---|---|
| `forge Spec.html` | **The specification.** Both daisyUI theme blocks in oklch, type and spacing scales, the mono rule, per-component specs, IA and measures, implementation order, fit with the planned roadmap, open decisions. Printable. **Read this first; where it and the mockups differ, it wins.** |
| `forge Mockups.html` | **The evidence.** Annotated mockups at phone (390px) and laptop (1180px). Newest work is at the **top**: turn 4 (sequence as primary mode), turn 3 (many questions per interruption), turn 2 (the affordance rule). Below them, sections 01–07: IA, queue, ticket timeline, job, board at 50 tickets, component specimens, capacity. Annotations beside each frame give the *reason*, not the pixel. |
| `forge Directions.html` | The three visual directions explored before "Bureau" was chosen. Historical context only — **do not implement from this file.** |
| `forge-ui-design-brief.md` | The original brief this work answers. |
