# Decisions

These decisions are settled. They are not to be reopened.

## Purpose and framing

- The scarce resource is the operator's attention, not compute and not model quota. Every design decision follows from this.
- Nothing reaches the operator until it has been verified.
- The platform is self-hosted.

## Lifecycle

- A ticket moves through a statechart, not a linear pipeline. Backward transitions are normal, not exceptional.
- Every project defines its own lifecycle in a definition file committed to that repository. The engine has no built-in default lifecycle.
- The workflow definition is pinned per ticket at admission.
- Approval requirements are declared per transition, and only on some transitions.
- Sub-structure within a state (fan-out and join) is declared as named, reusable blocks.
- An agent may spawn children only from an explicitly permitted set — bounded choice.
- A subagent is an ordinary job: same specification, isolation, artifacts and record.
- **Any job and any conversation may propose a ticket; none may create one.** A proposal is a
  document a person accepts or declines, and accepting calls the ordinary admission, pinning the
  workflow at that moment rather than when it was proposed. An agent's write scope is its own
  ticket; beyond it, it can only speak. See `design/ticket-proposals.md`.
- **Every job is handed the project's tickets and its open proposals**, as a snapshot composed
  when the job is assigned with its hash recorded. It is the one input that is not pinned to a
  version, because a generated index has no version to pin. Bodies only: another ticket's
  artifacts are pinned to jobs that are not this one.

## Jobs

- A job receives an immutable specification: prompt, inputs pinned by version, environment, commit, budgets, permitted children.
- Jobs are disposable. Anything that must survive is committed to the job's branch or written to the artifact store. Nothing else exists.
- A job commits its work before hibernating. History is squashed.
- Resuming the agent's own conversation is an optimisation, never a dependency. Artifacts are the contract.
- A job waiting on a human holds no process and no machine, so waiting is free.

## Artifacts and the human loop

- Artifacts live in the platform's own store, not in git. Code is git's job.
- Artifacts are immutable and versioned. Approval attaches to a specific version. Human edits produce a new version like any other.
- Three kinds: documents (the contract between steps, approvable), blobs (behind a storage behaviour, referenced by URI), presentations (rich, human-only, never consumed downstream).
- Blobs are served to the operator through the platform, not via provider-specific signed links.
- Questions are embedded in the document, next to the passage they concern, with a small set of options and a recommended default.
- Non-blocking questions state the assumption taken and let work continue. Blocking questions stop the job until answered — no timeout, no automatic fallback.
- Answers are their own versioned, attributed artifact.

## Environments and experiments

- Job environments are declared declaratively, in-repo, per job type, using Nix.
- Agents may modify their own environment during a job. The change is job-local and becomes a reviewable proposal for the shared definition, never a mutation of shared machine state.
- The same applies to workflow structure.
- A job may request an experiment state permitting environment and workflow modification. Experiments always require human approval, requested through the same interruption mechanism as any other blocking question.
- Promotion of an experiment result into the shared definition is a separate human approval.
- Approval gates, budgets, spawn permissions and depth limits are never modifiable in any mode.

## Execution

- Three tiers: a small always-on orchestrator, one large worker created on demand, and a durable store for blobs and seeds (object storage once deployed).
- The orchestrator holds the state machine, event log, artifact store, git, credentials and the web application. It compiles nothing.
- The worker hosts all agents for a session and is destroyed after a configurable idle period.
- Each job runs in its own resource-limited slice: hard memory ceiling so an out-of-memory build kills one job rather than the machine, and proportional CPU sharing so agents idle on inference donate capacity to whoever is compiling.
- Each job gets its own worktree and its own build directory, cloned from a warm seed using filesystem-level copy-on-write.
- No attached block volume, therefore no single-writer constraint.
- Provider-specific surface is confined to a driver. Hetzner is the first cloud target, after the PoC; nothing in the design may assume it. The PoC's provider is a local VM driver.

## Git

- The platform hosts its own repositories. Merge approval is a state in the machine.
- Repositories mirror to an external host so one machine is never the only copy.

## Interface

- A mobile-first web application; a native client is possible later. The API is the product surface.
- The home screen is a queue, not a dashboard: blocking questions, transition approvals, experiment requests, promotion decisions and review-ready tickets in one ordered list, answerable in sequence.
- Push notification for blocking questions and for a conversation's completed replies; everything
  else digested. *The conversation half widens an earlier decision: a reply to a question you
  asked is the same shape of thing as an answer you are owed. See `docs/design/conversations.md`
  § In the queue, and on the phone.*
- Additional views: ticket timeline, job view showing the pinned input manifest, board, and merge approval showing the diff alongside the verification report, the documents the change was built from, the questions answered, and total cost.
- Live output is shown where the operator is waiting for it — a conversation's reply, and a
  running job's stream — and nowhere else. *Reverses an earlier decision ("there is no live
  transcript view"), which generalised a true point about unattended work into a ban on live
  output as such. `docs/design/ui.md` § Motion and structure carries the distinction.*
- Ticket proposals are digested, never queued: the queue is what will not move until a person
  acts, and a proposal blocks nothing.
- Message delivery must be visibly reliable: message state shown, sends retried, answers composed offline and synced. A silently dropped message must be impossible.

## Security and users

- Proportionate and well designed: sessions, second factor available but not mandatory, all mutations audited into the event log, provider tokens confined to the orchestrator, short-lived scoped credentials per job, spend caps.
- Single operator today, but users and roles are in the data model from the start so team use is an expansion rather than a rewrite.

## Harnesses

- Claude Code is the first execution harness, not an assumption. Agent events are normalised into the platform's own schema at the driver boundary.
- Capabilities that differ between harnesses — conversation resumption, permission prompting — are declared, and both are already optional in the design.

## Analysis

- An optional, offline, propose-only analysis job may read the event log and propose workflow or environment changes. It runs no experiments, changes nothing, has no elevated permissions, and its proposals go through the normal approval path.

## Technology (decided for the proof of concept)

Settled for the project:

- Elixir throughout.
- Phoenix with LiveView for the platform.
- A standalone Elixir release for the worker-side agent manager.

Settled for the PoC, reversible afterwards on evidence from it (see `poc-plan.md`):

- One repository, three Mix projects joined by path dependencies, no umbrella: `forge_core`, `forge`, `forge_worker`.
- Postgres on the orchestrator. Oban for durable background work.
- Worker dials out over a Phoenix Channel, authenticated by a per-worker token injected at creation.
- Git served by the platform over smart HTTP with a per-job short-lived token. SSH for the operator only.
- The operator's Claude subscription (OAuth token) funds execution. API key billing remains a configuration choice; the comparison is not run.
- Job isolation by transient systemd units with memory and CPU limits, a Unix user per job, environment via `nix develop`.
- btrfs for copy-on-write worktrees and build directories.
- A local VM driver behind the provider driver for the PoC; Hetzner as the second implementation in the closing step.
- A storage behaviour for blobs and worker seeds, like the provider driver: one implementation in the PoC, a directory on the platform host served over HTTP by the platform; the S3-compatible implementation arrives in the closing step. No S3 client and no MinIO during the PoC.
- The PoC's goal is a functionally minimal platform the operator then deploys for their own project (a game); nothing in it may depend on that project or its language. The workload is a parameter: environment, build command and build directory come from the project's own workflow and flake.
- The PoC runs entirely on the operator's machine and is independent of any particular real project. No deployment, no cloud machine, no phone until it concludes; those are one closing step after the last milestone.
