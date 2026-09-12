# forge — operator UI design brief

You are redesigning the operator interface of **forge**, a self-hosted platform that moves
software tickets through a per-repository, statechart-defined lifecycle executed by
disposable AI agent jobs.

Scope: **rethink layout and information architecture**, not just styling. Optimise for
**phone and laptop equally**. Deliver a **design spec plus concrete tokens**; the engineer
implements it in Phoenix HEEx.

**How to read this brief.** §1–§6 describe what exists and can be tested today. §7 describes
where the product is going, from its own vision and plan documents. Everything in §7 is
marked **PLANNED** and is *not built* — do not design those screens, and do not specify
indicators for states that cannot occur yet. But the system you specify in §1–§6 should
**absorb §7 without a rewrite**: a card vocabulary that already has eight kinds in it, a
ticket view whose shape survives becoming a state timeline, a budget treatment that will take
a second ceiling. Where a decision today forecloses something in §7, say so.

---

## 1. The thesis the design must serve

> **The operator's attention is the scarce resource.** Nothing reaches them until it has been
> verified, and what does reach them arrives as an ordered queue of decisions.

And, on the interface specifically, from the vision:

> **The queue is the home screen. Not a dashboard — an inbox.** … answerable in sequence
> without navigating back.

Consequences:

- The queue is a **work-through-in-order list of decisions**, each answerable in place. If
  the design makes the operator choose *what to look at*, it has failed the thesis.
- Board, ticket and job views are for **when the operator goes looking** — after a decision,
  or during a post-mortem. Legible and calm, not attention-seeking.
- **There is deliberately no live transcript.** The vision is explicit: *"Watching agents work
  is how a review budget disappears."* Do not design an activity feed, a streaming log, or
  anything that invites watching. The job page shows a completed event stream, on purpose.
- **Reliability is the stated differentiator**, not an afterthought: *"message state visible,
  sends retried, answers composed offline and synced. The current failure — a message that
  vanishes silently — must be impossible by construction."*

The single operator is technical — they own the repositories, read diffs, know what a branch
is. Do not simplify the vocabulary. Do make its structure legible, because three distinct
concepts currently render identically (§4).

---

## 2. The two contexts

The vision calls the web application **mobile-first**. Treat phone and laptop as equally
important, with the phone leading where they conflict.

**Phone, away from the desk.** The near-term milestone demands a ticket be *driven entirely
from a phone, including one push notification answered from a lock screen*, with *message
state observed on a phone network*. Answering a blocking question must be possible
one-handed, in seconds, without zooming. This is the product's primary interaction.

**Laptop, at the desk.** Reading a plan or a diff, scanning a board across states, auditing a
job's pinned manifest and event stream. Wants width and density.

Today's UI is desktop-shaped and not good at that either: a top navbar, a hard `max-w-2xl`
column on *every* page, and `py-20` padding that costs a phone most of a screen.

---

## 3. Hard technical constraints

Non-negotiable — a design that ignores these cannot be built.

- **Phoenix LiveView, server-rendered HEEx.** No React/Vue/Svelte, no client-side routing.
  The DOM is patched by the server over a websocket; anything stateful in the client must
  survive patching. Interactions are `phx-click` / `phx-submit` bindings.
- **Tailwind CSS 4 + daisyUI 5.** Tailwind runs `source(none)` with explicit `@source` globs;
  daisyUI is loaded `themes: false` with two hand-authored themes in `assets/css/app.css` as
  `@plugin "daisyui-theme"` blocks. All colour values are **oklch**.
- **Two themes, light and dark, already wired.** The root element carries `data-theme`
  (`light`/`dark`) and `data-theme-source` (`system`/`user`); a three-way toggle sets them and
  the theme is applied before first paint. **Both are first-class.** You are replacing both
  palettes, so specify both fully.
- **Heroicons only**, as `hero-<name>` classes (incl. `-micro`/`-mini`) via a Tailwind plugin.
- **No build step beyond Tailwind + esbuild**, both pinned via Nix. No CSS-in-JS, no PostCSS
  plugins, **no webfont CDN** — self-hosted, possibly without internet egress. A non-system
  typeface must be self-hostable, and say so.
- **Progressive enhancement.** A service worker exists for web push only. Respect
  `prefers-reduced-motion` (`motion-safe:` is already used).

