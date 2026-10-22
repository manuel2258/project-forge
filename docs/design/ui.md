# Operator UI

Scope: the standing rules for every operator surface. This note is the standard — code follows
it, and a change of mind updates it first. It supersedes the UI guidance that `platform/AGENTS.md`
used to carry.

The governing idea, from `vision.md`: the operator's attention is the scarce resource, and the
queue is an inbox rather than a dashboard. Exactly one thing in the interface is allowed to be
loud — an item waiting on a human — and it is marked in accent, which is used for nothing else.
Everything else is ruled, monochrome and quiet.

**A phone can do everything a laptop can.** The layout changes with the width; what an operator
can reach and do does not. This reverses an earlier reading — *the phone is where decisions are
answered*, and so Workers, Chats, the create actions, settings and the capacity gauge were laptop
only — which held while the phone was an inbox and stopped holding once it became the client an
operator develops from when away from the laptop. Where a rule below still says *laptop*, it is
about arrangement, never about reach. See § The phone and § The work screen.

Source material for this note is the redesign handoff vendored under `docs/design/ui/`:
`forge Spec.html` is the specification and `forge Mockups.html` is the evidence. Where this note
and those files differ, this note wins — it is the one that tracks what was built.

## The affordance rule

**A border means you can tap it.** This governs every component.

- **Identifier** — states, statuses, outcomes, branches, commits, artifact names and versions:
  plain mono text, no border, no padding, no background.
- **Answer row** — 52px tall, 1px border, `base-200` ground, `--radius-field`, label left, `›`
  right, sends on tap. The only shape in the queue that commits something on a single tap:
  transitions, run again, and nothing inside a question form.
- **Option card** — a question's option: 1px border, `--radius-field`, a radio mark, the label in
  medium weight and its detail beneath. It **locks an answer in and sends nothing**; a primary
  border and a filled mark show the one chosen — primary, not accent, because accent is spent on
  what waits and a choice is a decision (§ Colour). It is not an answer row and does not wear the
  `›`, because the row's promise is that a tap commits.
- **Filled button** — `base-content` fill, and only ever "commit what I prepared": the Send beside
  a free-text field, and the Send that closes a question form.
- **Enter never commits a decision.** The free text beside one — a question form's own words, the
  comment beside Approve or Accept — is a box Enter breaks a line in, and only the button sends. A
  one-line input submits its form on Enter with the form's first button, which on an approval is
  Approve: a comment ended with Enter approved the version, and an answer ended with Enter sent the
  form before the questions after it were read; a radio may submit on Enter too, in some browsers,
  so a question form swallows Enter from its inputs. The composer is the one box Enter sends from,
  on a fine pointer (§ Talk), because there the box is the whole form. The create forms still
  submit on Enter — a ticket's title, a conversation's limits, and a new conversation's first
  message, which is the composer's box on a form that also holds its project, model and limits;
  this rule is written for decisions, and has not been carried to them.
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
| workflow state | plain mono, leading topology glyph, no box | `▸` job or command state (info) · `●` human state with outgoing transitions (primary) · `■` terminal (muted). Never coloured by status, never abbreviated. |
| ticket status | filled uppercase flag, beside the state | Rendered only when not `active`. `stuck` carries its age (`STUCK 19h`) in accent. Never replaces the state; never a board column. |
| job outcome | bare mono, coloured, at type scale | The **declared** outcome is the largest thing on the job page. The engine outcome is demoted to smaller mono beside it, with a caption naming which is which. |
| worker reachability | a dot and a word, beside the status | Whether the platform is holding a channel to the machine *now*. Orthogonal to `status`, which is what the database last recorded — a `ready` row that is not connected is the interesting case, not a contradiction. |

**`budget_exhausted` is followed by what ran out**: `· turns`, `· cost` or `· wall clock`,
beside the outcome and nowhere else, because the three want different responses from whoever
reads the row (`capacity.md` § Four exhaustions, three treatments). Not a second badge — two
marks of equal weight read as two outcomes — so it is mono at a lower opacity than any outcome
is drawn at, which also means **every row that draws a ceiling draws its outcome through
`outcome/1`**: on a row that wrote the outcome out as plain demoted text the two came out
level. Nothing at all for a job whose ceiling was not recorded. The same section says why a
job's turns are no longer drawn against its turn budget.

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
| Page title | `text-[23px] sm:text-3xl -tracking-[.03em] font-semibold` | A ticket's title on its review page |
| Work-screen title | `text-xl sm:text-2xl -tracking-[.03em] font-semibold`, truncated | A ticket's title on its work screen, whose header gives way first when the frame is short (§ The work screen) |
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
- **Primary** — links, human states, decisions that advance state or spend capacity, and the
  option chosen in a question form.
- **Info** — the job-state glyph and harness tool calls. Nothing else.
- **Success** — approval and the end of the queue. **Error** — engine errors, declared failures,
  failed sends. **Warning** — non-completion outcomes (§ The three axes), and a job whose memory
  was the trouble: its header line and its `memory` rows (`capacity.md` § Memory, which a job holds
  rather than spends). Neither is waiting on a person, so neither is accent.
- **File type** — the tile an artifact's icon sits in, and nothing else (§ Artifact types). Its
  hues are its own and kept at least 25° from every hue above, so that a type never reads as a
  state, an outcome or a wait: 210 Markdown, 175 code and data, 340 an image, 95 an archive,
  125 an Android app. None is more saturated than the accent (chroma 0.12 at most, against its
  0.13), so a tile is never the loudest thing on a page. Text, a log, the changeset and any other
  file are neutral, told apart by their icon.
- **Two surfaces per theme at most**: `base-100` for pages, `base-200` for the one row in a
  changed state. Structure is rules, not cards: `border-base-300` for section rules,
  `border-base-300/60` for rows within a section.

## Space, measure and targets

Base unit 4px. Page gutter `px-5` phone, `px-6`–`px-[30px]` laptop. Queue item `py-[15px]`
collapsed and `py-[18px]` expanded, internal stack `gap-[11px]`. Timeline step `pb-[26px]` laptop,
`pb-5` phone. Separation is a 1px rule, never a shadow — `--depth: 0`, no card shadows anywhere.

Radii: `--radius-selector: 0.3125rem`, `--radius-field: 0.375rem`, `--radius-box: 0.5rem`,
`--border: 1px`, `--noise: 0`.

Every tap target is at least 46px tall, answer rows are 52px and option cards at least 52px.
**`btn-sm` does not appear on any operator page.** There is no global page padding and no global
measure; each route sets its own:

| Route | Measure | Why |
|---|---|---|
| `/` | 34rem at every viewport | One ordered list. Width only lets a second item compete for the same glance. |
| `/board` | none | Full viewport. The columns are the workflow topology; capping them destroys the artefact. |
| `/projects/:name` | none | The same board for one project, beside a 21rem rail. Same reason. |
| `/projects` | 60rem | One row per project: its name, then what it has to run on. A list, not a board — the boards are a tap away on each row. |
| `/workers` | 74rem | One block per machine, ruled, not a table: a header line, three meters and two columns that stack on a phone. Wide enough for the two columns, no wider. |
| `/workers/:id` | 74rem | One machine: its header line and its log, newest first. The workers page's measure, because it is that page's row, looked at alone. |
| `/templates` | 60rem | Two lists with a form each — provider credentials, then templates. Not one wide table, so narrower than `/workers`; a template row carries its shape, figures, count and actions, and wraps where they do not fit. |
| `/projects/:name/settings` | 48rem | Forms and tables — tokens, people, mirrors. Narrower loses the row; wider is a rail with nothing to put in it. |
| `/projects/:name/repo` | 74rem | The repository the project holds: a branch picker, then either its commit list or its file tree, a file's content opened in place. The same reasoning as `…/review` — content needs the width, and there is no rail with anything to put in it, so no second column. |
| `/projects/:name/repo/commits/:sha` | 74rem | One commit, drawn by the same diff component the review page draws. Its page's measure, for its reason. |
| `/tickets/:project/:number` | 74rem | A work screen (§ The work screen): 53rem tabbed column plus a 21rem facts rail, divided by a 1px rule. Below `lg` the rail is the details sheet, opened from the context strip. |
| `…/review` | 74rem | Not a work screen: a page that scrolls, its column beside a 21rem rail at `lg` and above it below. The diff needs the width; the rail carries the evidence. |
| `…/jobs/:job_id` | 96rem | Laid out as the review page is, wider: its column is the harness stream, whose lines are an agent's paragraphs and commands, and at 74rem the column beside the 21rem rail left them a ribbon. A command's page is the same route and takes the same width, its script in the column. Manifest in the rail, the harness stream in the column — a bounded pane, since no tab body bounds it here — tailed while the job runs (§ Motion and structure). Under the outcome, and only when memory was the trouble, the `warning` line `capacity.md` § Memory describes. A job whose runs held project secrets has a *secrets* row in the manifest, a line per run — *`STRIPE_TEST_KEY` v2, `SENTRY_TOKEN` v1* — by name and version, never a value. |
| `/chats` | 34rem | One ordered list, so the queue's measure and for the queue's reason: width only lets a second row compete for the same glance. |
| `/chats/:id` | 74rem | The same work screen: a conversation is work with a branch, a cost and a record. The tabs are the column; what it cost and its facts are the rail, or the details sheet below `lg`. |
| `/chats/new` | 34rem | The first message is prose and needs the queue's measure, not a form field's — the same reason `/tickets/new` has it. |
| `/projects/new` | 26rem | A short form. Same frame as log-in, for the same reason. |
| `/tickets/new` | 34rem | The body is prose and needs the queue's measure, not a form field's. |
| `/users/log-in`, `/users/settings` | 26rem | Same shell, same type, same buttons. They must not read as a different product. **Not built as specified:** both are still the generator's pages under the layout's default 34rem, and log-in narrows its own form to `max-w-sm` (24rem) inside it. |
| `/accounts` | 48rem | Two lists of addresses with a row of decisions each, so the settings page's measure and for its reason: the row is what has to fit. |
| `/users/pending` | 34rem | A sentence and one button. The queue's measure because it is a single column of prose, and the only route that draws the layout **without its nav** — every link in it leads somewhere this account is redirected away from. |

