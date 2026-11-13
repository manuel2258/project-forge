# Capacity and usage

Scope: how consumption is modelled, recorded and drawn. Consumption is **consumed capacity, not
money**: one unit is one percent of a five-hour window, and quantities are stated in **windows** to
two significant figures and never more than two decimals (`1.4 windows`, `0.08 windows`), with
anything under a hundredth of a window written `<0.01 windows`. This survives work that spans four
windows and a week, which a percentage cannot, and it replaces `$0.15562769999999998` on every
operator surface. `0.0020 windows` beside `0.080 windows` was precision nobody can use, and on a
phone it was the figure that pushed a row onto a fourth line (UX pass, A11, B9).

**What a run used is weighted tokens, for every harness** (§ Usage in weighted tokens). It stays on
jobs and tickets as `usage`, the PoC's definition of usable asks for a total per ticket, and a
usage cap is enforced against it. It is not something the operator is shown directly: windows are.
Claude Code's own dollar figure is kept per run as information (`claude_cost_usd`), read by no cap
and no pick.

## Usage in weighted tokens

Codex reports no dollars, and forge must run a model released after its last release without
learning its price. So a run's usage is its tokens weighted by kind, the same weights for every
model and harness, **written here and nowhere else** (`ForgeCore.Usage` holds them):

| kind | weight |
|---|---|
| fresh input | 1 |
| cache write | 1.25 |
| cache read | 0.1 |
| output, reasoning included | 5 |

Held in hundredths (100, 125, 10, 500) so the arithmetic is integer; a run's usage is
`div(sum + 50, 100)`, an integer number of **weighted tokens**. These are Anthropic's price ratios,
so a large model's token counts as a small one's: the figure measures work done, not exactly
window consumed, which is the price of needing nothing per model. Output alone was declined: it
was a fifth of the weighted total on the figures of the conversation that settled this, and blind to the reading that dominates an agent's
work.

**Each model call is counted once.** Claude Code's stream repeats one call across several
`assistant` lines, so the worker's meter (`ForgeWorker.Job.Meter`) keeps a map of `message.id` to what has been counted and a
repeated line adds only its increase. A subagent's calls (lines with `parent_tool_use_id`) count
the same. A resumed run's usage is its own: only this run's calls are summed, never its session's
running total (ticket 36).

**Notation.** An integer, or a number with `k` or `M`: `800k`, `4M`, `84.2M`
(`ForgeCore.Usage.parse/1`, shown the same way). Workflows write `budget: { turns: 80, tokens:
800k }` and `limits: { ticket_tokens: 84.2M }`; the node sets `FORGE_DAILY_TOKENS`.

