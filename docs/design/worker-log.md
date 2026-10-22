# The worker log

Scope: a machine's own history — what happened to it and on it, at the level of the machine —
kept by the platform and read on the workers page. Not a job's event stream, and not the
machine's journal.

## Why it exists

A worker logs to journald on its own machine, and nobody can read that. A Hetzner machine has no
inbound port — the ssh door is shut unless the operator opened it (`worker-tier.md` § The provider
driver) — and a managed one is destroyed once it has had nothing to do for long enough, taking
its journal with it. What the platform itself saw happen to a machine — made, refused by its
driver, joined, refused at the join, swept as unreachable, destroyed and by what — was in the
*platform's* log, which is a host to grep, or in the one `last_error` a row keeps. "What was this
machine doing, and why did it go away?" had no answer on any surface the operator has.

## What goes in, and what does not

**Worker-level events, and what the worker itself could not do for a job.** A job appears as the
unit of work a machine accepted and finished, and nothing the agent did inside it: its tool calls,
its turns, its questions are the job's own event stream (`claude-code-events.md`), drawn on the
job page. Copying them here would make this page the activity feed `ui.md` § Motion and structure
refuses, and write every line twice.

**What the machine failed to do on a job's behalf is here, tied to the job.** A turn it could not
commit, a transcript it could not upload, a credential it could not open, a slice it could not
make: the worker's own work, not the agent's, and none of it reaches the job's event stream. This
note said the opposite first — "those belong on the job, not the machine" — and the job had
nowhere to put them, so each was a journal line and nothing else. That is how a conversation whose
every turn failed to commit looked, from the platform, exactly like one that had nothing to
commit: the turn arrived with no commit and no reason, and the reason was on a machine nobody can
read. A failure the job's own terminal message already carries — a job that failed, and why — is
`job.finished` and is not said twice.

Two sources, one log, told apart on every line:

**What the platform saw** — written by `Forge.Workers` and the channel as it happens:

| Type | Level | Says |
|---|---|---|
| `created` | info | made by which driver, as which machine, from which template — or provisioned by hand |
| `create.refused` | error | the driver's words, when it would not make the machine |
| `joined` | info | the release, build and protocol the join carried |
| `join.refused` | error | the protocol, and the range this platform accepts |
| `ready` | info | what the row now offers — memory, cores, kinds — which for a permanent machine is its owner's figures and not always what it reported |
| `disconnected` | info when the channel was shut down — the machine or the platform closed the connection, it left, its row was retired, the platform is draining for a restart or stopping — and warning when it crashed | why, in words; for a crash only the kind of error, since the stack trace is the platform's and this page is the owner's |
| `job.lost` | warning | a job the platform had running there that the machine rejoined without, requeued |
| `unhealthy` | error | the machine said its systemd stopped answering, and why; how many jobs were requeued; and whether it was told to reboot — or why not: permanent, or told within the hour |
| `healthy` | info | a machine marked unhealthy joined again without saying so, and takes work again |
| `unreachable` | warning | not heard from since when, how many jobs were requeued, and whether the row stays — for a permanent machine only when it had jobs to requeue |
| `destroyed` | info, or warning when forced, when its provider is gone, or when a machine arrived for a row retired while it was being made | by what: idle, idle and its slot wanted by a job it could not take, unreachable, its owner, the host's command line, a refused protocol |
| `machine.found` | warning | a machine the driver holds for this row whose id never reached it — a create cut off by a platform restart — found by its name as the row was being destroyed, and destroyed with it (`provisioning.md` § Whose account) |
| `destroy.refused` | error | the driver's words, when it would not let the machine go — and that the next sweep tries again only when a sweep was what asked (`ui.md` § The workers page: a Destroy pressed on the page promises no retry) |

**What the platform would otherwise repeat is said once.** `sweep_unreachable` runs on every
scheduling pass and retries a destroy the driver refused each time, and a refused permanent machine
knocks again every few minutes; a line per attempt would fill the 500 with one fact. So a managed
machine's `unreachable`, and every `join.refused` and `destroy.refused`, is written only if the
platform has written no line of that type about that machine since it last joined — its own
`joined` lines, never one a machine sent, which could otherwise lift the silence or impose it. The
row's `last_error` holds the driver's latest words. A permanent machine's `unreachable` needs no
rule: it is written only when there were jobs to requeue, and a machine out of touch is given none.

