# Operator UI

Scope: the standing rules for every operator surface. This note is the standard — code follows
it, and a change of mind updates it first. It supersedes the UI guidance that `platform/AGENTS.md`
used to carry.

The governing idea, from `vision.md`: the operator's attention is the scarce resource, and the
queue is an inbox rather than a dashboard. Exactly one thing in the interface is allowed to be
loud — something waiting on a human — and it is marked in amber, the accent, which is used for
nothing else. Everything else is ruled, quiet, and coloured only where a colour means something.

**A phone can do everything a laptop can.** The layout changes with the width; what an operator
can reach and do does not. The redesign this note describes goes further than the one before it:
the phone is not a narrow laptop that still works, it is the primary client, designed first, and
the desktop is the same blocks with room. Where a rule below names a width, it is about
arrangement, never about reach.

## Where this comes from, and what is built

The source is the redesign handoff vendored under `docs/design/ui/`:

- `README.md` — the overview, the frame's sizes, every screen by id, the interactions and the
  token tables.
- `RULES.md` — principles, frame, components, colour, type, the screen → source file map, what
  the design assumed the code would need (§ 7) and what it asked to be checked (§ 8).
- `design_system/` — the tokens (`tokens/*.css`, imported by `styles.css`), the 24 primitives as
  React contracts (`components/<group>/<Name>.jsx | .d.ts | .prompt.md`, a preview card per
  group), the foundation cards (`guidelines/`) and one clickable loop (`ui_kits/forge-phone/`).
  Its `fonts/` is a link to `platform/priv/static/fonts/`, which holds the same two files.
- `screens/final-design.dc.html` — **every agreed screen**, grouped by area, each with an id
  (`18b`) and a caption. Open it in a browser; `screens/fonts/` is the same link. The README calls
  it `Final Design.dc.html`; the file is `final-design.dc.html`. `screens/final-design-text.txt` is
  its text, for grepping a caption by screen id.

**Screen ids in this note are the handoff's** (`18c`), so a rule can be checked against the
drawing it came from. Captions are part of the specification. **Where this note and the handoff
differ, this note wins** — it is the one that tracks what was decided and built. Every place it
departs from the handoff on purpose says so where it does, with the reason.

**The previous design is in git history.** The note before this rewrite — daisyUI themes, the
board, the review page, the Decide tab, the bottom bar and its More sheet, the capacity gauge —
is `docs/design/ui.md` at `92ea7c1`, and it is what the code at the start of the redesign
follows. § Where the previous sections went maps each of its section names to where its content
is now, so a citation of one in a code comment still leads somewhere. **§ Not built yet lists what
of this note the code does not do yet**; until a line leaves that list, the code follows the
previous note on that point.

## Principles

From `RULES.md` § 1:

1. **The queue is home.** The app opens on it and every queue button leads to it; everything else
   is reached from it, from the title menu, or from a link. The bottom strip of top-level pages is
   gone, which gives the queue item its height back.
2. **One decision per place.** A decision — approve, accept, merge — lives in a row pinned under
   the top bar, on the page that shows the thing being decided (§ The decision row). **The queue
   never decides; it links.** This replaces the approval card that used to be drawn in the queue,
   on the Decide tab, on the Changes tab and on the review page alike.
3. **The bottom navigates and replies.** The bottom strip switches views of the object on screen;
   the composer sends a message. Neither holds a step decision.
4. **Nothing transient takes a decision's place.** Connection state, toasts and errors never use
   the decision row.
5. **Layout never moves under a finger.** A disabled control keeps its size and place. Panels
   overlay instead of pushing. A toast floats and cannot be tapped. A button that moved ignores
   taps for 500 ms (§ The moved-button guard).
6. **Colour carries meaning, not decoration** (§ Colour).
7. **Vertical first.** Phone and portrait desktop are primary. Wide desktop adds columns; it never
   reorders (§ Three layouts).

## The affordance rule

**A border means you can tap it.** This governs every component.

- **Identifier** — states, statuses, outcomes, branches, commits, artifact names and versions:
  plain mono text, no border, no padding, no background. A state carries its mark
  (§ The three axes), which is part of the identifier and not a badge.
- **What only says has no border.** An agent's words in a chat or on the job page, a notice, a
  usage card, a commit message, a ticket's type, a `recommended` or `optional` tag, a template's
  `disabled`, a project's address, a release block: each sits on `--surface-1` or on the page, and
  a notice's attention is its 2px inset left edge in its colour (§ Space). A bordered thing that
  does nothing teaches the eye that borders lie (UX pass, A5, B6). **The context card is the
  ticket's link**: the whole card, with a trailing `›`, in place of a separate *Open game#2 ›*
  under it.
- **A filled ink button is the next step** (`variant="primary"`: ink on the page, which is white on
  dark and blue-black on light). One per region, never two adjacent: the Send of a question card,
  *Create it*, *Issue it*, the dock button that commits the ways forward a person picked.
- **An amber button is a decision waiting on you** (`variant="decision"`) — Approve, Accept — and
  it lives only in a decision row and the drop panel that row opens. It leads with `◆`.
- **An outline button navigates or is secondary** — *Review the changeset ›*, *Later*,
  *Answer first*. A `›` on it says it goes somewhere.
- **An entry point to a form is `+ <Verb> a <noun>`**, an outline, full width on a phone and its
  own width from 768 — *+ Issue a token*, *+ Make a template*, *+ Add a machine* — and **the form
  it opens has an `h2` and ends in a filled `xl` *<Verb> it***, a Cancel or Discard beside it
  where there is one (UX pass, D11).
- **An outlined red button is destructive** — Reject, Revoke, End it, Destroy machine. Every one
  sits behind a confirm (§ The confirm) or a required note. **In a list it is small** — 36px, at
  the right end of the row — and **full width only on a page about one object** (a template, a
  conversation's details, a ticket's), placed last: the act a person does least is not the
  loudest thing on a list, and a thumb scrolling Secrets does not land on Delete. Signing out
  destroys nothing and is not red.
- **A choice row selects, and never commits.** A `ChoiceRow` is a 52px row with a radio (or a
  checkbox, where several may be picked), a label and its detail beneath; a question's option, a
  way forward on a stuck ticket, a token's git scope, an outcome to accept with. It is never a
  submit. **The dock button commits what was selected**, and says what it will do. This replaces
  the old *answer row*, the one shape that committed on a single tap: a stuck ticket's way
  forward is now two gestures, pick and confirm, which is the same shape every other decision in
  the product has.
- **A segmented switch picks a value or a view**, two to four short options of equal width — a
  token's API scope, Presentation · Files · Commits. It commits nothing either.

**Enter never commits a decision.** The free text beside one — a question card's own words, the
note beside Approve, Reject or Accept — is a box Enter breaks a line in, and only the button sends.
A one-line input submits its form on Enter with the form's first button, which on an approval was
Approve: a comment ended with Enter approved the version, and an answer ended with Enter sent the
form before the questions after it were read; a radio may submit on Enter too, in some browsers,
so a question card swallows Enter from its inputs. The composer is the one box Enter sends from, on
a fine pointer (§ Talk), because there the box is the whole form. The create forms still submit on
Enter — a ticket's title, a conversation's limits, and a new conversation's first message; this
rule is written for decisions, and has not been carried to them.

Transition actions carry a verb: `Move to planning`, never `→ planning`, and no `›`: they commit where they are. Verbs name the act and,
for a decision, its result — *Approve v1*, *Accept · shaped → planning*, *Interrupt and send*,
*Accept anyway* — and never *OK*, *Submit* or *Confirm*.

**A navigation target is the whole region, not the identifier inside it.** A job row in Steps, a
ticket row in a project's Tickets, a row in the queue's All sheet: the tappable thing is the row,
at its full height, not a 20px `#3` inside it. Hunting for a small link is the failure this rule
exists to prevent, and a row that only *looks* tappable at one end is worse than one that is not
tappable at all.

**A navigation target never contains a control that commits.** This is the constraint the rule
above must not break. A region that navigates may not enclose a choice row's form, a decision
button or a Send — nesting one inside the other makes "read this" and "approve this" the same
gesture, which is exactly what the queue's shape exists to keep apart. A row that navigates may
still carry a control **beside** it — the chats list's *End* — as a sibling, never a child.

## The three axes

Three orthogonal axes must never render as three colours of one badge. They get three different
*forms*, because form survives greyscale, colour blindness and a glance. The form for all of them
is `StateLabel` — a mono word led by a mark with a fixed meaning — and its marks are § Marks.
**A workflow state's mark comes from one mapping**, `ForgeWeb.Topology.mark/1`, drawn by
`Indicators.state/1` wherever a state is a label — Steps, a project's tickets and history, a
proposal's ticket, the workflow's flow, a branch in the repository — and written by the subline and
the workflow map as text; the status words
StateLabel draws (`running`, `idle`, …) take their marks from the same mapping, so no list can
draw one state two ways. The ticket's status beside it is `Indicators.status/1`.

| Axis | Form | Rules |
|---|---|---|
| workflow state | the state's name, mono, led by its topology mark | `▸` (info) a job or command state, while something runs in it · `●` (link) a human state with outgoing transitions, and a chat step · `○` (muted) a terminal state, where nothing will happen. Never coloured by status, never abbreviated. A terminal state is not drawn `✓`: names are the project's, and the platform cannot tell a `done` from an `abandoned`. |
| ticket status | a word beside the state, never instead of it | Drawn only when not `active`. `stuck` carries its age (`stuck 19h`) **in amber, with no `△`**: a stuck ticket waits on a person, so its word, its row's edge, its queue item, its step sentence and its dot on the workflow map (a ring, to tell it from a question) are all amber. It was once in warning on the ticket and the map and amber in the queue, and the two read as one colour anyway (UX re-check #4). `cancelled` is muted. `cancelled` is muted. Never a column, never a view. |
| job outcome | bare mono, coloured, at type scale | The **declared** outcome is the largest thing on the job page. The engine outcome is demoted to smaller mono beside it, with a caption naming which is which. |
| worker reachability | a dot and a word, beside the status | Whether the platform is holding a channel to the machine *now*. Orthogonal to `status`, which is what the database last recorded — a `ready` row that is not connected is the interesting case, not a contradiction. |

**`budget_exhausted` is followed by what ran out**: `· turns`, `· tokens` or `· wall clock`,
beside the outcome and nowhere else, because the three want different responses from whoever
reads the row (`capacity.md` § Four exhaustions, three treatments). Not a second badge — two
marks of equal weight read as two outcomes — so it is mono at a lower opacity than any outcome
is drawn at, which also means **every row that draws a ceiling draws its outcome through
`outcome/1`**: on a row that wrote the outcome out as plain demoted text the two came out level.
Nothing at all for a job whose ceiling was not recorded. The same section says why a job's turns
are no longer drawn against its turn budget.

Outcome colour maps by bucket, not by string match: success → `--success`, non-completion
(`did_not_converge`, `budget_exhausted`) → `--warning`, failure (`error`, declared failures) →
`--danger`, anything unrecognised → neutral. **`did_not_converge` is not an error** — it is the
agent honestly reporting it could not finish. Declared outcomes are project-defined; the list is
never hard-coded.

## Tokens

The values are `design_system/tokens/*.css` — colours, typography, spacing, elevation, fonts —
copied into `platform/assets/css/` near verbatim: **dark on `:root`, light under
`[data-theme="light"]`**, every colour in OKLCH. No component library: no daisyUI, no Heroicons,
no icon font. Components are HEEx function components ported from the primitives' contracts
(§ Components). A colour is never hard-coded in a template; it is a token or it is not drawn.

### Colour

**Neutrals** are a cool violet-grey (hue 300) on dark, stepping about two points of lightness per
surface: `--bg` 15.5 %, `--surface-1` 17.5 %, `--surface-2` 19.5 %, `--surface-3` 22 %, `--border`
24.5 %. Text is `--ink` and three lower opacities, `--ink-2` 75 %, `--ink-3` 55 %, `--ink-4` 40 %;
a meter's empty part is `--track`, ink at 10 %.

**`--border` is for rules nobody taps; `--border-control` is for things that can be tapped.**
`--border` against `--bg` is about 1.2:1 on dark and 1.4:1 on light — right for the line between
two rows, and invisible as the one signal that a secondary button, an unselected choice row, a
field, a segmented switch or the context button can be pressed (UX pass, A4). Those take
`--border-control`, which is `--border-strong` (about 2:1 on either theme).

**Each colour means one thing.** Discipline matters more than the values:

| Token | Means | And nothing else |
|---|---|---|
| `--accent` (amber), `--accent-text` | **a human is being waited on**: the queue button while its count is above zero, a decision button and its row's edge, the current step of a workflow track **on a ticket that waits on a person** (a queue item's card, a waiting row's ticks, the step dot of a stuck ticket or one with a decision row), the queue's progress, a projects row's waiting count, a waiting state's mark, **stuck** wherever it is said, and a document's `◇ unapproved` | Its value is entirely its scarcity. The current step of a ticket that waits on nobody is ink — `--info` for the step dot while something runs in it — never amber. The usage lines are never amber (§ Usage), nor is the `recommended` tag on an option, nor a selected choice, nor a warning. |
| `--info` (blue) | running: `▸`, an agent's actions in a transcript, the live job chip | |
| `--success` (green) | passed, added, connected, the end of the queue | |
| `--warning` (yellow) | near a limit, outdated, expiring, non-completion outcomes, a stalled job, memory trouble (`capacity.md` § Memory), a template's slots when full | Waits on nobody, so **it is its own hue**: yellow at 100 (`89% .13 100` on dark, an olive `52% .11 100` on light), 38° from the accent and lighter than it. The handoff drew it as a paler tone of the accent's own hue — on light the very same value as `--accent-text` — and told the two apart only by where they were drawn; at a glance, on a phone, they were one colour, and every lapse and near-limit read as "waits on you" (UX pass, A21, D1). **Every warning-coloured word leads with `△`** in the same colour — a row's latest line, a warning notice's title, anything set in `text-warning`, a token's expiry, a secret nothing receives, a usage pace, a memory line, a non-completion outcome — so it survives greyscale and colour blindness as the three axes do; at 12px mono in the dark theme hue alone did not tell it from amber (UX re-check #5). The rule is one selector list in `components.css`. A figure on a gauge — a usage percentage, the header's digits — is a scale and carries none. A shown-once secret (*Copy it now*) is a warning notice, not amber: nothing waits on you there. Never a filled button, a decision row's edge, a waiting count or the queue button, which are amber's alone. |
| `--danger` (red) | failed, removed, disconnected, destructive | |
| `--link` (violet) | links, a selected choice, a human state's `●` | |
| `--doc` (cyan) | a document's kind icon | |

The `--*-wash` and `--*-line` variants are the same colour at low opacity for a band's ground and
edge; they mean what their colour means.

**File type hues** tint the tile an artifact's kind sits in, and nothing else (§ Artifact types).
They are kept at least 25° from every hue above, so a type never reads as a state, an outcome or a
wait: 210 Markdown, 175 code and data, 340 an image, 315 an archive, 125 an Android app (an
archive was 95 until the warning took that hue, which is now 100). None is more
saturated than the accent, so a tile is never the loudest thing on a page. Text, a log, the
changeset and any other file are neutral, told apart by their glyph.

**Syntax colours are low-chroma** — keyword 320, module 200, function 260, string 110, atom 175,
attribute and number 345, chroma 0.08 at most, comment ink at 45 % in italic — so code never reads
as status (§ The project's repository says why it is coloured at all).

**The light theme** (`21i`, `21j`) is not the dark one inverted. Its neutrals are cool, a faint
blue-grey around hue 245–255, so the warm accent stands apart from the page. Every accent gets a
light-specific value: amber as a fill is brighter and yellower (80 % 0.155 72) and as text a deep
orange (56 % 0.160 52); red, green, blue and violet are deeper; the filled button is a blue-black
ink. **The toast stays dark on light**, so it still reads as something passing. The theme is the
existing three-way switch — system, light, dark — which writes `data-theme` on `<html>`; it is
on the You page (§ You).

### Type

Instrument Sans for language, JetBrains Mono for identifiers. Both are OFL, variable woff2,
self-hosted from `platform/priv/static/fonts/` with `font-display: swap`; there is no webfont CDN
and the product must build without egress. The design depends on the sans/mono *distinction*, not
on these two faces — the system stack is a supported fallback. **Mono ligatures are off**
(`font-variant-ligatures: none`) wherever code is drawn.

| Role | Size, weight | Used for |
|---|---|---|
| eyebrow | 10.5 mono, uppercase, +0.14 em, 55 % | the one label heading a group; never two adjacent |
| meta | 11.5 mono | a top bar's subline, a row's identifiers, a decision row's meta |
| small | 12.5 | secondary prose, hints |
| UI | 13.5; tab 13 | controls, tabs |
| body | 14.5 / 1.6 | prose, documents, captions; never below 14 on a phone |
| title | 15 / 600 / −0.02 em | the top bar's title |
| panel | 16 / 600 | a drop panel's or sheet's title |
| queue sentence | 19 / 500 / −0.01 em / 1.3 | the one sentence per queue item stating what is asked |
| desktop h1 | 20–22 / 600 / −0.02 to −0.025 em | the desktop title row |

**Mono is for things the system named**: workflow states, ticket and job statuses, outcomes,
artifact names and versions, branches, commit shas, session ids, environments, capacity, counts,
durations, ages, transition targets, sublines, eyebrows.

**Mono is never for things a person wrote or reads as language**: ticket titles, question text,
option labels, anchor quotations, explanatory sentences, empty-state copy, verb button labels.

**A count says its noun in the plural but for one** (`Format.counted/2`: `1 turn`, `3 turns`), and
**a figure that says nothing is left out**: a ticket that has spent nothing carries no `0 windows`
fact, and usage with no reported figure is no row rather than `5h — · week —` (UX pass, A11,
B19). **An identifier inside an eyebrow keeps its case** (`<span class="ui-id">`): an eyebrow is
upper case by CSS, and a branch `Fix/HUD` or a sha drawn in capitals is neither readable nor what
the system named. **A URL or a path breaks only after `/` or `:`**
(`Operator.Components.breakable/1`), never inside `.git`.

**Copy** is the handoff's wording, sentence case everywhere (an eyebrow is upper case by CSS, not
in its text), second person to the reader and third about the agent, no emoji and no exclamation
marks. Where a drawn string names data — a model, a price, a provider's name — the real value fills
it, and **where the platform has no real value the string is left out rather than invented**: no
model the platform did not record, no price in a currency the provider did not report.

### Space, sizes and targets

- **Bars** (phone): the 5-hour line 3, top bar 52, week line 2, decision row 60, composer 64,
  bottom strip 56. Desktop: header 56, decision row 56.
- **Controls**: 52 a primary action and a choice row, 48 a field and a secondary action, 42 the
  decision row's button, 40 a strip tab, 36 a row action (Copy), 34 and 28 at desk size. **Every
  phone target is at least 44px** — a link alone in a line of text too (*The whole job ›*,
  *Details ›*, *Repository ›*), which grows to the height with its text where it was; the old 46px floor and its *no `btn-sm`* rule are replaced by
  these sizes, which are the handoff's.
- **Spacing steps** 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 30, 40. Gutters 20 on a phone and 30 on a
  desktop. **Reading measure 680–820px** for prose, a transcript, a presentation.
- **Radii**: 4 a badge, 5 a desktop control, 6 a button, field or row, 8 a card or notice, 14 the
  outer corners of a sheet or drop panel, a pill for the queue button, a count bubble, a toast and
  the composer's field.
- **Elevation is almost none.** Shadows only on what floats or pins: the decision row (a short
  downward shadow), drop panels and sheets, toasts. Scrims are a 60–70 % dark overlay, no blur.
  Structure is 1px rules, not cards.
- **Selection and attention** are a 2px inset left edge: ink for selected, amber for waiting on
  you, red for broken. Never a coloured border on a rounded card.

### Marks

State is carried by Unicode marks with fixed meanings, never by an icon set:

| Mark | Means |
|---|---|
| `◆` | waits on you (amber); leads a decision button |
| `▸` | running (info); also a folded row's disclosure, turned when open |
| `●` | a workflow step or state |
| `✓` | done, passed |
| `✗` | failed |
| `◇` | a document an approval waits on, where approval is possible (§ Semantics that must not be lost) |
| `○` | idle, terminal |
| `›` | navigates — drawn on a link and never on a button that commits in place: not on *Send*, a dock's commit, *Admit* or *Start the release*, nor on an action such as `+ New` that opens where it is (`button/1` draws it on a link only) |
| `▾` `▴` | a menu or details, closed and open |
| `‹` | back to the queue, on the queue button |

Two inline stroke SVGs exist, at 1.5–1.6px with round caps: the queue's inbox and the composer's
send arrow. **Object kinds** are a 26px tile tinted at 16 % of the kind's colour with a mono glyph —
`md` a document, `±` a changeset, `⑂` a branch, `⇡` a release — which is the `TypeIcon`
primitive (the handoff's `⌁` has nothing to name: a failure is never a toast nor a row of its own); an artifact's file type is drawn through the same tile (§ Artifact types).
The logo (`design_system/assets/forge-logo.svg`) is drawn on sign-in only; the desktop header is the
plain wordmark `forge` with the version beside it.

## Components

The 24 primitives of `design_system/components/`, ported as HEEx function components. Each keeps
its contract's attributes and states; the `.prompt.md` beside each says when to use it.

| Group | Primitives |
|---|---|
| actions | `Button` — `primary`, `decision`, `outline`, `danger`; sizes; `fill`; a trailing `›`; a leading `◆` on a decision |
| navigation | `TopBar`, `QueueButton`, `UsageLine`, `BottomStrip` |
| decisions | `DecisionRow`, `DropPanel` |
| forms | `Field` (label above, hint or error below, `mono`), `Segmented`, `ChoiceRow`, `Stepper`, `Composer` |
| data | `ContextCard`, `ListRow`, `WorkflowTrack`, `StateLabel`, `DiffStat`, `TypeIcon`, `CountBubble`, `Eyebrow`, `FactList` |
| feedback | `Notice`, `Toast`, `Sheet` |

**Disabled keeps size and place**: the same element, never hidden. An outline or quiet button
goes to 45 % opacity; a filled one — primary or decision — is drawn on `--surface-3` with
`--ink-4` text instead, because a filled ink slab at 45 % reads as a working grey button and a
washed amber one as a pressed decision (UX pass, A20, B20). **The selected segment** of a
segmented switch is `--surface-3` with a 1px `--border-strong` ring and full ink, the others
`--ink-2`; each option is padded 10px either side, so a switch sized to its content never runs
its labels together. **A select** draws no native arrow: a `▾` in `--ink-3` on a field's border,
and `accent-color` is ink on `:root`, so no control falls back to the browser's blue.

**The workflow track** draws its labels from 768px up in the content column. On a phone and in
the wide context column it draws its segments alone — each carries its state's name as a
`title` — because six labels in 350px cut every one of them, the current one included, and the
facts line beside it already names the state. **Hover** on a
desktop is `--surface-2`; **pressed** does not shrink; **selected** is `--surface-2` with a violet
border on a choice, or the inset ink edge on a row. **Motion** is 120–220 ms on
`cubic-bezier(.2,.7,.2,1)`: panels drop or rise, toasts fade. Nothing pulses and nothing spins;
running is `▸` and words.

**A count bubble is grey.** It is amber only where what it counts waits on the reader — the queue
button's count, a projects row's waiting count — and a view's count in the strip is never amber.

**Where they live.** `ForgeWeb.UI.Navigation`, `.Decisions`, `.Forms`, `.Data` and `.Feedback`
(`platform/lib/forge_web/components/ui/`), imported into every LiveView and component; their
styles are `assets/css/components.css`, one `ui-*` class per part, in Tailwind's components layer
so a caller's utility still wins. Two primitives keep older names because seventy-odd call sites
use them: `Button` is `CoreComponents.button/1` and `Field` is `CoreComponents.input/1`. What the
port says that the contracts do not:

- **`button/1` defaults to `secondary` at `lg`** (48), not the contract's `primary` at `xl`: every
  call site written before the primitives passed no variant and meant a bordered button, and
  filling them all would put two filled buttons side by side. A page names its variant and size.
- **A choice, a segment and the stepper are real form inputs** — a radio, a checkbox, a number —
  so a form's `phx-change` sees them and a reconnect restores them (§ A reconnect is not a
  reload). A choice row and a segment draw *selected* from the input's own `:checked`, so they
  answer before the server does. The stepper's − and + step the number in the browser and fire
  `input` (`forge:step` in `app.js`), the one script a primitive adds.
