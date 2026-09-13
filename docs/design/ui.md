# Operator UI

Scope: the standing rules for every operator surface. This note is the standard — code follows
it, and a change of mind updates it first. It supersedes the UI guidance that `platform/AGENTS.md`
used to carry.

The governing idea, from `vision.md`: the operator's attention is the scarce resource, and the
queue is an inbox rather than a dashboard. Exactly one thing in the interface is allowed to be
loud — an item waiting on a human — and it is marked in accent, which is used for nothing else.
Everything else is ruled, monochrome and quiet.

Source material for this note is the redesign handoff vendored under `docs/design/ui/`:
`forge Spec.html` is the specification and `forge Mockups.html` is the evidence. Where this note
and those files differ, this note wins — it is the one that tracks what was built.

## The affordance rule

**A border means you can tap it.** This governs every component.

- **Identifier** — states, statuses, outcomes, branches, commits, artifact names and versions:
  plain mono text, no border, no padding, no background.
- **Answer row** — 52px tall, 1px border, `base-200` ground, `--radius-field`, label left, `›`
  right, sends on tap. The only shape in the queue that commits something.
- **Filled button** — `base-content` fill, and only ever "commit what I typed": the Send beside a
  free-text field.
- **Flag** — filled, uppercase, sharp corners. A label, never a control.

Transition actions carry a verb: `Move to planned ›`, never `→ planned`.

## The three axes

Three orthogonal axes must never render as three colours of one badge. They get three different
*forms*, because form survives greyscale, colour blindness and a glance.

| Axis | Form | Rules |
|---|---|---|
| workflow state | plain mono, leading topology glyph, no box | `▸` job state (info) · `●` human state with outgoing transitions (primary) · `■` terminal (muted). Never coloured by status, never abbreviated. |
| ticket status | filled uppercase flag, beside the state | Rendered only when not `active`. `stuck` carries its age (`STUCK 19h`) in accent. Never replaces the state; never a board column. |
| job outcome | bare mono, coloured, at type scale | The **declared** outcome is the largest thing on the job page. The engine outcome is demoted to smaller mono beside it, with a caption naming which is which. |

Outcome colour maps by bucket, not by string match: success → `success`, non-completion
(`did_not_converge`, `budget_exhausted`) → `warning`, failure (`error`, declared failures) →
`error`, anything unrecognised → neutral. **`did_not_converge` is not an error** — it is the
agent honestly reporting it could not finish. Declared outcomes are project-defined; the list is
never hard-coded.

## Type

Instrument Sans for language, JetBrains Mono for identifiers. Both are OFL and self-hosted from
`platform/assets/fonts/` as subsetted woff2 with `font-display: swap`; there is no webfont CDN
and the product must build without egress. The design depends on the sans/mono *distinction*, not
on these two faces — the system stack is a supported fallback.

| Role | Tailwind | Used for |
|---|---|---|
| Page title | `text-3xl/tight -tracking-[.03em] font-semibold` | Ticket title |
| Section title | `text-2xl -tracking-[.025em] font-semibold` | Queue, Board |
| Decision sentence | `text-xl/[1.3] font-medium` | The one sentence per queue item stating what is asked |
| Declared outcome | `font-mono text-3xl` / `text-xs` | Job page headline / jobs-table column |
| Waiting figure | `font-mono text-[17px]` | Right-aligned on every queue item |
| Body | `text-sm/[1.55]` | Prose, anchors, explanations. Never below 14px on a phone. |
| Identifier | `font-mono text-[12.5px]` | States, outcomes, artifact names, branches, commits, capacity |
| Micro label | `font-mono text-[11px] tracking-[.14em] uppercase` | Card kind, rail section heads. One per block, never two adjacent. |

**Mono is for things the system named**: workflow states, ticket and job statuses, outcomes,
artifact names and versions, branches, commit shas, session ids, environments, capacity, counts,
durations, ages, transition targets, micro labels.

**Mono is never for things a person wrote or reads as language**: ticket titles, question text,
option labels, anchor quotations, explanatory sentences, empty-state copy, verb button labels.

This rule roughly halves the volume of monospace while every identifier still looks like one.

## Colour

Both themes are hand-authored `@plugin "daisyui-theme"` blocks in `platform/assets/css/app.css`,
loaded with `themes: false`. Every value is oklch. Hue is constant across both themes — 300
neutrals, 290 primary, 62 accent, 240 info, 150 success, 22 error — and only lightness and chroma
move. Body text is ≥7:1 against its own base in both themes, muted text ≥4.5:1. The accent is
deliberately identical in both themes with dark content text, so the one loud mark in the product
does not shift meaning when the theme does.

Discipline matters more than the values:

- **Accent means one thing: a human is being waited on.** The queue mark on a blocking or stuck
  item, the `STUCK` flag, the ticket's current-step dot, the board's left rule, the "waiting on
  you" count, the usage meter fill. Nothing else may use it — its value is entirely its scarcity.
  The `RECOMMENDED` tag is outlined rather than accent for exactly this reason, and the window
  capacity gauge is neutral for it too: see `capacity.md`, which departs from the handoff here.
- **Primary** — links, human states, decisions that advance state or spend capacity.
- **Info** — the job-state glyph and harness tool calls. Nothing else.
- **Success** — approval and the end of the queue. **Error** — engine errors, declared failures,
  failed sends.
- **Two surfaces per theme at most**: `base-100` for pages, `base-200` for the one row in a
  changed state. Structure is rules, not cards: `border-base-300` for section rules,
  `border-base-300/60` for rows within a section.