Navigation is a hairline-ruled top row on a laptop and a fixed bottom bar on a phone (56px plus
safe-area inset, each item a full-height tap target, Queue carrying the only badge in the product).
The laptop row carries Queue, Board, Projects, Workers and Chats; the phone bar carries Queue,
Board, Chats and **More**, and everything else the laptop header holds is in the sheet More opens (§
The phone). Tickets joins both when `/tickets` exists, and not before. Nothing on `/workers` waits
on a human, which is why nothing on it is accent.

**The platform's version is beside the wordmark**, in muted mono — `forge 0.7.0` — on a laptop, and
the last line of the More sheet on a phone, for a signed-in account only: the log-in page tells
nobody which release is running. It is the application's own version, which every
`mix.exs` reads from `VERSION`, so it is the release the node is actually running: the first
thing to say when reporting something, and the way to see that a deploy took. Not a link and not
in the nav, because nothing is done with it but read it.

**Accounts is not a nav item.** It is one link beside the address in the laptop header and one
row in the phone's sheet, shown only to a node admin, because account governance is not a place
work happens and most accounts never reach it. It needs *a* link all the same: it is the only
surface the approval perimeter has, and without one nobody can discover that somebody is
waiting. See `design/identity.md` § Approval.

**Chats is a destination on both.** A conversation that waits on a human is already in the
queue with its question form; `/chats` is for finding one again — the one about the parser last
week, the one still running whose tab was closed. That used to be called a laptop errand. It is
not: on a phone it is how you get back to the work you were doing.

Ticket, job and artifact are pushed views with a back affordance naming where you came from, not
tabs in the nav. (The work screen has tabs *inside* it — § The work screen — which is a different
thing: they are views of one piece of work, not places.)

## Motion and structure

Motion is minimal and respects `prefers-reduced-motion`. **Nothing pulses and nothing is
decorative.** No spinner that conveys nothing, no shimmer, no animation that exists to look busy.

**Live output is allowed where a person is looking at the work.** This reverses a rule that said
otherwise — see the note below — so: a conversation streams its reply and its tool calls as they
arrive, and a ticket's running job streams its activity to the ticket's work screen and to its
job page (§ The work screen). None of them auto-scrolls away from something you are reading; a
view that has been scrolled up stays there and says how much arrived beneath. Nor does a patch
close what the reader opened: a long line expanded, an edit's diff, a folded run, the plan — each
`<details>` keeps its `open` while what is around it streams (`ForgeWeb.Actions.keep_open/0`), and
a stream's rows are keyed by their event, so the row opened is still that event's when a newer one
is drawn above it.

**Output that accumulates scrolls inside itself rather than growing the page.** A conversation's
messages and a job's stream are both bounded panes, because a page that grows downwards moves the
box you type in further away with every reply, and puts the thing you are waiting for below the
fold you are already at.

Which end is pinned follows which end is new. A conversation arrives at the bottom, so it is
pinned there while you are there, still when you are not, and it says how many messages are
beneath. A job's stream is newest first and needs no pinning at all: what arrives appears at the
top, where the reader already is, and pinning it to the bottom would scroll away from the newest
entry to reach the oldest.

Where nobody is looking at the work, nothing streams. The board does not animate, the queue does
not rearrange itself under a thumb, and a finished job's stream is paged, newest first, headed by
its completion state and entry count. Live is a property of a page about *one* piece of work that
the operator opened, never of a list of many.

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

**It was then narrowed a second time, to "who is looking".** The first reversal still kept a
workflow job's stream recorded-only, on the grounds that a workflow job runs unattended. That is
true of the job and not of the operator who has opened its ticket: someone reading a ticket
whose job is running is deciding whether to wait, answer, or steer, and a stream that only
refreshes on reload makes them guess. What `vision.md` warns against is a surface that *invites*
watching — a feed of many agents, or one that pulls you in. A ticket nobody opens streams to
nobody, and no list, board or queue ever streams, so the budget the rule protected is still
protected.

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
- **Free text is always a valid answer**, alongside any options — a real field in every question,
  never an escape hatch behind a link. Beside a chosen option it is a note on it; alone it is the
  answer.
- The queue is **one ordered list**, oldest first. No tabs and no filters that can hide an item;
  the operator must be able to reach the end and know they are done. Its decisions come first,
  oldest first; the digest of non-blocking questions follows the last of them, oldest first
  itself; the end of the queue follows that. The digest is below the decisions rather than
  sorted in among them because none of it is waiting on anyone, and an age beside a held job
  would compete with it for the same glance. It is on the same page and behind no control, so
  nothing is hidden and the end is still the end.
- A **human state with outgoing transitions** waits for a person; one without is terminal and
  never enters the queue. The topology glyph is the only thing distinguishing them.
- **Answering never navigates.** Tapping an option or pressing Send does not move you, open a page,
  or reorder the list; the item changes in place.
- **Presentations carry no approval slot at all**, so they cannot be misread as approvable.
  Experimental results are advisory and must never read as verified.
- **The diff is bounded and says where.** Past the page's limit it offers the `git diff` command
  for the exact range instead of trailing off. **So does a patch that is not valid UTF-8** — a
  latin-1 source file is diffed in full by git, and those bytes in a rendered page are a response
  body that is not UTF-8 and, through the socket, a serializer that raises in the transport
  process and takes every LiveView on the connection down. One rule, two reasons, and the same
  `git diff` line either way; it holds wherever a change is drawn, which is the review page, both
  Changes tabs and a repository commit. A *path* that is not UTF-8 is a different answer — it is
  made printable rather than withheld, because a change whose file list is missing is not a map
  (`Forge.Git.printable_path/1`). The file table above the patch is never truncated: it is the
  map of the change. Dollars do not appear here either — the review page is the surface where
  they are most tempting and least useful.
- A **merge decision** is reached from the queue by a link, never by an answer row. Answering
  never navigates, and the answer row and the Send are the shapes in the queue that commit
  something; a link that looked like one would make "read this" and "approve this" the same
  gesture.

## A reconnect is not a reload

A socket that drops while the page sits idle is not something the operator did, and it must not
cost them what a reload deliberately costs. Three cases start a form over and are meant to —
reloading, navigating away, opening the item on another device. A fourth, a dropped socket
rejoining the same page, is in none of them: nothing on the page says it happened beyond the
framework's reconnect banner, so anything taken then is taken silently.

**Every box a person types into sits in a form with an `id` and a `phx-change`.** That is not a
style rule, it is the whole mechanism. On a rejoin the client copies each such form out of the
live DOM and re-pushes its change event with what was typed, before the new mount's render is
applied; a form missing either attribute is not copied, is not replayed, and is drawn empty by
that render. So the page's handler for the change holds what arrives, and the box is drawn from
what it holds — see `ForgeWeb.Operator.Drafts` for the cards and
`ForgeWeb.Operator.QuestionForm` for the question form. Two modules, deliberately: a question
form holds a structured set of answers it has to validate and send, a card holds the fields of
one form as they came off the wire, and folding the first into the second would lose the
structure for the sake of one fewer module.