**The dollar rate is a placeholder.** `ForgeCore.Usage.per_dollar/0` is 200,000 weighted tokens to
the dollar — $5 per million fresh input tokens, an Opus-class price, with the weights above being
price ratios. It converts old dollar figures once (the migration, a pending job's `cost` budget)
and nothing else; fitting it to recorded runs is later work, like `window_tokens`.

## What the provider reports

Claude Code emits an undocumented `rate_limit_event` on the stream-json channel. Evidence from the
local dev node, 87 events across its job transcripts:

```json
{"type": "rate_limit_event",
 "rate_limit_info": {"status": "allowed_warning", "resetsAt": 1789210800,
                     "rateLimitType": "five_hour", "utilization": 0.96,
                     "isUsingOverage": false, "surpassedThreshold": 0.9},
 "uuid": "…", "session_id": "…"}
```

What the sample establishes:

- `rateLimitType` was `five_hour` on all 87. **No event of the sample was about the week**; the
  week has since been seen in `unifiedWindows` (§ What newer releases add) and is drawn from it.
- `resetsAt` (unix epoch) is present on all 87. The window boundary is provider-reported and does
  not have to be inferred.
- `utilization` is present on only 21 — exactly those with `status: "allowed_warning"`, once
  `surpassedThreshold` (0.9) is crossed. **Below the threshold the provider reports no figure at
  all.**
- `status` was `allowed` (66) and `allowed_warning` (21). A rejecting status was not observed.
- `overageStatus` / `overageDisabledReason` appear on the `allowed` events; `isUsingOverage` on
  all of them.

The consequence for drawing: the countdown is real and always available, and the gauge is only
honest above 90%.

**What newer releases add.** Third-party reports show `rateLimitType: "seven_day"` for the weekly
window and a `rejected` status once a window is exhausted; neither is in the sample above, and a
report whose own type is `seven_day` has still not been seen here. A `unifiedWindows` object has:
on the running platform (seen 2026-10-29; the version of Claude Code on the workers that sent them
was not recorded) one report carried `utilization` and `resetsAt` for `five_hour` (1%) and
`seven_day` (30%) together, and a later one on the same credential, the newest then, carried a
`unifiedWindows` holding only `five_hour`. So a report does not always name every window, and one
that leaves a window out says nothing about it. The driver maps `unifiedWindows` when it is present and the raw
message is kept either way, so the gauge is honest below 90% as well and the week has something
to draw (`docs/design/credentials.md` § Rate limits are per credential).

## Two objects, never drawn the same way

**Usage** is absolute and never resets: a job's usage, a timeline step's sum, a ticket's total
against its allowance. It is derived from `usage` through a single configured constant,
`config :forge, :capacity, window_tokens:` — the weighted tokens of one whole five-hour window,
1,000,000 to begin with (the old 5.0 dollars at the rate above). The
provider gives no per-job window share, so this constant is the only bridge from what the harness
reports to the unit the operator reads. **It is a placeholder until dogfooding calibrates it**, and
it is the one number in this note that is not evidence.

Drawn as a figure plus a 5px meter filled accent, against the ticket allowance. The allowance is
`limits.ticket_tokens` from the workflow grammar (the old `ticket_cost` converted), displayed in windows. A ticket allowance stays absolute — a cap expressed as a share of a refilling pool
would mean something different on Monday than on Friday.

**Capacity** is a live shared pool that refills, and it comes from `rate_limit_event` rather than
from anything forge computes. Each window — five-hour and weekly — is drawn as **a line**: the
five-hour window a 3px line directly above the top bar, the week a 2px line that is the top bar's
bottom border (`ui.md` § Usage). A line fills left to right over a track of ink at 10 %; **below
80 % it is quiet ink, from 80 % warning, from 95 % danger.** It is drawn **only from a
`utilization` figure the provider supplied** — in practice once the warning threshold is crossed.
A window with no figure draws no fill and no track: inventing the first ninety percent of a
meter's range is exactly the failure a quiet page avoids, and a quiet page should stay quiet until
capacity binds. Its reset is said where the window is written out — the usage panel, the usage
page, the desktop digits' title — as a mono time, whenever a reset is known.

The week is drawn like the five-hour window, from the newest report that names it — in
`unifiedWindows`, or as a report's own type — until its reset passes; with no such report there is
nothing truthful to draw, so it is not drawn.

**The lines draw a set of credentials, not one.** With a pool there is no single window, so each
line is, per window, the mean utilization of the credentials the page is about that have reported
one, a limited credential counting as full; where it is written out it says how many of them it
averages and the soonest reset among them. Which credentials is the page's: a project's pool on a
page about that project, the viewer's own everywhere else (`docs/design/credentials.md` § Showing
the windows). The rules above hold for it unchanged — no figure, no fill; neutral, never accent. A
set in which nothing reported draws nothing.

**The window lines are neutral, never accent.** The first handoff listed the window gauge among the
accent uses, which contradicts the rule accent exists to serve: accent means a human is being
waited on, and window capacity is resolved by time rather than by a person. Drawing it in accent
would put a loud mark on the one exhaustion the operator can do nothing about. The redesign's
handoff agrees (*never amber*), and goes further in the same direction: the lines turn warning and
danger as a window fills, which are the colours for *near a limit* and say nothing about who must
act. Usage against a ticket allowance stays accent — that ceiling does need a human.