## Space, measure and targets

Base unit 4px. Page gutter `px-5` phone, `px-6`–`px-[30px]` laptop. Queue item `py-[15px]`
collapsed and `py-[18px]` expanded, internal stack `gap-[11px]`. Timeline step `pb-[26px]` laptop,
`pb-5` phone. Separation is a 1px rule, never a shadow — `--depth: 0`, no card shadows anywhere.

Radii: `--radius-selector: 0.3125rem`, `--radius-field: 0.375rem`, `--radius-box: 0.5rem`,
`--border: 1px`, `--noise: 0`.

Every tap target is at least 46px tall, answer rows are 52px and stacked option buttons 48px.
**`btn-sm` does not appear on any operator page.** There is no global page padding and no global
measure; each route sets its own:

| Route | Measure | Why |
|---|---|---|
| `/` | 34rem at every viewport | One ordered list. Width only lets a second item compete for the same glance. |
| `/board` | none | Full viewport. The columns are the workflow topology; capping them destroys the artefact. |
| `/tickets/:project/:number` | 74rem | 53rem timeline column plus a 21rem facts rail, divided by a 1px rule. Below `lg` the rail moves under the timeline. |
| `…/review` | 74rem | Same frame. The diff needs the width; the rail carries the evidence. |
| `…/jobs/:job_id` | 74rem | Same frame. Manifest in the rail, completed harness stream in the column. |
| `/users/log-in`, `/users/settings` | 26rem | Same shell, same type, same buttons. They must not read as a different product. |

Navigation is a fixed bottom bar on a phone (56px plus safe-area inset, each item a full-height tap
target, Queue carrying the only badge in the product) and a hairline-ruled top row on a laptop.
**No hamburger at any width.** The bar carries Queue and Board; it gains Tickets as a third item
when `/tickets` exists, and not before. Ticket, job and artifact are pushed views with a back
affordance naming where you came from, not tabs.

## Motion and structure

Motion is minimal and respects `prefers-reduced-motion`. **Nothing pulses and nothing tails.**
There is deliberately no live transcript, no streaming log, and no activity feed — nothing that
invites watching agents work. The harness stream is paged, newest first, and is headed by its
completion state and entry count.

## Semantics that must not be lost

Getting these wrong makes the UI lie. They are acceptance criteria, not preferences.

- Approval attaches to an **exact artifact version**. Never imply "approve whatever is latest";
  the word "latest" appears nowhere in the product. There is no artifact chip without a version.
- **Blocking and non-blocking questions are different.** One has halted a job. Only blocking ones
  are pushed to the phone; non-blocking ones sit in a digest under *Not waiting on you*.
- **`stuck` is a flag, not a state.** A stuck ticket is still in its workflow state, and stuck is
  drawn on the step rather than as a step.
- **Free text is always a valid answer**, alongside any options — a real field with its own Send,
  never an escape hatch behind a link.
- The queue is **one ordered list**, oldest first. No tabs and no filters that can hide an item;
  the operator must be able to reach the end and know they are done.
- A **human state with outgoing transitions** waits for a person; one without is terminal and
  never enters the queue. The topology glyph is the only thing distinguishing them.
- **Answering never navigates.** Tapping an answer does not move you, open a page, or reorder the
  list; the item changes to its sent state in place.
- **Presentations carry no approval slot at all**, so they cannot be misread as approvable.
  Experimental results are advisory and must never read as verified.
- **The diff is bounded and says where.** Past the page's limit it offers the `git diff` command
  for the exact range instead of trailing off. The file table above it is never truncated: it is
  the map of the change. Dollars do not appear here either — the review page is the surface where
  they are most tempting and least useful.
- A **merge decision** is reached from the queue by a link, never by an answer row. Answering
  never navigates, and the answer row is the one shape in the queue that commits something; a
  link that looked like one would make "read this" and "approve this" the same gesture.

## The queue item

One shape, N kinds, so the list never becomes soup as kinds are added. An item is **one
interruption, not one question**: one job, stopped, against one artifact version, carrying N
questions. A job that stops inside a document typically stops with several questions, and one card
per question would turn three decisions into twenty items with identical timestamps.

Five parts: the mark, kind label and waiting figure; the decision sentence; optional context
including the anchor quotation; the answer affordance; a mono footer of identifiers
(`forge#41 · ▸ planned · plan.md v2`). Separation between items is a top rule, not a card.

Three marks carry all kinds, so the vocabulary scales to the planned set without becoming a colour
quiz. The kind is named in words beside the mark — eight kinds need eight labels but only three
marks.

- **Filled accent diamond** — a job is held or the ticket is stuck.
- **Hollow primary square** — advances state or spends capacity.
- **Hollow success circle** — routine.

The end of the queue is the success state: a success-coloured `END OF QUEUE` micro-label, a
sentence phrased as completion, and one line of evidence that work happened without you. The same
block, alone, is the empty state. Every other empty state names what would fill it rather than
announcing absence.

## Not built yet

Named so their absence is a decision rather than an oversight. Each is specified in the handoff:

- The answering sequence — one ordered full-screen pass over every decision in the queue.
- Message state (queued, retrying, failed, confirmed) and the client outbox with an idempotency
  key per answer. Until it lands, a send is confirmed by the flash the framework already shows.
- Document-with-margin-questions at laptop width.
- Addressable artifact versions (`…/artifacts/:name/:version`) and the `/tickets` finder. Until
  `/tickets` exists the phone bar carries two items, not three.
