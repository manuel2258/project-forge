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

A file in `.forge/workflows/` may carry `release: true`, which makes it the project's release: a
project admin starts one from the project page, it is left out of the ticket form, and it concludes
by itself when its last edge has no `approve` (`ticket-types.md` § Releases). Absent is false.

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
    budget: { turns: 20, tokens: 100k }

  planning:
    prompt: agents/plan.md
    env: implement
    inputs: [ticket, refinement.md]
    produces: [plan.md]
    budget: { turns: 40, tokens: 400k }

  implementing:
    prompt: agents/implement.md
    env: implement
    model: opus                       # optional; falls back to the project's, then the machine's
    effort: high                      # optional; the same chain, for how hard it thinks
    may_invoke:
      build: { max: 40 }
      test: { max: 20, concurrent: 4 }
    inputs: [plan.md]
    # Notes on what was done, the diff, and what the merge commit will say (§ Merging).
    produces: [implementation.md, changeset, commit-message]
    outcomes: [done, plan_invalid]
    budget: { turns: 200, tokens: 2M }

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
    budget: { turns: 60, tokens: 600k }

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
    budget: { turns: 80, tokens: 800k }

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
  ticket_tokens: 5M

schedules:                            # optional: tickets admitted on a clock (§ Schedules)
  - name: weekly-cleanup
    cron: "0 6 * * MON"               # five fields, read in UTC
    title: Weekly cleanup
    body: Tidy what the last week left behind.
