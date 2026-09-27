# Workflow grammar v1

Scope: the subset of the RFC sketch that milestone 1 executes. Blocks, fan-out, spawning and
experiments are not in v1 and are rejected by the validator if present, so nothing silently
half-works.

**Commands are live.** § Commands, and the `commands`, `invoke`, `may_invoke` and `exit` keys in the
example below, are what the validator accepts and the platform runs (`docs/design/commands.md`).
They are in this file rather than a separate one because this file is what the validator is
written against and what an agent is handed; the note moved first and the parser followed, which
is this repository's order.

**`resources` and `defaults` are live**, on a state, on a command and at the top level. They
arrived ahead of commands because they are what `docs/design/provisioning.md` gates on and neither
needs a command to exist — a refine job and a build job wanting different ceilings is the same
problem whether or not the build runs as a command. Everything on this page is live.

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

defaults:
  resources: { memory: 2200MiB, cpu: 1 }

commands:
  build:
    run: .forge/commands/build.sh
    env: build
    produces: build.log
    timeout: 20m
    resources: { memory: 4GiB, cpu: 4 }

  test:
    run: .forge/commands/test.sh
    env: build
    produces: test.log
    timeout: 30m
    resources: { memory: 6GiB, cpu: 8 }

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
    may_invoke:
      build: { max: 40 }
      test: { max: 20, concurrent: 4 }
    inputs: [plan.md]
    produces: [implementation.md, changeset]   # notes on what was done, and the diff
    outcomes: [done, plan_invalid]
    budget: { turns: 200, cost: 10.00 }

  checking:                           # a command state: no prompt, no agent, no budget
    invoke: [build, [test, --all]]
    exit: { 0: done, "*": checks_failed }

  verifying:
    prompt: agents/verify.md
    env: release
    may_invoke:
      test: { max: 10 }
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
  - { from: implementing, to: checking }
  - { from: implementing, to: planning,     when: plan_invalid }
  - { from: checking,     to: verifying }
  - { from: checking,     to: implementing, when: checks_failed, max: 3 }
  - { from: verifying,    to: review_ready }
  - { from: verifying,    to: implementing, when: tests_failed, max: 3 }
  - { from: review_ready, to: merged,       approve: [changeset] }

limits:
  ticket_cost: 25.00