What this does not reach is a reconnect the framework answers with a hard page refresh, which it
does when a push times out: there is no DOM left to copy from. That is a reload, and the three
deliberate cases' rule applies.

**Where the rule holds today.** On the conversation's composer and the question form docked
under it, a document's question form, an approval's comment, a proposal's comment and its type,
a human state's document, and the two screens that start something — a new ticket and a new
conversation, which is where the person who reported this said they lost work.

`ForgeWeb.ReconnectTest` holds the rule two ways: it walks those pages and fails on a box drawn
outside a form carrying both attributes, and it inventories every form in the web layer that
holds a box — including the boxes components draw rather than the form itself — so a new one
that cannot be replayed fails until somebody records why, the way
`authorization_inventory_test.exs` does for events. What neither reaches is a box drawn in no
form at all; no page draws one today, and only the walks would catch it if one appeared.

It does **not** hold yet on seven forms, which that inventory is where to read: a project's
members, its secrets, its mirrors and its default model, a worker's resources, and the two
log-in forms. Each carries no `phx-change`, so each loses what was typed on a rejoin. That is a
gap the inventory records rather than one the rule excuses — and two of them are why a person
settles it and not the next agent: a secret's value or a password coming back means holding it
in page state, which is a decision of its own (`docs/design/secrets.md`).

**A draft the document moved under is refused once, then saved on purpose.** The box keeps what
was typed even across a reload, so a Save from it could land on top of a version somebody else
wrote while it sat there — v5 from text written against v3, with v4's work gone from what the
workflow reads. The editor sends the version its draft was written against, and the first Save
after a newer version arrives is refused whole: the flash says which version it is now and that
the text is still in the box. **Saving again writes it.** The refusal is the warning, and
repeating the gesture is the decision to write over what arrived — a refusal with no way
forward would leave the operator told their text was safe and holding no gesture that could
send it, which is the same dead end as losing it. Nothing goes silently either way: the other
version is in the document and named in the refusal, and the typed text never leaves the box.

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

**A stuck item says why.** Its sentence is `<title> is stuck: <reason>.`, the reason from the
ticket's latest `ticket.stuck` — a failed job, a `max` that ran out, an outcome no edge matches,
a rejected approval. The push carries it after the title, and the ticket's Decide says it in place
of *Stuck, and waiting for you to choose*. The first ticket stuck on an exhausted `max` read only
*needs a way forward*, which is true of every stuck ticket and says nothing about this one.

**An approval shows what it approves.** Every document the approval pins is rendered (§ Documents)
between the sentence naming what it pins and Approve, under its name and version — a link to that
version's source — in a box that scrolls inside itself, so one long plan does not push the rest of
the queue below the fold. Approving a version you have to leave the item to read made the approval
the one decision in the queue taken on a name. A blob is its name and the link to its bytes, since
a blob is never laid out; a changeset is not drawn here at all, because the diff is its rendering:
*Read the change first* is beside the card in the queue and on Decide, and the card shares a page
with the diff on the Changes tab, beneath it, and on the review page, above it. The same card does it on the ticket's Decide and
Changes tabs.

The end of the queue is the success state: a success-coloured `END OF QUEUE` micro-label, a
sentence phrased as completion, and one line of evidence that work happened without you. The same
block, alone, is the empty state. Every other empty state names what would fill it rather than
announcing absence.

### Answering questions

