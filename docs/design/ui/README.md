# Handoff: forge UI redesign (phone and desktop)

## Overview
A full redesign of forge's web UI (Phoenix LiveView, `platform/lib/forge_web` in `manuel2258/project-forge`). The main goal is that the phone becomes fully usable: more vertical space for agent output and decisions, one clear place for every decision, and consistent navigation. Desktop is designed vertical-first (portrait monitor), with wide layouts adding columns.

It covers every screen in the app: the queue (home), ticket, changes and review, job, chat, project, proposals, repository, projects, project settings, machines/templates/credentials, accounts, usage, sign-in, app-wide states (connection, toasts, errors, not found) and a light theme.

## About the design files
The files in this bundle are **design references created in HTML**: prototypes showing the intended look and behaviour, not production code to copy. The task is to **recreate these designs in the existing codebase**: Phoenix LiveView with HEEx function components and the app's CSS (`assets/css/app.css`). Use its established patterns: function components for the primitives, LiveView assigns and events for state, and CSS custom properties for the tokens. The React components in `design_system/components/` describe each primitive's props and states. Port them as HEEx function components, don't ship React.

## Fidelity
**High-fidelity.** Colours, type, spacing, heights, radii, copy and interactions are final. Recreate them closely, using the token values below. The copy is final wording and is part of the design. Model names, euro prices and the provider name/host are placeholders (see RULES.md §8).

## Files
- `screens/Final Design.dc.html`: **every agreed screen**, grouped by area, each with an id (e.g. `18b`) and a caption that explains the behaviour. Open it in a browser; it needs `support.js`, `fonts/` and `assets/` beside it. Pan and zoom the canvas. Captions are part of the spec.
- `RULES.md`: the design rules: principles, frame, components, colour, type, the **screen → source file map**, "needs code" (backend work the design assumes) and "check against the code".
- `design_system/`: the derived design system.
  - `readme.md`: principles, recipes for new features, content and visual rules, iconography.
  - `styles.css` + `tokens/*.css`: all tokens as CSS custom properties. Copy them into `app.css` almost verbatim.
  - `components/<group>/<Name>.jsx | .d.ts | .prompt.md`: 24 primitives with props contracts and usage notes. Each group folder has a `*.card.html` preview.
  - `guidelines/*.html`: foundation specimen cards.
  - `ui_kits/forge-phone/index.html`: a clickable queue → changeset → approve → toast → next item loop.

## Implementation order
1. **Tokens and fonts.** Add `tokens/*.css` to `app.css`, with dark as `:root` and light under `[data-theme="light"]`. Self-host the two woff2 files.
2. **Frame.** Build `top_bar` (queue button, title/subline, context button, usage lines, disconnected state) and `bottom_strip` as function components. Put them in the root layout so every LiveView gets the same frame.
3. **Decision row and drop panel.** Then move every approve/accept/merge into them: step accept (`step_accept.ex`), changeset approval, document approval, chat merge.
4. **Queue as home.** One item per screen, context card, "All" sheet, end of queue (`queue_live.ex`).
5. **Navigation.** The title menu `Queue ▾` on top-level pages replaces the global nav. Retire `board_live.ex` and fold `review_live.ex` into Changes.
6. **Ticket, then changes and review, job, chat.** The rest follow the same frame.
7. **App-wide states:** connection, toast, inline errors, not found.
8. **Desktop layouts and the light theme.**