---

## 4. The domain vocabulary, and the central design problem

**Three orthogonal axes** currently render as one indistinguishable `badge-sm` through a
four-colour mapping. Separating them is the single most valuable thing you can do.

**Axis 1 — workflow state.** Where the ticket is in its lifecycle. Project-defined, not
fixed; e.g. `refined → planned → implemented → verified → review_ready → merged`. Two kinds:
*job states* run an agent job on entry; *human states* hold the ticket for a person
(`review_ready`), and a state with no outgoing transitions is terminal (`merged`). Transitions
may require **approval** of named artifacts, may be conditional on a job's outcome, and may
carry a retry cap.

**Axis 2 — ticket status**, the engine's view: `active`, `stuck`, `done`, `cancelled`.
**`stuck` is an engine flag, not a workflow state** — no transition matched, or a retry cap or
cost ceiling was hit, and a human must choose the way out. A stuck ticket is still *in* its
state. Do not render stuck as a place in the lifecycle.

**Axis 3 — job status and outcome.**
- status: `pending`, `running`, `waiting`, `hibernated`, `finished`
- outcome once finished: `converged`, `did_not_converge`, `budget_exhausted`, `error`,
  `cancelled`
- plus a **declared outcome** the agent selected from the workflow's allowed list — e.g.
  `done`, `plan_invalid`, `tests_failed`. Currently bare parenthetical text, though often the
  most informative field on the page.

`tests_failed`, `budget_exhausted` and `converged` are three completely different situations.
That should be obvious at a glance.

*Reachable today:* every ticket status except `cancelled`; job statuses `pending`, `running`,
`waiting`, `finished`; outcomes `converged`, `did_not_converge`, `budget_exhausted`, `error`.
`hibernated` and `cancelled` exist in the schema but nothing can produce them yet (§7).

### Other domain objects

**Artifacts** are the handoff contract between steps: immutable, versioned, attributed. Names
come from the workflow (`plan.md`, `implementation.md`, `report.md`), plus reserved
`changeset` (the diff of the ticket branch against its base) and `answers.md`. Three kinds
exist in the model — `document`, `blob`, `presentation` — but **only documents are produced
today**, rendered from markdown to HTML. **Approval attaches to an exact version, never to
"latest"**: a human edit creates a new version, and approving v1 does not carry to v2. The UI
must never blur this. When an upstream document moves ahead of what a job consumed, the
platform says so rather than silently re-running — so "your input is stale" is a state worth
designing.

**Questions** are asked by agents inside a document, next to the passage they concern. Each
has a stable `key`, the `text`, an `anchor` (the quoted passage), a short list of `options`, a
recommended `default`, and a `blocking` flag:
- **blocking** — the job has stopped and holds no process. This is what is pushed to the phone.
- **non-blocking** — the agent stated an `assumption` and continued. Digested, not urgent.

These must be visually distinct; today only the label text differs. **Free text is always a
valid answer** alongside the option taps — options are a convenience, never a constraint.
This same mechanism carries *every* human interruption in the system, which is why §7's new
queue kinds are not really new machinery.

