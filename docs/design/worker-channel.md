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

**Destroying a row closes its channel, and a join on a destroyed row is refused.** The socket
check runs once, when the connection is made, and a connection outlives the row it was made
for: a machine retired from the workers page, or by `mix forge.worker.retire`, is still holding
the channel it joined with, and a rejoin on that same live socket — which Slipstream does
whenever the platform closes a topic — never passes through `connect/3` again. So:

- `Workers.destroy/2` stops the row's channel wherever it marks the row `destroyed`, handing it
  the jobs still running there to `cancel` first — a retired permanent machine keeps running, and
  a job requeued from it would otherwise run twice;
- `join/3` asks the row again and refuses a destroyed one with `reason: "destroyed"`, and the
  channel reads the row once more after it is registered, closing itself if a retire landed in
  between, when there was no channel for the stop to reach;
- `ready/2`, `busy/1` and `release/1` write a status only after re-reading the row under a lock,
  and never over `destroyed`: each decides from a row read earlier — a message in flight, the
  scheduler's pass — and written from that read, a retired row came back to `idle` or `busy`,
  assignable and with its token valid again.

What the channel cannot reach is a row destroyed from another node — the host's command line runs
in its own VM, with its own registry — and there the other guards are the ones that hold: such a
machine keeps its open channel until it next reconnects, and it is never assigned anything,
because `assignable/2` reads the row's status.

There is no query-parameter fallback. Accepting both would keep the leak alive for as long as any
machine had not been updated, and a worker is updated in seconds (`bin/worker-update`); a worker
still sending the old shape is refused and says so in its log.

The token is minted once, when the worker row is created, and handed to the provider driver for
the config disk. The platform keeps only the hash — the same shape `Forge.Accounts.UserToken` uses, for
the same reason.

**A second join while the machine's channel is open is refused before anything is written**, with
`already_connected`. That is what a copy of a live machine's token makes, and the join now does
things — it records what the machine runs, it can destroy the machine, and a machine's first join
teaches its template (§ Versions) — none of which a second caller may do to a machine that is
there. A join by a token-holder while the real machine is away is not told apart; that is the
radius below, and learning is kept to a machine's first join so that a copy of the token cannot
also take its template out of service.

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
keeps assigning to that worker. The same is true of the project secrets a job names, sealed with
the same key since `docs/design/secrets.md`: a leaked worker token opens those of every job
assigned to it while the platform keeps assigning, which is the radius of a member of every
project the machine serves, not wider.

## Topic

`worker:<worker_id>`, one channel per worker, and `join/3` refuses a topic whose id is not the
socket's own. Not a topic per job: the worker is the unit that connects, disconnects and dies,
and a job is a thing that happens on it. Per-job topics would multiply exactly the reconnection
bookkeeping below by the number of running jobs.

The join payload is the worker's self-report:

```json
{"memory_total": 16106127360, "root": "/var/lib/forge",
 "seeds": ["seed/sample-rust/sha256-…"], "running": [{"job_id": "…", "attempt": 1}],
 "protocol": 1, "release": "0.2.1 (8rh57whmgk6m)", "build": "8rh57whmgk6m"}
```

and, from a machine that believes it is unhealthy, `"unhealthy": "<why>"` — left out, never
null, by one that does not (§ An unhealthy machine).

`seeds` is a list because a worker is not pinned to a project — `docs/design/worker-tier.md` §
Volumes and the seed says why — so it may hold one seed per project it has run a job for.

`running` is what makes a reconnect survivable — a dropped socket and a restart of the platform
alike; see § Reconnection and § A platform restart.

`protocol`, `release` and `build` say what is speaking; see § Versions. They are in the join and
not in `ready` because the platform has to decide before any work whether it will talk to this
machine at all, and `ready` comes minutes later.

## Messages

Platform → worker:

| Message | Payload | Meaning |
|---|---|---|
| `assign` | `job_id`, `kind`, spec JSON, slice limits (`memory_max`, `cpu_weight`), git endpoint + per-job token + branch + base, transcript key + token, a prefix and `put` token for the harness session's uploads, seed key + token, the backlog, `resume_session` (nil when there is nothing to resume), `fork_session`, the session file to restore (`session`: key, `get` token, id, the version that wrote it), wall clock, the job's inference credential sealed for this worker (`credentials.md` § Delivery to the machine); a chat adds `idle_ms`, `max_cost_usd` and `history` and a longer wall clock, and its spec a `replay` once it has been reopened | Run this job. |
| `assign` for a command | `job_id`, `kind: "command"`, its spec (the script's text, argv, commit, env, timeout), slice limits, git endpoint + a read-only per-job token + branch + base, the log's store key + `put` token, seed key + token, wall clock | Run this command (`docs/design/commands.md`). No credential, no backlog, no session. |
| — and for either, when it declares a group of files | `outputs`: a store prefix and a `put` token scoped to it (`docs/design/storage.md` § Serving) | Where the group's files go. |
| — and for any of the three, when the job names project secrets | `secrets`: one JSON object of name to value, sealed for this worker, this job and the purpose `secrets` (`docs/design/secrets.md` § Delivery); its spec's `secrets` names them | Put these in the process's environment, and mask them in what leaves (§ Masking there). |
| `cancel` | `job_id`, reason | Stop it. For `ticket_cancelled` the worker still sends a terminal message — a `hibernated` carrying the run's result, even when its push is refused because the cancel revoked the job's credential — and that is how the platform settles what the run spent. For `not_ours` and `retired` it sends none: the platform has already given that run up — re-queued it, placed it elsewhere or finished with it — and a report would be recorded against whatever the job is now (§ Reconnection). |
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
| `stats` | `cpu`, `memory_used`, `memory_total`, `disk_used`, `disk_total`, each only when readable | no |
| `log` | `at`, `type`, `level`, `message`, and `job_id` on a line about a job | no |
| `event` | `job_id`, normalised harness event | no |
| `turn` | `job_id`, turn index, commit, the turn's proposals and documents, and a harness summary carrying its cost | yes |
| `result` | `job_id`, `ForgeCore.Job.Result` as JSON — `status` `parked` for an agent that invoked commands, with the invocations and the commit it pushed; a command's with its exit status, duration and log key; either's `blobs` (name → key and size) and `invalid_blobs` (name → why) for its groups of files | yes |
| `hibernated` | `job_id`, commit sha, reason, the result as far as it got; a chat adds its turn count | yes |
| `failed` | `job_id`, reason | yes |
| `unhealthy` | reason; the reply says `reboot` (true or false) and `why` | yes |

**A worker refuses an assignment whose ceiling it will not make a unit with**: a `memory_max`
below `ForgeCore.Workflow.Resources.minimum_memory/0`, or one that is not a number, ends at once
as an error — a `result` for a workflow job or a command, `failed` for a chat — whose reason names
the ceiling and the minimum (`docs/design/worker-tier.md` § The job slice). A platform that minted
it is refused too, since the job row's changeset refuses the same, so this is for a platform older
than the worker.

The conversation rows are `docs/design/conversations.md`'s — § The wire for the four messages, §
Context for `history`, § Lifetime for `idle_ms` and the `replay`, and § Spend for `max_cost_usd` —
and the backlog is `docs/design/ticket-proposals.md` § Reading the backlog.
`Forge.Jobs.assignment/4` builds what `assign` carries, and `Forge.Jobs.assign/2` adds the sealed
credential and secrets to it.

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

## Live figures

`stats` is how the workers page draws a machine's CPU, memory and disk while it is connected
(`docs/design/ui.md` § The workers page). The worker samples and pushes it every five seconds,
apart from the heartbeat and on its own timer (`stats_ms`, configurable like `heartbeat_ms`),
because the two answer different questions: the heartbeat says the machine is alive and is
written to the row, and `stats` says how full it is and is written nowhere.

```json
{"cpu": 23.4, "memory_used": 5210000000, "memory_total": 16106127360,
 "disk_used": 41000000000, "disk_total": 152000000000}
```

- **`cpu` is a percentage of the whole machine between two samples**, from the `cpu` line of
  `/proc/stat`: the busy share of the time that passed, where idle is `idle` plus `iowait` and
  `guest` is not counted twice (the kernel already includes it in `user`). The first sample has
  nothing to be a difference from, so the first message has no `cpu`.
- **Memory is `MemTotal - MemAvailable`** from `/proc/meminfo` — what the kernel says could not
  be given to a new process without swapping, which is the figure a slice's ceiling is up
  against, and not `MemFree`, which counts the page cache as used.
- **Disk is the filesystem holding the job root**, from `df -P -B1 <root>`, because OTP has no
  `statfs`. `disk_total` is `Used + Available` rather than the filesystem's size, which is how
  `df`'s own capacity column counts: blocks reserved for root are not space a job can write, so
  a disk is full when that sum is used, not when the size is.
- **A figure that cannot be read is left out, never sent as zero.** A zero would draw an empty
  bar, which says *nothing is being used* — the opposite of *nothing could be read*.
- **What the platform keeps is what it can draw.** `cpu` from 0 to 100, and byte counts as whole
  numbers no larger than 2^60; anything else from a machine is dropped as if unread. A float total
  of 1e-300 passed a check for *non-negative* and divided the owner's workers page into an
  exception.

**It never touches the database.** The channel keeps the latest reading as its registry value
(`Workers.stats/1` reads it) and nothing else, so it lives and dies with the channel: a machine
that is not connected has no figures at all rather than stale ones, and there is no table, no
history and nothing to sweep. Unacked for the same reason events are: the next one is five
seconds away.

A platform older than this message logs it as unknown and replies with an error the worker
ignores, so a worker that sends it takes nothing away from a platform that does not read it —
which is what makes it an addition rather than a change (§ Versions).

## An unhealthy machine

`unhealthy` is a machine saying it can no longer run anything: its systemd stopped answering
(`docs/design/worker-tier.md` § A machine whose systemd stops answering). It is acked like a
terminal message and re-sent after a reconnect until it is, and **the reply is the platform's
decision**, not an acknowledgement alone: `{"reboot": true | false, "why": "…"}`. The platform
marks the row, stops placing work on it, requeues what was running there as it would a lost
machine's, and says yes only for a managed machine not told to reboot within the hour. The worker
reboots only on a yes, and only if it is itself a machine a driver made.

From the moment it sends it, the worker runs nothing: every job it had is stopped and reported to
nobody, and an assignment that reaches it afterwards is dropped with a `job.refused` line. That
is correct only because the platform requeues them — the ones running when the message is handled,
and any assignment the channel is handed after the mark, which it requeues rather than pushes
while the job is still that machine's to run —
and it is why this is protocol 4 (§ Versions).

**It is said once per episode**: re-sent until the platform answers, then not again, and said
afresh when `ForgeWorker.Health` marks the machine again — which a restarted health process does,
having forgotten. **Its join says so too**, as `unhealthy` in the payload, for as long as the
worker believes it — which is until the worker restarts. A join without it clears the mark: a machine that rejoins
healthy takes work again, and that is how an unmanaged machine comes back once its owner has
restarted it, and a managed one once it has rebooted.

## The machine's log

`log` carries a line of the machine's own history — a job it accepted or finished, a seed it
fetched or could not, a message from the platform it did not know, and what it could not do for a
job, such as a turn it could not commit — into the log the platform keeps for it and shows on
`/workers/:id`. Nothing a job's agent did goes here; that is the job's `event` stream. It is held while the worker is not joined and sent after the next
join, and otherwise best-effort and unacked, like an event. `docs/design/worker-log.md` is the
standard for what goes in, how it is bounded, and what the platform adds of its own.

## Versions

**The join says what is speaking**, in three fields:

- `protocol` — an integer, the version of this protocol the worker speaks. One number for the
  whole repository, in `core/priv/worker_protocol`, which `ForgeCore.WorkerProtocol` reads at
  compile time and `flake.nix` reads with `builtins.readFile`; nothing else may write it down,
  and a core test fails if `flake.nix` stops reading the file.
- `release` — the string the join line has always logged, `0.2.1 (8rh57whmgk6m)`: the
  application version and, when the release runs from the Nix store, the first twelve
  characters of its store path's hash.
- `build` — those twelve characters on their own, and left out rather than null when the
  release is not in the Nix store. That is what `nix build .#forge-worker` prints, what the
  platform release is built knowing (`docs/design/worker-tier.md` § Updating a worker), and what
  a snapshot is labelled with.

**The platform accepts protocol `P` if and only if `minimum ≤ P ≤ current`**, both from
`ForgeCore.WorkerProtocol`. A worker that sends no `protocol` is protocol 0, which is every
release before this field existed; `minimum` started at 0, so shipping the check refused nobody,
and is 4 from release 0.7.0 (§ What needs a bump, and raising the minimum).
A newer worker is refused as surely as an older one: a platform cannot know what a protocol
from after it expects.

All three are written onto the row at every join, refused or not — `workers.release`,
`workers.build` and `workers.protocol` — so the workers page can say what each machine runs and
why one was turned away. The one exception is a `destroyed` row, whose join is refused before
anything is written (§ Authentication): it is history, and a machine that disagrees does not get
to amend it.

**A refused join is `{:error, %{reason: "protocol", protocol: P, minimum: M, current: C}}`**,
after the row records the protocol it sent, and what happens next depends on whose machine it
is:

- **A managed machine is destroyed at once**, because it bills by the hour and can never take
  work, through `Workers.retire/2`: its running jobs are requeued once the row is destroyed. A
  destroy the driver refuses keeps the row as any refused destroy does.
- **Its template learns**, if this is the machine's first join, the protocol of the image it was
  made from (`workers.image`, copied from the template at creation), so no further machine is made
  from that snapshot (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).
  A first join that is accepted teaches it too, which is what ends the probe an unlabelled image is
  held to.
- **A permanent machine only gets the reason on its row.** It is not the platform's to power off,
  and updating it is somebody's errand; the page names it.

The refused join does **not** write `last_seen_at`. A permanent machine that keeps knocking is
still not a machine the platform can hear from, and its jobs have to reach
`Workers.sweep_unreachable/0`'s timeout like any unreachable machine's.

**The worker, refused, stops what it is running** — refused at the join, or turned away at the
socket itself, where a row that is destroyed or a token that is not its gets a 403 before any join
(`WorkerSocket.connect/3`); after a reconnect that is how a retired machine is refused, and the
join's own `destroyed` is only met on a socket that outlived its row. Nothing it reports can reach
the platform now: a refused join carries no messages, and the platform re-queues a refused
machine's jobs — at once for a managed one it destroys, after the unreachable timeout for a
permanent one. A permanent machine that ran on would spend its jobs' credentials on runs whose
results nobody would ever record, while the same jobs ran again elsewhere. So it stops them as it
does when it is unhealthy, reporting nothing.

**The worker, refused, says so once and waits minutes, not seconds.** One log line naming the
protocol it speaks and the range the platform accepts, and a rejoin after `refused_retry_ms`
(five minutes) rather than Slipstream's own backoff, which settles at ten seconds and would
write that line and ask that question three hundred and sixty times an hour for something
only a deploy can change. A join refused because the row is `destroyed` waits the same way.

### What needs a bump, and raising the minimum

**A change is breaking when a platform and a worker built on either side of it cannot work
together correctly**, and only a breaking change moves `current`. Breaking:

- removing or renaming a message, or a field the other side reads;
- changing a field's type, unit or meaning;
- a new field or message the other side must act on to be correct — a platform-to-worker
  `update` a worker has to obey, a field the platform starts requiring;
- changing what an ack or a refusal means.

**Not breaking**, and so no bump: a worker-to-platform message the platform may ignore (`stats`,
`log`); a new field whose absence already has a meaning the receiver honours (`cores` and
`accepts` were added this way, and absent reads as *unknown*); a platform-to-worker message a
worker may log and drop.

Bumping `current` without raising `minimum` keeps every older worker taking work, and refuses a
newer worker on an older platform — which is why additions do not bump it: the platform is
deployed first, and a snapshot built from a newer checkout would otherwise be turned away for a
field its platform could have ignored.

**Protocol 2 is commands** (`docs/design/commands.md`): a `kind: "command"` assignment, and a
`result` whose `status` is `parked`. It is a bump and not an addition because both directions need
acting on to be correct — a protocol 1 worker would run a command's spec as an agent job's, and a
protocol 1 platform would refuse a `parked` result it cannot read. The minimum stays 0: a
protocol 1 worker still takes every agent job whose state may not invoke, and the gate keeps the
rest from it by its recorded protocol (`Workers.fits?/2`).

**Protocol 3 is questions as a headline and a sentence** (`docs/design/job-prompt.md` § Output
format): an option is `{label, detail, recommended}`, `default` is gone, and the lengths are
limited. It is a bump because the worker is what teaches an agent the block — the preamble is the
worker's own copy — and what corrects it, while the platform re-parses every document it records
with the same strict parser: a protocol 2 worker's agent writes `options: [a, b]`, its worker
accepts it, and the platform refuses the result, which is then re-sent and refused on every join.
So an agent — a workflow job or a conversation — needs protocol 3 (`Forge.Jobs.protocol/1`), and
a protocol 2 worker keeps taking commands only. The minimum stays 0 until every template and
permanent machine has moved, as below; until then an old machine is not refused, it is simply
not given an agent. A template whose snapshot speaks protocol 2 makes no machine for an agent,
for the same reason, and the templates page says which snapshot it is.

**The batch a command state hands on is an addition** (`docs/design/job-prompt.md` § How the
job arrived): `entered_commands` in the spec, and `entered-<n>-<command>.log` entries in
`commands`. An older worker's spec parser drops `entered_commands`, so its manifest says nothing of
the batch, and it refuses the `entered-` names and logs `commands.unwritten`: the job is told only
where it came from and on which outcome, as before this existed. A log a state names in `inputs`
still reaches it, since inputs are inlined. That is less, not wrong, which is what an addition may
be.

**The carried session is an addition** (`docs/design/claude-code-events.md` § Resume): a prefix
to upload the harness session under, `session` to restore and `fork_session` on `assign`, and a
`session_blob` and `version` in a result's or a turn's harness summary. An older worker ignores
the first three and reports none of the last, and every combination is correct: it uploads
nothing, so nothing is carried; a resume of its own session finds what that machine holds, as it
always did; a fork of another attempt's session — a job directory the machine never had — finds
nothing, is re-queued cold with the fork cleared, and runs as a new attempt always did; and a
conversation it reopens never read `resume_session`, so it starts cold with the replay.

**Protocol 4 is an unhealthy machine** (§ An unhealthy machine): the `unhealthy` message and its
reply, and `unhealthy` in the join. It is a bump because a protocol 4 worker acts on the platform
acting on it — it stops its jobs and reports none of them, and drops what it is assigned — and a
platform that ignored the message would leave every one of those jobs `running` on a machine that
will never report it. A protocol 3 worker on a new platform never sends either, and the platform
would have treated it exactly as before — a machine that stopped answering found by the timeout —
had the minimum stayed where it was.

**Protocol 5 is integrating the default branch** (`docs/design/job-prompt.md` § Integrating the
default branch): `default_branch` in an assignment's `git`, which the worker must fetch, keep as a
squashed run's second parent when the run merged it, and an `integration` in the spec it renders
into the manifest. It is a bump because a protocol 4 worker would drop all three and still report
success: it would push a resolution squashed onto one parent, whose next check against the default
branch finds the conflict it was meant to resolve. So a job of an integrating state needs protocol
5 (`Forge.Jobs.protocol/1`, from the stored spec's `integration`), and a protocol 4 worker keeps
taking every other job. The minimum stays 4.

**The minimum is 4, from release 0.7.0.** No machine outside the operator's own ran an older
worker when protocol 4 shipped — no node served anyone else, and there were no permanent machines
to update — so the steps below cost one snapshot built at protocol 4 and the templates moved to it,
and the platform stops carrying three older protocols. **Here the order is the other way round**:
protocol 4 and the floor ship in the same release, and a platform at 0.6.0 would have refused a
snapshot labelled 4 as too new, so the platform is deployed first and the snapshot built after —
with, in between, no managed machine to run anything (`docs/deploy.md` § Upgrading). A worker at
0–3 is refused at its join, and a managed one is destroyed there (above); a template whose snapshot
is labelled older makes no machine until it names another, and one whose snapshot is unlabelled
makes one, which is refused and marks the image (below). What the floor leaves with nothing to decide is still in the
code: `Forge.Jobs.protocol/1`'s per-kind protocols (2 for a command, 3 for an agent), and the
templates page's word for a snapshot that cannot run an agent — every worker it accepts can run
those. **The protocol dimension of `Workers.fits?/2` and the scheduler's demand decides something
again** since protocol 5: an integrating job needs it, a job that names a secret needs 6, and a
protocol 4 worker is still accepted, so the gate is what keeps such a job off it (above).

**Protocol 6 is project secrets** (`docs/design/secrets.md` § Delivery): `secrets` on an
assignment, sealed under a purpose. It is a bump because ignoring it is wrong, not less: an older
worker drops the unknown key and runs the job without the secrets its state names — a build
without its registry token, a test against no key — and masks nothing. So a job naming secrets
needs protocol 6 (`Forge.Jobs.protocol/1`), and a protocol 4 or 5 worker, still accepted, keeps
taking every job that names none: an assignment without secrets is exactly what it was, and the
credential's seal is unchanged. The minimum stays 4 until the templates and permanent machines
have moved, as below.

**Protocol 7 is a conversation that merges the default branch** (`conversations.md` § Commits):
`default_branch` in a *chat's* assignment's `git`, and a squash that settles a conflict the run
left open instead of dying on `reset --soft` (`git-hosting.md` § Non-fast-forward on a ticket
branch). It is a bump because the first without the second is worse than neither. A protocol 5 or
6 worker fetches the branch and keeps a committed merge — that half was never kind-aware — but
its squash cannot survive a merge the turn left open, so the turn dies with a bare git error and
so does every turn after it, a trap no chat could reach while nothing told it the branch. So a
conversation needs protocol 7 (`Forge.Jobs.protocol/1`), a protocol 4-6 worker keeps taking every
workflow job and command, and the minimum stays 4.

**What this leaves exposed, named rather than claimed closed**: an *integrating* job still asks
only for 5, and on a 5 or 6 worker a run of it that ends mid-conflict fails the way forge#2 did.
That is the bug being fixed, not a misread of anything new the platform sends, and raising that
floor would strand tickets on machines that can still do everything else such a job needs. It
closes when the templates move, as every protocol does.

**`uncommitted` on a turn rides along without a bump.** An older worker never sends it, and an
older platform builds the `chat.turn` payload key by key (`Conversations.record_turn/2`) and so
drops it: the turn is recorded as it was before, with no commit and no reason.

What rides along without a bump, because an older side may ignore it: `job.harness.memory`
events and the `memory` a `starting` event carries (`docs/design/claude-code-events.md` § Memory),
which an older platform records like any other harness event; and `memory` in a result's or a
turn's harness summary, which it keeps in the event's payload and reads nothing from.

**Raising `minimum`** is the platform dropping an older protocol: the day it stops handling the
shape older workers send. It is the one edit here that refuses running machines, so, before it
ships:

1. build and label a snapshot at the new protocol (`bin/hetzner-image`) and move every template
   to it — the templates page shows each snapshot's protocol;
2. update every permanent machine (`bin/worker-update`) — the workers page shows each machine's;
3. then raise `@minimum` in `ForgeCore.WorkerProtocol`, which is a code change and not the file:
   the file is what this build speaks, and the minimum is what this platform still accepts.

A managed machine still on the old protocol when the platform restarts is refused and destroyed
on its next join. That is not its first join, so its template learns nothing from it; the template
is still labelled with the protocol its snapshot speaks — or, unlabelled, knows what the snapshot's
first machine said — and so refuses to make another. A missed template costs the machines that were
already running, and says so on the templates page rather than looping.

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
must treat them as idempotent — keyed by the job, since the payloads carry no attempt, and a
`turn` by its place in the conversation (`Conversations.record_turn/2`): a second `result` for a
job already `finished` is acked and dropped, not recorded twice. A job row is not one run — a
re-queued job runs again under the same row — so a report about an earlier run is told apart by
the job's status, below, and not by the key.

**A report about a run the platform has given up on is acked and dropped.** A `failed` or a
`hibernated` for a job that is back in the queue, waiting on a person or parked is the end of a
run the platform already let go of: it re-queued the job when the machine was lost, unhealthy or
retired, or after a rejoin that did not list it — or a person reopened the conversation — and a
run of it will be scheduled again. Recording the report would finish a workflow job with an
error, leave it hibernated where nothing resumes it, or put a reopened chat back to sleep. A
current worker sends no such report (it stops a run cancelled as `not_ours` or `retired`
silently, above); this rule is for the machines that predate that, and for a run that ended before
any `cancel` reached it. **It narrows the race and does not close it**: a job re-queued and placed
on the same machine again before the stale report is read is `running` once more, and the report
lands on the new run. From a current worker that needs a report already queued while the socket
was down, read in the milliseconds after the rejoin; from an older one, which drops a second
assignment of a job it is still stopping as *already running*, it is the old bug — its refused
push's `failed` finishing the re-run as an error — until the machine is updated. Only a run
identity carried in the protocol would close it. A `result` is not dropped: it is the
run's answer, which a job that finished while the socket was down still owes (`Jobs.complete/2`).
Nor is a dormant chat's ending, which `Conversations.ended/4` records as before: dormant is
`hibernated`, not one of the statuses above.

That ordering — commit, then ack — is the one that fails safely. Acking first and crashing loses
the job's outcome while the worker believes it is delivered. Committing first and crashing costs a
duplicate delivery, which the idempotency key absorbs — for a `result` and a `turn`; a re-sent
`hibernated` or `failed` is absorbed by the status rule above, with the race it states.

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
  PR #11's cold-recovery fix is what makes that safe: a re-queued job clears `out/` rather than
  inheriting a dead run's outputs.
- **Worker has it, platform does not have it running there.** The job is finished, back in the
  queue, waiting, parked, or running on another machine. The platform sends `cancel` with
  `not_ours`, and the worker stops the run **and reports nothing** — the same as a run stopped
  because the machine went unhealthy (§ An unhealthy machine). A job its ticket's cancel finished
  is the exception: it is told `ticket_cancelled`, because that cancel may never have reached a
  machine that was away when it was sent, and the report it asks for is how the run's spending is
  settled. It used to report, and the report
  landed on the job as it now was: a re-queued job finished as an error, because the run's final
  push was refused with the credential the re-queue had revoked, or left `hibernated`, which
  nothing resumes. A report that still arrives from an older worker is dropped (§ Delivery).
- **An assignment for a job whose cancelled run is still stopping waits for it.** The scheduler
  prefers the machine a job last ran on, so a job re-queued off this machine can be handed straight
  back while its old run is still in its grace period. The worker used to drop that assignment
  as *already running*, leaving the platform with a job marked `running` that nothing was; it now
  holds it and starts it once the old run has stopped.
- **Both agree.** Nothing happens, and the worker re-sends anything unacked. The job runs on.

## A platform restart

**A job running on a machine survives the platform restarting under it.** The worker holds its
jobs, keeps its terminal messages until they are acked, and redials within seconds; the platform
only has to not throw the work away before it does. So at boot `Forge.Jobs.recover/0` touches
only what no machine can ever report: a job left `running` on a row that is `destroyed`, or
missing, or no row at all. Those go back to the queue — a conversation dormant — and their git
credentials are revoked. Every other `running` job is left as it is, credential and open run
included, and what becomes of it is the worker's to say at its rejoin, by the rules above: listed,
it runs on in place; not listed, it is re-queued; never back, the unreachable sweep re-queues it
(§ When the machine goes away).

It used to re-queue everything at boot. Every rejoin then found its jobs no longer its own and
was told to cancel them, so every deploy threw away every run in flight — and the cancelled runs'
reports finished those jobs as errors or left them hibernated.

**There is no ordering to get right at boot**, and that is the reason for the rule rather than a
consequence of it. The jobs recovery touches are on rows a machine cannot join, so a worker that
rejoins in the first milliseconds, before recovery has run, meets nothing recovery is about to
change. Recovery is still once per boot, beside the scheduler and not in its `init`.

**The unreachable sweep's clock starts at boot at the earliest.** `last_seen_at` is written by a
heartbeat every twenty seconds, and a platform that was down for longer than the timeout would
otherwise find every machine overdue on its first pass, two seconds after it started — before the
machines had had a chance to redial — and destroy the managed ones with their jobs. A row is
overdue only once `worker_timeout_ms` has passed since the later of its `last_seen_at` and the
moment this node booted (`Workers.booted/0`).

**A run that ends while the platform is down waits for it.** Its branch and its store are the
platform's, so its last push and its uploads have nowhere to go: the push is tried again while it
cannot reach the platform, for up to ten minutes (`Workspace.commit_and_push/4`), and an upload
retries for about eight (`ForgeWorker.Store`). Meanwhile the job is still the machine's, listed at
its rejoin, and its result lands as usual once the platform is back. A credential refused is not
waited on. A push that gives up fails the run; the job has left the machine's list by its rejoin,
so it is re-queued there and the `failed` that follows is dropped as a run given up on.

What a restart still costs: events a job produced while the platform was down, which are
best-effort (§ Delivery); a run that ended and could not push or upload for longer than that
patience, which runs again; and a job whose machine does not come back within the timeout, which
runs again from its branch, as it would after any lost machine.

## When the machine goes away

`last_seen_at` is written at a join the platform accepts, at `ready` and by every `heartbeat` —
never by `stats`, and never by a refused join (§ Versions). Past `worker_timeout_ms` — counted
from `last_seen_at`, or from this node's boot if that is later (§ A platform restart) — the
platform stops waiting (`Workers.sweep_unreachable/0`), and what it does next depends on whose
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

**A machine that says it is unhealthy loses its jobs the same way**, through the same
`Workers.requeue_running/2`, without waiting for a timeout — it is connected, and saying so.
A row told to reboot is left alone by this sweep for `reboot_grace_ms` from when it was told,
so a machine rebooting is not destroyed for being away a minute
(`docs/design/worker-tier.md` § The same machine, the same row).

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

- **What the protocol floor left behind** (§ What needs a bump, and raising the minimum). With
  every accepted worker at protocol 4 or later, `Forge.Jobs.protocol/1`'s numbers for a command and
  an agent decide nothing; the protocol dimension of `Workers.fits?/2` and the scheduler's demand
  stay, because an integrating job needs protocol 5, a job that names a secret needs 6, and the
  floor is still 4; the workers
  page's *no stats — update it*, for a connected machine that spoke no protocol, can no longer be
  drawn; and `Provisioning.holds?/2` still asks only whether a template's image is new enough for
  the job, not whether this platform accepts it, so a project with a small template labelled 3 and
  a larger one labelled 4 has the small one chosen and refused three times before the larger is
  used. The last is the one that does something wrong; the rest are dead.
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
