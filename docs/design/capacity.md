# Capacity and usage

Scope: how consumption is modelled, recorded and drawn. Consumption is **consumed capacity, not
money**: one unit is one percent of a five-hour window, and quantities are stated in **windows** to
two significant figures (`1.4 windows`). This survives work that spans four windows and a week,
which a percentage cannot, and it replaces `$0.15562769999999998` on every operator surface.

`cost_usd` stays on jobs and tickets. It is what the harness reports, the PoC's definition of
usable asks for a total per ticket, and a spend cap is enforced against it. It simply stops being
something the operator is shown.

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

- `rateLimitType` was `five_hour` on all 87. **No weekly event was observed**, so the week is not
  drawn until one is.
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

**What newer releases may add, unverified here.** Third-party reports show `rateLimitType:
"seven_day"` for the weekly window, a `rejected` status once a window is exhausted, and — on newer
Claude Code — a `unifiedWindows` object on every event carrying `utilization` and `resetsAt` for
`five_hour` and `seven_day` together. None of it is in the sample above. The driver maps
`unifiedWindows` when it is present and the raw message is kept either way, so if it arrives the
gauge is honest below 90% as well and the week has something to draw
(`docs/design/credentials.md` § Rate limits are per credential).

## Two objects, never drawn the same way

**Usage** is absolute and never resets: a job's usage, a timeline step's sum, a ticket's total
against its allowance. It is derived from `cost_usd` through a single configured constant,
`config :forge, :capacity, window_cost_usd:` — the cost of one whole five-hour window. The
provider gives no per-job window share, so this constant is the only bridge from what the harness
reports to the unit the operator reads. **It is a placeholder until dogfooding calibrates it**, and
it is the one number in this note that is not evidence.

Drawn as a figure plus a 5px meter filled accent, against the ticket allowance. The allowance is
the existing `limits.ticket_cost` from the workflow grammar, displayed in windows; the grammar does
not change. A ticket allowance stays absolute — a cap expressed as a share of a refilling pool
would mean something different on Monday than on Friday.

**Capacity** is a live shared pool that refills, and it comes from `rate_limit_event` rather than
from anything forge computes. The current five-hour window carries a mono reset countdown derived
from `resetsAt`, shown whenever a window is known. The twenty-tick gauge (one tick per five
percent, compressing to ten ticks in the top bar) is drawn **only when the provider has supplied a
`utilization` figure** — that is, once the warning threshold is crossed. Below it the countdown
stands alone. Inventing the first ninety percent of a gauge's range would be exactly the failure
the design warns about for the countdown, and a quiet page should stay quiet until capacity binds.

The week becomes the headline only when it binds. Until a weekly `rate_limit_event` is observed
there is nothing truthful to draw, so it is not drawn.

**The top bar draws a set of credentials, not one.** With a pool there is no single window, so the
top bar's gauge is, per window — five-hour and weekly — the mean utilization of the credentials
the page is about that have reported one, a limited credential counting as full, beside a
countdown to the soonest reset among them; its title says how many of them it averages. Which
credentials is the page's: a project's pool on a page about that project, the viewer's own
everywhere else (`docs/design/credentials.md` § Showing the windows). The rules above hold for it
unchanged — no figure, no gauge; neutral, never accent.

**The window gauge is neutral, not accent.** The handoff lists it among the accent uses, which
contradicts the rule accent exists to serve: accent means a human is being waited on, and window
capacity is resolved by time rather than by a person. Drawing it in accent would put a loud mark on
the one exhaustion the operator can do nothing about. Usage against a ticket allowance stays accent
— that ceiling does need a human. This is a deliberate departure from the handoff, recorded here so
it reads as a decision rather than a mistake.

## Four exhaustions, three treatments

Only one of them is the operator's.

| Exhausted | Resolved by | Treatment |
|---|---|---|
| Job turn budget | the engine retries | outcome `budget_exhausted` on the job row with `· turns` beside it, nowhere else |
| Ticket allowance | **a human** — raise it or reroute | sticks the ticket, enters the queue, drawn in accent |
| Daily spend cap | **time**, or the operator raising it | `PAUSED · SPEND 6h 12m`, neutral, on the ticket; the board and the project page draw `PAUSED · SPEND` without the countdown. **Never in the queue** |
| Window capacity | **time** | `PAUSED · CAPACITY 1h 12m`, neutral, on the board and the ticket, **never in the queue**. Not built (§ Engine support) |

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
from the handoff's "turns always against budget" (`ui/README.md`), deliberately and for that
reason.

**The cost ceiling overshoots, and that is the mechanism working.** The provider streams no
per-turn cost, so the harness stops after the turn that crosses the line: `$5.07 of $5.00` and
`$9.16 of $8.00` are a cap doing its job, not failing at it. Nothing rounds them down or hides
the overshoot — a figure the operator cannot reconcile against the run is worse than one that
reads a few cents over.

