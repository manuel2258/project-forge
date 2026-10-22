# Claude Code driver and event normalisation

Scope: how milestone 1 runs Claude Code as a job and turns its output into the platform's own
events. Claude Code is the first harness, not an assumption; everything harness-specific stays
in `ForgeWorker.Harness.ClaudeCode`. Sources: the headless, CLI reference, authentication and
sessions pages under code.claude.com/docs, read on 2026-09-11.

## Invocation

One OS process per job, opened as an Erlang Port in line mode, stdout consumed line by line,
stderr captured to `stderr.log` in the worker's own directory beside the job's
(`ForgeWorker.Job.Dir.stderr_path/1`). There are two shapes, and
`ForgeWorker.Harness.ClaudeCode.command/3` picks one by its `:mode` option.

**Prompt**, for a workflow job. The composed prompt is written to `prompt.md` in the job directory
and redirected into stdin, which is therefore at EOF from the start:

```
claude -p \
  --output-format stream-json --verbose \
  --max-turns <spec.budget.turns> \
  --max-budget-usd <spec.budget.cost> \
  --permission-mode bypassPermissions \
  --model <configured>
```

**Streaming**, for a conversation (`conversations.md`). Stdin stays open: the composed prompt,
then every message, is written to it as a stream-json `user` line, and closing it is how the
conversation ends. A reopened conversation with nothing waiting to be answered holds the
composed prompt instead, and writes it with the first message as one line (`conversations.md`
§ Lifetime). A port cannot half-close, so the runner writes through a shell `read` loop that
exits on a sentinel line, which the harness sees as EOF (`ForgeWorker.Job.Runner`).

```
claude -p \
  --output-format stream-json --verbose \
  --input-format stream-json --replay-user-messages \
  --max-budget-usd <assignment.max_cost_usd> \
  --permission-mode bypassPermissions \
  --model <configured>
```

No `--max-turns`: a conversation ends when a person stops talking. `--max-budget-usd` is what was
left of the day when the conversation was assigned, and is absent when the day has no cap
(`conversations.md` § Spend). `--replay-user-messages` is what makes delivery observable
(`conversations.md` § Turns). A conversation is given `--resume <session_id> --fork-session` only
once it has been reopened with a session carried (§ Resume).

In both, `--model` is the model the platform resolved into the spec, else the machine's
`FORGE_CLAUDE_MODEL`, and is absent when neither names one. A workflow job whose assignment
carries a session also gets `--resume <session_id>` (§ Resume), and its `<spec.budget.cost>` is the
budget it was assigned, which the platform may have lowered to whichever cap binds first
(`capacity.md` § Spend caps).

Working directory is the job's worktree, inside `nix develop .#<env>`, with `FORGE_JOB`
pointing at the job directory described in `job-prompt.md`. Permissions are
bypassed because the slice is the sandbox: the job has its own Unix user, worktree, branch and
credential, and nothing outside them. `--permission-prompt-tool` and the `permission_denials`
result field are therefore unused in v1; the driver declares `permission_prompting: false`.

Not used: `--bare` (it skips OAuth credentials, which the credential comparison needs),
`--no-session-persistence` (resume is an optimisation we want to keep available).

## Environment and credentials

The harness process gets a clean environment built from an allowlist of the worker's own
variables (PATH, locale, proxies, Nix settings), a private HOME inside the job directory,
`FORGE_JOB`, `FORGE_MEMORY_MAX` when the slice has a ceiling (`worker-tier.md` § The job slice),
and exactly one of `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`, and the project secrets the
run holds, by their own names (`secrets.md` § Delivery) — none of them a name this list or the
harness reads, which `ForgeCore.Secret` refuses on both ends. Secrets
are written at spawn to a file only root can read, which the unit is handed with `LoadCredential=`
and the process loads itself (`worker-tier.md` § The job slice): never placed on a command line,
never in the unit's environment, which systemd shows every user on the machine, and resolved at
spawn time so they never sit in process state or crash reports. What the harness
prints of a project secret — in an event, the transcript, the session file — is masked by the
worker before it leaves the machine (`secrets.md` § Masking).

