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

Transition actions carry a verb: `Move to planning ›`, never `→ planning`.

**A navigation target is the whole region, not the identifier inside it.** A job row in the
timeline, a queue item's decision sentence, a ticket on the board: the tappable thing is the row,
at the full 46px, not a 20px `#3` inside it. Hunting for a small link is the failure this rule
exists to prevent, and a row that only *looks* tappable at one end is worse than one that is not
tappable at all.

**A navigation target never contains a control that commits.** This is the constraint the rule
above must not break. Answering never navigates, so a region that navigates may not enclose an
answer row, an approval card or a Send — nesting one inside the other makes "read this" and
"approve this" the same gesture, which is exactly what the queue's shape exists to keep apart.
On a queue item the navigating region is therefore the header and the decision sentence, and it
stops where the answer affordance begins.

## The three axes

Three orthogonal axes must never render as three colours of one badge. They get three different
*forms*, because form survives greyscale, colour blindness and a glance.

| Axis | Form | Rules |
|---|---|---|
| workflow state | plain mono, leading topology glyph, no box | `▸` job state (info) · `●` human state with outgoing transitions (primary) · `■` terminal (muted). Never coloured by status, never abbreviated. |
| ticket status | filled uppercase flag, beside the state | Rendered only when not `active`. `stuck` carries its age (`STUCK 19h`) in accent. Never replaces the state; never a board column. |
| job outcome | bare mono, coloured, at type scale | The **declared** outcome is the largest thing on the job page. The engine outcome is demoted to smaller mono beside it, with a caption naming which is which. |
| worker reachability | a dot and a word, beside the status | Whether the platform is holding a channel to the machine *now*. Orthogonal to `status`, which is what the database last recorded — a `ready` row that is not connected is the interesting case, not a contradiction. |

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
| `/projects/:name` | none | The same board for one project, beside a 21rem rail. Same reason. |
| `/workers` | 74rem | One table of machines. Wide enough for the row, no wider. |
| `/projects/:name/settings` | 48rem | A form and a table of credentials. Narrower loses the row; wider is a rail with nothing to put in it. |
| `/tickets/:project/:number` | 74rem | 53rem timeline column plus a 21rem facts rail, divided by a 1px rule. Below `lg` the rail moves under the timeline. |
| `…/review` | 74rem | Same frame. The diff needs the width; the rail carries the evidence. |
| `…/jobs/:job_id` | 74rem | Same frame. Manifest in the rail, completed harness stream in the column. |
| `/chats` | 34rem | One ordered list, so the queue's measure and for the queue's reason: width only lets a second row compete for the same glance. |
| `/chats/:id` | 74rem | Same frame again: a conversation is work with a branch, a cost and a record. The talking is the column; what it cost and what it wrote is the rail. |
| `/chats/new` | 34rem | The first message is prose and needs the queue's measure, not a form field's — the same reason `/tickets/new` has it. |
| `/projects/new` | 26rem | A short form. Same frame as log-in, for the same reason. |
| `/tickets/new` | 34rem | The body is prose and needs the queue's measure, not a form field's. |
| `/users/log-in`, `/users/settings` | 26rem | Same shell, same type, same buttons. They must not read as a different product. |
| `/accounts` | 48rem | Two lists of addresses with a row of decisions each, so the settings page's measure and for its reason: the row is what has to fit. |
| `/users/pending` | 34rem | A sentence and one button. The queue's measure because it is a single column of prose, and the only route that draws the layout **without its nav** — every link in it leads somewhere this account is redirected away from. |

Navigation is a fixed bottom bar on a phone (56px plus safe-area inset, each item a full-height
tap target, Queue carrying the only badge in the product) and a hairline-ruled top row on a
laptop. **No hamburger at any width.** The phone bar carries Queue and Board; it gains Tickets as
a third item when `/tickets` exists, and not before. **The laptop row carries Workers and Chats as
well, and the phone bar does not** — the phone is where decisions are answered and a machine is
never a decision. Nothing on `/workers` waits on a human, which is also why nothing on it is
accent.

**Accounts is not in either.** It is one link beside the address in the laptop header, shown
only to a node admin, because account governance is not a place work happens and most accounts
never reach it. It needs *a* link all the same: it is the only surface the approval perimeter
has, and without one nobody can discover that somebody is waiting. See
`design/identity.md` § Approval.

**Chats is on the laptop row for a different reason, and it is worth separating them.** A
conversation *does* wait on a human — but when it does it is already in the queue, with its
question and its answer rows, which is where an operator meets it on a phone. `/chats` is for
finding a conversation again: the one you had about the parser last week, the one still running
that you closed the tab on. That is a laptop errand. A conversation that needs you does not wait
for you to go looking.
Ticket, job and artifact are pushed views with a back affordance naming where you came from, not
tabs.

