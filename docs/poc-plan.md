# Proof of concept plan

The PoC has two jobs: put the open questions under real load, and reach a state the operator
actually uses every day. Everything not required for one of those is cut.

The PoC runs entirely on the operator's machine and is independent of any particular real
project. No deployment, no cloud machine, no phone until it concludes: the platform, its
Postgres, the worker VMs and the blob store all run locally, and the demo project is a
small repository kept for the purpose. The real deployment, the cloud driver and the phone
are one step after the last milestone, so that step is the first time the design meets a
network it does not control.

The goal is a functionally minimal platform the operator can then deploy for their own
project, a game. Nothing in the PoC may depend on that project or on its language: the
workload is a parameter (the project's environment, build command and build directory, as
its own workflow and flake declare them), and every measurement and milestone is run against
a small project kept for the purpose.

## Definition of usable

The PoC is done when all of the following hold:

- Ten real tickets on a real project have gone from idea to merged through the platform.
  The project is the operator's choice; forge itself is the default candidate.
- Every human decision on those tickets was taken from the queue page, none from a terminal.
  The phone, and push to it, is verified in the closing step rather than during dogfood.
- No message from the operator was ever silently dropped. Every send has a visible state.
- No job on the worker ever killed another job. Out-of-memory ends one slice, not the machine.
- Every ticket shows total cost, and a spend cap stopped at least one runaway job in testing.
- Each open question has a recorded answer or a recorded reason it is still open, with the
  evidence the PoC produced.

## Technology (PoC-scoped, recorded in decisions.md)

- Elixir throughout. Phoenix + LiveView for the platform. A standalone Elixir release for the
  worker-side agent manager.
- One repository, three Mix projects joined by path dependencies, no umbrella:
  `forge_core` (workflow parser, event schema, artifact types), `forge` (Phoenix platform),
  `forge_worker` (worker release). Each is a Nix-built release.
- Postgres on the orchestrator. Oban for durable background work.
- Worker dials out to the platform over a Phoenix Channel, authenticated by a per-worker token
  injected at creation via cloud-init. Slipstream as the client.
- Git served by the platform over smart HTTP wrapping `git http-backend`; per-job short-lived
  token as the password. Bare repositories on the orchestrator filesystem. SSH for the
  operator only.
- The operator's Claude subscription, as an OAuth token, funds execution. API key billing
  remains a configuration choice but is not compared during the PoC.
- Job isolation on the worker: transient systemd units with MemoryMax and CPUWeight, a fresh
  Unix user per job, environment entered through `nix develop` on the project's flake.
- btrfs subvolumes and snapshots for copy-on-write worktrees and build directories.
- A local VM driver (QEMU, booting the NixOS worker image) as the provider behind the
  driver for the whole PoC. Hetzner arrives in the closing step, as a second driver.
- A storage behaviour for blobs and worker seeds with one implementation for the PoC: a
  directory on the platform host, served over HTTP by the platform. No S3 client and no
  MinIO in the PoC; the S3-compatible implementation (Hetzner Object Storage) is the closing
  step's, behind the same behaviour.

Deferred to the start of the relevant milestone: workflow grammar subset, question block
syntax, Claude Code event schema, Claude Code permission mode inside the slice, push
notification library, operator auth details.

## Quality gate for the PoC's own code

Model fluency in Elixir is good but below Rust. The known failure mode is API drift in
LiveView and less common libraries, not language misunderstanding. Mitigation, applied from
the first commit:

- Every job runs `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict` and `mix test` before committing.
- Dependency versions are pinned. Hexdocs for the pinned versions are checked into the
  repository so agents read them rather than recall them.
- Phoenix generators produce the boilerplate; agents edit generated code rather than write it
  from memory.

## Cut list

Not in the PoC: fan-out and join blocks, experiment mode, presentations, multi-user and roles
beyond the data model, second factor, the analysis agent, a native client, offline compose,
repository mirroring beyond a single push hook. Environment proposals fall out for free: an
agent editing the flake in its worktree is already part of the changeset.

## Phase 0: measurements

All run on the operator's machine. Measurements 1 to 4 gate milestone 3 only. Measurement 5
is skipped by decision and taken as given; dogfooding in milestone 5 observes it instead.

