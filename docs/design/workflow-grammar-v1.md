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

**A project with more than one kind of ticket has a directory instead**: one complete workflow per
**ticket type**, `.forge/workflows/<type>.yml` (`docs/design/ticket-types.md` is the note).

- **A type is a `<name>.yml` directly in `.forge/workflows/`**, named by the file's stem, which
  follows the rule for state and artifact names: letters, digits, `.`, `_` and `-`, starting with
  a letter or a digit. Anything else there — another extension, a name that breaks the rule, a
  subdirectory, a symbolic link — is not a type: it is never read, and it blocks nothing.
- **Each type's file is a whole workflow.** Everything on this page holds for it exactly as for the
  single file, and a ticket of a type reads that type's file wherever this page says
  `.forge/workflow.yml`. Types share nothing but what they import (§ Imports) and the prompts and
  scripts they name by path.
- **A ticket's type is chosen when it is admitted, and pinned with its workflow.** With several
  types a person chooses — there is no default type — and with one it is implied. A ticket keeps
  its type for life.
- **The single file and a type in the directory, together, are an error**: there is no rule for
  which wins, and nothing is admitted until one form is gone.

A file in either form may carry `description:`, one line saying what kind of work it is for. The
ticket form shows it beside the type, and a job reads every type's in `tickets/index.md`, so it is
what decides which type a proposal suggests.

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
    # Notes on what was done, the diff, and what the merge commit will say (§ Merging).
    produces: [implementation.md, changeset, commit-message]
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
    on_enter: merge                   # terminal: entering it merges the changeset its edge named
    on_conflict: integrating          # where a conflict sends the ticket instead (§ Merging)

  integrating:                        # an on_conflict target: its job also sees the default branch
    prompt: agents/integrate.md
    env: implement
    may_invoke:
      build: { max: 10 }
    inputs: [plan.md, changeset]
    produces: [integration.md, changeset]
    budget: { turns: 80, cost: 4.00 }

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
  - { from: integrating,  to: checking }    # back through the checks and the approval (§ Merging)

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
action, or a list of them. v1 has exactly one, `merge`, which merges the changeset the transition
into the state named into the project's default branch — § Merging says which commit that is and
what a conflict does, `git-hosting.md` how. It is declared on the
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
a person write it, and so is one its producer declares `optional` (below), for the same reason in
the producer's own words. Which kind an input is follows from the transitions and the declarations
and needs no mark.

**A command's log is an input too** — the name in a command's `produces` (§ Commands), never one
of its groups. It is always optional, since no job state produces it and whether the command has
run by then is not something the transitions can say, and it is the latest version on the ticket
whichever caller ran it. It is a blob and not a document, so it is inlined cut to its two ends:
the first 64 KiB and the last 192 KiB, with how much was cut named between them, and anything that
is not UTF-8 replaced. The job a command state sends the ticket to is handed that state's logs
whether or not it names them, whole and as files (`docs/design/job-prompt.md` § How the job
arrived); naming one is for a state further on — a review that has to judge the fix to a build.

This paragraph replaces a sentence that said the reachability rule meant "a job never starts with a
missing input". It did not: the rule accepted `review.md` as an input of `implementing`, and the
job then could not be created on its first entry, which undid the transition into it and stuck the
ticket. A loop is how a later state sends work back with its reasons, so the reasons have to be
readable on the way back round — and absent on the way in.

**Produces** are the artifacts the job must write. `changeset` is reserved and means the diff
of the job's branch against the ticket's base. A name ending `/*` is a group of files (below),
and a name ending `!` is a presentation (below). Every other name is a document the job writes to
the platform's artifact store. A job that finishes without producing a document or the changeset
it declared has outcome `error`.