A `disconnected` is written only by a channel that joined: a refused join also ends in the
channel's `terminate/2`, and its refusal is the line.

**What only the machine knows** — sent by the worker in `log` messages
(`worker-channel.md` § The machine's log):

| Type | Level | Says |
|---|---|---|
| `job.accepted` | info | a job or chat it took on, and which attempt |
| `job.finished` | info, or error when it failed | how it ended — its outcome, hibernated and why, or failed and the first line of why — and how long it ran |
| `seed.fetched` | info | a project seed it fetched, and how long that took |
| `seed.missing` | warning | a seed it could not fetch, so the job builds cold |
| `harness.unprobed` | warning | the harness would not describe itself at join |
| `chat.missing` | warning | the platform spoke to a chat that is not running on this machine — a message, an interrupt or a close that reached nobody |
| `message.unknown` | warning | a message from the platform this release does not know — a version apart |
| `log.dropped` | warning | entries it could not keep while it was not connected |
| `machine.unhealthy` | error | its systemd stopped answering — a `systemd-run` that failed on the bus, or PID 1 not answering the probe twice in a row — and that it has stopped its jobs and takes no more (`worker-tier.md` § A machine whose systemd stops answering) |
| `machine.rebooting` | warning | the platform said to reboot and the machine is one a driver made, so it is rebooting now |
| `machine.unrebooted` | warning, or error when the reboot command itself failed | it is not rebooting, and why: the platform said no, or it is not a machine a driver made, or the reboot command itself failed. It was `machine.not_rebooting` until the first end-to-end run (2026-09-30, `measurements.md` § The unhealthy machine, end to end) found the platform keeping it as `unknown`: an underscore is not in a type (below) |
| `job.refused` | warning, or error for a ceiling | an assignment it did not start: its memory ceiling below the minimum or not a number, or the machine is unhealthy |
| `job.abandoned` | warning | a job it stopped without reporting its ending, because the platform had already given that run up: the machine went unhealthy, the platform cancelled it as no longer this machine's (`not_ours`) or because the row was retired, or the platform refused the machine — its join, or its connection at the socket (`worker-channel.md` § Reconnection, § Versions) |

And what it could not do for a job, each line carrying the job's id and the failure in the words
it was reported in (git's, the store's, the filesystem's):

| Type | Level | Says |
|---|---|---|
| `turn.uncommitted` | error | a conversation's turn it could not commit or push, so the turn's work is on the machine and not on the branch |
| `chat.undelivered` | warning | a message for a conversation the harness would not take |
| `credential.unopened` | error | the job's credential would not open, so the harness runs without one |
| `slice.failed` | error | a job or command it could not confine, and so did not run |
| `slice.uncleaned` | warning | a job's files it could not take back from the job's user, or the user it could not remove |
| `upload.failed` | warning | a transcript, a blob, a command's log or a harness session that did not reach the store, or had nowhere to go |
| `history.unwritten` | warning | what already ran on the ticket that a conversation was to read and could not be laid out, or an entry refused for a name that leaves its folder |
| `backlog.unwritten` | warning | the project's tickets that could not be laid out for the job, or an entry refused |
| `session.unrestored` | warning | a carried harness session it did not put back — written by another version of the CLI, not the session's own, or not downloadable — and so a cold start, or for a job a resume left to what the machine holds |
| `commands.unwritten` | warning | a command's log a resumed job, or one entered from a command state, was to read, left out because it would not fetch or its name was refused |
| `volume.uncreated` | warning | a worktree it could not make a volume of, so the finished tree cannot be kept as the ticket's template and its next job starts colder |
| `volume.unused` | warning | a seed or ticket volume that would not become the job's worktree, so it started colder |
| `volume.unkept` | warning | a finished worktree it could not keep as the ticket's template, so the next job starts colder |
| `worktree.undeleted` | warning | a finished job's worktree it could not remove |
| `event.dropped` | warning | an event of the job's it could not hand on — said once per run, since a sink that fails once fails for every event after it |

**Accepting a job is the worker's line, not the platform's.** The platform knows it sent an
assignment; only the machine knows it took it. An assignment lost in flight is the case
§ Reconnection in `worker-channel.md` repairs, and it shows here as `job.lost` at the rejoin — which
the two lines are there to tell apart from a job that ran.

## The `log` message

`{"at": "2026-09-26T19:20:00Z", "type": "job.accepted", "level": "info", "message": "…", "job_id": "…"}`
— `job_id` only on a line about a job. The worker sends it, unacked, from the link process, whatever
process the line came from (`ForgeWorker.Log.line/4` hands it to the link by name); it logs the same
line to its own journal as before.

- **Kept while not joined, and sent at the next join.** Up to a hundred lines are held, oldest
  dropped first, and a `log.dropped` line saying how many is sent ahead of them — so a job that
  finished while the platform was away is in the log, at the time the machine says it finished.
- **Best-effort otherwise**, like a job's events: a line pushed into a connection that is dropping
  is lost. Nothing is decided from this log.
- **Additive, so no protocol bump** (`worker-channel.md` § What needs a bump). A platform older than
  it replies `unknown_message`, which the worker ignores.
- **The test config turns the stream off** (`log_stream: false`), as it sets `stats_ms` long, and
  the tests about it turn it on: a push in `Slipstream.SocketTest` is a call the test must answer,
  and a line nobody asked for stalls the link.

**What the platform keeps is bounded, whatever a machine sends.** The type must look like one —
lower-case words and dots, at most 64 characters — or it is stored as `unknown`; the level is
`info`, `warning` or `error`, or `info`; the message is text, cut to 500 code points, with NUL
removed — **and only those 500 are read**: a message is cut as it is read rather than checked whole
and then cut, because checking a ten-megabyte message whole cost the channel ten seconds and half a
gigabyte, and the socket's frame limit is the only other bound on its size; `job_id` is kept only if it is a UUID. `at` is the machine's own clock, believed when it
is no more than five minutes ahead of the platform's and no more than a week behind, and replaced
by the time of arrival otherwise, and kept to the column's microseconds whatever precision it was
written in — a time with no fraction is one a `utc_datetime_usec` would otherwise refuse, crashing
the channel that received it. A line the platform writes is stamped with its own clock.

## Storage

`worker_log`: the worker, `at`, `source` (`platform` or `worker`), `type`, `level`, `message` and
`job_id`. **The last 500 lines per machine from each source**, trimmed as each is written: a
permanent machine runs for months and a line per job adds up, while what anyone reads is the
recent past. Per source, because **the platform's record of a machine is not the machine's to
erase**: with one budget, five hundred lines from a machine that is broken, or not what it claims,
pushed out every `joined`, `job.lost` and `destroy.refused` the platform had written about it. A
destroyed machine keeps its log, because "why did it go away" is asked afterwards.

It is not the `events` table. Those rows belong to a project, a ticket or a job, and are read by
who may see that project; a machine belongs to a user and serves several projects, and its log is
read by its owner (`identity.md` § Workers).

## The page

`/workers/:id`, reached by a *Log* link on the machine's block on `/workers`. The machine's header
line, then its log newest first — up to 200 lines, each with its time in UTC, where it came from,
its type, and its message, and the first eight characters of the job a line is about — re-read on
the same five-second timer as the workers page. **Only the
owner's**: the id is off the wire and read scoped to the viewer, and somebody else's machine is
*not here*, as on `/workers` (`identity.md` § Sequencing). A destroyed machine's log is still
there.

Error lines are in `error`; nothing is accent, for the reason nothing on `/workers` is.

## Deliberately not here

- **The machine's journal.** A "fetch the last 200 lines" request over the channel, the tail
  uploaded to the store under a scoped token as a transcript is, and taken automatically before a
  managed machine is destroyed, is the escape hatch for what this log does not carry. Not built.
- **The rest of the journal's warnings**, which are not about a job. The connection's own —
  disconnected, refused, a channel closed — are lines the platform writes from its side
  (`disconnected`, `join.refused`), and a machine that is not configured has no link to send
  anything on. The sweeps of old job directories and ticket volumes still warn only in the journal:
  housekeeping on the machine's own disk, about no job, and a candidate for this log if a full disk
  ever needs explaining.
- **Flow control.** A machine that sent a flood would churn its own 500 lines — not the platform's
  — and cost the platform what any message costs to decode; the same open item as job events in
  `worker-channel.md` § Open.
- **Search and filtering.** Two hundred lines newest first is what debugging one machine needs so
  far.
- **A machine that never connects** sends nothing, and its log is what the platform saw: made,
  and swept or refused. The provider's console is the rest.
