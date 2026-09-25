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

Pretending to be a worker includes being handed its jobs, and since `docs/design/credentials.md`
a job carries its inference credential — sealed with a key derived from this token, so whoever
holds the token opens it. That is not a wider radius than before: the token used to sit in the
machine's user data beside the machine's own inference credential, and whoever could read one
could read both. What is new is that it is the *pool's* credential, for as long as the platform
keeps assigning to that worker.

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
| `assign` | `job_id`, `kind`, spec JSON, slice limits (`memory_max`, `cpu_weight`), git endpoint + per-job token + branch + base, transcript key + token, seed key + token, the backlog, `resume_session`, wall clock, the job's inference credential sealed for this worker (`credentials.md` § Delivery to the machine); a chat adds `idle_ms`, `max_cost_usd` and `history` and a longer wall clock, and its spec a `replay` once it has been reopened | Run this job. |
| `cancel` | `job_id`, reason | Stop it. The worker still sends a terminal message. |
| `message` | `job_id`, `message_id`, text | A chat only: write this to the harness's stdin. |
| `interrupt` | `job_id` | A chat only: end this turn, keep the process. |
| `close` | `job_id`, reason | A chat only: end the conversation, release the machine. |

**There is no `drain`.** This table carried one — *take no new work* — meant to precede idle
destroy, and nothing ever sent it: `Workers.sweep_idle/0` takes only a worker that is already
`idle`, with no job to wait for, and destroys it directly. The worker honoured it and the
channel could push it, so both ends knew a message neither used, and it was removed from both
rather than kept for a use that might come. It was wrong where it was honoured, too: a draining
worker refused an assignment with a log line and no reply, and the platform — which marks a job
`running` before the assignment goes out (§ Delivery) — was left holding a job nothing was
running until the next rejoin. The first thing that would want a worker to stop taking work is
the pulled `update` `docs/design/worker-tier.md` § Updating a worker sketches, and that can say
so itself.

Worker → platform:

| Message | Payload | Acked |
|---|---|---|
| `ready` | `memory_budget`, `seeds`, `root`, `harness`, and `cores` and `accepts` when known | no |
| `heartbeat` | running job ids | no |
| `event` | `job_id`, normalised harness event | no |
| `turn` | `job_id`, turn index, commit, the turn's proposals and documents, and a harness summary carrying its cost | yes |
| `result` | `job_id`, `ForgeCore.Job.Result` as JSON | yes |
| `hibernated` | `job_id`, commit sha, reason, the result as far as it got; a chat adds its turn count | yes |
| `failed` | `job_id`, reason | yes |

The conversation rows are `docs/design/conversations.md`'s — § The wire for the four messages, §
Context for `history`, § Lifetime for `idle_ms` and the `replay`, and § Spend for `max_cost_usd` —
and the backlog is `docs/design/ticket-proposals.md` § Reading the backlog.
`Forge.Jobs.assignment/4` builds what `assign` carries, and `Forge.Jobs.assign/2` adds the sealed
credential to it.

**`ready` is not `join`.** A worker joins when its release boots; it is `ready` when it has
worked out what it can offer — its memory budget, cores and kinds (§ What a worker offers), and
the seeds it already holds. On a provider the two are minutes apart, because the machine answers
long before the release does. The platform will not assign a job to a worker that has joined for
the first time but is not ready. A worker that *re*joins keeps the status it had — nothing resets
it on disconnect — so for the moment between its join and its `ready` it is assignable on its
old figures, which the `ready` then confirms or corrects.

The Nix store and the seed are *not* between these two messages, though an earlier draft of
`docs/design/worker-tier.md` put them there. They cannot be: neither is knowable before the
worker has been told which project it is working on, and that is what an assignment is.

## What a worker offers

`ready` carries a `harness` map beside the memory budget, and it is answered the same way: by
asking the machine, not by the platform assuming.

**It also carries the other two dimensions of the gate**, `cores` and `accepts`
(`docs/design/provisioning.md` § What a worker offers):

```json
"memory_budget": 5939000000,
"cores": 4,
"accepts": ["command"]
```

Three things about them that the code depends on and a reader would not guess.