A document's questions are **one form with one Send**, wherever they are drawn — a queue item, a
ticket's Decide tab, a conversation's footer and its queue item. Answering one question locks its
answer in; nothing is sent until Send. The reason is the agent's: a job that stopped with three
questions resumed on the first answer that closed the last blocking one, and read whichever answers
had landed by then — so a person answering in order was racing the resume. One Send makes the
answers arrive together (`job-prompt.md` § Answering a document's questions at once).

- **Every question on the version is in the form.** Blocking ones are required; non-blocking ones
  are optional, carry their assumption and an `optional` tag, and are drawn in the same form rather
  than only in the digest, because they were asked in the same breath. A version with no blocking
  question keeps its form under *Assumed, and carried on* on the ticket, and its lines in the
  queue's digest (§ Not waiting on you).
- **Questions are in document order**, the order the agent wrote them in.
- **An option is a card**: the headline, the sentence beneath it, and a radio mark. The recommended
  one wears the outlined `RECOMMENDED` tag and **starts chosen**, so accepting every recommendation
  is one tap on Send. There is no separate *Accept all* row any more; pre-choosing did its job.
- **Below `lg` a locked question folds** to one line — a check, its question, what was chosen and
  any note — so the form stays short on a phone. Tapping the line opens it again at full size;
  choosing an option folds it again. A question that starts chosen starts folded. One with nothing
  chosen is open. Typing keeps a question open, so the form does not move under a thumb that is
  writing. **At `lg` and up nothing folds**: there is room for every question at full size, and a
  question that shrank to a line under the pointer that had just chosen in it hid the other
  options and the field for a note at the moment they were wanted. The fold is the width's, by
  CSS, so one page held across a resize is right at both: the question's fields are always in the
  form, and below `lg` a folded question hides them behind its line.
- **Free text beside the options**: *add a note, or answer in your own words*. With an option
  chosen it is a note on that option; with none it is the answer. An open question with a chosen
  option offers *Clear choice*, so an answer in your own words is reachable when a recommendation
  started chosen. It is the composer's box, growing to six lines, and **Enter in it is a new
  line** at every pointer: only Send sends (§ The affordance rule).
- **Send is disabled until the form can be sent** — every blocking question locked, and in a chat
  every question, since a chat reads each as blocking — and names what it will send,
  `Send 3 answers`. Above it, while it is disabled, one line says what is left:
  `1 blocking question left`, or `1 question left` where every question in the form is required
  and the word would tell nothing apart.
- **The page holds the draft, and only the page.** Reloading, navigating away or opening the item
  on another device starts from the recommendations again. Nobody else ever sees a half-answered
  form, and there is no draft to expire. A dropped socket is not one of those three and does not
  start it over: the form carries an `id` and a `phx-change`, so the client gives the draft back
  on the rejoin (§ A reconnect is not a reload).
- **A stale form sends nothing.** When the document has a newer version, or another person answered
  one of its questions, Send is refused whole and the page says so; it reloads with the current
  questions.

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
- **Only an assumption asked on its own.** One asked in the same document as a blocking question
  is in that document's form, optional, and not in the digest as well — a second place to answer
  it would be a second answer (§ Answering questions). `Forge.Queue` still serves it as an
  `:assumption`; which surface draws it where is the page's arrangement.
- **Each line navigates to its ticket**, where the question is answered. Answering never
  navigates and a navigation target never encloses a control that commits (§ The affordance
  rule), so the digest offers no answer of its own rather than a second place to give one.
- **It counts towards nothing.** Not the header's `N decisions · N items`, not the nav badge: a
  number that answering nothing ever lowers is not a count of what is waiting.
- **Answering one changes no job's flow.** Its answer joins `answers.md` for whichever job runs
  next on the ticket; a waiting job resumes only once no *blocking* question is open, and a
  non-blocking answer closes none (`job-prompt.md` § Non-blocking questions).

## The work screen

A conversation and a ticket are both *one piece of work*: a branch, a record, a cost, and something
that may be waiting on you. `/chats/:id` and `/tickets/:project/:number` are drawn in one frame,
from one set of components, so that steering a conversation and steering a workflow are the same
gesture on the same screen. The frame exists
because the phone is where an operator develops when away from the laptop, and developing needs the
change, the documents and what the agent actually did within a tap of the place you type — not
three pages away, and not below a pane that will not let you scroll past it.

**The frame fills the viewport exactly, at every width.** `100dvh`, less nothing: a fixed header,
a fixed tab row, a body that is the page's only scroller, and on a conversation a fixed composer.
The page never scrolls as a whole, so the box you type in is never below the fold. On a phone the
bottom bar is not drawn on a work screen — the header's back affordance and the composer take its
place, as in any messaging app — and the composer sits above the safe-area inset. The viewport
declares `interactive-widget=resizes-content`, and a hook sizes the frame from `visualViewport`
where the browser ignores that, so the on-screen keyboard pushes the composer up rather than
covering it.

**Header.** The back affordance naming where you came from, the title (*Conversation*, or the
ticket's title on one line), and the state, status and flags per § The three axes. On a phone a
conversation's back affordance and status share one line and *Conversation* is for assistive
technology only: every line of header is a line the transcript does not have. When the frame is
shorter than everything fixed in it — the keyboard is up — the header and the strip are what
give way, clipped, so the tabs and the composer stay. Beneath it, one
line — the **context strip** — of identifiers: the branch, `+added −removed` over N files, turns,
what it has spent in the same form the rail uses, and the compact capacity gauge for the page's
pool; and, only when memory was the trouble, *⚠ 2 OOM kills · peak 2.0 GiB of 2 GiB* in `warning`
(`capacity.md` § Memory, which a job holds rather than spends). A conversation holding project
secrets adds *holds `STRIPE_TEST_KEY`* — names, never a value — and, for one picked when it was
opened and deleted since, *⚠ `GONE_KEY` was deleted and this conversation no longer holds it* in
`warning`, read from its latest run (`secrets.md` § Conversations). On a phone, tapping the strip opens the **details sheet** (the More sheet's component,
§ The phone): everything the laptop rail holds, including *End it* and its confirm. At `lg` and up
the rail is drawn beside the body as it is today and the strip opens nothing: it is still the
same button in the markup, taking no pointer and reachable from the keyboard, and the sheet
declines to open where it is the rail. One element at every width keeps the strip's identifiers
drawn once; the cost is a tab stop that does nothing on a laptop.

**Tabs.** A row of 46px tabs under the header, each with a count where one is meaningful; a
count of zero is drawn muted, never hidden, so tabs never move. The tab is in the URL
(`?tab=changes`, by patch) so back, reload and a pushed link land on it.

| | Conversation | Ticket |
|---|---|---|
| first tab | **Talk** — default | **Decide** (open decisions) — default while anything waits |
| | **Changes** (files) | **Timeline** — default otherwise |
| | **Docs** (artifacts written) | **Changes** (files) |
| | **Activity** | **Docs** |
| | | **Activity** |

### Talk

The transcript, pinned to the bottom per § Motion and structure, then from the bottom up: the
composer, the now line, and any open question's form.

- **The transcript is the turn in the order it happened**, not one message per speaker. A turn
  is its text blocks with the agent's actions between them, read from the event log in sequence.
  Every block is its own box, full width on both sides: a micro label naming the speaker
  (*you · 3m*, *agent · turn 4*) heads each speaker's run, your messages on `base-200`, the
  agent's on `base-100` with a border, and one agent box per text block — two blocks are two
  things said on either side of some work, and joining them ran the last sentence of one into
  the first of the next.
- **Actions sit between the boxes**, unboxed, one mono line each, in info colour per § Colour:

  | Call | Line |
  |---|---|
  | `Edit`, `MultiEdit`, `Write`, `NotebookEdit` | `✎ path +n −m`; expands to the change as a small diff |
  | `Bash` | `$ command` and ✓ or ✗; a failure shows its excerpt's first lines unasked |
  | `Read`, `Grep`, `Glob`, `LS` in a row | one line for the run — *read 6 files · searched 2×* — expanding to the list |
  | `TodoWrite` | the agent's plan as a checklist, redrawn in place rather than repeated |
  | `Task` | `⤷ description`, the subagent's own calls (by `parent_tool_use_id`) folded under it |
  | `WebFetch`, `WebSearch` | `↗ url`, `? query` |
  | anything else | `name` and its summary as the job page draws it |

  Any result with `is_error` is in error colour with its excerpt shown. A retry or a rate limit is
  not a line: it is what the now line says (below). Notices, `control` and `delivered` are not
  drawn, per § Motion and structure.
- **Live, every line; finished, each run folded.** While a turn is open its action lines appear as
  their events arrive. When it ends, each run of actions between two text boxes folds into one
  line — *11 actions · edited parser.ex, lexer.ex · mix test ✗→✓* — that expands in place. An
  error in a folded run keeps its line visible, so a scroll back through the transcript is the
  conversation plus whatever went wrong.
- **A message keeps the line breaks it was written with.** A chat message is not a document: a
  single newline is a break, where Markdown would join the lines into one paragraph. On a phone,
  Enter is how a line is ended, so a transcript that drops single newlines drops the shape of
  every message typed there. This is a rule of the transcript's styles; § Documents is unchanged.
- **The now line** is drawn only while a turn is open: the call that has no result yet, in
  words — *running mix test*, *editing lexer.ex*, *reading router.ex* — or *retrying (2 of 10)*,
  or *rate limited, resumes 14:00 UTC*, or what memory is doing when that is the latest thing the
  turn reported — *a process was killed for memory (1 OOM kill · peak 2.0 GiB of 2 GiB)*; with no call in flight, while the agent is writing, an
  ellipsis; static text, nothing pulsing, with **Stop** and **Interrupt and send** beside it. The agent's latest `TodoWrite` list sits above it, collapsed to its
  current item, so where the agent is in its own plan is visible without scrolling. When no turn is open the composer is the box
  and Send alone.
- **The question form** for the last message's questions docks directly above the composer while
  it is open, so the answers are under the thumb: every question the reply asked, folded below
  `lg` as it is locked, and one Send that posts them as a single message (§ Answering questions). The composer
  stays for anything the form does not hold.
- **The composer** grows from one line to six and then scrolls inside itself. Send is a 46px
  square with a label for assistive technology. Enter sends where the primary pointer is fine; on
  a coarse pointer (`(pointer: coarse)`) Enter is a new line and only Send sends, because a phone
  keyboard has no shift-enter and a composer that cannot take a second line cannot take a
  message. The hint names the gesture that applies and is drawn only for a fine pointer. This is
  `message_box`'s behaviour, so it holds everywhere a message is typed. A box that is one field of
  a form holding more — a question's own words, an approval's comment — is the same box with Enter
  a new line at every pointer and no hint (§ The affordance rule).
- **A stopped conversation** replaces the composer, in the same place, with the reopen sentence
  and **Reopen**.

### Changes

What the branch holds against its base, bounded per § Semantics that must not be lost.

- The file table, never truncated; a row expands to its own patch in place.
- **The commits on the branch** since its base: short sha, subject, age.
- **Ask about this** on each file row and each hunk header: a control beside the row, never inside
  a navigating region (§ The affordance rule), which puts `path:line` into the composer's draft
  and switches to Talk. On a ticket there is no composer, so it goes to the ticket's most recent
  live conversation with the reference in its draft, or to `/chats/new` for the ticket with it in
  the first message when none is live — the reference travels in the URL and nothing is sent
  until the operator sends it.
- A conversation's **merge** and its conflict sentence are here, as they were beneath the diff.
  A ticket's changeset approval is here too, *when it is what is waiting*: the same approval card
  Decide draws, from the same component and the same event, at the foot of the diff it approves.
  Reading a change and approving it are adjacent; they are still two gestures.
- The review page stays: it is where *what it was built from* and *questions answered* sit beside
  the diff, and the queue's review items link there. Changes links to it when the ticket has a
  changeset.
- **The ticket's presentations come first on the review page**, above the diff and the facts rail
  and open rather than collapsed: a presentation is the reasoning the patch cannot carry, written
  to be read before it. Each is drawn dashed and `VIEW ONLY` with no approval slot, as the kind is
  everywhere (§ Semantics that must not be lost). Where a paragraph quotes `` `path:line` `` or
  `` `path:start-end` `` in backticks, the matching source from the changeset's head commit is
  drawn directly beneath that paragraph — any path in that tree, which is the repository as the
  change leaves it and not only the files the change touched — so the operator reads the lines
  the prose is about without going into the diff for them. **What is drawn is bounded, the way
  the patch beneath it is**, and the prose is an agent's, so every bound is on what the page
  draws rather than on what the document says: a fixed number of quotes drawn per presentation,
  counted over the whole of it and not per paragraph, since the same quote in forty paragraphs
  is forty blocks; a fixed number of lines and bytes per quote; a fixed number of bytes read out
  of git for the whole presentation, asked of git — and of the *blob*, not of whatever a path
  resolves to — before any of those bytes are; and a fixed length of prose rendered, past which
  the page draws the beginning and says the rest is in the source. Each bound that stops something says so where it
  would have drawn it — how many quotes it left out, or to read that one in the diff. A path or a
  range that does not resolve at that commit degrades to the same kind of muted note naming what
  was asked for, and **so does a path whose file is not text**: the diff prints `Binary files …
  differ` rather than those bytes, and a page that drew them would not survive being encoded for
  the browser. None of it can fail the page. A ticket with no presentation reviews exactly as it
  did before: the section is absent, not empty.

### Docs

Every artifact written — documents and files alike, a conversation's included, and on a ticket
all but the changeset, which is the Changes tab — one row each:
a `▸` where the row opens, the type's icon (§ Artifact types), the name, approval marks only
where approval is possible, and the latest version at the row's end, linked to its address;
earlier versions as links beneath. What the last turn wrote that was not recorded is listed
beneath, with why.

**A document is collapsed until it is opened.** Its row is a `<details>`, the `▸` turning as a
Changes row's does, whose body is the document **rendered** per § Documents — or its text as
written, when its name says it is text, a log or code. Open, one long plan pushed every row after
it a screen down, and the tab is read for what is there before it is read for any one thing in
it. An opened row stays open while the tab is patched (§ Motion and structure). The
version link is beside the summary and never inside it: the row is a control of its own
(§ The affordance rule).

**A file has no body here**: its whole row is the link to its bytes, drawn at the same height.
Reading every one of a build's outputs from the store to draw its row would be a store read per
row per patch, and a file's bytes are one tap away at its address.

### Activity

The event stream of the conversation's job, or of the ticket's current job with its earlier jobs
linked to their pages, newest first, notices behind their count. Its tool calls are drawn with
the action lines of § Talk, each carrying its result — a result is not a row of its own — the same component, so an edit, a command and a failure read the
same whether a conversation or a workflow job made them — and the job page draws them the same
way; every other event keeps the job page's row, a `memory` row with its type in `warning`. **A
row wraps rather than truncating**, and a line longer than 200 characters — an agent's paragraph, a
command on one long line — shows its first 200 and expands in place to the whole of it. A command's
line, a URL and a query do so wherever they are drawn, the transcript's included, since it is the
one component; a call drawn as its name and input is already cut short before it gets there
(`Forge.Events.tool_summary/2`, 160 characters of its input), so it is never long enough to clip.
The
whole is already on the page: an agent's text is drawn in full here, where a list or the CLI's log
draws `Forge.Events.summary/1`'s bounded line. **Live while the job runs**, on a conversation and on a ticket alike (§ Motion
and structure). A conversation's job is not opened on the job page; this tab is where it is read.
The job page itself tails its job while it runs, for the same reason.

### Decide and Timeline (ticket)

**Decide** is the ticket's *Waiting on you*: its blocking questions, approval card and
transition card, drawn with the queue's components — a document's questions as one form
(§ Answering questions) — answering in place and never navigating. Its count is what
the queue would count for this ticket (`Queue.for_ticket/1`), and it shows what it counts. With
nothing waiting it says so and names what would put something there. Beneath, without accent and
under no count, is what an agent **assumed and carried on from**: the non-blocking questions the
queue's digest sends here to be answered (§ Not waiting on you).

**Run again.** Beneath the transition card, and on its own when there is no card, a row names the
state and offers to run it again — `Run refining again` — whenever the ticket rests in a job or
command state with nothing live in it (`workflow-grammar-v1.md` § Running a state again). It is
on the ticket page after a success as well as a failure, because redoing a refinement before
approving it is a choice a person makes while reading it. In the queue it is on the stuck card
only. An approval card already asks one thing — this version, yes or no — and a third row that
throws the version away is a decision made from the ticket page, where the version is read. A
transition whose approval has nothing to approve is never on either card.

**Cancel ticket** is at the foot of the rail, in error colour behind a confirm, on an active or
stuck ticket; a cancelled one has **Restore** there instead, with a line saying where it is hidden
and what restoring leaves (`workflow-grammar-v1.md` § Cancelling a ticket). It is rare and
undoable, so it sits apart from Decide, which is where the ticket's next step is chosen.

**A human state's documents are written here**, above its transition card: one editor per name
the state declares in `produces` (`workflow-grammar-v1.md` § Semantics), holding the latest version
when there is one, and a filled *Save* that records what was typed as a new version by the person.
Writing one is not a decision and adds nothing to the count. It sits beside the transition because
the person deciding where the ticket goes next — a tester sending a build back — is the person the
next job needs to hear from, and a note that lived anywhere else would be skipped on the way to the
button.

**Timeline** is the ticket's body, the steps and job rows, and then **the ticket's
conversations**, live first, with *New chat* beside their heading — a conversation started from a
ticket used to be findable from the project page and not from the ticket it is about.

**A command is a job row like any other** (`docs/design/commands.md`): the whole row the target,
leading with `$` where an agent job's row has its attempt, the command and its arguments as an
identifier, its exit status where a job's outcome goes — `exit 0` in success, any other in error,
none as the engine outcome that says why — and its duration where a job's turns and cost go, since
it has neither. One an agent invoked is indented beneath the job that invoked it, in the step that
job is in; a command state's commands are that state's step. A command state's glyph is a job
state's, `▸`: entering it starts work that ends in an outcome.

**A failed command of the batch that decided where the ticket is shows the end of its log** under
its row: the last 4 KiB, from a whole line, with how much was cut. The failing line is what a
person looking at `build_failed` wants first, and before this it was behind the log's download.
Only that batch — an older one's failure was answered by the work after it — and never an
agent's own commands, whose logs the agent is handed. The rail's last four events say what three
of them mean beside their type: the statuses a batch decided and its outcome, why the ticket
stuck, and which edge it took.

**A ticket whose pin the default branch has moved past says so in its rail**, under the
`workflow` fact: the paths under `.forge/` that changed, and **Re-pin at `<sha>`** behind a
confirm (`workflow-grammar-v1.md` § Pinning). Nothing is said while `.forge/` is unchanged —
a default branch that moved on for other reasons changes nothing the ticket runs.

**A ticket a merge has put in conflict says so in its rail too**, beneath the facts and shaped like
the re-pin notice: *`main` no longer merges with this ticket's changeset since #12 merged* —
or *since a conversation merged*, or *`main` no longer merges with this ticket's changeset* when
it conflicted already — the paths, and **Send to `<target>`** behind a confirm, which takes the
conflict route to the merging state's `on_conflict` target (`workflow-grammar-v1.md` § Merging).
Found after every merge (`git-hosting.md` § After a merge, the other tickets) and shown while it
is still true of the ticket: its latest changeset is the one found conflicting, and the ticket has
not taken the conflict route since. It offers the action only where the engine would take it — an
open ticket with nothing live in its state, an edge from there into a merging state, and an
`on_conflict` on that state; otherwise it is the notice alone, because a conflict nobody can act
on from here is still worth knowing before the approval. Nothing starts until the button is
pressed: the confirm says a job will run when the target runs one, since that spends a credential
on a ticket the person may be about to cancel.

**The conflict route is a step like any other.** The transition it takes is in the timeline as the
step it leads to, and the rail's last events say what `ticket.merge_conflicted` means beside its
type — the first path that conflicted, how many more did, and the state that would have merged.

**A command's page** is the job page with what a command has: its exit status as the largest thing
on it, the script as it ran, the argument vector as JSON — it reached `exec` as a vector, and
joined with spaces two arguments would read as one — the commit it ran at, its timeout, the job
that invoked it, and its log.

## The phone

Below `sm` the shell is the bottom bar — Queue, Board, Chats, More — and every page reflows to one
column. Nothing is removed at this width; § The work screen is the one page with its own frame.

**More opens a sheet**, a native `<dialog>` drawn as a bottom sheet, opened with `showModal()`
from a dispatched event and closed by Escape, a tap on the backdrop, or navigating. Focus and
inertness come from the element rather than from code. In order: the capacity gauge with its
detail written out (§ The capacity gauge in the top bar); Projects, Workers, Templates, New
project, and Accounts for a node admin; then the account's address, which opens settings, the theme toggle,
and Log out. Every row is a 46px target. Logged out there is no More, and so no theme toggle
where a laptop's top row has one: what a logged-out phone reaches is the log-in forms, and the
theme there is the system's, as it is everywhere until someone picks one.

**This is the menu the note used to forbid** — *no hamburger at any width*. The objection was to
hiding the product's places behind a control, and it was right for the places that matter most:
Queue, Board and Chats stay one tap away on the bar. What the sheet holds is the rest of what a
laptop reaches from its top row — Projects and Workers from its nav, Templates from the Workers
page, the gauge, New project, Accounts and the account from the header's right-hand group — and the
alternative was not having them on a phone at all.

**The board stacks below `sm`.** Each state is a section — its name with the topology glyph and
count, then its tickets — in the same order the columns take on a laptop, so the workflow still
reads top to bottom as it reads left to right. A state with nothing in it is its heading and a
muted 0, not a placeholder sentence. **"N more" expands its column in place**, at every width: it
is a control, not a caption, and the tickets it reveals are already on the page. The four-row cap
exists so a column never grows its own scrollbar; expanding one lets the page scroll instead,
which is § The project page's reasoning applied to one column on request. A project with ticket
types stacks lane by lane, each type's heading above its states.

**Tables reflow below `sm`.** A project's tokens and mirrors, and a project's workflow table,
become one block per row: the row's identity on the first line, then label and value pairs. A
control stays in the cell it acts on — a token's *Revoke*, a mirror's *Remove* — and there it is
a full-width bordered 46px button (`reflow-control` in `app.css`). From `sm` up they are tables.
A table that scrolls sideways hides its controls off the right edge, which on a row whose last
column is the decision is hiding the decision. The workers page is not a table at all: a
machine is a block at every width (§ The workers page).

**The 46px floor has no phone exception** (§ Space, measure and targets): an `×` that removes an
assignment or a credential, the theme toggle's buttons, and a form's select are targets like any
other.

**Push follows the queue.** Anything that starts waiting on a human pushes to the phones of the
people in its project — a blocking question, an approval, a stuck ticket, a ticket ready for
review, a conversation's reply — and links to the work screen on the tab that holds it: Decide
for a ticket, Talk for a conversation. An assumption, which waits on nobody, is digested. The rule
is `Queue.waiting?/1`, not a list kept beside it, so a queue kind added later pushes or does not
for the same reason.

## Creating things

**Where the two create actions live, and why they are not in the same place.** A project is made
rarely and from nowhere in particular, so it is an action in the laptop top bar, beside the theme
toggle rather than among the nav items — those are destinations and this is not one. A ticket is
always made *for a project*, so it is offered on the project page — and on the create view that
has just made one — and nowhere else: the queue is an inbox and the board is every project at
once, and neither has a project to make a ticket for.

On a phone, New project is a row in the More sheet, and the project page offers New ticket and
New chat exactly as it does on a laptop. They used to be laptop-only, on the reasoning that the
phone is where decisions are answered; § The phone records why that no longer holds.

**A ticket form reached from a project does not ask which project.** It says which one, as an
identifier, and the select appears only on the bare `/tickets/new` — a route nothing links to,
kept so the address works and so the no-projects-at-all case still has somewhere to say so.

**A conversation is the same shape, and its bare route *is* linked to.** `/chats/new` reached
from a project or a ticket states which and asks nothing — there is not even a hidden field, the
view holds it. The select appears on the bare route, which the chats page links to: that page is
every conversation in every project you are in, so it is the one surface with no project to carry
and the only place a create affordance has to ask. A conversation is still never started from
nowhere; the asking moved to the one page that does not know.

**A conversation's secrets are boxes, none ticked**, below the model and the resources, and only
when the project has any: each secret's name, and two sentences saying what ticking one means —
*Set in its environment by name. Anyone in this project can ask it what they are*
(`secrets.md` § Conversations). A name deleted
between drawing the page and submitting it is refused by name, and the conversation is not
started without it.

**A list row that navigates may still carry a control, beside it and never inside it.** The chats
list ends a live conversation from its row, because a live row is a machine running and the
alternative was opening it first. The row is the link and the control is its sibling, which is
The affordance rule above applied rather than excepted. What a list may never offer is deleting a
conversation: they are kept for ever (`conversations.md` § Lifetime), and the affordance that
exists is the one that stops it costing something. Ending one does delete its *branch*, unless
the branch would not merge cleanly, so its confirm says so — the same sentence on the list and on
the conversation's page, from one definition, so neither can understate it.

A project and a ticket are made in the product. A **workflow is not**: it is
`.forge/workflow.yml` — or one file per ticket type under `.forge/workflows/` — in the project's
own repository, read at the ticket's base commit and
pinned at admission, so it versions with the code it governs and there is nothing for a form to
edit. The two create views are pushed views with a back affordance. A project's is reached from
the laptop top bar or the phone's More sheet, and from the board and the ticket form only when there are no projects at
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
- **A project with more than one ticket type is asked which, and nothing is preselected**
  (`ticket-types.md` § Admission). The chosen type's description and the state it starts in are
  said beneath the select; a type whose file does not parse is offered marked as such and says why
  when chosen, beside the types that admit. One type is stated rather than asked, and the single
  `.forge/workflow.yml` asks nothing about types at all.

Both are checked again on submit — the repository is a shared surface and a check is a moment,
not a guarantee — but the operator is never the one who finds out.

**The clone URL belongs on the project page, on the create view and on project settings, and
nowhere else.** Those are the moments an operator needs it: when the repository has just been
made, when they have come to change the workflow and have found that they cannot do it here, and
when they are minting the credential to use it with — settings names the URL a token is for, and
shows it once with the token in it. A git URL anywhere else is an invitation to a surface that is
not the product.

## The projects page

`/projects` lists the projects the viewer is a member of, one row each, and nobody else's
(`design/identity.md` § Read scoping). Before it a project was reached from a ticket, the board's
column headings or a URL, and nothing answered "which projects are there, and can each of them
run anything?".

A row is the project's name, which leads to its page, and four figures: its open tickets, the
templates assigned to it, the permanent machines assigned to it, and the credentials in its pool
that are not revoked. **A project that cannot run anything says so in error colour** — "no
template or machine", "no credential", or both — for the same reason a permanent machine that
serves nothing does on the workers page: it is the state that looks fine everywhere else and takes
no work. A project runs on a template *or* a permanent machine, so either one is enough. The
figures are counted in one query each over every project on the page, never one query per row.
The page reloads when a ticket of one of its projects changes, filtered to those projects before
anything is read; an assignment is not announced, and shows on the next visit. Nothing on it is
accent; nothing on it waits on a person. New project is in the header, as on the top row.

## The project page

`/projects/:name` is the overview and the project's own board. It exists because `/board` answers
"what is happening everywhere" and nothing answered "what is this project".

**A project with ticket types draws a lane per type**, on both boards, each under its name and
with its own workflow's columns, since a bug's states are not a feature's (`ticket-types.md`
§ The board). One lane draws no heading, so a project without types is drawn as it always was.

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

