# RFC: A self-hosted platform for supervised autonomous coding

**Status:** concept pitch — vision only, no implementation phasing
**Author:** Manu
**Date:** September 2026

---

## The problem

Autonomous coding agents work. Supervising them doesn't.

Today: a VPS runs Claude Code, reachable from the phone. Two things break it. The chat
client silently drops input messages, so a remote session is unreliable in exactly the
moment it should be useful. And several agents compiling a Bevy workspace on one small box
exhaust cores, RAM and disk until the OOM killer starts picking victims — the agents don't
fail, they kill each other.

Both are symptoms of the same gap: there is no system between the person and the agents.
No queue, no isolation, no record of what was decided, no way to approve a step from a
train platform. The agent is powerful; the harness around it is a terminal.

The scarce resource in this setup is not compute, and not model quota. It is **the
operator's attention**. Every design decision below follows from that.

---

## What this is

A self-hosted platform where a ticket moves through a defined lifecycle, each step executed
by an agent in an isolated environment, with every input, output and decision recorded and
inspectable, and with the human interrupted only where a human decision is actually
required.

It is not an IDE and not a chat client. It is a dispatcher, an artifact store, and an
approval queue.

---

## Principles

**Attention is the budget.** Nothing reaches the operator until it is verified. Interruptions
are batched, one-tap where possible, and always carry the context needed to answer them.

**Artifacts are the contract.** State passes between steps as documents, not as conversation
history. Documents are reviewable; transcripts are not.

**Nothing implicit.** A job sees exactly the inputs declared for it, pinned to exact
versions. "What was this built on?" always has one answer.

**Agents may experiment, never widen their own envelope.** Environment and workflow are
declared and versioned. An agent can propose changes to either; it cannot grant itself
permission.

**Portable by construction.** One provider is the test target; nothing in the design assumes
that provider.

---

## The ticket lifecycle

A ticket is a statechart, not a linear pipeline. The forward path (idea → refining → planning
→ implementing → verifying → review-ready → merged) is the easy part; the backward edges —
replanning when implementation invalidates a plan, splitting, blocking — are where the
design lives.

### Every project defines its own workflow

There is no built-in lifecycle. States, transitions, approval requirements, budgets, prompts
and permitted sub-structure are **declared in a definition file committed to each
repository**, versioned with the code it governs and pinned per ticket at admission. A game
written in Rust and a small web service will not want the same lifecycle, and neither should
have to accept one imposed by the platform. The engine executes whatever the project
declares; it has no opinion of its own.

The closest existing model is **GitLab CI**: a file in the repo, edited by the same people
through the same review process, defining stages and what runs in them. Several other
borrowings are deliberate. From **GitHub Actions**, reusable blocks referenced by name rather
than copied. From **statecharts** (XState and its lineage), nesting, parallel regions and
guarded transitions — because a ticket that fails verification must go *backwards*, and a CI
pipeline is a one-way graph that cannot express that. From **durable workflow engines** like
Temporal, execution that survives the process running it, which is what makes a job able to
wait indefinitely on a human answer at no cost.

The important departure from CI: a job's result is not pass or fail. An agent that tried and
did not converge is a different outcome from one that ran out of budget, and both are
different from a failing test. Retrying is not "the same inputs again" — it is another
attempt. The vocabulary is CI's; the semantics are not.

A rough sketch of what a project's file might look like:

```yaml
version: 1

states:
  refining:
    prompt: agents/refine.md
    env: refine                    # devshell name from the project's flake
    inputs: [ticket]
    produces: refinement.md
    budget: { turns: 20, cost: 0.50 }

  planning:
    prompt: agents/plan.md
    env: implement
    inputs: [ticket, refinement.md]
    use: compare-drafts            # reusable block, below
    produces: plan.md

  implementing:
    prompt: agents/implement.md
    env: implement
    inputs: [plan.md]
    can_spawn: [self-review]       # bounded choice: agent decides if and how often
    produces: [changeset, env-proposal.nix?]

  verifying:
    prompt: agents/verify.md
    env: release
    inputs: [plan.md, changeset]
    produces: [report.md, report.html]   # document + presentation

blocks:
  compare-drafts:
    fanout: { type: plan-draft, count: 2 }
    join:   { type: plan-compare }

transitions:
  - from: refining     to: planning       approve: [refinement.md]
  - from: planning     to: implementing                     # no approval
  - from: implementing to: verifying
  - from: verifying    to: review_ready
  - from: review_ready to: merged          approve: [changeset]
  - from: verifying    to: implementing    when: tests_failed  max: 3
  - from: implementing to: planning        when: plan_invalid  # backward edge

limits:
  spawn_depth: 2
  child_budget: 0.4                # fraction of the parent's remaining budget
  experiments: human_approval_required
```

