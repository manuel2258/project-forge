# Decisions

These decisions are settled. They are not to be reopened.

## Purpose and framing

- The scarce resource is the operator's attention, not compute and not model quota. Every design decision follows from this.
- Nothing reaches the operator until it has been verified.
- The platform is self-hosted.

## Lifecycle

- A ticket moves through a statechart, not a linear pipeline. Backward transitions are normal, not exceptional.
- Every project defines its own lifecycle in a definition file committed to that repository. The engine has no built-in default lifecycle. *Widened to one or more: a project may declare ticket types, one workflow file per type under `.forge/workflows/`, and a ticket's type is chosen at admission and pinned with its workflow; there is no default type (`design/ticket-types.md`).*
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
- A job commits its work before hibernating, when its state declares a `changeset`. A state
  that declares none has a scratch tree and commits nothing, ever. History is squashed.
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

- Three tiers: a small always-on orchestrator, workers created on demand, and a durable store for blobs and seeds. *Two things here changed. The worker tier was one large machine and is plural: a worker template says what machine to make, how many may exist (`max_workers`), how long one may idle and which job kinds it takes (`design/provisioning.md`). And the store was to become object storage once deployed; it is a directory on the platform host and object storage is not planned (§ Technology, below).*
- The orchestrator holds the state machine, event log, artifact store, git, credentials and the web application. It compiles nothing.
- A worker hosts several agents at once and is destroyed after a configurable idle period — its template's, or the node's when the template names none. *It goes only once nothing has a claim on it — a job parked on it within its commands' timeouts, or one that last ran on it just back in the queue. On a provider that bills every started hour the period is the least it is kept: it goes at the leeway point before an hour it has paid for ends, and only if nothing claimed it then (`design/worker-tier.md` § The hour already paid for).*
- Each job runs in its own resource-limited slice: hard memory ceiling so an out-of-memory build kills one job rather than the machine, and proportional CPU sharing so agents idle on inference donate capacity to whoever is compiling.
- Each job gets its own worktree and its own build directory, cloned from a warm seed using filesystem-level copy-on-write.
- No attached block volume, therefore no single-writer constraint.
- Provider-specific surface is confined to a driver. Hetzner is the first cloud target, after the PoC; nothing in the design may assume it. The PoC's provider is a local VM driver.

## Git

- The platform hosts its own repositories. Merge approval is a state in the machine.
- Repositories mirror to an external host so one machine is never the only copy.

## Interface

- A mobile-first web application; a native client is possible later. The API is the product surface.
- The home screen is a queue, not a dashboard: blocking questions, transition approvals, experiment requests, promotion decisions and review-ready tickets in one ordered list, answerable in sequence. *Widened: beneath those and beneath the digest, in its own group that counts towards nothing and is never pushed, the queue also shows a ticket whose current job is running on a worker or still waiting to start — read from the `Job.status` and `worker_id` the row already carries, no new data, and never a ticket a pause is holding (`docs/design/ui.md` § A job waiting for a machine). A decision is still the only thing in the queue that carries a mark or a count.*
- Push notification for everything that starts waiting on a human — a blocking question, an
  approval, a stuck ticket, a ticket ready for review, a conversation's completed reply — and
  nothing else; assumptions and the rest are digested. The rule is the queue's own
  `waiting?/1`. *Widens an earlier decision twice: first for a conversation's replies, a reply to a
  question you asked being the same shape of thing as an answer you are owed
  (`docs/design/conversations.md` § In the queue, and on the phone); then to every waiting kind,
  once the phone became a client the operator develops from rather than an inbox for questions.
  See `docs/design/ui.md` § The phone.*
- Additional views: ticket timeline, job view showing the pinned input manifest, board, and merge approval showing the diff alongside the verification report, the documents the change was built from, the questions answered, and total cost.
- Live output is shown on a page about one piece of work that the operator has opened — a
  conversation's reply and tool calls, a ticket's running job, a job's stream — and never on a
  list, board or queue. *Reverses an earlier decision ("there is no live transcript view"), which
  generalised a true point about unattended work into a ban on live output as such, and then
  narrows its first replacement ("where the operator is waiting for it") from who is waiting to
  who is looking. `docs/design/ui.md` § Motion and structure carries the distinction.*