The harness runs on a worker, not beside the platform, in a worktree the worker made for the job
and pushes back over the git endpoint with a token scoped to one ref (`worker-tier.md` § Git). On
the worker image (`FORGE_SLICE=systemd`) it runs in a transient systemd unit as a Unix user made
for that job, which owns the worktree and the job directory while it runs and is deleted after
(`ForgeWorker.Slice.Systemd`, `worker-tier.md` § The job slice). Where systemd is not PID 1 — a
development machine, a container — `ForgeWorker.Slice.Direct` runs it as the worker's own user
with no unit and no ceiling. That is not a sandbox, and it is a machine for running your own
agents on. Documented precedence puts
`ANTHROPIC_API_KEY` above the OAuth token, so both are never set. **Which one is the job's
credential's `kind`**, not a project setting — this line said *per-project* from the day it was
written, and nothing ever made it one. A job picks a credential from its project's pool when it starts
(`docs/design/credentials.md` § How a job picks), the credential says whether it is an API key or
a subscription token, and the driver sets that variable and unsets the other. A project gets one
or the other, or both in turn, by what its members assign to it. The credential arrives with the
assignment, sealed, and is opened only when the process is spawned.

## Input messages

Each stdout line is JSON with a top-level `type`. The types the driver knows and what it does:

| `type` | `subtype` | Driver action |
|---|---|---|
| `system` | `init` | Record `session_id`, `model`, `tools`, `claude_code_version`. Emit `harness.started`. |
| `system` | `api_retry` | Emit `harness.retry` with `attempt`, `max_retries`, `error`. |
| `system` | other | Emit `harness.notice` with the subtype and the raw message. |
| `rate_limit_event` | | Emit `harness.rate_limit` with `status`, `resets_at`, `rate_limit_type`, `utilization`, `is_using_overage`, and `windows` when the release sends `unifiedWindows`. Undocumented; see below. |
| `assistant` | | For each content block: `text` -> `harness.text`, `tool_use` -> `harness.tool_use` (`id`, `name`, input). Any other block, `thinking` included, is dropped. |
| `user` | | For each `tool_result` block -> `harness.tool_result` (`tool_use_id`, `is_error`, byte size, first 4 KB). For each `text` block -> `harness.delivered` (`text`): the echo `--replay-user-messages` writes when the harness takes a message, so only a conversation produces one. |
| `control_response` | | Emit `harness.control` with the response's `request_id` and `subtype`: the acknowledgement of an interrupt a conversation asked for. |
| `stream_event` | | Ignored. Not requested (`--include-partial-messages` is off). |
| `result` | `success` | Emit `harness.finished`. |
| `result` | `error_max_turns` | Emit `harness.finished`. Outcome `budget_exhausted`. |
| `result` | anything else | Emit `harness.finished`. Outcome `error`. |
| unknown | | Emit `harness.unknown` with its `type` and the raw message. Never crash. |
| unparseable line | | Emit `harness.malformed` with the raw line. Never crash. |

Messages carrying a non-null `parent_tool_use_id` belong to a harness-internal subagent. In v1
they are recorded with that id and otherwise treated the same; the platform's own subagents
are separate jobs and do not use this mechanism.

An event that stands for a whole message keeps it in `payload.raw`: `started`, `retry`, `notice`,
`control`, `rate_limit`, `finished` and `unknown`, and `malformed` keeps the raw line. The per-block events —
`text`, `tool_use`, `tool_result`, `delivered` — carry their block's fields and not the message;
the whole line is in the run's transcript regardless (below). The documentation does not list
all `result` subtypes nor every field (`duration_api_ms`, `modelUsage` and the shape of
`permission_denials` are undocumented), which is why `finished` keeps the whole message rather
than only the fields named here.

## Emitted events

All are `job.harness.*` in the event log, with `job_id`, `ticket_id`, `actor = {job, id}`:

