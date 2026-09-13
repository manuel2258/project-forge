# The worker channel

Scope: the wire between the platform and a worker. One Phoenix Channel, dialled out by the
worker, authenticated by a token the provider driver injected at creation. Settled in
`docs/decisions.md`; this note fixes the messages, the delivery rules and what happens when the
connection or the machine goes away.

The worker dials out for one reason: the platform is then the only process that listens. A worker
has no inbound port, no certificate, no DNS name and no stable address, and it is destroyed
several times a day. Every one of those is a problem the direction of the connection deletes.

## Authentication

`ForgeWeb.WorkerSocket` at `/worker/websocket`, connect params `worker_id` and `token`.

`connect/3` looks up the row, compares `:crypto.hash(:sha256, token)` against `workers.token_hash`
in constant time, and refuses unless the worker's status is `creating`, `ready`, `busy` or `idle`.
A `destroyed` worker is refused even with a valid token: destruction is the platform's record that
this machine is gone, and a machine that disagrees does not get to argue.

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
| `ready` | `memory_budget`, `seeds`, timings | no |
| `heartbeat` | running job ids | no |
| `event` | `job_id`, `seq`, normalised harness event | no |
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

## Delivery

Three classes, and they are deliberately not treated alike.

**Events are best-effort.** They are pushed in order on one connection, which Phoenix preserves,
and nothing recovers one lost to a dropped socket. This is allowed because of what an event is
for: `docs/decisions.md` says artifacts are the contract and the conversation is an optimisation.
A lost event costs a line in the timeline. It never costs a decision, because no decision is taken
from the event stream — the result carries everything the engine reads. The worker stamps a per-job
`seq`, so the platform can record that it missed some rather than pretend it did not.

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
