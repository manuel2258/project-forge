# The worker channel

Scope: the wire between the platform and a worker. One Phoenix Channel, dialled out by the
worker, authenticated by a token the provider driver injected at creation. Settled in
`docs/decisions.md`; this note fixes the messages, the delivery rules and what happens when the
connection or the machine goes away.

The worker dials out for one reason: the platform is then the only process that listens. A worker
has no inbound port, no certificate, no DNS name and no stable address, and it is destroyed
several times a day. Every one of those is a problem the direction of the connection deletes.

## Authentication

`ForgeWeb.WorkerSocket` at `/worker/websocket`. The worker identifies itself in the connect
param `worker_id` and authenticates with an `x-forge-worker-token` **header**.

The `x-` prefix is not decoration: Phoenix's socket transport forwards only `x-` prefixed headers
to `connect/3`, which is what `:x_headers` in the endpoint's `connect_info` means. Its
`:auth_token` alternative rides the `sec-websocket-protocol` subprotocol and exists for browsers,
which cannot set headers at all. The store is an ordinary HTTP request rather than a handshake
and so uses `Authorization: Bearer`.

**The token is a header and not a query parameter, and that is the whole point.** A URL is
recorded by every proxy, access log, tracing span and metrics label between the worker and the
platform; a request header is not. The worker token is long lived and grants the channel for the
life of the machine, so a copy of it in a reverse proxy's access log is a machine identity anyone
with read access to that log can replay. `docs/deploy.md` puts a TLS proxy in front of the
platform, which is exactly when this stops being theoretical.

`worker_id` stays in the query string: it is an identifier, not a secret, and having it there
keeps the connection legible in a log when something is wrong.

`connect/3` looks up the row, compares `:crypto.hash(:sha256, token)` against `workers.token_hash`
in constant time, and refuses unless the worker's status is `creating`, `ready`, `busy` or `idle`.
A `destroyed` worker is refused even with a valid token: destruction is the platform's record that
this machine is gone, and a machine that disagrees does not get to argue.

There is no query-parameter fallback. Accepting both would keep the leak alive for as long as any
machine had not been updated, and a worker is updated in seconds (`bin/worker-update`); a worker
still sending the old shape is refused and says so in its log.

The token is minted once, when the worker row is created, and handed to the provider driver for
the config disk. The platform keeps only the hash — the same shape `Forge.Accounts.UserToken` uses, for
the same reason.

**The token authenticates the machine, not any job.** Everything a worker is allowed to touch
beyond the channel — a store key, a git ref — is a separate, short-lived, scoped token minted per
assignment. So the blast radius of a leaked worker token is: it can pretend to be that worker
until the worker is destroyed. It cannot read another worker's jobs, another ticket's blobs, or
push to another branch.

## Topic

`worker:<worker_id>`, one channel per worker, and `join/3` refuses a topic whose id is not the
socket's own. Not a topic per job: the worker is the unit that connects, disconnects and dies,
and a job is a thing that happens on it. Per-job topics would multiply exactly the reconnection
bookkeeping below by the number of running jobs.

The join payload is the worker's self-report:

```json
{"memory_total": 16106127360, "root": "/var/lib/forge",
 "seeds": ["seed/sample-rust/sha256-…"], "running": [{"job_id": "…", "attempt": 1}]}
```

`seeds` is a list because a worker is not pinned to a project — `docs/design/worker-tier.md` §
Volumes and the seed says why — so it may hold one seed per project it has run a job for.

`running` is what makes a reconnect survivable; see § Reconnection.

## Messages

Platform → worker:

| Message | Payload | Meaning |
|---|---|---|
| `assign` | spec JSON, slice limits, git endpoint + per-job token + branch, transcript key + token, seed key + token, `resume_session`, wall clock | Run this job. |
| `cancel` | `job_id`, reason | Stop it. The worker still sends a terminal message. |
| `drain` | — | Take no new work; reply when the last job ends. Precedes idle destroy. |

Worker → platform:

| Message | Payload | Acked |
|---|---|---|
| `ready` | `memory_budget`, `seeds`, `harness`, timings | no |
| `heartbeat` | running job ids | no |
| `event` | `job_id`, normalised harness event | no |
| `result` | `job_id`, `attempt`, `ForgeCore.Job.Result` as JSON | yes |
| `hibernated` | `job_id`, `attempt`, commit sha, reason | yes |
| `failed` | `job_id`, `attempt`, reason | yes |

**`ready` is not `join`.** A worker joins when its release boots; it is `ready` when it has
worked out what it can offer — the memory budget it is scheduled against, and the seeds it
already holds. On a provider the two are minutes apart, because the machine answers long before
the release does. The platform will not assign a job to a worker that has joined but is not ready.