`started` (session_id, model, tools, version), `text` (text), `tool_use` (id, name, input),
`correction` (round, of, problems — the worker's own, § Correcting the outputs), `starting`
(waited_s, gave_up, stderr, memory — the worker's own, § A harness that never starts), `memory`
(what, ceiling, current, peak, oom_kills, new_kills, pressure — the worker's own, § Memory),
`tool_result` (tool_use_id, is_error, bytes, excerpt), `delivered` (text), `control`
(request_id, subtype), `retry` (attempt, max_retries, error), `notice` (subtype), `rate_limit`
(status, resets_at, rate_limit_type, utilization, is_using_overage, windows), `unknown` (type),
`malformed` (reason), `finished` (subtype, is_error, num_turns, duration_ms, total_cost_usd,
usage, result, session_id).

`text`, `tool_use`, `tool_result` and `delivered` also carry `parent_tool_use_id`. A conversation
forwards `delivered` with the platform's `message_id` added, and does not forward the echo of its
opening prompt (`conversations.md` § The wire). The process's exit status is not on `finished`: it
arrives separately from the output (often before its last chunk, so the runner waits for both),
and is reported with the run's result as `exit_status` in its harness summary.

**The worker's own events are `job.harness.*` too**, and that is where the platform expects them:
`Forge.Jobs.record_harness_event/2` keeps that namespace and nothing else from a worker, because
the rest of the log is the platform's own record. `correction`, `starting` and `memory` are the
worker speaking about the harness it runs, not the harness speaking.

## Memory

The worker reads the job's cgroup while a run is live (`worker-tier.md` § What the slice reads
while a job runs) and says what it saw as `job.harness.memory`. Each event carries `what`, the
ceiling, the current use and the peak so far in bytes, the OOM kills so far, and the pressure
figure when there is one. `ForgeWorker.Job.Memory` decides, from each sample and what came
before it, which to say — pure, so the rules are tested without a cgroup:

- **`oom_kill` — a process in the job was killed for memory.** One event per increase of
  `memory.events`' `oom_kill`, with `new_kills` saying by how many. Each correction round runs
  in a cgroup of its own whose counters start at nought, so the run's count is the rounds'
  summed.
- **`ceiling` — the job reached its ceiling and is being reclaimed or throttled.** The first
  time `max` rises in a run and never again: it counts every time the kernel had to reclaim at
  the ceiling, which is thousands of times a minute for a build that fits only just.
- **`pressure` — the job is thrashing at its ceiling.** `full avg10` at or above the threshold on
  two samples in a row (twenty percent, `worker-tier.md` says why), once per episode: an episode
  ends at the first sample below it, and the next one needs two above again. This is the case a
  ceiling that binds without killing produces, and the case of 2026-09-29's first chat, whose
  harness could not so much as exec.

**A `starting` event carries the sample too**, as `memory`, so a harness that has not said it
started says whether memory is why — and its row in the timeline says it: *not started after
120s · stderr: Running as unit: forge-job-4eb6….service · memory 0.0 GiB of 2 B · full
pressure 100.0%* (`Forge.Events.summary/1`). The stderr there is its last line as it is, and
under `Slice.Systemd` that is usually `systemd-run`'s own `Running as unit:` — kept on purpose,
since before the harness has said anything it is the one line that says the unit exists: the
difference between a harness that is slow and a `systemd-run` that never got an answer. `Slice.Direct` has nothing to read, and there `memory` is
nil and no `memory` event is ever made.

**What a run ends with** is `memory: %{ceiling, peak, oom_kills}` in its harness summary
(`ForgeWorker.Job.Runner`'s `harness_summary/5`), and in a conversation's per-turn summary as
it stood when the turn ended. It comes from the unit's own last reading (`worker-tier.md` § The
job slice) when there is one: a harness killed for memory takes its cgroup with it, and the
sample before may be seconds older than the kill. The same reading is given to
`Memory.observe/2` once more at the end, so an OOM kill no sample saw is still an event before
the result.

**When the harness itself was killed for memory, the reason says so in words** — *the harness
was killed at its 2 GiB memory ceiling* — rather than *harness produced no result message* or an
exit status. That is a run with no result message, not stopped by the platform, whose unit's
last reading has its main process ending on `killed`/`KILL` and an OOM kill counted. The
ceiling is named when the slice had one.

## Rate limit events

`rate_limit_event` is not in the documentation but is emitted in practice, carrying a
`rate_limit_info` object: `status`, `resetsAt` (unix epoch), `rateLimitType`, `isUsingOverage`,
and — only once `surpassedThreshold` is crossed — `utilization`. It is the provider's own report
of the five-hour window. The platform stamps each one with the credential its job ran on, and the
pick reads it to pass over a limited credential (`credentials.md` § Rate limits are per
credential); `capacity.md`'s operator readout is designed to draw from it and is not built.

This section said it was mapped before it was. Until `credentials.md` step 5 it fell through the
catch-all into `harness.unknown`, which is the behaviour the unknown clause exists for and the
reason nothing was lost — the samples in `capacity.md` were read back out of stored transcripts.

The full raw stdout of each run is written to `transcript-<run>.jsonl` beside the job directory,
in the worker's own (`worker-tier.md` § What a machine that never dies accumulates). A
workflow job's is uploaded to the store and recorded as a blob version with its content hash; a
conversation's is uploaded when it ends and recorded nowhere (`conversations.md` § Lifetime). It
is never rendered live; it exists for debugging after the fact.

## Accounting

`total_cost_usd` and `num_turns` from the `result` message are written to the job — **added to
what is already there**, so `jobs.turns` and `jobs.cost_usd` are the job's running totals over
every invocation it has had, and a job the engine resumed after a rate limit has more than one.
This is why the two are not the same quantity as `spec.budget.turns`, which is one invocation's
ceiling, and why nothing draws them as a ratio (`capacity.md` § Four exhaustions, three
treatments). The documentation calls the cost a client-side estimate; it is stored as such and
reconciled against provider billing later if that ever matters. `--max-turns` and
`--max-budget-usd` are the harness-side enforcement; the driver additionally enforces a wall-clock limit
(engine default, not in the workflow grammar) and kills the process with SIGTERM, then SIGKILL
after a grace period. No `finished` event is emitted for that; the run's result records why it
was killed, and § Outcome mapping reads it as `cancelled` or `budget_exhausted`.

## Outcome mapping

Decided in this order, first match wins:

1. Process killed by the platform: `cancelled` (operator) or `budget_exhausted` (wall clock).
   A harness that had already produced its result before the signal is not relabelled.
1. A collected document holds an open blocking question (one whose key was not answered):
   the job becomes `waiting`, and nothing below applies until it resumes and ends again.
2. No `result` message before exit: `error`.
3. `result.subtype == error_max_turns`, a subtype starting `error_max_budget`, or exit
   status 2 with an error result (documented as the cost ceiling): `budget_exhausted`.
4. Any other non-success `result`, or `is_error`: `error`.
5. Success, but a declared artifact in `produces` is missing or has no parseable front
   matter: `error` — once § Correcting the outputs has had its rounds.
6. Front matter `outcome` is `did_not_converge`: `did_not_converge`. An agent may always
   report this, whatever the state declares.
7. Front matter `outcome` is a declared outcome of the state: `converged`, with
   `declared_outcome` set. Anything else: `error` — once § Correcting the outputs has had its
   rounds, which also covers an undeclared file in `out/` (rule 5's neighbour in
   `ForgeCore.Job.Outcome`).

### Naming the failure

The outcome says a job failed; the reason stored beside it is what says why, and it is what the
timeline and the queue have to work with. **The reason comes from the result message's `result`
field — the harness's own last words — in preference to its `subtype`.**

One thing is no longer only in the reason: a `budget_exhausted` job also carries **which ceiling
stopped it** — `:turns`, `:cost` or `:wall_clock` — structurally, on the job row
(`ForgeCore.Job.Outcome.exhausted/1`, `jobs.exhausted`, `capacity.md` § Four exhaustions, three
treatments). `exhausted/1` and § Outcome mapping's rules 1 and 3 read the same facts, so a run
one calls a budget stop is a run the other names a ceiling for; `ForgeCore.Job.OutcomeTest` holds
the two together. Everything else about a failure is still the reason's alone.

`subtype` is not a diagnosis and sometimes not even a fact. A machine with no usable credential
returns `subtype: "success"` with `is_error: true`, exit status 1, one turn and zero tokens, and
`result: "Not logged in · Please run /login"`. Reading the subtype alone produced the reason
*"harness result: success"* on a job that failed without reaching the model — the operator was
told the opposite of what happened, while the sentence naming the cause sat unused in the same
message. So: prefer the text, keep the subtype alongside it when the subtype is informative, and
never print `success` as the reason a job failed.

This also retires a guess recorded earlier in this note. Exit status 2 was described as the cost
ceiling "or an authentication failure before the first turn, which yields no result message and
is caught earlier". It does not: an authentication failure exits **1** and does produce a result
message, so it was never caught earlier. Rule 3 is unchanged — exit 2 with an error result is
still the cost ceiling — but nothing may assume an unauthenticated run is silent.

## Correcting the outputs

A run can end cleanly and still end in `error` because of what it wrote: a document that does not
parse, a declared output it never wrote, a file in `out/` nobody declared, or an outcome the state
does not accept. **Before the worker reports such a run, it resumes the same session and tells it
what is wrong** — up to twice — and reports only what the last round leaves behind.

The case that made it a rule: two refinements failed in production, one on a `question` block
whose unquoted text held `: `, one on `options: [5, 10, 20]`, which YAML types as integers. Each
agent had finished its work and said it was waiting for answers; each document was dropped with
its questions, the job ended in `error`, and the ticket stuck with no transition out. Either
mistake is a sentence away from fixed, and the session that made it is the one that knows what it
meant.

**Where.** In the worker's runner (`ForgeWorker.Job.Runner`), not on the platform. The validator
is `ForgeCore.Document.parse/2`, which the worker already runs when it collects `out/`, and the
session lives in the job's private `HOME` on this machine — a round trip through the platform
would ask a question the worker can answer, and would then need the machine to still be there.
The platform hears one result, as before, and still checks what arrives.

**When** (`ForgeCore.Job.Correction.needed/2`, pure): the run is `finished` with outcome `error`,
nothing killed it, the harness's result is `success` without `is_error`, and the reason is in the
outputs — `missing`, `undeclared`, `invalid`, or an outcome document whose `outcome` is absent or
not the state's. A run the harness stopped for its budget, one that failed to authenticate, one
that is `waiting` or parked, and one that failed for any other reason is reported as it is.

**How.** Another harness process in the same runner, the same slice and the same job directory,
with `out/` exactly as the last round left it: `--resume <session_id>` and, on stdin, the problems
one per line (`Correction.prompt/3`), written to `correction-<n>.md` beside `prompt.md` so both
stay readable. It ends like any run and is collected and decided again. Each round is announced as
`job.harness.correction` with the problems it was sent, so the timeline says it happened.

**What it may spend.** The job's budget, not a new one: a round gets the turns and cost the
earlier rounds left (`Correction.remaining/2`), and none starts on less than one turn or no money.
The wall clock is the runner's and covers every round. A cancel reaches whichever process is
running, because it is the same runner — and one that lands after a round printed its result and
before it exited is still a cancel: a run asked to stop is never corrected, and is reported
killed. The spawn options a round is started from are kept behind a function, because they carry
the git token and the runner's state is what a crash report prints. Two rounds at most (`:max_corrections`); after the last,
the run is reported as it stands.

**What the platform is told.** One result: the last round's documents and outcome, with the
harness summary's `turns`, `cost_usd` and `duration_ms` summed over every round and `corrections`
saying how many ran — the platform adds a result's figures to the job once, so a result carrying
only the last process's would lose the rest. One transcript holds every round, in order.

**What is not corrected.** A conversation: it has no outputs to accept, and a person reads every
turn. A proposal that does not parse: it never fails the job (`ticket-proposals.md` § Malformed
degrades, never drops). And whether the failure reached the operator at all: when every round
fails, `job.finished` carries each invalid document's errors as text (`invalid`), and the reason
names them in one line — the name alone was what the two production failures left.

## A harness that never starts

`system/init` is the harness saying it started. A process given its prompt that has not said so
is reported every two minutes as `job.harness.starting` — how long it has waited and the last
2 KiB of its stderr, which is where `nix develop` writes what it is building — and stopped after
thirty (`ForgeWorker.Job.Runner`, `:start_notice_ms` and `:start_timeout_ms`). The run then ends
like one with no result message, and its reason says it never started, with stderr's last line.
A conversation that ends this way is reported hibernated with that reason, so it can be reopened
on a machine that works.

The case: two new chats on one machine, which had just closed a third after an hour of Android
builds, sat for 38 minutes with the worktree fetched and not one `job.harness.*` event, until the
machine was destroyed by hand. The same chat started within a minute and a half on a fresh one.
Why the first machine stalled is **not known** — the machine is gone, its journal with it, and
nothing that could have said was sent anywhere. The candidates are the ones a used machine has and
a fresh one lacks (a disk near the Nix store's `min-free`, so a garbage collection under the
store's lock; a leftover of the earlier chat), and they are guesses. What is fixed is that the
next one says what it is waiting on while it waits.

**2026-09-29 added a candidate with the same shape**, and it is only that: a machine whose PID 1
had stopped answering, so that every `systemd-run` on it waited on the bus and a chat placed there
never started (`worker-tier.md` § A machine whose systemd stops answering). In that case the second
chat's `starting` events carried `Failed to start transient service unit: Connection timed out`;
the 38-minute case sent no events at all, so nothing says whether it was the same thing. The wedge
itself has since been reproduced on the worker image: a run that meets it now ends after 25
seconds, when `systemd-run` gives up on the bus (`worker-tier.md` § How a machine finds out).

**A harness that exits before it starts ends at once.** It did not: in streaming mode the wrapper
was `<relay> | exec env -i … <harness>`, and when the harness side exited — `systemd-run` giving up
on the bus, say — the shell went on waiting for the relay, which was blocked in `read` on the
port's stdin for a line that was never coming. The port never reported an exit, and the run was
stopped by the thirty-minute limit above instead. Now the harness side, once its process has
exited, signals the port's process group with `USR1`: the relay, which has the default action,
goes; the wrapper shell ignores it and carries on; and the shell exits with the harness's status.
Not `PIPE`, which would have read better: the BEAM ignores it, an ignored signal stays ignored
across `exec`, and a shell may not trap one it started ignoring — which is also why the relay
never died writing into the pipe the harness had left.

**And the relay is ready before it is signalled.** The first version had the wrapper trap `USR1`
and relied on the relay, a forked subshell, dropping that trap: between the fork and the moment
the subshell resets its traps the signal is caught and lost, and a harness that exits that fast
leaves the relay in `read` for the thirty minutes this was meant to end. Review found it; it hung
2 runs in 3,000 under dash and 3 under bash with a harness that exits at once. So the wrapper
ignores `USR1`, the relay restores the default and then writes one empty line, and the harness
side reads that line before it starts the harness — so it cannot signal a relay that is not
listening yet. The line never reaches the harness; the harness side restores the default too, so
the harness runs with `USR1` as it always had. 0 hangs in 3,000 runs under each shell.
Everything the wrapper's comments defend still holds — the prompt goes down the pipe, the close
sentinel still gives a clean EOF, it is POSIX `sh` with no `awk`, and the wrapper is still the
leader of the process group `Exec.signal/2` signals. What goes with the relay is anything else
still in that group, which on the image is nothing — the job's own processes are in its unit —
and on a development machine is what the harness left behind it, which a unit would have ended.

Such a run's reason is stderr's last line, as a stopped one's is: *the harness exited with status
1 before it started; stderr: error: flake 'git+file:///w' does not provide attribute
'devShells.x86_64-linux.default'*. Not a bus error, whose run nobody reports: it is the machine's
failure, and the job goes back to the queue (`worker-tier.md` § How a machine finds out).
`systemd-run`'s own lines are taken out first (`worker-tier.md` § The job slice, *Not `--quiet`*),
so the last line is the one that names something. A run that produced a result message without
starting — a resume the harness refused — keeps the harness's own words.

The watch starts when the prompt is delivered, not when the process is spawned: a reopened
conversation holding its prompt until someone writes (§ Invocation) is silent because it has been
given nothing. Each correction round (§ Correcting the outputs) is timed from its own start. A
harness that said it started and then works for hours is the wall clock's business, not this.

Two more gaps from the same case are closed in `ForgeWorker.Link`. A conversation process that
crashed was never reported — nothing monitored it — so the platform went on believing it ran; the
link now monitors each one and reports a crash as `failed`. And a message for a chat that is not
running on the machine was a line in the journal only; it is a `chat.missing` line in the machine's
log, which reaches the platform's worker log.

## Resume

`system/init` supplies `session_id`, stored as `job.harness_session_id`. When the job is assigned
again — resumed after a blocking question is answered, say — the assignment carries it as
`resume_session` and the driver adds `--resume <session_id>`. The prompt is then a continuation
naming the answers, the branch and the commit the worktree is at, and the pinned manifest — not
the whole prompt a fresh run gets — and the runner chooses it from the same `resume_session` the
flag comes from (`job-prompt.md` § The continuation prompt). Resume is never required for
correctness, and no outcome depends on it: what it saves is context, which is this system's
expensive resource.

**What `--resume` needs is a file, and the file is carried.** Claude Code keeps a session as
`$HOME/.claude/projects/<the working directory, each character not a letter or digit a dash>/<session_id>.jsonl`,
and `HOME` is `$FORGE_JOB/home` — on the machine that ran the job and on no other. So after every
run the worker reads that file the way it reads `out/` (one open, the handle's owner checked, a
size cap; `ForgeWorker.Job.Dir.stage_session/4`) and uploads it under the job's own key, and the
platform records it as `jobs.session_blob`, beside the Claude Code version that wrote it
(`system/init`'s `claude_code_version`). A resume's assignment carries a `get` token for it, and
the worker puts it back before the harness starts — on whatever machine that is. The transcript
that is already uploaded is the harness's stdout and is not this file; it cannot stand in for it
(below).

**It is checked before it is used, because a wrong file does not fail.** The worker restores the
file only when the machine's Claude Code reports the version that wrote it and the file holds
this session's own chained records — every line JSON, and a `user` or `assistant` record naming
the session and carrying `parentUuid`. Anything else is a cold start: the worker drops the
session, runs the full composed prompt, and logs `session.unrestored`. A file that fails to
download, or that no run uploaded, leaves the resume to whatever the machine holds, which is the
case this section used to be about: found on the machine that ran it, and not on any other.

**Measured, 2026-09-29, Claude Code 2.1.284** (`docs/measurements.md` § Session resume):

| Case | What happened |
|---|---|
| The session's own `HOME` and working directory | Resumed; remembered. |
| An empty `HOME` — another machine, nothing carried | Exit 1, one `result` of subtype `error_during_execution`, no `system/init`, no cost; stderr `No conversation found with session ID`. |
| An empty `HOME` with the session file restored | Resumed; remembered. |
| The same, run from another working directory | Resumed; remembered, and the turn was appended to the restored file. |
| An empty `HOME` with the stdout transcript placed as the session file | **Started — `system/init` and all — and remembered nothing**, with only a stderr warning that no record carried `parentUuid`. |

The second row settles what this section used to call unmeasured: a session that is not there
ends before `system/init`, which is what `Forge.Jobs.resume_refused?/2` reads, and the re-queue
with no session is sound. The fourth retires a caveat this section carried from the CLI's
documentation — that session lookup is per project directory — for this version at least. The
last is why the file is checked: a restored file that is not the session's own is not refused, it
is silently a fresh session handed a continuation prompt it has no memory to continue.

**A new attempt that came back resumes its predecessor as a fork.** When a transition sends the
ticket back into a state it has run before — `reviewing` returning work to `implementing`, a
tester sending a build back, a state's own `budget_exhausted` self-loop sending it back to itself
— and that state's previous attempt ended either with an outcome its agent declared (`converged`)
or by running out of budget (`budget_exhausted`), the new job records the previous one as
`jobs.resume_from_id`. Its first run restores the previous attempt's session and adds
`--fork-session`, so it begins with its predecessor's conversation under a session id of its own,
and the old one's file is untouched. Its continuation says it is a new attempt that came back, and
why; `out/` is empty and every output is written again. A person's *Run again* never forks — it is
a request to redo, and it is what a person reaches for after a failure — and neither does an
attempt after one that ended `error`, `did_not_converge` or `cancelled`, which is started fresh so
as not to carry on from whatever went wrong. No state forks another's session: a reviewer does
not share the implementer's memory. Nor does an attempt fork one that was given other
instructions — another prompt, after a re-pin moved it, or another preamble, after the platform's
changed: the fork would remember the old ones and be told they were its own.

**A budget stop is the one failure worth carrying on from**, and it is here because of what it is
not: the three that start fresh each say something about the *work* — the agent could not reach an
outcome, the run broke, a person stopped it — and a fork of one carries whatever went wrong into
the attempt meant to escape it. A budget stop says nothing about the work at all. The
instructions never changed and the agent never concluded anything; it simply ran out of room to
act on them, which is exactly the rule the fork depends on — that it is told its session's
instructions are its own. Carrying the context is also the whole point: a cold second attempt
re-reads the code and re-derives the findings the first one already paid for, which is the
expense that pays for a state's budget twice. The risk this leaves open is the one the other
three are kept out for: an attempt that spends its budget the same way twice makes no progress
but costs a second budget. The `max: 1` on every `budget_exhausted` self-loop in
`.forge/workflows/` is what bounds that, not this rule.

**So the continuation says so.** A self-loop sends the state from itself to itself, which is not
the ticket going on and coming back, and the fork's opening paragraph said it was. An attempt
whose way in was its own state on `budget_exhausted` is told instead that the last attempt ran out
before it reached an outcome, that the budget below is a fresh one a workflow allows only so many
of, and to reach a declared outcome inside it rather than read again what it remembers reading.
The same outcome out of *another* state is an ordinary way back and reads as one. The outputs
paragraph is unchanged either way: a run that wrote a document before the harness stopped it had
that document kept as a version like any other, and this attempt's `out/` is still empty.

A forked resume that is refused is the same re-queue as any other: `resume_refused?/2` asks whether
the run was a resume, and the re-queue clears the fork with the session, so it is tried once.

**What it costs** is the previous context read again on the first turn, uncached — by then the
prompt cache has long expired — so a lap starts at the size of the last one's context, bounded by
Claude Code's own compaction. Whether that is cheaper than a cold start reading the code again is
open, and answerable from the costs the platform already records per job.

**A conversation resumes too**, once it has been reopened (`conversations.md` § Lifetime). Nothing
re-queues it, so a resume the harness refuses is handled where it ends: the platform forgets the
session (`Forge.Conversations.ended/4`), and the next reopen starts cold, with the replay.

## Declared capabilities

The driver module exports `capabilities/0` returning
`%{resume: true, permission_prompting: false, budget_turns: true, budget_usd: true,
streaming_input: true}`, so a second harness is a module with a different map. **Only one key is
read.** The worker's runner refuses a streaming run on a driver without `streaming_input` rather
than starting one that ignores every message. The map is also forwarded to the platform in the
harness offer on `ready` and stored with the worker's `harness`, where nothing reads it; the other
four keys are declarations nothing checks yet.