- **The composer is a textarea**, not the contract's one-line input, growing to six lines,
  with the Enter rules of § Talk and § The affordance rule in its own hook — which
  `Conversations.message_box/1` reads too, until the chat screens are drawn with the composer.
- **The context card's ticket reference is `ref`**, since `id` is the element's.
- **A field keeps 8px below itself**, which the contract does not draw, because the forms written
  before the primitives stack fields without a gap of their own.
- **A usage line with no figure** keeps its band and draws neither track nor fill (`capacity.md`
  § Two objects).

## The frame

**Every signed-in page is drawn in one frame**, from one layout, so that a queue count, a usage
line or a lost connection is drawn the same way and in the same place everywhere. The frame is
`Layouts.app/1`, which every LiveView renders first, fed by one `on_mount` that reads what it
draws — the queue count, the usage lines, the waiting accounts a node admin's count includes — and
keeps them current: it hears queue changes on a topic tagged with the project, matches the
project against the viewer's own before reading anything (CLAUDE.md § Rules), and recounts at
most once a second. A change is announced there only when it can change somebody's queue: a
ticket's, a conversation's state or a person's message, and of a reply streaming in, only the
block that makes the conversation wait on its person — not every block after it, which would have
every open page rebuild its queue for each sentence a chat says. The root template, which is
rendered once per HTTP request and never patched, draws none of it. Sign-in screens are drawn in
a frame of their own with no usage lines and no
queue (§ Signing in).

### The phone

Width reference 412px. Top to bottom, every band a fixed height except the content:

| Band | Height | Holds |
|---|---|---|
| 5-hour usage line | 3 | § Usage. Tappable: opens the usage panel. |
| Top bar | 52 | Left, **the queue button**: a 34px pill in a 46px target, `‹`, the inbox icon and the mono count; amber while the count is above zero, quiet at zero; **always goes to the queue**, never back. Middle, **the title** (15/600, cut with an ellipsis) over **the subline** (mono 11.5: the object's number, state and status). Right, **the context button**: the object's parent by name, `game ›`, bordered — or on a project's own page, `+ New` (§ The project page). |
| Week usage line | 2 | Replaces the top bar's bottom border. Tappable, as above. |
| Decision row | 60, when there is one | § The decision row. Shares the top bar's surface and shadow. |
| Content | the rest | The page's only scroller. An optional split pane for questions (§ The question card). |
| Composer | 64, when there is one | § Talk. |
| Bottom strip | 56, when the object has views | § The bottom strip. |

**The frame fills the viewport exactly.** `100dvh`, less nothing: fixed bands and one scroller,
so the composer is never below the fold and the strip never scrolls away. The composer and the
strip sit above the safe-area inset. The viewport declares `interactive-widget=resizes-content`,
and a hook sizes the frame from `visualViewport` where the browser ignores that, so the on-screen
keyboard pushes the composer up rather than covering it. When the frame is shorter than everything
fixed in it, the content is what gives way, never the composer.

**Both ends of the top bar always mean the same thing** (`5j`): left is the queue, right is the
parent object — or, on a page with no parent, its one action: a project's `+ New`, and the queue's
**All N**, which opens the All sheet and so spends no row of its own above the item (UX pass, A1).
An action draws no `›`. On the queue, which has no queue button, the title starts at the 20px
gutter, so the page has one left edge. There is no back arrow — moving to the next thing goes through the queue, and
moving up goes through the parent — and back *within* a page is a back row at the top of its
content (`‹ Settings`).

**The title is a control.** On a top-level page it is a switch, `Queue ▾`, that drops the title
menu (§ The title menu). On every other page it drops the object's details (§ Drop panels): a
ticket's facts and lifecycle (`6d`), a chat's (`15e`), a project's (`7f`). The title shows `▴`
while its panel is open.

**Top-level pages** are Queue, Projects, Chats, Machines, and Usage. Their title is the switch, and
they draw no strip — but for Machines, whose three views (Machines · Templates · Credentials) are one
top-level place with a strip of its own (`12f`, `14a`; § The bottom strip). The queue's top bar draws no queue button — it is the queue — and the others keep
it on the left (`19c`).

### Three layouts

| Layout | Width | Arrangement |
|---|---|---|
| phone | below 768px | § The phone. |
| portrait | 768–1439px | The desktop header and title row, then **the same blocks stacked in the phone's order**. An object's strip views become the title row's tabs. |
| wide | 1440px and up | The header and title row, then columns: **a list column of 320–360px on the left and/or a context column of 360–440px on the right**, the content between them at its reading measure. |

**What sits under the content belongs to its column.** The composer, the queue's question card
and its Later · Send dock, a ticket's dock and an empty page's one button are drawn in the content
column, at the page's measure and centred with it — sticky at the foot of the scroller, so they
never scroll away — and on a wide screen they stop where the list and context columns begin,
which then run the window's full height. Drawn across the window they sat 30px off every edge of
the content they answered, a commit button 700px from the choices it committed, and a list
column cut off after two items (UX pass, A2, B1, C18). **The content column is centred on every
page**, and a page that asks for all of the width (`measure={nil}`) still stops at 90rem. **Every
view of a ticket reads in one centred column** — Changes included, below 1440px, where it used to
sit at the gutter while Steps and Docs were centred, so switching views moved the text sideways;
from 1440px the presentation beside the file it follows is the one exception. An agent's prose
stops at 68 characters a line.

**The order is never changed** — wide adds columns, it never moves a block above another — so a
person who knows the phone's page knows the desktop's. Every page has a wide and a portrait
arrangement; the handoff draws them for the queue (`13f`, `13g`), a chat step (`16h`, `16i`),
Changes (`19g`, `18f`), the job (`21a`, `21b`), a chat (`15f`), a project (`7g`, `7h`), proposals
(`8e`, `8g`), the repository (`10f`), the projects page (`11e`), settings (`9i`, `21h`), machines
and templates (`12o`, `14f`) and usage (`23b`), and the rest are extrapolated from those by the
rule above.

**The desktop header** is 56px: the wordmark `forge` with the platform's version in muted mono
beside it, the title menu's switch, Queue with its count, the usage digits (§ Usage), and the
account by its address's local part (the whole address is its title). **The switch names the
section the page is in** — the top-level page's own title; Chats on a chat; Machines on a machine;
Accounts and You on theirs; Projects on a ticket, a project, its repository and its settings; Menu
on not found — where it once said *Projects ▾* on every inner page, a chat and the 404 included
(UX pass, A6). The queue's list column heads itself with its count alone, not a fourth *Queue*. **The version** is the application's own, which every `mix.exs` reads from `VERSION`, so
it is the release the node is actually running: the first thing to say when reporting something,
and the way to see that a deploy took. On a phone it is the last line of the title menu. It is
drawn for a signed-in account only: the sign-in page tells nobody which release is running.

**The title row** carries a back link in mono 12, the page's h1, the state, and the view tabs
(32px) on the right — the same list the phone's strip draws, from one definition. **On a page
with no list or context column it takes the body's measure and centring**, so the title starts
where the content does rather than at the window's gutter above a centred body (UX re-check #16);
beside a list column it stays at the gutter, over the list. The decision
row on a desktop is 56px and spans the window under it; its button is 34px.

### The title menu

`19b`. Tapping a top-level page's title drops the menu from the top bar over a dimmed page. Each
destination carries its state, so the menu doubles as an overview:

- **Queue** — the decisions waiting, in amber while there are any.
- **Projects** — how many, and how many wait on you: *2 projects · 1 waits on you*.
- **Chats** — how many are live, and how many there are: *▸ 1 live of 2*.
- **Machines** — busy and idle; *none yet* rather than *0 busy · 0 idle*.
- **Usage** — the two windows (§ Usage), or *no figures yet*. **This row opens the usage panel**
  in the menu's place rather than going to `/usage` (the panel's *Details ›* does): on a phone the
  two usage lines are display-only — 3px and 2px at the screen's edge are no target — and this is
  the way in. With a fine pointer the lines stay clickable, each reaching 6px further into the
  page.
- At its foot: the account (its address, leading to You), and for a node admin **Accounts** with
  the number waiting (§ Accounts). The version is the last line.

**What each destination says is read when the menu opens, not on every page's mount**: the frame
draws the title, and the per-destination figures cost a read only for the person who asked to
see them. They are scoped as the pages they lead to are — the projects counted are the viewer's.
Tapping outside, the title again, or the handle at the panel's foot folds it.

**This replaces the nav row, the bottom bar and the More sheet.** The objection that once forbade
a menu — *no hamburger at any width* — was to hiding the product's places behind a control, and
it held for the places that matter most. They are still one tap away: the queue is the left end of
every top bar, the parent object the right end, and the menu names every top-level place with its
state, which a row of nav labels never did.

### Drop panels

**The one overlay pattern.** The title menu (`19b`), an object's details from its title (`6d`,
`15e`, `7f`), a decision's confirmation (`16g`, `18c`) and the usage panel (`22e`) are all one
component: a panel that drops from the bar it belongs to, full width on a phone and anchored to its
trigger on a desktop, over a 60 % scrim, with the 14px radius on its outer corners and a handle at
its foot. **Nothing below it moves.** A tap outside, the trigger again, or the handle folds it;
Escape does on a keyboard.

A drop panel that holds a form — a decision's note, a release's note — holds it in a form with an
`id` and a `phx-change` (§ A reconnect is not a reload), and **its errors are drawn inside it**
(§ Errors stay where you acted).

### Sheets

**From the bottom, only for things opened from the bottom**: the project's `+ New` (`21c`), the
queue's *All* (`13e`), a repository's branch picker (`10b`). A native `<dialog>` drawn as a bottom sheet, opened with `showModal()` from a
dispatched event and closed by Escape, a tap on the backdrop, or navigating; focus and inertness
come from the element rather than from code. **It opens with the focus on the sheet itself**
(`autofocus` on it, out of the tab order), not its first row, which opened wearing the focus ring
as if already chosen.

### The confirm

**A second look is asked in place, never by the browser.** `ForgeWeb.UI.Decisions.confirm/1`
draws the trigger; tapped, it gives way to the sentence that says what will happen and two
buttons named for the act — *Keep it* (outline) and *Revoke it*, *Destroy it*, *Take it out*
(outlined red) — on the red wash with a 2px red edge, under the row it is about. Nothing else
moves, it opens and folds in the browser with no round trip, and it stays open across the page's
patches. The button that acts is the one carrying the event; the trigger sends nothing. A weighty
act that destroys nothing — re-pinning a ticket, sending it on, granting admin — asks the same
way in the neutral tone.

It replaced `data-confirm` and the browser's `window.confirm` at nineteen sites (UX pass, D3): *OK
/ Cancel*, against § The affordance rule's verbs; unthemed; a system alert detached from the row on
a phone; and one Chrome lets a person switch off for the rest of the page, after which every
Destroy ran on one tap. A test reads the web layer's source and fails on a `data-confirm`.

What asks: revoking a token or a credential, deleting a secret or a waiting account, removing a
member, a mirror, a template or a provider credential, destroying or retiring a machine, ending a
conversation, cancelling a ticket, taking one out of the merge queue, suspending an account,
making someone a node admin or a project admin, making yourself a project member, re-pinning a
ticket and sending one on from a merge conflict.

### The decision row

`16f`, `18b`, `18d`, `18e`. **Every approve, accept and merge in the product is a decision row
and the drop panel it opens**, and nowhere else: a ticket's changeset approval, a document
approval, a chat step's Accept, a chat's merge.

- **It appears only once the decision exists** — a chat step's Accept after the step's document
  has its first version (`16e` → `16f`), an approval once the ticket waits on one — and leaves when
  the decision is made. One row at a time.
- **It is pinned**: under the top bar on a phone and under the title row on a desktop, never
  scrolling away, and **on every view of the object** — Steps, Changes, Docs, Activity — so a
  person can read any of them and decide from where they are.
- **It is four things in a line**: the kind's tile (`±`, `md`), the object in mono with its key
  facts (`changeset v1 +48 −6`, `brief.md v2 · 3m`), a meta line in mono 11 (`✓ check 21s ·
  review → merging`), and the button.
- **Amber when it waits on you** — Approve, Accept — with a 2px amber inset edge. **Neutral when it
  does not** — a chat's merge, which nobody is waiting on (`18e`) — with a 50 % ink edge and an
  outline button. The edge is the button's colour.
- **A transient state never takes its place** (Principle 4).

**Its button drops the confirmation panel from the row** (`16g`, `18c`). The panel says, in this
order: what happens and where the ticket goes; what it pins or commits — the commit message
read-only (§ Changes), the documents and their versions; any warning; then **the secondary act and
the primary**, the primary in the trigger's colour. Cancel, or a tap outside, folds it, and
nothing underneath has moved.

| Decision | The panel's secondary | The panel's primary |
|---|---|---|
| A changeset approval | Reject (outline red), with a **required** note | Approve v1 (amber) |
| A document approval | Reject, with a required note | Approve (amber) |
| A chat step's Accept | Answer first, when questions are open | Accept, or Accept anyway (amber) |
| A chat's merge | Cancel | Merge (outline) |

**A reject needs a note** (`18c`), and Reject is disabled until the note holds something other
than whitespace. The rule is the operation's and not the page's: `Engine.decide/4` refuses a
rejection whose comment is missing or blank with `{:error, :note_required}` before anything is
written, so the API, `mix forge.approve`, a chat's request and the page all meet it, and a
request that reaches the server past a disabled button is refused inside the panel. **The note is
kept and handed on**: it is the decision's comment, Activity draws it with the rejection, and the
next job on the ticket reads it in `entered.comment` the way it reads a person's comment on a
transition (`job-prompt.md` § How the job arrived).

**What the panel holds is the decision's it was opened on.** When the decision on screen is
replaced — decided by someone else, rejected and written again as a newer version, a later visit
of the step, new commits on the chat's branch — the panel folds and drops its note and its pick, so
a new decision never arrives open under a finger with words written about the one before. **A
press names what it was pressed on**: Approve and Reject carry the edge and the versions the panel
drew, and a press on an approval that is no longer what waits does nothing and is refused in words
where the person acted — in the panel of what waits now, or, when nothing does, in place of the
row until it is dismissed (`ForgeWeb.Operator.Decision`).

**A merge approval shows what it merges from.** `decisions.md` puts the documents the change was
built from, the questions answered and the cost beside the merge approval; they are under Files in
the Changes view (§ Changes) and in the approval's panel, above the commit message. In the panel
*built from* is one version a line, each linked to the version it names — joined into one string it
was the one fact a reviewer could not read, cut by an ellipsis — and *spent* is left out while the
ticket has spent nothing.

**Open questions are never answerable inside the panel.** Accepting a chat step with questions
open warns *N open questions will stay unanswered*, names them, and says what the next state
starts from; its secondary is *Answer first*, which folds the panel and opens the question card
(`16g`). Answers never count once the step is accepted, so the panel does not pretend they might.

### The bottom strip

`BottomStrip`: the views of the object on screen, equal-width 40px tabs, the active one on `--bg`
with a border and weight 500, a grey count bubble where a count means something. **A count of zero
is drawn muted, never hidden, so tabs never move.** At most five. **It only navigates**: a new
view of an object is a new tab, never a special button, and no decision is ever in it. The view
is in the URL (`?tab=changes`, by patch) so back, reload and a pushed link land on it; an unknown
view falls back to the object's default.

| Object | Views |
|---|---|
| a ticket | Steps · Changes · Docs · Activity, and Talk while it has a live or step conversation |
| a chat | Talk · Changes · Docs · Activity |
| a project, its repository and its settings | Tickets · Merge · Chats · Workflow · Proposals |
| machines | Machines · Templates · Credentials |

**A job takes the ticket's strip** (§ The job page), and a chat step the ticket's (§ The Accept
area): their own views are a segmented switch in the content, because the strip's tabs already
belong to the ticket. Each object's list is one builder: `TicketViews.strip/5`, with its counts read the
ticket's way by `strip_of/4` on a job's page and a step's conversation; `ProjectLive.strip/3`, whose
counts only the project's own page draws — its repository, a commit and its settings draw none
rather than a figure they did not read; and `WorkersLive.views/0`.

## Transient states

`20a`–`20d`. **Nothing transient takes a decision's place, and nothing transient moves the
layout.**

### Toasts

`20b`. After an action succeeds: a 372px pill floating 84–90px above the bottom, `--toast-bg`,
an icon and two lines — what happened and what it started (*Approved refinement.md v1 · planning
started*), read from the ticket after the move: *in the merge queue* where it waits its turn
there, *merged into main* where entering the state merged it, and *moved to `<state>`* only where
nothing starts — **no button, `pointer-events: none`**, so it can vanish under a finger without harm.
It fades after `--toast-life`, 4 seconds; **one at a time**, the newest replacing the last. It is
drawn from the `:info` flash. By the time it shows, the row it confirms has already gone, because
the decision was made.

### Errors stay where you acted

`20d`. **A failure is never a toast**: it needs a response, and a toast cannot hold one safely.
The error is drawn inside the drop panel or under the field the person acted from, in red, in the
server's words, with the next step as a button in that same place, and it stays until it is
closed or the cause is fixed. An error with no panel — a send that failed in a chat — is drawn
under the message it belongs to. A refusal that has a form keeps what was typed (§ A reconnect is
not a reload covers the drafts).