Each measurement is a script that takes a workload as parameters: a repository, the command
that enters its environment (`nix develop .#<env>`), its build command, and the build
directory that command warms. The script is what the PoC keeps; the workload it is first run
on is a sample project with a dependency tree and a heavy build step, chosen for being
representative, not for being the operator's. The same script is run on the operator's
project in the closing step, where its numbers become that deployment's settings.

**M1. Build cache acceptance.** Three variants, each measured as: restore cache into a fresh
worktree, run the build command, count what rebuilt and the wall time against a warm local
build. (a) A build directory produced by a Nix builder from the dependency closure alone,
copied into the worktree. (b) A remote compilation cache where the toolchain has one
(sccache-style) pointed at a cache directory on another volume, cold local disk, populated
cache; what is tested is that a cache made elsewhere transplants. (c) Baseline: a
warm build directory rsynced from a different checkout path, to expose absolute path and
mtime sensitivity. Pass: only the project's own sources rebuild and time is within 2x warm.
Outcome decides the build cache open question and the storage model.

**M2. Copy-on-write divergence.** A btrfs subvolume holding a warm worktree and its build
directory. Snapshot it four times, check out a different realistic branch in each, build.
Record exclusive bytes per snapshot and wall time at 1, 2 and 4 concurrent builds. Pass: four
concurrent builds fit the disk and scale acceptably. Outcome sets agents per worker.

**M3. Peak build memory.** Peak resident memory of the build command, and of its heaviest
step where the toolchain exposes one (the link, for compiled languages), for the project's
debug and release configurations, read from the cgroup's memory peak under a transient
systemd unit. Outcome sets MemoryMax per slice, agents per worker and machine size.

**M4. Worker cold start.** Scripted end to end with a timestamp per phase: create a local VM
from the worker image, cloud-init, worker release connects, Nix store populated from the
binary cache, btrfs seed fetched from the platform's store, first incremental build
completes. Outcome
decides whether destroying the worker is viable and sets the default idle period. The cloud
provider's own machine creation time is added in the closing step, not here.

**M5. Agent output quality.** Skipped by decision. Taken as given that agents, prompted well,
produce bounded, well-formed documents with few good questions. Observed during milestone 5
dogfooding rather than measured up front.

## Milestones

Each milestone ends with a demo. The demo is the acceptance test.

### Milestone 1: core, local, no cloud, no UI

- `forge_core`: parse the workflow file (v1 subset: states, transitions with approve, when
  and max, budgets, limits), validate it, pin it per ticket.
- Ticket statechart persisted in Postgres. Live jobs are supervised processes started from
  rows. Backward transitions are ordinary transitions.
- Job specification: prompt, input manifest pinned by artifact version, environment name,
  commit, budgets, permitted children (empty in v1).
- Claude Code driver: a Port around headless Claude Code with streaming JSON output, events
  normalised into the platform's schema, budget enforcement by turns and cost.
- Artifact store: documents and answers versioned in Postgres, blobs behind the storage
  behaviour, immutable, approval attached to a version.
- Append-only event log. Every mutation writes an event.
- CLI for admitting a ticket, listing the queue, answering a question, approving a version.
- The worker manager runs on the same machine as the platform for this milestone: the
  platform depends on the worker application by path and runs jobs in its own VM. The
  channel between separate processes arrives with milestone 3.

Demo: a ticket runs refine and plan on the demo project, produces two documents, blocks on a
question, is answered from the CLI, continues, and the job view shows the pinned manifest.

Probes: branch granularity (one branch per ticket).

### Milestone 2: human loop

- LiveView queue as the home screen: blocking questions, transition approvals and
  review-ready tickets in one ordered list, answerable in sequence.
- Questions rendered inline in the document next to the passage, options plus default,
  one tap to answer. Answers become versioned, attributed artifacts.
- Message state visible on every send, retried on failure, confirmed on receipt.
- Web push for blocking questions. Everything else digested. Verified on the desktop
  browser, where `localhost` is a secure context; the phone comes in the closing step.
- Ticket timeline view. Job view with pinned manifest. Board view.
- Operator session auth, single user.

Demo: the ticket from milestone 1, driven entirely from the queue page in a browser, with
one blocking question arriving as a push notification.

Probes: question representation under real use, message reliability.

### Milestone 3: worker tier