**A project with ticket types shows one workflow per type**, each under its name and description,
and a type that does not parse as its reason beside the ones that do. What `.forge/workflows/`
holds that is not a type is listed with why, since it blocks nothing and would otherwise be
invisible (`ticket-types.md` § The project page).

**It links to the repository it holds** — `Repository ›` in the header, beside Settings. The
page says what the repository means to the platform; what is actually in it is
§ The project's repository.

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

**Its secrets are listed for every member and set only by an admin** (`secrets.md` § Surfaces).
A member reads the names, because a workflow's author needs them; each row is a name, its version,
who set it when, and who receives it — the commands and states of the default branch's workflows
that name it, each with its ticket type when there are types, how many live conversations hold it, and when a run last held it. No value is ever
drawn, to anyone, because none is ever loaded — the value field is write-only, sent once on submit
and rendered empty again after a save.

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
every minute while the page is open, since the countdown is to a moment.

**On a phone it is the first thing in the More sheet**, and there its title is written out as a
line of text under each window, because a phone has no hover and a figure whose meaning lives in
a tooltip is a figure without one there. The work screen's context strip carries the compact
form (§ The work screen).

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
retires it — from its row here, or with `mix forge.worker.retire`. It holds no `max_workers`
slot: that ceiling is a template's and counts the machines made from it, and a permanent worker
came from no template. Destroyed rows are hidden unless asked for: they are history, and the page
is about what exists.

