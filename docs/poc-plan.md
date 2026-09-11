# Proof of concept plan

The PoC has two jobs: put the open questions under real load, and reach a state the operator
actually uses every day. Everything not required for one of those is cut.

## Definition of usable

The PoC is done when all of the following hold:

- Ten real tickets on the Bevy project have gone from idea to merged through the platform.
- Every human decision on those tickets was taken from the phone, none from a terminal.
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
- API key billing by default. Subscription authentication is a comparison experiment.
- Job isolation on the worker: transient systemd units with MemoryMax and CPUWeight, a fresh
  Unix user per job, environment entered through `nix develop` on the project's flake.
- btrfs subvolumes and snapshots for copy-on-write worktrees and build directories.
- Hetzner as the provider behind the driver. Hetzner Object Storage (S3 API) as the durable
  layer; MinIO for local development.

Deferred to the start of the relevant milestone: workflow grammar subset, question block
syntax, Claude Code event schema, Claude Code permission mode inside the slice, push
notification library, object storage client, operator auth details.

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

All run on the existing machine. Measurements 1 to 4 gate milestone 3 only. Measurement 5 is
skipped by decision and taken as given; dogfooding in milestone 5 observes it instead.

**M1. Build cache acceptance.** Three variants, each measured as: restore cache into a fresh
worktree, run `cargo build`, count recompiled crates and wall time against a warm local build.
(a) A `target/` produced by a Nix builder (crane-style dependency artifacts) copied into the
worktree. (b) sccache with an S3 backend, cold local disk, populated remote cache.
(c) Baseline: a warm `target/` rsynced from a different checkout path, to expose absolute path
and mtime sensitivity. Pass: only workspace crates rebuild and time is within 2x warm.
Outcome decides the build cache open question and the storage model.

**M2. Copy-on-write divergence.** A btrfs subvolume holding a warm worktree and `target/`.
Snapshot it four times, check out a different realistic branch in each, build. Record
exclusive bytes per snapshot and wall time at 1, 2 and 4 concurrent builds. Pass: four
concurrent builds fit the disk and scale acceptably. Outcome sets agents per worker.

**M3. Link peak memory.** Peak resident memory of the link step for dev and release profiles,
with the default linker and with mold, read from the cgroup's memory peak under a transient
systemd unit. Outcome sets MemoryMax per slice, agents per worker and machine size.

**M4. Worker cold start.** Scripted end to end with a timestamp per phase: create server from
snapshot image, cloud-init, worker release connects, Nix store populated from the binary
cache, btrfs seed restored from object storage, first incremental build completes. Outcome
decides whether destroying the worker is viable and sets the default idle period.

**M5. Agent output quality.** Skipped by decision. Taken as given that agents, prompted well,
produce bounded, well-formed documents with few good questions. Observed during milestone 5
dogfooding rather than measured up front.

## Milestones

Each milestone ends with a demo. The demo is the acceptance test.

### Milestone 1: core, on the existing VPS, no cloud, no UI

- `forge_core`: parse the workflow file (v1 subset: states, transitions with approve, when
  and max, budgets, limits), validate it, pin it per ticket.
- Ticket statechart persisted in Postgres. Live jobs are supervised processes started from
  rows. Backward transitions are ordinary transitions.
- Job specification: prompt, input manifest pinned by artifact version, environment name,
  commit, budgets, permitted children (empty in v1).
- Claude Code driver: a Port around headless Claude Code with streaming JSON output, events
  normalised into the platform's schema, budget enforcement by turns and cost.
- Artifact store: documents and answers versioned in Postgres, blobs in object storage,
  immutable, approval attached to a version.
- Append-only event log. Every mutation writes an event.
- CLI for admitting a ticket, listing the queue, answering a question, approving a version.
- The worker manager runs on the same machine as the platform for this milestone.

Demo: a ticket runs refine and plan on the Bevy project, produces two documents, blocks on a
question, is answered from the CLI, continues, and the job view shows the pinned manifest.

