# project-forge

A self-hosted platform that moves software tickets through a per-repository, statechart-defined lifecycle, executed by disposable agent jobs on an elastic worker tier. Verified, immutable, versioned artifacts are the handoff contract between steps, and the operator's attention is treated as the scarce resource: nothing reaches them until it has been verified, and what does reach them arrives as an ordered queue of decisions.

The concept is described in full in [docs/vision.md](docs/vision.md). Settled decisions, open questions, required measurements and prior-art findings are recorded alongside it in `docs/`. The proof-of-concept plan is [docs/poc-plan.md](docs/poc-plan.md), and the design notes it calls for are in [docs/design/](docs/design/).

**Status:** milestones 1, 3 and 4 of the [PoC plan](docs/poc-plan.md) are complete. Milestone 2 is built, but its demo is not: web push has never been exercised, so no blocking question has yet arrived as a notification ([docs/open-questions.md](docs/open-questions.md) § Message reliability). The platform runs no jobs itself: they run on worker machines it creates from templates and destroys, or on ones provisioned by hand. The stack is Elixir, with Phoenix and LiveView for the platform and a standalone Elixir release for the worker; further PoC-scoped choices are listed in [docs/decisions.md](docs/decisions.md). Part of the closing step arrived early: a NixOS module and a container image ([docs/deploy.md](docs/deploy.md)), and a Hetzner driver that has created and destroyed real machines but has not yet had one connect to a platform and run a job. Running on a host, backups and the phone remain.

## Layout

| Directory | Mix app | Purpose |
|---|---|---|
| `core/` | `forge_core` | Workflow parser, event schema, artifact types. Shared by path dependency. |
| `platform/` | `forge` | Phoenix + LiveView platform: orchestrator, artifact store, queue UI. |
| `worker/` | `forge_worker` | Standalone release for the worker-side agent manager. |
| `measure/` | — | The measurement harness behind `bin/measure`. Bash, not a Mix project. |

## Getting started

Requires Nix with flakes. Postgres is included in the devshell; point `platform/config/dev.exs` at whichever instance you run.

```
nix develop            # or `direnv allow`
bin/check              # quality gate: shell lint, then compile, format, credo, tests
cd platform && mix setup && mix phx.server
```

Releases build with `nix build .#forge` and `nix build .#forge-worker`; on Linux,
`.#platform-image` is the platform's container image and `.#worker-image` (x86_64 only) the
machine a worker boots. `bin/release` publishes the first ([docs/deploy.md](docs/deploy.md)).

`bin/measure` is the measurement harness for the worker tier (`docs/measurements.md`). It
runs outside the quality gate, in `nix develop .#measure`, because it needs btrfs, systemd
and root; `bin/measure selftest` exercises it without any of them.

## Driving a ticket

Run the node with `mix phx.server`; it serves the pages at `http://localhost:4000` (queue at
`/`, board at `/board`, tickets at `/tickets/<project>/<n>`, chats at `/chats`) and schedules
pending jobs. Log in with a user created from the command line; browser registration is off.

**Nothing runs without a worker.** A job goes to a connected worker that can take it, or to a
machine made from a worker template assigned to its project (`/templates` for yours, `/workers`
for the machines); with neither, the ticket sticks and says so. A `local` template boots
`nix build .#worker-image` under QEMU, with `FORGE_WORKER_IMAGE` naming the qcow2 it builds. See
[docs/design/worker-tier.md](docs/design/worker-tier.md) and
[docs/design/provisioning.md](docs/design/provisioning.md).

The same operations are available as a JSON API under `/api/v1` with a bearer token, see
`docs/design/api-and-ui.md` for the routes:

```
mix forge.token you@example.com --name laptop     # prints the token once
curl -H "Authorization: Bearer $TOKEN" http://localhost:4000/api/v1/queue
mix forge.token.list you@example.com              # names, not tokens
mix forge.token.revoke you@example.com laptop
```

Repositories are served over smart HTTP at `/git/<project>.git` with a short-lived per-job token
as the password; hooks enforce one branch per ticket and mirror the default branch. See
[docs/design/git-hosting.md](docs/design/git-hosting.md).

And as Mix tasks that write rows:

```
mix forge.user.add you@example.com 'a long password' --node-admin   # the first account
mix forge.project.add game /srv/git/game.git      # bare repo; you administer it
mix forge.project.add game /srv/git/game.git --owner you@example.com   # when several admins exist
mix forge.project.mirror game backup https://github.com/you/game.git --user you --token TOKEN
                        # mirrors need the repository at $FORGE_REPOS_DIR/<name>.git, where the
                        # web page puts a project; one added at another path cannot have them
mix forge.git.token game --ticket 1               # a clone URL with a short-lived credential
mix forge.admit game "Persist the high score table" --body-file ticket.md
mix forge.queue                                   # questions, approvals, stuck, review
mix forge.show game#1                             # state, jobs, artifacts, events
mix forge.answer game#1 storage-backend --choice sqlite
mix forge.approve game#1 [--reject --comment "..."]
mix forge.transition game#1 implementing       # human states and stuck tickets
mix forge.edit game#1 plan.md plan.md             # a human edit is a new version
mix forge.chat open game "what is this repo?"     # a conversation; also show, and say/close --node
mix forge.seed.publish game ~/seeds/game          # the warm clone workers start from
mix forge.worker.new game --out worker.env        # a worker you boot yourself; never swept
mix forge.worker.list                             # and forge.worker.retire ID to end one
```

`bin/worker-update` ships a new worker release to a running machine without rebuilding its
image, through the machine's ssh door, which is shut by default.

Push notifications for blocking questions need VAPID keys once: run
`mix generate.vapid.keys` and set `FORGE_VAPID_PUBLIC_KEY`, `FORGE_VAPID_PRIVATE_KEY` and
`FORGE_VAPID_SUBJECT` for the node; then tap "Notify me" on the queue page in each browser.
A conversation's reply pushes when it completes; everything else goes into one daily digest
push.

Jobs run Claude Code headless on a credential its owner added in `/users/settings` and assigned
to the job's project; the node's own `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are not
read (`docs/design/credentials.md`). By default `FORGE_DATA_DIR` holds the store, the local
driver's machines and git's scratch files. On a worker, `FORGE_NIX_ENV` (on unless set
otherwise) wraps each job in the project's `nix develop .#<env>`.

