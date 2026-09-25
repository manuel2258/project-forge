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
`platform/priv/static/fonts/` as subsetted woff2 with `font-display: swap`; there is no webfont CDN
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
| `/templates` | 60rem | Two lists with a form each — provider credentials, then templates. Not one wide table, so narrower than `/workers`; a template row carries its shape, figures, count and actions, and wraps where they do not fit. |
| `/projects/:name/settings` | 48rem | Forms and tables — tokens, people, mirrors. Narrower loses the row; wider is a rail with nothing to put in it. |
| `/tickets/:project/:number` | 74rem | 53rem timeline column plus a 21rem facts rail, divided by a 1px rule. Below `lg` the rail moves under the timeline. |
| `…/review` | 74rem | Same frame. The diff needs the width; the rail carries the evidence. |
| `…/jobs/:job_id` | 74rem | Same frame. Manifest in the rail, the recorded harness stream in the column — not live (§ Motion and structure). |
| `/chats` | 34rem | One ordered list, so the queue's measure and for the queue's reason: width only lets a second row compete for the same glance. |
| `/chats/:id` | 74rem | Same frame again: a conversation is work with a branch, a cost and a record. The talking is the column; what it cost and what it wrote is the rail. |
| `/chats/new` | 34rem | The first message is prose and needs the queue's measure, not a form field's — the same reason `/tickets/new` has it. |
| `/projects/new` | 26rem | A short form. Same frame as log-in, for the same reason. |
| `/tickets/new` | 34rem | The body is prose and needs the queue's measure, not a form field's. |
| `/users/log-in`, `/users/settings` | 26rem | Same shell, same type, same buttons. They must not read as a different product. **Not built as specified:** both are still the generator's pages under the layout's default 34rem, and log-in narrows its own form to `max-w-sm` (24rem) inside it. |
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
view that has been scrolled up stays there and says how much arrived beneath. **Only the
conversation does so today.** The job page draws what was recorded and re-reads it when its
ticket changes; it does not subscribe to a running job's events, so a live job stream is not
built.

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
  are pushed to the phone; non-blocking ones sit in a digest under *Not waiting on you*, and are
  counted in the daily digest push apart from what is waiting (§ Not waiting on you).
- **`stuck` is a flag, not a state.** A stuck ticket is still in its workflow state, and stuck is
  drawn on the step rather than as a step.
- **Free text is always a valid answer**, alongside any options — a real field with its own Send,
  never an escape hatch behind a link.
- The queue is **one ordered list**, oldest first. No tabs and no filters that can hide an item;
  the operator must be able to reach the end and know they are done. Its decisions come first,
  oldest first; the digest of non-blocking questions follows the last of them, oldest first
  itself; the end of the queue follows that. The digest is below the decisions rather than
  sorted in among them because none of it is waiting on anyone, and an age beside a held job
  would compete with it for the same glance. It is on the same page and behind no control, so
  nothing is hidden and the end is still the end.
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

### Not waiting on you

A non-blocking question is an assumption an agent stated and carried on from, so it is not a
decision and does not get a decision's shape. `Forge.Queue` serves it as its own kind,
`:assumption`, so that no reader — the page, the JSON API, the CLI, the digest push — can count it
as a blocking question by accident; the page draws it in the digest between the last decision
and the end of the queue:

- **Prose, not cards.** A micro-label heading, one sentence saying how many assumptions were
  stated and that work continued, then one line each: the question, what was assumed, and the
  ticket and age as identifiers. No mark, no answer rows, no accent — nothing in it is waiting on
  a human.
- **Each line navigates to its ticket**, where the question is answered. Answering never
  navigates and a navigation target never encloses a control that commits (§ The affordance
  rule), so the digest offers no answer of its own rather than a second place to give one.
- **It counts towards nothing.** Not the header's `N decisions · N items`, not the nav badge: a
  number that answering nothing ever lowers is not a count of what is waiting.
- **Answering one changes no job's flow.** Its answer joins `answers.md` for whichever job runs
  next on the ticket; a waiting job resumes only once no *blocking* question is open, and a
  non-blocking answer closes none (`job-prompt.md` § Non-blocking questions).

## Creating things

**Where the two create actions live, and why they are not in the same place.** A project is made
rarely and from nowhere in particular, so it is an action in the laptop top bar, beside the theme
toggle rather than among the nav items — those are destinations and this is not one. A ticket is
always made *for a project*, so it is offered on the project page — and on the create view that
has just made one — and nowhere else: the queue is an inbox and the board is every project at
once, and neither has a project to make a ticket for.

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
exists is the one that stops it costing something. Ending one does delete its *branch*, unless
the branch would not merge cleanly, so its confirm says so — the same sentence on the list and on
the conversation's page, from one definition, so neither can understate it.

