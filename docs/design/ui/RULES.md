# forge UI — design rules and handoff

Source of truth for the screens: `Final Design.dc.html` (every agreed screen, grouped by area). Exploration and history: `Ticket View - Redesign.dc.html` (turns 1–22, newest on top). Screen ids (e.g. `18b`) are the same in both files.

## 1. Principles

1. **The queue is home.** It is the only top-level page. Everything else is reached from it, from the title menu, or from links.
2. **One decision per place.** A decision lives in a row pinned under the top bar, on the page that shows the thing being decided. The queue never decides; it links.
3. **The bottom navigates and replies.** The bottom strip switches views. The composer replies. Neither holds a step decision.
4. **Nothing transient takes a decision's place.** Connection state, toasts and errors never use the decision row.
5. **Layout never moves under a finger.** Disabled buttons keep size and place. Toasts overlay. A button that moved ignores taps for 500ms.
6. **Colour carries meaning, not decoration.** See §4.
7. **Vertical first.** Phone and portrait desktop are primary. Wide desktop adds columns; it never reorders.

## 2. Frame

### Phone (412 wide reference)
| Part | Size | Content |
|---|---|---|
| Top bar | 52px | Left: queue button (amber pill, ‹ + inbox icon + count; always goes to the queue). Middle: title + mono subline (state). Right: usage gauge (§3.6), then the context button (project, `game ›`). |
| Decision row | 60px, optional | Pinned under the top bar, shares its surface and shadow. See §3.1. |
| Content | flex | Scrolls. Max reading measure on desktop: 680–820px. |
| Split pane | optional | Questions. Draggable handle, fits its card up to a user-set limit. |
| Composer | 64px | Field with send as an icon inside it. Never a filled button. |
| Strip | 56px | Views of the current object (e.g. Steps · Changes · Docs · Activity), count bubbles. No decisions. |

Top-level pages (Queue, Projects, Chats, Machines): the title is a switch (`Queue ▾`) that drops the navigation menu from the top bar. Inner pages have plain titles.

### Desktop
- Header 56px: wordmark + version, `Projects ▾`, Queue with count, usage gauge (§3.6), account.
- Title row: back link, h1, state, view tabs on the right.
- Decision row: same component as the phone, 56px, full width.
- Wide (≥1440): add a context column (360–440px) right, or a list column (320–360px) left. Portrait (≈1080): stack the same columns vertically in the phone's order.

## 3. Components

### 3.1 Decision row
- Icon (26px tinted square) · object name in mono with key facts · meta line (11px mono) · button.
- Button: 42px phone / 34px desktop. **Amber filled** when something waits on you (Accept, Approve). **Neutral outline** when it doesn't (Merge a chat).
- 2px inset edge in the same colour as the button.
- Tapping the button drops a confirmation panel from the row over a dimmed page (`16g`, `18c`): what happens, what it pins/commits, warnings, then secondary (Reject / Answer first / Cancel) + primary in the same colour as the trigger.
- Open questions are never answerable inside that panel; it warns: "N open questions will stay unanswered" (`16g`).
- Appears only when the decision exists (e.g. after the first document version, `16e` → `16f`). Leaves when the decision is made.

### 3.2 Drop panels
The single overlay pattern: title menu (`19b`), object details from the title (`6d`, `15e`), decisions (`16g`, `18c`), usage (`22e`). Drops from the bar it belongs to, full width on phone, anchored to the trigger on desktop. Tap outside to close. Nothing below moves.

### 3.3 Sheets
From the bottom, only for things opened from the bottom: "+ New" (`21c`), "All items" (`13e`), the workflow map (`7f`).

### 3.4 Buttons
- One filled button per screen region, never two adjacent.
- Filled white (ink on light) = the next step. Amber = a decision waiting on you. Outline = navigation or secondary. Outlined red = destructive.
- Hit targets ≥44px on phone, primary actions 48–52px.

### 3.5 Transient states (`20a`–`20d`)
- **Disconnected:** the top bar itself turns red-hatched with a 2px red rule; title becomes "Not connected", subline counts down. Senders grey out in place. No buttons.
- **Toast:** floating rounded pill above the strip, ~372px, icon + two lines, no buttons, `pointer-events: none`, 4s.
- **Errors:** never toasts. Shown inside the panel you acted from, or under the message they belong to.
- **Not found / not allowed:** keeps the frame, names what was asked for, offers the two useful destinations.

### 3.6 Usage gauge (`22l`)
Two lines frame the top bar on every signed-in screen:
- **5-hour window:** 3px line directly above the top bar, full width.
- **Week:** 2px line that replaces the top bar's bottom border. A pinned decision row sits below it.
- Fill left to right; track at 10% ink. <80% quiet ink (60% / 45%), ≥80% warning yellow, ≥95% red. Never amber.
- Tapping the top bar's top or bottom edge opens the usage panel (`22e`): percent, reset time, pace, what is spending.
- Desktop: same lines around the header; a quiet mono "42% 5h · 18% wk" beside the account takes the line colours (`22n` digits, `22l` placement).
- Not shown on sign-in screens.
- Detail page `23a` (phone) / `23b` (desktop): both windows with reset and pace, 15-minute spend for the 5h window, per-day spend for the week, what spent it (by item / project / model). Reached from the title menu, the panel's *Details ›*, and the desktop digits.

### 3.7 Lists and rows
- Ticket rows: number · title · type badge · state dot + step · latest event (warning colour on failure).
- Workflow track: 7 segments, done 50% ink, current amber, next 30%, rest 12%.
- Grouped lists (proposals): source header with select-all checkbox, members indented on a 1px rail (`8a`).