```

## Semantics

**States** come in three kinds. A *job state* has a `prompt` and runs one agent job per entry. A
*command state* has `invoke` and runs the commands it names, with no agent and no prompt; its
outcome comes from their exit statuses rather than from a document. A *human state* has neither;
the ticket waits there, holding no process, until a transition is taken by a human or by the
engine. `initial` names the state a ticket enters at admission. A
state with no outgoing transitions is terminal.

**A human state may declare `produces`: documents a person writes while the ticket rests there**,
on the ticket's Decide tab or through `POST …/artifacts/:name`. `human_testing` declaring
`test-report.md` is the case: the person who tried the build is the one the next job needs to
hear from, and a document is how every other state hears from the one before it. Nothing requires
one before a transition out is taken — a tester who approves the changeset has nothing to report —
so a state that reads it takes it as an optional input (§ Inputs, below). It is a document and
nothing else: not `changeset`, which only a job's commits make.

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
consumer is reachable). At job start the engine resolves each input to the latest version of that
artifact on the ticket and pins it in the job's manifest.

**An input is required when every way into the consumer passes through a job state that produces
it, and leaves that state on an outcome the job could not have reached without writing it —
`done` or one it declared — and optional otherwise.** An edge taken on an engine outcome (`error`,
`did_not_converge`, `budget_exhausted`, `cancelled`) guarantees nothing, because a job ends on one
exactly when it may not have written what it declared. A required input always exists by the time
the job starts. An
optional one exists only once its producer has run: `review.md` read by `implementing` when
`reviewing` can send work back is the case — `implementing` runs first, before any review exists,
and again after one. An optional input that exists is pinned like any other; one that does not is
left out, and the manifest names it as not yet written, so the agent knows what may appear on a
later attempt. A document a human state produces (below) is always optional, because nothing makes
a person write it. Which kind an input is follows from the transitions and needs no mark.

This paragraph replaces a sentence that said the reachability rule meant "a job never starts with a
missing input". It did not: the rule accepted `review.md` as an input of `implementing`, and the
job then could not be created on its first entry, which undid the transition into it and stuck the
ticket. A loop is how a later state sends work back with its reasons, so the reasons have to be
readable on the way back round — and absent on the way in.

**Produces** are the artifacts the job must write. `changeset` is reserved and means the diff
of the job's branch against the ticket's base. A name ending `/*` is a group of files (below).
Every other name is a document the job writes to the platform's artifact store. A job that
finishes without producing a document or the changeset it declared has outcome `error`.

**A name ending `/*` is a group of files** — `package/*`, `screenshots/*` — for what is not a
document: a build to try, a screenshot, anything whose bytes are not text. The job writes any
number of files into `$FORGE_JOB/out/package/`, each a regular file named as an artifact is named,
and each becomes a version of a blob artifact `package/<file>` on the ticket, which a person
downloads from the ticket (`docs/design/ui.md` § Addressable artifact versions). The count is open
and may be zero, so a group is never missing; a file that cannot be kept — too large, one too
many, not a regular file, a name that is not a name — is reported with why and does not fail the
job. A group is not a document: it carries no outcome and no questions. **It is not yet an input
and cannot be approved**: nothing on the reading side exists, and the validator says so rather
than accept a declaration nothing honours. A command produces groups the same way
(§ Commands).

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
`job-prompt.md`). Only a job that ends without open blocking questions has an outcome. A job
waiting on a command it invoked waits the same way and for the same reason — it is parked, holding
no process — but nothing is asked of a person and the wait ends when the commands do.

**Transitions.** `when` names an outcome and defaults to `done`. On job end the engine takes
the single transition from the current state whose `when` matches the outcome. If none
matches, the ticket becomes *stuck* (an engine flag, not a workflow state) and appears in the
queue for the operator to pick any declared transition from that state manually. `max` caps
how many times a transition may fire for one ticket; exceeding it also sticks the ticket.

**Approval.** `approve` lists artifact names. The transition is not taken automatically; it
enters the queue as a decision, and the operator approves or rejects the latest version of
each listed artifact. A transition a person takes by hand records the same approvals as
part of the choice. Approval attaches to those exact versions.

**Rejection keeps the ticket in `from` and hands the choice back.** The rejection is recorded
against the versions it refused, the decision stops being pending, and the ticket becomes
*stuck* — the same engine flag an unmatched outcome raises, and the one both surfaces read to
offer the transitions out of the state. The operator then chooses what happens next, including
editing the artifact (which creates a new version) and taking the transition by hand, which
records the approvals against that new version.

Clearing the pending decision is the part that matters, and it was missing: a rejection that
left it pending left the ticket saying "waiting for you to choose" while the queue and the ticket
page both still drew the approve-or-reject card, because each of them checks `pending_transition`
before anything else. There was no way forward from the page at all.

**Merging.** A state declaring `on_enter: merge` merges the `changeset` the ticket's approval
pinned, not whatever the branch head happens to be. The merge is checked before the transition is
taken, so a conflict refuses the approval and leaves the ticket where it was, with its edges out
intact; had it moved into a terminal `merged` first, there would be nowhere to go from there. It
is idempotent, so entering the state twice merges once.

**Budget.** `turns` and `cost` (USD) are per job and required on every job state. A command state
has neither — there is no inference to bound — and is bounded by each command's `timeout` instead;
declaring `budget` on one is an error. Reaching
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

## Commands

A **command** is a fixed script the project declares once and two callers run: a state that names
it in `invoke`, and an agent whose state allows it in `may_invoke`. `docs/design/commands.md` is
the note; this section is the grammar.

```yaml
commands:
  build:
    run: .forge/commands/build.sh    # relative to the repository root, at the pinned commit
    env: build                       # devShell, as on a state
    produces: build.log              # one artifact: the command's combined output
    timeout: 20m                     # required
    resources: { memory: 4GiB, cpu: 4 }
```

**`timeout` is a duration**: a whole number and one unit — `90s`, `20m`, `2h` — or a bare number of
seconds, and at most a day. One unit only; `1h30m` is written `90m`. A command that outlives it is
stopped, and ends with no exit status. `run` and `timeout` are required; `env`, `produces` and `resources` are not.
`produces` is where the combined output is recorded on the ticket, as a blob: without it the
output is still kept with the command's own job, and still handed to an agent that invoked it.
It may instead be a list of at most one such name and any number of groups of files —
`produces: [package.log, package/*]` — whose files the script writes into `$FORGE_OUT/package/`.

**The script is read at the ticket's pinned base commit**, like this file, never from the branch a
job is working on. Otherwise an agent that edits `build.sh` changes what `build` means for the
state that is meant to judge it. A ticket that changes a command script sees the change only after
it merges.

**Arguments are freeform and carry no schema.** An invocation supplies a list of strings and the
worker `exec`s the script with them as an argument vector — never a string given to a shell, so
`--filter "foo bar"` cannot word-split. A state's `invoke` entry is either a command name or a
list whose head is the name and whose tail is the arguments: `[test, --all]`. There is no
parameter declaration to validate against, and the exact vector is recorded on the invocation
because it is no longer derivable from this file.

**`invoke` makes a command state.** It lists commands to run on entry, and the state has no
`prompt`, `inputs`, `produces`, `outcomes`, `budget`, `model`, `env` or `may_invoke` — each command
brings its own environment. It may carry `resources`, which its commands fall back to (§ Resources).
Commands in the list run concurrently, at the ticket branch's head when the state was entered, and
the state waits for all of them.

**`exit` maps exit statuses to outcomes** and is required on a command state. Keys are integers —
quoted or not, since the pinned definition is stored as JSON and every key comes back a string — or
`"*"` for the default; the value is the outcome the transitions out are selected by. The status a
state maps is the *first non-zero* status among its commands, in `invoke` order, or zero when all
succeeded. A command that ended with no status — its timeout, a slice that could not be made —
counts as non-zero and matches only `"*"`, and a status no key matches is the engine outcome
`error`. A command state's declared outcomes are the values of its `exit` map, so `when:` on its
edges is checked against them exactly as for a job state; an engine outcome is not a value `exit`
may name.

**`may_invoke` grants a job state's agent the right to invoke**, with `max` invocations over the
job's life — required — and at most `concurrent` in flight, optional and unbounded when absent. It
is the workflow half of `spec.permitted_children`: an allowlist resolved at job creation and
carried on the spec. A breach is refused and reported to the agent, which is not a job failure —
`commands.md` § Limits says why.

**An agent invokes by writing `$FORGE_JOB/invoke.json` and ending its run**: a JSON array of
`{"command": "build", "args": ["--release"]}`. The job's manifest names what it may invoke and how
many remain. `commands.md` § How an agent invokes has the mechanism.

**A job waiting on a command is parked**, always. It holds no process, its slice is released, and it
resumes when every command it invoked has finished. There is no inline form and nothing in the
grammar selects between them.

## Resources

```yaml
defaults:
  resources: { memory: 2200MiB, cpu: 1 }
```

`resources` is valid on a command, on a job or command state, and under `defaults`. It is resolved
nearest-first: the command's, then the invoking state's, then `defaults`, then the platform's
configured slice. `memory` is the slice's hard ceiling and what the scheduler's gate
counts; `cpu` is how many cores the scheduler reserves when placing the job — **a reservation,
not a quota**, because capping a slice would throw away the proportional CPU sharing
`decisions.md` chose. There is no `disk` key. `commands.md` § Resources has the reasoning and the
failure mode a declaration no machine can satisfy produces;
`docs/design/provisioning.md` § The gate is what does the matching.

**Each field is resolved on its own, and neither is required where it appears.** A state wanting
more memory than the default writes `resources: { memory: 6GiB }` and keeps the default core
count. Requiring both would mean restating a number to change its neighbour, which is most of
what `defaults` exists to prevent.

**Sizes are binary units or a bare count of bytes** — `B`, `KiB`, `MiB`, `GiB`, `TiB`, matched
whatever their case, so `4gib` is `4GiB`. **The unit is optional and a bare number means bytes,
written either way**: `512` and `"512"` are the same size. They were not — the unit was
mandatory for a string, so a quoted number in YAML parsed differently from an unquoted one, and
a form, where every field is a string, could not carry a plain byte count at all. That is how
it was found: the templates page filled its own memory field with a figure it then refused. `4GB` is refused with a message naming `GiB`, rather
than accepted as an approximation: the two differ by enough to matter to a ceiling whose job is to
kill, and nobody sizing memory means the decimal one. Case-folding does not blur that — `mib` is
still not `mb`.

## Pinning

At admission the engine reads `.forge/workflow.yml` at the ticket's base commit, validates
it, and stores the parsed definition and the commit hash on the ticket. Later changes to the
file do not affect that ticket. Re-pinning is a human action and not in v1.

## Validation (rejects the file, never partially runs it)

- `version` is `1`; `initial` names a job state; every state name is unique.
- A job state has `prompt` and `budget`, and neither `invoke` nor `exit`. A command state has
  `invoke` and `exit` and none of `prompt`, `inputs`, `produces`, `outcomes`, `budget`, `model`,
  `env` or `may_invoke`. A human state has
  none of those but `produces`, and no `invoke` either; `on_enter` and `produces` are the keys it
  may carry, and what it produces is documents — never `changeset`.
- `model`, where present, is a non-empty string. Its value is not checked against anything.
- State and artifact names are single path segments: letters, digits, `.`, `_`, `-`.
- Every `inputs` entry is `ticket` or produced by a state that can run before the consumer; every
`produces` entry other than `changeset` is produced by exactly one state. `ticket` is never
produced; `answers.md` is platform-managed and never declared.
- A job state declaring outcomes other than `done` produces at least one document. A command
  state does not, because its outcomes come from `exit`.
- Every state is reachable from `initial` through transitions.
- Every transition names existing states; for one `from`, `when` values are distinct.
- `when` is an engine outcome or a declared outcome of `from`; for a command state the declared
  outcomes are the values of its `exit` map. `max` is a positive integer.
- Every `invoke` and `may_invoke` entry names a command declared in `commands`. An `invoke` entry
  is a name or a list whose head is a name; `may_invoke` values are maps of `max` and
  `concurrent`, both positive integers.
- Every command has `run` and `timeout`; `run` is a path under `.forge/` that exists at the pinned
  commit, and `produces`, where present, is an artifact name — or a list of at most one and any
  number of groups — produced by no state and by no other command.
- `resources`, where present, is a mapping of `memory` (a byte size) and `cpu` (a positive
  integer), each optional and each falling back through the chain on its own. Any other key is an
  error, and `disk` is rejected with a message saying it is *reserved* rather than unknown, so it
  does not read as a typo. `defaults`, where present, is a mapping whose only key is `resources`.
- A command's `env`, where present, is subject to the same rule as a state's.
- `approve` entries are produced by `from` or an earlier state.
- Prompt files exist at the pinned commit.
- Artifact names are fixed, and a group `name/*` names its files, not them: `name` is an artifact
  name, and the group is produced by exactly one job state or command, never by a human state,
  and never under a name something produces as a document. A group is neither an input nor
  approved.
- Every `on_enter` entry is a known action (`merge` alone in v1); `on_enter` is absent from every
  job state and every command state; at most one state in a workflow merges; `initial` does not merge; and a workflow that
  merges has a state producing `changeset`.
- Keys outside this grammar (`blocks`, `use`, `can_spawn`, `fanout`, `spawn_depth`,
  `child_budget`, `experiments`) are errors in v1.

Two of these cannot be checked here and are the scheduler's at run time: whether any machine can
satisfy a declared `resources`, and whether a command's script is executable. `forge_core` has no
database and no network, so a validator that tried would be guessing about a fleet it cannot see.
`commands.md` § Resources says what the scheduler does instead, and why queueing for ever is the
wrong answer.

## Deferred, with the intended shape

Named blocks with fan-out and join, `can_spawn` with `spawn_depth` and `child_budget`,
experiment states, further `on_enter` actions, and guarded transitions on document fields. None of
these change the meaning of anything above.
