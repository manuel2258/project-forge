---
name: release
description: Cut a forge release from main without stopping to ask — decide the version bump, bump VERSION, build and push the platform image with bin/release, and build the Hetzner worker snapshot when the worker changed. Run by the land skill after every landing.
---

# release

A release is a `Version X.Y.Z` commit on `main` that changes `VERSION` and nothing else, and the
platform image at `ghcr.io/manuel2258/forge:X.Y.Z` — which `ghcr.io/manuel2258/forge:latest` then
names too. There is no git tag: the `Version` commit marks a release in git, and `bin/release`
refuses a version the registry already holds, which is what the tag used to enforce. (Releases up
to 0.7.0 also carry a `vX.Y.Z` tag.) `bin/release` does the build and the push; this skill decides
what goes into `VERSION` first and, when the worker changed, builds the Hetzner snapshot with
`bin/hetzner-image`.

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

Everything the release runs — `skopeo`, `hcloud`, the build — comes from the devshell. The only
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

   - **Hetzner** (the snapshot, only if step 3 asks for one — check here anyway, so the answer is
     known before the version commit). `HCLOUD_TOKEN` set, and the project answers with at least
     one ssh key, which `bin/hetzner-image` needs for rescue:

     ```
     hcloud ssh-key list -o noheader -o columns=name | head -n1
     ```

     Unset, refused, or no key: the release goes ahead without a snapshot; step 10 says the
     snapshot was not built and why, and gives the command. That is a degraded release, not a
     failed one — unless the verdict is **Required** (run step 3's check now to know), when the
     new platform refuses every existing worker: then **stop before step 1**, because publishing `:latest` without a snapshot it can
     talk to would strand every job on the node.

   - **Branch.** `bin/release` refuses anything but `main`. From a working branch:
     `git switch main && git merge --ff-only origin/main`. Remember the working branch for
     step 9.

1. **What is being released.** The last release is the last `Version` commit:

   ```
   last=$(git log -1 --format=%h --grep='^Version [0-9]')
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

4. **Write the message.** It follows the earlier ones (`git log --grep '^Version' -3`): subject
   `Version X.Y.Z`, body `Since v<last>: …` — what changed for the operator, in prose, not a list
   of commits — then the worker protocol (unchanged at N, or bumped to N) and whether there are
   migrations. Keep the attribution trailers the session requires. Nobody approves it; write it
   as if someone will read it in `git log` a year from now, because that is who reads it.

5. **Bump and push.**

   ```
   printf '%s\n' X.Y.Z > VERSION
   git add VERSION
   git commit            # the message from step 4
   git push origin main
   ```

   Never `--force`. If the push is rejected, `main` moved: reset the version commit away
   (`git reset --hard origin/main`) and go back to step 1 — once. A second rejection means
   someone else is landing; stop and report.

6. **Build and publish the platform image.**

   ```
   bin/release
   ```

   It refuses a dirty tree or a version the registry already holds, builds `.#platform-image`
   and copies it to the registry with skopeo — no Docker daemon — as `:X.Y.Z`, then copies that
   to `:latest` inside the registry, so both name one digest. The token comes from `GHCR_TOKEN`,
   else `GITHUB_TOKEN`, else `gh auth token`. The build is long; run it in the background and
   wait for it. If it fails, fix the cause and run it again: nothing reaches the registry before
   the first copy, and a run that copied `:X.Y.Z` and stopped before `:latest` is finished by
   running it again.

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

8. **Build the snapshot, when step 3 said Required or Recommended** and step 0 found Hetzner
   usable. Not for **Not needed**. From this commit, so the snapshot is labelled with this
   release's build, and after the image is published (for Required, the platform goes first):

   ```
   bin/hetzner-image --name forge-worker-X.Y.Z
   ```

   It creates a rescue server, writes the image, verifies it, snapshots and deletes the server —
   a few minutes of one machine, then a snapshot costing cents a month. It is long: run it in the
   background and wait. It cleans up its server on any exit; if it fails, check with
   `hcloud server list` that no `forge-image-builder-*` is left, delete one that is, and report
   the failure with the command to run again. Do not retry it unattended — a second run is a
   second server.

   It does not move any template onto the snapshot. That is the operator's, on `/templates`,
   because it changes what their machines boot and spends their provider credential.

9. **Back to the working branch**, if step 0 left one, onto the new `main`:

   ```
   git switch <working branch>
   git reset --hard origin/main
   git push --force-with-lease origin HEAD
   ```

10. **Report**, in one message: the version and why that bump; the digest
    (`ghcr.io/manuel2258/forge@sha256:…`, what a deployment pins) and that `:latest` names it;
    the Hetzner verdict and its reason, and either the snapshot's name, build and protocol as
    `bin/hetzner-image` printed them — with the reminder to point the templates at it on
    `/templates` — or why it was not built and the command to build it.