## Four exhaustions, three treatments

Only one of them is the operator's.

| Exhausted | Resolved by | Treatment |
|---|---|---|
| A job's own budget | **the workflow** — a retry, or an edge onward to a person | outcome `budget_exhausted` on the job row with `· turns`, `· tokens` or `· wall clock` beside it, nowhere else |
| Ticket allowance | **a human** — raise it or reroute | sticks the ticket, enters the queue, drawn in accent |
| Daily spend cap | **time**, or the operator raising it | `paused · spend 6h 12m` in the ticket's subline, neutral, counting down to midnight UTC; the project's ticket list draws `paused · spend` without the countdown. **Never in the queue** |
| Window capacity | **time** | `PAUSED · CAPACITY 1h 12m`, neutral, on the ticket and the project's ticket list, **never in the queue**. Not built (§ Engine support) |

**The first row is the workflow's, not the engine's.** What happens to a job that ran out is an
edge in the definition: a self-retry where one is declared, and otherwise wherever
`when: budget_exhausted` points — forge's own `reviewing` sends it on towards `review_ready`,
because a review that spent its budget on subagents learns nothing from being run again from
scratch and a person should read whatever report it left. (It goes by way of `presenting`, which
every route to `review_ready` takes; that is `ui.md` § Changes, not this note.) Where the workflow declares no edge at all the ticket
sticks and enters the queue, which is the second row's treatment reached by another road.

**`budget_exhausted` names its ceiling.** The outcome says a job ran out; which of the three
ceilings it ran out of — its turn budget, its cost budget, or the driver's wall clock — is a word
beside it on every job row (`jobs.exhausted`, `ForgeWeb.Indicators.ceiling/1`, drawn fainter
than the outcome it qualifies) and on the job in the API, which the UI is a client of. Before it,
"ran out of money" and "ran out of turns" were one atom and the distinction survived only in the
free text of a `job.finished` event, which is the wrong place for it: they want different
responses from whoever reads the row. Nothing is drawn for a job whose ceiling was not
recorded — a row from before the column, or from a worker too old to send it — because an absent
fact is not one of the three.

**A job's turns are not drawn against its turn budget.** `jobs.turns` is the harness's own
`num_turns` summed over every invocation the job has had, and `spec.budget.turns` is the
`--max-turns` ceiling each single invocation is given; a job the engine resumed after a rate
limit can pass the second without ever breaching it. Drawn as a ratio the pair told a story the
numbers do not: `37/30 converged` on a job no cap had stopped, beside `38/60 budget_exhausted` on
a job that $5.07 of $5.00 had. So the job page draws the turns a job used, the pinned manifest
draws the ceiling as *per run*, and what actually ended the job is the word above. This departs
from the first handoff's "turns always against budget" (its `docs/design/ui/README.md`, in git
history at `92ea7c1`), deliberately and for that reason.

**The usage ceiling overshoots, and that is the mechanism working.** Forge counts after each model
call and stops the run after the call that crosses the line: `810k of 800k` is a cap doing its job,
not failing at it. Nothing rounds them down or hides
the overshoot — a figure the operator cannot reconcile against the run is worse than one that
reads a few cents over.

Keeping the pauses out of the queue is load-bearing. A paused ticket in the inbox trains the
operator to open items they cannot act on, which is the exact failure the thesis is written
against. The daily cap is the platform's own rather than the provider's — it is what the operator
sets so a bad night cannot cost a month — but it is resolved the same way, by a clock, so it is
drawn the same way. The countdown is to the next UTC midnight.

## Usage history

The usage page (`ui.md` § Usage) says what spent a window and how fast it is filling. Both are
read from records the platform already keeps; no history of utilization is stored.