**`commit-message` is the second reserved name, and unlike `changeset` it is a document a job
writes text into** — declared, written to `out/`, and kept as a version exactly like any other.
What is reserved about it is what reads it and what it may not be: a workflow that merges must
have a state producing it (§ Validation), and it may never be declared `optional`, because
merging has nothing to fall back on if it is absent. The merge's entry action reads it directly,
the way it reads `changeset`, and it is never pinned as an ordinary job `input` on its account —
nothing stops a state from also listing it as an input if a later state wants to read it, and
nothing requires that either. Its text is what the merge commit says, used as written
(`git-hosting.md` § The merge).

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

**A name ending `!` is a presentation** — `presentation.md!`, `deck.md!` — the artifact kind the
data model has always had and nothing wrote: prose an agent composes for the person deciding
whether to merge, and for nobody else. The real artifact name is the name with the `!` stripped,
which is what the job writes to `$FORGE_JOB/out/` and what the version is recorded under; the
marker stays in `produces` because it is the declaration, not the filename. It is parsed exactly
as a document is — front matter and all, so it may carry the outcome and may ask questions — and
differs from one only in the kind it is recorded under, which is what the ticket's surfaces read
to draw it `VIEW ONLY` with no approval slot (`docs/design/ui.md` § Semantics that must not be
lost). **It is never an input and cannot be approved**: nothing downstream consumes a
presentation, by decision, and the validator says so rather than accept a declaration nothing
honours. **Only a job state may declare one**, because neither other shape fits: a human state
writes nothing itself, and a command's output is captured stdout, not composed prose. A name may
not be produced as a document or a group of files by one state and a presentation by another — it
is one artifact with one kind. Like any other produced document it may be declared `optional`
(below), which is how a workflow says whether a ticket must have one.

**`optional` names what the job may finish without writing.** Everything in `produces` is
required by default: a job that ends having not written a document it declared has outcome
`error`, which is what makes a document a contract. A name in a job state's `optional` is excused
from that one rule and nothing else — the file's absence is not a failure, and when the absent
document is the one that carries the outcome the job is `done`, by the same rule as a state that
produces no document at all. The names are the artifacts' own, with no marker:
`produces: [presentation.md!]` is excused by `optional: [presentation.md]`, the spelling `inputs`
and `approve` use. Only a document may be optional — `changeset` is the branch the job's commits
made, and a group of files already has no minimum — and only a job state may say so, since nothing
obliges a person to write a human state's documents in the first place. **A state that declares a
choice of outcomes may not excuse the document that carries it** (§ Validation): the choice is
made in that document's front matter, and there is nothing to read in a file nobody wrote.

**This is how a workflow says whether an artifact is required**: the same state, with or without
the line. The cost is that nothing then distinguishes an agent with nothing to say from an agent
that forgot, so a document worth checking should stay required.

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

**While a decision is pending, no other transition may be taken.** The decision comes first,
whichever edge is asked for, and `Forge.Engine.choose/4` refuses with `{:error, :pending_approval}`
— `repinnable/2`'s name for the same condition. This is a rule of the grammar and not of a
surface, which is the correction: it used to live only in the ticket page's `:if` on its chooser,
which was armour while clicking was the only way in. A conversation asks for a transition by
writing a file (`conversations.md` § Taking a transition), so the check belongs at the operation,
where the chat, the API and the page all meet it.

**A transition that approves a document with no version is not offered.** Approving records an
approval on the latest version of each listed artifact, and a state whose job failed may never have
written one: a refinement that did not parse left its ticket stuck in `refining` with `planning`
offered, and taking it failed on `{:no_version, "refinement.md"}` twice before anyone could say
why. So the surfaces list only the transitions whose `approve` names all have a version
(`Forge.Engine.offered_edges/2`, whose targets are `offered_transitions/2`), and taking one anyway
is refused with the name that has none. The filter is per *edge*, which is why the surviving edges
and not merely their targets are what the one walk returns: two edges may reach one target with
only one of them offerable.