## Layout: the phone frame
Width reference 412px. Top to bottom:
| Band | Height | Notes |
|---|---|---|
| 5h usage line | 3px | track `--track`, fill 60% ink; ≥80% `--warning`, ≥95% `--danger`. Tappable (opens usage). |
| Top bar | 52px | padding 0 4px. Left: queue button (46px hit area, 34px pill, amber when count > 0, ‹ + inbox icon + mono count 12.5px). Middle: title 14px/500 ellipsis + mono subline 11.5px (state). Right: context button (34px, border, mono 12px, "game ›"). Top-level pages: title + ▾ (11px, 60%). |
| Week usage line | 2px | replaces the top bar's bottom border; fill 45% ink. |
| Decision row (optional) | 60px | padding 0 10px 0 16px; 26px TypeIcon · title mono 14/500 · meta mono 11/65% · button 42px. Inset 2px left edge in amber (waits on you) or 50% ink (neutral). Shadow `0 8px 14px -10px`. |
| Content | flex | scrolls; gutters 20px. Optional split pane for questions: 16px handle, fits its card up to a user-set limit. |
| Composer (optional) | 64px | field 48px, radius 24px, send = 40px round icon button inside the field. |
| Bottom strip | 56px | padding 0 8px, gap 4px, `--surface-2` bg; tabs flex equal, 40px, 13px; active tab bg `--bg` + 1px border + 500. Grey count bubbles 18px. **Navigation only.** |

Desktop: header 56px (wordmark + mono version, Projects ▾, Queue + count, usage digits, account); title row (back link mono 12px, h1 20–22/600, state, view tabs 32px); decision row 56px spanning the window; columns 320–360px list left and/or 360–440px context right on wide screens. Portrait stacks the same blocks in phone order.

## Screens / views
Each id below is a drawn screen in `screens/Final Design.dc.html`. Read its caption for behaviour. The source file each area replaces is in RULES.md §6.

### Home and navigation
- **19a**: Queue · the only top level, no strip
- **19b**: Title tapped · the menu drops from the top bar
- **19c**: Another top-level page · same switch, queue on the left

### Queue
- **18a**: Queue · approval: read first, decide on the change
- **13b**: Questions · context above, the card below
- **13c**: Stuck · why, what was tried, the ways forward
- **13d**: End of the pass · what is left to know
- **13e**: All items · the list as a sheet

### Ticket
- **16e**: D · before the first version: no header
- **16f**: D · the document header, with Accept
- **16g**: D · Accept tapped: the band opens in place
- **5d**: Activity · job running, nothing waiting
- **5g**: Steps · done, nothing waiting
- **6a**: Docs · every document on the ticket
- **6d**: Details · sheet from tapping the subline
- **16h**: Desktop, portrait (1080 × 1500): the same pinned row under the title
- **16i**: Desktop, wide (1600 × 1000): conversation and document side by side, Accept open

### Changes and review
- **19d**: Changes in review · the presentation is the default
- **19e**: Whole file · from an excerpt, and back
- **19f**: No presentation · Files is the default
- **18b**: Changes · the approval pinned under the top bar
- **18c**: Approve tapped · what it commits, and Reject
- **18d**: Docs · approving a document, same row

### Job
- **6e**: Job page · a drill-in from Activity or Steps
- **21a**: Job page, desktop wide (1600 × 900): what it did on the left, where it stands on the right
- **21b**: Job page, desktop portrait (1080 × 1500): where it stands on top, the transcript below

### Chat
- **12c**: Chats · find one again
- **12d**: New chat · after the first message
- **15a**: Talk · responding, with its plan and a way to stop
- **18e**: Chat · merging its branch, the row in neutral
- **15c**: Changes · does not merge cleanly
- **15d**: Stopped · reopen, in today's words
- **15e**: Details · this chat, and ending it

### Project
- **7a**: Tickets · every open ticket, what it is doing
- **7b**: Merge · the order approved tickets land in
- **7c**: Chats · conversations about the project
- **7d**: Workflow · what the next ticket will pin
- **7e**: Proposals · the pane opened from the strip
- **7f**: Details · sheet from tapping the project name
- **12e**: New ticket · title, body, type
- **21c**: + New · ticket, chat, or the release
- **21d**: The release block · its other four states
- **21e**: A release ticket · same frame, its own badge

### Proposals
- **8a**: Proposals · grouped by where they came from
- **8b**: Review · one proposal at a time

### Cache textures by content hash
- **8c**: Select · several at once
- **8f**: Long-press a group: all of its source selected
- **8d**: History · what became of them