**Templates is a button in the header**, not a link inside the explanation beneath it, where it
used to be the only way there from a laptop. While the viewer has no template of their own it is
drawn filled, and a line beneath the header says in error colour that the platform can make no
machine for them: the machines on this page are the viewer's, a machine the platform makes is made
from its owner's template, and the only other kind is one the viewer mints and boots themselves.

**New machine is beside it**, and mints a permanent machine for the viewer (`identity.md`
§ Minting a permanent machine). It opens a form beneath the header that asks one thing — the
project it serves first, or none yet, from the projects the viewer is in — and names no owner,
because the machine is the viewer's. What it mints is drawn once, in the *Copy this now* block
project settings uses for a token (§ Project settings) — one component, `shown_once`, for both: the machine's whole environment, one
`NAME=value` per line, with a sentence saying where it goes — a file named `worker.env` on a disk
labelled `forge-config`, or the provider's user data — and that only its hash is kept. *Done*
dismisses it; the row it made is already in the list, *not connected* and *last seen never* until
a machine boots with it. **It is never filled**: a filled button is the Templates button's way of
saying nothing will appear here by waiting, and one button saying it is enough.

Nothing here is accent. It is a readout with four decisions in it: minting a permanent machine
(above), what one offers (below), which projects it serves, and — on every row that is not
destroyed — ending it.