**Running a state again.** A person may run the ticket's current state again whenever it is a job
or command state and nothing is live in it — stuck or active, after a failure, and after a
success too, say to have a refinement done afresh before approving it (`Forge.Engine.retry/2`).
It makes the next attempt of the state's job, or the state's commands again, with the arrival
the last attempt had (`job-prompt.md` § How the job arrived); clears any pending approval, since
the documents it would approve are about to be replaced; unsticks the ticket; and records
`ticket.retried`. It takes no transition, so no `max` counts it: `max` bounds the engine's loops,
and this is a person choosing to spend again. What a retry may spend is the ticket's cost cap,
as for any job.

**Cancelling a ticket.** A person may cancel a ticket that is active or stuck
(`Forge.Engine.cancel/2`): the ticket becomes `cancelled`, every job of it that is still live —
pending, running, waiting, parked or hibernated — is finished with outcome `cancelled`, a machine
running one is told to stop, any pending approval is cleared, and `ticket.cancelled` names the
jobs it ended. **It is not a deletion.** Events and artifact versions are append-only
(`data-model.md`), the branch is the work, and a mistaken cancel must be undoable — so a cancelled
ticket keeps all of it and is **hidden everywhere a ticket is listed**: the board, the project
page, the queue, the projects page's count, the API's ticket list, a project token's ticket
choice, and the backlog every job reads (`ticket-proposals.md` § Reading the backlog). Its own
page is still reached by its address, and offers **Restore**, which makes it `stuck` in the state
it was in: waiting for a person to run that state again or take a transition out of it. Nothing
else acts on a cancelled ticket — it takes no transition, no retry and no approval, and the
scheduler cannot stick it back into view. A report arriving from a job it ended is refused, as any
report for a finished job is, and settles what that last run spent — the cancel closed the run
with nothing, and spend is read from runs — and releases the machine, which nothing else would.
The cancel locks the ticket and its live jobs, so a job starting or a result being recorded at the
same moment happens wholly before it or is refused after it. The ticket's conversations are left
as they are: a conversation is ended by closing it.

**Merging.** A state declaring `on_enter: merge` merges the `changeset` version the transition
into it named, not whatever the branch head happens to be, and checks it before a person's
transition into it is taken — and before the engine's own, when the state names `on_conflict`.
What a conflict does is the state's to say, with that key — § Merging.

**Budget.** `turns` and `cost` (USD) are per job and required on every job state. A command state
has neither — there is no inference to bound — and is bounded by each command's `timeout` instead;
declaring `budget` on one is an error. Reaching
either ends the job with `budget_exhausted`, and the job row names which ceiling stopped it.
There are three, not two: the turn budget, the cost budget, and the engine's wall-clock limit,
which is a default of the engine's and has no key here at all
(`capacity.md` § Four exhaustions, three treatments). `limits.ticket_cost` is required and caps the
sum over all jobs of a ticket; reaching it sticks the ticket. Budgets are never modifiable by a
job.

**`limits.ticket_cost` caps the jobs the engine starts, and not a conversation.** The workflow
and command jobs of a ticket are what it sums; a conversation opened on that ticket has no
ticket allowance and meets the daily cap alone, as `capacity.md` § Spend caps and
`conversations.md` § Spend already say. The allowance exists to stop a runaway workflow, and a
person asking why a ticket is stuck is not one — a cap that stopped them investigating would
work against its own purpose. A chat's spend is still recorded, on the conversation and its own
runs rather than on `ticket.cost_usd`.

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

## Merging

```yaml
states:
  merged:
    on_enter: merge
    on_conflict: integrating     # a job state or a human state of this workflow
```

**Which commit a merge merges, and what it says.** Every transition into the merging state names
the commit it is taken for: the latest `changeset` version at the moment it is taken, read once.
For a person that is the version their approval of the edge records, in the same act; for the engine's own edge out
of a job state it is the version that job's result recorded, since a result is recorded before the
engine decides where it sends the ticket. The check before the transition is made on that commit,
`transition.taken` names it (`changeset` and `changeset_version`), and the entry action merges
*it*, read back from that event — never "the latest version" again. Two consequences, and they are
why the rule is stated rather than left to the code:

- a version written after the transition cannot be merged by it;
- an approval never merges a version other than the one it was recorded against, because a
  person's approval of `changeset` is recorded against the version the check was made on — the
  one the transition names — and not against the latest read again. A version an integration
  writes later reaches the default
  branch only through a later transition, which names it — and, on an edge with `approve`, needs
  approving in its own right.

It replaces "the latest version, whenever the merge reads it", which was harmless only while every
merge followed a person's approval in the same request. With the engine merging on its own (route
(b), below) the read and the approval would have been minutes apart, and nothing tied them.

**The same rule for the message.** The transition also names the latest `commit-message` version
at the moment it is taken; `transition.taken` carries it as `commit_message_version`, and the
entry action uses *that* version and never the latest again. The version alone is on the event and
not the text, because the text is read back from the artifact rather than duplicated into the log.
It closes the same race the changeset's rule closes: a conversation rewriting `commit-message`
after the approval but before the entry action runs would otherwise change what the commit says.
A transition that names a changeset and no `commit-message` reaches the merge with nothing for the
commit to say, and sticks the ticket in the merging state saying so.

`refs/forge/approved/<n>` is written by each merge attempt, at the commit it merges, whoever's
transition named it — on route (b) nobody approved anything and the engine's attempt writes it. The
name is history; what it means is *the commit this ticket's merge was last attempted for*, kept
reachable (`git-hosting.md` § Non-fast-forward on a ticket branch).

**The check.** Before a transition into the merging state is taken, `Forge.Merge.check/2` runs
`merge-tree` on the commit it names against the default branch's head, and moves no ref. It runs
for a person's approval, for an edge a person takes by hand, and — when the state has
`on_conflict` — for the engine's own edge. What a conflict then does:

- **Without `on_conflict`**, exactly what it did before the key existed. A person's approval or
  hand-taken edge is refused, nothing is recorded, and the ticket stays where it was with its edges
  out. The engine's own edge is not checked; the merge runs after it, and a failure sticks the
  ticket in the merging state, which offers nothing.
- **With `on_conflict: <state>`**, the ticket goes there instead. Whoever was taking the edge into
  the merging state takes this one: `transition.taken` records it from where the ticket was to the
  target, on the outcome `merge_conflict`, and `ticket.merge_conflicted` records the merging state,
  the conflicting paths, the default branch's head it was checked against, the commit and its
  version, and whether a person or the engine took it. The job the target runs is told how it got
  there like any other (`job-prompt.md` § How the job arrived). A person's approval is still
  recorded against the version they approved, because that is what they did; it merges nothing,
  by the rule above.
- **A failure that is not a conflict** — no changeset, a repository that is not there — refuses a
  person's act, as before, and sticks the ticket where it is when the edge was the engine's.

**The late race.** The check passed, the transition was recorded, and the merge itself then
conflicts: another merge moved the default branch in between, and the one retry against the new
head conflicts too (`git-hosting.md` § Where it runs, and what a conflict does). With
`on_conflict` the ticket leaves the merging state by that edge — `transition.taken` from the
merging state to the target, the same `ticket.merge_conflicted` — which is the only way out of a
terminal state there is. A late failure that is not a conflict, a push the hook refused, still
sticks the ticket in the merging state. `on_conflict` adds no transition: nobody chooses it and no
outcome selects it, so a merging state with no transitions out is as terminal as it was. If the
move cannot be made — the target's job cannot be created — the ticket is stuck in the merging
state saying so, rather than left reading `done`. So does a merge with no `commit-message` version
to read.