### Repository
- **10a**: Commits · the default branch, newest first
- **10b**: Branch · grouped, ticket branches named
- **10c**: Files · the tree at the branch head
- **10d**: A file · its own screen, lines wrap
- **10e**: A commit · what it changed

### Projects
- **11a**: Projects · what needs you, and what can run
- **11b**: Projects · none yet
- **11c**: New project · two fields
- **11d**: Created · the one thing to do next

### Project settings
- **9a**: Settings · one row per section
- **9b**: Tokens · what each may do, in a sentence
- **9c**: Issue a token · choices as rows, nothing that writes preselected
- **9d**: Issued · shown once
- **9e**: Secrets · who receives each, never its value
- **9f**: People · role in place, add at the foot
- **9g**: Model and effort · one page, two dials
- **9h**: Branch and mirrors · what the last push said

### Tokens
- **21h**: Settings, desktop portrait (1080 × 1500): the form moves under the table

### Machines, templates, credentials
- **12f**: Machines · what each is doing
- **12g**: A machine · its log, newest first
- **14a**: Templates · each one's ceiling, in money
- **14b**: A template · ceiling, image, projects, failures
- **14c**: New template · steps in the order the provider needs
- **14d**: Credentials · yours, write-only
- **14e**: None yet · why nothing runs
- **12o**: Desktop, wide: machines as a table, templates and credentials beside

### Accounts and you
- **12i**: Accounts · who may sign in
- **12j**: You · your account and this device

### Usage
- **23a**: Usage · its own top-level page (drawn tall)
- **23b**: Usage, desktop wide (1600 × 900): both windows side by side, what spent it below

### Signing in
- **21o**: Sign in · provider configured: the provider, nothing else
- **21p**: Sign in · no provider configured, or “Other ways”
- **21n**: Coming back · provider errors in plain words
- **21g**: Link sent · and the link opened

### App-wide states
- **20a**: Connection lost · the top bar changes, nothing moves
- **20b**: A message after an action · a floating pill, no buttons
- **20d**: An action that fails · the error stays where you acted
- **20c**: Not found · say what was asked for, and where to go

### Light theme
- **21i**: Light · the queue item
- **21j**: Light · the approval row, and a toast

## Interactions and behaviour
- **Queue.**
  - Opens on the oldest item. "Later" sends it to the end of the pass.
  - An approval item links to the changeset ("Review the changeset ›", an outline button). It never approves in place.
  - Questions open the tabbed question card in a split pane.
  - Stuck shows ways forward as choice rows plus a dock button.
  - "All N" opens a bottom sheet with every item. Decided items stay, dimmed with ✓, for the pass.
  - The end of the queue is its own state.
- **Decision row.**
  - Appears only once the decision exists, e.g. after a document's first version.
  - Its button drops a panel (DropPanel) under the row, over a 60% scrim. It shows what happens, what it pins or commits, warnings, and the secondary act (Reject outlined red, or Answer first) plus the primary in the same colour as the trigger.
  - Tap outside or Cancel folds it. Nothing underneath moves.
  - When questions are open, Accept warns "N open questions will stay unanswered". It never offers answers inside the panel.
  - Reject requires a note (assumed; see RULES.md §7).
- **Title.**
  - On top-level pages, tapping the title drops the navigation menu (19b).
  - On inner pages, tapping it drops the object's details (6d, 15e, 7f). The title shows ▴ while open.
  - Close it with the title, the handle at the panel's bottom edge, or a tap outside.
- **Bottom strip.** Switches views. A new view is a new tab with a grey count, never a special button.
- **Toast.**
  - After an action. A 372px pill floating 84–90px above the bottom, icon plus two lines, no buttons, `pointer-events:none`, 4s, one at a time.
  - Errors are never toasts. They stay inside the panel or field where you acted (20d).