### 3.8 Code
Server-side highlighting (`10g` plan): `ForgeWeb.Highlight.file/2`, `:lumis`, classes → `--syntax-*` vars, plain fallback over 100 KB / unknown / error. Lines wrap, ligatures off, 28px gutter. Diffs: green/red row tints at 10%.

## 4. Colour

Dark (default), OKLCH:
| Token | Value | Use |
|---|---|---|
| bg | `oklch(15.5% 0.008 300)` | page |
| surface-1 / 2 | `17.5% / 19.5% 0.008–0.009 300` | cards, strip, selected |
| border | `oklch(24.5% 0.008 300)` | rules |
| ink | `oklch(94% 0.004 300)` | text, filled button |
| amber | `oklch(76% 0.130 62)` on `oklch(18% 0.040 62)` | waits on you: queue button, decision buttons, current step |
| info blue | `oklch(72% 0.100 240)` | running, agent actions |
| success | `oklch(72% 0.120 150)` | passed, added, connected |
| warning | `oklch(82% 0.110 62)` | outdated, expiring, near a limit |
| error | `oklch(72% 0.170 22)` | failed, removed, disconnected, destructive |
| link / select | `oklch(72% 0.130 290)` | links, selected options |
| document | `oklch(74% 0.100 210)` | document icons |

Light (`21i`, `21j`): cool neutrals around hue 245–255 (`bg 99.2% 0.004 240`, `border 89% 0.012 250`, `ink 22% 0.025 255`). Amber fill `80% 0.155 72`, amber as text `56% 0.160 52`. Other accents deeper: success `52% 0.140 162`, error `55% 0.200 25`, info `52% 0.150 248`, link `50% 0.190 278`. Toast stays dark.

Syntax (dark): keyword `76% .08 320`, module `84% .05 200`, function `88% .04 260`, string `82% .06 110`, atom `80% .06 175`, attribute/number `78% .07 345`, comment ink 45% italic. Chroma ≤ 0.08 so code never reads as status.

## 5. Type
- UI: Instrument Sans. Data, ids, paths, numbers: JetBrains Mono.
- Phone: title 14–16/600, body 14–15/1.6, meta 11–12.5 mono, eyebrows 10.5–11 mono uppercase +0.14em.
- Queue sentence 19/500. Page h1 20–30/600, −0.02 to −0.03em.

## 6. Screen map

| Area | Final screens | Replaces / built from |
|---|---|---|
| Navigation | 19a–19c | `components/layouts.ex` |
| Queue | 18a, 13b–13g | `live/queue_live.ex` |
| Ticket | 5j, 16e–16i, 2a–2d, 5d, 5g, 6a, 6d | `live/ticket_live.ex`, `components/work_screen.ex`, `components/step_accept.ex`, `live/operator/question_form.ex` |
| Changes / review | 19d–19g, 18b–18d, 18f | `components/diff.ex`, `live/review_live.ex` (folded in) |
| Job | 6e, 21a, 21b | `live/job_live.ex` |
| Chat | 12c, 12d, 15a, 15c–15f, 18e | `live/chat_live.ex`, `chats_live.ex`, `chat_new_live.ex` |
| Project | 7a–7h, 12e, 21c–21e | `live/project_live.ex`, `ticket_new_live.ex`; `live/operator/board.ex`, `board_live.ex` retired |
| Proposals | 8a–8g | `live/project_live.ex` (proposals) |
| Repository | 10a–10f | `live/repo_live.ex`, `repo_commit_live.ex` |
| Projects | 11a–11e | `live/projects_live.ex`, `project_new_live.ex` |
| Settings | 9a–9i, 21h | `live/project_settings_live.ex` |
| Machines | 12f, 12g, 12o, 14a–14f | `workers_live.ex`, `worker_live.ex`, `templates_live.ex` |
| Usage | 23a, 23b | `components/layouts.ex` (gauge), new usage page |
| Accounts / you | 12i, 12j | `accounts_live.ex`, `user_live/settings.ex` |
| Sign in | 21o, 21p, 21n, 21g | `user_live/login.ex`, `user_live/confirmation.ex` |
| States | 20a–20d | `components/layouts.ex` (flash, connection) |

## 7. Needs code
- "Since you last looked": per-person last-viewed per ticket (`13a`, `13f`).
- Waiting and running counts per project (`11a`).
- Change a member's role in place (`9f`); one Save for model + effort, and the resolved "machine's" value (`9g`).
- The machine a chat holds, in its details (`15e`).
- Review step writes `presentation.md` with excerpts, "How it was checked", "Worth a look" (`19d`, `19g`).
- Reject requires a note (`18c`); reviewer summary (`18a`).
- Usage pace projection, 15-minute and per-day spend history, per-item / project / model breakdown (`22e`, `23a`).
- Remember last sign-in method on the device (`21m`, optional).
- `:lumis` precompiled binary on the deploy image (`10g`).

## 8. Check against the code
- Project naming rule (`11c`); new-ticket fields (`12e`); machine states (`12f`).
- Accounts admin-only, waiting accounts count toward the queue badge (`12i`).
- Release "Since 0.31" assumes the previous tag is findable (`21e`).
- Placeholders: model names (`9g`), euro prices (`14a`), provider name/host `manu.software` / `auth.manu.software` (`21o`).

## 9. Known gaps in Final Design
- 5j, 5d, 5g, 6d show no waiting decision; when one exists, they take the §3.1 row as 6a does.
- Inner machine page 12g has no queue button on the left; add it as on other inner pages.
