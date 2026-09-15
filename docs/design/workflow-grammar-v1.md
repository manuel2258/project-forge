# Workflow grammar v1

Scope: the subset of the RFC sketch that milestone 1 executes. Blocks, fan-out, spawning and
experiments are not in v1 and are rejected by the validator if present, so nothing silently
half-works.

**This file is compiled into the release.** `ForgeCore.Workflow` reads it at compile time and
serves it as `grammar/0` — a conversation asked to bootstrap a project is handed *this note*
rather than a copy of it, because a copy would drift from the validator the first time either
changed and the copy is what the agent would read. Two consequences worth knowing before you
touch it: editing it rebuilds `forge_core` and everything downstream, and moving or renaming it
breaks the build rather than a link. It is named in `flake.nix`'s `embeddedDocs` for exactly
that reason — the build sandbox has no `docs/` unless a file is listed there.

## Location

`.forge/workflow.yml` in the project repository. Prompts referenced by the file live under
`.forge/` and are resolved relative to it. The file is read at the ticket's base commit and
pinned (see below).

## Shape

```yaml
version: 1
initial: refining

states:
  refining:
    prompt: agents/refine.md
    env: refine
    inputs: [ticket]
    produces: [refinement.md]
    outcomes: [done]                  # default; may be omitted
    budget: { turns: 20, cost: 0.50 }

  planning:
    prompt: agents/plan.md
    env: implement
    inputs: [ticket, refinement.md]
    produces: [plan.md]
    budget: { turns: 40, cost: 2.00 }

  implementing:
    prompt: agents/implement.md
    env: implement
    model: opus                       # optional; falls back to the project's, then the machine's
    inputs: [plan.md]
    produces: [implementation.md, changeset]   # notes on what was done, and the diff
    outcomes: [done, plan_invalid]
    budget: { turns: 200, cost: 10.00 }

  verifying:
    prompt: agents/verify.md
    env: release
    inputs: [plan.md, implementation.md, changeset]
    produces: [report.md]
    outcomes: [done, tests_failed]
    budget: { turns: 60, cost: 3.00 }

  review_ready: {}                    # human state: no prompt, no job
  merged:
    on_enter: merge                   # terminal: entering it merges the approved changeset

transitions:
  - { from: refining,     to: planning,     approve: [refinement.md] }
  - { from: planning,     to: implementing }
  - { from: implementing, to: verifying }
  - { from: implementing, to: planning,     when: plan_invalid }
  - { from: verifying,    to: review_ready }
  - { from: verifying,    to: implementing, when: tests_failed, max: 3 }
  - { from: review_ready, to: merged,       approve: [changeset] }

limits:
  ticket_cost: 25.00
```

## Semantics

**States** come in two kinds. A *job state* has a `prompt` and runs one job per entry. A
*human state* has no prompt; the ticket waits there, holding no process, until a transition is
taken by a human or by the engine. `initial` names the state a ticket enters at admission. A
state with no outgoing transitions is terminal.

**A job is the state's ongoing activity, not its entry action.** The distinction is in the
grammar: `on_enter` is the entry-action slot and a job is deliberately not in it. The engine sets
the ticket's state to the target and creates the job in the same transaction, so the ticket
*occupies* the state for the job's whole life — minutes, through cancellation, through a park on
a blocking question, through retries. In statechart terms the job is the state's do-activity and
the edges out are completion transitions, selected by the outcome.

**Naming: the tense follows the topology.** A job state is named for the activity, as a gerund —
`planning`, `implementing`. A human or terminal state is named for the condition it rests in —
`review_ready`, `merged`. Names are the project's to choose and nothing validates this, but
getting it backwards makes the platform assert something false: a ticket in a job state called
`implemented` is *not* implemented, and will not be until the job it is running ends. The name is
read at the moment it is least true — on the board while the work is in flight, and as the
timeline step heading the job's rows sit under.

The tempting objection is that a ticket also rests in a job state *after* its job, while a
transition waits for approval, so no tense is true throughout. It does not hold: that phase is
carried by `pending_transition`, a separate field, and a ticket parked on the edge out is not
doing the state's work. The state name has one job, and it is to name the activity.

**Entry actions.** `on_enter` names what the platform does when a ticket arrives in a state: one
action, or a list of them. v1 has exactly one, `merge`, which merges the ticket's approved
changeset into the project's default branch — see `git-hosting.md` for how. It is declared on the
state rather than on the edge because entering the state is the invariant: two edges into the same
state would each have to carry it, and a transition a person takes by hand down a third would
skip it silently. `on_enter` is not allowed on a job state, whose entry already runs a job.

**Inputs** are artifact names. `ticket` is reserved and means the ticket body as a document. Every
other name must be produced by a state that can run before the consumer (one from which the
consumer is reachable), so a job never starts with a missing input. At job start the engine
resolves each input to the latest version of that artifact on the ticket and pins it in the job's
manifest.

**Produces** are the artifacts the job must write. `changeset` is reserved and means the diff
of the job's branch against the ticket's base. Every other name is a document the job writes
to the platform's artifact store. A job that finishes without producing what it declared has
outcome `error`.

**Outcomes.** A job ends with exactly one outcome. Engine outcomes always exist and cannot be
declared: `did_not_converge`, `budget_exhausted`, `error`, `cancelled`. Declared outcomes are
listed in `outcomes` and default to `[done]`. The agent selects a declared outcome by writing
it into the front matter of the first *document* in `produces` (field `outcome`); a missing or
undeclared value is `error`. A job state whose `produces` holds no document therefore has
outcomes `[done]` only. An agent may always write `did_not_converge`, whatever the state
declares. This is how "tests failed" differs from "ran out of budget" and both differ from
"converged".