**A machine is a block, not a table row.** Seven columns did not fit a phone and never would, so
each machine is a block separated from the next by a row rule (`border-base-300/60`), with no
card and no box, in this order:

- **A header line**: the short id; provider and provider id; `status`; the reachability dot and
  word; `managed` or `permanent`; the release it last joined with, in muted mono, and beside it
  `current` or `other build` (below); and, on the right, *Log* — on every row, destroyed ones
  too — and the control that ends it.
- **A refusal line**, when the machine's last join spoke a protocol this platform does not
  accept, in `error`: *refused: protocol 3, this platform accepts 4–5 — update it*. It is drawn
  from the protocol the row recorded and the range the platform accepts now, so it cannot say
  something the next join would not.
- **An unhealthy line**, when the machine said its systemd stopped answering, in `error`:
  *unhealthy since 14:02 UTC: <its reason>*, then what happens next — *told to reboot at 14:02 UTC;
  takes work again when it rejoins healthy*, or for a managed machine told within the hour
  *rebooted within the hour, so not again: destroy it, or wait for it to rejoin healthy*, or for a
  permanent one *not the platform's to reboot: restart it, and it takes work again when it rejoins
  healthy* (`worker-tier.md` § A machine whose systemd stops answering). Nothing is placed on it
  while the line is there, so it says so rather than leaving a `ready` row looking assignable.
  There is no control to clear it: rejoining healthy is what clears it.
- **Three meters — CPU, RAM and disk** — each a mono figure over a thin bar, from the machine's
  own last report (`worker-channel.md` § Live figures), re-read on the page's five-second
  refresh. The bars are **neutral and never accent**: a full machine is not waiting on a human,
  and the one loud colour is kept for what is. A disk at 95% or more also says so in `error`,
  because a full disk is how a job fails rather than slows. A connected machine that has sent no
  figures reads *no stats — update it* when its join spoke no protocol, since a release that
  predates them is the reason, and *no stats yet* when it did — such a release sends its first
  figures one tick after joining, and every machine rejoins at once after a deploy. A machine that
  is not connected draws no meters at all, because a disconnected machine's last figures are a
  guess about now.
- **Two columns beneath, stacking on a phone**: what it offers the gate — capacity, the report
  that disagrees, *never made* — and the form behind *Set what it offers*; then the harness, what
  it is running, when it was last seen and since when it has been idle — and, for a machine the
  platform made, when it will go (*goes in 43m*, *goes now*): the end of its period or of a
  claim on it, or on a provider billing by the hour the leeway point of an hour it has paid for
  (`worker-tier.md` § The hour already paid for) — and which projects it serves. Every line the
  table carried is still here; this was a relayout, not a removal.

Everything tappable on it is 46px, the selects and fields of its two forms included.

**Each block links to the machine's log**, `/workers/:id`: what the platform saw happen to it and
what the machine itself reported — joined, refused, jobs accepted and finished, seeds fetched,
swept, destroyed and by what — newest first, with its time and where it came from. It is the
machine's history and not a job's: what an agent did is on the job page. `worker-log.md` is the
standard for it.

**Ending a machine is the fourth decision, and it is the owner's.** A managed row offers
**Destroy machine** and a permanent one **Retire**, each behind a confirm that says what will
happen, from one definition each so the sentence cannot drift between uses: *the machine is
deleted at the provider, and its N running jobs are requeued*, or *forge forgets the machine,
the machine itself keeps running, and its N running jobs are requeued*. The id is the client's,
so `Workers.retire_by_owner/2` reads the row scoped to the viewer before anything happens, and
somebody else's id posted by hand is *not here*, exactly as for the other two decisions
(`identity.md` § Sequencing). A driver that refuses leaves the row, with its words, and the
flash names `mix forge.worker.retire --force` — force is not on this page, and why is
`provisioning.md` § Whose account. It does not promise a retry: the sweeps retry a destroy only
for a machine that is unreachable or idle, and a machine somebody just pressed Destroy on is
usually neither.

**The release is what the machine said, and the hint beside it is what the platform knows.**
`flake.nix` builds the platform release knowing the build of the worker release it ships with
(`worker-tier.md` § Updating a worker); a row whose build is that one reads `current`, and any
other reads `other build`. **Not "older build"**, which is what this was first going to say: a
build is a hash and hashes have no order, so the platform cannot tell a machine that lags it
from one made from a newer checkout than the platform itself — which is exactly what building a
snapshot before deploying produces. In the usual order of things it is older, and *other* is the
word that is true either way. A node built outside Nix knows no build and draws no hint; a row
that has not joined since the release was on the wire has nothing to compare and draws none
either.

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

**A snapshot says what it carries.** Beside a template's image, and in the image select, the
page shows the snapshot's worker build — with the same `current` or `other build` hint — and the
protocol it speaks, read from its provider labels (`provisioning.md` § A snapshot that speaks the
wrong protocol). A snapshot made before the labels existed reads *unlabelled*: it cannot be
identified after the fact, and a date is not an identification.

## A job waiting for a machine

A pending job the scheduler could not place says why, in one sentence, where the job is looked at:
under its row on the ticket's timeline, and on a pending conversation's page where the reply will
appear. The sentence is the scheduler's (`provisioning.md` § The gate), in the product's voice —
*Waiting for room: …*, *Waiting for a template: …* — and it is language, so it is sans at body size,
never mono. **A sentence that sends the operator somewhere sends them where the reason is.** A
provider that refused to make a machine left its words on the worker row, so that sentence names the
workers page; a template the platform would not spend from — its provider credential is another
user's, or another provider's — or would not make a machine from, because its image speaks a worker
protocol this platform does not accept, made no worker row, and its words are on the template, so
those name the templates page. Both pages show the viewer's own rows only, so each sentence names whose
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
needs structure, which source text cannot carry. A document whose name says it is text, a log or
code and data (§ Artifact types) is the exception: it is shown as its text, in a `pre` that
scrolls inside itself, because Markdown would join its lines into one paragraph. This holds
wherever a document is drawn — the Docs tab, the review page and an approval card — because all
three draw it with `ForgeWeb.FileType.render_document/2`.

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

## Artifact types

An artifact's row carries an icon for the kind of file it is, so a build's package, its log and
the plan beside them are told apart at a glance: a list of them is read by shape before it is
read by name. It is drawn on every row and chip that is an artifact: the Docs tab, a job page's
*Wrote* and a command's log, the ticket's chips, the review page's documents and an approval
card's pinned versions. Where an artifact is named inline among other identifiers — the queue
item's sentence and its footer, a question's answer, the Decide tab's document editor — it stays
words. `ForgeWeb.FileType` is the one place a type is decided.

The type is the name's extension. A document, which is text by construction, is Markdown unless
its extension says text, a log or code; a blob with an extension not below is a *file*. It is
never read from the bytes: drawing a row must not cost a store read.

| Type | Extensions | Icon | Hue |
|---|---|---|---|
| Markdown | `.md` `.markdown`, and a document or presentation of any other name | a page with lines | 210 |
| text | `.txt` `.csv` `.tsv` | lines | neutral |
| log | `.log` | a terminal | neutral |
| code and data | `.json` `.yaml` `.yml` `.toml` `.xml` `.html` `.css` `.js` `.ts` `.ex` `.exs` `.heex` `.py` `.rb` `.go` `.rs` `.java` `.kt` `.swift` `.c` `.h` `.sh` `.sql` `.nix` `.diff` `.patch` | brackets | 175 |
| image | `.png` `.jpg` `.jpeg` `.gif` `.webp` `.svg` `.avif` | a picture | 340 |
| archive | `.zip` `.tar` `.gz` `.tgz` `.xz` `.bz2` `.zst` `.7z` `.jar` `.aab` | a box | 95 |
| Android app | `.apk` | a phone | 125 |
| file | anything else | a cube | neutral |
| changeset | the `changeset` blob, which is a commit and not a file | `±` | neutral |

The icon sits in a 28px tile — 20px in a chip — tinted with its hue at low strength, on
`--radius-field` and unbordered: it is not a control, and the row it sits in is. The tile is the
only thing the type colours; the name beside it is an identifier and stays mono `base-content`.
The hues are § Colour's *file type* and nothing else's. The icon carries its type's words for
assistive technology, since an icon alone says nothing to a screen reader.