Shape only — the real grammar is a design task, not settled here. What matters is that it is
declarative, diffable, small enough to read in one sitting, and reviewable by the same
process as any other change to the project.

Within a state, work can fan out and rejoin — two plan drafts compared by a third agent, an
implementation followed by a self-review. These sub-structures are named, reusable blocks in
the same definition file. An agent may spawn children only from an explicitly permitted set,
so the possible shape of execution is known before it runs, while the actual shape is chosen
at runtime.

Subagents are not a separate concept. A subagent is a job: same specification, same
isolation, same artifacts, same record. That uniformity is the entire reason not to use the
harness's built-in mechanism — children become inspectable, resumable and budgeted like
everything else.

---

## Jobs

A job is one execution of one state. It receives an immutable specification: the state's
prompt, a manifest of input artifacts pinned by version, the environment to run in, a git
commit, budgets, and the child types it may spawn. It produces artifacts, an outcome, and a
full event record.

Jobs are disposable. Anything that must survive is either committed to the job's branch or
written to the artifact store — nothing else exists. A job that is interrupted commits its
work in progress and hibernates; on resume it is reconstructed from its branch and its
declared inputs. Continuing the agent's actual conversation is an optimisation attempted
where cheap, never a dependency.

This is what makes waiting free. A job blocked on a human decision holds no process and no
machine — only a row and some documents. It can wait indefinitely at no cost.

---

## Artifacts and the human loop

Artifacts live in the platform's own store, not in git. Code is git's job; the reasoning
around code is the platform's.

Every artifact is immutable and versioned. Editing produces a new version; approval attaches
to a specific version. A human edit is just another version with a human author. Because
inputs are pinned, a job's basis is permanently answerable even after later revisions — and
when an upstream document moves ahead of what a job consumed, the platform says so rather
than silently re-running work.

Three kinds:

- **Documents** — prose plus structured fields. The contract between steps. Approvable.
- **Blobs** — build output, test logs, screenshots. Held in object storage, referenced by
  URI, served to the operator through the platform rather than by provider-specific signed
  links.
- **Presentations** — rich, human-only views. Nothing downstream may consume them, so they
  need no schema and carry no approval semantics.

**Questions are part of the document.** An agent uncertain about scope raises the question
next to the paragraph it concerns — a short question with a small set of options and a
recommended default. Non-blocking questions state the assumption taken and let work
continue. Blocking questions genuinely stop the job until answered; there is no timeout and
no automatic fallback. Answers are their own versioned artifact, attributed and pinned to
what they answered.

This is the mechanism for every human interruption in the system, including an agent asking
permission to experiment.

---

## Environments

Each job type declares its environment declaratively, in-repo, alongside the workflow. A
refinement job gets no toolchain; an implementation job gets the Rust environment; cross-
compilation and mobile SDKs belong only to the release path, never to agent nodes.

Agents may modify their own environment during a job. The change is job-local and becomes a
reviewable proposal for the shared definition — never a mutation of shared machine state.
The same applies to workflow structure. An agent that needs a tool must, in effect, open a
pull request for it.

**Experiments are explicit and always human-approved.** A job may request an experiment
state permitting environment and workflow modification; the request goes through the same
interruption mechanism as any other blocking question. Results are advisory and marked as
experimental. Promotion into the shared definition is a second, separate human approval.
Approval gates, budgets, spawn permissions and depth limits are never modifiable, in any
mode.

---

## Execution

Three tiers, deliberately unbalanced:

**Orchestrator** — small, always on. Holds the state machine, the event log, the artifact
store, git, credentials and the web application. Compiles nothing, so it never dies under
load.