```

## Semantics

**States** come in three kinds. A *job state* has a `prompt` and runs one agent job per entry, unless it is marked `chat: true`, when
it opens a conversation instead (§ Chat steps). A
*command state* has `invoke` and runs the commands it names, with no agent and no prompt; its
outcome comes from their exit statuses rather than from a document. A *human state* has neither;
the ticket waits there, holding no process, until a transition is taken by a human or by the
engine. `initial` names the state a ticket enters at admission. A
state with no outgoing transitions is terminal.

**A human state may declare `produces`: documents a person writes while the ticket rests there**,
on the ticket's Steps, under its current step, or through `POST …/artifacts/:name`. `human_testing` declaring
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
read at the moment it is least true — on the project's tickets while the work is in flight, and as
the step heading the job's rows sit under.

The tempting objection is that a ticket also rests in a job state *after* its job, while a
transition waits for approval, so no tense is true throughout. It does not hold: that phase is
carried by `pending_transition`, a separate field, and a ticket parked on the edge out is not
doing the state's work. The state name has one job, and it is to name the activity.

**Entry actions.** `on_enter` names what the platform does when a ticket arrives in a state: one
action, or a list of them. v1 has two. `merge` merges the changeset the transition into the state
named into the project's default branch — § Merging says which commit that is and what a conflict
does, `git-hosting.md` how. `update` brings the ticket's own branch up to date with the default
branch and runs no job (§ Bringing the branch up to date). Either is declared on the
state rather than on the edge because entering the state is the invariant: two edges into the same
state would each have to carry it, and a transition a person takes by hand down a third would
skip it silently. `on_enter` is not allowed on a job state, whose entry already runs a job.
`merge` and `update` are not both on one state.

**Inputs** are artifact names. `ticket` is reserved and means the ticket body as a document;
`attachments/…` is reserved too, and is not an input: a job is handed the pool whatever it declares
(`attachments.md`). Every
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
have a state producing it (§ Validation), it is declared as a plain document and never as a
presentation or a group of files, nobody approves it, and it may never be declared `optional`,
because merging has nothing to fall back on if it is absent. The merge's entry action reads it
directly, the way it reads `changeset`, and it is never pinned as an ordinary job `input` on its
account —
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

**A name ending `@` is a page** — `form@` — an HTML page that forge hosts, sandboxed, with a live
store of its own that survives every new version of it (`pages.md`). The job writes the page's files,
flat, into `$FORGE_JOB/out/form/`; `index.html` is required and is its entry, and each file becomes a
version of a blob `form/<file>` on the ticket (or on the project chat), as a group's files do, under
the same limits (1 GiB a file, 100 files a run), a file that cannot be kept reported with why and not
failing the job. The artifact name is the name with the `@` stripped, as a presentation's is, and
the marker stays in `produces` because it is the declaration. `forge-page.js` is a reserved file
name. **A declared page the job did not write — no `out/form/index.html` — ends the job `error`**,
which `optional: [form]` excuses (the spelling of `inputs` and `approve`: no marker). A later job
that produces the same name publishes a new version; the store is untouched. A page is **not an
input and is never approved** — a job reads its data live, not as a pinned copy. **A command
produces no page.** A name may not be produced as a page in one state and as a document, group or
presentation in another.

**A human state may name one page to open**, with `opens: form` (one name, no marker): while the
ticket rests there its queue item and its page lead with *Open `form` ›*, a link and not a decision
(`ui.md` § The queue). The page must be produced by some state, and until it has a version the
action says so.

**`optional` names what the job may finish without writing.** Everything in `produces` is
required by default: a job that ends having not written a document it declared has outcome
`error`, which is what makes a document a contract. A name in a job state's `optional` is excused
from that one rule and nothing else — the file's absence is not a failure, and when the absent
document is the one that carries the outcome the job is `done`, by the same rule as a state that
produces no document at all. The names are the artifacts' own, with no marker:
`produces: [presentation.md!]` is excused by `optional: [presentation.md]`, the spelling `inputs`
and `approve` use. Only a document or a page may be optional — `changeset` is the branch the job's commits
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
queue for the operator to pick any declared transition from that state manually, or to jump (§ Jumping) — except one
that approves or merges, which is taken on the ticket's page, where what it approves is on screen,
and which the queue links to. `max` caps
how many times a transition may fire for one ticket; exceeding it also sticks the ticket.

**Approval.** `approve` lists artifact names. The transition is not taken automatically; it
enters the queue as a decision, and the operator approves or rejects the latest version of
each listed artifact. A transition a person takes by hand records the same approvals as
part of the choice. Approval attaches to those exact versions. **An edge out of an integrating
state into a merging state approves `changeset` whether or not it lists it** (§ Merging, *What
follows the rebase*): the person who decides it, or takes it by hand, is approving the merge.

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

**An approval on an edge that queues merges nothing** (§ The merge queue): it records the approval
and queues the ticket, and **while the ticket is queued no other transition may be taken**, the
same rule as for a pending decision.

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
as for any job. It takes an optional **note**, carried as the arrival comment, and an optional
**raise of the ticket's cap** (§ Extending a job). On an agent state it is refused when the ticket
has nothing left of its cap unless the raise covers what the state's budget needs; with something
left but less than the state's budget, it runs lowered to what is left (`job.budget_lowered`) unless
the person raises the cap. A command state spends no tokens and is never refused for the cap.
The act, its guard and its checks are one transaction, and the ticket is locked in it.

**Extending a job.** A job that ended `budget_exhausted` on a ticket it stuck may be reopened by a
person (`Forge.Engine.extend/5`): the same job row and attempt, a new run, on its own session. Only
a person: no outcome, `transition.json`, `invoke.json`, scheduler or retry reopens a finished job,
and no workflow edge on `budget_exhausted` is involved. It is offered, and acted on, only when
`Forge.Jobs.Extensions.extendable/3` says so: a stuck, unqueued ticket; the job is the state's
latest attempt, `:workflow` and `:finished` with `:budget_exhausted`, and no job of the state is
live; the state is an agent state; and the job kept a session id and a session file. The figures are
**on top of what the job has used**, never a new total: the reopened run's token ceiling is the
extension's tokens, and its turn ceiling the extension's turns where the harness bounds them
(Claude Code; a Codex run is not bounded by turns, and the form has no turns box for it); the
wall clock is the per-run default and is not a person's to set. **The ticket cap:** tokens past what the ticket has
left are refused unless the same submission raises the ticket's cap by at least the shortfall;
the raise is stored as an addition (`tickets.cap_raise`), so a re-pin that moves the workflow's cap
moves it under the raise. Each of the extension, the restart and the raise is its own insert-only
record (who, when, the figures, the note), logged as `job.extended`, `ticket.retried` and
`ticket.cap_raised`. No `max` counts any of them, and either clears a pending approval. The job
runs on the spec it was created with even if the ticket was re-pinned since. A job may be extended again
once its reopened run has stopped on budget too, so each extension is the one stop it answers;
an extension while the job is live again (or while a Run again waits on a hold), and an extension
after a restart, are refused. **Only the run an extension was given to is told so**: it is stamped
with the extension (`job_runs.extension_id`) and its continuation opens with it, while a later run
of the same job — resumed after a question, a park or a limit — keeps the extension's ceiling and is
told what any resume is (`spec.extension.later_run`). A run the platform takes back with no
result — the harness refused its session, its machine was lost or never reached, or it hibernated —
lets go of the extension, and the run that follows takes it. **A cold run is told of the extension
whichever run of the job it is**, having no memory of an earlier telling. **A
second Run again on a held ticket is refused as a live job is**, since the first one's entry waits for
the release and a second would overwrite its note.

**Cancelling a ticket.** A person may cancel a ticket that is active or stuck
(`Forge.Engine.cancel/2`): the ticket becomes `cancelled`, every job of it that is still live —
pending, running, waiting, parked or hibernated — is finished with outcome `cancelled`, a machine
running one is told to stop, any pending approval is cleared, and `ticket.cancelled` names the
jobs it ended. **It is not a deletion.** Events and artifact versions are append-only
(`data-model.md`), the branch is the work, and a mistaken cancel must be undoable — so a cancelled
ticket keeps all of it and is **hidden everywhere a ticket is listed**: the project
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

**Holding a ticket.** A member may put an open ticket — active or stuck, in any state, of any
type, a release's included — **on hold** (`Forge.Engine.hold/2`), and release it
(`Forge.Engine.release/2`). While a ticket is on hold the platform takes no step on it by itself:
no job or command is handed to a machine, no transition is taken on the engine's own authority
(the retry edges `budget_exhausted` and `did_not_converge` included), a job
waiting on a credential's rate limit does not resume, a restart does not set its jobs running, no
chat step opens a conversation, and the merge queue does not merge it. An entry into an update step
waits too (`held_entry`), and release runs the step. A person's own moves work:
answering, approving or rejecting, taking a transition by hand, Accept, retrying; what they would
start waits for the release.

**A hold is three nullable columns on `tickets`, not a status.** `held_at` is the flag;
`held_transition` is `{job_id, state, outcome, from, to}` for an engine transition that waits, the
outcome being the *string* the engine routed on (an agent's declared outcome, or a command batch's
mapped exit outcome) and not the job's enum; `held_entry` is `{state, entered, came_back}` for a
job, command or chat step that waits to be made. A new status would lose a held ticket's place in
the merge queue (`run_entry/1` drops a ticket that is not `active`) and orphan the outcome of its
finishing run (`put_after_job/4` records a job whose ticket is not `active` as orphaned), both
without an error.

**Two layers, so that a race costs nothing.** *Deferral* covers what the engine would make while a
ticket is held: `put_after_job/4` reads the ticket row `FOR UPDATE` and, when held and the engine
would take a transition, writes `held_transition` and `transition.held` instead; `put_entry/6`
(where the engine makes a state's job, commands or conversation once a ticket exists — release
also uses it, so the two cannot drift; admission makes its first state's directly, behind its own
hold branch; the commands an agent invokes are inserted by `Forge.Jobs.Commands.put_invoked/7`,
which does not go through it and is held back by the dispatch gate alone) writes `held_entry`
instead of making anything; an approval, stuck and the
budget cap behave as they do today. *The dispatch gate* covers rows that already exist:
`Forge.Jobs.pending/2` leaves a held ticket's workflow and command jobs out and `mark_started`
re-reads the ticket `FOR SHARE` and refuses a held one, so a job placed from a read taken before
the hold is refused under the lock. A conversation is not gated: an open one is a person talking,
and carries on. A held ticket's pending job reserves none of the day's allowance
(`capacity.md`) and holds no claim on a machine.

**A run already going finishes**, and its outcome is recorded as it would be; the transition it
would take waits. **Stop now** (`Forge.Engine.stop_now/2`) is the separate, further action: every
live job and command of the state is finished as `cancelled`, the machine is told with the cancel
a cancelled ticket's is (`{:cancel, id, :ticket_cancelled}` — the worker acts on the cancel and
not the reason, so there is no protocol bump), what the run spent is settled by the worker's
report, and the state runs again on release as a retry would run it. A command state's batch that
has a cancelled command is never decided, and so `Forge.Jobs.Commands.recover/0` on a restart does
not take the failure edge for a batch that was stopped.

**What release does.** In one transaction: the row is locked and the hold re-read (so of two
people releasing at once one is refused with `:not_on_hold`); a ticket that **never started** is
refreshed; the hold is cleared; and what waited is made — the transition through `put_after_job/4`
with the outcome it was routed on, so `max` rounds, approvals and the budget are read now, or else
the entry through `put_entry/6` on the ticket's current pin; then the entry actions of the state
it moved into, as after any transition, and a kick of the merge queue. `ticket/N` is moved by the
transaction's last step, so that nothing which can refuse runs after the branch has moved; only
the commit can, and an infrastructure fault there is the one way the branch is left at the new
head under the old pin (a later release is then refused with `:branch_moved`). A move by hand out of the
state (`choose` — a jump included —, `integrate`, a retry) clears `held_transition`: it replaces the transition that
waited, which is then not taken.

**A ticket that never started** — `Forge.Tickets.started?/1`: no workflow job or command has
`started_at`, and no chat step's conversation has opened (a derived read, no column to keep true;
`mark_started` writes before it pushes, so a failed push counts as started and is released
without a refresh) — is **refreshed** when released: its workflow is re-pinned at the default
branch's head, its own type's file as `repin/2` reads it, `base_commit` moves to that head and
`ticket/N` with it, as a compare-and-swap (`git update-ref <ref> <head> <old base>`) after the
database writes and before a chat step's branch is cut. A job made for it before it was held that
no machine took is withdrawn (finished as `cancelled`) and made again on the new pin. **The
release is refused whole, changing nothing and leaving the ticket on hold, when the type's file
is gone or does not parse, when the new workflow has no state of the ticket's name, or when the
branch is no longer where admission left it.** A ticket that has started is released as it is.
Only a first start refreshes: keying it on "no commits" would re-pin a ticket held between steps.

**Cancel and restore.** Cancelling clears `held_transition` and `held_entry` and keeps `held_at`;
restoring brings the ticket back stuck *and* on hold, and nothing restarts on release that the
restore said would not. A cancelled ticket keeps its milestone, so one restored after the milestone
closed is put at the bottom of the tickets in no milestone, as closing would have put it, and the
move is an event (`ticket.milestone_set`): an open ticket in a closed milestone is in no list.

**Left alone on purpose.** `Forge.Merge.Watch` only records and tells. `Engine.resume_placement/2`
unsticks and starts nothing, since the gate holds the job, and excluding held tickets would make a
placement stick a dead end again. `Conversations.apply_transition_request/2` moves the ticket in
the opener's name, which is a person's move; it writes no hold. No job and no conversation can hold,
release or stop a ticket.

**Merging.** A state declaring `on_enter: merge` merges the `changeset` version the transition
into it named, not whatever the branch head happens to be, and checks it before a person's
transition into it is taken — and before the engine's own, when the state names `on_conflict`.
What a conflict does is the state's to say, with that key — § Merging.

**Budget.** `turns` and `tokens` (weighted tokens: `800k`, `4M`, an integer — `capacity.md` § Usage in
weighted tokens) are per job and required on every job state. `cost` (USD) is the older key: the
parser still reads it, converts it at `ForgeCore.Usage.per_dollar/0` and remembers it
(`Workflow.legacy_keys/1` lists what a workflow still names), and **admitting a ticket on a workflow with one is refused**, naming the
replacement. A ticket already admitted keeps running on the converted figure. `turns` bounds a
Claude Code run and does not bound a Codex run. A command state
has neither — there is no inference to bound — and is bounded by each command's `timeout` instead;
declaring `budget` on one is an error. Reaching
either ends the job with `budget_exhausted`, and the job row names which ceiling stopped it.
There are three, not two: the turn budget, the token budget, and the engine's wall-clock limit,
which is a default of the engine's and has no key here at all
(`capacity.md` § Four exhaustions, three treatments). `limits.ticket_tokens` (the older `ticket_cost`, refused the same way) is required and caps the
sum over all jobs of a ticket; reaching it sticks the ticket. Budgets are never modifiable by a
job. **A person may raise it for one ticket** on the Extend or Run again form
(§ Extending a job): the allowance is then `limits.ticket_tokens` plus the ticket's `cap_raise`.

**`limits.ticket_tokens` caps the jobs the engine starts, and not a conversation.** The workflow
and command jobs of a ticket are what it sums; a conversation opened on that ticket has no
ticket allowance and meets the daily cap alone, as `capacity.md` § Spend caps and
`conversations.md` § Spend already say. The allowance exists to stop a runaway workflow, and a
person asking why a ticket is stuck is not one — a cap that stopped them investigating would
work against its own purpose. A chat's spend is still recorded, on the conversation and its own
runs rather than on `ticket.usage` — **but for a chat step's** (§ Chat steps), whose turns add
to `ticket.usage`: the step is the ticket's own work, the next job's cap sees it, and nothing
the cap finds ends the conversation.

**Environment.** `env` is a devShell name in the project's `flake.nix`; the job runs inside
`nix develop .#<env>`. Absent `env` means no toolchain beyond the harness.