The Nix store and the seed are *not* between these two messages, though an earlier draft of
`docs/design/worker-tier.md` put them there. They cannot be: neither is knowable before the
worker has been told which project it is working on, and that is what an assignment is.

## What a worker offers

`ready` carries a `harness` map beside the memory budget, and it is answered the same way: by
asking the machine, not by the platform assuming.

```json
"harness": {
  "driver": "claude_code",
  "name": "Claude Code",
  "version": "2.1.220",
  "capabilities": {"resume": true, "streaming_input": true, "...": true},
  "login": "ok",
  "models": [{"id": "claude-opus-5", "name": "Claude Opus 5"}, "..."],
  "aliases": ["opus", "sonnet", "haiku", "fable"]
}
```

`capabilities` is `ForgeWorker.Harness.capabilities/0`, which the worker has always computed and
has never told anyone. Everything else is new.

**The models are discovered, not declared.** The driver asks
`GET https://api.anthropic.com/v1/models` with the machine's own credential and reports what
comes back. The models a credential may use is not something the platform can know: it holds no
credential, and on a fleet with more than one it would be answering for the wrong account.

That the harness's own CLI cannot answer this was checked rather than assumed. Claude Code 2.1.220
has no models subcommand; `--model` documents four aliases in its help text and otherwise accepts
any string, and a name it rejects is rejected only once a turn is under way. So the alternative to
the API call is a probe session per candidate name — a billed turn each, to learn something one
free unbilled request already answers.

The list is the *account's*, and it is the only thing about the model that varies. A model is a
remote service: nothing about the machine — its memory, its store, its devShell — constrains
which one it may call. That is why this is one blob reported once at `ready` rather than a
capability the scheduler matches against.

**Two probes, both free, and together they are the login check.** `claude --version` says the
binary is there and which one; the models request says the credential is accepted. A worker minted
without a credential currently joins, reports ready, and then fails every job with *Not logged in*
(`Forge.Workers.harness_env/0` names this failure). `login` makes it visible before the first job
instead of after it. Neither probe starts a session and neither spends a token.

The probe runs at join, not at boot, so a rejoin re-reads it — a credential rotated under a
running worker, or a `bin/worker-update` that replaced the harness binary, is picked up on the
next connection rather than on the next machine.

**A probe that fails never prevents `ready`.** The worker reports what it learned and reports the
failure as `login`; refusing to go ready would turn a transient network error into a machine that
takes no work at all, which is strictly worse than a machine whose model list is momentarily
unknown.

**More than one worker.** The platform keeps each worker's answer on its own row and offers the
**union** of the live ones. Workers built by the same provider driver share an image and a
credential and so answer identically; a union that is not a single set means either an image
rollout is half done or the fleet holds more than one account. Union rather than intersection
because the list is an offer, not a gate — see `docs/design/workflow-grammar-v1.md` § Model for
why naming a model the platform has never heard of stays legal.

## Delivery

Three classes, and they are deliberately not treated alike.

**Events are best-effort.** They are pushed in order on one connection, which Phoenix preserves,
and nothing recovers one lost to a dropped socket. This is allowed because of what an event is
for: `docs/decisions.md` says artifacts are the contract and the conversation is an optimisation.
A lost event costs a line in the timeline. It never costs a decision, because no decision is taken
from the event stream — the result carries everything the engine reads. A lost event is not
detectable: the worker pushes `job_id` and the event and nothing else (`link.ex:139`), so there is
no per-event sequence and the platform cannot tell a gap from a quiet job. The `seq` on an `events`
row is the platform's own insertion order, assigned on arrival, and orders what arrived rather than
what was sent.

**Terminal messages are acked and retried.** `result`, `hibernated` and `failed` are pushed with a
reply expected; the platform replies only after the transaction that records them commits. Until
the ack arrives the worker keeps the message and re-sends it after any reconnect. The platform
therefore must treat them as idempotent, keyed by `(job_id, attempt)`: a second `result` for a job
already `finished` is acked and dropped, not recorded twice.

That ordering — commit, then ack — is the one that fails safely. Acking first and crashing loses
the job's outcome while the worker believes it is delivered. Committing first and crashing costs a
duplicate delivery, which the idempotency key absorbs.

**`assign` is not acked, and the row is marked before it goes out.** The opposite was written
here first — ack, then mark — and it is wrong for the same reason milestone 1 already
discovered in `Forge.Jobs.start/1`: a row the progress changeset refuses must be refused
*before* anything is running, or the refusal arrives after a billed invocation has already
started and the scheduler retries the job every tick. So the platform marks the job `running`
with its worker, sends the assignment, and puts the row back to `pending` if the send fails.

What that costs is the case the ack was meant to cover: an assignment lost in flight leaves a
job marked `running` on a worker that never heard of it. The rejoin reconciliation below is
exactly the repair for that, and it is needed anyway — a machine that reboots loses its jobs
the same way — so the ack would have bought a second mechanism for a case the first already
handles.