Probes: branch granularity (one branch per ticket), the credential comparison (same tickets
on API key and subscription token, compare limits, cost visibility and failure modes).

### Milestone 2: human loop

- LiveView queue as the home screen: blocking questions, transition approvals and
  review-ready tickets in one ordered list, answerable in sequence.
- Questions rendered inline in the document next to the passage, options plus default,
  one tap to answer. Answers become versioned, attributed artifacts.
- Message state visible on every send, retried on failure, confirmed on receipt.
- Web push for blocking questions. Everything else digested.
- Ticket timeline view. Job view with pinned manifest. Board view.
- Operator session auth, single user.

Demo: the ticket from milestone 1, driven entirely from a phone, including one push
notification answered from a lock screen.

Probes: question representation under real use, message reliability.

### Milestone 3: worker tier

- Hetzner driver: create machine from image, destroy, object storage endpoint. Nothing
  outside the driver knows the provider.
- NixOS worker image: btrfs root, Nix daemon with the binary cache, Claude Code, the worker
  release started by cloud-init with its token.
- Worker connects out over a channel. Platform schedules a job only when its slice fits the
  remaining memory budget.
- Per-job transient systemd unit, Unix user, MemoryMax and CPUWeight from measurements.
- Worktree and build directory snapshotted from a warm seed. Seed restored from object storage
  at cold start, using whichever cache form measurement 1 chose.
- Per-job git token, short-lived, scoped to the ticket branch.
- Idle destroy after a configurable period, default from measurement 4.
- Job commits and hibernates on interruption; resume reconstructs from branch and manifest.
  Conversation resume attempted when cheap, never required.

Demo: implement and verify states run on a fresh worker for the Bevy project, two tickets in
parallel, one deliberately exhausting memory, the other finishing untouched. Worker destroyed
after idle, recreated on the next ticket.

Probes: idle period, sandbox platform question (only reopened if this milestone fails),
build cache in practice.

### Milestone 4: git and merge

- Platform-hosted bare repositories over smart HTTP. Hooks enforce branch discipline.
- Merge approval as a state: diff alongside the verification report, the documents the change
  was built from, the questions answered and total cost.
- Post-receive mirror to an external host.
- Spend caps per ticket and per day, enforced by the platform.

Demo: a ticket from idea to merged, entirely from the phone, mirrored externally.

### Milestone 5: dogfood

Two weeks of real tickets on the Bevy project. Fix what breaks. Record cost, timing, retries
and backward transitions per ticket so the analysis agent has data later. Ends when the
definition of usable is met.

## How each open question is probed

| Open question | Where | What the PoC records |
|---|---|---|
| Which credential funds execution | Milestone 1 | Same tickets on both credentials: limits hit, cost visibility, failure modes, terms of use for each |
| Structured question representation | Milestone 2 | Parse failures, answer taps per question, cases the format could not express |
| Worker idle period | Measurement 4, milestone 3 | Cold start time, idle time distribution across real tickets, cost of idle versus recreate |
| Branch granularity | Milestone 1 onward | Conflicts and rebases per ticket with one branch per ticket; whether any sequential job needed its own branch |
| Reproducible build cache | Measurement 1 | Which variant passed, rebuild counts and times |
| Adopt an existing sandbox platform | Milestone 3 | Whether the thin version (systemd plus btrfs) held; evaluation of alternatives only if it did not |

## Risks

- **Agent output sprawls.** The largest risk. Accepted without up-front measurement by
  decision; first observed in milestone 1 output and formally during dogfooding.
- **Cache does not transplant.** If every variant in measurement 1 fails, the seed becomes a
  maintained btrfs blob synced to object storage. The design survives; the storage model gets
  heavier.
- **Model fluency in Elixir.** Mitigated by the quality gate above. Expect the first
  milestone to be slower than the estimate while the guardrails settle.
- **Nix packaging of Mix releases.** Known friction. Spike it in the first week of milestone
  1, not at deployment time.
- **LiveView is not offline.** Accepted for the PoC. Message state and retries cover the
  original failure; offline compose comes later with a small JS layer.
