# forge design system

forge is an agent work platform: projects hold tickets that move through workflows (triage → shaping → planning → implementing → review → merging), agents run jobs on machines, and people answer questions and approve what agents produce. The UI exists to let one person keep many agents moving, mostly from a phone.

This system is derived from the redesign in this project. It is meant for adding new features so they look and behave like the rest.

- Source repo: `manuel2258/project-forge` (Phoenix LiveView, `platform/lib/forge_web`). See `github.md`.
- Every agreed screen: `Final Design.dc.html`. History and alternatives: `Ticket View - Redesign.dc.html`.
- Handoff rules and screen → code map: `docs/design/ui/README.md`.

## Index

- `styles.css`: the only file to link. It imports `tokens/` (fonts, colors, typography, spacing, elevation).
- `components/`: React primitives, one folder per concern, each with `.jsx`, `.d.ts`, `.prompt.md` and a preview card.
  - `actions/` Button
  - `navigation/` TopBar, QueueButton, UsageLine, BottomStrip
  - `decisions/` DecisionRow, DropPanel
  - `forms/` Field, Segmented, ChoiceRow, Stepper, Composer
  - `data/` ContextCard, ListRow, WorkflowTrack, StateLabel, DiffStat, TypeIcon, CountBubble, Eyebrow, FactList
  - `feedback/` Notice, Toast, Sheet
- `guidelines/`: foundation cards (colors, type, spacing, marks, principles).
- `ui_kits/forge-phone/`: the queue → changeset → approve loop, clickable.
- `assets/forge-logo.svg`, `fonts/` (Instrument Sans, JetBrains Mono, variable woff2).
- `SKILL.md`: for use as an agent skill.

## Principles

1. **The queue is home.** Everything that waits on a person collects there, oldest first, one item per screen. Other places are reached from the title menu (`Queue ▾`) or links.
2. **One decision per place.** A decision (approve, accept, merge) lives in a `DecisionRow` pinned under the top bar, on the page that shows the thing being decided. The queue shows context and links there. It never decides.
3. **The bottom navigates and replies.** `BottomStrip` switches views of the current object. `Composer` sends messages. Neither holds a decision.
4. **Nothing transient takes a decision's place.** Toasts float above the strip and can't be tapped. A lost connection changes the top bar itself. Errors appear in the panel or field they belong to.
5. **Layout never moves under a finger.** A disabled control keeps its size and place. Panels overlay instead of pushing. A button that moved ignores taps for 500ms.
6. **Colour carries meaning, not decoration.** See Visual foundations.
7. **Vertical first.** Phone and portrait desktop are primary. Wide desktop adds columns (list on the left, context on the right) but never reorders.

## Recipes for new features

**A new screen on an object** (ticket, chat, project, machine):
`TopBar` (queue left, title + mono state subline, parent object right) → optional `DecisionRow` → content (lists of `ListRow`, cards of `ContextCard`, facts in `FactList`) → optional `Composer` → `BottomStrip`.

**A new view of an object.** Add a tab to its `BottomStrip`, with a grey `CountBubble` when there's a count. Keep it to five tabs at most. A view never becomes a special amber button.

**A new decision.**
1. Show a `DecisionRow` only once the decision exists.
2. Make it amber when it waits on the person and neutral otherwise.
3. Its button opens a `DropPanel` that states what happens, shows what it pins or commits, warns about consequences ("N open questions will stay unanswered"), and holds the secondary act (Reject, Answer first).
4. Add the item to the queue, as context plus a link.

**A new form.**
- `Field` for text, with the label above and the hint or error below.
- `Segmented` for 2–4 short options.
- `ChoiceRow` for visible choices that need a sentence each.
- A dropdown when the set is large (models).
- `Stepper` for small integers.
- One filled `Button` in the dock, labelled with what it does ("Issue it", "Create it").

**A new list page.**
- Lead with an `Eyebrow` group label and a mono count.
- Every row says what happened last, in words.
- Group by source with an indented 1px rail when membership matters.
- Selection uses checkboxes, and long-press on the phone.
- Bulk actions sit in a bar directly under the list.

**After an action.** Show a `Toast` with what happened and what started ("Approved changeset v1 · merging started"), then move on to the next thing.

**Overlays.** Anything opened from a bar drops from that bar (`DropPanel`): the title menu, details from the title, decision confirmations, usage. Anything opened from the bottom rises as a `Sheet`.

**Desktop.**
- The same components at the desk sizes: 56px header, 34px controls, a 56px decision row spanning the window.
- A wide screen adds a 360px list column on the left and/or a 400px context column on the right.
- A portrait screen stacks those columns in the phone's order.

## Content fundamentals