**The frame draws no failure at all**, so there is no `:error` flash to fall back on: a refusal
is the page's own state, drawn by `error_note` (`ForgeWeb.UI.Feedback`) where it belongs — every
refusal in place is that one component, one red at one size, and a test reads the web layer's
templates with LiveView's own tokenizer and fails on one drawn by hand: a plain element that says
it is an alert, or that is coloured danger and shows an assign whose name ends in `error` (the
sign-in page's titled refusal, `21n`, is the one other). The operator's shared events (`ForgeWeb.Operator.Actions`) leave the event refused and its words in
`:refusal`, and each place that sends one draws it for its own events (`Actions.refused/1`): the
details for re-pin, integrate, cancel and restore; the ways forward for running again and moving
on, on the ticket and in the queue; the merge queue for *Take out*; a question card's foot for its
Send. A page's own refusals sit by their button — an account's row, a machine's row, the push
switch on the queue and on You, End and Reopen in a chat. A refusal that comes back to the sign-in
page across a redirect — a dead link, a provider that failed, a session that ran out — carries
the `:sign_in_error` flash, which only that page reads and draws under its field; a provider's own
registered refusal carries `:oidc_refusal` instead, drawn titled above its button (`21n`). Both
are the sign-in page's alone (§ Signing in).
A test reads the source and fails on any `put_flash` with `:error` under `lib/forge_web`.

### Connection state

`20a`. **Losing the connection adds no row and no button. The top bar itself changes**: a red
hatched ground, a 2px red rule along its top, the title *Not connected* beside a crossed-out
signal, and the subline counting down to the automatic retry and saying when the page last heard
anything. There is nothing to press. The bar keeps its 52px. **Everything that would send
something greys out in place**, keeping its size and position — a sender is marked as one, and
CSS greys it while the bar is red. A sender is a button with a server `phx-click` (not one
holding JS commands only), a submit button of a `phx-submit` form — inside it, or outside it and
naming it with `form=` — or anything marked `data-sends`; it is disabled where it stands and
enabled again on the way back. The state is `data-connection` on `<html>`, set by the
`Connection` hook (`assets/js/connection.js`) from
LiveView's `phx-disconnected` and `phx-connected` on the frame's top, after LiveView's own
half-second grace; the countdown is to the socket's next try, whose intervals that file gives
(250 ms, 1 s, 2 s, then every 5 s). On a desktop the header is the bar, and says *Not connected*
after the release. The page-loading bar does not run for a lost connection. When the connection returns the bar shows green briefly and
then the page's title again, and nothing has moved.

This replaces the framework's reconnect banner, and what it promises is the same as before:
§ A reconnect is not a reload says what survives the rejoin.

### The moved-button guard

**A button whose position changed in the last 500 ms ignores taps.** A row that left above it, a
panel that folded, a list that recounted: each moves what is under a finger at the moment it
lands, and a tap meant for *Later* lands on *Approve*. The guard records where every visible
button was, and a click on one that moved within the window is swallowed. It is in the client,
because only the client knows where a thing was drawn (`assets/js/moved_guard.js`). The place is
the layout's, not the screen's, so scrolling arms nothing; a button seen for the first time is not
armed, and a click from the keyboard is aimed by focus and never swallowed. The window is the
`--moved-guard` token.

### Focus

Every interactive element shows a **2px `--link` outline with a 2px offset** when focused from the
keyboard (`:focus-visible`). The handoff does not draw it and asks for it.

### Not found

`20c`. **The frame stays**, so the queue button still works. The page names what was asked for in
the app's own terms — *game#47*, *the project `game`* — gives the likeliest reasons, and offers the
two places worth going. **A project the viewer is not a member of gets exactly this page**, the
same as a project that does not exist (`identity.md` § Projects and members): the handoff's
*Not allowed* variant (*You aren't in game*) says the project exists, which is what a non-member
may not learn, so it is not built. The not-allowed wording is for `/accounts` reached by someone
who is not a node admin, the one page whose existence is not a secret. The removed `/board` and
`/tickets/:project/:number/review` land here, each saying where it went.

It is the endpoint's error page (`ForgeWeb.ErrorHTML`, the words `ForgeWeb.NotFound`), so one
page answers both an address no route matches and a row a page could not find — which a project
the viewer is not in is, by `ForgeWeb.Access`. Membership is decided first, by the same check the
pages are guarded by, and nothing inside the project is read until it says yes: a member is told
the ticket range, a non-member only that there is no such project, in the words a project that
does not exist gets. It is drawn without a socket, since nothing on it changes, so the title menu
on a desktop's header does not open there; the links all work. Signed out or not yet approved, it
is the sign-in screens' page, which says nothing about the node. `/accounts` for an account that
is not a node admin's raises `ForgeWeb.NotAllowed`, a `403` drawn the same way.

## Motion and structure

Motion is minimal and respects `prefers-reduced-motion`. **Nothing pulses and nothing is
decorative.** No spinner that conveys nothing, no shimmer, no animation that exists to look busy.

**Live output is allowed where a person is looking at the work.** This reverses a rule that said
otherwise — see the note below — so: a conversation streams its reply and its tool calls as they
arrive, and a ticket's running job streams its activity to the ticket's page and to its job page.
None of them auto-scrolls away from something you are reading; a view that has been scrolled up
stays there and says how much arrived beneath. Nor does a patch close what the reader opened: a
long line expanded, an edit's diff, a folded run, the plan — each `<details>` keeps its `open`
while what is around it streams (`ForgeWeb.Actions.keep_open/0`), and a stream's rows are keyed by
their event, so the row opened is still that event's when a newer one is drawn above it.

**Output that accumulates scrolls inside itself rather than growing the page.** A conversation's
messages and a job's stream are bounded panes, because a page that grows downwards moves the box
you type in further away with every reply, and puts the thing you are waiting for below the fold
you are already at.

Which end is pinned follows which end is new. A conversation arrives at the bottom, so it is
pinned there while you are there, still when you are not, and it says how many messages are
beneath. A job's stream on its Activity view is newest first and needs no pinning: what arrives
appears at the top, where the reader already is. The job page's transcript reads in order, newest
at the bottom (`21a`), and is pinned as a conversation is.

Where nobody is looking at the work, nothing streams. The queue does not rearrange itself under a
thumb (§ The queue), a list of tickets redraws a row when it changes and animates nothing, and a
finished job's stream is paged, headed by its completion state and entry count. Live is a property
of a page about *one* piece of work that the operator opened, never of a list of many.

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
nobody, and no list or queue ever streams, so the budget the rule protected is still protected.

## Semantics that must not be lost

Getting these wrong makes the UI lie. They are acceptance criteria, not preferences.

- Approval attaches to an **exact artifact version**. Never imply "approve whatever is latest";
  the word "latest" appears nowhere in the product — bar one exception: `@latest` in a reference
  from Markdown to an artifact (§ Documents → References), which still draws a numbered address.
  There is no artifact chip without a version.
- **Approval state is shown only where approval is possible.** An artifact no transition in the
  pinned workflow lists in `approve:` is never marked waiting for approval (`◇`), because nothing
  will ever approve it and a warning the operator cannot act on is a lie about the state of the
  work. A workflow with no approvals at all therefore shows no approval marks anywhere. This is
  the same reasoning that gives presentations no approval slot, applied to the workflow rather
  than to the artifact's kind.
- **Approve, accept and merge live only in a decision row** (§ The decision row). Not in the queue,
  not in the strip, not in the composer's row, not at the foot of a diff.
- **The queue links to a decision and never takes one.** Its approval item's way on is *Review the
  changeset ›*, an outline link to the ticket's Changes view, where the row is.
- **A reject needs a note**, refused by the operation when blank, kept with the decision, drawn in
  Activity, and handed to the next job (§ The decision row).
- **Blocking and non-blocking questions are different.** One has halted a job. Only blocking ones
  are pushed to the phone; non-blocking ones sit under *Not waiting on you* at the end of the
  queue's pass, and are counted in the daily digest push apart from what is waiting
  (§ Not waiting on you).
- **`stuck` is a status, not a state.** A stuck ticket is still in its workflow state, and stuck is
  drawn on the step rather than as a step.
- **Free text is always a valid answer**, alongside any options — a real field in every question,
  never an escape hatch behind a link. Beside a chosen option it is a note on it; alone it is the
  answer.
- **The queue can be reached to its end.** One item per screen, but no tab and no filter can hide
  an item: the *All* sheet lists every one, and the pass ends somewhere definite (§ The queue).
- A **human state with outgoing transitions** waits for a person; one without is terminal and
  never enters the queue. The topology mark is the only thing distinguishing them.
- **Answering never leaves the queue.** Sending a question card's answers moves the pass to the
  next item in place; it does not open a page or navigate away. On a ticket or a chat the card
  closes and the page stays.
- **Presentations carry no approval slot at all**, so they cannot be misread as approvable.
  Experimental results are advisory and must never read as verified. **The platform gives a
  presentation no special sections either** — *How it was checked*, *Worth a look* or a reviewer's
  summary are what a project's own workflow may write in it, not slots the page parses for or
  draws.
- **The diff is bounded and says where.** Past the page's limit it offers the `git diff` command
  for the exact range instead of trailing off. **So does a patch that is not valid UTF-8** — a
  latin-1 source file is diffed in full by git, and those bytes in a rendered page are a response
  body that is not UTF-8 and, through the socket, a serializer that raises in the transport
  process and takes every LiveView on the connection down. One rule, two reasons, and the same
  `git diff` line either way; it holds wherever a change is drawn, which is a ticket's and a
  chat's Changes and a repository commit. A *path* that is not UTF-8 is a different answer — it is
  made printable rather than withheld, because a change whose file list is missing is not a map
  (`Forge.Git.printable_path/1`). The file list above the patch is never truncated: it is the map
  of the change. Dollars do not appear here either — the Changes view is the surface where they
  are most tempting and least useful.

## A reconnect is not a reload

A socket that drops while the page sits idle is not something the operator did, and it must not
cost them what a reload deliberately costs. Three cases start a form over and are meant to —
reloading, navigating away, opening the item on another device. A fourth, a dropped socket
rejoining the same page, is in none of them: the top bar says the connection went (§ Connection
state) but not what it took, so anything taken then is taken silently.

**Every box a person types into sits in a form with an `id` and a `phx-change`.** That is not a
style rule, it is the whole mechanism. On a rejoin the client copies each such form out of the
live DOM and re-pushes its change event with what was typed, before the new mount's render is
applied; a form missing either attribute is not copied, is not replayed, and is drawn empty by
that render. So the page's handler for the change holds what arrives, and the box is drawn from
what it holds — see `ForgeWeb.Operator.Drafts` for the cards and
`ForgeWeb.Operator.QuestionForm` for the question card. Two modules, deliberately: a question
card holds a structured set of answers it has to validate and send, a card holds the fields of
one form as they came off the wire, and folding the first into the second would lose the
structure for the sake of one fewer module.

What this does not reach is a reconnect the framework answers with a hard page refresh, which it
does when a push times out: there is no DOM left to copy from. That is a reload, and the three
deliberate cases' rule applies.

**Where the rule holds.** On a conversation's composer and the question card docked above it, a
document's question card, an approval's note, a proposal's comment and its type, a human state's
document, the release note, and the two screens that start something — a new ticket and a new
conversation, which is where the person who reported this said they lost work. The redesign adds
boxes, and each new one joins this list or the inventory says why not: a reject note in its panel,
the composers that start a conversation in place, project settings' one form for model and effort,
the stepper forms, a bulk decline's shared reason.

A chat step's Accept form (§ The Accept area) is in this group too: its outcome pick and its open
confirm ride in the form's own fields, so the change event the client replays restores them. It
holds no text box, so `ForgeWeb.ReconnectTest`'s walk and inventory have nothing to say about it;
`chat_step_live_test.exs` replays the event against a fresh mount instead.

`ForgeWeb.ReconnectTest` holds the rule two ways: it walks those pages and fails on a box drawn
outside a form carrying both attributes, and it inventories every form in the web layer that
holds a box — including the boxes components draw rather than the form itself — so a new one
that cannot be replayed fails until somebody records why, the way
`authorization_inventory_test.exs` does for events. What neither reaches is a box drawn in no
form at all; no page draws one today, and only the walks would catch it if one appeared.

It does **not** hold yet on six forms, which that inventory is where to read: a project's
members, its secrets, its mirrors, a worker's resources, and the two log-in forms. Each carries no
`phx-change`, so each loses what was typed on a rejoin. That is a gap the inventory records rather
than one the rule excuses — and two of them are why a person settles it and not the next agent: a
secret's value or a password coming back means holding it in page state, which is a decision of its
own (`docs/design/secrets.md`). A project's default model and effort were two more, until they
became one form with one Save (§ Project settings) whose change the page holds.

**A draft the document moved under is refused once, then saved on purpose.** The box keeps what
was typed even across a reload, so a Save from it could land on top of a version somebody else
wrote while it sat there — v5 from text written against v3, with v4's work gone from what the
workflow reads. The editor sends the version its draft was written against, and the first Save
after a newer version arrives is refused whole: the refusal, under the editor, says which version
it is now and that the text is still in the box. **Saving again writes it.** The refusal is the
warning, and repeating the gesture is the decision to write over what arrived — a refusal with no
way forward would leave the operator told their text was safe and holding no gesture that could
send it, which is the same dead end as losing it. Nothing goes silently either way: the other
version is in the document and named in the refusal, and the typed text never leaves the box.

## The queue

`19a`, `18a`, `13b`–`13g`. **The queue is home**: `/`, the only top level with no queue button,
its title the switch `Queue ▾`, its subline the place in the pass — *1 of 4 · 5 decisions*, the
decisions being the queue button's count less what this pass decided (§ What the queue counts).

**One item per screen, oldest first.** An item is **one interruption, not one question**: one job,
stopped, against one artifact version, carrying N questions; one approval; one stuck ticket; one
chat waiting on its reader. A job that stops inside a document typically stops with several
questions, and one screen per question would turn three decisions into twenty items with
identical timestamps.

Each item is drawn in the same order: an eyebrow naming its kind and where it is (*approval ·
review → merging*) with its waiting time on the right; **the queue sentence**, saying what is asked
(*Sound toggle in settings is ready to merge.*); **the context card** — the ticket's number and
title, its type, its workflow track with the current step in amber (a queue item waits on you), and its facts (state and visit,
jobs and usage in windows, when it was admitted); what is particular to the kind (below); and at
the foot **Later** and the item's way on. **On a phone the context card is one line** — the
ticket's number, its title and `›` — because the track and the facts are one tap away and every
line above the question card is a line of the content it covers.

**Later sends the item to the end of the pass.** Nothing is lost by it and nothing is recorded:
the pass is the page's, and reloading starts a new one in the queue's order. What was left for
later is not met again on the way — it waits at the end, under *Back to it* — so the pass ends
however often Later is pressed.

**Deciding an item moves the pass on, in place.** A question card's Send, a way forward's dock
button: each sends, and the next item is drawn without a navigation. A decided item stays in the
*All* sheet, dimmed with `✓`, for the rest of the pass. A refused send is not a decision: the item
stays, with the refusal in words.

**The queue does not rearrange itself under a thumb.** An item that arrives while a person is in
the pass joins its end; one that stops waiting while drawn — answered on another device, approved
from the ticket — stays drawn, saying so, until the person moves on, and what it offers is refused
in words if sent. At the end of the pass, the first item to arrive is drawn.

### What each kind shows

- **An approval** (`18a`) shows enough to know what you are walking into: the changeset's size,
  files and check, and **the commit message it will write**, under *The commit it will make* — or, for a
  document approval, every document it pins, rendered (§ Documents) under its name and version in
  a box that scrolls inside itself, so one long plan does not push the rest below the fold. Its way
  on is **Review the changeset ›** (or *Read the document ›*), an outline link to the ticket's
  Changes or Docs view, **where the decision row is**. It never approves here. There is no
  *Reviewer said* block: what a reviewer wrote is the presentation's, and the platform gives a
  presentation no slots (§ Semantics that must not be lost).
- **Questions** (`13b`) show what the agent said when it stopped with the passage that asked
  highlighted, **before** the context card — it is what the questions are about, and under the card
  it was beneath the split pane on a phone — and the questions in the question card, in the split
  pane (§ The question card). On a phone a passage longer than four lines is clamped with *more* at
  its end, and the split pane starts at no more than 45 % of the screen, its choice rows scrolling
  inside it.
- **Accounts waiting on a node admin** are one item, the oldest's age its own: the sentence counts
  them, and its way on is *Review the accounts ›*. Nothing is decided in the queue.
- **A stuck ticket** (`13c`) says **why, in words**, beside the engine's outcome: its sentence is
  `<title> is stuck: <reason>.`, the reason from the ticket's latest `ticket.stuck` — a failed job,
  a `max` that ran out, an outcome no edge matches, a rejected approval. Then the last attempt's
  outcome, its error excerpt and the agent's closing words; how much of the ticket's allowance is
  gone; and **the ways forward as choice rows** — each transition the person may take and *Run
  `<state>` again* where the state can be — with what each does, none preselected, and a dock
  button that takes the one picked and is disabled until one is. The push carries the reason after the title. The first ticket stuck on an exhausted
  `max` read only *needs a way forward*, which is true of every stuck ticket and says nothing about
  this one.
- **A conversation waiting on its reader** shows its last reply and, when it asked questions, the
  question card; *Open the chat ›* leads to it.

### The question card

`2a`–`2d`, `13b`. A document's questions are **one form with one Send**, wherever they are drawn —
a queue item, a ticket, a conversation's dock. Answering one question locks its answer in; nothing
is sent until Send. The reason is the agent's: a job that stopped with three questions resumed on
the first answer that closed the last blocking one, and read whichever answers had landed by then
— so a person answering in order was racing the resume. One Send makes the answers arrive together
(`job-prompt.md` § Answering a document's questions at once).

**It sits in a split pane** under the content it is about: a 16px handle above it, the card sized
to fit what it holds up to a limit the person sets by dragging, so the context above can still be
read or dragged away. Tapping the handle folds the card to its tabs and Send (`2c`). **The limit is
kept per device**, in the browser's storage: no part of this redesign asked for it to follow a
person, and a limit that suits a phone does not suit a monitor. On a desktop the split is vertical
at every width and an option is a 34px row (`2d`).

- **One tab per question**, in document order, the order the agent wrote them in. Blocking ones are
  required; non-blocking ones are optional, carry their assumption and an `optional` tag, and are
  in the same card rather than only under *Not waiting on you*, because they were asked in the same
  breath. A version with no blocking question keeps its card under Steps on the ticket, and its
  lines in the queue's *Not waiting on you* (§ Not waiting on you). A tab is marked `●` once its
  answer is locked in, `○` before; a card of one question draws no tabs. The card opens on the
  first question with nothing locked in, and the one last touched stays shown, so locking an answer
  in never moves the card under the thumb. Every question is in the form whichever tab shows, so
  Send carries them all.
- **An option is a choice row**: its headline, the sentence beneath it, and a radio. The
  recommended one wears an outlined `recommended` tag and **starts chosen**, so accepting every
  recommendation is one tap on Send.
- **Free text beside the options**: *add a note, or answer in your own words*. With an option
  chosen it is a note on that option; with none it is the answer. A question with a chosen option
  offers *Clear choice*, so an answer in your own words is reachable when a recommendation started
  chosen. It grows to six lines, and **Enter in it is a new line** at every pointer: only Send
  sends (§ The affordance rule).
- **Send is disabled until the card can be sent** — every blocking question locked, and in a chat
  every question, since a chat reads each as blocking — and names what it will send,
  `Send 3 answers`. Beside it, while it is disabled, one line says what is left:
  `1 blocking question left`, or `1 question left` where every question in the card is required
  and the word would tell nothing apart.
- **The page holds the draft, and only the page.** Reloading, navigating away or opening the item
  on another device starts from the recommendations again. Nobody else ever sees a half-answered
  card, and there is no draft to expire. A dropped socket is not one of those three and does not
  start it over: the card is a form with an `id` and a `phx-change`, so the client gives the draft
  back on the rejoin (§ A reconnect is not a reload).
- **A stale card sends nothing.** When the document has a newer version, or another person answered
  one of its questions, Send is refused whole and the card says so; it redraws with the current
  questions.

### The end of the pass, and *All*

**The pass ends somewhere definite** (`13d`): what was decided in it, what was left for later with
a way back to it — each a row as the *All* sheet draws it, which leads back to the item — and then
the two quiet groups, **Under way** and **Not waiting on you**, which count towards nothing. When
nothing is left, an eyebrow in `--success`, *End of queue*, and a sentence phrased as completion —
*Nothing needs you. Work continues without you.* — head it; the same block, alone, is the empty
queue. **When items were left for later it does not say done**: the eyebrow is neutral, *End of
the pass*, and the sentence counts them, *4 left for later.* Every other empty state names what
would fill it rather than announcing absence. *Under way* says each half once — *2 tickets running
on a worker.*, *5 tickets not yet on a worker.* — over its titles, rather than on every line.

**All N**, the top bar's right end on a phone (where another page links to its parent, which the
queue has none of), opens the whole queue as a sheet (`13e`), so the end is in reach at a glance: every item
in the pass's order, each with its kind, age, title, ticket and step, decided ones dimmed with `✓`,
then the two quiet groups. Tapping a row jumps the pass to it. **A row's kicker is the kind
alone** — *2 blocking questions*, *approval* — with its age right-aligned and never wrapped; where
the item is, the document and its version or the transition, is the row's latest line, said once.

**On a wide screen** (`13f`) the whole queue is the left column, always visible so the end is in
view, each row the kind and age, the title, the ticket number with its workflow track and step,
and the latest event in warning when something failed; the item is in the middle at reading width;
the ticket's context is the right column — its track, what happened in order since the person last
looked, and the documents in play. **On a portrait screen** (`13g`) the ticket's context is a band
above the item and the queue keeps its column. *Notify me*, which subscribes this browser to push,
is in the queue's header on a desktop and on the You page everywhere.

**Since you last looked.** The context the queue and the ticket draw names what happened on the
ticket since this person last opened it — the events after their previous look, the newest eight,
in words (a transition, a stick and its reason, a decision, a document written, what was said and
by whom, a job ending), never the job's harness stream. On a phone the queue draws the context
card alone, as `13b` does; from 768px it adds this list and the documents in play.
A look is recorded per person and ticket when the ticket's page is opened, after the membership
check, and the previous one is what is compared against; another person's look never moves mine.
**A socket rejoining the same page records none** (§ A reconnect is not a reload): a rejoin is a
connected mount like the first, and recording it would make the look the first mount recorded,
seconds earlier, the previous one — every mark gone after a phone slept for thirty seconds. So the
page carries the look it was opened with (`#ticket-look`, drawn only by a connected render), the
socket sends it back when it joins, and a mount that receives it for its own ticket draws from it
and writes nothing. A dead render carries none, nor does another page, so a new visit records one.

### What the queue counts

**The queue button's count is the number of items the queue page draws** for the viewer: questions
grouped per document version, approvals, stuck tickets, conversations waiting on their reader — and
not assumptions, not the two under-way kinds. **For a node admin it also counts accounts waiting
for approval** (`12i`): an account waiting on an admin is a decision, and without it in the count
nobody would know to look. **The queue lists them where the count says they are**: one item,
*2 accounts wait to be approved.*, whose way on is *Review the accounts ›* to Accounts, where each
is decided — a count with nothing in the pass to show for it was the worst of both. The count is scoped
by membership like the page. **The queue's subline counts the same way** — one decision per item,
a document's questions one, plus the accounts — so its *N decisions* and the title menu's never
disagree. On the queue page they are one count, not two that agree: the page hears changes only
through the frame, which reloads it and takes the button's figure from the page's own read
(`ForgeWeb.Frame.follow/3`), so a ticket change reads the queue once.

### Not waiting on you

A non-blocking question is an assumption an agent stated and carried on from, so it is not a
decision and does not get a decision's shape. `Forge.Queue` serves it as its own kind,
`:assumption`, so that no reader — the page, the JSON API, the CLI, the digest push — can count it
as a blocking question by accident; the page draws it at the end of the pass:

- **Prose, not items.** An eyebrow, one sentence saying how many assumptions were stated and that
  work continued, then one line each: the question, what was assumed, and the ticket and age as
  identifiers. No mark, no choice rows, no amber — nothing in it is waiting on a human.
- **Only an assumption asked on its own.** One asked in the same document as a blocking question
  is in that document's question card, optional, and not here as well — a second place to answer
  it would be a second answer (§ The question card). `Forge.Queue` still serves it as an
  `:assumption`; which surface draws it where is the page's arrangement.
- **Each line navigates to its ticket**, where the question is answered. A navigation target never
  encloses a control that commits (§ The affordance rule), so this group offers no answer of its
  own rather than a second place to give one.
- **It counts towards nothing.** Not the subline, not the queue button: a number that answering
  nothing ever lowers is not a count of what is waiting.
- **Answering one changes no job's flow.** Its answer joins `answers.md` for whichever job runs
  next on the ticket; a waiting job resumes only once no *blocking* question is open, and a
  non-blocking answer closes none (`job-prompt.md` § Non-blocking questions).

### Push follows the queue

Anything that starts waiting on a human pushes to the phones of the people in its project — a
blocking question, an approval, a stuck ticket, a ticket ready for review, a conversation's reply —
and links to the object: a ticket's URL, which opens on the view holding what waits (§ The ticket),
and a conversation's Talk. An assumption, which waits on nobody, is digested. The rule is
`Queue.waiting?/1`, not a list kept beside it, so a queue kind added later pushes or does not for
the same reason.

## A job waiting for a machine

A pending job the scheduler could not place says why, in one sentence, where the job is looked at:
under its row in the ticket's Steps, and on a pending conversation's page where the reply will
appear. The sentence is the scheduler's (`provisioning.md` § The gate), in the product's voice —
*Waiting for room: …*, *Waiting for a template: …* — and it is language, so it is sans at body size,
never mono. **A sentence that sends the operator somewhere sends them where the reason is.** A
provider that refused to make a machine left its words on the worker row, so that sentence names the
machines page; a template the platform would not spend from — its provider credential is another
user's, or another provider's — or would not make a machine from, because its image speaks a worker
protocol this platform does not accept, made no worker row, and its words are on the template, so
those name the templates view. Both show the viewer's own rows only, so each sentence names whose
page: the template owner's, who may not be the person reading it. **A job waiting for a worker
image** being built in the provider account of whoever owns its template says so and names that
owner's templates page (its Credentials view, where the build is drawn); a release whose image is not published or not
public says that and names no page, because nothing on the node fixes it. Both are quiet, like every
wait: nobody has a decision to make. It is drawn only while the job is
pending, and only the latest reason since the job last started; every change stays in the job's own
event stream, where it is a line like any other.

**It is not amber**, even when the answer is a template nobody has assigned. Amber is the queue's
mark for a human decision, and neither a job running nor a job not yet on a machine is that: the
queue draws a ticket resting on either quietly, under **Under way** at the end of the pass —
the same shape § Not waiting on you gives an assumption, counted towards nothing and never pushed.
Which of the two a ticket is in is `Job.status` and `worker_id` on its live job and nothing else;
the rules below say what else the group reads, and what for. A ticket that no template could ever
hold is stuck instead of merely pending, and is an item that way; stuck excludes the quiet line
rather than sharing it. A conversation in the same position waits on a person and is drawn quietly
all the same — the gap `provisioning.md` § The gate records, not a rule.

Four rules, each of which the group broke first:

- **It is the ticket's live work, and a command is work.** A command state's job *is* a command
  (`commands.md` § An invocation is a job) and an agent that invoked one parks while it runs, so a
  read of workflow jobs alone left the queue saying *Nothing needs you* while a build was on a
  machine. Nor is it the ticket's newest row: a command is created after the agent that invoked
  it, and a batch is inserted in declared order, so the newest row is routinely one that has
  already finished while its siblings run. It is a running job with a worker if the ticket has
  one, else a pending job — running first, because a ticket is on a machine the moment any of its
  work is.
- **A paused ticket is still never here.** The daily spend cap and a rate-limited credential pool
  both leave a job pending with its ticket active, and `capacity.md` keeps both out of the queue
  because an item the operator cannot act on is what the queue exists not to contain. The group
  drops them, asking `Forge.Spend` and the wait the scheduler recorded. The cap is drawn
  `paused · spend` in its place; the rate limit is drawn nowhere at all, because that surface is
  not built (`capacity.md` § Engine support), so such a ticket is in no operator surface but the
  reason sentence in its own Steps. **That is a gap, not a treatment** — `capacity.md`'s to
  close, and not a reason to put a ticket nobody can act on back in the queue. The cap gates a
  workflow job only: a command takes no spend gate, so a pending one is not dropped.
- **Neither line names a cause.** *Running on a worker* and *Not yet on a worker* are the two
  halves of one axis. *Waiting for a worker* named a cause and got it wrong: most of the reasons a
  job is pending are about getting it a machine, but waiting a turn behind a sibling command is
  not, and a refused template needs a person. The sentence above is where a cause is stated,
  because it is the one place that knows which cause.
- **The age of a running line is the current run's**, from the run ledger — not `jobs.started_at`,
  which keeps the first run's start for the life of the job, and not the row's age. A job answered
  at 19:00 after stopping on a question at 09:10 read ten hours old a minute into its second run
  under either.

## The ticket

`/tickets/:project/:number`. A ticket and a conversation are both *one piece of work*: a branch, a
record, a cost, and something that may be waiting on you. They are drawn in the same frame from
the same components, so that steering a conversation and steering a workflow are the same gesture
on the same screen.

**The top bar**: the queue button; the ticket's title over its subline — `#39 · ● review`, its
state per § The three axes, then a status that is not `active` — and no *waiting on you*: the
decision row under it says that in amber, and at 412px the words were what the ellipsis cut,
taking the state with them (UX pass, B13); the project, `game ›`. Tapping the title drops
**the details** (`6d`). Under it, the decision row when an approval or a step's Accept waits.
**The views** are Steps · Changes · Docs · Activity, and Talk while the ticket has a live
conversation or a step's (Talk leads to `/chats/:id`, which draws the ticket's frame — § The Accept
area).

**The view it opens on is the one holding what waits**: Changes for a changeset approval, Docs for
a document approval, Steps for questions, a stuck ticket or a human state; otherwise Steps. A
pushed link, the queue's link and an old link with a view the ticket no longer has all land there.
**It is chosen when the page is opened or navigated, not as the ticket changes**: an approval
arriving while somebody reads Steps, or one decided elsewhere while they read Changes, does not
move the page under them. The next visit, a tap on a view, or the person's own decision lands where
the ticket is then — a rejection made here goes on to Steps, where its ways forward are.
**There is no Decide view.** What it held moved to where the thing is, and nothing it held was
dropped — the table in § Steps says where each went.

**On a wide screen** the document an approval or a step's Accept waits on is drawn, rendered, in
the context column beside whichever view is open (`16i`), so it is read while deciding; below 1440
it is a tap away on Docs. A release ticket's band (`21e`) sits where a decision row would, above
it when both are there.

### Steps

`5g`. The workflow as the ticket has walked it: a step per visit, on the line-and-dot the project's
Workflow view uses, each step its state, its jobs and commands as rows, its outcome, and the
transition it took. The current step is open; done ones fold. Rows new since the person last
looked are marked.

**Where the Decide tab's contents went:**

| Was on Decide | Is now |
|---|---|
| A document's questions | The question card, in the split pane above the strip, on every view |
| The approval card | The decision row (§ The decision row) |
| The transition card and *Run again* | **Ways forward**, under the current step: a choice row per transition and per *Run `<state>` again*, and a dock button that takes the one picked |
| A human state's document editors | Under the current step, above its ways forward |
| The merge-queue card | On the current step |
| What an agent assumed and carried on from | Under Steps, unaccented, under no count |
| The not-buildable page | Steps' whole content |

**A ticket whose pin cannot be built** (`workflow-grammar-v1.md` § Pinning) has no steps to draw,
so its Steps view is: a notice that the workflow it was pinned to can no longer be read with the
errors behind a disclosure, the way on — Re-pin when `.forge/` has changed, Cancel (Restore when
cancelled) — then its documents and its history. Every other action on it is refused in words.
This is not a ticket admitted under an earlier release: those open as any other.

**Ways forward.** Whenever the ticket rests where a person may move it — a human state, a stuck
ticket, a job or command state with nothing live in it — the current step ends with the
transitions the person may take, as choice rows that say where each leads and what it starts, and
a button naming the one picked (*Move to planning*) — in the dock on a phone, under the thumb, and
from 768 directly under the choice rows it commits, where a docked button sat a screen away from
them. **Run again** is one of them —
`Run refining again` — whenever the ticket rests in a job or command state with nothing live in it
(`workflow-grammar-v1.md` § Running a state again). It is offered after a success as well as a
failure, because redoing a refinement before approving it is a choice a person makes while reading
it. A transition whose approval has nothing to approve is never offered. A way forward is not a
decision row: it moves the ticket and approves nothing, which is the difference between a dock
button and an amber one.

**A human state's documents are written here**, above its ways forward: one editor per name the
state declares in `produces` (`workflow-grammar-v1.md` § Semantics), holding the latest version
when there is one, and a filled *Save* that records what was typed as a new version by the person.
Writing one is not a decision and adds nothing to the count. It sits beside the ways forward
because the person deciding where the ticket goes next — a tester sending a build back — is the
person the next job needs to hear from, and a note that lived anywhere else would be skipped on the
way to the button.

**The merge queue** stands on the current step once an approval has queued the ticket
(`workflow-grammar-v1.md` § The merge queue): *In the merge queue · 2nd of 5*, then what is
happening — waiting for those ahead, being merged, being integrated (it keeps its place) — and
**Take out of queue**, behind a confirm that says the approval is withdrawn and that an integration
already running will finish but will not merge. Nothing is hidden by pressing it: the card goes
when the server says the ticket left the queue, and a ticket that has merged, or was taken out by
someone else, is refused in words saying so. A queued ticket offers no ways forward and no
send-to-integration action — the queue does those — and approval is not offered again for what is
approved. The details say *merge queue* with the place, and Steps lists the queue's events —
queued, back in line after an integration, taken out, left, merged — under *Merge queue*, and only
for a ticket that has a queue event. It is called the merge queue everywhere, and never "the
queue", which is the page of decisions.

**A command is a job row like any other** (`commands.md`): the whole row the target, leading with
`$` where an agent job's row has its attempt, the command and its arguments as an identifier, its
exit status where a job's outcome goes — `exit 0` in success, any other in danger, none as the
engine outcome that says why — and its duration where a job's turns and usage go, since it has
neither. One an agent invoked is indented beneath the job that invoked it, in the step that job is
in; a command state's commands are that state's step. A command state's mark is a job state's,
`▸`: entering it starts work that ends in an outcome.

**A failed command of the batch that decided where the ticket is shows the end of its log** under
its row: the last 4 KiB, from a whole line, with how much was cut. The failing line is what a
person looking at `build_failed` wants first, and before this it was behind the log's download.
Only that batch — an older one's failure was answered by the work after it — and never an agent's
own commands, whose logs the agent is handed.

**The conflict route is a step like any other.** The transition it takes is in Steps as the step it
leads to, and Activity says what `ticket.merge_conflicted` means beside its type — the first path
that conflicted, how many more did, and the state that would have merged.

**A release ticket** (`21e`) uses this frame unchanged, with a slim band under the top bar marking
it as the release: not a decision row, so no button and no amber. The release's note and what
has merged since the previous release lead its Steps. *Since* is the project's previous release
ticket that reached its terminal state, by its version, and the tickets merged after it; a project
with no earlier release draws nothing there. The platform keeps no git tags to read it from.

### The details

`6d`. Tapping the title drops the ticket's details: its facts (type, workflow and its pin, branch,
admitted, jobs and usage in windows, the capacity lines written out for the project's pool —
§ Usage), what it pinned, and its lifecycle actions. Three notices live here, each shown only while
true:

