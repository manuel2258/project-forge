# The project's archive

A job, and a conversation, can read the whole of its project's past: every document every ticket
ever produced in every version, the files they uploaded, and a ledger of every job that ran. It
is a read-only folder, `$FORGE_JOB/archive/`, and **nothing in it is copied when the job starts**:
a file's bytes are fetched the first time the agent opens it.

Ticket 24 asked for it, and the person who owns the project answered the two questions that shaped
it: fetch on demand, because fetching everything at every start is not practical; and documents
*and* files, every version, with a file of the jobs that ran, so that a job can analyse the project
and not only quote from it.

## What it widens

- `docs/decisions.md` said every job is handed ticket *bodies only*. That is still true of
  `tickets/` and of `inputs/`, which stay the only **pinned** inputs. It stopped being true of what
  a job may *read*.
- `ticket-proposals.md` § A mounted filesystem, now (it was § Not a mounted filesystem) rejected a mount that fetches on open, for four
  reasons. Each is answered there, in the note, now; the cost it named was a megabyte of bodies and
  here it is every version and every blob of a project, which no job can be handed up front.

## Why it is `archive/`

`history/` is taken: a conversation already has `$FORGE_JOB/history/<state>/<attempt>/` with the
transcripts of earlier jobs (`conversations.md`). Transcripts, logs and a conversation's chat
history are **not** in the archive. The name is `ForgeCore.Workflow.archive_dir/0`, beside
`tickets_dir/0`, and the preambles state it in the same list as `tickets/`.

## Layout

The platform composes it; the worker serves it. Names are decided on the platform, and the worker checks each again (`Tree`) before it will show it.

