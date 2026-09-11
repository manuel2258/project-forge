# Workflow grammar v1

Scope: the subset of the RFC sketch that milestone 1 executes. Blocks, fan-out, spawning and
experiments are not in v1 and are rejected by the validator if present, so nothing silently
half-works.

## Location

`.forge/workflow.yml` in the project repository. Prompts referenced by the file live under
`.forge/` and are resolved relative to it. The file is read at the ticket's base commit and
pinned (see below).

## Shape

```yaml
version: 1
initial: refined

states:
  refined:
    prompt: agents/refine.md
    env: refine
    inputs: [ticket]
    produces: [refinement.md]
    outcomes: [done]                  # default; may be omitted
    budget: { turns: 20, cost: 0.50 }

  planned:
    prompt: agents/plan.md
    env: implement
    inputs: [ticket, refinement.md]
    produces: [plan.md]
    budget: { turns: 40, cost: 2.00 }

  implemented:
    prompt: agents/implement.md
    env: implement
    inputs: [plan.md]
    produces: [changeset]
    outcomes: [done, plan_invalid]
    budget: { turns: 200, cost: 10.00 }

  verified:
    prompt: agents/verify.md
    env: release
    inputs: [plan.md, changeset]
    produces: [report.md]
    outcomes: [done, tests_failed]
    budget: { turns: 60, cost: 3.00 }

  review_ready: {}                    # human state: no prompt, no job
  merged: {}                          # terminal: no outgoing transitions

transitions:
  - { from: refined,      to: planned,      approve: [refinement.md] }
  - { from: planned,      to: implemented }
  - { from: implemented,  to: verified }
  - { from: implemented,  to: planned,      when: plan_invalid }
  - { from: verified,     to: review_ready }
  - { from: verified,     to: implemented,  when: tests_failed, max: 3 }
  - { from: review_ready, to: merged,       approve: [changeset] }

limits:
  ticket_cost: 25.00
```

## Semantics

**States** come in two kinds. A *job state* has a `prompt` and runs one job per entry. A
*human state* has no prompt; the ticket waits there, holding no process, until a transition is
taken by a human or by the engine. `initial` names the state a ticket enters at admission. A
state with no outgoing transitions is terminal.

**Inputs** are artifact names. `ticket` is reserved and means the ticket body as a document.
Every other name must be produced by some state. At job start the engine resolves each input
to the latest version of that artifact on the ticket and pins it in the job's manifest.

**Produces** are the artifacts the job must write. `changeset` is reserved and means the diff
of the job's branch against the ticket's base. Every other name is a document the job writes
to the platform's artifact store. A job that finishes without producing what it declared has
outcome `error`.

**Outcomes.** A job ends with exactly one outcome. Engine outcomes always exist and cannot be
declared: `did_not_converge`, `budget_exhausted`, `error`, `cancelled`. Declared outcomes are
listed in `outcomes` and default to `[done]`. The agent selects a declared outcome by writing
it into the front matter of the first document in `produces` (field `outcome`); a missing or
undeclared value is `error`. An agent may always write `did_not_converge`, whatever the state
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
each listed artifact. Approval attaches to those exact versions. Rejection keeps the ticket in
`from` and the operator chooses what happens next, including editing the artifact (which
creates a new version) and approving that.

**Budget.** `turns` and `cost` (USD) are per job. Reaching either ends the job with
`budget_exhausted`. `limits.ticket_cost` caps the sum over all jobs of a ticket; reaching it
sticks the ticket. Budgets are never modifiable by a job.

**Environment.** `env` is a devShell name in the project's `flake.nix`; the job runs inside
`nix develop .#<env>`. Absent `env` means no toolchain beyond the harness.

## Pinning

At admission the engine reads `.forge/workflow.yml` at the ticket's base commit, validates
it, and stores the parsed definition and the commit hash on the ticket. Later changes to the
file do not affect that ticket. Re-pinning is a human action and not in v1.

## Validation (rejects the file, never partially runs it)

- `version` is `1`; `initial` names a job state; every state name is unique.
- Every `inputs` entry is `ticket` or produced by some state; every `produces` entry other
  than `changeset` is produced by exactly one state.
- Every transition names existing states; for one `from`, `when` values are distinct.
- `when` is an engine outcome or a declared outcome of `from`; `max` is a positive integer.
- `approve` entries are produced by `from` or an earlier state.
- Prompt files exist at the pinned commit.
- Artifact names are fixed. The prefix form `name/*` is reserved for blob groups and is
  rejected in v1 with a message saying so.
- Keys outside this grammar (`blocks`, `use`, `can_spawn`, `fanout`, `spawn_depth`,
  `child_budget`, `experiments`) are errors in v1.

## Deferred, with the intended shape

Named blocks with fan-out and join, `can_spawn` with `spawn_depth` and `child_budget`,
experiment states, `on_enter` actions such as merging, and guarded transitions on document
fields. None of these change the meaning of anything above.