**The target is a job state or a human state, with a transition out.** A job state is the usual
case, and a job state that is some merging state's `on_conflict` is an *integrating* state: its
job's checkout also fetches the default branch, read-only, and its manifest says what conflicted
and how to resolve it (`job-prompt.md` § Integrating the default branch). **Nothing but a conflict
may lead into an integrating state** — no declared transition names it as `to`. What makes a job
an integration is the state it is in, so a state that ordinary work also arrives at would make
every one of its jobs fetch the default branch, need a newer worker, and be told a conflict sent
it when none had; `implementing` as the target was the case that would have done it. A human
state is allowed as the target too, and may be reached other ways, since it runs nothing: a team
that wants a person to look at every conflict should not have to pay an agent to say it could not
first, and the person has the moves its transitions offer — send it back to implementing,
resolve it by hand on the ticket's branch with a token from the project's settings
(`git-hosting.md` § Issuing a token) and move it on to a state whose job records the branch, or
cancel it. A command state is
refused: its checkout is given no default branch to merge, and a fixed script cannot decide what
a conflict should become. Nor may the target be the merging state itself — a conflict has to leave
it — or a state with no transitions out, where a conflict would end the ticket unmerged. And
`merge_conflict`, the outcome the route is recorded on, is the platform's: no state declares it and
no `exit` maps to it, so no job can end on it and no `when` can select it.

**After integration, the workflow decides**, with ordinary edges out of the integrating state.
Both of these are expressible, and both work:

```yaml
transitions:
  # (a) back to an earlier step, then the usual approval into the merging state
  - { from: integrating, to: human_testing }
  - { from: human_testing, to: merged, approve: [changeset] }

  # (b) straight to the merging state, with no person in between
  - { from: integrating, to: merged }
```

On route (a) the approval names the integrated version and needs giving afresh; the approval of
the version before integration cannot merge it. Route (b) is the engine's own edge into the merging
state, so it is checked like any other: still conflicting — or the default branch moved again while
the job ran — it takes `on_conflict` again.

**That loop is bounded by the platform, not by `max`.** The engine sends a ticket down
`on_conflict` by itself at most **three times in a row**: an engine-taken edge into the merging
state whose check conflicts takes `on_conflict` only while fewer than three
`ticket.merge_conflicted` the engine took have been recorded since a person last moved the ticket —
took a transition, or ran its state again. The fourth sticks the ticket where it was, in the
integrating state with its edges out, saying `merge still conflicts after 3 integrations in a row:
the integrate-then-merge loop stops here`. A person moving it on starts the count again, and a
person's own conflicting approval is never counted: there is a person in that loop already.

`max` was the other way to bound it, and does not work. `max` counts an edge each time it fires,
and the edge round this loop does not fire when it conflicts — the ticket goes to `on_conflict`
instead — so `max: 3` on `integrating → merged` would bound successful merges, of which there is
one. Counting the redirected attempt as a firing would make `transition.taken` say the ticket
entered a state it never did. And a bound the author has to remember is one most workflows would
not have, on the one loop that spends a credential with nobody watching.

A late race takes `on_conflict` whatever the count, because sticking in the merging state is the
dead end the key exists to remove; it is counted when the engine's edge led to it. The count is
consulted at the check, which every round of route (b) passes. A round that ends in a late race
instead has to lose to another merge twice inside its own merge, so a loop the count cannot stop
is one where the default branch moves under every merge this ticket makes — paced by other
tickets' merges, and bounded, like any job, by the ticket's cost cap.

**The ticket's base follows an integration.** The `changeset` is the diff of the branch against the
ticket's base, and once the branch has merged the default branch that diff would include every
other ticket's work since. So when a job's result records a `changeset` version whose commit
contains a later default-branch commit than the base — the merge base of that commit and the
default branch's head, when it descends from the base — the base moves there, in the same
transaction, and `ticket.base_moved` says from where to where. Only an integrating job's checkout
can see the default branch, so in practice that is the integrating job's result; a person's hand
resolution moves it the same way when the next job records the branch.