**Spend over time is the run ledger, bucketed by when a run reported.** `job_runs` (`credentials.md`
§ Spend) holds what each run of a job used, in weighted tokens (§ Usage in weighted tokens), and on
which credential; no dollars are read, for either harness. The five-hour card draws the
spend of the page's credentials in 15-minute buckets from the window's start to its reset; the
week card in one bucket per day of the window, 24 hours each from its start, so a week is seven
bars and not eight part-days. A bucket holds its start and not its end. A window no credential has
reported has no reset, and its buckets run over the length before now instead. **A run lands in one bucket, the one holding the moment its usage was
last written** — `finished_at` for a run that reported, and for a run still open, the moment a
conversation's turn last counted it. A workflow job reports its usage only at its end, so a long job
is one bar at the moment it finished, not spread over the hours it ran; a conversation's run records
itself every turn with its running total, so its whole usage so far sits at its latest turn. That
is coarser than the truth and says so; spreading usage over a run's life would be inventing a
rate nothing reported. `Forge.Jobs.Runs.record/3` writes the usage with `update_all`,
which stamps nothing on its own, so it sets `updated_at` itself: that is the open run's moment.

**Pace is projected, not remembered.** A window's start is its reset less its length — five hours,
or seven days — and its average rate is its latest utilization over the time since that start.
Projected to the reset at that rate, a window that would cross 100 % before it resets is drawn
*full in ~N*, the time until it would; any other is *on pace*. It needs the latest utilization and
reset, which `Forge.Credentials.windows/2` already reads, and nothing else. A window with no
utilization has no pace.

**What spent it is a share of the window's figure**, never dollars: each item's — a job or a
conversation, the running ones marked — project's or model's share is **the window's measured
figure split by usage**, its weighted tokens over those of everything the set used since the window
began, times the figure. The figure is capacity, measured; the weighted tokens only say how it
divides, so the
shares add up to the figure over them and never to more. **That includes use outside forge.** The
figure is the provider's, and counts everything the credential did — its owner's own Claude
sessions as much as forge's jobs — while the weighted tokens are forge's alone, so whatever the
credential did elsewhere is split in with forge's lines in proportion to their usage: one 20k-token
job on a credential its owner has filled to 80 % by hand reads 80 %. The legend says so, in those words —
*use of these credentials outside forge is split in with them* (review fixes 7, M2). Setting it
apart as a line of its own, *N % outside forge*, was weighed and not built: it needs forge's part
of the figure from forge's usage, which is the estimate below — a configured guess at a window's
size (`window_tokens`), a placeholder, in five-hour windows and so in no unit the week's figure has, and summed
over credentials whose figure is their mean. A line computed from that would present a guess as
a measurement, which is what this section exists to stop. With a figure and nothing spent yet,
every share is 0 %. They were each a share of
`window_tokens` (once `window_cost_usd`), the unit § Two objects defines, and that is a different object: on a set of two
credentials at 91 %, shares of *one* configured window read 95 % under it (UX pass, D6). **With no
figure** — no credential of the set has reported the window — there is nothing measured to split,
and the share is that estimate, said to be one: *share of one 5h window, estimated from tokens
used*. A conversation's model is `jobs.model`, a workflow job's the one its spec
was resolved to, and a job with neither is *the project's default*. **An item in a project the
viewer is not a member of is counted and never named**: one line, *elsewhere*, because the viewer's
credential paid for it and a project they are not in is not one they may learn about (`identity.md`
§ Read scoping) — under every breakdown, the model one included. What is spending now, in the usage
panel, is the items of that list with a run still open.

## Spend caps

`usage` is what a cap is enforced against, even though it is not what the operator is shown. (The
caps are *usage caps*: they count weighted tokens, not money.)
Both caps live in `Forge.Spend` and are asked in `Forge.Jobs.assign/2` (its `spend_gate`), which
every billed invocation passes through: a job reaches a machine only by being assigned to one, so
a ticket over its allowance is stuck before a worker is spoken to. It was `start/1` while the
platform ran jobs itself. A conversation has no ticket allowance and meets the daily cap alone. A
ticket over its allowance is stuck, which also drops it out of `Forge.Jobs.pending/2` so the
scheduler stops retrying it every tick.