- **Plain, specific, second person.** The UI speaks to "you" about "it" (the agent): "Nothing needs you. Work continues without you." It never says "I".
- **Sentence case everywhere.** Titles, buttons and tabs are all sentence case. Eyebrows are the only uppercase text (CSS transform).
- **Verbs name the act and its result:** "Approve v1", "Accept · shaped → planning", "Interrupt and send", "Answer first", "Accept anyway", "Review the changeset ›". Never "OK", "Submit" or "Confirm".
- **Say why, in the app's terms:** "did_not_converge · 3 tests failing", "No workflow in the project sets `release: true`, so it has no release to start." Keep the server's and engine's own words for errors and states.
- **Consequences before commitment:** "Ends the chat step, approves brief.md v2 and moves to planning." and "Never shown again."
- **Numbers are exact and mono:** "+48 −6", "14 of 30", "0.22 windows", "waiting 25m", "5h 42%".
- **No emoji. No exclamation marks.** Marks are Unicode glyphs with fixed meanings (see Iconography).

## Visual foundations

- **Mood:** a dark, quiet console where colour appears only when something means something. The light theme uses cool neutrals.
- **Colour:**
  - **Neutrals:** cool violet-grey (hue 300). Surfaces step about 2% in lightness: bg 15.5, surface-1 17.5, surface-2 19.5, border 24.5.
  - **Accent (amber):** reserved for "waits on you": the queue button, decision buttons and edges, the current workflow step, the queue's progress.
  - **Info blue:** running, agent actions.
  - **Green:** passed, added, connected.
  - **Warning yellow:** outdated, expiring, near a limit.
  - **Red:** failed, removed, destructive, disconnected.
  - **Violet:** links and selected choices.
  - **Cyan:** documents.
  - Usage lines never use amber.
- **Type:**
  - Instrument Sans for UI and reading. JetBrains Mono for ids, paths, numbers, states, sublines and eyebrows.
  - Nine-step scale from 10.5 to 22px. Body 14.5/1.6, titles 600 at −0.02em, the queue sentence 19/500.
  - Mono ligatures are off in code.
- **Spacing and frame:**
  - Fixed bands: 3px 5h line, 52px top bar, 2px week line, optional 60px decision row, content, optional 64px composer, 56px strip.
  - Phone gutters 20px, desktop 30px. Reading measure 680–820px.
- **Controls:**
  - Phone: 52px primary and choice rows, 48px fields, 42px decision button, 40px tabs, 36px row actions. Hit targets are 44px or larger.
  - Desktop: 34px and 28px.
- **Corners:** small. 4–6px for controls and rows, 8px for cards and notices, 14px only on the outer corners of sheets and drop panels, pills for the queue button, bubbles and toasts.
- **Borders:** 1px rules carry the structure. Selection and attention use a 2px inset left edge (ink for selected, amber for waiting, red for broken). No coloured left-border cards with rounded corners.
- **Elevation:** almost none. Shadows only for things that float or pin: the decision row (a short downward shadow), drop panels and sheets, toasts.
- **Overlays:** a 60–70% dark scrim behind panels. No blur.
- **Backgrounds:** flat. No gradients or imagery. The one pattern is the red diagonal hatching on a disconnected top bar.
- **Motion:** short and functional. 120–220ms with an ease-out curve. Panels drop or rise, toasts fade, and nothing pulses or bounces. A running state is shown with ▸ and words, not a spinner.
- **States:**
  - **Hover (desktop):** surface-2 background.
  - **Pressed:** no shrink. The control stays where it is.
  - **Selected:** surface-2 with a violet border (choices) or the inset ink edge (rows).
  - **Disabled:** 45% opacity, same size and place.
- **Code:** server-side highlighting with low-chroma colours, so code never reads as status. Diff rows tinted at 10%.

## Iconography

- **Almost no icons.** State is carried by Unicode marks with fixed meanings:
  - ◆ waits on you (amber)
  - ▸ running (blue)
  - ● workflow step or state
  - ✓ done / passed
  - ✗ failed
  - ◇ unapproved document
  - ○ idle
  - › navigates
  - ▾ ▴ menu or details open
  - ‹ back to the queue
- **Object kinds** use a 26px tinted square with a glyph: `md` document, `±` changeset, `⑂` branch, `⇡` release, `⌁` connection (`TypeIcon`).
- **Two small stroke SVGs** exist, at 1.5–1.6px stroke with round caps: the queue's inbox and the composer's send arrow. They are inlined in `QueueButton` and `Composer`.
- **No icon font. No emoji.**
- **Logo:** `assets/forge-logo.svg`, used on sign-in. The desktop header uses the plain wordmark "forge" with the version in mono.

## Intentional additions

These have no direct counterpart in the current LiveView components. They were defined by the redesign:
- DecisionRow
- DropPanel
- UsageLine
- QueueButton
- ContextCard
- WorkflowTrack
- Toast
- Composer, in its icon-send form