- **A ticket whose pin the default branch has moved past**, under the `workflow` fact: the paths
  under `.forge/` that changed, and **Re-pin at `<sha>`** behind a confirm
  (`workflow-grammar-v1.md` § Pinning). Nothing is said while `.forge/` is unchanged — a default
  branch that moved on for other reasons changes nothing the ticket runs.
- **A ticket a merge has put in conflict**, shaped like the re-pin notice: *`main` no longer merges
  with this ticket's changeset since #12 merged* — or *since a conversation merged*, or *`main` no
  longer merges with this ticket's changeset* when it conflicted already — the paths, and **Send to
  `<target>`** behind a confirm, which takes the conflict route to the merging state's
  `on_conflict` target (`workflow-grammar-v1.md` § Merging). Found after every merge
  (`git-hosting.md` § After a merge, the other tickets) and shown while it is still true of the
  ticket: its latest changeset is the one found conflicting, and the ticket has not taken the
  conflict route since. It offers the action only where the engine would take it — an open ticket
  with nothing live in its state, an edge from there into a merging state, and an `on_conflict` on
  that state; otherwise it is the notice alone, because a conflict nobody can act on from here is
  still worth knowing before the approval. Nothing starts until the button is pressed: the confirm
  says a job will run when the target runs one, since that spends a credential on a ticket the
  person may be about to cancel.
- **Cancel ticket**, outlined red behind a confirm, on an active or stuck ticket; a cancelled one
  has **Restore** instead, with a line saying where it is hidden and what restoring leaves
  (`workflow-grammar-v1.md` § Cancelling a ticket). It is rare and undoable, so it sits in the
  details rather than among the ways forward.

What the ticket's own jobs proposed is named here with a link to the project's Proposals, which is
where a proposal is decided (`ticket-proposals.md` § Where it surfaces).

### Changes

`19d`–`19g`, `18b`, `18f`. **The review page and Changes are one view.** What the branch holds
against its base, bounded per § Semantics that must not be lost, under a segmented switch:
**Presentation · Files · Commits**.

**It opens on the presentation while the ticket is in review and its agent has written one**
(`19d`) — in review meaning that what waits is an approval of the change, one that merges or pins
the changeset; otherwise on Files. With no presentation the option is dimmed and says why (*No
presentation yet*), and Files says it is the work in progress on the ticket's branch (`19f`). The
approval row is pinned above all three, so a person approves after reading either. The sub-view is
in the address (`?tab=changes&sub=presentation|files|commits`, and `&file=…&lines=…&para=…` for a
whole file), so a link and a reload land on it, and what a sub-view reads — a presentation's
Markdown and git, a whole file, the documents' renders — is read only while it is on screen.

**The presentation** is the ticket's `presentation.md`, rendered (§ Documents), drawn as the
presentation kind is everywhere — no approval slot, nothing that reads as verified. It is free
markdown: the platform draws what the project's workflow wrote and gives it no sections of its own.
Where a paragraph quotes `` `path:line` `` or `` `path:start-end` `` in backticks, the matching
source from the changeset's head commit is drawn directly beneath that paragraph — any path in that
tree, which is the repository as the change leaves it and not only the files the change touched —
so the operator reads the lines the prose is about without going into the diff for them. **What is
drawn is bounded, the way the patch is**, and the prose is an agent's, so every bound is on what the
page draws rather than on what the document says: a fixed number of quotes drawn per presentation,
counted over the whole of it and not per paragraph, since the same quote in forty paragraphs is
forty blocks; a fixed number of lines and bytes per quote; a fixed number of bytes read out of git
for the whole presentation, asked of git — and of the *blob*, not of whatever a path resolves to —
before any of those bytes are; and a fixed length of prose rendered, past which the page draws the
beginning and says the rest is in the source. Each bound that stops something says so where it
would have drawn it — how many quotes it left out, or to read that one in Files. A path or a range
that does not resolve at that commit degrades to a muted note naming what was asked for, and **so
does a path whose file is not text**: the diff prints `Binary files … differ` rather than those
bytes, and a page that drew them would not survive being encoded for the browser. None of it can
fail the page.

**Images and links resolve, and are not bounded.** `![queue](screenshots/queue.png)` in the prose
is drawn as that image, pinned to the version current when the presentation was written, and
`[the plan](plan.md)` links to the document (§ Documents → References). The bounds above stay for
quotes and prose, but **images are the exception to "what is drawn is bounded"**: every resolved
image is drawn and each is fetched only when scrolled near (`loading="lazy"`), so a presentation
naming a hundred files costs the reader a hundred requests only if they scroll past a hundred. An
image past the prose bound is absent because the prose it was in is.

**An excerpt is highlighted as the file it was cut from**, numbered from where it was cut, with the
lines the change added tinted. **Every excerpt links to its whole file** (`19e`): the changeset
head's blob, through the same bounded `Forge.Git` reads the repository page uses (512 KB, text
only), highlighted (§ The project's repository), the lines the change added tinted and the
excerpt's lines marked in the margin, its neighbours in the change at the foot, and *‹
Presentation* back to the paragraph it came from. **Its head — the way back, the path and its
`+ −` — stays at the top of the view while the file scrolls**, and the file opens three lines above
the first marked line, under that head, so the lines arrive with their context and their name. The file is the changeset's commit's and no
other's: a path the branch gained later, or one outside the tree, is a miss like a path that never
existed. **On a wide screen** the presentation reads at 680px on the left, its excerpts become
links, and the right pane shows the whole file the paragraph in view points at, those lines
marked, following as the reader scrolls; a file tab switches it by hand (`19g`).

**Files** is the file list with each file's `+ −` (`DiffStat`), never truncated; a row opens its
patch in place, rows tinted for added and removed lines (16 % in dark, where 10 % was a few percent
of lightness, about 10 % in light) with a 2px edge in the line's own colour, numbered on their own
side, lines wrapping rather than scrolling sideways. **An open patch keeps its file's row at the
top while it is read.** When the approval
merges, what it will commit is drawn first, its subject in bold (`18b`); a ticket with no
presentation yet leads instead with the sentence that says the list is the work in progress. **While an approval of the changeset waits, the
change drawn is the commit that approval pins**, not the branch's head, which may have moved on;
a pinned version that names no commit says so rather than showing the branch. Beneath it, **what the merge approval needs beside the diff**
(`decisions.md`): the documents the change was built from, the questions answered on the ticket,
and the ticket's usage. **Commits** is the commits on the branch since its base: short sha,
subject, age. **On a wide screen** the approval row carries the commit message inline and the file
list moves to the left of the diff (`18f`): the list carries each file's `+ −` and marks the file in
view with the inset edge, the first patch opens by itself, and the patches beside it do not repeat
the counts — the two columns are not the same list twice.

**Ask about this** is on each file row and each hunk header: a control beside the row, never inside
a navigating region (§ The affordance rule). While a file's patch is open it is the hunks' alone —
two of them 30px apart asked the same thing. On a chat it puts `path:line` into the composer's draft
and switches to Talk. On a ticket there is no composer, so it goes to the ticket's most recent live
conversation with the reference in its draft, or to `/chats/new` for the ticket with it in the
first message when none is live — the reference travels in the URL and nothing is sent until the
operator sends it.

**What the merge commit will say** is drawn wherever a merge is decided — in the approval's drop
panel, the queue's approval item, a chat's merge, and above the files on Changes — from one
component (`WorkScreen.commit_message`: its version in the eyebrow, then the subject in mono
13/500 and the body after a blank line, as git keeps them, on `--surface-1` with no border and no
*view only*, the body without front matter), so they cannot disagree about whether the operator
saw it, nor about what git will write: Changes once ran the body into the subject's sentence. It is the `commit-message` document, an
agent's text used as written, so it is drawn **read-only**: **it is never an editor**, and no
surface offers to change it. **Where the approval would merge and no version exists**, the row
says there is nothing to merge yet and the panel **draws no Approve**, as a chat draws no merge.
**A ticket pinned before the document existed** has no state that could write one, so the panel
draws a sentence in the message's place — pinned before merges carried a written message, so the
merge says what earlier releases wrote — with the subject line, and **does draw Approve**. A ticket
whose pin has a producer and no version is the case above, with no Approve.

### Docs

`6a`, `18d`. Every artifact on the ticket but the changeset, which is Changes — documents and
files alike — **grouped by what each asks of you**: *Waiting* first (a document an approval or a
step waits on), then *Built from* (what the ticket was built from), then *Produced* (what its jobs
wrote). A row is the type's tile (§ Artifact types), the name, who wrote it and where it is
pinned, approval marks only where approval is possible, and the version at the row's end, linked
to its address; earlier versions fold under it as links. What the last turn wrote that was not
recorded is listed beneath, with why. A document waiting for approval takes the decision row, and
its `◇` goes once it is approved. (The handoff turns it into `◆` there, which is already the mark
for *waits on you*; this note does not.)

**A document is collapsed until it is opened.** Its row is a `<details>` whose body is the document
**rendered** per § Documents — or its text as written, when its name says it is text, a log or code.
Open, one long plan pushed every row after it a screen down, and the view is read for what is there
before it is read for any one thing in it. An opened row stays open while the view is patched
(§ Motion and structure). The version link is beside the summary and never inside it: the row is a
control of its own (§ The affordance rule). The diff between two versions is not drawn: nothing
computes one, and the version links are the way to each.

**A closed row fetches nothing.** A document that refers to an image draws it with a lazy `img`
inside the row's `<details>`, which a browser does not request until the row is opened.

**A file has no body here**: its whole row is the link to its bytes, drawn at the same height.
Reading every one of a build's outputs from the store to draw its row would be a store read per
row per patch, and a file's bytes are one tap away at its address.

### Activity

`5d`. The event stream of the ticket's current job, with its earlier jobs linked to their pages, or
of a conversation's job — newest first, notices behind their count, rows new since the person last
looked marked. A rejection is drawn with its note. Its tool calls are drawn with the action lines of
§ Talk, each carrying its result — a result is not a row of its own — the same component, so an
edit, a command and a failure read the same whether a conversation or a workflow job made them,
and the job page draws them the same way. **An event with a form in words is drawn in it**: a
version written is `wrote commit-message v1 ›`, linked where Docs links that version; a person's
message is `you: Yes, try it.`; a turn's end is a thin divider, `turn 1`, not a row; the agent's
words are headed `agent`; a proposal's fate, logged against the job that proposed it, is
`proposal-1 admitted as #44`, `declined` or `reopened` (review fixes 7, L3). Never a `version_id` or a payload's keys — the raw form is the job
page's raw log. Every other event keeps the job page's row, a `memory`
row with its type in warning. **A row wraps rather than truncating**, and a line longer than 200
characters — an agent's paragraph, a command on one long line — shows its first 200 and expands in
place to the whole of it. A command's line, a URL and a query do so wherever they are drawn, the
transcript's included, since it is the one component; a call drawn as its name and input is already
cut short before it gets there (`Forge.Events.tool_summary/2`, 160 characters of its input), so it
is never long enough to clip. The whole is already on the page: an agent's text is drawn in full
here, where a list or the CLI's log draws `Forge.Events.summary/1`'s bounded line. **Live while the
job runs** (§ Motion and structure). With nothing waiting, the job running now is a quiet info chip
in the strip's right slot that opens its job page (`5d`; it is drawn in the dock above the strip for
now, § Not built yet) — on Changes and Docs only: Steps and Activity lead with the job's own row,
and the chip there said it again a line away. A conversation's job is not opened on the job page;
its Activity is where it is read.

Under the stream, **On the ticket** lists what happened to the ticket itself rather than in a job
— a decision and its note, a transition, a stick, a merge-queue event, a rename — newest first.
Activity also says what the platform's own events mean beside their type: the statuses a command
batch decided and its outcome, why the ticket stuck, which edge it took, and what each merge-queue
event means.

## The job page

`/tickets/:project/:number/jobs/:job_id`, `6e`, `21a`, `21b`. **A drill-in from Steps or Activity,
inside the ticket's frame**: the title is the ticket, the subline the job, and the strip the
ticket's, so the way out is the strip. The live chip still points at the job running now while
the person reads one that failed.

- **The outcome is the headline** — the declared outcome at the largest size on the page, the
  engine's beside it in smaller mono with a caption naming which is which, `budget_exhausted ·
  turns` per § The three axes — and under it, only when memory was the trouble, the warning line
  `capacity.md` § Memory describes.
- **Three figures on one line**: turns, usage in windows (the exact weighted tokens in its title),
  duration.
- **Stream · Manifest · Wrote**, a segmented switch, because the strip's tabs belong to the ticket.
  It is the page's one switch. The stream is the harness's events drawn as the transcript draws
  them, newest at the bottom, a bounded pane tailed while the job runs; its head says how far it got,
  and holds a quiet `raw log` toggle and — only while a failure is on screen — a mono link in
  danger ink, `✗ 2 failed · first ↑`, that jumps to the first. **On a phone the time is said once a
  minute**, as a small divider over the row that opens it, rather than on every row, where the
  same `21:50:56` nine times took a fifth of the width. The manifest is the pinned input manifest,
  led by **the prompt the job was given**, folded: it is an input like the rest. Wrote is what the
  job produced, each with its type's tile and linked to its version.
- **Its plan** — the agent's latest `TodoWrite` — **and its facts**, and **the earlier attempts at
  this state in this visit**, each linked. The facts name **the harness with its model**, `Codex ·
  gpt-5` (a command has none), and its usage, *converted from dollars* where the migration made
  it; **its runs** are listed under the plan, each in windows with the exact weighted tokens in its
  title and its tokens by kind beneath (`120k fresh input · 0 cache write · 3M cache read · 90k
  output`) — a converted run has none and says so.
- A job whose runs held project secrets has a *secrets* fact, a line per run — *`STRIPE_TEST_KEY`
  v2, `SENTRY_TOKEN` v1* — by name and version, **never a value**.

**On a wide screen** (`21a`) what it did is on the left and where it stands — plan, facts, earlier
attempts — on the right; **on a portrait screen** (`21b`) plan and facts are a band under the title
and the transcript takes the rest of the height.

**There is no Stop on a workflow job's page.** The handoff draws one; no operation stops a
workflow job, and a stop with nothing behind it is a hidden refusal. Cancelling the ticket is the
way to end its work, from the ticket's details.

**A command's page** is the job page with what a command has: its exit status as the largest thing
on it, the script as it ran, the argument vector as JSON — it reached `exec` as a vector, and
joined with spaces two arguments would read as one — the commit it ran at, its timeout, the job
that invoked it, and its log.

## Chats

### The list

`/chats`, `12c`. A top-level page: its title is the switch. A conversation that waits on a human is
already in the queue; `/chats` is for finding one again — the one about the parser last week, the
one still running whose page was closed.

**A list of conversations is ordered by when each was last used, and the project plays no part.**
That is the last thing said in it, by the person or the agent, newest first; a conversation where
nothing has been said yet — a workflow step's chat waiting for a machine, whose agent speaks first —
is placed by when it was started. It is one rule for `/chats`, a project's Chats and a ticket's,
because all three read it from one function (`Forge.Conversations.summaries/1`). `/chats` and a ticket's are one component,
titled by `Conversations.title/3`; a project's Chats (`7c`) draws its own rows, titled by the last
thing said in each, which is what tells one project's conversations apart. The **live** ones — holding a machine, waiting for one or running
on one, the set that gets *End* — are a section above, headed **Live · N**; the rest follow under
**Earlier**, drawn only when a Live section is. With nothing live there is neither heading and the
list is just the list; a section with nothing in it is absent, not empty, and with no conversations
at all the page says so in its own words. A row is the title (§ A chat), the project and the ticket step it
belongs to, its last line, and the time it is ordered by — a live row's in the colour of running,
with `▸`. The subline counts them: *1 live · 14 in all*. The list follows what is said without a
reload, woken by conversations it can show (`Events.subscribe_chats/0`: a message names its project
and ticket, and a list matches that before it reads anything) and, on a project's Chats, by a
change to a ticket of a project the viewer is in, which is what draws a workflow step's chat the
moment its ticket enters the step. A row moves as things are said, and a conversation starting,
ending or going idle moves it between the sections. Because a row can move under a finger, *End*
names the conversation it will end — its project where the list names projects, its ticket, and
the start of the last thing said (`End parser #12 "why does…"?`) — and confirming ends the row that
was tapped, whatever has moved since. *End* is a quiet word in danger ink at the row's top right,
beside its time, not a button on a line of its own; asked, its sentence and buttons take the row's
width under it.

