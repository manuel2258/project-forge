# Decide the release

Nothing is committed in this state — this is the decision `publishing` carries out, not the
release itself.

Before deciding anything, invoke `ghcr-check` and `hetzner-check` together, in one batch, so a
human approves `release-notes.md` already knowing whether it can actually be carried out. Read
their logs on resume. A failed `ghcr-check` is fatal — end with `did_not_converge` and say why,
writing no `release-notes.md`. A failed `hetzner-check` is only fatal if the verdict below would
be Required.

**What is being released.** The last release is the last `Version` commit:

```
last=$(git log -1 --format=%h --grep='^Version [0-9]')
git log --format='%h %s%n%b' "$last"..HEAD
git diff --stat "$last"..HEAD
```

Nothing after `$last`: there is nothing to release. End with `did_not_converge` and say so — not
a failure, just nothing for this ticket to do.

**Decide the bump.** minor (`0.5.0` → `0.6.0`) for anything the operator or a job can see do
something new or different — a feature, a changed behaviour, a migration, a worker protocol
bump. patch (`0.2.0` → `0.2.1`) only when the release fixes what the last one meant to do and
adds nothing. When in doubt, minor.

```
git diff --name-only "$last"..HEAD -- platform/priv/repo/migrations
git diff "$last"..HEAD -- core/priv/worker_protocol core/lib/forge_core/worker_protocol.ex
```

**Decide the Hetzner verdict**, the same way the `release` skill does:

```
git diff --stat "$last"..HEAD -- worker core nix/worker-image.nix flake.nix flake.lock \
  docs/design/workflow-grammar-v1.md
```

Required (the protocol moved or its minimum rose), Recommended (worker-side code changed but the
protocol did not), or Not needed (only `platform/`, docs, `bin/` or `measure/` changed).

Write `release-notes.md`: the target version and why that bump, the Hetzner verdict and its
reason, and the commit message `publishing` should use (subject `Version X.Y.Z`, body
`Since v<last>: …` in prose, the worker protocol line, migrations if any — following
`git log --grep '^Version' -3`). A human approves this document before anything is built.