A project and a ticket are made in the product. A **workflow is not**: it is
`.forge/workflow.yml` in the project's own repository, read at the ticket's base commit and
pinned at admission, so it versions with the code it governs and there is nothing for a form to
edit. The two create views are pushed views with a back affordance. A project's is reached from
the laptop top bar, and from the board and the ticket form only when there are no projects at
all; a ticket's from the project page, and from the project's create view once it exists. The
queue links to neither.

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

**The clone URL belongs on the project page, on the create view and on project settings, and
nowhere else.** Those are the moments an operator needs it: when the repository has just been
made, when they have come to change the workflow and have found that they cannot do it here, and
when they are minting the credential to use it with — settings names the URL a token is for, and
shows it once with the token in it. A git URL anywhere else is an invitation to a surface that is
not the product.

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

**The page has outgrown credentials.** Beside the tokens it carries the project's people — added
by the address of an approved account, as `member` or `admin`, and removed; an address with no
account and one whose account is still pending get the same answer, *No approved account for
that address*, and a suspended account is named as suspended — its
default model, its default branch as a fact, and its mirrors: a table of what each last push
said, and the only place a mirror is set or removed (`git-hosting.md` § What the mirrors say about
themselves). Tokens, people, mirrors and the model are drawn only for a project admin; the
branch is drawn for every member. Saving the model is refused without the admin capability —
`Operator.set_model/3` is the guard, not the form — and the form is not offered to anyone the
guard would refuse.

## Account settings

`/users/settings` carries the caller's **inference credentials** below the email and the
password, because they are the caller's in the same sense: nobody else sees them, a node admin
included, and the page is already behind sudo mode, which is right for the one place a token is
typed (`design/credentials.md`).

**A token is typed once and never shown again, not even back into its own field.** The form is
re-rendered on every change, and a password input's value is rendered like any other, so the
field is written out rather than `<.input>` and is never given a value by the server. It is
`phx-update="ignore"` so that re-rendering does not wipe what was typed, and it is replaced by an
empty one when an add succeeds.

A row is an identifier line — name, harness and kind, what the last check found, what it has
spent today with the daily limit beside it if one was set — then a line per window the provider
has reported, five-hour and weekly: its utilization when one was given, its reset, and
*rate-limited* in warning colour while it blocks. Then two controls, **Check again** and
**Revoke**. The limit says *not
enforced* in the row itself, because it is not, and a figure next to a limit reads as a cap.

**Spend is in dollars here**, an exception to `capacity.md`'s recommendation that dollars leave
the operator's surfaces, and recorded there as one. A credential is its owner's money, an API key
is billed in dollars and has no window to count in, and the limit beside the figure was typed in
dollars. The figures are as of the page's last action, not live. Beneath it, **Funds**: the
projects whose pool it is in, each with an `×`, and a select of the viewer's own projects to add
one — the same shape as a template's projects on `/templates`, because it is the same decision
about whose money reaches which project. Rows are separated by a rule,
not boxed, because the row itself does nothing when tapped. Revoked rows stay, dimmed and without
controls: what was spent through them is still attributed to them.

## The capacity gauge in the top bar

The laptop header carries a small gauge for the five-hour and the weekly window, first in the
header's right-hand group: per window — `5h`, `week` — ten ticks of mean utilization and a mono
countdown to the soonest reset, each only when there is something truthful to draw
(`design/capacity.md` § Two objects). Neutral, never accent, because it is resolved by time. Its
title says what it averages — *5h window: 95% used on average, 2 of 2 credentials reporting,
soonest reset Fri 14:00 UTC* — and whose they are is the page's: a project's pool on a page about
that project (the project, its settings, a ticket, its review, a job, a conversation), the
viewer's own everywhere else (`design/credentials.md` § Showing the windows). A set in which
nothing has reported a window draws nothing at all, rather than an empty gauge. It is redrawn
every minute while the page is open, since the countdown is to a moment. Laptop only, like the
header: it is not a decision.

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

**It lists the viewer's own machines and nobody else's.** A machine has an owner, and a row says
which projects it serves — a permanent machine's own assignments, with a control to add one and
an `×` on each, or for a machine the platform made, the template it serves through and that
template's projects. A project a person is not in is not one they may learn exists, so another
person's row is not drawn at all. A permanent machine that serves nothing says, in error colour,
that it takes no work: it is the machine-shaped version of the row that is `ready` and not
connected (`design/identity.md` § Workers). So does a machine whose release predates a job
carrying its credential — it is given no agent job, and the row says to update it
(`design/credentials.md` § What a worker offers now). The harness column no longer counts models:
a machine holds no account, and the models are a credential's.