**Waiting.** If a produced document contains an open blocking question, no outcome is
evaluated and no transition is taken. The job waits for the answer and then resumes (see
`job-prompt.md`). Only a job that ends without open blocking questions has an outcome.

**Transitions.** `when` names an outcome and defaults to `done`. On job end the engine takes
the single transition from the current state whose `when` matches the outcome. If none
matches, the ticket becomes *stuck* (an engine flag, not a workflow state) and appears in the
queue for the operator to pick any declared transition from that state manually. `max` caps
how many times a transition may fire for one ticket; exceeding it also sticks the ticket.

**Approval.** `approve` lists artifact names. The transition is not taken automatically; it
enters the queue as a decision, and the operator approves or rejects the latest version of
each listed artifact. A transition a person takes by hand records the same approvals as
part of the choice. Approval attaches to those exact versions. Rejection keeps the ticket in
`from` and the operator chooses what happens next, including editing the artifact (which
creates a new version) and approving that.

**Merging.** A state declaring `on_enter: merge` merges the `changeset` the ticket's approval
pinned, not whatever the branch head happens to be. The merge is checked before the transition is
taken, so a conflict refuses the approval and leaves the ticket where it was, with its edges out
intact; had it moved into a terminal `merged` first, there would be nowhere to go from there. It
is idempotent, so entering the state twice merges once.

**Budget.** `turns` and `cost` (USD) are per job and required on every job state. Reaching
either ends the job with `budget_exhausted`. `limits.ticket_cost` is required and caps the sum
over all jobs of a ticket; reaching it sticks the ticket. Budgets are never modifiable by a
job.

**Environment.** `env` is a devShell name in the project's `flake.nix`; the job runs inside
`nix develop .#<env>`. Absent `env` means no toolchain beyond the harness.

**Model.** `model` names the model this state's job runs on — `opus`, `sonnet`, `haiku`, or a
full id. It is optional, and what fills the gap is a chain: the state's, then the project's, then
whatever the machine was built with.

It is per state because states differ in what they need. Refining a ticket into prose and
implementing it across twenty files are not the same problem, and a workflow that cannot say so
pays for the larger model on every state or accepts the smaller one everywhere.

**Not validated against a list of models.** Model names change faster than this file, and a
validator that knew them would reject a workflow naming a model released last week — refusing
work for being newer than the platform. What is checked is that it is a non-empty string. A name
the harness does not recognise fails the job, visibly, with the harness's own message, which is a
better error than one the platform invents from a stale list.

**The product offers a list; the grammar still does not.** Workers report the models their
credential may use (`docs/design/worker-channel.md` § What a worker offers), so a surface where a
person picks a model is a dropdown of what is connected now — the four aliases the harness
resolves, and the model ids the credential may use. That list is discovered on every worker join
rather than written down here, which is what dissolves the staleness objection above: a model
released last week is in it as soon as a worker connects.

The dropdown appears **only when there is something to put in it.** With no worker connected there
is nothing to discover, and the field is free text — otherwise configuring a project before
starting a machine would be impossible, which is the order a new operator does it in. A value
already set that the fleet no longer offers stays selectable rather than being silently dropped,
for the same reason: the worker that has it may be asleep rather than gone.

Parsing this file reaches no worker at all — `forge_core` has no network and no database — so the
rule above is what the grammar checks, and it is unchanged. A workflow may name any model; only
the form has a list.

## Pinning

At admission the engine reads `.forge/workflow.yml` at the ticket's base commit, validates
it, and stores the parsed definition and the commit hash on the ticket. Later changes to the
file do not affect that ticket. Re-pinning is a human action and not in v1.

## Validation (rejects the file, never partially runs it)

- `version` is `1`; `initial` names a job state; every state name is unique.
- A job state has `prompt` and `budget`. A human state has no `prompt`, `env`, `inputs`,
  `produces`, `outcomes`, `budget` or `model`; `on_enter` is the one key it may carry.
- `model`, where present, is a non-empty string. Its value is not checked against anything.
- State and artifact names are single path segments: letters, digits, `.`, `_`, `-`.
- Every `inputs` entry is `ticket` or produced by a state that can run before the consumer; every
`produces` entry other than `changeset` is produced by exactly one state. `ticket` is never
produced; `answers.md` is platform-managed and never declared.
- A state declaring outcomes other than `done` produces at least one document.
- Every state is reachable from `initial` through transitions.
- Every transition names existing states; for one `from`, `when` values are distinct.
- `when` is an engine outcome or a declared outcome of `from`; `max` is a positive integer.
- `approve` entries are produced by `from` or an earlier state.
- Prompt files exist at the pinned commit.
- Artifact names are fixed. The prefix form `name/*` is reserved for blob groups and is
  rejected in v1 with a message saying so.
- Every `on_enter` entry is a known action (`merge` alone in v1); `on_enter` is absent from every
  job state; at most one state in a workflow merges; `initial` does not merge; and a workflow that
  merges has a state producing `changeset`.
- Keys outside this grammar (`blocks`, `use`, `can_spawn`, `fanout`, `spawn_depth`,
  `child_budget`, `experiments`) are errors in v1.

## Deferred, with the intended shape

Named blocks with fan-out and join, `can_spawn` with `spawn_depth` and `child_budget`,
experiment states, further `on_enter` actions, and guarded transitions on document fields. None of
these change the meaning of anything above.
