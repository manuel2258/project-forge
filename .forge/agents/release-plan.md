# Decide the release

Nothing is committed in this state — this is the decision `publishing` carries out, not the
release itself.

**The ticket is the note** the project admin wrote when they started the release from the project
page, and it may be empty. Read it before deciding: it is where they say a bump should be minor
whatever the diff looks like, or that this release is for one fix. Where the note and a rule below
disagree, follow the rule and say in `release-notes.md` what the note asked and why it was not done
— a human approves the document, so that is where the disagreement is decided.

Before deciding anything, invoke `ghcr-check` and `hetzner-check` together, in one batch, so a
human approves `release-notes.md` already knowing whether it can actually be carried out. Read
their logs on resume. A failed `ghcr-check` is fatal — end with `did_not_converge` and say why,
writing no `release-notes.md`. A failed `hetzner-check` is only fatal if the verdict below would
be Required.

**What is being released.** The last release is the last release commit — `chore(release): X.Y.Z`
now, `Version X.Y.Z` up to 0.15.0, and **both patterns are needed** or this finds 0.15.0 for ever
(`CLAUDE.md` § Commit messages):

```
last=$(git log -1 --format=%h --grep='^chore(release): [0-9]' --grep='^Version [0-9]')
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

Write `release-notes.md`, and **start it with front matter naming the version**:

```
---
version: 0.18.0
---
```

That is what renames the ticket from *Release in progress* to the version on every page that lists
it (`docs/design/ticket-types.md` § Releases); a version with no front matter leaves the
placeholder for the ticket's life. Plain `X.Y.Z`, with no `v`. Then the target version and why that
bump, the Hetzner verdict and its reason, and the commit message `publishing` should use — subject **`chore(release): X.Y.Z`**, body
`Since v<last>: …` in prose, the worker protocol line, migrations if any. Earlier ones read
`Version X.Y.Z`; follow their body and not their subject
(`git log --grep '^chore(release): ' --grep '^Version ' -3`), because the subject is the convention
`CLAUDE.md` § Commit messages now sets and the marker the command above looks for. A human
approves this document before anything is built.