- **Disconnected.** The top bar turns red-hatched with a 2px red top rule, the title reads "Not connected", and the subline counts down. Senders grey out in place, and nothing is hidden or moved. On reconnect it shows green briefly.
- **Moved-button guard.** A button whose position changed in the last 500ms ignores taps.
- **Motion.** 120–220ms, `cubic-bezier(.2,.7,.2,1)`. Panels drop or rise and toasts fade. No pulsing, no spinners: running is shown with ▸ and words.
- **Hover (desktop):** `--surface-2` background. **Pressed:** no shrink. **Disabled:** 45% opacity, same size and place.
- **Focus:** use a 2px `--link` outline with a 2px offset on all interactive elements (not drawn; please add).
- **Responsive.**
  - Phone below 768px.
  - Desktop portrait for tall screens, where blocks stack.
  - Desktop wide from 1440px, which adds columns.
  - Vertical order is the same in every layout.

## State management (LiveView assigns)
- Global, in the root layout: `queue_count`, `usage` (`%{five_h: pct, week: pct, resets: …}`), `connected?`, `flash` (rendered as a toast), `theme`.
- Per object page: `pending_decision` (nil or `%{kind, title, meta, action, tone}`), `decision_open?`, `active_view` (strip tab), `details_open?`, `split_limit_px` (persisted per person).
- Queue: `items` (oldest first), `index`, `deferred` ("Later"), `decided` (for the pass).
- New data the design needs, listed in RULES.md §7: "since you last looked" per person and ticket, waiting and running counts per project, the reviewer's summary and presentation.md, reject notes, usage pace and spend per job, and the machine a chat holds.

## Design tokens
All tokens are in `design_system/tokens/`. Values are authored in OKLCH; the hex values are sRGB approximations for reference.

### Colour, dark (default)
| Token | OKLCH | ≈ hex |
|---|---|---|
| `--bg` | `oklch(15.5% 0.008 300)` | `#0d0b0f` |
| `--surface-1` | `oklch(17.5% 0.008 300)` | `#111014` |
| `--surface-2` | `oklch(19.5% 0.009 300)` | `#151418` |
| `--surface-3` | `oklch(22% 0.010 300)` | `#1b1a1f` |
| `--border` | `oklch(24.5% 0.008 300)` | `#212024` |
| `--border-soft` | `oklch(24.5% 0.008 300 / .6)` | `#212024 @ 60%` |
| `--border-strong` | `oklch(40% 0.010 300)` | `#48474c` |
| `--chip` | `oklch(30% 0.012 300)` | `#2f2d33` |
| `--ink` | `oklch(94% 0.004 300)` | `#ebeaed` |
| `--ink-2` | `oklch(94% 0.004 300 / .75)` | `#ebeaed @ 75%` |
| `--ink-3` | `oklch(94% 0.004 300 / .55)` | `#ebeaed @ 55%` |
| `--ink-4` | `oklch(94% 0.004 300 / .40)` | `#ebeaed @ 40%` |
| `--track` | `oklch(94% 0.004 300 / .10)` | `#ebeaed @ 10%` |
| `--accent` | `oklch(76% 0.130 62)` | `#ec9d53` |
| `--on-accent` | `oklch(18% 0.040 62)` | `#1e0d00` |
| `--accent-text` | `oklch(76% 0.130 62)` | `#ec9d53` |
| `--accent-wash` | `oklch(76% 0.130 62 / .08)` | `#ec9d53 @ 8%` |
| `--accent-line` | `oklch(76% 0.130 62 / .5)` | `#ec9d53 @ 50%` |
| `--accent-highlight` | `oklch(24% 0.035 62)` | `#2b1b0d` |
| `--info` | `oklch(72% 0.100 240)` | `#67addd` |
| `--success` | `oklch(72% 0.120 150)` | `#69ba7c` |
| `--warning` | `oklch(82% 0.110 62)` | `#f8b478` |
| `--danger` | `oklch(72% 0.170 22)` | `#fd7273` |
| `--danger-line` | `oklch(72% 0.170 22 / .5)` | `#fd7273 @ 50%` |
| `--danger-wash` | `oklch(72% 0.170 22 / .06)` | `#fd7273 @ 6%` |
| `--link` | `oklch(72% 0.130 290)` | `#a495f0` |
| `--doc` | `oklch(74% 0.100 210)` | `#51bcce` |
| `--diff-add` | `oklch(72% 0.120 150 / .10)` | `#69ba7c @ 10%` |
| `--diff-del` | `oklch(72% 0.170 22 / .10)` | `#fd7273 @ 10%` |
| `--overlay` | `oklch(8% 0.005 300 / .7)` | `#020202 @ 70%` |
| `--overlay-soft` | `oklch(8% 0.005 300 / .6)` | `#020202 @ 60%` |
| `--toast-bg` | `oklch(26% 0.012 300)` | `#252329` |
| `--toast-ink` | `oklch(96% 0.004 300)` | `#f2f1f4` |
| `--syntax-keyword` | `oklch(76% 0.08 320)` | `#c8a1d1` |
| `--syntax-module` | `oklch(84% 0.05 200)` | `#a5d5d7` |
| `--syntax-function` | `oklch(88% 0.04 260)` | `#c8d9f3` |
| `--syntax-string` | `oklch(82% 0.06 110)` | `#c6c89b` |
| `--syntax-atom` | `oklch(80% 0.06 175)` | `#95cbbb` |
| `--syntax-number` | `oklch(78% 0.07 345)` | `#d9a6c2` |
| `--syntax-comment` | `oklch(94% 0.004 300 / .45)` | `#ebeaed @ 45%` |

