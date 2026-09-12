# Claude Code driver and event normalisation

Scope: how milestone 1 runs Claude Code as a job and turns its output into the platform's own
events. Claude Code is the first harness, not an assumption; everything harness-specific stays
in `ForgeWorker.Harness.ClaudeCode`. Sources: the headless, CLI reference, authentication and
sessions pages under code.claude.com/docs, read on 2026-09-11.

## Invocation

One OS process per job, opened as an Erlang Port in line mode, prompt written to stdin, stdin
closed, stdout consumed line by line, stderr captured to the job log.

```
claude -p \
  --output-format stream-json --verbose \
  --max-turns <spec.budget.turns> \
  --max-budget-usd <spec.budget.cost> \
  --permission-mode bypassPermissions \
  --model <configured>
```

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

In milestone 1 the harness still runs as the same Unix user as the platform, in a linked
worktree of the bare repository. That is not a sandbox: an agent could reach the repository
or the data directory through the filesystem. The worker tier with a Unix user per job and
its own machine is what closes this; until then the operator runs their own agents on their
own machine. Documented precedence puts
`ANTHROPIC_API_KEY` above the OAuth token, so both are never set. Which one is a per-project
setting; the credential comparison in milestone 1 runs the same tickets under each. In v1 the
value is the operator's; short-lived scoped credentials per job come with the worker tier.

## Input messages

Each stdout line is JSON with a top-level `type`. Documented types and what the driver does:

| `type` | `subtype` | Driver action |
|---|---|---|
| `system` | `init` | Record `session_id`, `model`, `tools`. Emit `harness.started`. |
| `system` | `api_retry` | Emit `harness.retry` with `attempt`, `max_retries`, `error`. |
| `system` | other | Emit `harness.notice` with the raw message. |
| `rate_limit_event` | | Emit `harness.rate_limit` with `status`, `resets_at`, `rate_limit_type`, `utilization`, `is_using_overage`. Undocumented; see below. |
| `assistant` | | For each content block: `text` -> `harness.text`, `tool_use` -> `harness.tool_use` (`id`, `name`, input), `thinking` -> counted, not stored. |
| `user` | | For each `tool_result` block -> `harness.tool_result` (`tool_use_id`, `is_error`, byte size, first 4 KB). |
| `stream_event` | | Ignored. Not requested (`--include-partial-messages` is off). |
| `result` | `success` | Emit `harness.finished`. |
| `result` | `error_max_turns` | Emit `harness.finished`. Outcome `budget_exhausted`. |
| `result` | anything else | Emit `harness.finished`. Outcome `error`. |
| unknown | | Emit `harness.unknown` with the raw line. Never crash. |
| unparseable line | | Emit `harness.malformed` with the raw line. Never crash. |

Messages carrying a non-null `parent_tool_use_id` belong to a harness-internal subagent. In v1
they are recorded with that id and otherwise treated the same; the platform's own subagents
are separate jobs and do not use this mechanism.

Every emitted event keeps the raw message in `payload.raw`. The documentation does not list
all `result` subtypes nor every field (`duration_api_ms`, `modelUsage` and the shape of
`permission_denials` are undocumented), so nothing is dropped on the assumption it is
unimportant.

## Emitted events

All are `job.harness.*` in the event log, with `job_id`, `ticket_id`, `actor = {job, id}`:

`started` (session_id, model, tools), `text` (text), `tool_use` (id, name, input),
`tool_result` (tool_use_id, is_error, bytes, excerpt), `retry` (attempt, max_retries, error),
`rate_limit` (status, resets_at, rate_limit_type, utilization, is_using_overage),
`notice`, `unknown`, `malformed`, `finished` (subtype, is_error, num_turns, duration_ms,
total_cost_usd, usage, result, exit_status).

## Rate limit events

`rate_limit_event` is not in the documentation but is emitted in practice, carrying a
`rate_limit_info` object: `status`, `resetsAt` (unix epoch), `rateLimitType`, `isUsingOverage`,
and — only once `surpassedThreshold` is crossed — `utilization`. It is the provider's own report
of the five-hour window, and it is what `capacity.md` draws the operator's capacity readout from.
Before it was mapped it fell through the catch-all into `harness.unknown`, which is the behaviour
the unknown clause exists for and the reason nothing was lost.

The full raw stdout of each run is written to `transcript-<run>.jsonl` in the job directory
and recorded as a blob version with its content hash. It is never rendered live; it exists
for debugging after the fact.

## Accounting

`total_cost_usd` and `num_turns` from the `result` message are written to the job. The
documentation calls the cost a client-side estimate; it is stored as such and reconciled
against provider billing later if that ever matters. `--max-turns` and `--max-budget-usd`
are the harness-side enforcement; the driver additionally enforces a wall-clock limit
(engine default, not in the workflow grammar) and kills the process with SIGTERM, then SIGKILL
after a grace period, emitting `finished` with outcome `cancelled` or `budget_exhausted`.

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
   matter: `error`.
6. Front matter `outcome` is `did_not_converge`: `did_not_converge`. An agent may always
   report this, whatever the state declares.
7. Front matter `outcome` is a declared outcome of the state: `converged`, with
   `declared_outcome` set. Anything else: `error`.

## Resume

`system/init` supplies `session_id`, stored as `job.harness_session_id`. After hibernation,
the driver first tries `claude -p --resume <session_id>` with a continuation prompt naming the
pinned manifest and the branch state. Documented caveat: session lookup is per project
directory, so the worktree path must be the same one the session started in; on a different
worker it will not be found. A resume that exits without ever emitting `system/init` is
re-queued as a fresh invocation with the same spec and no session. Resume is never required
for correctness, and no outcome depends on it.

## Declared capabilities

The driver module exports `capabilities/0` returning
`%{resume: true, permission_prompting: false, budget_turns: true, budget_usd: true}`. The
engine reads these rather than assuming them, so a second harness is a module with a
different map.