**A conflict can be found before the merge.** After every merge into the default branch — a
ticket's or a conversation's — the project's other open tickets with a changeset are checked, and
one whose latest changeset no longer merges is told so on its page, once per commit, with which
merge caused it
(`docs/design/ui.md` § Decide and Timeline). Nothing starts by itself: a job spends a credential,
and the ticket may be one its operator is about to cancel. A person can send it down the conflict
route from there (`Forge.Engine.integrate/2`) when its state has an edge into a merging state with
`on_conflict` and nothing is live in it: the check is run again, a conflict takes the same route an
approval that conflicted takes — less the approval — and a pending approval is cleared, since the
version it would approve is about to be replaced. A ticket that merges cleanly by then is refused,
and the notice it acted on was stale.

The merge itself is idempotent, so entering the merging state twice merges once.

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

**What a script can rely on.** It starts in the checkout, at the commit the invocation names, and
the environment names four places:

| Variable | Is |
|---|---|
| `FORGE_CHECKOUT` | The checkout: the same directory the script starts in, named for a script that has changed directory. |
| `FORGE_JOB` | The job's own directory, outside the checkout. |
| `FORGE_OUT` | `$FORGE_JOB/out`, where the script writes its groups of files. |
| `HOME` | `$FORGE_JOB/home`, empty, and never handed to another job. |

**The script is not in the checkout.** What runs is the pinned copy, written into `$FORGE_JOB`, so
`$0` is a path there and not `.forge/commands/build.sh`. A script that finds the repository by
climbing from `dirname "$0"` leaves it — the `cd` succeeds, and the build then runs in a directory
with no repository in it. Use the working directory or `$FORGE_CHECKOUT`.

**Nothing in `HOME` outlives the job.** A tool cache that should carry from one job to the next
belongs inside the checkout, ignored by git: that is what the project's seed and a ticket's volume
keep (`docs/design/worker-tier.md` § Volumes and the seed).

**Arguments are freeform and carry no schema.** An invocation supplies a list of strings and the
worker `exec`s the script with them as an argument vector — never a string given to a shell, so
`--filter "foo bar"` cannot word-split. A state's `invoke` entry is either a command name or a
list whose head is the name and whose tail is the arguments: `[test, --all]`. There is no
parameter declaration to validate against, and the exact vector is recorded on the invocation
because it is no longer derivable from this file.

**`invoke` makes a command state.** It lists commands to run on entry, and the state has no
`prompt`, `inputs`, `produces`, `outcomes`, `budget`, `model`, `env`, `may_invoke` or `secrets` —
each command brings its own environment, and its own secrets. It may carry `resources`, which its commands fall back to (§ Resources).
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

## Imports

```yaml
# .forge/common.yml — a library
commands:
  build: { run: .forge/commands/build.sh, env: build, produces: build.log, timeout: 20m }
defaults:
  resources: { memory: 2200MiB, cpu: 1 }
states:
  implementing:                       # a template, used only where a state extends it
    prompt: agents/implement.md
    env: implement
    produces: [implementation.md, changeset]
    budget: { turns: 200, cost: 10.00 }
```

```yaml
# .forge/workflows/bug.yml
version: 1
import: [common.yml]
initial: implementing
states:
  implementing:
    extends: implementing             # the template's keys, then these replace its own
    inputs: [ticket]
  ...
```

A workflow may `import` **libraries**: files under `.forge/`, outside `workflows/`, named by their
path relative to `.forge/`, read at the same commit as the workflow. A library holds `commands`,
`defaults` and state templates under `states`, and nothing else — no `version`, `initial`,
`transitions`, `limits` or `import`.

- **Commands are imported whole.** A command name declared by two libraries, or by a library and
  the workflow, is an error: a workflow that needs another build names it differently.
- **Defaults are imported field by field, and the workflow's own win.** Two libraries setting the
  same field is an error.
- **A state template is used only by a state that names it**, `extends: <template>`, under any
  name of its own. **The keys the state writes replace the template's whole**: a `budget` in the
  state is the budget, not a patch to the template's.
