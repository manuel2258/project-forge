# Decide the release

Check credentials before writing anything — a version bumped and then unable to publish is worse
than not starting:

```
auth=$(mktemp); printf '{}' > "$auth"
printf '%s' "$GHCR_TOKEN" | skopeo login --authfile "$auth" -u manuel2258 --password-stdin ghcr.io
rm -f "$auth"
bin/hetzner-image --check
```

Neither secret has a fallback here — unlike a human running the `release` skill by hand, this job
has exactly `GHCR_TOKEN`, `HCLOUD_TOKEN` and `HETZNER_PRIVATE_KEY` from the project's secrets, and
nothing from `gh auth token` or an ssh agent. A failed login ends this job with no changeset: say
why in `release-notes.md` and leave `VERSION` untouched. `bin/hetzner-image --check` failing is
only fatal if its own verdict (next) would be Required.

**What is being released.** The last release is the last `Version` commit:

```
last=$(git log -1 --format=%h --grep='^Version [0-9]')
git log --format='%h %s%n%b' "$last"..HEAD
git diff --stat "$last"..HEAD
```

Nothing after `$last`: end with no changeset and say so in `release-notes.md` — there is nothing
to release, not a failure.

**Decide the bump.** minor (`0.5.0` → `0.6.0`) for anything the operator or a job can see do
something new or different — a feature, a changed behaviour, a migration, a worker protocol
bump. patch (`0.2.0` → `0.2.1`) only when the release fixes what the last one meant to do and adds
nothing. When in doubt, minor.

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
protocol did not), or Not needed (only `platform/`, docs, `bin/` or `measure/` changed). Record it
plainly in `release-notes.md` — `publishing` acts on exactly this word and does not re-derive it.

**Write and commit.** `VERSION` gets the new number; the commit message follows `git log --grep
'^Version' -3` — subject `Version X.Y.Z`, body `Since v<last>: …` in prose, the worker protocol
line, and migrations if any. Produce `release-notes.md` (the bump, why, and the Hetzner verdict
with its reason) and the changeset.