```
archive/index.md                 # taken at <time>; one line per ticket, every status
archive/jobs.tsv                 # every job of the project: header row, `n/a` where absent
archive/<n>/jobs.tsv             # the same, that ticket only
archive/<n>/<name>               # the latest version of a document or file, its original name
archive/<n>/<stem>.v001<ext>     # each version; zero-padded to 3, wider past 999
archive/<n>/<group>/<file>       # a `name/*` member: the artifact name's `/` is a folder
```

- **Documents, presentations and blobs** of every ticket, of every status. **Not** the changeset
  (that is git, and the agent has the repository), **not** `proposal-*` (they stay in `tickets/`),
  not a job's transcript or raw harness output, not the artifacts of a project chat (a ticket chat's documents are the ticket's, and are here). A command's log that the
  workflow declares among what it produces is a file like any other and is here.
- `index.md` has a line per ticket — number, title, type, state, status, and what it holds
  (documents, files and versions, which counts every version of both) — and says when it was taken. A ticket still in flight shows the
  versions that exist when its folder was last listed; the ticket the job belongs to is in it.
- `jobs.tsv` columns: `ticket state attempt kind outcome status started_at finished_at turns
  cost_usd model effort memory_max cores runs`. `runs` counts `job_runs`. Where the platform
  recorded nothing (an old row, a job that never started) the field is `n/a`, not omitted. **No
  credential, no machine, no owner**: the file says what ran and not who paid (the person's answer
  on ticket 24).
- **`jobs.tsv` and `index.md` are the platform's.** An artifact called `jobs.tsv` is not listed
  (and the name is logged), so the ledger cannot be shadowed by a file an agent wrote.
- **Version names.** `plan.md` is the latest; `plan.v001.md`, `plan.v002.md` … are each version. A
  name with no extension (`ticket`) becomes `ticket.v001`. If two names collide, or a file and a
  folder do, the later in sort order is dropped and logged — the tree is never ambiguous.
- **A name is one segment** (not empty, not `.` or `..`, no NUL, at most 255 bytes) or
  `group/segment`. The check is lexical and it is the whole model, which is sound for the reason
  `CLAUDE.md` asks every guard to give: **the worker never turns a name into a path on its disk.**
  The tree is in memory, a lookup is by exact key in a map, and the cache is keyed by the version's
  id.

## The door and its grant

`GET /archive`, `GET /archive/tickets/:number` and `GET /archive/tickets/:number/:ref`, served by
`ForgeWeb.ArchiveController`, with no session, beside `/store`. The first lists the root, the second
one ticket, the third is a version's bytes, exactly as `Forge.Artifacts.served/2` serves them.

- **The grant is the per-job git token** (`git-hosting.md` § The per-job token): minted per
  assignment, scoped to a project, hashed at rest, revoked when the job ends, its rows the audit
  trail. `Forge.Git.Tokens.authorise_job/1` accepts only a live token that carries a `job_id`; an
  operator's token has none and is refused here. Nothing was added to the schema.
- **The project is the token's, never the path's.** Every query is scoped by the project on the
  token row. A ref that belongs to another project, a git version or a proposal is `404`, the same
  `404` as one that does not exist; every token failure is the same `401`.
- `GET` only. There is no other verb on the path.

## The worker's side

The worker has no FUSE helper (`fusermount3` is not on the image) and no room for a daemon, but its
kernel ships `9p` and `9pnet_fd`. So **the worker serves 9P2000.L itself, over a unix socket, and
root mounts it** with the kernel's own client:

```
mount -t 9p -o trans=unix,version=9p2000.L,ro,nosuid,nodev,noexec,access=any,cache=none \
  <private dir>/s $FORGE_JOB/archive
```

`<private dir>` is `$TMPDIR/forge-archive-<16 hex digits>`, mode 0700, made with `File.mkdir/1`
(which refuses a name that exists) and removed with the server. It is not beside the job because a
unix socket's path is at most 107 bytes and the socket beside the job would be `<root>/jobs/<uuid>.worker/archive.sock`, 76 on
the image and more on any longer root. A worker killed outright leaves the directory and a dead
socket in it.

- `ForgeWorker.Archive.P9` is the codec; `Tree` the pure layout; `Client` the HTTP; `Server` the
  socket; `Mount` the one place that runs `mount` and `umount`. Only `Mount.NineP` needs a real
  machine; the rest is tested by speaking 9P to the socket from ExUnit.
- **Read-only is the server's rule as well as the mount's.** Every message that would change
  anything, and `lopen` with a write, truncate, append or create flag, is `EROFS`. A file is mode
  0444 and a folder 0555, owned by root.
- **Listing and reading.** Attaching, `stat` of the root and `statfs` fetch nothing; listing the root, or walking into it,
  fetches the root listing (two small files and the ticket numbers) and no file's bytes. A ticket's
  listing is
  fetched on the first walk or `readdir` into it and again once `:archive_listing_ttl_ms` (60 s)
  has passed, so a ticket in flight shows new versions; a directory or file opened keeps the
  instance it opened, so a refresh never tears a read. A file's bytes are fetched when it is
  **opened**, streamed to a temporary file under the job's root-only worker directory, checked
  against the listed size and sha256 where one was kept, and only then renamed into the cache,
  keyed by the version's id. A second open is served from the cache; two opens at once share one
  fetch.
- **A failed read is bounded and says why.** Connecting takes at most 10 s and a transfer has to
  make progress every 30 s — no progress, not total size, so a gigabyte file is not cut short. The
  error is a plain errno: `ETIMEDOUT` (platform unreachable), `ENOENT` (gone), `EACCES` (the grant
  ended), `EIO` (it arrived damaged). A failed fetch leaves nothing in the cache and the next read
  tries again; the file is never there half-written.
- **Lifetime.** The server and the mount are made after the job directory is prepared and the slice
  has handed it to the job's user (its recursive `chown` must not meet the mount), and before the
  process starts. They are gone before the files are handed back: `umount -l` and closing the socket
  run in the runner's cleanup and again, idempotently, before every `Slice.leave`, so that the
  `chown -R` that takes the files back never walks a read-only mount. A resume prepares again: a new socket, an empty
  cache. The worker's start unmounts every 9p mount under the jobs root, read from
  `/proc/self/mountinfo`; `Dir.sweep/2`, which runs whenever any job ends, releases only the one
  directory it is about to remove, and only once that directory is stale — another job's archive on
  the machine is live.
- **A worker with no mount** (`FORGE_ARCHIVE` unset: a developer's machine, the test suite) puts one
  `README.md` in the folder saying so. The kernel mount is `FORGE_ARCHIVE=9p`, which the worker
  image sets as it sets `FORGE_SLICE`.
- **Protocol 9.** A worker older than it would start the job without the folder and say nothing, so
  a workflow job and a chat need protocol 9 and an older worker is given neither
  (`worker-channel.md` § Versions). A command has no folder and keeps its number.

## What is recorded

**The folder is live, not pinned.** The job's prompt says so in a sentence: later versions may
appear, the documents there were not approved for this job, cite a version and do not assume the
latest. What the job actually opened is recorded as `job.archive_read` events — ticket number,
artifact name and version — once per distinct version, written by the door on a content `GET`; a job
that opened nothing records nothing. The job page shows only the count, and the lists of events — the job's, the ticket's, the project's
— leave these out; `Forge.Events.archive_reads/1` reads them.

## Not here

Writing to the history. Transcripts, stderr and a chat's own history. Open proposals. Git diffs.
A search or query interface. Another project's history, for any user. An operator page to browse
it, a grammar key to turn it off, a retention rule. Credential and machine identity in `jobs.tsv`.

**A risk named, not closed.** `Archive.start/3` removes and recreates the folder as root, inside a
job directory that the slice has already handed to the job's user. That is exploitable only by a process of
that user which outlived a killed worker and plants a link where the folder goes; nothing looks for
such a process at the worker's start.

## Not verified here

The kernel mount itself: `nix/worker-health` has an item that mounts for a job, looks at the folder as
the job's user, sees a write refused and a read of a file fail as `Connection timed out` (its platform
is a port nothing listens on, so **no successful read through the kernel is checked**), and finds
the mount gone afterwards. It needs KVM and **has not
run** in the environment this was built in; the gate covers the 9P server and the door, not the
kernel's client. The modules are on the image (`9p.ko` and `9pnet_fd.ko` are in the kernel's module
tree on a running worker, 6.18.50); `trans=unix` is an option of `9pnet_fd` and has not been tried
with a mount.