- Ticket proposals are digested, never queued: the queue's decisions are what will not move until
  a person acts, and a proposal blocks nothing. *The queue also serves open non-blocking
  questions, beneath its decisions and in no count of what is waiting (`docs/design/ui.md` § Not
  waiting on you); a proposal is not among them, and is decided on the project page.*
- Message delivery must be visibly reliable: message state shown, sends retried, answers composed offline and synced. A silently dropped message must be impossible.

## Security and users

- Proportionate and well designed: sessions, second factor available but not mandatory, all mutations audited into the event log, provider tokens confined to the orchestrator, short-lived scoped credentials per job, spend caps.
- Single operator today, but users and roles are in the data model from the start so team use is an expansion rather than a rewrite.
- **Authentication is local accounts and OIDC, both first class.** More than one issuer may be
  configured. A local account is also the recovery path: a self-hosted platform whose only door
  is an external IdP is bricked by a bad redirect URI.
- **An OIDC login provisions a user on the spot** — no prior row, no invitation, no linking
  step. Identity is `(issuer, subject)`, never email; the same person arriving through two
  issuers is two users, deliberately.
- **An account that arrives through a login page is pending until a node admin approves it.**
  Approval is the perimeter, which is what lets everything behind it be permissive. Only an OIDC
  first login creates one: browser registration is off, a magic link goes only to an address that
  already has an account, and an account made on the host (`Forge.Release.create_operator/3`,
  `mix forge.user.add`) is approved outright. *This said "local and OIDC alike"; no local login
  creates an account.*
- **`node_admin` is account governance and nothing else**: approve, suspend, promote. Seeded on
  the host. It grants no access to any project. It is the only global role.
- **Authorization is per project.** `project_member` with two roles: `admin` (settings, delete,
  membership) and `member` (everything else the product does). Any approved user may register a
  project and becomes its admin. There are no invitations — an admin adds an existing user.
- **No authorisation decision compares a role name**, it asks for a capability, so splitting the
  two roles later changes one function rather than every call site. Counting admins and ordering
  them for display do read the name; neither decides access.
- **Every human write is guarded in a context, never by the page that calls it.** `Forge.Operator`
  holds the ticket, conversation and project-settings actions; `Forge.Projects` holds the
  membership ones, because they are about that table. A hidden button is not a guard, and the
  mutation that tests one of these rules deletes the check in the context.
- **Forge never reads an IdP claim to decide access.** Membership derived from a claim is revoked
  only at the next login, and a role changed at the IdP is a change to who can spend money here
  that leaves no trace in the event log.
- **Reads are membership-scoped**, not only mutations: queue (page and API), board, project and
  ticket lists, `/tickets/new`, artifacts, conversations — both the list and the page — push
  fan-out, and the event log, which gains a `project_id` because it could not otherwise answer
  the question. A suspended account receives no push.
- **A project always has an owner.** `Projects.register/2` refuses a nil one rather than creating
  a project with no members, which is invisible to everyone including node admins. The command
  line resolves one with `Accounts.owner_for/1` and `Forge.Release.add_member/3` is the repair
  path, since a project with no admins has nobody for the product's own page to act through.
- **A user owns credentials; a credential is a subscription token or an API key**, one type
  covering both because the harness already takes that union. This answers which credential funds
  execution for team use: each person brings their own, so individual-use licensing is respected.
- **A credential's daily limit is tracked, not enforced.** The ticket allowance and the node-wide
  daily cap are untouched and keep enforcing.
- **A job holds the credential, not the machine.** A job picks one from its project's pool when it
  starts and the credential travels with the assignment, so a project can pool several tokens and
  a machine is not tied to one account or one harness. A credential's owner assigns it to projects
  they are a member of; nobody else can. The node's own `ANTHROPIC_API_KEY` and
  `CLAUDE_CODE_OAUTH_TOKEN` stop being read — neither fallback nor seed. See
  `design/credentials.md`.
- **A job picks the credential that has spent least today among those not rate-limited, and keeps
  it while it is not limited.** The oldest wins a tie. A job whose own credential is limited moves
  to a free one; a pool that is all limited leaves the job pending and the ticket active until the
  earliest reset, because time resolves it and nobody is being asked for anything.
