# Storage

Scope: the behaviour that holds bytes the database does not — artifact blobs and worker seeds —
and its one PoC implementation, a directory on the platform host served over HTTP by the
platform. A second, S3-compatible implementation would go behind the same behaviour; nothing
above the behaviour may learn which one is installed, and § What would move this to S3 says why
writing one is not scheduled. `docs/decisions.md` settles this much; what follows is the shape.

Two things force a behaviour now rather than later. The worker stops sharing a filesystem with
the platform in milestone 3, so `file:///…/transcript-1.jsonl` stops being a thing the platform
can read. And the seed — after M1, a maintained warm build directory rather than a reproducible
Nix artefact (`docs/measurements.md` § M1) — is hundreds of megabytes that has to reach a cold
worker from somewhere.

## The behaviour

`Forge.Storage`, selected by `config :forge, Forge.Storage, impl: …`, as
`Forge.Push.Sender` already is.

```
@callback put(key, {:file, path} | iodata, opts) :: {:ok, %{size: integer, hash: String.t()}} | {:error, term}
@callback get(key) :: {:ok, binary} | {:error, :not_found | term}
@callback fetch(key, path) :: {:ok, %{size: integer, hash: String.t()}} | {:error, :not_found | term}
@callback stat(key) :: {:ok, %{size: integer, hash: String.t()}} | {:error, :not_found}
@callback delete(key) :: :ok | {:error, term}
```

**Both a byte form and a path form, deliberately.** A transcript is a few hundred kilobytes and
wants `get/1`; a seed is hundreds of megabytes and must never pass through a BEAM binary. `put`
takes `{:file, path}` for the same reason on the way in. An implementation that can only do one
of the two is not an implementation of this behaviour.

**No `path/1` callback, ever.** The temptation is obvious — the local implementation *has* a
path, and a caller with a path can `File.stream!` it — and it is exactly the callback that makes
the S3 implementation impossible and reintroduces the milestone-1 assumption that platform and
worker share a disk. Callers get bytes, a file they named, or a URL.

**`hash` is `sha256:<hex>`**, the form `artifact_version.content_hash` already carries
(`Forge.Storage.hash/1`). The store computes it while writing, so no caller
reads a file twice to hash it.

## Keys

A key is `<prefix>/<rest>`, lowercase, `[a-z0-9._/-]`, no `.` or `..` segment, no leading slash,
at most 512 bytes. The behaviour validates; implementations do not have to. The prefixes:

- `job/<job_id>/<name>` — per-job blobs. Transcripts land here, one per run.
- `seed/<project>/<seed_id>` — worker seeds. `<seed_id>` identifies the contents, not the time:
  see `docs/design/worker-tier.md` § Volumes and the seed.
- `artifact/<sha256>` — content-addressed blobs an artifact version points at that are not tied
  to one job.

Keys are opaque above `Forge.Storage.Key`, which builds them. Nothing parses a key to recover a
job id; the database already knows.

## How an artifact version points at a blob

`artifact_version.blob_uri` gains one scheme: `store:<key>`. `git:<sha>` is unchanged.

**`file://` rows are read, never written.** `artifact_version` is append-only, enforced by a
database trigger (`platform/priv/repo/migrations/20260911201840_create_artifact_versions.exs`),
so a migration that rewrote milestone-1 rows to `store:` keys would have to drop the trigger to
do it. It is not worth it: the reader understands both schemes, `file://` means "written before
the worker moved off this host", and the set of such rows only ever shrinks. New versions are
always `store:`.

## Serving

Two doors, because there are two audiences and only one of them has a session.

**The operator** reads a blob through the existing authenticated routes. The platform reads it
from the store and serves the bytes. Not a redirect to the store, and never a provider-signed
link: `docs/decisions.md` puts blobs behind the platform so that what the operator can see stays
the platform's decision.

**The worker** has no session. It gets a short-lived token, minted by the platform and carried in
the job assignment (`docs/design/worker-channel.md`), and calls `GET`/`PUT /store/:key`.

The token is `Phoenix.Token.sign/4` over the endpoint's `secret_key_base`, with
`%{key: key, op: :get | :put}` and a `max_age` from config (default 15 minutes). It is the only
`Phoenix.Token` in the codebase. The per-job git token was expected to be the second and is not:
it is 32 random bytes stored as a sha256 hash in `git_tokens`, with the mechanics of
`Forge.Accounts.UserToken`. It is revoked when its job ends and its rows are the audit trail, and a
signed token offers neither (`docs/design/git-hosting.md` § The per-job token).

Three properties this must have, and why:

- **Scoped to one key and one verb.** A token that says "you may read the store" is a token that
  reads every ticket's transcripts. A worker holding a `put` token for its own job's transcript
  cannot overwrite the seed.