**The day's total** is the sum of the usage of the runs that *started* in that UTC day — each start
of a job is a run (`docs/design/credentials.md` § Spend) — monotonic, and it matches what the
operator watched happen. A job in flight has recorded nothing — usage lands
at completion — so the figure the gate reads adds the budgeted tokens of every live job to what is
already spent. Without that, several concurrent jobs each pass the gate on their own and together
walk straight through the cap.

**Stopping a job already running** is forge's own, during the run, for both harnesses. The driver
emits a `usage` event per model call; the runner (and a chat's process) keeps the weighted sum and,
once it passes the effective budget, stops the process through the wall-clock path and the run ends
`budget_exhausted`, stopped `:tokens`. The effective token budget of a job is the least of what its
state declared, what the ticket has left and what the day has left; a conversation's is what is
left of the day. The stored spec is not touched — a job's budget is written once — and the
difference is recorded as `job.budget_lowered`, without which a job stopping at a tenth of its
declared budget is inexplicable to anyone reading the log later. Claude Code is no longer given
`--max-budget-usd`. This is what a worker needs protocol 11 for.

**The job is told as well.** The manifest's budget says what a lowered cost was lowered from and
by which cap, and names what the ticket has left of its allowance for every job still to run on
it. The event is the operator's record; the agent could not read it. Without the figures one
ticket's jobs all finished far under budget — the largest used $6.76 of $30.00 — while reasoning
that "a fifth edit to this file would cost the ticket a whole implementing cycle", which a visible
allowance answers at once.
The wall clock remains the platform's own coarse stop, independent of whether the harness honours
its flag.

## Engine support

Three changes, in order of dependency.

**1. Map the event. Built.** `ForgeWorker.Harness.ClaudeCode` let `rate_limit_event` fall through
its catch-all into `harness.unknown` until `docs/design/credentials.md` needed it. It has a clause
emitting `harness.rate_limit` with `status`, `resets_at`, `rate_limit_type`, `utilization` and
`is_using_overage`, keeping the raw message in `payload.raw` like every other event.
`claude-code-events.md` records it as an undocumented type observed in practice.

**2. Read the window from the event log.** No new table. The append-only event log is already the
record, so the window is read from the most recent `job.harness.rate_limit` event. **With more than
one credential there is more than one window**: a limit is an account's, and the node's latest
event may be another account's. So the platform stamps the job's `credential_id` onto each
`rate_limit` event it records. **And a credential has more than one window**: each report names its
`rateLimitType`, and a report about the five-hour window says nothing about the week. So whether a
window blocks is its own type's latest event per credential, and a credential is limited while any
of them blocks — which is what `docs/design/credentials.md` § How a job picks reads to pass over a
limited credential. Staleness is self-evident rather than hidden: a `resets_at` in the past means
the window has rolled over and utilization is unknown again, which is the same state as having no
figure yet. **A window's figure is the newest report's that names it**, either as its own type
or in `unifiedWindows`, and so is its reset — except that a window that blocks keeps the reset of
the report that blocks it, which is what it blocks until. A report that leaves a window out leaves
it as it was, until its reset passes (`Forge.Credentials.windows/2`; the week vanished from the top
bar when a five-hour report whose `unifiedWindows` held only `five_hour` followed one that held
both, ticket 32). Blocking is unaffected — only a report's own status decides it.

**3. Gate the scheduler.** `Forge.Jobs.Scheduler` refuses to start a job while the current window
is blocking, leaving the ticket `active` — not `stuck`, and not in the queue — and surfacing as
`PAUSED` until `resets_at`. **The gate is per credential, through the pick**: a job whose every
credential is limited waits pending with its ticket active, and a job whose own credential is
limited moves to a free one (`docs/design/credentials.md` § How a job picks). A job stopped by a
limit *mid-run* goes back to pending the same way rather than failing (`credentials.md` § A limit
reached mid-run). The `PAUSED · CAPACITY` surface on the ticket is not built. The gate keys on
the status string: anything beginning `allowed` permits, anything else pauses. That is
forward-compatible with statuses this sample does not contain, and it fails towards not spending an
invocation rather than towards burning one. A rejecting status has not been observed, so until one
is, this path is written from the naming convention rather than from evidence, and it is the first
thing to verify when a window is genuinely exhausted.

## Memory, which a job holds rather than spends

A job's memory is neither usage nor capacity in the sense above. It does not accumulate, and it
does not refill: it is a **ceiling the job holds for as long as it runs** — its slice's
`MemoryMax`, which the gate reserved on a machine (`docs/design/provisioning.md` § The gate) — and
a **peak** the job reached under it. Nothing about it is a person's to wait on while it is fine,
so a quiet job draws nothing about memory at all.

**It is drawn only when it was the trouble**: a process in the job was killed for memory, the job
reached its ceiling, or it thrashed there (`claude-code-events.md` § Memory). Then, and only then:

- **In the job's header** — the job page's, under the outcome, and a conversation's context strip
  — one mono line in `warning`, with a `△` in front: *2 OOM kills · peak 2.0 GiB of 2 GiB*, or
  *reached its ceiling · peak 2.0 GiB of 2 GiB*, or *thrashing at its ceiling · peak …*. The
  figures are the worst the job's events and its result report, so it is visible without
  scrolling the timeline.
- **In the timeline**, each `memory` event is a row like any other with its sentence
  (`Forge.Events.summary/1`), the type in `warning`.
- **In a conversation's now line**, when a memory event is the latest thing the turn reported.

**`warning`, never accent and never error.** Not accent, for the reason the window gauge is not:
a job at its ceiling is not waiting on a person, and the one loud colour is kept for what is. Not
error, because a job whose child was killed and which retried with less parallelism has done
nothing wrong; when the harness itself was killed the job's outcome says so in error colour
already, and the reason says why in words. Peak against ceiling is two figures and no meter: the
peak of a job that reached its ceiling *is* the ceiling, so a bar would be full whenever it
mattered and say nothing the words do not.

`Forge.Jobs.Memory` computes it from the job's events — `trouble/1`, reading the `memory` events
and the `memory` a `job.finished` or a `chat.turn` ended with — and words it: `words/1` for the
header, `sentence/1` for an event's row and the now line, so the three cannot disagree. A figure
the worker sent that is not a whole number of bytes is left out of the line rather than raised on.

## Open

- **`window_tokens` is uncalibrated.** Every absolute usage figure is wrong by whatever factor it
  is wrong by until dogfooding sets it. It is a display constant only: nothing schedules, caps or
  refuses on it.
- **A report whose own type is the week is unobserved.** The week has been seen only in
  `unifiedWindows`, and is drawn as the five-hour window is, as its own line.
- **The rejecting status is unobserved**, so the scheduler gate's trigger is inferred from naming.
- **A job at a window edge** goes back to pending with its session and resumes — on another
  credential if one is free, on its own after the reset if not (`docs/design/credentials.md`
  § A limit reached mid-run). What is still unsettled is whether Claude Code, stopped by a limit,
  leaves a session that `--resume` continues cleanly; a resume that does not start at all already
  falls back to a fresh run from the branch.
- **Whether dollars survive anywhere.** The recommendation is that they leave every operator
  surface and stay in the API, the Mix tasks and the event log. A number the operator cannot act on
  is noise; capacity is one they can act on. One exception is deliberate: a credential's spend on
  `/users/settings` was in dollars, beside a daily limit typed in dollars, because an API key is
  billed in them and has no window (`ui.md` § Account settings).
- **Machine spend is a third kind of cost and this note has no place for it.** Everything here is
  inference: a refilling window, and usage in weighted tokens. `docs/design/provisioning.md`
  adds an hourly bill for machines, which refills nothing, accrues with no job running, and is
  bounded by a count — `max_workers` per template — rather than by money. It is also the one
  figure an operator can act on immediately, which by this note's own test earns it a surface.
  Two things are unsettled: whether it belongs beside window capacity or stays on the templates
  page, and what to do about currency, since that note's first provider bills euros while every
  figure here is dollars and nothing converts them.