## Motion and structure

Motion is minimal and respects `prefers-reduced-motion`. **Nothing pulses and nothing is
decorative.** No spinner that conveys nothing, no shimmer, no animation that exists to look busy.

**Live output is allowed where a person is waiting for it.** This reverses a rule that said
otherwise — see the note below — so: a conversation streams its reply as it arrives, and a job
may show its stream while it runs. Neither auto-scrolls away from something you are reading; a
view that has been scrolled up stays there and says how much arrived beneath.

**Output that accumulates scrolls inside itself rather than growing the page.** A conversation's
messages and a job's stream are both bounded panes, because a page that grows downwards moves the
box you type in further away with every reply, and puts the thing you are waiting for below the
fold you are already at.

Which end is pinned follows which end is new. A conversation arrives at the bottom, so it is
pinned there while you are there, still when you are not, and it says how many messages are
beneath. A job's stream is newest first and needs no pinning at all: what arrives appears at the
top, where the reader already is, and pinning it to the bottom would scroll away from the newest
entry to reach the oldest.

Where nobody is waiting, nothing streams. The board does not animate, the queue does not
rearrange itself under a thumb, and a finished job's stream is paged, newest first, headed by its
completion state and entry count.

**The stream shows what the job did, not what the harness said about itself.** Claude Code turns
every `system` message into a `notice` event, and `thinking_tokens` alone can outnumber
everything else a job produced: the page becomes a telemetry feed with the work buried in it,
which is the activity feed this section exists to refuse. Those events are recorded — the event
log is the record and nothing may quietly drop what a job did — and hidden behind a control that
says how many there are. Recorded and not drawn is the rule; dropping them would be a different
and worse decision.

**Why this used to be forbidden, and why it is not.** The rule was "no live transcript, no
streaming log, no activity feed — nothing that invites watching agents work", from `vision.md`'s
*"watching agents work is how a review budget disappears"*. That is a true observation about
**unattended** work: a feed of agents grinding through tickets is a machine for spending the
operator's attention on nothing. It was overstated into a prohibition on live output as such,
which also forbids the case where the operator is the one who asked the question and is waiting
for the answer. The distinction is who is waiting, not whether bytes move.

## Semantics that must not be lost

Getting these wrong makes the UI lie. They are acceptance criteria, not preferences.

- Approval attaches to an **exact artifact version**. Never imply "approve whatever is latest";
  the word "latest" appears nowhere in the product. There is no artifact chip without a version.
- **Approval state is shown only where approval is possible.** An artifact no transition in the
  pinned workflow lists in `approve:` is never marked `unapproved`, because nothing will ever
  approve it and a warning the operator cannot act on is a lie about the state of the work. A
  workflow with no approvals at all therefore shows no approval marks anywhere. This is the same
  reasoning that gives presentations no approval slot, applied to the workflow rather than to the
  artifact's kind.
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
(`forge#41 · ▸ planning · plan.md v2`). Separation between items is a top rule, not a card.

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

## Creating things

**Where the two create actions live, and why they are not in the same place.** A project is made
rarely and from nowhere in particular, so it is an action in the laptop top bar, beside the theme
toggle rather than among the nav items — those are destinations and this is not one. A ticket is
always made *for a project*, so it is offered on the project page and nowhere else: the queue is
an inbox and the board is every project at once, and neither has a project to make a ticket for.

Both are laptop-only, because the header is. That is the same reasoning as the workers page: the
phone is where decisions are answered, and creating a project is not a decision waiting on
anyone.

**A ticket form reached from a project does not ask which project.** It says which one, as an
identifier, and the select appears only on the bare `/tickets/new` — a route nothing links to,
kept so the address works and so the no-projects-at-all case still has somewhere to say so.

**A conversation is the same shape, and its bare route *is* linked to.** `/chats/new` reached
from a project or a ticket states which and asks nothing — there is not even a hidden field, the
view holds it. The select appears on the bare route, which the chats page links to: that page is
every conversation in every project you are in, so it is the one surface with no project to carry
and the only place a create affordance has to ask. A conversation is still never started from
nowhere; the asking moved to the one page that does not know.

**A list row that navigates may still carry a control, beside it and never inside it.** The chats
list ends a live conversation from its row, because a live row is a machine running and the
alternative was opening it first. The row is the link and the control is its sibling, which is
The affordance rule above applied rather than excepted. What a list may never offer is deleting a
conversation: they are kept for ever (`conversations.md` § Lifetime), and the affordance that
exists is the one that stops it costing something.