- **`cores` and `accepts` are omitted, never null.** A machine with nothing to say leaves the key
  out, and the platform reads an absent key as *unknown* rather than as zero or as an empty
  list — which is what keeps every worker that predates these fields taking work. `memory_budget`
  is always sent, because there not knowing is itself an instruction: a machine that cannot
  measure its own memory offers nothing and is assigned nothing.
- **The names in `accepts` are not checked by the worker.** It passes through whatever it was
  configured with, and the platform drops the kinds it does not recognise. A worker validating
  against its own list would refuse a kind the platform gained in a migration the machine has not
  been rebuilt for — and the machine is the half that is replaced least often.
- **What arrives fills a blank row and never overwrites a set one.** These are scheduling values
  and the row is what the gate reads, so an operator's correction to a permanent worker survives
  every reconnect. The report is kept verbatim in `workers.reported` so the two can be compared,
  which is the same treatment `harness` gets and for the same reason.

```json
"harness": {
  "driver": "claude_code",
  "name": "Claude Code",
  "version": "2.1.220",
  "capabilities": {"resume": true, "streaming_input": true, "...": true},
  "credential": "per_job",
  "aliases": ["opus", "sonnet", "haiku", "fable"]
}
```

`capabilities` is `ForgeWorker.Harness.capabilities/0`, which the worker has always computed and
told nobody until the probe existed.

**It describes a harness, not an account.** Until `docs/design/credentials.md` it carried `login`
and `models` as well: the driver asked `GET https://api.anthropic.com/v1/models` with the machine's
own token and reported what came back, because the models a credential may use were the account's
and the platform held no account. The machine holds none now — a job brings its credential in the
assignment — so both questions moved to where the accounts are. The platform asks the provider
once per credential, when the credential is saved (`credentials.md` § Checked on save), and a
picker offers the models of the credentials in a project's pool.

That the harness's own CLI cannot answer the model question was checked rather than assumed, and
it is why the answer comes from the API at all. Claude Code 2.1.220 has no models subcommand;
`--model` documents four aliases in its help text and otherwise accepts any string, and a name it
rejects is rejected only once a turn is under way. So the alternative to the API call is a probe
session per candidate name — a billed turn each, to learn something one free unbilled request
already answers.

**What is left is free and cannot fail on the network.** `claude --version` says the binary is
there and which one, and the aliases are declared by the driver rather than discovered. A binary
that is missing reports a `null` version and still reports the rest; the probe always answers.

**`"credential": "per_job"` is the worker saying it takes its credential from the assignment**,
and the gate reads it (`Forge.Workers.runs?/2`). It is added by the link rather than by the
driver, because it is the link that does it, and it is said even when the probe raises — beside
the driver's name, which the driver declares apart from its probe for exactly that case. A release older than that ignores the assignment's credential and runs the
job on whatever its own environment holds, which the platform would then record against a
credential it did not spend — so a worker that does not say it is given no inference job, and
`credentials.md` § What a worker offers now says why that inverts the trap in § Open below.

The probe runs at join, not at boot, so a rejoin re-reads it — a `bin/worker-update` that replaced
the harness binary is picked up on the next connection rather than on the next machine.

**More than one worker.** The platform keeps each worker's answer on its own row and offers the
**union** of the live ones' aliases. Workers built from one image answer identically; a union that
is not a single set means an image rollout is half done. Union rather than intersection because
the list is an offer, not a gate — see `docs/design/workflow-grammar-v1.md` § Semantics, under
**Model**, for why naming a model the platform has never heard of stays legal.

## Delivery

Three classes, and they are deliberately not treated alike.

**Events are best-effort.** They are pushed in order on one connection, which Phoenix preserves,
and nothing recovers one lost to a dropped socket. This is allowed because of what an event is
for: `docs/decisions.md` says artifacts are the contract and the conversation is an optimisation.
A lost event costs a line in the timeline. It never costs a decision, because no decision is taken
from the event stream — the result carries everything the engine reads. A lost event is not
detectable: the worker pushes `job_id` and the event and nothing else (`ForgeWorker.Link`'s
`handle_info({:event, …})`), so there is
no per-event sequence and the platform cannot tell a gap from a quiet job. The `seq` on an `events`
row is the platform's own insertion order, assigned on arrival, and orders what arrived rather than
what was sent.