**Events** form an append-only timeline: `ticket.admitted`, `artifact.version_written`,
`job.created`, `job.started`, `job.finished`, `job.interrupted`, `approval.requested`,
`approval.approved`, `approval.rejected`, `question.answered`, `transition.taken`. A separate
high-volume `job.harness.*` stream (the agent's own tool calls, text and results) appears only
on the job page.

**Cost** is real money, accumulated per job and summed per ticket against a workflow-declared
ceiling (`limits.ticket_cost`) that sticks the ticket when reached. Jobs also carry a **turn
budget**. Both are shown as bare numbers with no sense of the ceiling.

---

## 5. The pages as they exist today

All four operator pages are a single `max-w-2xl` centred column under a desktop navbar
(`forge` wordmark, Queue, Board, theme toggle).

**`/` Queue** — one flat, oldest-first list of four card kinds, all styled identically as
`card bg-base-200 shadow-sm` with an uppercase micro-label:
1. **question** — blocking only, option buttons with the default highlighted, plus free text.
2. **approval** — `from → to on outcome`, the artifacts it approves, a comment, Approve/Reject.
3. **stuck** — the state it is stuck in, a button per available transition.
4. **review** — a ticket resting in a human state with a way forward; same buttons.

Plus a "Notify me" button subscribing this browser to web push. Empty state: *"Nothing needs
you right now."*

**`/board` Board** — per project, tickets grouped into columns by workflow state. **Column
order is derived by walking the project's pinned workflow from its initial state**, so the
columns encode the real topology of the lifecycle — which the flat presentation discards. Each
card: ticket link, status badge, cost. Squeezed inside `max-w-2xl` with its own horizontal
scroller of `w-56` columns.

**`/tickets/:project/:number` Ticket** — header (project#number, title, state, status, cost,
branch, body); pending approval card; open questions; a transition card if stuck or in a human
state; the jobs list (state #attempt, status, outcome, turns, cost); artifacts as collapsible
sections with markdown rendered inline; the event timeline as small monospace rows.

**`/tickets/:project/:number/jobs/:job_id` Job** — header (state #attempt, status, outcome,
turns, cost, harness session id); the **pinned manifest** (branch, workflow commit,
environment, budget, allowed outcomes, each input artifact with its exact version); the
harness event stream.

**`/users/log-in`, `/users/settings`** — stock Phoenix screens; email+password and magic link.
**Registration is deliberately disabled** (accounts are made from the command line, and the
page says so). Low priority, but they should not look like a different product.

---

## 6. Problems to solve now

1. **Three axes, one badge** (§4). Separate them; give `declared_outcome` real prominence.
2. **`max-w-2xl` on everything.** The board is a wide artefact forced into a narrow column.
   Different pages want different measures.
3. **Waiting time is computed and discarded.** Every queue item carries the `since` timestamp
   the list is *ordered by*, and the UI never shows it. "This has been waiting two days" is
   plausibly the most important thing on a card.
4. **Cost renders as a raw float**: `$0.15562769999999998`. There is a per-ticket ceiling and
   a per-job turn budget — a consumption story to tell, and no number wants that precision.
5. **Four card kinds that look the same.** A blocking question, a money-spending approval, a
   stuck ticket and a routine review read as one texture. Their urgency differs sharply — and
   §7 adds four more kinds to the same list.
6. **Monospace is the dominant texture.** Every state, branch, outcome and commit is
   `font-mono`. They are identifiers and should look like it, but it currently overwhelms.
7. **No mobile navigation**, heavy `py-20` padding, `btn-sm` tap targets.
8. **Message state is unmet and is the stated differentiator.** Today: `phx-disable-with` on
   buttons plus two generic reconnect banners ("We can't find the internet", "Something went
   wrong!"). Needs a real pending / failed / retrying / confirmed story — see §7 for where it
   goes (offline compose and sync).
9. **Empty and error states are one grey sentence.** The queue's empty state is what a
   well-running system looks like; it should feel like success, not absence.
10. **No affordance for scale.** Everything assumes a handful of tickets. A board with 50
    tickets across 6 states, or a timeline of 200 events, degrades badly.

---

## 7. PLANNED — where this is going

From the vision and the PoC plan. **None of this is built.** Do not design these screens or
specify indicators for unreachable states. Do make sure §1–§6 absorbs them.

**The queue grows more kinds.** The vision's queue carries *blocking questions, transition
approvals, **experiment requests**, **promotion decisions** and review-ready tickets* — and
eventually **analysis-agent proposals**. So plan a card vocabulary that scales to ~8 kinds in
one ordered list without becoming soup, and without tabs or filters that can hide an item.

**The ticket view becomes a state timeline.** The vision specifies *"a vertical timeline of
states with outcome, cost and artifacts per step"* — not today's flat stack of sections. If
your IA rethink heads that way already, so much the better.

**Merge approval becomes its own rich view**: *the diff alongside what the platform uniquely
knows — the verification report, the chain of documents the change was built from, the
questions answered along the way, and total cost.* This is the densest screen the product
will have. Do not design it; do leave room for it.

**Artifacts gain two more kinds.** *Blobs* — build output, test logs, **screenshots** — held
in object storage, served through the platform rather than provider signed links, so image
and log viewing arrives. *Presentations* — rich, human-only views (e.g. a `report.html`
beside a `report.md`); **nothing downstream may consume them, so they carry no schema and no
approval semantics.** A presentation must never look approvable. The grammar also reserves
prefix groups (`screenshots/*`) for blob outputs with an open member count.

**Jobs gain hierarchy.** Within a state, work can fan out and rejoin — two plan drafts
compared by a third agent, an implementation followed by a self-review — as named reusable
*blocks*. Agents may spawn children from an explicitly permitted set, under a depth limit.
So the flat jobs list becomes a tree, and a job page may have a parent and children.

**Experiments and promotion.** A job may request permission to experiment, through the same
interruption mechanism as any blocking question. Results are **advisory and marked
experimental**; promoting one into the shared definition is a second, separate approval. So
artifacts and outcomes need an "experimental, advisory" treatment that cannot be mistaken for
a verified result.

**Workers become real.** A worker tier with provider, status, memory budget and last-seen
time; jobs scheduled onto workers and destroyed when idle. This is when **`hibernated`**
becomes reachable — jobs commit and hibernate on interruption and resume from branch and
manifest. Possibly a small infrastructure view.

**Cancel becomes reachable.** The engine already produces the `cancelled` outcome from an
operator kill, but nothing in the UI or API triggers it yet. Expect a cancel affordance on a
running job, and `cancelled` to start appearing.

**Budgets gain a second dimension**: spend caps **per ticket and per day**, platform-enforced.
Whatever you design for cost must take another ceiling.

**Multi-user, eventually.** Single-operator today, but the data model carries users and roles
from the start — **approver, promoter, spender**. Sessions with optional second factor; all
mutations audited into the same event log. So attribution ("who approved this version") should
have somewhere to live, even while there is one user.

**Message state, fully.** Beyond visible state and retry: *answers composed offline and
synced*. The design should not assume a live socket at the moment of answering.

---

## 8. Semantics that must not be lost

Getting these wrong makes the UI lie:

- Approval attaches to an **exact artifact version**. Never imply "approve whatever is latest".
- **Blocking and non-blocking questions are different.** One has halted a job.
- **`stuck` is a flag, not a state.** A stuck ticket is still in its workflow state.
- **Free text is always a valid answer**, alongside any options.
- The queue is **one ordered list**. No tabs or filters that can hide an item — the operator
  must be able to reach the end and know they are done.
- A **human state** with outgoing transitions waits for a person; one without is terminal.
  These look identical today and should not.
- **`did_not_converge` is not an error.** It is the agent honestly reporting it could not
  finish.
- **No live transcript.** Do not invite watching agents work.
- PLANNED: **presentations carry no approval semantics** and nothing downstream consumes them;
  **experimental results are advisory** and must not read as verified.

---

## 9. What to deliver

1. **Both themes as concrete daisyUI theme blocks**, in oklch: every variable the current
   themes set — `--color-base-100/200/300`, `--color-base-content`, `primary`, `secondary`,
   `accent`, `neutral`, `info`, `success`, `warning`, `error` with their `-content` pairs, plus
   `--radius-selector/field/box`, `--size-selector/field`, `--border`, `--depth`, `--noise`.
   Light and dark fully specified, contrast-checked to WCAG AA for body text.
2. **Type and spacing scales** in Tailwind terms, including the identifier/monospace treatment
   and when it applies.
3. **Per-component specs**: the four queue card kinds (extensible to ~8), the
   state/status/outcome indicators, the ticket header, the job manifest, the board column and
   card, the artifact disclosure, the timeline row, the message-state affordances
   (pending/failed/retrying/confirmed), and the empty states.
4. **Annotated mockups** of the four operator pages at phone and laptop widths — annotated
   with reasoning, not just pixels.
5. **A layout and IA recommendation**: the measure each page wants, how navigation works on a
   phone, and how the queue expresses "work through these in order".
6. **An implementation order**, cheapest-highest-impact first, so it lands incrementally.
7. **A short note on §7 fit**: for each planned item, whether your design absorbs it as-is,
   needs an extension you have left room for, or would have to be reworked.

State your reasoning where a choice is not obvious. Where you need a decision from the
engineer or product owner rather than guessing, say so explicitly.

## 10. Out of scope

The JSON API and its error shapes; the CLI; the workflow grammar; how agent jobs are scheduled
or executed; and building anything from §7. This is the presentation of what exists — with
layout and information architecture open for reconsideration, and the planned picture as a
constraint on how far the design can be painted into a corner.