A project and a ticket are made in the product. A **workflow is not**: it is
`.forge/workflow.yml` in the project's own repository, read at the ticket's base commit and
pinned at admission, so it versions with the code it governs and there is nothing for a form to
edit. The two create views are pushed views with a back affordance, reached from the board (a
project, and a ticket in a named project) and from the queue (a ticket).

**A new project cannot take a ticket yet, and the product says so rather than failing.** The
repository it just made has no workflow, so admission would fail on a parse error naming a file
the operator has never seen. Instead:

- Creating a project ends on what to do next, not on a redirect: **a conversation that writes the
  workflow**, offered as the primary action, with the clone URL beneath it for working by hand.
- **It used to say to clone the repository and push a `.forge/workflow.yml`, and at the time that
  was not possible.** `pre-receive` accepted a write to the default branch from the platform's own
  merge and nothing else, and every credential was scoped to one branch which was never that one.
  There was no push that would have been accepted. Work still reaches the default branch that
  way — a branch, read and merged — and bootstrapping a *workflow* is not an exception to it,
  which is why a conversation is the primary action here rather than a special case in the hook.
- **Importing a repository that already exists is the exception**, because there is no branch to
  merge and no conversation that can produce one. That is what the default-branch token above is
  for, and the create view says so beneath the clone URL rather than sending the operator to a
  terminal to find out. See `git-hosting.md` § The default-branch token, and what it costs.
- The ticket form resolves the chosen project's workflow *before* the operator types anything,
  and says plainly when there is none. A form that accepts a title and a body and then rejects
  them for a reason in a third place is the failure being avoided.

Both are checked again on submit — the repository is a shared surface and a check is a moment,
not a guarantee — but the operator is never the one who finds out.

**The clone URL belongs on the project page and on the create view, and nowhere else.** Those are
the two moments an operator needs it: when the repository has just been made, and when they have
come to change the workflow and have found that they cannot do it here. A git URL anywhere else
is an invitation to a surface that is not the product.

## The project page

`/projects/:name` is the overview and the project's own board. It exists because `/board` answers
"what is happening everywhere" and nothing answered "what is this project".

Its board is `/board`'s, uncapped. The four-row cap is there so a column never grows its own
scrollbar and hides its own count; the objection is to a column that scrolls independently, not
to a long one, and with a single project on the page there is room to let the page scroll. Both
boards arrange their columns with the same code, so the two can never drift apart.

**It shows the workflow and never edits it.** A workflow is `.forge/workflow.yml` in the
project's own repository, read at the ticket's base commit and pinned at admission, so it
versions with the code it governs. What the page shows is the *repository's current* workflow —
the one the **next** ticket will pin — which is not necessarily the one the board is arranged by,
because every ticket on that board pinned its own at admission. On a project whose workflow has
just changed those differ, and saying which is which is the point rather than a detail.

**It lists the project's conversations, live ones first.** The board is the workflow and a
conversation is not on it — it has no state to be in — so without this a chat is a thing you can
start from the page and then cannot find from the page. Live first because that is the one that
is costing something and holding a machine; the rest are a record, and are folded away once there
are more than a handful of them.

## Project settings

`/projects/:name/settings` is where a project's credentials are issued and seen, reached from
the project page. It exists because the product sent the operator to a terminal: the project
page hands out a clone URL and says to push a workflow, and `mix forge.git.token` was the only
way to get the credential for either.

**A token is shown once and then only described.** Only the hash is kept, exactly as for the
worker token and the operator's API tokens, so the row afterwards can say what a token may do
and when it was last used but never what it is. The one-time display is the same shape as the
create view's clone URL: the moment it is useful is the moment it is on screen.

The form offers three scopes and no more: read the whole project, write one ticket's branch, or
write the default branch — the last named after the branch itself, because it is the one that
reaches what every job builds on, and a scope worth choosing on purpose.

What a row shows is its *capability*, not its identity: the ref it may write, or that it may only
read; when it expires; when it was last used; and whether a job holds it. A token minted for a
job is listed and never offered for revocation by hand — the engine revokes it when the job ends,
and a human revoking one mid-run would fail that job for a reason nothing records.

Expired and revoked rows stay, behind the same disclosure the workers page uses for destroyed
machines. They are the audit trail: what was issued, to what scope, and whether it was ever used.

## The workers page