**Worker** — one large machine, created on demand and destroyed after a configurable idle
period. Hosts all agents for that session. Each job runs in its own resource-limited slice:
a hard memory ceiling so an out-of-memory build kills one job rather than the machine, and
proportional CPU sharing so agents idle on inference donate capacity to whoever is
compiling. Scheduling admits a job only when its slice fits the remaining memory budget.

Each job gets its own worktree and its own build directory, cloned from a warm seed using
filesystem-level copy-on-write, so several parallel builds share storage and diverge only
where they actually recompile.

**Object storage** — the durable layer. Binary cache, build cache, blobs, logs. No attached
volume, therefore no single-writer constraint and no failure mode where a crashed
orchestrator strands storage.

Everything above the provider API is ordinary Linux. Provider-specific surface is confined to
a driver: create a machine, destroy it, and an object-storage endpoint.

---

## Git

The platform hosts its own repositories. This closes the loop: merge approval is a state in
the machine rather than a link to somewhere else, hooks enforce the branch discipline
mechanically, and post-merge actions need no external round trip. Repositories mirror to an
external host so a single machine is never the only copy.

---

## The interface

A web application, mobile-first, with a native client possible later. The API is the product
surface; clients are interchangeable.

**The queue is the home screen.** Not a dashboard — an inbox. Blocking questions, transition
approvals, experiment requests, promotion decisions and review-ready tickets in one ordered
list, answerable in sequence without navigating back. Push notification for blocking
questions; everything else digested.

**Ticket view** is a vertical timeline of states with outcome, cost and artifacts per step.
**Job view** shows the pinned manifest — the transparency promise made concrete. **Board
view** gives the familiar swimlane-per-state overview. **Merge approval** shows the diff
alongside what the platform uniquely knows: the verification report, the chain of documents
the change was built from, the questions answered along the way, and total cost.

Watching agents work is how a review budget disappears — so nothing in the product invites it.
That is about *unattended* work: a feed of agents grinding through tickets spends attention on
nothing. It is not an argument against live output when the operator is the one waiting, which is
why a conversation streams its reply.

Reliability is the differentiator: message state visible, sends retried, answers composed
offline and synced. The current failure — a message that vanishes silently — must be
impossible by construction.

---

## Security and multi-user

Designed properly, proportionate to the fact that this holds credentials and can spend money:
sessions, second factor available but not mandatory, all mutations audited into the same
event log, provider tokens confined to the orchestrator, short-lived scoped credentials
issued per job, spend caps.

Single-operator today. The data model carries users and roles from the start — approver,
promoter, spender — so team use is an expansion rather than a rewrite.

---

## Harness independence

Claude Code is the first execution harness, not an assumption. The platform normalises agent
events into its own schema at the driver boundary, so a second harness is a driver rather
than a migration. Capabilities that differ between harnesses — conversation resumption,
permission prompting — are declared, and the design already treats both as optional.

---

## An analysis agent

Optional, offline, propose-only. A job whose input is the event log rather than a ticket. It
reads cost, timing, outcomes, retries and backward transitions across completed work and
proposes workflow or environment changes. It runs no experiments, changes nothing, and has
no elevated permissions; its proposals go through the same approval path as any other.

This requires only that the event log records enough to make it possible.

---

## Open questions

- **Which credential funds execution.** Subscription authentication is individual-use;
  metered API billing is not. This decides whether team use is real and is unresolved.
- **Form representation** for structured questions.
- **Idle period** before a worker is destroyed — depends on measured cold-start time.
- **Branch granularity**: one branch per job, or one per ticket with rebasing on conflict.
- **Whether the build cache can be produced as a reproducible artifact** rather than a
  maintained blob. The storage design is simpler if it can.

---

## Measure before building

Five cheap experiments, all runnable on the existing machine, that determine whether parts of
this design survive:

1. Whether the build tool accepts a cache produced by the environment system without
   rebuilding from scratch. The storage model depends on it.
2. How much a copy-on-write build directory actually diverges during a realistic branch
   build. Determines whether one worker can host several parallel compiles.
3. Peak memory of a link step. Sets slice limits, agents per worker, and machine size.
4. End-to-end cold start of a worker. Decides whether destroying it is viable at all.
5. **Whether agents, prompted well, actually produce bounded, well-formed artifacts and ask
   few good questions.** The quietest risk and the largest: everything here can work
   mechanically and still be useless if the output is sprawling. Testable today with no
   infrastructure at all.