### Colour, light (`[data-theme="light"]`)
| Token | OKLCH | ≈ hex |
|---|---|---|
| `--bg` | `oklch(99.2% 0.004 240)` | `#fafdff` |
| `--surface-1` | `oklch(97.5% 0.005 245)` | `#f4f7fa` |
| `--surface-2` | `oklch(95% 0.007 245)` | `#ebeff3` |
| `--surface-3` | `oklch(92% 0.009 248)` | `#e0e5ea` |
| `--border` | `oklch(89% 0.012 250)` | `#d5dbe3` |
| `--border-soft` | `oklch(89% 0.012 250 / .8)` | `#d5dbe3 @ 80%` |
| `--border-strong` | `oklch(75% 0.012 250)` | `#a8afb5` |
| `--chip` | `oklch(90% 0.010 250)` | `#d9dfe5` |
| `--ink` | `oklch(22% 0.025 255)` | `#131b26` |
| `--ink-2` | `oklch(22% 0.025 255 / .75)` | `#131b26 @ 75%` |
| `--ink-3` | `oklch(22% 0.025 255 / .58)` | `#131b26 @ 58%` |
| `--ink-4` | `oklch(22% 0.025 255 / .42)` | `#131b26 @ 42%` |
| `--track` | `oklch(22% 0.025 255 / .10)` | `#131b26 @ 10%` |
| `--accent` | `oklch(80% 0.155 72)` | `#faab35` |
| `--on-accent` | `oklch(24% 0.060 60)` | `#331700` |
| `--accent-text` | `oklch(56% 0.160 52)` | `#ba5100` |
| `--accent-wash` | `oklch(80% 0.155 72 / .14)` | `#faab35 @ 14%` |
| `--accent-line` | `oklch(70% 0.155 62 / .6)` | `#e18518 @ 60%` |
| `--accent-highlight` | `oklch(93% 0.060 80)` | `#fde4bb` |
| `--info` | `oklch(52% 0.150 248)` | `#006cba` |
| `--success` | `oklch(52% 0.140 162)` | `#00804f` |
| `--warning` | `oklch(56% 0.160 52)` | `#ba5100` |
| `--danger` | `oklch(55% 0.200 25)` | `#cc272e` |
| `--danger-line` | `oklch(55% 0.200 25 / .45)` | `#cc272e @ 45%` |
| `--danger-wash` | `oklch(55% 0.200 25 / .06)` | `#cc272e @ 6%` |
| `--link` | `oklch(50% 0.190 278)` | `#504dcb` |
| `--doc` | `oklch(50% 0.100 215)` | `#007187` |
| `--diff-add` | `oklch(60% 0.130 162 / .12)` | `#089868 @ 12%` |
| `--diff-del` | `oklch(60% 0.190 25 / .10)` | `#db4241 @ 10%` |
| `--overlay` | `oklch(30% 0.020 255 / .35)` | `#272e38 @ 35%` |
| `--overlay-soft` | `oklch(30% 0.020 255 / .25)` | `#272e38 @ 25%` |
| `--toast-bg` | `oklch(23% 0.020 255)` | `#171d26` |
| `--toast-ink` | `oklch(97% 0.004 250)` | `#f3f5f8` |
| `--syntax-keyword` | `oklch(45% 0.10 320)` | `#6d4177` |
| `--syntax-module` | `oklch(45% 0.07 200)` | `#156165` |
| `--syntax-function` | `oklch(40% 0.06 260)` | `#344868` |
| `--syntax-string` | `oklch(45% 0.09 110)` | `#595911` |
| `--syntax-atom` | `oklch(45% 0.08 175)` | `#0f6353` |
| `--syntax-number` | `oklch(45% 0.10 345)` | `#7b3c62` |
| `--syntax-comment` | `oklch(22% 0.025 255 / .45)` | `#131b26 @ 45%` |

