---
name: release
description: Cut a forge release from main — decide the version bump, say whether a new Hetzner worker snapshot is needed, bump VERSION, then build and push the platform image with bin/release.
---

# release

A release is a `Version X.Y.Z` commit on `main` that changes `VERSION` and nothing else, the
`vX.Y.Z` tag on it, and the platform image at `ghcr.io/manuel2258/forge:X.Y.Z` — which
`ghcr.io/manuel2258/forge:latest` then names too. `bin/release`
does the tag, the build and the push; this skill decides what goes into `VERSION` first and says
what the release means for the worker snapshots.

## Preconditions

- **A human asked for this release.** It writes to `main`, pushes a tag and publishes an image.
- On `main`, the working tree clean, and `main` equal to `origin/main` after
  `git fetch origin main`. Work that is not landed is not released — land it first (`land`).
- `bin/check` passes on this commit.

## Steps

1. **What is being released.**

   ```
   last=$(git describe --tags --abbrev=0)
   git log --format='%h %s%n%b' "$last"..HEAD
   git diff --stat "$last"..HEAD
   ```

   If there is nothing after `$last`, stop and say so.

2. **Decide the bump.** forge is `0.x`, and has been bumped like this so far:

   - **minor** (`0.5.0` → `0.6.0`) when anything the operator or a job can see does something new
     or different: a feature, a changed behaviour, a new migration, a worker protocol bump.
   - **patch** (`0.2.0` → `0.2.1`) when the release only fixes what the last one meant to do
     and adds nothing.

   A migration or a protocol bump is never a patch. Check both:

   ```
   git diff --name-only "$last"..HEAD -- platform/priv/repo/migrations
   git diff "$last"..HEAD -- core/priv/worker_protocol core/lib/forge_core/worker_protocol.ex
   ```

3. **Decide whether a new Hetzner snapshot is needed.** A managed machine boots the snapshot its
   template names and runs the worker release baked into it. What the platform checks at the join
   is the protocol (`docs/design/worker-channel.md` § Versions); what `/templates` compares is the
   build label. The build always changes with a release, because every `mix.exs` reads `VERSION`
   — so "the label no longer matches" is not the question. The question is what the worker does.

   ```
   git diff --stat "$last"..HEAD -- worker core nix/worker-image.nix flake.nix flake.lock \
     docs/design/workflow-grammar-v1.md
   ```

   Say one of three things, with the reason:

   - **Required** — `core/priv/worker_protocol` moved, or `@minimum` in
     `ForgeCore.WorkerProtocol` rose above what the current snapshot speaks. A platform built from
     this refuses (minimum) or cannot use (current) the old snapshot's worker. Deploy the
     platform first, then the snapshot (§ What needs a bump, and raising the minimum).
   - **Recommended** — the protocol is unchanged but worker-side code changed: `worker/`, `core/`
     (including `core/priv/*.md`, which a job is handed), `nix/worker-image.nix`, or a
     `flake.nix`/`flake.lock` change that reaches the worker image rather than only the devshell
     or the platform. Old machines keep working and keep running the old worker code. Name what
     they would miss.
   - **Not needed** — only `platform/`, docs, `bin/` or `measure/` changed. `/templates` will show
     the snapshot's build as not current; that is the version string, not behaviour.

4. **Propose, and wait.** Put to the human, in one message: the version, why that bump, the
   Hetzner verdict and its reason, and the draft commit message. Proceed only on their yes; take
   their version if they give another.

   The message follows the earlier ones (`git log --grep '^Version' -3`): subject `Version X.Y.Z`,
   body `Since v<last>: …` — what changed for the operator, in prose, not a list of commits — then
   the worker protocol (unchanged at N, or bumped to N) and whether there are migrations. Keep
   the attribution trailers the session requires.

5. **Bump and push.**

   ```
   printf '%s\n' X.Y.Z > VERSION
   git add VERSION
   git commit            # the message agreed in step 4
   git push origin main
   ```

   Never `--force`. If the push is rejected, `main` moved: stop and go back to step 1.

6. **Build and publish the platform image.**

   ```
   bin/release
   ```

   It refuses a dirty tree or a tag that names another commit, tags `vX.Y.Z`, pushes the tag,
   builds `.#platform-image` and copies it to the registry with skopeo — no Docker daemon — as
   `:X.Y.Z`, then copies that to `:latest` inside the registry, so both name one digest. The
   token comes from `GHCR_TOKEN`, else `gh auth token`. The build is long; run it in the
   background and wait for it. If it fails after the tag was pushed, fix the cause and run it
   again: a tag that already names HEAD is a re-run and fine.

7. **Report** the version, the digest `bin/release` printed (`ghcr.io/manuel2258/forge@sha256:…`,
   what a deployment pins), that `:latest` now names it, and the Hetzner verdict again. Check
   the last with `skopeo inspect --format '{{.Digest}}' docker://ghcr.io/manuel2258/forge:latest`
   (with `--creds` from `gh auth token` if the package is private); it must print the same digest. When a snapshot is required or
   recommended, give the command and do not run it — it creates and pays for a Hetzner server,
   and needs the human's `HCLOUD_TOKEN`:

   ```
   HCLOUD_TOKEN=… bin/hetzner-image
   ```

   Run from this commit, so the snapshot is labelled with this release's build. Then the
   template has to be pointed at the new snapshot on `/templates`.