- **A job stopped by its credential's limit mid-run is not failed.** It goes back to pending with
  its session, lets its machine go, and resumes — on another credential at once if one is free,
  on its own after the reset if not. Spend is recorded per run, so a job that moved is on each
  credential's figure for what it spent there. See `design/credentials.md`.
- **A user owns workers; its owner assigns it to projects they are a member of.** A project admin
  cannot reach for someone else's machine, because the machine is paid for by its owner. A machine
  made from a template reaches the projects its template is assigned to, read at placement. A job
  runs only on a worker assigned to its project.
- **A project's secrets are the project's, written by its admins and named by every member.**
  Nobody reads a value back. The platform never uses one; it carries it to the jobs that list it.
- **The workflow is the access list for jobs.** A job state or a command names the secrets it
  receives, and a ticket entering that state gets them; the secret itself carries no rule about
  where it may go. A conversation's secrets are picked by the person opening it, so every project
  secret is readable by every member. Delivered values are masked in what the worker uploads where
  that is easy — the exact value and its JSON-escaped form — and nothing more is claimed. See
  `design/secrets.md`.

See `design/identity.md`.

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
- Postgres on the orchestrator. Durable background work is rows in Postgres: a job is a row, `Forge.Jobs.Scheduler` (one GenServer) hands pending ones out, and `Forge.Jobs.recover/0` re-queues on boot the workflow jobs a previous node left running on a machine that is gone, and leaves the rest to their machines' rejoins (`design/worker-channel.md` § A platform restart). *This said "Oban for durable background work"; Oban was never added.*
- Worker dials out over a Phoenix Channel, authenticated by a per-worker token injected at creation.
- Git served by the platform over smart HTTP with a per-job short-lived token. No SSH: the operator reaches a repository over the same endpoint, with a token they mint — including the one shape that may write the default branch, fast-forward only, which is what seeds a repository and changes a workflow (`design/git-hosting.md` § The default-branch token, and what it costs).
- The operator's Claude subscription (OAuth token) funds execution. API key billing remains a configuration choice; the comparison is not run.
- Job isolation by transient systemd units with memory and CPU limits, a Unix user per job, environment via `nix develop`.
- btrfs for copy-on-write worktrees and build directories.
- A local VM driver behind the provider driver for the PoC; Hetzner as the second implementation in the closing step. **The Hetzner driver is written and has created and destroyed real Hetzner machines; no Hetzner worker has yet connected to a platform and run a job**, so what the closing step still owes the driver is that, not an implementation. Which driver speaks for a machine is resolved per machine from the row rather than per node from configuration (`docs/design/provisioning.md`), which is what a fleet spanning two providers needs and what one global `impl` prevented.
- A storage behaviour for blobs and worker seeds, like the provider driver: one implementation, a directory on the platform host served over HTTP by the platform. No S3 client and no MinIO.
- **Object storage is not a precondition for deploying, and the closing step no longer carries it.** The case for it was durability — "so seeds and blobs survive the platform host" — and durability is not what a bucket buys on its own. `artifact_version.blob_uri` is the only thing that maps a key to meaning and keys are opaque by design, so blobs that outlive the database are bytes with no names; of the three things the host holds that must survive it — Postgres, the bare repositories, the store — the store is the most replaceable (a seed is a warm build directory a job can rebuild) and the only one a bucket would cover, while the repositories already have the mirror and Postgres has nothing. One backup covers all three. What would move the decision is the host's disk becoming the binding constraint, or the store having to outlive the host it sits on; `design/storage.md` § What would move this to S3. The behaviour is what keeps that cheap: a second implementation is a module and a config key.
- The PoC's goal is a functionally minimal platform the operator then deploys for their own project (a game); nothing in it may depend on that project or its language. The workload is a parameter: environment, build command and build directory come from the project's own workflow and flake.
- The PoC runs entirely on the operator's machine and is independent of any particular real project. No deployment, no cloud machine, no phone until it concludes; those are one closing step after the last milestone. *Overtaken in part: the deployment path and the Hetzner driver were built without waiting for milestone 5, and `poc-plan.md` § Closing step says which parts of that step remain.*