- Provider driver with one implementation: local VMs (QEMU) created from the worker image
  and destroyed. Nothing outside the driver knows the provider; the Hetzner implementation
  is the closing step's job.
- NixOS worker image: btrfs root, Nix daemon with the binary cache, Claude Code, the worker
  release started by cloud-init with its token. The same image boots locally and, later, on
  the provider.
- Worker connects out over a channel. Platform schedules a job only when its slice fits the
  remaining memory budget.
- Per-job transient systemd unit, Unix user, MemoryMax and CPUWeight from measurements.
- Worktree and build directory snapshotted from a warm seed. Seed fetched from the platform's
  store at cold start, using whichever cache form measurement 1 chose.
- Per-job git token, short-lived, scoped to the ticket branch.
- Idle destroy after a configurable period, default from measurement 4.
- Job commits and hibernates on interruption; resume reconstructs from branch and manifest.
  Conversation resume attempted when cheap, never required.

Demo: implement and verify states run on a fresh local worker VM for the demo project, two
tickets in parallel, one deliberately exhausting memory, the other finishing untouched.
Worker destroyed after idle, recreated on the next ticket.

Probes: idle period, sandbox platform question (only reopened if this milestone fails),
build cache in practice.

### Milestone 4: git and merge

- Platform-hosted bare repositories over smart HTTP. Hooks enforce branch discipline.
- Merge approval as a state: diff alongside the verification report, the documents the change
  was built from, the questions answered and total cost.
- Post-receive mirror to another repository (a local bare one is enough to prove the hook).
- Spend caps per ticket and per day, enforced by the platform.

Demo: a ticket from idea to merged, entirely from the queue page, mirrored.

### Milestone 5: dogfood

Two weeks of real tickets on a real project, still on the operator's machine with local
worker VMs. Fix what breaks. Record cost, timing, retries and backward transitions per ticket
so the analysis agent has data later. Ends when the definition of usable is met.

### Closing step: deployment, cloud, phone

After the PoC has concluded on evidence, and only then:

- The platform on a host with the NixOS module, TLS in front, secrets outside the store.
- The Hetzner driver as the second provider implementation; the cloud's own machine creation
  time added to measurement 4.
- The S3 implementation of the storage behaviour (Hetzner Object Storage) as the durable
  layer for seeds and blobs, so they survive the platform host.
- The phone: push subscribed on the real origin, one blocking question answered from the
  lock screen, message state observed on a phone network.
- The real project moved onto the host; the mirror pointed at its external home.

Demo: the milestone 4 demo again, from the phone, on the host.

## How each open question is probed

| Open question | Where | What the PoC records |
|---|---|---|
| Which credential funds execution | Settled for the PoC: the operator's subscription token. Reopened only for team use | Limits hit and cost visibility on the subscription token, as they occur |
| Structured question representation | Milestone 2 | Parse failures, answer taps per question, cases the format could not express |
| Worker idle period | Measurement 4, milestone 3 | Cold start time, idle time distribution across real tickets, cost of idle versus recreate |
| Branch granularity | Milestone 1 onward | Conflicts and rebases per ticket with one branch per ticket; whether any sequential job needed its own branch |
| Reproducible build cache | Measurement 1 | Which variant passed, rebuild counts and times |
| Adopt an existing sandbox platform | Milestone 3 | Whether the thin version (systemd plus btrfs) held; evaluation of alternatives only if it did not |

## Risks

- **Agent output sprawls.** The largest risk. Accepted without up-front measurement by
  decision; first observed in milestone 1 output and formally during dogfooding.
- **The local VM is not the cloud machine.** Cold start, disk and network differ. Accepted:
  the PoC settles the design, the closing step measures the provider's constants.
- **Cache does not transplant.** If every variant in measurement 1 fails, the seed becomes a
  maintained btrfs blob kept in the store. The design survives; the storage model gets
  heavier.
- **Model fluency in Elixir.** Mitigated by the quality gate above. Expect the first
  milestone to be slower than the estimate while the guardrails settle.
- **Nix packaging of Mix releases.** Known friction. Spike it in the first week of milestone
  1, not at deployment time.
- **LiveView is not offline.** Accepted for the PoC. Message state and retries cover the
  original failure; offline compose comes later with a small JS layer.