## Reconnection

Slipstream reconnects with backoff and rejoins. The join payload's `running` list is then compared
against the platform's rows for this worker:

- **Platform says running, worker does not have it.** The run is gone — the machine rebooted, the
  release restarted, the slice was killed. The job goes back to `pending` and is scheduled afresh.
  This is the rule `Forge.Jobs.recover/0` already applies at platform boot, and PR #11's
  cold-recovery fix is what makes it safe: a re-queued job clears `out/` rather than inheriting a
  dead run's outputs.
- **Worker has it, platform has already recorded a terminal state.** The platform sends `cancel`.
  A duplicate terminal message then arrives and is dropped by the idempotency rule above.
- **Both agree.** Nothing happens, and the worker re-sends anything unacked.

## When the machine goes away

`last_seen_at` is written by every `heartbeat` and every message. Past `worker_timeout_ms` the
platform stops waiting: it re-queues that worker's running jobs, asks the provider driver to
destroy the machine, and marks the row `destroyed`. Destroying a machine that is merely
partitioned is the right trade here — the jobs are re-runnable by construction, and a worker that
is unreachable is not doing anything the platform can observe or bill.

**This runs on every scheduling pass, before anything asks for capacity**, and that ordering is
not housekeeping. `max_workers` counts every row that is not `destroyed`, so a machine the
platform has lost track of holds a slot for ever; at the PoC's `max_workers` of 1 it holds all of
them, and the queue never moves again. A killed VM, a platform restarted while a machine was
booting, a `create` that half-succeeded — each leaves exactly that row, and each was a deadlock
until this existed.

A worker that has never reported has no `last_seen_at`, so it is timed from when its row was
made: a machine that never finishes booting has to expire too, or a failed `create` is
indistinguishable from a slow one for ever. A worker that is connected is never swept, however
quiet: the registry is the evidence, and the timeout is only for workers that are not in it.

## Why Slipstream

It is a maintained Phoenix Channel client with reconnection, rejoin and a GenServer-shaped
callback API. The alternative is a raw WebSocket client plus a hand-written implementation of the
Phoenix channel protocol, which is what Slipstream is. `docs/poc-plan.md` named it; nothing here
disagrees.

It is the worker's dependency, not the platform's. The platform gets a `Phoenix.Socket`, which it
already has the framework for.

## Testing

- Platform side: `Phoenix.ChannelTest` against the real socket and channel, with a token minted the
  way the driver mints it. Rejection cases — wrong token, destroyed worker, someone else's topic —
  are tests, not comments.
- The end-to-end flow test (`platform/test/forge/flow_test.exs` today) becomes a scripted fake
  worker that speaks this protocol: joins, reports ready, accepts an assignment, streams a couple
  of events, returns a result. That is what replaces running a real `ForgeWorker.Job.Runner` inside
  the platform's BEAM once the path dependency is gone.
- Worker side: the `Link` process is tested against a stub socket rather than a live platform, so
  `forge_worker`'s tests stay free of Phoenix.

## Open

- **No flow control on events.** A pathologically chatty harness could outrun the platform's event
  writer. The bound today is the harness's own output, which milestone 1 observed and did not find
  alarming; if it becomes one, the fix is batching events per job, not dropping them.
- **One channel carries both control and data.** A large `result` blocks events behind it on the
  same socket. Transcripts already go to the store rather than over the channel, which is what
  keeps results small; if they stop being small, they follow the transcript.
- **`drain` has no deadline.** A job that will not finish keeps a worker alive past its idle
  period. The wall clock in the runner is the backstop, and it is a long one.
- **The model is not a scheduling requirement.** A job naming a model goes to whichever worker
  the memory gate offers, and nothing checks that *that* worker reported it. Harmless while the
  fleet is homogeneous — workers from one provider driver share an image and a credential, so
  they answer § What a worker offers identically — and the cost of being wrong is one wasted
  assignment: the harness refuses the name and the job fails with the harness's own message,
  which is visible rather than silent.

  It stops being harmless when workers genuinely diverge, which is a half-finished image rollout
  or a fleet holding more than one account. The fix is to make the model a requirement beside the
  slice: `Workers.assignable/1` takes the wanted model as well as the bytes and skips a worker
  whose `harness["models"]` does not list it. The data is already on the row — this is a `where`
  clause, not a new mechanism.

  Two traps for whoever builds it. A worker that reported **no** harness at all must stay
  assignable: a release older than the probe, or one whose probe could not reach anything, is
  still a worker, and filtering it out would idle the fleet on a network blip. And the aliases
  are not in `models` — `opus` is a name the CLI resolves, not an id the API returns — so a
  requirement matched against ids alone would refuse every workflow that names one. The only
  workflow in this repository that names a model names `opus`.