**Harness.** `harness` names which execution harness runs this state's job: `claude_code` or `codex`
(`ForgeCore.Harness.names/0`; `docs/design/codex.md`). A job's harness is its state's, else its
project's setting, else `claude_code`, so a workflow naming none behaves as before. A command state
has none. The model and effort chains below walk the **job's harness's** settings: a project holds
a model and an effort for each, its existing ones being Claude Code's, and `FORGE_CLAUDE_MODEL` /
`FORGE_CLAUDE_EFFORT` remain Claude Code's alone.

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

**Effort.** `effort` names how hard the harness thinks on this state's job — for Claude Code,
one of `low`, `medium`, `high`, `xhigh`, `max`. It is optional, and the gap is filled by the same
chain `model` walks: the state's, then the project's, then whatever the machine was built with.

It is per state for the same reason `model` is, and it is a second dial rather than a facet of
the first: the model is which mind does the work and the effort is how long it is given to think,
and a workflow routinely wants a small model thinking hard or a large one answering quickly. A
grammar that folded them together could not say either.

**Not validated against a list of levels.** The levels belong to the harness, not to this
platform, and `effort` is meant to reach harnesses that do not exist here yet — so a list written
down here would be both stale and wrong for everything but Claude Code. What is checked is that it
is a non-empty string. A level the harness does not recognise fails the job with the harness's own
message, which is better than one the platform invents.