Keeping the pauses out of the queue is load-bearing. A paused ticket in the inbox trains the
operator to open items they cannot act on, which is the exact failure the thesis is written
against. The daily cap is the platform's own rather than the provider's — it is what the operator
sets so a bad night cannot cost a month — but it is resolved the same way, by a clock, so it is
drawn the same way. The countdown is to the next UTC midnight.

## Spend caps

`cost_usd` is what a cap is enforced against, even though it is not what the operator is shown.
Both caps live in `Forge.Spend` and are asked in `Forge.Jobs.assign/2` (its `spend_gate`), which
every billed invocation passes through: a job reaches a machine only by being assigned to one, so
a ticket over its allowance is stuck before a worker is spoken to. It was `start/1` while the
platform ran jobs itself. A conversation has no ticket allowance and meets the daily cap alone. A
ticket over its allowance is stuck, which also drops it out of `Forge.Jobs.pending/2` so the
scheduler stops retrying it every tick.

**The day's total** is the sum of the costs of the runs that *started* in that UTC day — each start
of a job is a run (`docs/design/credentials.md` § Spend) — monotonic, and it matches what the
operator watched happen. A job in flight has recorded nothing — cost lands
at completion — so the figure the gate reads adds the budgeted cost of every live job to what is
already spent. Without that, several concurrent jobs each pass the gate on their own and together
walk straight through the cap.

**Stopping a job already running** is the harness's, because the provider streams no per-turn
cost and the platform therefore has no meter to watch. What the platform does instead is hand the
harness a smaller budget: the effective cost budget of a job is the least of what its state
declared, what the ticket has left and what the day has left, so the existing `--max-budget-usd`
enforcement stops a runaway job at whichever cap binds. The stored spec is not touched — a job's
budget is written once — and the difference is recorded as `job.budget_lowered`, without which a
job stopping at a tenth of its declared budget is inexplicable to anyone reading the log later.

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
`rateLimitType`, and a report about the five-hour window says nothing about the week. So a
credential's windows are the latest event per credential *and* type, and it is limited while any of
them blocks — which is what `docs/design/credentials.md` § How a job picks reads to pass over a
limited credential. Staleness is self-evident rather than hidden: a `resets_at` in the past means
the window has rolled over and utilization is unknown again, which is the same state as having no
figure yet.

**3. Gate the scheduler.** `Forge.Jobs.Scheduler` refuses to start a job while the current window
is blocking, leaving the ticket `active` — not `stuck`, and not in the queue — and surfacing as
`PAUSED` until `resets_at`. **The gate is per credential, through the pick**: a job whose every
credential is limited waits pending with its ticket active, and a job whose own credential is
limited moves to a free one (`docs/design/credentials.md` § How a job picks). A job stopped by a
limit *mid-run* goes back to pending the same way rather than failing (`credentials.md` § A limit
reached mid-run). The `PAUSED` surface on the board and the ticket is not built. The gate keys on
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
  — one mono line in `warning`, with a `⚠` in front: *2 OOM kills · peak 2.0 GiB of 2 GiB*, or
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

- **`window_cost_usd` is uncalibrated.** Every absolute usage figure is wrong by whatever factor it
  is wrong by until dogfooding sets it. It is a display constant only: nothing schedules, caps or
  refuses on it.
- **The weekly window is unobserved.** If the provider emits one, the week is a thin plain bar
  beneath the window gauge and becomes the headline when it is the binding ceiling.
- **The rejecting status is unobserved**, so the scheduler gate's trigger is inferred from naming.
- **A job at a window edge** goes back to pending with its session and resumes — on another
  credential if one is free, on its own after the reset if not (`docs/design/credentials.md`
  § A limit reached mid-run). What is still unsettled is whether Claude Code, stopped by a limit,
  leaves a session that `--resume` continues cleanly; a resume that does not start at all already
  falls back to a fresh run from the branch.
- **Whether dollars survive anywhere.** The recommendation is that they leave every operator
  surface and stay in the API, the Mix tasks and the event log. A number the operator cannot act on
  is noise; capacity is one they can act on. One exception is deliberate: a credential's spend on
  `/users/settings` is in dollars, beside a daily limit typed in dollars, because an API key is
  billed in them and has no window (`ui.md` § Account settings).
- **Machine spend is a third kind of cost and this note has no place for it.** Everything here is
  inference: a refilling window, and usage derived from `cost_usd`. `docs/design/provisioning.md`
  adds an hourly bill for machines, which refills nothing, accrues with no job running, and is
  bounded by a count — `max_workers` per template — rather than by money. It is also the one
  figure an operator can act on immediately, which by this note's own test earns it a surface.
  Two things are unsettled: whether it belongs beside window capacity or stays on the templates
  page, and what to do about currency, since that note's first provider bills euros while every
  figure here is dollars and nothing converts them.