**The list's composer starts a chat in place**, in the dock, with a project picker beside it — this
is the one surface with no project to carry, so the one place a create affordance has to ask. The
picker offers the viewer's projects only (the one used last first), the event looks the name up
among those and nowhere else, and the operation refuses any other; a started chat opens. On a project's
Chats the composer is the same with the project fixed.

**A list row that navigates may still carry a control, beside it and never inside it.** The list
ends a live conversation from its row, because a live row is a machine running and the alternative
was opening it first. What a list may never offer is deleting a conversation: they are kept for
ever (`conversations.md` § Lifetime), and the affordance that exists is the one that stops it
costing something. Ending one does delete its *branch*, unless the branch would not merge cleanly,
so its confirm says so — the same rule, in the same words, on the list and on the conversation's
details, from one definition, so neither can understate it.

### A new chat

`/chats/new`, `12d`: the project (fixed when opened from a project or a ticket, which states which
and asks nothing — there is not even a hidden field, the view holds it), the secrets, **the
harness**, a switch defaulting to the project's and never folded, since it decides which model
and effort are offered (Claude Code's from the workers and credentials; Codex's model typed, its
effort from the levels the machines offer for Codex), then the model, effort, memory and cores
folded to one line — *Machine · 8GiB · 4 cores*, the platform's
figures until one is typed — because they are rarely changed; the fold opens on its own while any
of them holds something, and **last the first message**, directly above *Start the chat*: it is the
field a person finishes on, and Enter sends from it. *Start the chat* is the dock's. *Ask about this* on a ticket links here with the reference in the first message.

**A conversation's secrets are chips, none picked**, only when the project has any: each secret's
name, and two sentences saying what picking one means — *Set in its environment by name. Anyone in
this project can ask it what they are* (`secrets.md` § Conversations). A name deleted between
drawing the page and submitting it is refused by name, and the conversation is not started without
it.

### A chat

`/chats/:id`, `15a`–`15f`, `18e`. The top bar: the conversation's title over its subline (its
state, *responding · turn N*, *waiting on you*, *idle*, *waiting for a machine*, *stopped 2h ago*),
and its project or ticket on the right. **A conversation has no stored title**: it is called by the
first line of what the person opened it with, a workflow step's by its ticket, and one with nothing
said yet *Chat* (`Forge.Conversations.title/3`) — on its page and on every list. Tapping the title
drops **the details** (`15e`): its facts, **the machine it holds** — its provider, memory and
cores, to every member; linked to the machine's page only for the machine's owner, because the
machines pages are the owner's (`identity.md` § Workers); none when it holds none — the usage
lines written out, what it has spent, the secrets it holds by name (*holds `STRIPE_TEST_KEY`*, and
for one picked when it was opened and deleted since, *`GONE_KEY` was deleted and this conversation
no longer holds it* in warning, from its latest run — `secrets.md` § Conversations), and **End it**
with its confirm and the ending rule in its words. Views: Talk · Changes · Docs · Activity.

**The merge is a neutral decision row** (`18e`): `⑂` the branch, its size and commits, Merge in
outline, because nothing is waiting on anyone. Its panel shows the commit message read-only and
Merge. **Where no `commit-message` version exists the row says there is nothing to merge yet and
draws no button**, since the merge would be refused (`conversations.md` § Commits). **Where the
branch does not merge cleanly**, the row's meta says so in red and its button reads **Resolve ›**
and goes straight to Changes — no panel, since a panel with Merge disabled and a link onward was two
taps more for an act that would be refused — where the conflict is drawn with its two ways out as
rows (`15c`): *ask it to rebase* fills the composer with the request and the paths, so what is sent
can still be edited, and sends nothing; *take it by hand* is the `git fetch` of the branch from the
project's clone URL, with a copy button. The composer is drawn on Changes as well as Talk for that.
**On a wide screen** Changes stops being a view: the branch, its commits, its commit message,
*Merge into main* and the facts sit in the right column beside the conversation (`15f`), the
Changes tab and the merge row are not drawn there, and a merge refused from that column says why in
it; on a conflict the column draws the two ways out where *Merge into main* would be. End it stays in the details.

### Talk

`15a`. The transcript, pinned to the bottom per § Motion and structure, then from the bottom up:
the composer, the now line, the plan band, and any open question's card.

- **The transcript is the turn in the order it happened**, not one message per speaker. A turn
  is its text blocks with the agent's actions between them, read from the event log in sequence.
  Each text block is its own bubble — the person's and the agent's told apart by side and ground,
  a run of one speaker's bubbles headed once (*you · 3m*, *agent · turn 4*) — and two blocks are
  two things said on either side of some work: joining them ran the last sentence of one into the
  first of the next.