**The product offers a list; the grammar still does not.** The harness driver declares its levels
as it declares its model aliases, and a worker reports them when it becomes ready
(`docs/design/worker-channel.md` § What a worker offers). A surface where a person picks an effort
is a dropdown of the union across the workers connected now, in the order of the reports (workers
built from one image agree, so that is the harness's own). Like the model field, it is **free text when no connected worker offers a level** — including when
a level is already stored — so a project can be configured before a machine exists. A stored level
that nothing offers stays in the list, selected and marked "Set", so saving the form unchanged
never alters it. And the list is an offer, not a gate: a level that is not in it is still stored,
which is what lets a harness newer than its workers keep working.

Parsing this file reaches no worker, so the rule above is what the grammar checks, and it is
unchanged. A workflow may name any level; only the form has a list.

### Jumping

A **jump** moves a ticket to any state of its pinned workflow, whether or not a transition leads
there from where it rests. It is the escape hatch for a workflow gone wrong — usually one in which
the transition that would put things right does not exist — made by an active member of the project
on the ticket's page, through a token with API write access (as API), or through a ticket chat
(`conversations.md` § Taking a transition). Everyone meets the same operation, `Forge.Engine.choose/4`,
and the same rules.

**What is an edge and what is a jump.** A request names a target state. When a transition from the
current state that the ticket *offers* resolves to it — the only edge there, or the bare edge among
several (`ForgeCore.Engine.choose/4`'s default), or the one an API call's `outcome` names — the
request takes that transition exactly as before: its approvals, its `queue`, its `max` count.
Every other target is a jump: one no edge reaches; one several edges reach with no bare edge among
them; and one whose only edges are not offered because their `approve` names a document with no
version. An unknown state is refused. A caller may say which kind it drew (`jump: false` for a
declared way forward, `true` for a fold row), and a request that finds the other kind is refused
rather than taken, so a press drawn before the ticket moved never becomes the other kind — an edge
that would approve a document the person never saw. The merge queue says `jump: false`: it offers
no jumps.

**Required inputs.** A jump into a state that starts a job is refused when the job would be created
missing an input the engine requires (`required_input?/3`), by the creation itself, in the one
transaction that moves the ticket: a missing input rolls the whole jump back with the input's
name, and the version checked is the version the job is created with. **A ticket on hold makes no
job when it is moved** (§ Holding a ticket), so the same rule is asked there, after the row is
locked, and a jump that would make a job for `release/2` to find an input missing is refused with
the input's name. An optional input that does
not exist is no reason to refuse. A command state or a chat step requires nothing at creation, and
a human or a terminal state starts nothing. A ticket chat may write a missing document first, in
the same turn or an earlier one.

**Approvals.** A jump records none, whatever the transitions into its target declare
(`docs/decisions.md`). The one exception is a jump into a state that merges: it is refused when
there is no changeset version, or no `commit-message` version where the pin has a state producing
one, and otherwise it records one approval of the changeset's latest version — the version the
merge merges — in the name of whoever made it, as an approval by hand does.

**Merging.** A jump into a merging state joins the project's merge line when any declared
transition into it says `queue: true`: the ticket stays where it is, `active`, with an entry whose
`jump` is true. Otherwise it merges at once, as an approval in that workflow does, a conflict going
down the merging state's `on_conflict` with the approval recorded: that move is the conflict route's,
recorded as an approval's is (`ticket.merge_conflicted`, the edge at outcome `merge_conflict`), and
not as a jump event — what sent the ticket there was a conflict. **A source that has landed merges
cleanly**: the check before the jump asks `already_merged?` as the merge does, so a done ticket
jumped back into its merging state with nothing new is not called a conflict with its own landed
work (a squash-merged commit merged again against its old base would be, wherever the default branch
has touched the same file since). A queued jump taken out of the line by a person (`take_out/2`)
restores no approval to be asked again; the ticket rests where it is, **stuck** where it is in a
state with no way out — a done or stuck ticket jumped to its own terminal merging state.

**An integrating state** may be entered by a jump with no conflict behind it. Its job is told it
arrived by a jump and that no conflict sent it, and is handed no conflicting paths
(`job-prompt.md` § Integrating the default branch). This is the one exception to "nothing but a
conflict" (§ Merging).

**A ticket that is done may be reopened** by a jump, becoming active in the state named; a
cancelled one is refused. When it had merged, the branch is first brought to what the default
branch holds — a merge of the earlier merge commit into the branch head, which moves the branch
by compare-and-swap, last in the jump's transaction — and the ticket's base becomes that merge
commit (`git-hosting.md` § The merge), so the next merge, the changeset a person approves for it and
the diff the page shows are only the work since. **Reopening meets what restoring a cancelled ticket
does** (`Engine.restore/2`): a milestone closed since leaves the ticket in none, and a release is not
reopened while another is open (`{:release_open, ticket}`, § Releases in `ticket-types.md`).

**A jump counts against no `max`** and is not a firing of any transition, so it is not drawn as a
loop. Every other refusal a move by hand meets still applies: a live job or conversation in the
current state, a pending decision, a ticket in the merge line, a pin that no longer parses, a
requester who is not an active member. A jump to the state the ticket is in is a jump like any
other: entering it does what entering it does. A step conversation has none (§ Chat steps).

**The record** of a jump that takes effect is a `transition.taken` event with `jump: true`, no `outcome`, the `from` and `to`,
the comment, `reopened: true` when the ticket was done, and the changeset and commit message it
names when the target merges, by whoever made it. The job it starts reads `entered.jump`. Jobs
arriving by a jump need worker protocol 12 (`worker-channel.md` § What needs a bump).

## Schedules

A workflow file may declare tickets of its own type that the platform admits on a clock, so that a
regular piece of work — a weekly cleanup, a monthly dependency check — need not wait for a person
to press *new ticket*. `docs/design/schedules.md` is the note: what *on* means, what is done when a time
is missed, and who a ticket is admitted in the name of. This section is the grammar.

```yaml
schedules:
  - name: weekly-cleanup
    cron: "0 6 * * MON"
    title: Weekly cleanup
    body: |
      Look for dead code and stale comments in `core/` and remove what nothing uses.
```

`schedules` is a **list**, not a mapping, because YAML keeps the last of two equal keys of a mapping
and "two schedules of one name" would then be impossible to refuse. Each entry has exactly four
keys and all four are required, non-blank strings:

- `name` follows the rule of a state's name (letters, digits, `.`, `_`, `-`, starting with a letter
  or digit) and is unique within the file. It is what a person's switch belongs to: a renamed
  schedule is a new one and starts off. At most 100 characters.
- `cron` is five fields — minute `0-59`, hour `0-23`, day of month `1-31`, month `1-12` or
  `JAN`-`DEC`, day of week `0-7` or `SUN`-`SAT` (0 and 7 are Sunday) — **read in UTC**. A field is
  a comma list of `*`, `n`, `a-b`, `*/s` and `a-b/s`. There is no `@weekly`, `L`, `#` or `?`. A step
  of 0, a reversed range, a value out of range and a line that names no date that exists (`0 0 30 2
  *`) are refused, as is a line over 200 characters (the platform keeps it in a row). **No lower
  bound is put on how often it may fire.**
- `title` and `body` are the ticket it admits. The ticket's title is the `title` and the UTC date
  the time was due — *Weekly cleanup · 2026-11-23* — and its body is `body`, exactly as a ticket
  written by hand carries its own, shown as text wherever it is drawn.

**When both day fields are restricted a day must match both.** `0 9 1-7 * 1` is the first Monday
of the month. Standard cron reads it as days 1 to 7 *or* any Monday, which is about eleven firings
a month and is not what the line is written for; this dialect has one rule, and it is the
narrower.

**A schedule on the default branch is off.** Nothing is admitted until a project admin switches it
on from the project page, and every ticket it admits is admitted in that admin's name. Once on, it
follows the file: its cron line, title and body are read at the time it fires (§ Pinning: the
ticket pins the same commit the title was read from). A schedule is declared in the file of the
type it admits, or in `.forge/workflow.yml` for a project with no types, and **never in the release
type's file**, which a schedule may not start (`docs/design/ticket-types.md` § Releases). A library
may not hold one.

## Release keys

Two top-level keys, meaningful only in a workflow that sets `release: true`
(`ticket-types.md` § The record, the tag, the history), and a convention for a document.

```yaml
release: true
release_files: [package/*, images/*]   # groups of files that belong to the release
release_notes: release-notes.md        # the document that is the release's notes
```

- `release_files` is a list of groups, spelled as `produces` spells them (`name/*`), each produced
  by a state or by a command's `produces`. Only these groups are listed on the release's record;
  every other group stays on the ticket. Absent is none.
- `release_notes` names one plain document that a job state (one with a prompt and not `chat: true`)
  produces. The record keeps its text at its latest version when the release concluded, with front
  matter removed; the same text is the git tag's message.
- **`links:`** in a job's document front matter is a list of entries, each `{label, url}`, the way
  `version:` is read: only a job's documents count, presentations included, and a chat step's and a person's edit do not. A release's record
  lists the links of the latest version of every such document when it concluded. An entry whose
  label is not a non-empty string of at most 200 bytes, or whose url is not an absolute `http` or
  `https` URL with a host, of at most 2048 bytes and without whitespace or control characters, is dropped alone; only the
  first 50 entries of a document are read; a list that is not a list is
  ignored; neither fails the job that wrote it.

## Chat steps

**A job state marked `chat: true` is a conversation, not a one-shot job.** It keeps everything a
conversation can use — `prompt`, `inputs`, `produces` (documents and pages), `outcomes`, `env`,
`model`, `effort`, `resources`, `secrets` — and gains one difference: when a ticket enters it, no
job runs. A ticket conversation opens on the ticket (`conversations.md` § A conversation that is
a step) and the ticket waits for a person. The documents the step declares are written as the
conversation goes; when the person is satisfied they press **Accept**, pick the outcome when the
step declares more than one, and the ticket takes the edge for that outcome as after a job. Until
then it stays in the step. **While the ticket is on hold no conversation opens** (§ Holding a
ticket): the entry waits and the conversation opens at release; one already open carries on.

```yaml
states:
  refining:
    chat: true
    prompt: agents/refine.md
    inputs: [ticket]
    produces: [refinement.md]
    outcomes: [done, needs_more]    # the person picks; no outcome is preselected
```

- **The person alone chooses the outcome.** An `outcome:` in a document's front matter is ignored
  and the agent is not offered `transition.json` for this ticket in this step — so no jump either
  (§ Jumping); a separate ticket chat can be opened to repair. An edge on an
  engine outcome (`error`, `did_not_converge`, …) never fires from a chat step: nothing in it ends
  without a person.
- **Accept is the approval.** When the edge Accept takes has `approve`, Accept approves those
  documents, as a by-hand approval would, with no second decision. **Every document it records or
  approves is pinned to the version the person was shown**: the step's own `produces`, and the
  documents that edge approves, which may be an earlier state's. The page lists each and sends its
  version back; a newer one recorded since — by the step's agent, another conversation or a person
  through the API — refuses Accept and redraws the page, so nothing is approved unseen. An edge
  approving a document nobody has written yet is drawn as blocked (`Engine.offered_edges/2` does
  not offer it either) and says to ask the agent for it, which the step may write.
- **No ceiling.** `budget` is refused. The node's daily cap and the idle timeout still pause or
  end the conversation, and the ticket stays in the step. Its spend is added to the ticket's
  cost and is seen by the cap on later jobs; the cap never ends the chat (§ `limits.ticket_tokens`).
- **A visit is one conversation.** A ticket returning to the step over a backward edge opens a
  new one, which is told it is a return. Carrying a conversation on with a message is not a new visit.
- **Not a changeset step.** A chat commits to its own branch, so `changeset` and `commit-message`
  are not produced here; what a step conversation commits never reaches the ticket's branch.
- **Every other rule applies unchanged** (reachability, each outcome having an edge, `approve`
  produced by `from` or earlier, `max` on edges): a chat step is a job state to the engine's
  graph, and `ForgeCore.Engine.step/4` treats it as one.

## Bringing the branch up to date

```yaml
states:
  refresh:
    on_enter: update
    on_conflict: resolving      # optional; a job state or a human state, as a merging state's
  resolving: { prompt: ..., ... }
transitions:
  - { from: implementing, to: refresh }
  - { from: refresh, to: checking }
```

A ticket's branch is cut from the default branch at admission and nothing moves it afterwards. A
state declaring `on_enter: update` is how a workflow says *here*: entering it brings the ticket's
branch up to date with the default branch, runs **no job** and spends nothing, and the engine then
takes the state's one edge out at once — or sticks the ticket instead, when the ticket's token cap is
spent (also on a conflicted visit) or the clean edge's `max` is exceeded (a conflict is not bound by a
`max`), as the end of a job would (§ Semantics). It is the platform's own step. Which edges lead through
one is the workflow's decision — the engine has no built-in lifecycle (`docs/decisions.md`) — and a
workflow may have several.

