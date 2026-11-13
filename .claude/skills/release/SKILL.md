---
name: release
description: Cut a forge release from main without stopping to ask — decide the version bump, write the changelog section, bump VERSION, build and push the platform image and the worker image it is built knowing with bin/release. Run by the land skill after every landing.
---

# release

A release is a `chore(release): X.Y.Z` commit on `main` that changes `VERSION` and files the
release's section of the changelog (`platform/priv/changelog.md`) and nothing else,
and the platform image at `ghcr.io/manuel2258/forge:X.Y.Z` — which
`ghcr.io/manuel2258/forge:latest` then names too. There is no git tag: the release commit marks a
release in git, and `bin/release` refuses a version the registry already holds, which is what the
tag used to enforce. (Releases up to 0.7.0 also carry a `vX.Y.Z` tag.)

**The subject changed at 0.16.0**, from `Version X.Y.Z` to the conventional form (`CLAUDE.md`
§ Commit messages). Every search for the last release therefore carries both patterns, and
dropping the old one would make every release after the first conventional one diff from 0.15.0.

`bin/release` does the build and the push of both images; this skill decides what goes into
`VERSION` first. **It builds no Hetzner snapshot**: the platform builds one in each account that
needs it, from the worker image this release publishes (`docs/design/provisioning.md` § Putting the
release's image into an account), so no Hetzner token or ssh key is needed here.

**It runs unattended.** The `land` skill runs it after every landing, and the human's request to
land is the request to release: nothing below waits for a yes. It stops and reports only when
something goes wrong — a precondition that does not hold, a credential that is missing or refused,
a push that is rejected, a build that fails, a digest that does not match. Stopping is always
safe: every step is either re-runnable or leaves `main` in a state the next run picks up.

## Preconditions

- Asked for: by the human directly, or by `land` after a landing the human asked for. Never on
  the agent's own initiative.
- The work is landed: `main` equal to `origin/main` after `git fetch origin main`, the working
  tree clean. Work that is not landed is not released — land it first (`land`).
- `bin/check` passes on this commit. After a landing it just did; do not run it twice.

## Setup

Everything the release runs — `skopeo`, `oras`, the build — comes from the devshell. The only
thing installed by hand is Nix itself, and only on a machine that lacks it (a fresh cloud
session):

```
curl -sSfL https://install.determinate.systems/nix | sh -s -- install linux --init none --no-confirm --prefer-upstream-nix
export PATH=/nix/var/nix/profiles/default/bin:$PATH
nix --version
```

An "unable to parse existing receipt" error from the installer is harmless when `nix --version`
then works: Nix was already there. Then run every command below, step 0 included, inside the
devshell — `nix develop --command bash` for a shell, or prefix a command with
`nix develop --command` — and not `apt-get install skopeo`. Behind a TLS-intercepting proxy, also
`export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` (step 6).

## Steps

0. **Check the credentials, before anything is written.** A release that pushes its version
   commit and then cannot publish is the half-done state this avoids.

   - **GitHub** (the image push). The token is `GHCR_TOKEN`, else `GITHUB_TOKEN`, else
     `gh auth token` — the order `bin/release` uses. Prove it can log in to the registry, into a
     throwaway authfile so nothing is stored:

     ```
     token=${GHCR_TOKEN:-${GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}}
     auth=$(mktemp); printf '{}' > "$auth"
     printf '%s' "$token" | skopeo login --authfile "$auth" -u manuel2258 --password-stdin ghcr.io
     rm -f "$auth"
     ```

     No token, or a refused login: **stop before step 1** and report that the landing is on
     `main` and unreleased, and why. Never print the token.

   - **The worker image's package is public.** `bin/release` pushes the worker image to
     `ghcr.io/manuel2258/forge-worker-image` before the platform image, and a builder server in
     someone else's Hetzner account downloads it without credentials, so the package must be made
     public once, by hand on GitHub (package settings → change visibility). Until then no account can
     build and every job that needs a build waits with *this release's worker image is not published, or not
     downloadable without a login*; that is a degraded release and not a failed one, and step 10 says so. It cannot be
     checked from here with the release's token, so say it in the report the first time.

   - **Branch.** `bin/release` refuses anything but `main`. From a working branch:
     `git switch main && git merge --ff-only origin/main`. Remember the working branch for
     step 9.

1. **What is being released.** The last release is the last release commit, matched on both
   subjects — multiple `--grep` are OR'd and the parentheses are literal in git's default basic
   regex:

   ```
   last=$(git log -1 --format=%h --grep='^chore(release): [0-9]' --grep='^Version [0-9]')
   git log --format='%h %s%n%b' "$last"..HEAD
   git diff --stat "$last"..HEAD
   ```

   **A version committed and never published comes first.** If the registry does not hold
   `:$(cat VERSION)` — a run that stopped after step 5, say on a refused push — that version is
   not released yet: skip steps 2 to 5 and publish it at step 6, from `main` as it is now, so what
   landed since rides with it. Ask with `skopeo inspect --authfile "$auth"
   docker://ghcr.io/manuel2258/forge:$(cat VERSION)`; `manifest unknown` means not published.

   If there is nothing after `$last` and its version is published, stop and say so — that is not
   an error, and `land` reports it as "nothing to release".

2. **Decide the bump.** forge is `0.x`, and has been bumped like this so far:

   - **minor** (`0.5.0` → `0.6.0`) when anything the operator or a job can see does something new
     or different: a feature, a changed behaviour, a new migration, a worker protocol bump.
   - **patch** (`0.2.0` → `0.2.1`) when the release only fixes what the last one meant to do
     and adds nothing.

   A migration or a protocol bump is never a patch. When in doubt between the two, it is
   minor: a patch that should have been a minor misleads, the other way round only wastes a
   number. Check both:

   ```
   git diff --name-only "$last"..HEAD -- platform/priv/repo/migrations
   git diff "$last"..HEAD -- core/priv/worker_protocol core/lib/forge_core/worker_protocol.ex
   ```

3. **Decide how much a new worker image matters.** Nothing is built for it here — each account
   builds its own when a template naming `latest` next needs a machine — but the verdict tells the
   operator what to expect. A managed machine boots the snapshot its
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

4. **Write the message.** Subject `chore(release): X.Y.Z`, body `Since v<last>: …` — what changed
   for the operator, in prose, not a list of commits — then the worker protocol (unchanged at N,
   or bumped to N) and whether there are migrations. The body follows the earlier ones
   (`git log --grep '^chore(release): ' --grep '^Version ' -3`); their subject does not, being
   pre-0.16.0. Keep the attribution trailers the session requires. Nobody approves it; write it
   as if someone will read it in `git log` a year from now, because that is who reads it.

4a. **Write the changelog section** — the release's section of the changelog every hosted
   project's agent reads, by `docs/design/changelog.md` § Writing a section: over the same
   `$last..HEAD` range, from the surfaces it lists, leaving out what only concerns running a node.
   It starts `## X.Y.Z` and is a section even when nothing in the range concerns projects (then
   it is the heading and *Nothing for projects in this release.*). Write it to a scratch file, for
   example `/tmp/changelog-section.md`. It is step 4a, not 5, so that the steps other places name
   by number stay as they are. **No release reaches `main` without one**:
   `Forge.ChangelogTest` fails when the newest section is not the version `VERSION` names.

5. **Bump and push.**

   ```
   printf '%s\n' X.Y.Z > VERSION
   bin/changelog-add /tmp/changelog-section.md    # files it above the newest section
   git add VERSION platform/priv/changelog.md
   git commit            # the message from step 4
   git push origin main
   ```

   Never `--force`. If the push is rejected, `main` moved: reset the version commit away
   (`git reset --hard origin/main`) and go back to step 1 — once. A second rejection means
   someone else is landing; stop and report.

6. **Build and publish the worker image and the platform image.**

   ```
   bin/release
   ```

   It refuses a dirty tree or a version the registry already holds, then builds
   `.#worker-image-release` and pushes it with `oras` to `ghcr.io/manuel2258/forge-worker-image:X.Y.Z`
   (refusing a tag that already holds a different digest, and checking the digest it reads back).
   Only then does it build `.#platform-image`, which is built knowing that image's checksum, and copy
   it to the registry with skopeo — no Docker daemon — as `:X.Y.Z`, then copy that to `:latest`
   inside the registry, so both name one digest. The token comes from `GHCR_TOKEN`, else
   `GITHUB_TOKEN`, else `gh auth token`. The build is long; run it in the background and wait for
   it. If it fails, fix the cause and run it again: **a failed run can leave the worker image
   published without the platform**, which is harmless — nothing refers to it until the platform
   that knows its checksum is — and the next run finds it already there with the same digest and
   goes on; a run that copied `:X.Y.Z` and stopped before `:latest` is finished by running it
   again.

   **Behind a TLS-intercepting proxy** — a cloud session's — the build's fixed-output fetchers
   (the mix dependencies, some from git) need the proxy's CA, and they see only what Nix binds
   into their sandbox: export `NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` before
   `bin/release`, when that system bundle carries the proxy's CA. A path elsewhere, such as the
   proxy's own bundle, does not exist inside the sandbox and the fetch fails on the certificate.

7. **Check the digest.** `:latest` must name what `bin/release` printed:

   ```
   skopeo inspect --creds "manuel2258:$token" --format '{{.Digest}}' \
     docker://ghcr.io/manuel2258/forge:latest
   ```

   A different digest is a failure: stop and report both.

8. **Nothing to build.** `bin/release` published the worker image at step 6, before the platform,
   and the platform was built knowing its checksum. Accounts get their snapshot from the platform, on demand;
   a template naming a fixed snapshot is the operator's, as before. If step 3 said **Required**,
   the new platform refuses old snapshots, and the first job on `latest` in each account starts
   a build (jobs wait with a reason meanwhile).

9. **Back to the working branch**, if step 0 left one, onto the new `main`:

   ```
   git switch <working branch>
   git reset --hard origin/main
   git push --force-with-lease origin HEAD
   ```

10. **Report**, in one message: the version and why that bump; the digest
    (`ghcr.io/manuel2258/forge@sha256:…`, what a deployment pins) and that `:latest` names it;
    the worker image (`ghcr.io/manuel2258/forge-worker-image@sha256:…`, from `bin/release`'s
    output), step 3's verdict and its reason, and, the first time, the reminder that its package
    must be public.