**Terminal messages are acked and retried.** `result`, `hibernated` and `failed` are pushed with a
reply expected, and so is a chat's `turn`, because it carries the cost the daily cap is computed
from; the platform replies only after the transaction that records them commits. Until the ack
arrives the worker keeps the message and re-sends it after any reconnect. The platform therefore
must treat them as idempotent — keyed by the job, since a job row is one attempt and the payloads
carry no attempt, and a `turn` by its place in the conversation (`Conversations.record_turn/2`):
a second `result` for a job already `finished` is acked and dropped, not recorded twice.

That ordering — commit, then ack — is the one that fails safely. Acking first and crashing loses
the job's outcome while the worker believes it is delivered. Committing first and crashing costs a
duplicate delivery, which the idempotency key absorbs.

**`assign` is not acked, and the row is marked before it goes out.** The opposite was written
here first — ack, then mark — and it is wrong for the same reason milestone 1 already
discovered in `Forge.Jobs.start/1`, the in-process entry point `Forge.Jobs.assign/2` replaced: a
row the progress changeset refuses must be refused
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

`last_seen_at` is written at join, at `ready` and by every `heartbeat`. Past `worker_timeout_ms`
the platform stops waiting (`Workers.sweep_unreachable/0`), and what it does next depends on whose
machine it is:

- **A managed worker** has its running jobs re-queued — a workflow job to `pending`, a chat to
  dormant — and its machine destroyed through the driver. The row is marked `destroyed` only once
  the driver says the machine went: a refusal keeps the row, with the driver's words in
  `last_error`, and the next sweep tries again, because the row is the platform's claim that
  nothing is billing (`docs/design/provisioning.md` § Whose account). A row naming a provider
  this node no longer has is retired at once, since no retry could succeed.
- **An unmanaged worker keeps its row.** Its running jobs are re-queued the same way, but the
  machine is the operator's and may well come back, and a `destroyed` row never can
  (`docs/design/worker-tier.md` § Managed and unmanaged).

Destroying a managed machine that is merely partitioned is the right trade — the jobs are
re-runnable by construction, and a worker that is unreachable is not doing anything the platform
can observe or bill.

**This runs on every scheduling pass, before anything asks for capacity**, and that ordering is
not housekeeping. A template's `max_workers` counts every row made from it that is not
`destroyed` (`Provisioning.live_count/1`), so a machine the platform has lost track of holds one
of that template's slots for ever; at the default of 1 it holds all of them, and nothing more is
made from it. A killed VM, a platform restarted while a machine was booting, a `create` that
half-succeeded — each leaves exactly that row, and each was a deadlock until this existed, when
the ceiling was the node's `max_workers` of 1 rather than a template's.

A worker that has never reported has no `last_seen_at`, so it is timed from when its row was
made: a machine that never finishes booting has to expire too, or a failed `create` is
indistinguishable from a slow one for ever. A managed one swept that way also counts as a failure
of its template (`docs/design/provisioning.md` § A template that cannot make a working machine
is taken out of service). A worker that is connected is never swept, however quiet: the registry
is the evidence, and the timeout is only for workers that are not in it.

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
- **The model is not a scheduling requirement.** A job naming a model goes to whichever worker
  the memory gate offers, and nothing checks that the job's *credential* may use it. The cost of
  being wrong is one wasted assignment: the harness refuses the name and the job fails with the
  harness's own message, which is visible rather than silent.

  Since `docs/design/credentials.md` the model list is a credential's and not a machine's, so the
  requirement belongs in the pick rather than in `Workers.assignable/2`: prefer a credential
  whose `models` lists the one the job wants. The data is on the credential row.

  Two traps for whoever builds it. A credential that has never been **checked** has no list and
  must stay pickable, or a platform that cannot reach the provider refuses every job. And the
  aliases are not in `models` — `opus` is a name the CLI resolves, not an id the API returns — so
  a requirement matched against ids alone would refuse every workflow that names one. The only
  workflow in this repository that names a model names `opus`.

  The trap this item used to open with — *a worker that reported no harness must stay
  assignable* — no longer holds, and not because it was wrong: it was about a probe that could
  fail on a network blip, and the probe no longer makes a request. A worker reporting no harness
  is now a release too old to take a job's credential, and it takes no inference job
  (`credentials.md` § What a worker offers now).