**Every entry runs it, and a retry never does.** The step is run by the transition into it, from
whichever act took the transition (a job's result, a person's choice, an approval, a command, a
conversation's Accept), by a release replaying an entry, and by boot's recovery; the merge queue only
enters merging states and never takes one. A job resumed or retried in the state after it keeps its working tree, so nothing
moves a branch under a running job: the step is entered after the job before it has ended, and
a ticket that still has a live job of its own (a state the product does not make) is stuck by the
step, with its branch where it was.

**Four results**, from the ticket's head `H` and the default branch's head `D`:

- *current*: `D` is already in `H`. No branch moves and no changeset is recorded.
- *forwarded*: `H` is in `D`, the branch has nothing of its own. The branch moves to `D`, with no
  merge commit and no changeset version (an empty change on every ticket that passes a step before
  it has work would be noise).
- *merged*: the branch has its own commits and `D` merges cleanly into it (`merge-tree`). The
  platform writes the merge commit — parents `H` then `D`, message `Merge <default> into
  ticket/<n>`, author and committer the platform — and records a `changeset` version of it, by the
  engine.
- *conflicted*: the merge conflicts. The branch is not moved. The ticket goes to the state's
  `on_conflict`, taken on the outcome `merge_conflict` as a merging state's is, and its job is
  told what conflicted and given the default branch (`docs/design/job-prompt.md` § Integrating the
  default branch). With no `on_conflict` the ticket sticks, saying which paths conflicted. The
  visit is recorded as `ticket.branch_updated`, **not** as `ticket.merge_conflicted`: the
  three-in-a-row bound (§ The merge queue) reads that event only, and an update step's loop is
  bounded by the `max` on the edges it runs through, by a person, or, where a workflow has neither, by the ticket's token cap, which the step checks before it takes its edge. The validator does not require any of them.

**The write is the platform's push, never a ref set directly.** Every move of the branch is a
push of the new head to `refs/heads/ticket/<n>` with `--force-with-lease` naming `H`, so
`pre-receive` and the mirrors see it as they see every other write (`git-hosting.md`). If the
branch is no longer at `H` the push is refused; the step reads the branch again and decides once
more from the new head. If the branch moved a second time it sticks the ticket, saying the branch is
being pushed to while the step runs (the rule `git-hosting.md` § Where it runs gives the
merge).

**The base moves with the branch.** In all three clean results the ticket's base becomes the merge
base of the new head and the default branch (the rule of § Merging, "The ticket's base follows an
integration"), and `ticket.base_moved` says so — when that is past the base, which a visit that
found the branch already current, with the base already there, is not. The diff shown on the ticket and handed to a job
as `changeset` is the branch against its base, so it holds the ticket's own work and not what the
default branch brought in. Every job's manifest names the base (`job-prompt.md`).

**It re-pins.** In the same step the ticket is re-pinned to its type's workflow at `D`, the commit the
code was brought up to, whether the merge was clean or conflicted, and `ticket.repinned` records
both commits, by the engine. The edge out is decided on the workflow the ticket then has. The
re-pin is **skipped**, with the reason recorded on `ticket.branch_updated`, and the ticket goes on,
when the workflow at `D`: has no file for the type any more, fails to parse or validate, cannot be
read at all, has no state of this name, or has one that is not an update step (so there is no edge
to take). A ticket
whose pin has no update step never passes through one, and the engine never re-pins it; a person's
re-pin (§ Pinning) is how it gets one.

**An edge out of the step may lead into a merging state** (route (b), § Merging). The transition the
engine then takes names the changeset version the step left — the one it wrote when it merged, the
latest one otherwise — and merges that, recorded as the engine's. An approval a person gave earlier
stays recorded against the version it was given on; it is never moved to a version the step wrote,
so a workflow that routes a step straight into a merge can merge a version nobody read. That is the
workflow's decision, as route (b) is, and the validator does not refuse it. With `queue: true` on
the edge the ticket enters the merge queue with that version; a ticket already in the line, or in
the queue now, is left alone by the step.

**Hold.** A ticket on hold does not run the step on entry; it writes `held_entry` and the step runs
when the ticket is released (§ Holding a ticket). A hold that lands after the entering transaction
but before the step looks is seen by the step, which leaves the ticket alone; a hold that lands while
the step is running is seen when it records: it records the visit and keeps the entry. **Release runs
the step for any active ticket resting in one**, which decides on the branch as it is then — a
*current* visit and the edge when nothing conflicts, the conflict route when something does.

**Nobody acts inside a running step.** While a ticket is active in an update step `choose`, re-pin
and integrate are refused (`{:updating, state}`) and there is no job to retry. A step that stuck
the ticket offers its one edge out. A stuck step is not retried in place: a workflow that wants
*try again* routes a human state back into it. A crash between the git work and its record leaves
the ticket active in the step; boot runs the step again for such a ticket, and a second run finds
the branch *current*.

**A visit that fails to record leaves the base where it was.** The merge is already pushed when the
record transaction runs, so a record that fails, or a ticket cancelled while the git half ran,
leaves the branch ahead of its base. The base moves again when a job's result records a
`changeset` (§ The ticket's base follows an integration) or when the ticket passes an update step
again (a clean visit moves it, a *current* one included), and a job started in between reads the old
base. The ticket is stuck in the step when the record fails.

**What it records.** `ticket.branch_updated`, by the engine, for every visit it records (a record
transaction that fails writes none, and sticks the ticket) — the head before and
after, `D`, the result, the conflicting paths, the merges brought in, whether it retried, and the
re-pin or the reason there was none.

**Validation.** Beside the rules of a merging state: an update step has no prompt and no `invoke`,
no `produces`, exactly one transition out with no `when` and no `approve`, and that transition does
not lead into an update step (no chain, no loop with no job in it); it is not `initial`; it is not
also a merging state; its `on_conflict` is a job state or a human state with a way out, never an
update step. Several steps may share one conflict state, and a human state may have an edge back
into a step.

## Merging

```yaml
states:
  merged:
    on_enter: merge
    on_conflict: integrating     # a job state or a human state of this workflow
```

An `update` step (§ Bringing the branch up to date) names its conflict state the same way, and that
state is an integrating state too.

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

**One exception, decided by the pin and never by the missing version.** A pinning whose workflow
has no state producing `commit-message` — one stored before 0.16.0 added the document — can never
get a version, so its merge says what the platform wrote for every merge until 0.15.0: the subject
`Merge <branch>: <title>`, then `Ticket:`, `Changeset:` and `Approved-by:` (`Forge.Merge.legacy_message?/1`).
A pin that *has* a producer and no written version sticks as above.

`refs/forge/approved/<n>` is written by each merge attempt, at the commit it merges, whoever's
transition named it — on route (b) the engine's attempt writes it, after an approval that was
already on record (§ *What follows the rebase*). The name is history; what it means is *the commit this ticket's merge was last attempted for*, kept
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
to read, unless the pin has no state producing it (§ Merging).

**The target is a job state or a human state, with a transition out.** A job state is the usual
case, and a job state that is some merging state's `on_conflict` is an *integrating* state: its
job's checkout also fetches the default branch, read-only, and its manifest says what conflicted
and how to resolve it (`job-prompt.md` § Integrating the default branch). **Nothing but a conflict
or a jump (§ Jumping) may lead into an integrating state** — no declared transition names it as `to`. What makes a job
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

  # (b) straight to the merging state, with no second approval
  - { from: integrating, to: merged }
```

On route (a) the approval names the integrated version and needs giving afresh; the approval of
the version before integration cannot merge it. Route (b) is the engine's own edge into the merging
state, so it is checked like any other: still conflicting — or the default branch moved again while
the job ran — it takes `on_conflict` again.

**What follows the rebase: route (b) needs an approval already on record.** Route (b) carries no
`approve` because it is meant for a ticket whose changeset a person already approved and then
conflicted: the approval of the version before the rebase is the one that stands. The engine
therefore reads the record before it takes an edge **out of an integrating state into a merging
state** for a ticket that is not in the merge queue (a ticket in the line goes back into its old
place, as below, with no new approval asked for). *The record* is the approvals of `changeset`, on
every version, approved and rejected alike (`Forge.Artifacts.changeset_decision/1`). **It stands**
when its latest decision is an approval that was not withdrawn; it does not when it is empty, when
the latest decision is a rejection, or when the latest approval was withdrawn by taking the ticket
out of the queue. "Latest" is by version, then by when, and a rejection recorded in the same
second as an approval of the same version counts as the later (`approvals.inserted_at` is whole
seconds, and the safe reading is the one that asks again).

- **It stands:** the edge is taken as written — queued when it says `queue: true`, otherwise
  checked and merged. This is what keeps route (b) as it was for a ticket the queue sent: its
  approval was recorded on the way in and is withdrawn only by taking it out of the line, which
  takes the ticket out of this path too (it then asks, below).
- **It does not:** the ticket stays in the integrating state with a decision pending on that
  edge, approving `changeset` at its latest version (the one the rebase wrote), and
  `approval.requested` is logged. Approving it takes the edge as an approval of any edge into the
  merging state does — queued, or checked and merged; rejecting it needs a note, records the
  rejection and leaves the ticket stuck with its declared edges offered. Nothing is merged and no
  row is made in the line until a person approves. This holds with or without `queue: true` on the
  edge. The record is read when the engine takes the edge, not when the job ended.

An edge out of an integrating state into a merging state **approves `changeset`** whether or not
it declares it, for whoever takes it: a person who decides the pending approval, who takes it from
the ticket's chooser, or whose conversation writes `transition.json` for it, or who accepts a chat
step that is the integrating state. Without that, the hand-taken edge would merge a changeset with
no approval of it on record.

Only an edge out of an integrating state is read this way. A workflow in which neither a merging
state nor an update step names an `on_conflict` has no integrating state, and an engine edge into
a merging state — `release.yml`'s `publishing → merged` — merges as it always did. An update step's
conflict state counts: an edge out of it into a merging state needs an approval on record, even
when the merging state names no `on_conflict` of its own. One consequence: a workflow that names an
`on_conflict` and draws route (b) with no approval anywhere on the way to it now stops at the
rebase for an approval after a conflict, where it used to merge.

**That loop is bounded by the platform, not by `max`.** The engine sends a ticket down
`on_conflict` by itself at most **three times in a row**: an engine-taken edge into the merging
state whose check conflicts takes `on_conflict` only while fewer than three
`ticket.merge_conflicted` the engine took have been recorded since a person last moved the ticket —
took a transition, ran its state again or put it in the merge queue (`merge_queue.entered`, by a
person; the engine's own enqueue does not count). The fourth sticks the ticket where it was, in the
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
transaction, and `ticket.base_moved` says from where to where. Of the runs on a ticket's branch
only an integrating job's checkout can see the default branch, so in practice that is the
integrating job's result; a person's hand resolution moves it the same way when the next job
records the branch. A conversation's checkout can see it too (`conversations.md` § Commits), but
it commits to `chat/<id>` and records no `changeset`, so nothing of it reaches here. An `update`
step moves the base itself when it moves the branch (§ Bringing the branch up to date).

**A conflict can be found before the merge.** After every merge into the default branch — a
ticket's or a conversation's — the project's other open tickets with a changeset are checked, and
one whose latest changeset no longer merges is told so on its page, once per commit, with which
merge caused it
(`docs/design/ui.md` § The details). Nothing starts by itself: a job spends a credential,
and the ticket may be one its operator is about to cancel. A person can send it down the conflict
route from there (`Forge.Engine.integrate/2`) when its state has an edge into a merging state with
`on_conflict` and nothing is live in it: the check is run again, a conflict takes the same route an
approval that conflicted takes — less the approval — and a pending approval is cleared, since the
version it would approve is about to be replaced. A ticket that merges cleanly by then is refused,
and the notice it acted on was stale. **The rebase does not merge such a ticket by itself**: it
was sent with no approval, and when its rebase ends the engine reads the record (§ *What follows
the rebase*) — an unapproved ticket waits at the integrating state for a decision on the rebased
changeset.

The merge itself is idempotent, so entering the merging state twice merges once.

### The merge queue

An edge into a merging state may say `queue: true`:

```yaml
  - { from: review_ready, to: merged, approve: [changeset], queue: true }
```

Taking that edge **takes no transition**. It records the approvals, if the edge has any, and puts
the ticket in its project's line (`merge_queue_entries`, one row per queued ticket); the ticket
stays in `from`, `active`, with nothing pending, and nothing is checked for a conflict. Wherever
the key is declared it is always in force — there is no project, user or ticket setting that turns
it off for that edge, and a workflow with no `queue` key never writes a row, so approval merges
at once and a conflicting approval takes the conflict route exactly as above. **A jump into the merging state
queues when any declared edge into it does** (§ Jumping): its entry has no edge, only the states it
was queued from and for, and `jump` true; the runner merges it by a jump of its own, as the system,
with the changeset and commit-message versions it was approved on, and a conflict goes down
`on_conflict` as for any entry. Taking it out restores no pending approval, and the ticket sticks
(or rests in a human state) as for any other. The engine's own
edge into a merging state queues the same way (it is the ticket's place that matters, not who
asked), with the job's outcome behind it — **except out of an integrating state, where it queues
only a ticket whose approval is on record** (§ Merging, *What follows the rebase*). The row of
such a ticket carries the approval it stood on, so taking it out of the line withdraws that
approval too.

**A ticket on hold keeps its place in the line and is skipped** (§ Holding a ticket): `claim/1`
passes over a waiting entry whose ticket is held and takes the one behind it, `lock_entry` puts a
claimed row whose ticket was held since back to `waiting` at its place rather than leaving the
line, and the places the line draws do not count a held entry as one a ticket waits behind.
Released, it is merged from the place it kept.

A runner takes the line one project at a time (`Forge.MergeQueue.Runner`; the work is a task of
its own, not the request that approved):

- **Order** is the row's `position`, a database sequence, so it is the order approvals were
  recorded in and it is the same after a restart. A ticket approved again is a new approval and
  goes to the back.
- **One at a time.** The front `waiting` row is claimed by making it `merging`; a partial unique
  index on `(project_id) where status = 'merging'` refuses a second one, which is the guard.
  Projects do not wait for each other.
- **The front is checked** against the default branch's head, on the changeset version and with
  the `commit-message` version that were current when it was approved (after an integration, the
  changeset it produced and the latest message). Clean: the edge is taken
  (`transition.taken` names both) and the merge made, and the ticket leaves the line as merged.
  Conflicting: the conflict route is taken as for any engine edge, the three-in-a-row bound
  included — a person's entry into the queue (`merge_queue.entered`) starts the count again, as
  taking a transition does — and reaching the bound sticks that ticket with the message above and
  nobody behind it. Any other failure (no changeset, no commit message, a push refused) sticks
  that ticket with the reason. A stuck ticket is out of the line; one bad ticket never holds it.
- **Integration keeps the place** and does not hold the line: a row being integrated
  (`integrating`) is skipped over, and the tickets behind it that merge cleanly go first. When the
  integrating job ends, an edge straight to the merging state puts the row back to `waiting`
  (`merge_queue.returned`) against the changeset the integration produced, to be checked in its
  turn; an edge to any other state — and an approval to be given, or a stick — takes the ticket out
  of the line (`merge_queue.left`), because it needs a person again. A `on_conflict` that is a
  human state leaves on arrival for the same reason.
- **Taking a ticket out** (`Forge.Engine.take_out/2`) is an unapproval, by a person who may
  approve on the project: the approval rows are marked withdrawn (they stay, and `approved?` no
  longer counts them), the row goes, and the ticket is again where it was approved from — the
  pending approval when a job's outcome asked for it, the chooser when it rests in a human state,
  otherwise stuck so a person is offered its edges. It must be approved afresh to be queued again.
  Allowed while waiting and while integrating. During integration the job is not stopped: only the
  merge after it is, because when the job ends the engine does not take an edge into the merging
  state for a ticket a person took out since it entered its state (it sticks with its edges
  offered); an edge to any other state is taken as the workflow says. It is refused while the
  merge itself is running, and, for a ticket that is not queued, with how it left (merged, or
  taken out by someone else).
- **While queued, no other transition may be taken** — `choose`, retry, integrate, re-pin and a
  chat step's Accept all refuse with `:queued`, at the operation, whether asked by the page, the
  API or a conversation. Accept meets it when a conflict route leads into a chat step (§ Chat
  steps): the step's conversation runs as an integration does, and its Accept waits until a
  person takes the ticket out, after which it takes the edge as it would on any ticket.
- **Recovery** is the runner's task's first act, and a node has only one task for a project: it
  registers under the project's name (`Forge.MergeQueue.Registry`, local to the node) and a second
  finds the name taken, asks for it for a couple of seconds in case its holder is just finishing,
  and stops. Its tasks outlive a restarted runner, so holding the name is how a new task
  knows whether a live one owns a `merging` row; holding it, any `merging` row is a task's that is
  gone (a crash of the platform, the runner or the task), including one whose runner was down when
  its task died, and a project with only such a row is started like one with a waiting row. A row
  left `merging` is finished from where its ticket got to: in the merging state, the merge is
  finished (entering is idempotent); sent down the conflict route, the row becomes `integrating`
  and keeps its place; still where it was queued from, back to `waiting`; anywhere else, the row
  goes. A task that dies is started again after a delay, so a row that kills it does not spin.
- **The ticket row is locked** wherever the line and the ticket are decided together: taking out, a
  job's result arriving for a ticket in the line, and the runner's merge or stick. Each re-reads
  the row under the lock, so a take-out and an integration finishing at once are serialised and
  each sees the other's result.

`approve` is not needed on a queueing edge; without it the edge queues and only the engine's
runner takes it.

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
    keep_build: [0, 1]               # optional: exit statuses whose tree the ticket's next command starts from
    warm_start: false                # optional: do not start from that tree (default true)
```

**`timeout` is a duration**: a whole number and one unit — `90s`, `20m`, `2h` — or a bare number of
seconds, and at most a day. One unit only; `1h30m` is written `90m`. A command that outlives it is
stopped, and ends with no exit status. `run` and `timeout` are required; `env`, `produces`, `resources`, `keep_build` and `warm_start` are not.
`produces` is where the combined output is recorded on the ticket, as a blob: without it the
output is still kept with the command's own job, and still handed to an agent that invoked it.
**It produces no page** (`name@` is refused here). It may instead be a list of at most one such name and any number of groups of files —
`produces: [package.log, package/*]` — whose files the script writes into `$FORGE_OUT/package/`.

**`keep_build` and `warm_start`** say what a command passes on and what it starts from
(`docs/design/worker-tier.md` § The command copy). `keep_build` is a non-empty list of whole
numbers from 0 to 255: when the script exits *on its own* with one of them, its tree becomes the
ticket's command copy on that machine, for the ticket's next command. Absent, the command keeps
nothing, as before. The numbers are written as numbers — not `"*"`, and not digits in quotes — and a
timeout, a cancel or a kill never keeps whatever is listed. `warm_start` is `true` or `false`, and
`true` when absent: `false` makes the command ignore the ticket's copy and start as it would
without one. Both are on a *command* and nowhere else; on a state or under `defaults` they meet
the unknown-key refusal, which names where they are, and a value of the wrong kind is refused
naming the command and the value (`commands.build.keep_build`).

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
belongs inside the checkout, ignored by git: that is what the project's seed, a ticket's volume and
a ticket's command copy keep (`docs/design/worker-tier.md` § Volumes and the seed, § The command
copy). The command copy is the one a *command* leaves, and only when its definition says
`keep_build`.

**Arguments are freeform and carry no schema.** An invocation supplies a list of strings and the
worker `exec`s the script with them as an argument vector — never a string given to a shell, so
`--filter "foo bar"` cannot word-split. A state's `invoke` entry is either a command name or a
list whose head is the name and whose tail is the arguments: `[test, --all]`. There is no
parameter declaration to validate against, and the exact vector is recorded on the invocation
because it is no longer derivable from this file.

**`invoke` makes a command state.** It lists commands to run on entry, and the state has no
`prompt`, `inputs`, `produces`, `outcomes`, `budget`, `model`, `effort`, `env`, `may_invoke` or
`secrets` — each command brings its own environment, and its own secrets. It may carry `resources`, which its commands fall back to (§ Resources).
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
    budget: { turns: 200, tokens: 2M }
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

**A pinning is read as it was admitted.** The stored definition is built against the grammar — its
keys and the types of its values — and is not validated again (`Parser.from_pinned/1`).
Validation belongs to admission and re-pinning, which read the file as it is now and are exactly
as strict as the validator is: a rule added later binds the next admission, never a stored pin.
Reading a pin through the validator was the defect of 0.16.0, whose `commit-message` rule rejected
every definition stored before it and gave each of those tickets a 500 on its page. What can still
fail is a pin the grammar can no longer build, because it dropped a key the pin uses. The ticket
page then says that the workflow it was pinned to can no longer be read, with the errors behind a
disclosure, and offers Re-pin when `.forge/` has changed on the default branch and Cancel while the
ticket is open (Restore once cancelled) — neither reads the old pin. An address naming its Changes view draws Steps,
which is all such a ticket has. The
engine reads such a pin with `Tickets.workflow/1`, which raises, and the page offers no action that
reaches it (cancel, restore and re-pin do not read the old pin).

A stored definition with no `queue` key reads every edge as `queue: false`.

**Re-pinning is a person's act, with one exception: an update step** (§ Bringing the branch up to
date) re-pins by the engine, at the default-branch commit it brought the code up to, and records the same
`ticket.repinned` event with the engine as the actor. A pin whose workflow has no update step never
meets it. What follows is the person's (`Forge.Engine.repin/2`). It reads the workflow of the ticket's
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
The details). A ticket that changes a command script still sees the change only after it
merges: re-pinning takes the default branch, never the ticket's own.