- **Imports are one level deep**: a library imports nothing and a template extends nothing.

The imports are resolved when the ticket is admitted, and what the ticket pins is the result —
the definition with no `import` and no `extends` left in it — so a later change to a library
reaches a ticket only through a re-pin. An error about a part a library supplied names the
library: `common.yml: states.implementing.budget.turns: must be a positive integer`.

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

**`memory` is at least 512 MiB** (`ForgeCore.Workflow.Resources.minimum_memory/0`), and a smaller
one is refused by name — *must be at least 512MiB, the least a job can run in* — wherever it is
declared. The figure is chosen, not measured — a floor under which no agent is expected to run
— so a smaller ceiling is never a job that runs slowly; at two bytes it described one that took its machine with it
(`worker-tier.md` § A machine whose systemd stops answering). It is one definition, and every
other place a size enters — the new-chat form, the templates page, the workers page, the job
row, the worker itself — refuses below the same one.

## Secrets

```yaml
commands:
  publish:
    run: .forge/commands/publish.sh
    timeout: 10m
    secrets: [CARGO_REGISTRY_TOKEN]

states:
  implementing:
    prompt: agents/implement.md
    secrets: [STRIPE_TEST_KEY]
    ...
```

**`secrets` lists the project secrets a job state's agent or a command receives**, by name, in its
environment; entering the state, or running the command, is the grant, and nothing else is
(`docs/design/secrets.md` § The workflow is the access list). It is a list of names and nothing
more: not on a command state, which runs commands that bring their own; not on a human state,
which runs nothing; and not under `defaults`, because a default is a secret in every job. Nothing
is inherited — an agent's secrets do not pass to the commands it invokes.

**The validator checks the names, not the project.** Each is a secret's name and not a reserved
one (`ForgeCore.Secret`, `secrets.md` § Names), and none is listed twice. Whether the project has
set it is the platform's question, asked when the job is scheduled, because secrets change after a
workflow is pinned: a job naming one the project lacks sticks its ticket until an admin sets it.

## Pinning

At admission the engine reads `.forge/workflow.yml` — or the chosen type's file — at the ticket's
base commit, validates it, and stores the parsed definition, the commit hash and the type on the
ticket. Later changes to the
file do not affect that ticket, and neither do later changes to its prompts or command scripts,
which are read at the same commit.

**Re-pinning is a person's act** (`Forge.Engine.repin/2`). It reads the workflow of the ticket's
own type at the default branch's head — refusing when that type's file is gone — validates it as
admission does, and stores the definition and the commit in place of the old ones; every job made after it reads its prompt and its scripts from there. The branch,
its base and what the ticket has written stay. It is refused while a job for the ticket's state
is live, since that job was made from the old pin; while an approval is pending, whose transition
the new workflow may not have; when the new workflow has no state the ticket is in; and when the
head is the pin already. A `ticket.repinned` event records both commits.

It exists because the pin makes some failures unfixable from inside the ticket. A command script
nobody on the ticket may edit, failing in a way no change on the branch can mend, would have gone
on failing on that ticket after a fix landed on the default branch, for as long as the ticket
lived; the only way on was to move the ticket past the state by hand. The ticket page says when `.forge/` has changed on the
default branch since the pin, which paths, and offers the re-pin beside it (`docs/design/ui.md` §
Decide and Timeline). A ticket that changes a command script still sees the change only after it
merges: re-pinning takes the default branch, never the ticket's own.

## Validation (rejects the file, never partially runs it)

- `version` is `1`; `initial` names a job state; every state name is unique.
- A job state has `prompt` and `budget`, and neither `invoke` nor `exit`. A command state has
  `invoke` and `exit` and none of `prompt`, `inputs`, `produces`, `optional`, `outcomes`,
  `budget`, `model`, `env`, `may_invoke` or `secrets`. A human state has
  none of those but `produces`, and no `invoke` either; `on_enter` and `produces` are the keys it
  may carry, and what it produces is documents — never `changeset`, a group of files or a
  presentation, and never `optional`, which is a job state's.