- **Short-lived, minted per assignment, and sized to their use.** The lifetime is signed into the
  token (`Forge.Storage.Token.sign/3`), so a verifier does not apply one number to all of them.
  Most live `token_max_age`, fifteen minutes. The transcript `put` is minted at assignment and
  used when the job stops, and between the two lie the job's preparation as well as its wall
  clock: the worker starts the clock only once the clone and the seed are ready
  (`ForgeWorker.Link`'s `prepare_and_run/3`, and `ForgeWorker.Job.Conversation` for a chat), so
  a slow first seed fetch is time the clock never sees. So it lives the wall clock, plus a
  preparation margin — `preparation_margin_ms` under `config :forge, Forge.Jobs`, an hour — plus
  the ordinary fifteen minutes: two hours and a quarter for a workflow job, twenty-five hours and
  a quarter for a conversation. At a flat fifteen minutes every transcript of a longer job was
  refused as `expired_token`, and at the clock alone so was that of any job whose preparation
  outran the fifteen minutes. A conversation's `history` tokens — a `get` for each earlier
  transcript on its ticket (`Conversations.history/1`) — are read only once the worktree is
  prepared, so they carry the same margin over the ordinary fifteen minutes; the seed's `get` is
  spent as preparation begins and does not. The hour is a generous guess rather than a
  measurement. M4's 35-second cold start is not the figure for it: most of that is booting the
  machine and populating its Nix store, and neither is inside the window — a machine is up before
  it is assigned anything, and the runner enters the project's environment after the clock has
  started. What is inside it is the seed fetched and unpacked, which M4 put at 3.3 seconds for
  192 MiB over loopback, and the fetch of the branch into the snapshot, which it did not time. A
  provider's network makes the seed slower by an amount nobody has measured, and a project with no
  seed is cloned whole, which nobody has timed either. The per-job git token already had the same
  room — it outlives the clock by `git_token_ttl_minutes`, ninety minutes
  (`docs/design/git-hosting.md` § The per-job token). Refreshing tokens over the channel was the
  first plan and is not built; one key and one verb for the life of one job is a small grant.
- **Not a bearer of identity.** The token authorises an operation on a key. It says nothing about
  who the worker is; that is the channel's job, and it happened before any token was minted.

A `put` to a key that exists is refused (409). Blobs are immutable — the artifact model says so —
and the store is not the place to discover that a job ran twice.

## The local implementation

`Forge.Storage.Local`, writing under `<root>/<key>`, where the root (`Forge.Storage.Local.root/0`)
is the `:dir` of `config :forge, Forge.Storage`: `FORGE_STORE_DIR` when it is set, and otherwise
`store/` under `FORGE_DATA_DIR` (default `tmp/forge`), beside the rest of the platform's data.

- Writes are to a temporary file in the same directory, then `File.rename/2`. A crash mid-write
  leaves a temp file, never a short object that `stat` would report as whole.
- The key is validated, then the path is built from it and checked to still be under the store
  root, so a key that smuggles a traversal past validation fails twice.
- `delete/1` on a missing key is `:ok`. The caller wanted it gone.
- No fsync. This is a PoC on the operator's machine; a power cut loses the last transcript and
  the ticket's documents are in Postgres.

## What would move this to S3

**Durability is not it, and that is the change of mind.** This note and the plan both said the
closing step would swap in an S3 implementation "so seeds and blobs survive the platform host".
A bucket does not deliver that on its own: `artifact_version.blob_uri` is the only mapping from a
key to what it means, and § Keys makes keys opaque on purpose, so a store that outlives its
database is bytes with no names. Of the three things a host holds that must survive it — Postgres,
the bare repositories, the store — this is the most replaceable: a seed is a warm build directory
a job can rebuild, and a transcript is history rather than state the platform runs on. The
repositories have the mirror; Postgres has nothing; one backup covers all three. So the answer to
"it does not survive the host" is a backup, and `docs/decisions.md` records that.

Two things would change it, and both are measurable rather than arguable:

- **The host's disk becomes the binding constraint.** § Open says nothing deletes a transcript or
  an old seed, and seeds are hundreds of megabytes per project. Local means the ceiling is the
  host's disk, so the number to watch is the store's size against it. Retention is the cheaper
  answer first; a bucket is the answer when retention is not enough.
- **The store has to outlive the host it sits on** — a platform that is rebuilt, containerised or
  moved often enough that restoring a directory from a backup is the thing that hurts.

When one of them bites, the implementation replaces one module and a config key. It gets
`{:file, path}` for the seed and streams it, gets bytes for a transcript, computes the same hash,
and mints its own tokens — except that it does not, because tokens are the platform's
(`Forge.Storage.Token` is not a callback). A provider that can sign URLs is welcome to; the
platform still serves the operator's blobs itself.

What would break it, and therefore what this note forbids: a `path/1` callback, a caller that
`File.exists?`es a key, a key with a scheme in it, and any assumption that `put` is atomic across
two keys.

## Open

- **Deletion has no policy.** Nothing deletes a transcript or an old seed today. The store grows
  monotonically for the PoC, which is fine on the operator's disk and is not fine on the host.
  Retention lands with the closing step, when there is a bill attached.
- **The seed's transport form is not settled here**, because it is the worker tier's question —
  and it has settled it: a compressed tar, not a `btrfs send` stream. See
  `docs/design/worker-tier.md` § Volumes and the seed.
- **No integrity check on read.** `stat` reports the hash the store recorded at write; nothing
  re-reads a blob to confirm it. A local disk that silently rots is out of scope.

## The token is a header

A store token goes in `Authorization: Bearer <token>`, never in the query string, for the reason
`docs/design/worker-channel.md` § Authentication gives at greater length: a URL is recorded by
every proxy and access log on the path, and a request header is not.

It matters less here than it does for the channel — a store token is scoped to one key and one
verb and most expire in minutes — but the two are minted by the same platform and read by the same
worker, and having one rule instead of two is worth more than the minutes of exposure it saves.