## Validation (rejects the file, never partially runs it)

- **Pages** (`name@`, § Semantics): refused on a command, a command state, and a human or `on_enter`
  state; refused where one name is a page in one state and a document, group or presentation in
  another, a command's groups included; refused as an `inputs` entry and as an `approve` entry;
  `optional` may name a page. **`opens`** is refused anywhere but on a human state, and when it names
  a page no state produces, or more than one name. A chat step may declare pages (it still declares
  neither groups nor presentations). Each is refused by name, with the reason.
- `version` is `1`; `initial` names a job state; every state name is unique.
- A job state has `prompt` and `budget` (a chat step has no `budget`; § Chat steps), and neither `invoke` nor `exit`. A command state has
  `invoke` and `exit` and none of `prompt`, `inputs`, `produces`, `optional`, `outcomes`,
  `budget`, `model`, `effort`, `env`, `may_invoke` or `secrets`. A human state has
  none of those but `produces`, and no `invoke` either; `on_enter`, `opens` and `produces` are the keys it
  may carry, and what it produces is documents — never `changeset`, a group of files or a
  presentation, and never `optional`, which is a job state's.
- `chat`, where present, is `true` or `false`. A chat step is a job state with a `prompt` and has
  no `budget` (it has no ceiling), no `may_invoke`, no `changeset` or `commit-message` in
  `produces` (a chat commits to its own branch), no group of files or presentation in `produces` (a page may be),
  and no `optional` naming its outcome document. Each is refused by name, with the reason. Command
  and human states cannot be chat steps. Every other rule of a job state holds.