- **A question the agent asked is said in its bubble, not shown as its block.** Each ` ```question `
  fence is drawn as a quote of what it asks and its options' labels; the answer is the question
  card in the dock. A fence the document's parser does not read as a question (one inside another
  fence) stays as written.
- **Actions sit between the bubbles**, unboxed, one mono line each, in info per § Colour:

  | Call | Line |
  |---|---|
  | `Edit`, `MultiEdit`, `Write`, `NotebookEdit` | `✎ path +n −m`; expands to the change as a small diff |
  | `Bash` | `$ command` and `✓` or `✗`; a failure shows its excerpt's first lines unasked |
  | `Read`, `Grep`, `Glob`, `LS` in a row | one line for the run — *read 6 files · searched 2×* — expanding to the list |
  | `TodoWrite` | the plan band, redrawn in place rather than repeated |
  | `Task` | `⤷ description`, the subagent's own calls (by `parent_tool_use_id`) folded under it |
  | `WebFetch`, `WebSearch` | `↗ url`, `? query` |
  | anything else | `name` and its summary as the job page draws it |

  Any result with `is_error` is in danger with its excerpt shown. A retry or a rate limit is not a
  line: it is what the now line says (below). Notices, `control` and `delivered` are not drawn, per
  § Motion and structure.
- **A line of the platform's own, where the turn it is about stands.** The transcript is what the
  two sides said, with one exception: a turn whose work did not reach the branch
  (`conversations.md` § Commits). One warning line, `△` and a sentence, unboxed, after that turn's
  last bubble — and wearing **neither speaker's heading**, because the platform said it and a turn
  that only acted has no bubble of its own to put it under. It is not a harness `notice` event,
  which is still not drawn. It can only appear on a turn that has *ended* — it is what closing the
  turn found — so it never interrupts a reply being spoken; and it ends the agent's run, so whatever
  the agent says next is headed again.
- **Live, every line; finished, each run folded.** While a turn is open its action lines appear as
  their events arrive. When it ends, each run of actions between two text blocks folds into one
  line — *11 actions · edited parser.ex, lexer.ex · mix test ✗→✓* — that expands in place. An error
  in a folded run keeps its line visible, so a scroll back through the transcript is the
  conversation plus whatever went wrong.
- **A message keeps the line breaks it was written with.** A chat message is not a document: a
  single newline is a break, where Markdown would join the lines into one paragraph. On a phone,
  Enter is how a line is ended, so a transcript that drops single newlines drops the shape of every
  message typed there. This is a rule of the transcript's styles; § Documents is unchanged.
- **The plan band**, while a turn is open: the agent's latest `TodoWrite` list folded to its current
  item, with a progress track, so where the agent is in its own plan is visible without scrolling;
  it opens to the whole checklist. While it is drawn it is the plan: the open turn's `TodoWrite` is
  not drawn in the transcript as well, and an ended turn keeps its own.
- **The now line**, while a turn is open: the call that has no result yet, in words — *running mix
  test*, *editing lexer.ex*, *reading router.ex* — or *retrying (2 of 10)*, or *rate limited,
  resumes 14:00 UTC*, or what memory is doing when that is the latest thing the turn reported —
  *a process was killed for memory (1 OOM kill · peak 2.0 GiB of 2 GiB)*; with no call in flight,
  while the agent is writing, an ellipsis. Static text, nothing pulsing, with **Stop** on the line.
  With a draft typed, Send becomes **Interrupt and send**, and the form carries a field saying so,
  drawn with the button from the same state, so what is sent is what the button named. **The plan
  and the now line are one row** above the composer at every width — `3/5 ▾ running mix
  assets.build … Stop` — the band giving its current item's words to the now line below a wide
  screen, where both drawn in full were two bands for one fact (`15f`).
- **The question card** for the last message's questions docks above the composer while it is open,
  so the answers are under the thumb: every question the reply asked and one Send that posts them
  as a single message (§ The question card). The composer stays for anything the card does not
  hold.
- **The composer** is the `Composer` primitive in the 64px dock: a 48px field, fully rounded, that
  grows from one line to six and then scrolls inside itself, with send as a 40px round icon button
  inside it — never a filled button — labelled for assistive technology. **Enter sends where the
  primary pointer is fine; on a coarse pointer (`(pointer: coarse)`) Enter is a new line and only
  send sends**, because a phone keyboard has no shift-enter and a composer that cannot take a second
  line cannot take a message. The hint names the gesture that applies and is drawn only for a fine
  pointer. This holds everywhere a message is typed. A box that is one field of a form holding more
  — a question's own words, a decision's note — is the same box with Enter a new line at every
  pointer and no hint (§ The affordance rule). **The composer only replies**: no decision is ever in
  its row.
- **A stopped conversation** (`15d`) has no composer — a Send offered there would take a tap and
  lose the message. The transcript dims slightly, the reopen sentence takes the composer's place in
  both its variants, branch kept or branch gone, and **Reopen** takes the dock.

## The Accept area

A chat step's Accept, `16e`–`16i`. A ticket resting in a **chat step** (`workflow-grammar-v1.md` § Chat steps) says so in
its Steps — *This step is a conversation* — with a link to it, and **the conversation's page draws
the ticket's frame**: its title is the ticket, its decision row the step's Accept, and its strip the
ticket's, with Talk the conversation and the other views leading to the ticket's (`?tab=`); the
conversation's own `?tab=` is not read there, since those views are the ticket's, and its subline is
the ticket's own — number, the state's mark and name, its status when not active — with the step's
visit after it. Both
pages draw Accept from the same component and the same state: `ForgeWeb.Components.StepAccept`
drawn from one read model, `Forge.Steps.view/2`.

**Before the step's document has its first version there is nothing to accept** (`16e`): no row,
nothing amber, the screen is the conversation. **Once v1 exists the row appears** (`16f`): the
document, its version and age, *Read*, and an amber Accept. It updates to each new version and
stays on every view. **Tapping Accept drops the confirmation** (`16g`), and the question card folds
away behind it, since answers no longer count once the step is accepted.

The panel lists each document the step declares, and any an outcome approves that it does not, with
its latest version, whether it is written, and whether this visit's conversation wrote it or it is
from an earlier visit (or, for one the step does not declare, an earlier step). A step with one
outcome shows no picker; a step with several shows each outcome as a choice row saying where it
leads and whether it counts as approval, **with none preselected and Accept disabled until one is
picked** — and until then it reads *Pick an outcome*, saying why it does nothing rather than naming
an act it cannot take. The handoff preselects one; this keeps the earlier rule, because the outcome decides
where the ticket goes and a default is a decision taken for the person. With questions open it
warns *N open questions will stay unanswered* and offers *Answer first* (§ The decision row). The
form carries the version number of each document as it was drawn, in hidden fields, so what is sent
is what the DOM showed; a newer version since refuses it and redraws.

States, each saying what to do rather than going blank:

| State | The row and panel say |
|---|---|
| Nothing produced yet | no row; the Steps line names the documents expected, and that they appear as the agent writes them |
| A turn in flight | the row, its button disabled, and that it is waiting for the reply to finish |
| Ready | the documents with versions, the outcome rows, Accept |
| Refused | why in words, inside the panel (no version of X, the step has moved on, the outcome has no edge or its `max` is spent, a newer version arrived) and what to do |
| Every way out blocked | no outcome can be taken now, and for each one why: no edge, `max` spent, or an approved document nobody has written; no button |
| Dormant | the conversation is stopped with **Reopen**; Accept still works if the documents exist; never "run again" |

The outcome pick and an open confirm live in a form with an `id` and `phx-change`, so they survive
a reconnect (§ A reconnect is not a reload). Outcome, state and document names are text, cut to the
line where they stand alone and wrapped (`overflow-wrap: anywhere`) where they sit in a sentence. A
step waiting for a machine, a slot, a credential or a missing secret says why on both pages: under
the step in Steps, and in the conversation where the reply will appear. Steps draws an accepted
step's outcome as a job's row does.

**On a desktop** (`16h`) the row is pinned under the title row with Accept on the right, the
question card keeps the split pane at the bottom with its own Send, and the two never touch.
**On a wide screen** (`16i`) the document opens beside the conversation instead of over it, with
the passage behind an open question highlighted, and Accept's panel is anchored to its button.

## The project page

`/projects/:name`, `7a`–`7h`, `21c`–`21e`. The project's own page: its top bar is the project's
name over *12 open · 2 waiting on you*, with **`+ New`** in the right slot; tapping the title drops
**the details** (`7f`); the views are **Tickets · Merge · Chats · Workflow · Proposals**.

**There is no board.** `/board` — every project at once, a column per state — is gone, and so is
the project page's own board. What the board answered is answered by Tickets, which says what each
ticket is doing, and by the Workflow view's map, which puts the open tickets on their states. Its
four-row cap, its lanes and its "N more" went with it.

### Tickets

`7a`. **Every open ticket, as one list: what waits on you first, then the rest by last change.**
A row is three lines with 14px around it: the number, the title and how long ago it changed —
left out when what the ticket is doing already carries an age (*stuck 25m*, *waiting 12m*,
*running 4m*), so one age is never said twice; a compact workflow track, the state, what the
ticket is doing and — on a phone only once it has spent more than half of what its workflow allows
it, in the warning colour — its usage so far (a figure the same on every row was noise, and what
spilled a row onto a fourth line); and the most recent thing that happened, in words — the agent's latest line, or the decision a waiting ticket
needs, at full strength. Colour follows meaning only: amber waits on you — a stuck ticket included — and info is running; the row of a ticket waiting on you carries the amber edge. A paused ticket says
`paused · spend` where its activity would be (`capacity.md` § Four exhaustions). A queued ticket
says *queued 2/5*. History — done and cancelled tickets — folds beneath, led by a `▸` that turns
when open. The switch above is **All · Waiting · Running** with counts in bubbles, and *Running*
means a job running now — not a ticket queued to merge or waiting for a machine, which the map
draws with the running ones. The table's usage is a right-aligned figure.

### Merge

`7b`. **The merge queue**, in order, under its own name (never "the queue": that is the page of
decisions): the place as a quiet 13px rank numeral, then the ticket's number and title (wrapped
and cut at two lines, markup shown as text), its state in mono (so *integrating* while it is) and
what is happening to it or what it waits for in a sentence — not the place again, which the rank
says — and **Take out** behind the same confirm as on the ticket. Beneath, **recent
merges**, which answer "did it land?" without opening each ticket, each sha plain mono. Empty, it names the edge that
would fill it when the repository's workflow queues one, and otherwise says only that nothing is
waiting.

### Chats

`7c`. **The project's conversations**, in the order and the sections of § Chats, every one drawn:
nothing folds away. A row is named by **what the conversation was opened with** — the string the
Proposals view names it by — with its last line beneath (a row named by its last line could not
be told from another that ended the same way; one with no opening yet is still named by it), and
its proposals are counted on it — every proposal the conversation wrote, decided or not. Turns and
spend are left out while they are zero. The composer starts a chat in place with the project fixed, and the page then
opens it. A plain conversation has no state, so without this a chat would be a thing you
can start from the page and then cannot find from the page.

### Workflow

`7d`. **It shows the workflow and never edits it.** A workflow is `.forge/workflow.yml` — or one
file per ticket type under `.forge/workflows/` — in the project's own repository, read at the
ticket's base commit and pinned at admission, so it versions with the code it governs and there is
nothing for a form to edit (*Edited by pushing, not here*). What the view shows is the
*repository's current* workflow — the one the **next** ticket will pin — which is not necessarily
the one an open ticket follows, because every ticket pinned its own at admission. On a project
whose workflow has just changed those differ, and saying which is which is the point rather than a
detail.

It is headed **How a new ticket moves**, with the pinning said once as small print under it.
**A vertical flow on the line-and-dot Steps uses**, so the two read alike: each state with its
topology mark — in ink, not the running blue, since a workflow's states are not live — how many
open tickets rest there (the phone has nowhere else to see it), its job in words (*runs
triage.md · writes triage.md*), its budget in turns and windows, and where it goes on
which outcome, with approvals and queueing in the link colour. **Types are a segmented switch**
with each type's open tickets counted in it, **showing first the ordinary type with the most open
tickets** (the first alphabetically drew a map of two dots on a project with six tickets of
another type), each under its name and description, a type that does not parse showing its reason; what
`.forge/workflows/` holds that is not a type is listed with why, since it blocks nothing and would
otherwise be invisible (`ticket-types.md` § The project page). The release workflow is one of the
types, and says it is the release.

**On a portrait and a wide screen the workflow is a map** (`7g`, `7h`): a box per state with its
job and budget, states joined left to right in declared order, skips and loops drawn as arcs, and
the open tickets as dots on their states, counted in figures in the box and each dot named on
hover — which is what the board used to show at a glance.
Clicking a state filters the tickets table. It is drawn on the server, as SVG, from the parsed
workflow.

### Proposals

`7e`, `8a`–`8g`. **Proposals are the project's decisions** (`ticket-proposals.md`), decided here and
nowhere else.

- **Grouped by where they came from** (`8a`), newest batch first: a chat that ended with three
  ideas, a ticket split into four. A group is the **job** that wrote them, so two runs of one
  ticket are two batches. Each group names its source — a chat by what it was opened with, or a
  ticket by number — in words, *From the chat “…”*, *From ticket #44 · …*, with no state mark (a
  `▸` there read as a running ticket) — and its proposals are indented under it on a 1px rail. A
  row is the title and the first two lines of the body.
- **The reader** (`8b`) shows one proposal at reading size, where it came from above its title, and
  **Admit** (with the type to admit it as, on a project with types), **Skip** and **Decline** in
  the thumb zone — on a phone they stick to the foot while the proposal scrolls, and the list's
  tabs and *Select* give way to the reader's own *‹ Proposals*; each moves to the next proposal.
  **Admit is a decision** (amber, `◆`, no `›`: it writes a ticket), and where there is a type to
  choose it waits, disabled with the reason beside it, until one is chosen — the suggestion is
  chosen for you when it is a type here. One box takes a **note, optional**: kept with the
  decision either way, a reason when declining. Skip writes nothing: it is the page's. The composer sends a question **to the source chat**, so a vague proposal can be
  sharpened before it becomes a ticket; a proposal a ticket's job wrote has no chat to ask, and
  draws no composer.
- **Selecting** (`8c`, `8f`): *Select* beside the list switches on selection (a long-press, which
  `8c` draws, is not built: it would be the page's only gesture code), and each row becomes a
  checkbox rather than a link; a group's header gains a box
  that selects or clears the whole group, showing a dash when only some are picked. A bulk bar with
  the type, one reason and the two verbs sits at the foot, above the strip. **Declining several takes one shared
  reason**, optional as it is for one (an empty box declines them with none), and is refused
  whole — nothing written — when any one of them is not the actor's to decline. *Admit N* waits
  for a type as the reader's does.
- **History** (`8d`): admitted proposals link to the ticket they became and show where it is now;
  declined ones keep their reason (`○ declined` in ink-3: a person's decision, not a failure), and
  **can be reopened** (`ticket-proposals.md` § Deciding says who may and what it returns to); one
  reopened since says so instead of offering it again, drawn faint, and **is not counted under
  Declined** — it is open again, and counted in both it was in two lists at once. The three
  lists' counts are the switch's grey bubbles.
- **On a wide screen** (`8e`) the list keeps the sources and the reader sits beside it; **on a
  portrait screen** (`8g`) the reader stacks under the list. Not built: the open tickets a proposal
  touches (nothing relates a proposal to a ticket's files), and the portrait divider's drag.

### The details, `+ New` and the release

**The details** (`7f`): the project's facts, its clone URL with a copy button, its mirrors' state
(a failing one says so), and links to Settings, Repository and **Releases** (§ A project's
releases), with the latest release as a fact in one line when there is one. The worker seed is a
fact only when there is one. **No raw event names**: a list of *artifact.version_written*, *job.harness.text*
said nothing an operator could read, so it is gone until the activity sentences a ticket's own
Activity is written in can say it (UX pass, C7).

**It says which forge release the project was written for** (`changelog.md` § The project page).
The details always have a *forge release* fact beside *default branch*: the release recorded in
`.forge/forge-release`, e.g. `0.17.0`, or *not recorded*. It is read from the tip of the default
branch, the same commit the Workflow view reads, and redrawn whenever that is, so a push to the
default branch is not drawn live, as it is not for the workflow. The fact and every notice say
**forge** in words, so neither is read as the project's own releases. A notice is a `warning`
notice at the head of the page, above every view — on a phone, where one view is drawn at a time,
it is never hidden behind another — with nothing in it folded away. Five cases, by the rule in
`changelog.md` § The one list:

- **Behind** (older than the release the node runs): *Written for forge 0.17.0. This node runs
  forge 0.19.0.* It shows whenever the project is older, even when every newer section says there is
  nothing for projects.
- **Not recorded**: the project records no forge release, so it counts as forge 0.1.1, then the
  node's release.
- **Newer than the node**: written for a newer forge than the node runs, both named, and features
  it uses may not work here.
- **Not a release**: the file does not name a forge release, with what it holds quoted as plain
  text, cut short (or, over 64 bytes, said to be too large).
- **Current**: the fact alone, and no notice.
- **No default branch** (nothing to read from): the fact says *not recorded* and no notice is
  drawn, because the Workflow view's "cannot take a ticket" notice already speaks for that
  repository.

*Behind* and *not recorded* carry a link, a full-size target, that opens a new chat for this project
with the upgrade request already typed in the message box and naming the release the node runs.
Nothing is sent until the person sends it, and a warning nobody can act on is a lie (§ Semantics
that must not be lost). Every member who can see the page sees the fact, the notice and the link,
since every member may open a conversation; nobody outside the project sees the page. There is
nothing typed on the page, so a reconnect redraws the same.

**`+ New`** opens a sheet (`21c`). On a phone it is the top bar's right slot, a link to the page's
own address with `?new`, which opens the sheet when the page mounts; from 768 the page draws
*+ New ticket*, *+ New chat* and, for an admin, *Release…* above its sections. The sheet holds
**New ticket**, **New chat**, and for a project admin **the
release block**. **A project admin sees the release block, and nobody else does**
(`ticket-types.md` § Releases). It is in one of five states (`21d`): *ready*, headed *Release* over its file, a form holding one
optional note box (held across a rejoin, and sent with `phx-disable-with`) and **Start the
release**, an outline button because starting a release creates a ticket and approves nothing;
*open*, a link to the release already open and no button; *none*, the sentence saying no workflow
in the project sets `release: true` and where to set it; *several*, naming both files and saying
to unset one; and *broken*, the file and why it does not parse, with the button disabled. A refusal
is said in words inside the sheet and keeps what was typed; where the sheet has since lost the box
(another admin's release is open, the flag has moved) the note is shown as unsent text beneath the
sentence. Success is a toast — *Release started as ticket #46* — and the page opens on that ticket.
A member who is not an admin is drawn nothing, and the server refuses the event whatever the page
showed.

**On a portrait screen** (`7g`) the views are the title row's tabs, as a ticket's and a chat's
are, and one view is drawn at a time across the whole column: the tickets as a table whose title
column takes the room the rest leave, the map on Workflow, and the facts in the title's details.
`7g` drew everything stacked beside a rail of facts; at 1080 that left the title column 80px and
every title three lines tall (UX pass, C1 and A32). **On a wide screen** (`7h`) there are no views
(the tabs are not drawn): the map is on top, the tickets table takes the left with the facts
under it, and the right column holds what needs a decision (proposals in brief, each opening the
reader, rather than admitted in place), what is landing and the conversations; a view the address
names is scrolled to, so a link to the workflow lands on it. `+ New chat` is the action row's
alone, and *Release…* is an outline like its neighbours. The Proposals view is the page by itself, back to the project from its title row. **It keeps the project's
title and `+ New`** — it is one of the project's views, as the strip says, and a title that
turned into *Proposals* with the project in the right slot made the person wonder whether they
had left it; the subline says what it holds, *8 proposals · 3 sources*.

## A project's releases

A release that ended `done` leaves a record (`ticket-types.md` § The record, the tag, the history),
and three surfaces draw it. **Nothing on them is a form and none of them writes**, so a reconnect
has nothing to lose and the page redraws the same records (§ A reconnect is not a reload). Who may
see them is who may see the project, and the guard is the project page's own
(`ForgeWeb.Access.project_by_name!/2`): its members. A node admin is not implicitly a member
(`identity.md`), so to a node admin who is not one, as to anyone else, each address is "not found",
exactly as the project page is. Both pages are in the project's frame: its strip of views leads back
to the project page, the context is the project, and the back is the project (the list) or the
list (a release).

- **`/projects/:name/releases`** lists the records, newest first, reached by `Releases ›` in the
  project's details beside `Repository ›`; its subline counts them. It shows the newest 20 and a
  *Show more* control that is a link to `?shown=40`, then 60, and so on, so the count survives a
  reconnect and a reload, and every record is reachable. While the project has a release ticket
  open, one line above the list names it as in progress and links to its ticket; it is not a record
  and has no page. With no records the page says a release appears once one ends `done`; when no
  workflow of the project sets `release: true` it says that instead, since that is what would fill
  it.
- **An entry** shows the version as its heading, linking to the record's page (a plain "no
  version" when there was none); what became of the tag, in words; the date, the commit, short,
  linking to the repository's commit page, and the ticket it came from, as facts; the notes,
  rendered as a document is on the Docs view (`ForgeWeb.Markdown`, never raw HTML); the files,
  each a download with its name and size at the address of its artifact version (§ Addressable
  artifact versions: a large or binary file is a download and never rendered); and the links, each
  shown by its label.
- **What became of the tag** is one of four sentences, the same on all three surfaces
  (`ForgeWeb.ReleaseComponents.tag_words/1`): *Tagged vX.Y.Z*; *vX.Y.Z was already taken by
  another commit (abc1234) and was not moved*; *Not tagged: <why>*; *No version, so no tag*.
- **`/projects/:name/releases/:id`** is one record, at its own id, which never changes and is
  unique when two records share a version; its title is the version and its subline the project
  and the date. It shows everything the entry shows. An id that names no record, names another
  project's, or is not an id at all is "not found".
- **The project page** shows the latest record as a fact in its details — its version, its date
  and what became of its tag, linking to its page — and nothing when there are none. The
  `Releases ›` link is there either way.
- **Live.** A release that concludes appears on an open releases page and project page without a
  reload, by the ticket-changed event both already listen to.
- **The phone.** One column; every download, link and *Show more* is a full-size tap target
  (`--target-min`, § The phone). A long version, label, name or URL wraps and never stretches the
  page. Markup in a version, a label or a file name is text. A record with 100 files lists 100.

## Creating things

**A project** is made rarely and from nowhere in particular, so it is offered on the projects page
— in the dock while there are none, beside the list otherwise — and from the title menu's Projects.
**A ticket** is always made *for a project*, so it is offered in that project's `+ New` and on the
create view that has just made one, and nowhere else: the queue is an inbox and has no project to
make a ticket for.

**A release is never offered in the ticket form's type select** (nor in the proposal type select):
the form behaves as though that type did not exist, and a project whose only type is the release
says so the way a project with no workflow does (`ticket-types.md` § Releases). The release block
is the one way to start it.

**A ticket form reached from a project does not ask which project** (`12e`). It says which one, as
an identifier, and the select appears only on the bare `/tickets/new` — a route nothing links to,
kept so the address works and so the no-projects-at-all case still has somewhere to say so. **The
form names the first step and its budget before you admit**, from the chosen type's workflow:
under *First step*, the state by its mark with its turns and windows beside it, and its job (the
prompt and what it writes) in small print. The type's description is the type select's hint.

**A conversation is the same shape** (§ A new chat): reached from a project or a ticket it asks
nothing; the chats list, the one surface with no project to carry, asks.

A project and a ticket are made in the product. **A workflow is not** (§ Workflow). The create views
are pages with a back row.

**A new project cannot take a ticket yet, and the product says so rather than failing** (`11c`,
`11d`). The repository it just made has no workflow, so admission would fail on a parse error
naming a file the operator has never seen. Instead:

- **The form is two fields**, its errors under the field each belongs to, with **a preview of the
  clone URL the name will make**, which catches a typo before it becomes the repository's name. The
  naming rule under the field is the one the platform enforces, and **it is checked as it is
  typed**, by the changeset the submit runs: a name it would refuse says so under the field as the
  whole rule in a sentence, and the preview is struck rather than presenting it as the address you
  will get. The preview is drawn from the first render, `<name>` standing in while the name is
  blank, so it never appears under the finger and pushes *Create it* down. What happens to the
  empty repository is said once, as small print under the button; the next screen says the rest.
- **Creating a project ends on what to do next, not on a redirect**, with its routes in this
  order: **a conversation that writes the workflow**, offered as the primary action; working in it
  by hand, with the clone URL and a link to issue a token; and a line saying the first ticket is
  admitted from the project's `+ New` once the workflow is merged, linking the project — not a
  button to the ticket form, which until then can only say it is not ready. **While the project
  can run nothing** — the projects page's own answer, no template or machine, or no credential —
  the routes are led by saying so, with where each is added (the templates page, the credentials
  in your settings), and the chat is an outline that says it runs once there is somewhere to run.
- **It used to say to clone the repository and push a `.forge/workflow.yml`, and at the time that
  was not possible.** `pre-receive` accepted a write to the default branch from the platform's own
  merge and nothing else, and every credential was scoped to one branch which was never that one.
  Work still reaches the default branch that way — a branch, read and merged — and bootstrapping a
  *workflow* is not an exception to it, which is why a conversation is the primary action here
  rather than a special case in the hook.
- **Importing a repository that already exists is the exception**, because there is no branch to
  merge and no conversation that can produce one. That is what the default-branch token is for,
  and the create view says so beneath the clone URL rather than sending the operator to a terminal
  to find out. See `git-hosting.md` § The default-branch token, and what it costs.
- The ticket form resolves the chosen project's workflow *before* the operator types anything,
  and says plainly when there is none — a warning notice linking a chat to set it up (or fix the
  type), with Title and Body disabled until it can take one. A form that accepts a title and a body and then rejects them
  for a reason in a third place is the failure being avoided.
- **A project with more than one ticket type is asked which, and nothing is preselected**
  (`ticket-types.md` § Admission). The chosen type's description and the state it starts in are
  said beneath it; a type whose file does not parse is offered marked as such and says why when
  chosen, beside the types that admit. One type is stated rather than asked, and the single
  `.forge/workflow.yml` asks nothing about types at all.

Both are checked again on submit — the repository is a shared surface and a check is a moment,
not a guarantee — but the operator is never the one who finds out.

**The clone URL belongs on the project's details, on the create view and on project settings, and
nowhere else.** Those are the moments an operator needs it: when the repository has just been made,
when they have come to change the workflow and have found that they cannot do it here, and when they
are minting the credential to use it with — settings names the URL a token is for, and shows it once
with the token in it. A git URL anywhere else is an invitation to a surface that is not the product.

## The projects page

`/projects`, `11a`–`11e`. A top-level page. It lists the projects the viewer is a member of, one
row each, and nobody else's (`identity.md` § Read scoping).

**A row leads with what needs you and what runs**: how many items wait on the viewer in that
project — the amber count and edge, matching the queue, counted as the queue button counts them —
and how many of its jobs are on a machine now, then the latest thing that happened: its most
recently changed open ticket and the state it is in (*#41 is implementing · 4m*, *#118 is stuck in
review · 1h*), or with none open, when it last merged (*nothing running · last merge 3d*). **A
row with a count names what has waited longest instead**, and how many more (*#40 is stuck in
review · 1h ago, and 2 more*): the count is amber because of those, and the latest-changed
ticket hid them. It is read from the same queue the count is, in the same one read; on a phone a
project that can run nothing still says that in its place (below).
**Projects that wait on you sort first**, by name within each group, and the subline under the
title adds their counts up (*4 projects · 4 waiting on you*). Beneath, its figures: its
open tickets, the templates assigned to it, the permanent machines assigned to it, and the
credentials in its pool that are not revoked. **A project that cannot run anything says so in
danger**, in place of its latest line — "no template or machine", "no credential", or both — for
the same reason a permanent machine that serves nothing does on the machines page: it is the state
that looks fine everywhere else and takes no work. A project runs on a template *or* a permanent
machine, so either one is enough.

**Every figure is counted in one query over every project on the page, never one query per row**:
the waiting counts from one read of the viewer's queue, grouped by project; the running counts from
one grouped query over running jobs in the viewer's projects; the four figures one query each. The
page reloads when a ticket of one of its projects changes, filtered to those projects before
anything is read; an assignment is not announced, and shows on the next visit.

**None yet** (`11b`) says how to get one: make one, or ask someone in one to add you by the address
you signed in with — which it shows, because that is what the person adding them types (§ Project
settings); New project is then the dock's one button, not the top bar's. **From 1024px** — a
portrait screen too, where list rows stretched across 1030px put the count 950px from the name
(`11e`) — the projects are one table: the phone's fields as columns, every zero drawn the same
quiet way, *runs on* holding the figures or, when nothing can run, *nothing can run* in danger
with the reason in its title. **On a wide screen** New project (`/projects/new`) is that table with the
form in the column beside it, where after *Create it* the next steps (`11d`) take the form's
place. Below a wide screen `/projects/new` is the form alone.

## The project's repository

`/projects/:name/repo`, `10a`–`10f`, reached from the project's details. The project page says what
the repository *contains* for the platform — the clone URL, the default branch, the workflow it
holds — and answered nothing about the code: what landed last week, and what the tree looks like
now. Reading either meant cloning.

It is membership-scoped like every other project read, through the same
`ForgeWeb.Access.project_by_name!/2` guard the project page uses, and a non-member gets the miss a
project that does not exist gets (`identity.md` § Projects and members). There is no admin
distinction: a member may already clone the whole repository with a read token, so a page that
shows them less would be a lock on the window beside an open door.

**One 56px bar holds the branch and the view**: the branch picker and a Commits · Files switch. The
branch, the view, the page, the file open (`?file=`) and the path whose history is shown
(`?path=`) are the only state the view holds that is not read from the repository, so all of them
are in the query string and every control patches it — the page is bookmarkable at any depth and
survives a reload. A list or an empty value in any of them is the same as none.

**The branch picker is a sheet** (`10b`), from `refs/heads/` and nothing else — the platform's own
refs under `refs/forge/*` are bookkeeping, not somewhere to look: the default branch first with its
newest commit and age, then each open ticket's branch **of this project** with the ticket's number
(drawn as its step's mark), title and step, then the others, with a search field that matches a
name, and a ticket's number and title. The tickets are read through the project, so another
project's ticket carrying the same branch name labels nothing here. The current branch is marked;
the default branch is the one on first load. An unknown branch in the address falls back to the
default rather than failing, so a stale link lands somewhere real. Choosing a branch is all the
picker does — a row patches the address and the sheet closes — and nothing here creates, moves,
deletes or merges one. Moving branch drops the open file and the history's path.

- **Commits** (`10a`) is the branch's own history, newest first, thirty to a page, each row the
  subject, then the short sha, **the author** and the age, opening the commit. **Newer and Older are
  a fixed foot**, with the range between them (`1–30`). Thirty because a repository with thousands
  of commits must never load them all, and paging because every commit still has to be reachable.
  The page is by position (`--skip`), not by a cursor: a commit landing between two loads shifts
  what a page points at by one, which is the cost of not holding a cursor the ticket did not ask
  for. **With `?path=` it is one file's history** (`git log -- path`, *History of this file*), its
  head saying so and *All commits* going back to the branch's.
- **Files** (`10c`) is the selected branch's head as a tree. A directory is read when it is opened
  and not before, so a repository with ten thousand files costs the same as one with ten until
  somebody goes looking; reopening one already read draws it from what the page holds rather than
  asking git again. It is **plain identifier text** — mono, no colour, no icons — the way the rest
  of the product draws a path; a folder is told from a file by its `▸` and a trailing slash and
  nothing else, folders sort first, and each level indents 18px.

**A file is its own screen** (`10d`), by a patch of `?file=`: a back row to the tree, the path with
*Copy*, its size and line count, *History of this file*, and its lines. The tree stays in the page
while the file is open, so going back finds it as it was left; a file opened from the address —
a link, a reload — opens the directories it sits in, so the tree shows where it is. **One file is
open at a time**, so the page holds directory *names* and exactly one file's content, which the
512 KB bound below then bounds in full. **On a wide screen** (`10f`) the switch goes: the tree on
the left, the open file in the middle with 40px line numbers, and the branch's history (or the
file's) on the right. The branch picker and, beside it, the branch counts and the clone URL with
*Copy* sit in a row above the three columns rather than in the title row, which is the frame's.
**Portrait** keeps the phone's arrangement under the desktop's title row.

The repository's strip is the project's views (§ The bottom strip), each leading to the project
page on that view; none is this page, so none is active, and no counts are drawn — each is the
project page's figure, read there.

**A file is drawn only when it is small enough and is text.** Its size is asked of git before its
content ever is, so a file at or over **512 KB** says so instead and is never partially loaded.
The whole file Changes opens is read by the same function (`ForgeWeb.Blob.read/3`), so the two
cannot drift apart on either rule. A
**binary** file is listed by name and its content is never rendered — not garbled, not previewed,
not offered as a download. Neither limit is a failure the page reports: both are the row saying
what the file is. Lines wrap rather than scrolling sideways, numbers take 28px, ligatures are off.
A wrapped line's rest **hangs under its own indent and two more** (`Highlight.hang/1`), so it
never starts back at the code's first column, where it read as a new line of code.

**Binary here means `ForgeCore.Document.text?/1`** — valid UTF-8 with no NUL, over the whole file —
and not git's own "a NUL in the first 8000 bytes". git's rule is right for git's output path and
wrong for this one: what the page draws goes out as JSON over the socket, so a latin-1 source file
with no NUL in it at all was drawn garbled, and one whose invalid byte reached the rendered HTML
made the socket's serializer raise and took every LiveView on that connection down. The product
already wrote this rule down, for this reason, where a document is read and where one is served.

**Code is highlighted, on the server.** *Reverses an earlier decision ("no syntax colouring, by
language or by anything else"), settled on the repository's ticket by the person who answered it,
on the grounds that § Colour gives a hue only to something about the work and "this word is a
keyword" would be a seventh meaning. The redesign's refinement reverses it, and keeps that
reasoning's point by the palette: syntax colours are chroma 0.08 at most, so code never reads as
status, and they are spent on nothing else.* `ForgeWeb.Highlight.file/2` highlights with Lumis in
the language the file's name says — a shebang where the name says nothing, as for `bin/check` —
emitting classes (no inline colours) that `code.css` maps to `--syntax-*`, and
**falls back to plain, escaped text** over 100 KB, for a language it has no parser for, and on any
error — logged as a warning, never an error. A file drawn in Changes' whole-file view is highlighted
the same way.

**Opening a commit is its own page** (`10e`), `/projects/:name/repo/commits/:sha`: a back row,
the commit's subject, short sha, author and age, the parent it is read against (a link to the
parent's own page, carrying the same origin; *root commit* when there is none) and the size of the
change, then the files it changed in the same file list a ticket's Changes draws
(`ForgeWeb.Diff.file_table/1`, each row opening its wrapped patch in place), so a binary file in a
commit already reads *binary* with no attempted content. A commit is shown against its first parent, and a
root commit against the empty tree, so the first commit in a repository opens like any other. Two
arbitrary commits are not diffed against each other; only a commit's own change. The back row
carries the branch, the page and the file whose history it was opened from, and on a wide screen
the file open beside the list and the view it was open on, so returning lands where the reader was
rather than at the top.

**Nothing here writes to the repository at all.** The reads are `for-each-ref`, `log`,
`rev-parse`, `ls-tree`, `cat-file` and `show` on the branch page, and `log`, `rev-parse`,
`hash-object` and `diff` on a commit's: no worktree, no checkout, no ref touched and no object
written. `hash-object` is in that list without `-w`: a root commit's diff is read against the empty
tree, which git carries whether or not the repository holds it, so the tree is *named* rather than
written. (`Forge.Git.empty_tree/1` still writes it for `create_root_commit/2`, where a commit will
reference it and `git fsck` would otherwise report it missing for ever.)

The test that holds this records the repository *directory* and not its refs, because the first
version of this page could write a file into it while every ref stayed exactly where it was.

A path or a branch name from the address is resolved by git against its own trees and refs, never
against the filesystem, so `..` in either does not escape anything: it matches nothing and the page
reads it as not found, like any other typo. **That is true of a path and a branch and was not true
of the sha**, which is the harder half of the same question: git reads any argument beginning with
`-` as an option wherever it sits, and `log --output=<file>` writes a file, so
`/projects/:name/repo/commits/--output=config` truncated the project's own `HEAD` with one GET and
`--output=../../x` wrote outside the repositories directory. Two guards answer it now. The general
one is `Forge.Git.run/3`, which refuses a value the caller was handed when it begins with a dash,
marked `{:data, value}` wherever one is passed as a whole argument. **The mark is fail-open and
that is a known trade-off, not a claim about safety**: a future caller who forgets it gets a hole
and no error. The alternative — `run/3` refusing *any* dashed argument unless it is in a
module-level allowlist of the flags this module uses — replaces an obligation at every call site
with one list, and is the better shape if a third site of this ever appears. What keeps the current
rule honest is that it is greppable: a value in `Forge.Git` that is not a literal and is not marked
is visible in review, and the two that are flags' own values (`--skip=`, `--max-count=`) are guarded
as integers instead, because a flag's value is not a position git reads an option in. The
particular guard is this page: the address names a commit, so only a hex object name is read out
of it, and anything else is the ordinary miss before git is reached at all.

**A name that is not text is drawn in git's own escaped form.** A repository may hold a file called
`caf\xE9.txt`, and the platform asks git for paths exactly as they were written — which is what
makes `résumé.md` readable instead of `"r\303\251sum\303\251.md"`. Those raw bytes in a page are the
same crash as a non-UTF-8 patch, one layer down and reachable from a *filename*, so every path
leaves `Forge.Git` through `printable_path/1`: as git printed it when that is text, and C-escaped in
quotes when it is not. `unquote_path/1` is its exact inverse, so such a file still opens and such a
directory still expands — the escaped form is what the browser holds, and it is read back before
git sees it.

## Project settings

`/projects/:name/settings`, `9a`–`9i`, `21h`. Where a project's credentials are issued and its
people and defaults are set. It exists because the product sent the operator to a terminal: the
project hands out a clone URL and says to push a workflow, and `mix forge.git.token` was the only
way to get the credential for either.

**An index of sections**, one row each with a one-line state, by `?section=`, grouped as the
design groups them — Access: Tokens, People; Agent: Harness, model and effort, Secrets; Repository: Branch
and mirrors — with the clone URL and its Copy at the index's foot. **Warning marks something to
look at**: a token about to lapse (live, not a job's, and ending within three days), a secret
nothing receives — *ask an admin* after it for a member, who cannot fix it (UX pass, D26) — and a
failing mirror, named, **in danger**, as its row says it (D17). A row's state wraps to a second
line rather than cutting off the very words that warn (D10). Tokens, people, mirrors, the model and the effort are
drawn only for a project admin; **a member who is not an admin sees only Secrets and Repository**
(the default branch, without the mirrors), and a section asked for by name that is not theirs is
not drawn. Every write is refused without the admin capability by the operation, not the form,
and no form is offered to anyone the operation would refuse.

**One render, three arrangements**, decided by CSS. On a phone the index is the page; a section
replaces it, with `‹ Settings` at its head; and a section's form — Issue a token, Set a secret,
Add a mirror (`&add=1`) — replaces the section, with `‹ Tokens` and so on, while People's *Add
someone* sits at the foot of its rows. **On a wide screen** (`9i`) the index is a 272px column,
the section a table in the middle, its form always in the right-hand column; **on a portrait
screen** (`21h`) the index stays on the left and the form moves under the table, in two columns. A
bare `/settings` on a desktop draws the first section beside the index, since there is room for
both and nothing to choose between. **A section stops at a measure** — 60rem with a table, 40rem
without one (People, Model and effort) — so a field and its button are not 1300px apart (D8). The handoff puts the clone URL in the desktop's title row,
which the frame does not offer a page; it is at the index's foot on every width.

### Tokens

`9b`–`9d`. **A token is shown once and then only described.** Only the hash is kept, exactly as for
the worker token and the operator's API tokens, so the row afterwards can say what a token may do
and when it was last used but never what it is.

The form issues **a project token** (`git-hosting.md` § One project token, two doors), with its
choices visible because each decides what the token can touch: a name; **what git may do** as five
choice rows — nothing, read, write one ticket's branch, push any open ticket's branch, or also the
default branch, the last named after the branch itself and carrying its warning inline, because it
reaches what every job builds on and is a choice worth making on purpose; **what the API may do**
as a segmented switch — nothing, read, or read and change as a member can; and **how many days it
lasts** as a stepper, from 7, at most 365. **Git reads and the API is off, so nothing that writes is
preselected.** A hidden per-render nonce makes a second submit of the same form a no-op, so a double
click makes one token.

**Issued** (`9d`) is the one moment the secret exists on screen — never in a flash, a toast or the
URL: an amber band, because the person has to act on it; each value with a Copy; the `curl` line
only when the API is not off, and the clone URL only when git is not nothing. It takes the form's
place — the whole screen on a phone, the form's column on a desktop — and the dock's button, *I
have copied it*, which says what it confirms, is the only way out.

A row reads top to bottom (`9b`): the name (whole, wrapping: a phone has no hover for a `title`)
and its expiry; its
*capability* in a sentence — *Git: read every branch · API: write* — **in the form's own words**,
which the list and the issued band share: *read every branch*, *write #1's branch*, *push any open
ticket's branch*, *push any open ticket's branch and main* (UX pass, D13: the band said `admin`).
The main-branch choice's inline detail is a warning, with `△`; when and through which door it was last
used, and who issued it. **A token minted for a job says so instead of offering Revoke** — the
engine revokes it when the job ends, and a human revoking one mid-run would fail that job for a
reason nothing records. Revoke keeps its confirm. Expired and revoked rows stay, folded: they are
the audit trail — what was issued, to what scope, and whether it was ever used.

### Secrets

`9e`. **Listed for every member and set only by an admin** (`secrets.md` § Surfaces). A member
reads the names, because a workflow's author needs them. A row is a name, its version and age, then
**who receives it in words** — the commands and states of the default branch's workflows that name
it, each with its ticket type when there are types, how many live conversations hold it, and when a
run last held it. **A name nothing receives is in warning**, because it may be a misspelling. No
value is ever drawn, to anyone, because none is ever loaded — the value field is write-only, sent
once and rendered empty again after a save. *Set* is the section's form — name, value, and the note
that setting an existing name replaces its value — on a phone a screen of its own like *Issue a
token*'s rather than the handoff's sheet, so the four forms here arrive one way; *Delete* is on the
row, behind its confirm, and so is **Replace value**, which opens that form with the name filled and
locked (UX pass, D18). The value is a textarea, for a key of several lines, **drawn as dots until
shown** (D19). The setter reads *set by you@…*.

### People

`9f`. A row per member — **you first, then the admins, then everyone else by address**, an order
that does not move between loads (UX pass, D23) — their address, **their role as the add form's
`member | admin` switch on the row** (A14: it was a menu, popping over the next row), and a 40px
`×` behind a confirm. Changing a role no longer means removing and re-adding someone. Picking a
role commits it (a role is not a draft), except **granting admin and making yourself a member,
which ask first in place**, under the row. The role is changed only on someone already in the
project. **The last administrator's switch and `×` are disabled, with the reason in words**, and the operation refuses it whatever the
page drew (`Projects.put_member/4`). **Adding is at the foot**: an address, as `member` or `admin`.
There are no invitations, so an address needs an approved account: one with no account and one
whose account is still pending get the same answer, *No approved account for that address*, and a
suspended account is named as suspended. The error stays next to the field.

### Model and effort

`9g`, titled *Harness, model and effort*. **One form, one Save**, for the project's default harness
and each harness's own model and effort (`codex.md`), all written in one transaction with an event
each, or none. **The harness comes first**, a switch of Claude Code and Codex: what a state naming
none runs on, and what a new conversation starts on. Then **Claude Code**'s model and effort, as
below, and **Codex**'s: a model typed (nothing lists Codex's models; empty is Codex's own default)
and an effort from the levels the connected machines offer for Codex, a box while none does. A
project that sets one harness's dials never changes the other's jobs. The index row says the
harness and its own model and effort. A workflow state that names its own harness, model or effort
keeps it; a saved change applies to jobs that start after it. **The model's options are the models the
project's credential pool offers** (`credentials.md`) — a machine holds no account and offers none —
beside the aliases the connected harnesses resolve, with a text field when there is nothing to
offer. **Beside *the machine's* the page says what it resolves to only from what was observed**:
the model the project's newest job with no model of its own actually ran on, read from its
harness's init event, labelled as observed — and only since the project's model last changed,
because before that such a job ran on the project's model; nothing when no such job ran, and
nothing while the project names a model. With no model set, a worker passes no `--model` and the
harness picks, which the platform cannot know in advance, so it never claims to. Effort has no
observed value and shows none; it is a switch of the levels the connected workers offer, the
machine's first, rows when more than four, and a box while none is offered. *Discard* puts back
what is stored.

### Branch and mirrors

`9h`. The default branch as a fact, for every member. **Mirrors come first among the repository
facts, because this is the only place one is set or removed**: a table of what each last push said
(`git-hosting.md` § What the mirrors say about themselves), a failing mirror leading with its
status, the remote's own error and when it last succeeded. Add opens a form with five fields, the
token write-only.

## Machines

`/workers`, `/workers/:id`, `/templates`, `12f`, `12g`, `12o`, `14a`–`14f`. A top-level page,
titled **Machines** in copy; the routes stay `/workers` and `/templates`, and code and notes keep the
word *worker*. **Views: Machines · Templates · Credentials**, where Templates and Credentials are
`/templates` with `?view=`. Nothing on any of them waits on a human, so nothing on them is amber;
a template's slots when full are in warning, a limit reached (§ Colour), where `14a`'s caption says
amber.

### The machines view

`/workers` lists the machines, and it exists for one reason the CLI cannot serve: **whether a
worker is connected lives in a registry inside the running platform.** `mix forge.worker.list` is a
different node and so has no column for it — a LiveView runs inside the platform and does.

Two facts that look like one and are not:

- `status` is what the database last recorded: `creating`, `ready`, `busy`, `idle`, `destroyed`.
- **connected** is whether a channel is held right now, read from the registry.

A row that is `ready` and not connected is the state that cost this project a day — a machine that
looks healthy on every surface and cannot take work. The page puts the two side by side so that
reads as what it is. **A row that is busy or ready and not connected draws its dot and *not connected* in danger**,
and its status in ink — never in the running colour or the quiet grey (UX pass, D14). The status
itself is not the problem: on a node that lost its workers every row was red from dot to *busy*,
and *busy* in red read as "busy is an error" (UX re-check #17). A row says
nothing that contradicts it: no *idle* while busy, no release-predates line on a machine that has
reported nothing yet, no *free* figure on a destroyed row or one that never said what it has, and
the harness by its display name (*Claude Code*).

**It lists the viewer's own machines and nobody else's.** A machine has an owner, and a row says
which projects it serves — a permanent machine's own assignments, with a control to add one and an
`×` on each, or for a machine the platform made, the template it serves through and that template's
projects. **The control is one in all three places that assign projects** — a permanent machine,
a template, an inference credential on You (`ForgeWeb.ProjectAssign`): a chip per project with its
`×`, and a select that offers **only the projects not yet assigned**, starting on a disabled *add a
project…*, beside a secondary *Assign*; with nothing left to offer, the form is not drawn (UX pass,
D5 — the select used to open on a project already assigned, and *Assign* then changed nothing). A project a person is not in is not one they may learn exists, so another person's row is
not drawn at all. A permanent machine that serves nothing says, in danger, that it takes no work: it
is the machine-shaped version of the row that is `ready` and not connected (`identity.md`
§ Workers). So does a machine whose release predates a job carrying its credential — it is given no
agent job, and the row says to update it (`credentials.md` § What a worker offers now) — and, before
that, one below protocol 11, which takes **no job of any kind** because tokens are counted during a
run there (`capacity.md` § Spend caps): *takes no job: it speaks protocol 10 and counting tokens
during a run needs 11; update it*. The harnesses a machine offers beyond its first are listed
under it, each with its version and the outcome of its own update (`codex.md`).

**A row leads with its connection dot and what it is doing, in words** (`12f`): the job and its
ticket (*implementing #2 · game#41 · 4m*), the chat (*chat · game · 3m*), or — for a machine the
platform made — when it will go (*goes in 43m unless work arrives*, *goes now unless work
arrives*): the end of its period or of a claim on it, or on a provider billing by the hour the
leeway point of an hour it has paid for (`worker-tier.md` § The hour already paid for). Otherwise
*being made*, *waiting for work*, or *destroyed 2h ago*. **A job's ticket or project is named only
when the viewer is a member of that project**: the machine is its owner's, the work it runs is a
project's, and an owner who has left the project may not learn what it is doing there — such a job
is its step alone. The head carries the short id, `other build` in warning when the release is not
this platform's, the status (`▸ busy` in the running colour, `gone` for a destroyed row), and a
mono line naming where it comes from: the template and its projects, or `permanent` and its own
(*hetzner-cx22 · site*, *permanent · no project*). The head is the link to the machine's log;
nothing that commits is inside it. Under it, in this order, each only where it applies:

- **Its identifiers**: the short id; provider and provider id; `status`; `managed` or `permanent`;
  the release it last joined with, in muted mono, and beside it `current` or `other build`, an
  outdated one in warning (below).
- **A refusal line**, when the machine's last join spoke a protocol this platform does not accept,
  in danger: *refused: protocol 3, this platform accepts 4–8 — update it*. It is drawn from the
  protocol the row recorded and the range the platform accepts now, so it cannot say something the
  next join would not.
- **An unhealthy line**, when the machine said its systemd stopped answering, in danger: *unhealthy
  since 14:02 UTC: <its reason>*, then what happens next — *told to reboot at 14:02 UTC; takes work
  again when it rejoins healthy*, or for a managed machine told within the hour *rebooted within
  the hour, so not again: destroy it, or wait for it to rejoin healthy*, or for a permanent one
  *not the platform's to reboot: restart it, and it takes work again when it rejoins healthy*
  (`worker-tier.md` § A machine whose systemd stops answering). Nothing is placed on it while the
  line is there, so it says so rather than leaving a `ready` row looking assignable. There is no
  control to clear it: rejoining healthy is what clears it.
- **Three meters — CPU, RAM and disk** — each a mono figure over a thin bar, from the machine's own
  last report (`worker-channel.md` § Live figures), re-read on the page's five-second refresh. The
  bars are **neutral and never amber**: a full machine is not waiting on a human. A disk at 95 % or
  more also says so in danger, because a full disk is how a job fails rather than slows. A
  connected machine that has sent no figures reads *no stats — update it* when its join spoke no
  protocol, since a release that predates them is the reason, and *no stats yet* when it did — such
  a release sends its first figures one tick after joining, and every machine rejoins at once after
  a deploy. A machine that is not connected draws no meters at all, because a disconnected
  machine's last figures are a guess about now.
- **What it offers the gate**: memory and cores, each free against offered, with the kinds it takes
  beneath; a machine that never reported cores says so rather than showing an invented figure, and
  one whose own report disagrees with its row shows the report in danger — the row governs, so a
  machine reporting less than its row is one the platform will overcommit. A permanent machine's
  `accepts`, memory and cores are operator-set here (`provisioning.md` § What a worker offers, and
  who says so), behind *Set what it offers* rather than a hover, because an editable field must look
  editable; a managed row offers none — it is replaced, not corrected.
- **A row whose create failed carries the driver's reason.** Until it was drawn, a refusing driver
  was invisible on every surface the operator has.

**Destroyed rows stay, dimmed**, because their log is read after they go — hidden until *Show
destroyed*. The subline adds the fleet up (*3 busy · 1 idle · 1 template at its limit*, a template
being at its limit when it has made as many machines as its maximum); the page counts machines
(`N live · N connected`) beside a row of slots — one per machine that exists, busy ones in the
running colour, then one per machine the viewer's templates may still make, at most 24 — and the
foot says a job is scheduled against what it asked for in memory and cores and against the kinds
a machine takes, and what a job that declares nothing is given. With no template of the viewer's,
a notice says the platform can make no machine for them and offers **Templates** filled: the one
state in which nothing will appear by waiting.

**`managed`** is shown because it is the only thing that differs between a machine the platform may
destroy and one it may not; the second reads `permanent`, and its row stays until somebody retires
it — from its row here, or with `mix forge.worker.retire`. It holds no `max_workers` slot: that
ceiling is a template's and counts the machines made from it, and a permanent worker came from no
template.

**+ Add a machine** makes a permanent machine for the viewer — the form headed *A machine you boot
yourself*, its submit *Make it* (UX pass, D11) — (`identity.md` § Minting a permanent
machine). It asks one thing — the project it serves first, or none yet, from the projects the viewer
is in — and names no owner, because the machine is the viewer's. What it mints is drawn once, in the
shown-once block project settings uses for a token — one component, `shown_once`, for both: the
machine's whole environment, one `NAME=value` per line, with a sentence saying where it goes — a
file named `worker.env` on a disk labelled `forge-config`, or the provider's user data — and that
only its hash is kept. *Done* dismisses it; the row it made is already in the list, *not connected*
and *last seen never* until a machine boots with it.

**Ending a machine is the owner's decision.** A managed row offers **Destroy machine** and a
permanent one **Retire**, each outlined red behind a confirm that says what will happen, from one
definition each so the sentence cannot drift between uses: *the machine is deleted at the provider,
and its N running jobs are requeued*, or *forge forgets the machine, the machine itself keeps
running, and its N running jobs are requeued*. The id is the client's, so
`Workers.retire_by_owner/2` reads the row scoped to the viewer before anything happens, and
somebody else's id posted by hand is *not here*, exactly as for the other decisions
(`identity.md` § Sequencing). A driver that refuses leaves the row, with its words, and the error
names `mix forge.worker.retire --force` — force is not on this page, and why is `provisioning.md`
§ Whose account. It does not promise a retry: the sweeps retry a destroy only for a machine that is
unreachable or idle, and a machine somebody just pressed Destroy on is usually neither.

**The release is what the machine said, and the hint beside it is what the platform knows.**
`flake.nix` builds the platform release knowing the build of the worker release it ships with
(`worker-tier.md` § Updating a worker); a row whose build is that one reads `current`, and any
other reads `other build`. **Not "older build"**: a build is a hash and hashes have no order, so the
platform cannot tell a machine that lags it from one made from a newer checkout than the platform
itself — which is exactly what building a snapshot before deploying produces. In the usual order of
things it is older, and *other* is the word that is true either way. A node built outside Nix knows
no build and draws no hint; a row that has not joined since the release was on the wire has nothing
to compare and draws none either.

**Each row links to the machine's log**, `/workers/:id` (`12g`): what the platform saw happen to it
and what the machine itself reported — joined, refused, jobs accepted and finished, seeds fetched,
swept, destroyed and by what — newest first, each entry its date and time, source and type over its
message, an error in danger across the whole entry. A job id links to its job page, or a chat's to
the chat, **only in a project the viewer is in**, for the reason a row names a ticket only there;
elsewhere it is its short id as text. It is the machine's history and not a job's: what an agent
did is on the job page. `worker-log.md` is the standard for it. Its title is the machine's short
id and its subline how it stands and where it comes from (*destroyed 2h ago · hetzner-cx22 ·
site*); its identifiers head the content. Its top bar has the queue button like every other inner
page, and the context button back to Machines.

**On a wide screen** (`12o`) the row heads line up as a table — machine, status, doing, template ·
projects, release, the release in warning when it is another build — under column names, with each
row's lines and controls beneath its head; templates and credentials sit in the right column, where
their forms open.

### Templates and credentials

`/templates` lists the recipes machines are created from (`14a`–`14c`, `14f`) and the provider
credentials they spend (`14d`) — one person's own, never anybody else's. The view is in the URL:
`?view=credentials`, `?template=<id>` for one opened, `?new=1` for the new one; a template id that
is not the viewer's opens nothing. An opened template or the new one is drawn beside the list on a
wide screen (`14f`) and on its own below 1440, where the list steps aside.

**A template leads with its ceiling in money**: its `max_workers` times the price per machine, in
**the currency the provider's catalogue reports** (`€0.044/h`, three places; a currency with no
symbol here is written after the figure), because the maximum count is the only ceiling on machine
spend and it belongs beside the price. A template whose price or currency the catalogue does not
report, or whose size it does not sell, draws *no price from the provider*, rather than a zero.
Sums are per currency and never across two. Then how many of the maximum it runs now, as slots, in warning when
full; its identifiers, what each machine is, and the projects that may use it — a template with no
project says it is never used. **A disabled template** carries its flag and its failure in danger,
with Enable. The page's subline adds up every ceiling it can. **The catalogue is read once per
credential per mount** — ceilings, liabilities and the form's sizes share one cache — never per row,
and the images only while a form is open.

**A template** (`14b`) shows its ceiling large — and under it what that comes to over a month,
*≈ €118/mo at the ceiling*, since a provider bills by the hour and a person budgets by the month
(UX pass, D24; a month is 730 hours) — its slots and what happens when they are full, the
machine it makes with its image's build compared to this platform's — the outdated case in warning
— and the projects that may use it, assigned and unassigned in place. Remove keeps its confirm
(*Machines already made from it keep running*). **Editing it shows the form alone**: no ceiling
card above it — the live one in Limits is the one that changes — no Projects and no Remove under
its *Save it*, and Cancel an `xl` outline beside Save (UX pass, D16). **A snapshot says what it carries**: beside a
template's image, and in the image select, the snapshot's worker build — with the same `current` or
`other build` hint — and the protocol it speaks, read from its provider labels (`provisioning.md`
§ A snapshot that speaks the wrong protocol); a snapshot made before the labels existed reads
*unlabelled*.

**A new template is steps in the order the provider needs** (`14c`): account, then machine, then
limits, then what it takes. Before an account exists, the later steps are locked with the sentence
saying why. Size and image are selects filled from the provider's catalogue, with the price and
build in each option; picking a size fills memory and cores, which can still be edited; the limits
step shows the ceiling as it changes. The name is asked above the steps. Max machines is a stepper;
idle minutes stays a number field, because blank — the platform's default — is a value a stepper
cannot say. Only one form is open at a time, because both read one catalogue: opening the new one
puts an edit away.

**Credentials** (`14d`) are the viewer's, write-only: each says how many templates name it and the
ceiling it is liable for, so removing one has a visible cost; Remove keeps its confirm (*Templates
that name it stop being able to create*). The secret fields come from the provider's driver.

**A credential's row carries its image builds** (`?view=credentials`). The platform builds the release's worker image
into an account when a template naming `latest` needs it (`provisioning.md` § Putting the release's
image into an account), so the row of the credential — its owner's only — holds the switch *build
worker images automatically* (a `role=switch` row, as You's push switch) (on for a new credential and every existing one, saved when flipped),
a *Build now* button with what it costs beside it (a few minutes of a small machine on this
account, no confirmation), and the account's last five builds, newest first: when it started, which
worker build, what started it (a template by name, or *build now*), and how it stands — running
since when, built, failed with the provider's or the builder's words, or abandoned at the time
limit. *Build now* is offered only when it would do something: when the current build is already in
the account or one is running it is not, and the row says which. On a node that does not know its
own release build there is neither switch nor button, and the row says so. With no builds the row
says what would fill it. The words are text, never markup, cut to one line on the row (an ellipsis, the whole in its title) and
in the log. The list is read from what is stored and the switch is saved when flipped, so
a reconnect loses nothing; the row wraps like the rest of the page, and both controls stay reachable
on a phone.

**None yet** (`14e`) gives the empty page to the most important sentence on it: the three things
that make a project able to run — a provider credential, a template, the template assigned to a
project — with what is already done ticked (a credential, or no provider here needing one), the
projects with neither a template nor a permanent machine named in the third step, and the next step
in the dock: *Add a credential* while there is none, *Make a template* after.

**On a wide screen** the machines view's right column (`12o`) lists the viewer's templates — slots
as `2 of 4`, in warning when full — and credentials with how many templates name each, leading to their
views; below 1440 it is not drawn, since the views already lead there.

## Accounts

`/accounts`, `12i`. **Not a top-level page.** It is reached from the title menu's foot and from the
You page, shown only to a node admin, because account governance is not a place work happens and
most accounts never reach it. It needs *a* way in all the same: it is the only surface the approval
perimeter has, and the queue button's count is how an admin learns somebody is waiting
(§ What the queue counts). See `identity.md` § Approval.

Two lists: **waiting first**, with Approve as an outline — two waiting rows would be two
primaries side by side, and the way here is the queue's item — Refuse, and Delete, which frees the
address and keeps its confirm — the difference said once under the eyebrow, *Refuse keeps the
address blocked; Delete frees it to sign up again* (UX pass, D22); then everyone else. **Each row says how the person signed in** — the
identity's issuer and subject — because an identity is the issuer and subject, never the address
alone. The issuer is drawn as the configured provider's name when one names it and as its host
when none does (a provider since removed), the subject as the issuer sent it; an account made on
the host has none and says how it signs in as You says it — *password*, or *email link* with
neither (`SignIn.ways/2`; it said *local*, which You never did — UX pass, D20). Beside the address: how long a waiting account has waited,
*admin* and *you* on those rows, and how long ago a suspended one was suspended. The title's
subline counts the waiting and the accounts.

**Suspend and Make admin ask first** (§ The confirm), naming the account, and so does **Remove
admin on your own row**, which takes away the page you are on; on anyone else's it is one tap.
**Your own row offers no Suspend**, and `Accounts.suspend_user/2` refuses it anyway: a suspended
account is signed out at once, every open page of it disconnected (`identity.md` § Approval), so
it would leave you unable to reinstate yourself (UX pass, D2). *Remove admin* is offered only
while another admin **who can act** is left — a suspended one does not count — which is the rule
`set_node_admin/3` refuses by (review fixes 7, M1). An act from a page whose admin has been
suspended or demoted since it opened is refused in the row: *You can no longer govern accounts.*

## You

`/users/settings`, `12j`. Reached from the account in the title menu and the desktop header. It
holds what is about **this browser**, then what is about **the account**:

- **This browser**: notifications — subscribe this browser to push, which used to be the bell on
  the queue — and **the theme**, a segmented switch of system, light and dark.
- **Account**: how the person signs in — each identity as the accounts page draws it, and
  *password* when the account has one — the email and password forms, and **inference
  credentials** (below), whose form is headed *Add a credential* and submits *Add it*; a credential
  whose provider listed no models says *models not listed*, not *0 models*.
- Then, **after what is yours to set** (UX pass, D20): for a node admin, **Accounts** as a row with
  the number waiting, and **Usage**, a row with the two windows' figures, leading to `/usage`.
- **Sign out**, last.

The push row is drawn only on a node that has push configured, and its switch is the browser's
own subscription, read by the browser: the server does not know whether this browser is
subscribed, so it never draws the switch on or off itself.

The page is behind sudo mode, which is right for the one place a token is typed.

### Account settings

The caller's **inference credentials** are here because they are the caller's in the same sense as
the email and password: nobody else sees them, a node admin included (`credentials.md`).

**A token is typed once and never shown again, not even back into its own field.** The form is
re-rendered on every change, and a password input's value is rendered like any other, so the field
is written out rather than drawn by the field component and is never given a value by the server.
It is `phx-update="ignore"` so that re-rendering does not wipe what was typed, and it is replaced by
an empty one when an add succeeds. **The form names the harness first** (`codex.md`): Claude Code's
kinds, or Codex's *ChatGPT login (Plus or Pro)* — the folder's `auth.json` pasted into a box of
several lines, so a phone can add one, with how to make a login for forge alone above it — and
*Codex access token (Business or Enterprise)*, with an optional expiry date. The kind is in the
box's id, since an ignored element is never patched and another kind's box has to be another
element.

A row is an identifier line — name (cut to the row, whole in its title), harness and kind, what
the last check found — then what this kind says of itself: for a ChatGPT login its account, plan,
when Codex last renewed it and *in use* / *free* (its owner only); for an access token the days
left before the expiry its creator chose, in warning from seven days, warned about and never
enforced. Then what it has used today, in windows with the weighted tokens counted behind it, the
daily limit beside it if one was set (typed in the same notation, `4M`), and the tokens by kind
behind the figure. Then **its windows**, five-hour and weekly,
each its usage line, its utilization when one was given, its reset, and *rate-limited* in warning
while it blocks. Then two controls, **Check again** and **Revoke**. The limit says *not enforced* in
the row itself, because it is not, and a figure next to a limit reads as a cap.

**Usage is in weighted tokens here**, as everywhere (`capacity.md` § Usage in weighted tokens): it
was dollars, the one exception to `capacity.md`'s recommendation that dollars leave the operator's
surfaces. A Claude API key's dollar figure is kept per run (`claude_cost_usd`) and drawn on that
credential's row only, since it is the one kind billed in dollars (*Claude Code's figure: $6.25
today*); it is read by no cap and no pick. A Codex credential is checked by its shape when it is
added, its first job being the check, so it has no *Check again*. The figures are as of the page's
last action, not live. Beneath it, **Funds**: the projects
whose pool it is in, each with an `×`, and a select of the viewer's own projects to add one — the
same shape as a template's projects, because it is the same decision about whose money reaches
which project. Revoked rows stay, dimmed and without controls: what was spent through them is still
attributed to them.

There is no *API tokens* row: a user's API tokens are issued from the command line, and a row that
led nowhere would be a promise.

## Usage

`22e`, `23a`, `23b`. How much of the inference windows is spent, and what spent it. `capacity.md`
is the standard for what the figures mean; this is how they are drawn.

**Two lines frame the top bar on every signed-in page**: the **five-hour window** as a 3px line
directly above it, full width, and the **week** as the 2px line that replaces its bottom border, a
pinned decision row sitting below it. Each fills left to right over a `--track` of ink at 10 %:
**below 80 % in quiet ink** (60 % for the five-hour, 45 % for the week), **from 80 % in warning,
from 95 % in danger. Never amber**: capacity is resolved by time, not by a person (`capacity.md`
§ Two objects). On a desktop the same lines run around the header, and **the digits** — a quiet
mono *42 % 5h · 18 % wk* beside the account, taking the lines' colours — link to `/usage`. The
lines are not drawn on sign-in screens.

**Each line is the mean over the page's set of credentials**: on a page about a project — the
project, its settings and repository, a ticket, a job, a conversation in it — that project's pool,
which is what its work draws on; everywhere else the viewer's own credentials (`credentials.md`
§ Showing the windows). A limited credential counts as full. **A window in which no credential of
the set has reported a utilization draws no fill and no track**, only the bar's edge it replaces,
so an empty set never reads as 0 %; the band keeps its height, because the frame does not move.

**Clicking either line, or the title menu's Usage row, opens the usage panel** (`22e`), a drop
panel — 440px on a desktop, so what is spending is not cut — **headed with whose figures they are**
(*game's pool · 3 credentials*, *your 2 credentials*: the panel on a project and `/usage` draw
different sets, and unnamed, 74% then 91% read as one figure moving; UX pass, D7): per window the
percentage, its reset, and its **pace**; what is spending it now; and *Details ›* to `/usage`. Per credential, the
panel names **only the viewer's own**; on a project page the rest of the pool is one line, *others
in game's pool*, never named, because a pool holds other people's credentials and a row that names
a credential is its owner's alone.

**`/usage`** (`23a`, `23b`) is a top-level page, reached from the title menu, the panel's
*Details ›* and the desktop digits. **A card per window**: its percentage large, its line, the reset
and the pace; the five-hour card draws spend in 15-minute steps up to now, the time left before the
reset hatched; the week card draws spend per day, each bar's title the weighted tokens it holds. **Beneath, what spent the five-hour window**, by
item, with the running ones marked, switching **By project** and **By model**; a model the job did
not set is drawn as *the project's default*, and **By model is left out of the switch while one
model spent the window**, since it would only repeat the total (kept while it is the one shown).
**Shares are the card's figure split by what each used, in weighted tokens** (`capacity.md` § Usage history, § Usage in weighted tokens), in percent, and
they add up to the card's figure exactly: whole percents handed out by largest remainder to the
card's own rounded figure — not to their sum rounded, which put 95 % of lines under a 96 % card
when the sum came to 95.49999… (review fixes 7, L1) — so three items of 30.3 % read 31, 30 and
30 under 91 %, the 31 going to the first of equals. **Their bars are absolute** — a share of the track,
so a line at 22 % draws a fifth of it, never drawn against the largest line — and the legend says
what they are a share of: *shares of the 91% above, split by what each used; use of these
credentials outside forge is split in with them* (`capacity.md` § Usage history), or with no figure
*share of one 5h window, estimated from tokens used* (UX pass, D6); a share's title gives the weighted tokens counted behind it. The five-hour axis is labelled on
whole hours, and a job that ended otherwise says how in words (*didn't converge*). **Items in a project the viewer is not a member of are one line, unnamed** —
*elsewhere* — counted, because the viewer's credential paid for them, and never titled. On a wide
screen the two cards are side by side and the week's split by project is beside the item list
(`23b`), as shares of the week card's figure in the same way — in windows, estimated, when the
week has none — and narrower it is not drawn, because *By project* above says the same of the five-hour window. By item, the first five
are named and the rest are one line, *N earlier jobs and chats*: running ones first, then newest
first, so *earlier* is true. The page's set is the viewer's own credentials, and its windows are the
frame's lines' own (`ForgeWeb.Capacity`), so the page cannot disagree with the lines over it. The
panel's per-window figures are the lines' too, and what is spending now is the running items of the
same set; both read once when the panel opens.

**Pace** is the window's average rate since it started, projected to its reset: *full in ~N* when
that projection crosses 100 % before the reset, *on pace* otherwise. It is computed from the latest
utilization and the window's start — its reset less its length, five hours or seven days — so no
history of utilization is kept or needed (`capacity.md` § Usage history).

## Signing in

`21o`, `21p`, `21n`, `21g`, and the pending page. **Drawn in the sign-in frame**: no top bar, no
queue, no usage lines, no version; the logo at 72px or 44px.

- **With an OIDC provider configured** (`21o`), the page is the logo and one button, *Continue with
  `<provider>`*, the provider named as configured and never as the handoff's placeholder; *Other ways
  to sign in ▾* leads to the next screen.
- **Other ways** (`21p`) is password and email link, as a switch. **A node with no provider shows it
  as its sign-in page**, without the back link.
- **The device remembers how it last signed in.** A successful sign-in sets an http-only cookie,
  `_forge_last_sign_in`, a year long, to `password`, `magic` or `oidc:<provider>`; a node with a
  provider then opens on *Other ways* for a device that last used a password or a link — on the
  link for a link — and lists the remembered provider first. A value outside that set, or naming
  a provider the node no longer has, is ignored and never drawn. It names a method, never a
  person: no address, no subject, and logging out leaves it, because it is about the device.
- **Each screen has an address**, `/users/log-in?way=provider|password|link`, so a refusal
  returns to the screen it came from — a wrong password to the password, a dead link to the link,
  a provider's refusal to the provider — and the back link from *Other ways* is a link. **A wrong
  password is drawn under Sign in**, not under the password field, as a whole sentence — *That
  email and password don't match an account here.* — because the refusal is the pair's and the
  page cannot say which half was wrong.
- **Coming back from the provider** (`21n`): if it refuses, the error sits above the button in the
  provider's own code with a plain reading — *It said: access_denied. You cancelled, or your account
  there isn't allowed to use forge* — escaped, and the button is still there to try again. **Only
  the codes OAuth and OpenID Connect register are quoted**, each with its own reading: the code
  arrives on a URL anybody can write, and a page that echoed any string under the provider's name
  would let a link put words in its mouth. Any other code reads as a login that could not be
  completed, and is logged. The
  handoff draws a holding screen *while the callback is checked*; the callback is a controller that
  checks and redirects in one request, so there is no moment to draw one in, and it is not built. A
  new identity lands on the pending page, keyed by issuer and subject.
- **A link sent, and the link opened** (`21g`): the confirmation wears the same head as every
  sign-in screen, the 44px logo beside the word, and asks the question it means, *Is this your own
  device?*, with the common answer filled — **and no button focused**, since one that opens with
  the focus ring reads as already chosen; the first sign-in confirms the address and later ones
  only sign in, both with the same two answers. An expired link goes back to sign-in with
  a red line under the field.
- **Pending** (`/users/pending`) is a sentence and one button, in the sign-in frame: every link the
  frame would draw leads somewhere this account is redirected away from.

## Documents

An agent's document is rendered, not shown as source. Source is one tap away — every ticket
artifact's name is a link to its exact version (below) — and the roadmap's margin-questions view
needs structure, which source text cannot carry. A document whose name says it is text, a log or
code and data (§ Artifact types) is the exception: it is shown as its text, in a `pre` that scrolls
inside itself, because Markdown would join its lines into one paragraph. This holds wherever a
document is drawn, because every place that draws one draws it with
`ForgeWeb.FileType.render_document/3`.

### References

Markdown that the platform draws can point at the artifacts around it, and **everything that draws
Markdown resolves them**: a presentation, a document wherever it is drawn, and a chat's messages.
`ForgeWeb.Markdown.to_html/2` takes the resolutions as an argument, so a caller that passes none
does not compile; `Forge.References` decides what a name means.

**The forms.** `![alt](screenshots/queue.png)` and `[text](plan.md)` name an artifact as its scope
keeps it. Followed by `@N` (`queue.png@2`) it is exactly that version, and by `@latest` the newest.
`archive/<n>/` before any of the three names ticket `<n>` of the same project, the path an agent
reads under `$FORGE_JOB/archive/` (`archive.md`), with the archive's `queue.v002.png` spelled
`queue.png@2`. Digits carry no leading zero, the match is exact (no `./`, no case folding, no
URL-encoding), and a name that holds an `@` itself wins over the reading with a version.

**Which version.** A bare name is pinned: the newest version that existed when the referring text
was written, or that the same job wrote (a job's screenshots are kept in the same transaction as
its document, and a timestamp alone would catch them only by the second). A version of another job
in the same second counts as before. A conversation is one job across many turns, so for it "the
same job" narrows to the same turn: a version of a later turn never changes what an earlier one
shows. `@N` is that version whenever it was written. `@latest` follows new versions, in an approved
document too — the one form whose picture changes after it was written, chosen as such. Another
ticket's bare names are pinned by the clock alone.

**What is drawn.** An image that resolves to a raster blob (§ Addressable artifact versions: the
same test serves and draws it) is an `<img>` inside a link to the same numbered address,
`loading="lazy"`, at its own size scaled down to the column and never up. **Every other image is a
muted note and is never fetched** — alt text, the name asked for, and why: not on this ticket, no
such version, not drawn as an image, no such ticket, not on ticket *n*, outside the project, not
resolved by the caller (*is not shown*), or (in a project chat) *chats keep no images*. A remote
URL, a `data:` URI, `//host` and a path into the app are among those: no `<img>` for them exists in
the page. A link that resolves goes to the numbered address of the version in its own scope; one
that does not keeps its text and loses its target, except `http:`, `https:`, `mailto:` and
`#fragment`, which stay.

**Where a name is searched.** The ticket for a ticket's text and a ticket conversation's; a project
chat's own documents for a project chat's. A message has no version, so its moment stands in: a
reply sees up to and including the recording of its own turn, a person's message what was recorded
before it was sent, a reply still streaming what exists as it is drawn.

**A secret in a picture is not hidden.** The worker masks secrets in text, not in groups of files
(`secrets.md`), so a key on screen when a screenshot was taken is in the picture, and is now drawn
without a click.

### How a document is drawn

Rendered document bodies are the one place the product styles Markdown, and they do it from a
scoped block of CSS (`.doc`) on the tokens rather than from `@tailwindcss/typography`: the plugin
brings its own type scale, and this note already has one. Headings step down from the panel size
and never reach the page title, lists keep their markers, and the body is the sans face at body
size — a document is language, not an identifier. Fenced code in a document is mono with
ligatures off.

**A document body never widens its column.** Whatever an agent wrote — a 300-character URL, a wide
table, an unwrapped fenced block — is contained: `min-w-0` on the column so a flex child cannot push
past it, `overflow-wrap` on prose, and `overflow-x: auto` on the block elements that legitimately
cannot wrap (`pre`, `table`). Content that overflows scrolls inside its own box. It never reaches a
neighbouring column, which is the failure this rule was written for.

The body sits on `--surface-1` inside an 8px block, because a document is the one thing on the page
that is not the product's own writing, and the ground is what says so.

## Artifact types

An artifact's row carries its kind, so a build's package, its log and the plan beside them are told
apart at a glance: a list of them is read by shape before it is read by name. It is drawn on every
row and chip that is an artifact: Docs, a job page's *Wrote* and a command's log, a decision row, a
decision panel's pinned versions. Where an artifact is named inline among other identifiers — the
queue sentence, a question's answer, a human state's editor — it stays words.
`ForgeWeb.FileType` is the one place a type is decided.

The type is the name's extension. A document, which is text by construction, is Markdown unless its
extension says text, a log or code; a blob with an extension not below is a *file*. It is never read
from the bytes: drawing a row must not cost a store read.

| Type | Extensions | Glyph | Hue |
|---|---|---|---|
| Markdown | `.md` `.markdown`, and a document or presentation of any other name | `md` | 210 (`--doc`) |
| text | `.txt` `.csv` `.tsv` | `txt` | neutral |
| log | `.log` | `log` | neutral |
| code and data | `.json` `.yaml` `.yml` `.toml` `.xml` `.html` `.css` `.js` `.ts` `.ex` `.exs` `.heex` `.py` `.rb` `.go` `.rs` `.java` `.kt` `.swift` `.c` `.h` `.sh` `.sql` `.nix` `.diff` `.patch` | `{}` | 175 |
| image | `.png` `.jpg` `.jpeg` `.gif` `.webp` `.svg` `.avif` — all but `.svg` are served inline and drawn when a document refers to them (§ Documents → References) | `img` | 340 |
| archive | `.zip` `.tar` `.gz` `.tgz` `.xz` `.bz2` `.zst` `.7z` `.jar` `.aab` | `zip` | 95 |
| Android app | `.apk` | `apk` | 125 |
| file | anything else | `file` | neutral |
| changeset | the `changeset` blob, which is a commit and not a file | `±` | neutral |

The glyph sits in the `TypeIcon` tile — 26px, 20px in a chip — tinted with its hue at 16 %, on a
6px radius and unbordered: it is not a control, and the row it sits in is. The tile is the only
thing the type colours; the name beside it is an identifier and stays mono `--ink`. The hues are
§ Colour's *file type* and nothing else's. The tile carries its type's words for assistive
technology, since a glyph alone says little to a screen reader.

**An Android app is first class.** Its Docs row says *Android app* beneath its name, and its address
serves it as `application/vnd.android.package-archive` rather than `application/octet-stream`,
still as an attachment — unless its bytes are small, valid text, which no real package is (an
`.apk` is a zip), and which is then shown as text like any other (§ Addressable artifact versions).
The media type is what tells a phone's browser the download is an app to hand to the package
installer, rather than bytes it saved. That a phone then installs it from the row is unobserved
here: it is tested as headers, and no package has yet been installed from a forge page.

## Addressable artifact versions

`…/artifacts/:name/:version` serves the exact bytes of one version, to an authenticated operator. It
is what every artifact name in the product links to: rows in Docs, the produced list on a job,
transcripts, a decision's panel, the queue item, a conversation's details.

**An artifact has the address of its scope.** A ticket's is under the ticket,
`/tickets/:project/:number/artifacts/:name/:version`. One scoped to a conversation
(`artifacts.job_id`) — a project chat's documents, and every conversation's proposals — is under the
conversation, `/chats/:id/artifacts/:name/:version`, and served to whoever may open that
conversation: a member of its project, the same guard as `/chats/:id`. `ArtifactController`
resolves the name within the one scope the address names and nowhere else, so a version of the same
name in another scope is not reachable through it. A ticket chat's documents are the ticket's, so
they are under the ticket. A conversation's Docs lists every version it wrote, the row the link.

**There is no versionless form.** `…/artifacts/:name` would have to mean "latest", and the word
appears nowhere in this product for the same reason approval attaches to a version and not to a
name. The one exception is `@latest` in a reference from Markdown (§ Documents → References), which
is resolved when the page is drawn into a numbered address.

**Every response carries `content-security-policy: default-src 'none'; sandbox`**, text, images and
downloads alike, on the session routes and the API's raw route: if a browser ever lays a version out
as a page, nothing in it runs. (An image drawn inside a page is unaffected.) That is every response
that sends a version's bytes; the changeset's redirect and a 404 on the session routes keep the
browser pipeline's policy, and the API's errors are JSON.

- A **document** serves its stored text as `text/plain`, front matter included. The rendered view is
  Docs — the ticket's or the conversation's — and a decision that pins it; this route is the source
  behind it.
- A **blob** is fetched from the store by its key and served as `text/plain` when it is text no
  larger than a document may be. Anything else — a package, a screenshot, a large log — is served as
  `application/octet-stream` with `content-disposition: attachment` — an `.apk` as
  `application/vnd.android.package-archive` (§ Artifact types) — copied from the store to a temporary
  file and sent from there rather than read into memory: a download, never rendered. **A raster
  image is the exception:** a blob named `.png` `.jpg` `.jpeg` `.gif` `.webp` or `.avif` is served
  with its `image/*` type and `content-disposition: inline` (the versioned filename kept for a
  save), whatever its bytes and however small — decided from the name before the text check, so
  that a version drawn as an image is a version served as one. `nosniff` makes a `.png` full of
  markup an image or nothing. **`.svg` stays a download**, small text included: it can carry script,
  and at a same-origin address it would run in the operator's session. A *document* named `x.png` or
  `x.svg` is text, as every document is. A group's file is named `group/file`, and its address
  carries the name as one encoded segment.
- A **changeset** is not a file. `git:<sha>` names a commit, so the changeset's address redirects to
  the ticket's Changes view, which is the rendering of a diff. Nothing tries to serve it as bytes.

Serving raw bytes is what the route does *today*, not what the path means. When the
margin-questions view lands it takes this route's HTML representation and raw moves behind a
parameter; the address of a version does not change.

## Where the previous sections went

Code comments cite the previous version of this note by section. Each of those names, and where its
content is now:

| Previous section | Now |
|---|---|
| The affordance rule | § The affordance rule (the answer row and option card are § The affordance rule's choice row) |
| The three axes | § The three axes |
| Type, Colour, Space, measure and targets | § Tokens; the per-route measure table is § Three layouts |
| Navigation (the nav row, the version, Accounts, Chats is a destination on both) | § The frame, § The title menu, § Accounts, § Chats |
| Motion and structure | § Motion and structure |
| Semantics that must not be lost | § Semantics that must not be lost |
| A reconnect is not a reload | § A reconnect is not a reload |
| The queue item | § The queue, § What each kind shows |
| Answering questions | § The question card |
| Not waiting on you | § Not waiting on you |
| The work screen (the frame, header, context strip, details sheet, tabs) | § The phone, § The ticket, § A chat, § The bottom strip |
| Talk | § Talk |
| Changes (and the review page) | § Changes |
| Docs | § Docs |
| Activity | § Activity |
| Decide and Timeline | § Steps (the table there), § The details |
| The Accept area | § The Accept area |
| The phone (the bottom bar, More, the board stacked, tables reflowed, push) | § The phone, § The title menu, § Push follows the queue |
| Creating things | § Creating things |
| The projects page | § The projects page |
| The project page | § The project page |
| Project settings | § Project settings |
| Account settings | § Account settings |
| The capacity gauge in the top bar | § Usage |
| The workers page | § Machines |
| A job waiting for a machine | § A job waiting for a machine |
| Documents, References | § Documents, § References |
| Artifact types | § Artifact types |
| Addressable artifact versions | § Addressable artifact versions |
| The project's repository | § The project's repository |

## Not built yet

The code at this commit follows the previous version of this note (§ Where this comes from, and
what is built). Each
line below is something this note says that the code does not do yet; a change that builds one
removes its line. Until then, where the two disagree, the code is the previous design and the
previous note describes it.

- **The decision row**: the check's time in a changeset's meta line.
- **The queue**: a changeset's check and its time in 18a's meta, and the list rows' track ticks.
  The question card's tabs and split pane are drawn in the queue and in a chat; the ticket draws
  the tabbed card without the pane's handle. Options are 46px rows at
  every width, not the desktop's 34px (`2d`).
- **The ticket**: rows new since the person last looked are marked in Activity, and not yet in
  Steps; the job's chip sits in the dock above the strip
  rather than in the strip's right slot; Steps' line-and-dot is the ticket's own, not yet the
  project Workflow view's; a stuck ticket's subline says `stuck` without its age (§ The three
  axes), because nothing records when it stuck.
- **Talk**: the person's and the agent's bubbles are told apart by ground and by the speaker's
  heading, both full width, not by side — though on a phone the person's is set in 24px from the
  left, so a glance down the column says who spoke.
- **Changes**: the whole file draws the lines the change added, tinted, and not the lines it took
  out between them (`19e` draws both); the foot's neighbouring files are links, not a swipe.
- **The job page**: the job's chip sits in the dock above the strip, as the ticket's does, rather
  than in the strip's right slot.
- **The repository**: the branch sheet's fold of a long group (`10b`'s *2 more*) and the age of a
  branch that is neither the default nor a ticket's; a file added by a commit is not marked *new*
  on the commit page.
- **The Accept row** of a chat step has no document age and no *Read* in its meta line (§ The
  Accept area, `16f`–`16i`), and **the wide step document** does not highlight the passage an open
  question is about.
- **A chat's merge row with no `commit-message`** draws a disabled *Merge*, where § A chat draws no
  button; with a conflict, *Resolve ›* still goes to the two ways out.
- **A decision row's tile** is `changeset` or `doc` by the pin, not the pinned artifact's file type
  (§ Artifact types).
- **Chats**: *End* is drawn on `/chats` only, not on a ticket's or a project's Chats.
- **The ticket's details**: *Cancel ticket* is a quiet button in danger red, not outlined red
  (§ The affordance rule).
- **Docs**: a row does not say where its version is pinned, and the approvable group is headed
  *Waiting on you*.
- **Settings**: Branch and mirrors draws the default branch before the mirrors.
- **Machines**: the minted machine's notice is dismissed with *I have copied it*, not *Done*. A
  machine row's refusals other than Destroy's, and You's refusal to assign a machine, are drawn at
  the head of the page or under the whole list, not by their button (§ Errors stay where you
  acted).
- **A model's and an effort's options** are the union over every ready, busy or idle worker on the
  node, not the harnesses connected now.
- **Sizes this note states and the code does not draw yet**: strip tabs size to their label
  (`flex: 1 1 auto`), not equal width, and the segmented switches' options are uneven too; the top
  bar's title is 14/500, not 15/600; the queue sentence is 20px, not 19; a `ChoiceRow` without a
  detail line is 46px, not 52; some phone targets are under 44px — question tabs and send at 40,
  the panel's handle at 22; the light theme's scrims are 25–35 %, not 60–70 %; there are three
  inline stroke SVGs, not two (the offline mark as well); and syntax attributes take the atom
  hue (175), not 345.

Left out on purpose, and not coming with this design: a holding screen while an OIDC callback is
checked (§ Signing in), Stop on a workflow job's page (§ The job page), the diff between two
versions of a document (§ Docs), an *API tokens* row on You (§ Account settings), the *Not allowed*
variant of not found **for a project** (§ Not found: a non-member is told only of a miss; the
not-allowed wording is drawn for `/accounts` alone), and preselecting a chat step's outcome (§ The
Accept area).

Still unbuilt from before the redesign, and still specified only in the earlier handoff:

- Message state (queued, retrying, failed, confirmed) and a client outbox with an idempotency key
  per answer. Until it lands, a send is confirmed by its toast.
- Document-with-margin-questions at desktop width.
- A `/tickets` finder across projects.
