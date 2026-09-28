# Claude Code driver and event normalisation

Scope: how milestone 1 runs Claude Code as a job and turns its output into the platform's own
events. Claude Code is the first harness, not an assumption; everything harness-specific stays
in `ForgeWorker.Harness.ClaudeCode`. Sources: the headless, CLI reference, authentication and
sessions pages under code.claude.com/docs, read on 2026-09-11.

## Invocation

One OS process per job, opened as an Erlang Port in line mode, stdout consumed line by line,
stderr captured to `stderr.log` in the job directory. There are two shapes, and
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
(`conversations.md` § Turns). A conversation is never given `--resume`.

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
`FORGE_JOB`, and exactly one of `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`. Secrets
are forwarded through the environment, never placed on a command line, and are resolved by
the driver at spawn time so they never sit in process state or crash reports.

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
| `system` | `init` | Record `session_id`, `model`, `tools`. Emit `harness.started`. |
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

`started` (session_id, model, tools), `text` (text), `tool_use` (id, name, input),
`correction` (round, of, problems — the worker's own, § Correcting the outputs), `starting`
(waited_s, gave_up, stderr — the worker's own, § A harness that never starts),
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

`total_cost_usd` and `num_turns` from the `result` message are written to the job. The
documentation calls the cost a client-side estimate; it is stored as such and reconciled
against provider billing later if that ever matters. `--max-turns` and `--max-budget-usd`
are the harness-side enforcement; the driver additionally enforces a wall-clock limit
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

The outcome says a job failed; the reason stored beside it is the only thing that says why, and
it is what the timeline and the queue have to work with. **The reason comes from the result
message's `result` field — the harness's own last words — in preference to its `subtype`.**

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
flag comes from (`job-prompt.md` § The continuation prompt). A conversation never resumes this
way; reopening one clears its session (`conversations.md` § Lifetime). Documented caveat: session
lookup is per project directory, so the worktree path must be the same one the session started
in; on a different worker it will not be found. A resume that exits without ever emitting
`system/init` is re-queued as a fresh invocation with the same spec and no session, and so with
the full composed prompt: the fallback is that re-queue, not a guess made before the run. Resume
is never required for correctness, and no outcome depends on it.

That the harness *does* exit before `system/init` when the session is not found — rather than
starting a new session and carrying on — is **unmeasured**. It is inferred from the caveat, not
observed, and the continuation prompt rests on it (`job-prompt.md` § The continuation prompt):
a harness that started afresh would hand a continuation to an agent that remembers nothing of the
job. No measurement resumes anything; that is the first one to add.

## Declared capabilities

The driver module exports `capabilities/0` returning
`%{resume: true, permission_prompting: false, budget_turns: true, budget_usd: true,
streaming_input: true}`, so a second harness is a module with a different map. **Only one key is
read.** The worker's runner refuses a streaming run on a driver without `streaming_input` rather
than starting one that ignores every message. The map is also forwarded to the platform in the
harness offer on `ready` and stored with the worker's `harness`, where nothing reads it; the other
four keys are declarations nothing checks yet.