- `model`, where present, is a non-empty string. Its value is not checked against anything.
- `effort`, where present, is a non-empty string, and likewise unchecked (§ Model).
- State and artifact names are single path segments: letters, digits, `.`, `_`, `-`.
- Every `inputs` entry is `ticket`, a command's log, or produced by a state that can run before the
consumer; every `produces` entry other than `changeset` is produced by exactly one state. `ticket`
is never produced; `answers.md` is platform-managed and never declared. **`attachments` and
  every name beginning `attachments/` is reserved** for the files people attach (`attachments.md`):
  no state or command may produce it, consume it as an input, or name it as a group, so an attached
  file can never collide with an artifact a job writes. The release's changelog section says so,
  because a hosted project's workflow could be using the name.
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
- **`commit-message` is declared as a plain document, and nothing else.** `commit-message/*` and
  `commit-message!` are refused where they are declared, saying so. A group records one artifact
  per file — `commit-message/<file>` — and never one called `commit-message`, so a workflow
  declaring the group form would validate and then stick every ticket that reached its merge, for
  want of a message no state could produce; a presentation would work and is refused for the
  premise, since this one is a plain git message nobody views as prose. The rule that a merging
  workflow has a producer reads the *artifact* name, so such a workflow is told what to write
  instead rather than also told its merge has no message.