### Typography
- Families: **Instrument Sans** (UI, reading) and **JetBrains Mono** (ids, paths, numbers, states, sublines, eyebrows). Both are variable woff2 in `fonts/`.
- Scale (px):
  - eyebrow 10.5: mono, uppercase, letter-spacing .14em, 55% opacity
  - meta 11.5: mono
  - small 12.5
  - UI 13.5, tab 13
  - body 14.5 / line-height 1.6
  - title 15 / 600 / −.02em
  - panel 16 / 600
  - queue sentence 19 / 500 / −.01em / 1.3
  - desktop h1 20–22 / 600 / −.02 to −.025em
- Mono ligatures are off in code (`font-variant-ligatures: none`).

### Spacing, sizes, radii, elevation
- **Bars:** 5h line 3, top bar 52, week line 2, decision row 60 (56 desktop), composer 64, strip 56, desktop header 56.
- **Controls:** xl 52 (primary, choice rows), lg 48 (fields, secondary), md 42 (decision button), tab 40, sm 36 (row actions), desk 34, desk-sm 28. Phone hit targets ≥ 44.
- **Spacing steps:** 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 30, 40. Gutters 20 (phone) and 30 (desktop). Reading measure 680–820.
- **Radii:** 4 (badges), 5 (desktop controls), 6 (buttons, fields, rows), 8 (cards, notices), 14 (outer corners of sheets and drop panels), 999 (queue button, bubbles, toasts, composer field).
- **Shadows:**
  - decision row `0 8px 14px -10px oklch(6% .005 300 / .9)`
  - panels `0 16px 30px oklch(6% .005 300 / .8)`
  - toast `0 10px 30px oklch(6% .005 300 / .6)`
  - scrims `oklch(8% .005 300 / .6–.7)`
- **Selection and attention:** a 2px inset left edge: ink (selected), amber (waits on you), red (broken).

## Assets
- `assets/forge-logo.svg`: the existing logo, used on sign-in at 72px (provider screen) and 44px (other ways).
- `fonts/instrument-sans-var.woff2`, `fonts/jetbrains-mono-var.woff2`: self-host these.
- Icons: none from a library. State marks are Unicode with fixed meanings: ◆ waits on you (amber), ▸ running (blue), ● step/state, ✓ done, ✗ failed, ◇ unapproved document, ○ idle, › navigates, ▾▴ open/closed, ‹ back to the queue.
- Two inline stroke SVGs (1.5–1.6px, round caps): the queue inbox and the composer send arrow. Source is in `QueueButton.jsx` and `Composer.jsx`.
- Object kinds: a 26px tinted square (16% of the colour) with a mono glyph: md (document), ± (changeset), ⑂ (branch), ⇡ (release), ⌁ (connection).