**An Android app is first class.** Its Docs row says *Android app* beneath its name, and its
address serves it as `application/vnd.android.package-archive` rather than
`application/octet-stream`, still as an attachment — unless its bytes are small, valid text, which
no real package is (an `.apk` is a zip), and which is then shown as text like any other
(§ Addressable artifact versions). The media type is what tells a phone's browser the download is
an app to hand to the package installer, rather than bytes it saved. That a phone then installs it
from the row is unobserved here: it is tested as headers, and no package has yet been installed
from a forge page.

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
  is a work screen's Docs tab — the ticket's or the conversation's — and an approval card that pins
  it; this route is the source behind it.
- A **blob** is fetched from the store by its key and served as `text/plain` when it is text no
  larger than a document may be. Anything else — a package, a screenshot, a large log — is served
  as `application/octet-stream` with `content-disposition: attachment` — an `.apk` as
  `application/vnd.android.package-archive` (§ Artifact types) — copied from the store to a
  temporary file and sent from there rather than read into memory: a download, never rendered. A group's file is named `group/file`,
  and its address carries the name as one encoded segment.
- A **changeset** is not a file. `git:<sha>` names a commit, so the changeset links to `…/review`,
  which is the rendering of a diff. Nothing tries to serve it as bytes.

Serving raw bytes is what the route does *today*, not what the path means. When the
margin-questions view lands it takes this route's HTML representation and raw moves behind a
parameter; the address of a version does not change.

## The project's repository

`/projects/:name/repo` is the repository itself, reached from `Repository ›` in the project
page's header beside Settings. The project page says what the repository *contains* for the
platform — the clone URL, the default branch, the workflow it holds — and answered nothing about
the code: what landed last week, and what the tree looks like now. Reading either meant cloning.

It is membership-scoped like every other project read, through the same
`ForgeWeb.Access.project_by_name!/2` guard the project page uses, and a non-member gets the miss
a project that does not exist gets (`design/identity.md` § Projects and members). There is no
admin distinction: a member may already clone the whole repository with a read token, so a page
that shows them less would be a lock on the window beside an open door.

**A branch picker chooses what is being looked at**, from `refs/heads/` and nothing else — the
platform's own refs under `refs/forge/*` are bookkeeping, not somewhere to look. The project's
default branch is selected on first load. An unknown branch in the address falls back to the
default rather than failing, so a stale link lands somewhere real. Choosing a branch is all the
picker does: nothing here creates, moves, deletes or merges one.

**Two tabs, both in the address: Commits and Files.** The branch, the tab and the page are the
only state the view holds that is not read from the repository, so all three are in the query
string and every control patches it — the page is bookmarkable at any depth and survives a
reload.

- **Commits** is the branch's own history, newest first, thirty to a page, with `Older ›` and
  `‹ Newer`. Thirty because a repository with thousands of commits must never load them all, and
  paging because every commit still has to be reachable. The page is by position (`--skip`), not
  by a cursor: a commit landing between two loads shifts what a page points at by one, which is
  the cost of not holding a cursor the ticket did not ask for.
- **Files** is the selected branch's head as a tree. A directory is read when it is opened and
  not before, so a repository with ten thousand files costs the same as one with ten until
  somebody goes looking; reopening one already read draws it from what the page holds rather than
  asking git again. It is **plain identifier text** — mono, no colour, no icons — the way the
  rest of the product draws a path, and a folder is told from a file by the `▸` it carries and
  nothing else. **One file is open at a time**: opening another replaces it, opening the open one
  closes it. The page therefore holds directory *names* and exactly one file's content, which
  the 512 KB bound below then bounds in full — the alternative was a reader's whole afternoon of
  opened files sitting in the socket's own process.

**A file opens in place, as plain text, and only when it is small enough.** Its size is asked of
git before its content ever is, so a file at or over **512 KB** says so instead and is never
partially loaded. A **binary** file is listed by name and its content is never rendered — not
garbled, not previewed, not offered as a download. Neither limit is a failure the page reports:
both are the row saying what the file is.

**Binary here means `ForgeCore.Document.text?/1`** — valid UTF-8 with no NUL, over the whole
file — and not git's own "a NUL in the first 8000 bytes". git's rule is right for git's output
path and wrong for this one: what the page draws goes out as JSON over the socket, so a latin-1
source file with no NUL in it at all was drawn garbled, and one whose invalid byte reached the
rendered HTML made the socket's serializer raise and took every LiveView on that connection
down. The product already wrote this rule down, for this reason, where a document is read and
where one is served.

**No syntax colouring, by language or by anything else.** Settled on this ticket by the person who
answered it, and consistent with § Colour. Five of its six bullets give a hue to something about
the *work* — a wait, a link or a decision, a job's state, an outcome, an artifact's type — and
the sixth is about surfaces rather than meaning. None of them is about the text a page draws.
"This word is a keyword" would be a seventh meaning, spending the only scarce thing § Colour
has on something that is not a state of anything.

**Opening a commit is its own page**, `/projects/:name/repo/commits/:sha`: the commit's identifier
line, then the files it changed and the patch in each, drawn by `ForgeWeb.Diff.section/1` — the
same component the review page draws, so a binary file in a commit already reads *binary* with no
attempted content. A commit is shown against its first parent, and a root commit against the
empty tree, so the first commit in a repository opens like any other. Two arbitrary commits are
not diffed against each other; only a commit's own change. The back link carries the branch and
the page it was opened from, so returning lands where the reader was rather than at the top.

**Nothing here writes to the repository at all.** The reads are `for-each-ref`, `log`,
`rev-parse`, `ls-tree`, `cat-file` and `show` on the branch page, and `log`, `rev-parse`,
`hash-object` and `diff` on a commit's: no worktree, no checkout, no ref touched and no object
written. `hash-object` is in that list without `-w`: a root commit's diff is read against the
empty tree, which git carries whether or not the repository holds it, so the tree is *named*
rather than written. (`Forge.Git.empty_tree/1` still writes it for `create_root_commit/2`, where
a commit will reference it and `git fsck` would otherwise report it missing for ever.)

The test that holds this records the repository *directory* and not its refs, because the first
version of this page could write a file into it while every ref stayed exactly where it was.

A path or a branch name from the address is resolved by git against its own trees and refs,
never against the filesystem, so `..` in either does not escape anything: it matches nothing and
the page reads it as not found, like any other typo. **That is true of a path and a branch and
was not true of the sha**, which is the harder half of the same question: git reads any argument
beginning with `-` as an option wherever it sits, and `log --output=<file>` writes a file, so
`/projects/:name/repo/commits/--output=config` truncated the project's own `HEAD` with one GET
and `--output=../../x` wrote outside the repositories directory. Two guards answer it now. The
general one is `Forge.Git.run/3`, which refuses a value the caller was handed when it begins
with a dash, marked `{:data, value}` wherever one is passed as a whole argument. **The mark is
fail-open and that is a known trade-off, not a claim about safety**: a future caller who forgets
it gets a hole and no error. The alternative — `run/3` refusing *any* dashed argument unless it
is in a module-level allowlist of the flags this module uses — replaces an obligation at every
call site with one list, and is the better shape if a third site of this ever appears. What
keeps the current rule honest is that it is greppable: a value in `Forge.Git` that is not a
literal and is not marked is visible in review, and the two that are flags' own values
(`--skip=`, `--max-count=`) are guarded as integers instead, because a flag's value is not a
position git reads an option in. The particular guard is this page: the address names a commit,
so only a hex object name is read out of it, and anything else is the ordinary miss before git
is reached at all.

**A name that is not text is drawn in git's own escaped form.** A repository may hold a file
called `caf\xE9.txt`, and the platform asks git for paths exactly as they were written — which
is what makes `résumé.md` readable instead of `"r\303\251sum\303\251.md"`. Those raw bytes in a
page are the same crash as a non-UTF-8 patch, one layer down and reachable from a *filename*, so
every path leaves `Forge.Git` through `printable_path/1`: as git printed it when that is text,
and C-escaped in quotes when it is not. `unquote_path/1` is its exact inverse, so such a file
still opens and such a directory still expands — the escaped form is what the browser holds, and
it is read back before git sees it.

## Not built yet

Named so their absence is a decision rather than an oversight. Each is specified in the handoff:

- The answering sequence — one ordered full-screen pass over every decision in the queue.
- Message state (queued, retrying, failed, confirmed) and the client outbox with an idempotency
  key per answer. Until it lands, a send is confirmed by the flash the framework already shows.
- Document-with-margin-questions at laptop width.
- The `/tickets` finder. Until it exists neither the laptop row nor the phone bar has Tickets.
