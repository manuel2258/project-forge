# Storage

Scope: the behaviour that holds bytes the database does not — artifact blobs and worker seeds —
and its one PoC implementation, a directory on the platform host served over HTTP by the
platform. The S3-compatible implementation is the closing step's, behind the same behaviour;
nothing above the behaviour may learn which one is installed. `docs/decisions.md` settles this
much; what follows is the shape.

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
(`platform/lib/forge/jobs.ex` `file_hash/1`). The store computes it while writing, so no caller
reads a file twice to hash it.

## Keys

A key is `<prefix>/<rest>`, lowercase, `[a-z0-9._/-]`, no `.` or `..` segment, no leading slash,
at most 512 bytes. The behaviour validates; implementations do not have to. The prefixes:

- `job/<job_id>/<name>` — per-job blobs. Transcripts land here, one per run.
- `seed/<project>/<seed_id>` — worker seeds. `<seed_id>` identifies the contents, not the time:
  see `docs/design/worker-tier.md` § Seed.
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
`%{key: key, op: :get | :put}` and a `max_age` from config (default 15 minutes). It is the first
`Phoenix.Token` in the codebase; the per-job git token (`docs/design/worker-tier.md` § Git token)
is the second and reuses the module.

Three properties this must have, and why:

- **Scoped to one key and one verb.** A token that says "you may read the store" is a token that
  reads every ticket's transcripts. A worker holding a `put` token for its own job's transcript
  cannot overwrite the seed.
- **Short-lived, and minted per assignment.** A job that outlives its tokens asks for new ones
  over the channel rather than holding a long-lived one.
- **Not a bearer of identity.** The token authorises an operation on a key. It says nothing about
  who the worker is; that is the channel's job, and it happened before any token was minted.

A `put` to a key that exists is refused (409). Blobs are immutable — the artifact model says so —
and the store is not the place to discover that a job ran twice.

## The local implementation

`Forge.Storage.Local`, writing under `<data_dir>/store/<key>`, where `data_dir` is the one
`Forge.Jobs.data_dir/0` already returns.

- Writes are to a temporary file in the same directory, then `File.rename/2`. A crash mid-write
  leaves a temp file, never a short object that `stat` would report as whole.
- The key is validated, then the path is built from it and checked to still be under the store
  root, so a key that smuggles a traversal past validation fails twice.
- `delete/1` on a missing key is `:ok`. The caller wanted it gone.
- No fsync. This is a PoC on the operator's machine; a power cut loses the last transcript and
  the ticket's documents are in Postgres.

## What the closing step needs from this

The S3 implementation replaces one module and a config key. It gets `{:file, path}` for the seed
and streams it, gets bytes for a transcript, computes the same hash, and mints its own tokens —
except that it does not, because tokens are the platform's (`Forge.Storage.Token` is not a
callback). A provider that can sign URLs is welcome to; the platform still serves the operator's
blobs itself.

What would break it, and therefore what this note forbids: a `path/1` callback, a caller that
`File.exists?`es a key, a key with a scheme in it, and any assumption that `put` is atomic across
two keys.

## Open

- **Deletion has no policy.** Nothing deletes a transcript or an old seed today. The store grows
  monotonically for the PoC, which is fine on the operator's disk and is not fine on the host.
  Retention lands with the closing step, when there is a bill attached.
- **The seed's transport form is not settled here** — tar versus `btrfs send` stream — because it
  is the worker tier's question. See `docs/design/worker-tier.md` § Seed.
- **No integrity check on read.** `stat` reports the hash the store recorded at write; nothing
  re-reads a blob to confirm it. A local disk that silently rots is out of scope.