`managed` is shown because it is the only thing that differs between a machine the platform may
destroy and one it may not; the second reads `permanent`, and its row stays until somebody
retires it (`mix forge.worker.retire`). It holds no `max_workers` slot: that ceiling is a
template's and counts the machines made from it, and a permanent worker came from no template.
Destroyed rows are hidden unless asked for: they are history, and the page is about what exists.

Nothing here is accent. It is a readout with two decisions in it, both on a permanent row only: what
the machine offers (below), and which projects it serves.

**`docs/design/provisioning.md` made the page's old summary line false, and it was redesigned
rather than patched.** It read *"A job is scheduled against memory, not against a count: one
slice is 2.2 GiB, and a machine takes as many as its budget holds"*, which was exactly right while
every job and every machine was the same. With resources declared per job, cores on the gate and
several machine shapes there is no equally short true sentence, and `slices/1` — a budget divided
by one constant — had nothing to divide by and is gone. What the page does now:

- The header counts machines (`N live · N connected`), and the summary says a job is scheduled
  against what it asked for in memory and cores and against the kinds a machine takes, and what a
  job that declares nothing is given.
- A row's capacity is two figures, memory and cores, each as free against offered, with the kinds
  it takes beneath. What a machine *is* stops being derivable from one number, so it has to be
  shown. The design was two bars; what was built is two lines of text. A machine that never
  reported cores says so rather than showing an invented figure, and one whose own report
  disagrees with its row shows the report in `error`: the row governs, so a machine reporting
  less than its row is one the platform will overcommit.
- A row whose create failed carries the driver's reason. Until it was drawn, a refusing driver
  was invisible on every surface the operator has.
- The page stopped being purely a readout. A permanent worker's `accepts`, memory and cores are
operator-set and editable here (`provisioning.md` § What a worker offers, and who says so), which
was the first decision this surface carried; the projects a permanent row serves, added and removed
on the row, are the second. § The affordance rule governs it: an editable field on the one page that
has never had one must look editable, so it is a form behind a *Set what it offers* link rather than
a hover. A managed row offers none — it is replaced, not corrected.

**And it has a sibling.** `/templates` lists the recipes machines are created from and the
provider credentials they spend — one person's own, never anybody else's. A template carries
`max_workers`, and its size is chosen from the provider's catalogue with the price per hour where
the driver reports one, which makes it the first operator surface where a number is money that
keeps accruing. § Creating things governs the form; the ceiling and the price are in the same
form, because raising one raises the other. The two pages link to each other and share the
Workers nav item.

## A job waiting for a machine

A pending job the scheduler could not place says why, in one sentence, where the job is looked at:
under its row on the ticket's timeline, and on a pending conversation's page where the reply will
appear. The sentence is the scheduler's (`provisioning.md` § The gate), in the product's voice —
*Waiting for room: …*, *Waiting for a template: …* — and it is language, so it is sans at body size,
never mono. **A sentence that sends the operator somewhere sends them where the reason is.** A
provider that refused to make a machine left its words on the worker row, so that sentence names the
workers page; a template the platform would not spend from — its provider credential is another
user's, or another provider's — made no worker row, and its words are on the template, so that one
names the templates page. Both pages show the viewer's own rows only, so each sentence names whose
page: the template owner's, who may not be the person reading it. It is drawn only while the job is
pending, and only the latest reason since the job last started; every change stays in the job's own
event stream, where it is a line like any other.

**It is not accent**, even when the answer is a template nobody has assigned. Accent is the
queue's mark, and a waiting job is not in the queue: a ticket that no template could ever hold
is stuck, and gets its accent that way. A conversation in the same position waits on a person
and is drawn quietly all the same — the gap `provisioning.md` § The gate records, not a rule.

## Documents

An agent's document is rendered, not shown as source. Source is one click away — every ticket
artifact's name is a link to its exact version (below) — and the roadmap's margin-questions view
needs structure, which source text cannot carry.

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
a job, transcripts, the review page's documents and answers, the queue item's footer, a
conversation's rail.

**An artifact has the address of its scope.** A ticket's is under the ticket,
`/tickets/:project/:number/artifacts/:name/:version`. One scoped to a conversation
(`artifacts.job_id`) — a project chat's documents, and every conversation's proposals — is under
the conversation, `/chats/:id/artifacts/:name/:version`, and served to whoever may open that
conversation: a member of its project, the same guard as `/chats/:id`. `ArtifactController`
resolves the name within the one scope the address names and nowhere else, so a version of the
same name in another scope is not reachable through it. A ticket chat's documents are the
ticket's, so they are under the ticket. The conversation's rail lists every version it wrote, the
row the link, as a job page's produced list does. This was a gap until chats wrote documents: the
rail listed names, unlinked and unversioned.

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