`/workers` lists the machines, and it exists for one reason the CLI cannot serve: **whether a
worker is connected lives in a registry inside the running platform.** `mix forge.worker.list` is
a different node and so has no column for it — a LiveView runs inside the platform and does.

Two facts that look like one and are not:

- `status` is what the database last recorded: `creating`, `ready`, `busy`, `idle`, `destroyed`.
- **connected** is whether a channel is held right now, read from the registry.

A row that is `ready` and not connected is the state that cost this project a day — a machine
that looks healthy on every surface and cannot take work. The page puts the two side by side so
that reads as what it is.

`managed` is shown because it is the only thing that differs between a machine the platform may
destroy and one it may not, and an unmanaged row sits against `max_workers` until somebody
retires it. Destroyed rows are hidden unless asked for: they are history, and the page is about
what exists.

Nothing here is accent and nothing here is a decision. It is the one operator surface that is
purely a readout.

**`docs/design/provisioning.md` makes the page's own summary line false, and that is the part to
design rather than patch.** It reads *"A job is scheduled against memory, not against a count: one
slice is 2.2 GiB, and a machine takes as many as its budget holds"*, which is exactly right while
every job and every machine is the same. With resources declared per job, cores on the gate and
several machine shapes, there is no equally short true sentence, and `slices/1` — a budget divided
by one constant — has nothing to divide by. Two consequences for this page:

- A row's capacity becomes two bars, memory and cores, each showing promised against offered.
  What a machine *is* stops being derivable from one number, so it has to be shown.
- The page stops being purely a readout. A permanent worker's `accepts`, memory and cores are
  operator-set and editable here (`provisioning.md` § What a worker offers, and who says so),
  which is the first
  decision this surface has ever carried. § The affordance rule governs it: an editable field on
  the one page that has never had one must look editable.

**And it gains a sibling.** Worker templates are a second list — the recipes machines are created
from — and they carry `max_workers` and a price per hour, which makes them the first operator
surface where a number is money that keeps accruing. § Creating things governs the form; the
ceiling and the price belong on the same page, because raising one raises the other.

## Documents

An agent's document is rendered, not shown as source. Source is one click away — every artifact
name is a link to its exact version (below) — and the roadmap's margin-questions view needs
structure, which source text cannot carry.

Rendered document bodies are the one place the product styles Markdown, and they do it from a
scoped block in `app.css` rather than from `@tailwindcss/typography`. The plugin brings its own
type scale, and this note already has one; overriding it costs more than writing thirty lines.
The rules: headings step down from the Identifier size and never reach the page title, lists keep
their markers, and the body is the sans face — a document is language, not an identifier.

**A document body never widens its column.** Whatever an agent wrote — a 300-character URL, a
wide table, an unwrapped fenced block — is contained: `min-w-0` on the column so a flex child
cannot push past it, `overflow-wrap` on prose, and `overflow-x: auto` on the block elements that
legitimately cannot wrap (`pre`, `table`). Content that overflows scrolls inside its own box. It
never reaches the facts rail, which is the failure this rule was written for.

The body sits on `base-200` inside a `--radius-box` block. This is the second sanctioned use of
that surface — see Colour — and it is sanctioned because a document is the one thing on the page
that is not the product's own writing, and the ground is what says so.

## Addressable artifact versions

`…/artifacts/:name/:version` serves the exact bytes of one version, to an authenticated operator.
It is what every artifact name in the product links to: chips on the ticket, the produced list on
a job, transcripts, the review page's documents and answers, the queue item's footer.

**There is no versionless form.** `…/artifacts/:name` would have to mean "latest", and the word
appears nowhere in this product for the same reason approval attaches to a version and not to a
name.

- A **document** serves its stored text as `text/plain`, front matter included. The rendered view
  is on the ticket; this route is the source behind it.
- A **blob** is fetched from the store by its key and served as `text/plain` when it is text.
- A **changeset** is not a file. `git:<sha>` names a commit, so the changeset links to `…/review`,
  which is the rendering of a diff. Nothing tries to serve it as bytes.

Serving raw bytes is what the route does *today*, not what the path means. When the
margin-questions view lands it takes this route's HTML representation and raw moves behind a
parameter; the address of a version does not change.

## Not built yet

Named so their absence is a decision rather than an oversight. Each is specified in the handoff:

- The answering sequence — one ordered full-screen pass over every decision in the queue.
- Message state (queued, retrying, failed, confirmed) and the client outbox with an idempotency
  key per answer. Until it lands, a send is confirmed by the flash the framework already shows.
- Document-with-margin-questions at laptop width.
- The `/tickets` finder. Until it exists the phone bar carries two items, not three.