- `model`, where present, is a non-empty string. Its value is not checked against anything.
- State and artifact names are single path segments: letters, digits, `.`, `_`, `-`.
- Every `inputs` entry is `ticket`, a command's log, or produced by a state that can run before the
consumer; every `produces` entry other than `changeset` is produced by exactly one state. `ticket`
is never produced; `answers.md` is platform-managed and never declared.
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
- `resources`, where present, is a mapping of `memory` (a byte size of at least 512 MiB) and
  `cpu` (a positive integer), each optional and each falling back through the chain on its own.
  Any other key is an error, and `disk` is rejected with a message saying it is *reserved* rather
  than unknown, so it does not read as a typo. `defaults`, where present, is a mapping whose only key is `resources`.
- A command's `env`, where present, is subject to the same rule as a state's.
- `secrets`, on a job state or a command, is a list of names, each matching
  `^[A-Z][A-Z0-9_]{0,63}$`, none reserved (`ForgeCore.Secret`) and none listed twice.
- `approve` entries are produced by `from` or an earlier state.
- Prompt files exist at the pinned commit.
- Artifact names are fixed, and a group `name/*` names its files, not them: `name` is an artifact
  name, and the group is produced by exactly one job state or command, never by a human state,
  and never under a name something produces as a document. A group is neither an input nor
  approved.
- A presentation `name!` names one artifact: `name` is an artifact name, and the presentation is
  produced by exactly one job state — never by a human state or a command — and never under a
  name a state produces as a document or a group of files, or a command produces as its log or a
  group of files. A presentation is neither an input nor approved.
- `optional`, where present, is on a job state and lists names, each the artifact name of one of
  that state's own produced documents, none twice. `changeset` and a group of files are refused by
  that rule and refused by name, so the message says which it is rather than "not produced here".
  `commit-message` is refused **by name even though it passes that rule** — it is one of the
  state's own produced documents — because a merge has nothing to say without it.
- **A state declaring a choice of outcomes may not have `commit-message` first in `produces`.**
  The outcome document is the first document there, and this one is a plain git message with no
  front matter to choose in: the choice could never be made, every job would read `done`, and the
  state's other edges would be dead. It is a question of order, which is why `.forge/common.yml`
  keeps `presentation.md!` ahead of it.
- **A state declaring outcomes other than `done` may not make its outcome document optional.**
  An absent document is `done` and can be nothing else, so excusing the document the choice is
  written in is a way to take the `done` edge by writing nothing — and where `done` is not among
  the declared outcomes, a way to converge on an outcome no transition can match and stick the
  ticket behind a job that succeeded. It is the same rule as "declaring outcomes other than done
  requires a document in produces", one step further: there has to be one, and it has to be
  written.
- Every `on_enter` entry is a known action (`merge` alone in v1); `on_enter` is absent from every
  job state and every command state; at most one state in a workflow merges; `initial` does not merge; and a workflow that
  merges has a state producing `changeset` and a state producing `commit-message`, the second
  never `optional`.
- `on_conflict`, where present, is on the state that merges, and names another state of the
  workflow that is a job state or a human state with a transition out — never a command state,
  and never the merging state itself; a job state it names is the `to` of no transition
  (§ Merging). Every walk of the graph — whether each state is reachable, whether an input or an
  approval comes before its reader, the order the board draws its columns in — follows it as an
  edge out of the merging state, because the ticket can reach the target only by it. It is no
  transition: no `when` selects it and no person chooses it.
- `merge_conflict` is neither a declared outcome nor a value of an `exit` map.
- `description`, where present, is a non-empty string.
- Every `import` entry is a path of names under `.forge/`, not in `workflows/`, that exists at the
  pinned commit, and appears once; § Imports has the rest.
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