- **Nothing approves `commit-message`.** A transition's `approve` may not name it: the operator
  reads it above the control that merges and confirms that (`ui.md` § Changes), and no surface
  offers to approve or edit it.
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
- Every `on_enter` entry is a known action (`merge` and `update`); `on_enter` is absent from every
  job state and every command state; no state both merges and updates (§ Bringing the branch up to
  date has the update step's own rules); at most one state in a workflow merges; `initial` does not merge; and a workflow that
  merges has a state producing `changeset` and a state producing `commit-message`, the second
  never `optional`. This binds admission and re-pinning; a stored pin is not asked again
  (§ Pinning) and its merge is the exception in § Merging.
- `on_conflict`, where present, is on a state that merges or one that updates, and names another state of the
  workflow that is a job state or a human state with a transition out — never a command state,
  and never the merging state itself; a job state it names is the `to` of no transition
  (§ Merging). Every walk of the graph — whether each state is reachable, whether an input or an
  approval comes before its reader, the order the project page draws its states in — follows it as an
  edge out of the merging state, because the ticket can reach the target only by it. It is no
  transition: no `when` selects it and no person chooses it.
- **An update step** (`on_enter: update`) has no `produces`, exactly one transition out, with no
  `when` and no `approve`, that does not lead into an update step; it is not `initial` and not also
  a merging state; and no `on_conflict` of any state names an update step. A human state may have
  an edge back into one. Each is refused with a message of its own.
- `queue` is `true` or `false`, and `true` only on an edge whose `to` has `on_enter: merge`:
  `only an edge into a merging state (one with on_enter: merge) can queue; "x" merges nothing`.
  Nor on an edge out of a chat step: `an edge out of a chat step cannot queue: "x" is ended by
  Accept, which merges at once` — Accept ends the step's conversation, so a ticket taken out of
  the line would rest in a step with nothing left to Accept. A pin made before the key existed
  reads as `false` (§ Pinning).
- `merge_conflict` is neither a declared outcome nor a value of an `exit` map.
- `description`, where present, is a non-empty string.
- `release`, where present, is `true` or `false`. It is refused in `.forge/workflow.yml`, which has
  no types, and in a library, which is not a workflow, each saying why. Two type files setting it is
  not a validation error — it is the project having no release — and is said by the project page.
  The single-file refusal is validation and not parsing, so a stored pin carrying the key is built
  as it was admitted.
- `release_files`, where present, is a list of non-empty strings, and `release_notes` a non-empty
  string. Both are refused without `release: true`, and in a library, saying to set them in the
  type that imports it. Each `release_files` entry must be a `name/*` that some state's `produces`
  or some command's `produces` declares, and `release_notes` a plain document in the `produces` of
  a state with a prompt and without `chat: true` (not a group, a presentation, the changeset, or a
  chat step's). Every error names the key, and for a file its place in the list:
  `release_files[1]`.
- `schedules`, where present, is a list of mappings with exactly the keys `name`, `cron`, `title`
  and `body`, each a non-blank string (§ Schedules). A name follows a state's name rule and appears
  once in the file and is at most 100 characters; a `cron` is five fields of the dialect, names a date
  that exists and is at most 200 characters. Refused in
  a file with `release: true`, saying a schedule never admits a release, and in a library. Each
  error names the entry and the key: `schedules[1].cron`.
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
experiment states, further `on_enter` actions beyond `merge` and `update`, and guarded transitions on document fields. None of
these change the meaning of anything above.
