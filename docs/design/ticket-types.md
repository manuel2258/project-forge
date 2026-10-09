# Ticket types

A project has more than one shape of work. A feature is refined, planned, implemented, verified
and merged; a bug is reproduced first and needs no plan; a spike investigates and reports and
merges nothing. Today a project has one workflow, `.forge/workflow.yml`, so every ticket runs the
feature's lifecycle or the project writes a lifecycle so general that it fits nothing well.

This note is the standard for **ticket types**: several workflows per project, one chosen when a
ticket is admitted. Code follows it; a change of mind updates it first.

**It is built** — all but a listing of libraries, which § Imports says is not: the grammar half — `description`, `import` and `extends`, resolved by
`ForgeCore.Workflow.Imports` through `Parser.load/2` — and the directory of types
(`Forge.TicketTypes`), admission, re-pinning and drift by type, proposals suggesting a type, what a
job is told, the project page, the board's lanes and the ticket page. What it leaves out on purpose
is § Deliberately not here. What is unobserved is a real project with types: everything here is
tested against repositories a test made.

## A type is a workflow

**A ticket type is the workflow a ticket runs, and nothing else.** Two types with the same
workflow are one type with two names, and a classification that does not change what runs — a
label, a priority, a component — is not a type and is not in this note. That keeps the concept
checkable: a type exists if and only if a workflow file declares it.

The product calls it a *ticket type*. Code calls it `ticket_type`, never a bare `type` or `kind`:
`jobs.kind` (`workflow | command | chat`), the queue's item kinds and the vision's
`fanout: { type: … }` already own those words.

## Where they live

```
.forge/
  workflows/
    feature.yml        # one type per file; the type's name is the file's stem
    bug.yml
    spike.yml
  common.yml           # a library: imported, never a type (§ Imports)
  agents/
    implement.md       # prompts are shared by path, as they are today
  commands/
    build.sh
```

**Each file under `.forge/workflows/` is a complete v1 workflow** (`workflow-grammar-v1.md`),
validated on its own. The grammar, the validator, the reachability rule for inputs and the
pinning are unchanged, because each file is exactly what `.forge/workflow.yml` is now. This is
GitHub Actions' layout, which the vision already borrows from: one file per workflow, in one
directory, reviewed like any other change. Its `limits.ticket_cost` and `defaults` therefore are
per type for free — a spike capped at a dollar and a feature at twenty-five is two files saying
so.

**The single file stays valid and means one type.** A project with only `.forge/workflow.yml`
has one unnamed type, and nothing in the product mentions types: no select on the form, no lanes
on the board. Most projects start there and many will stay, and a directory holding one file is
ceremony. **Both at once — the single file and a type in the directory — is an error**, at
admission and on the project page, naming both paths: there is no rule for which wins, and
inventing one is how a ticket runs a workflow nobody chose.

**A type's name is its file's stem**, and follows the rule for state and artifact names
(`ForgeCore.Workflow.valid_name?/1`): letters, digits, `.`, `_` and `-`, starting with a letter or
a digit, and ending where the string does — a name cannot end in a newline. Only `<name>.yml`
directly in `.forge/workflows/` is a type. Anything else there — `bug.yaml`, `Bug Fix.yml`, a
README, a subdirectory, a symbolic link — is listed on the project page as *not a type*, with why,
and blocks nothing: one stray file must not stop every other type admitting, and a stray beside
the single file does not make a project with both. **The directory is in use when it holds a
type.** When it holds files and none is a type, and there is no single file, nothing can be
admitted, and the refusal — on the form, the project page and the API alike — names each file and
why it is not a type, rather than saying only that there is no `.forge/workflow.yml`.

**A file may carry `description:`**, one line — with `import` (§ Imports), one of the two
top-level keys the grammar gains. The ticket form shows the chosen type's, and an agent proposing a
ticket reads every type's (§ What a job is told). It is optional, and a type without one is
offered by name alone.

## Imports

Three files repeating the same `build` and `test` commands, and the same `implementing` state,
is three places to change a timeout. A type may import a **library**: a file under `.forge/`,
outside `workflows/`, holding shared declarations.

```yaml
# .forge/common.yml — a library
commands:
  build: { run: .forge/commands/build.sh, env: build, produces: build.log, timeout: 20m }
  test:  { run: .forge/commands/test.sh,  env: build, produces: test.log,  timeout: 30m }

defaults:
  resources: { memory: 2200MiB, cpu: 1 }

states:
  implementing:
    prompt: agents/implement.md
    env: implement
    may_invoke: { build: { max: 40 }, test: { max: 20 } }
    produces: [implementation.md, changeset]
    budget: { turns: 200, cost: 10.00 }
```

```yaml
# .forge/workflows/bug.yml
version: 1
description: Something that worked and does not; reproduced before it is fixed.
import: [common.yml]
initial: reproducing

states:
  reproducing:
    prompt: agents/reproduce.md
    env: implement
    may_invoke: { test: { max: 10 } }
    inputs: [ticket]
    produces: [reproduction.md]
    budget: { turns: 40, cost: 2.00 }

  implementing:
    extends: implementing             # the library's, then the keys below replace its own
    inputs: [ticket, reproduction.md]

  checking:
    invoke: [build, [test, --all]]
    exit: { 0: done, "*": checks_failed }

  review_ready: {}
  merged: { on_enter: merge }

transitions:
  - { from: reproducing,  to: implementing }
  - { from: implementing, to: checking }
  - { from: checking,     to: review_ready }
  - { from: checking,     to: implementing, when: checks_failed, max: 3 }
  - { from: review_ready, to: merged,       approve: [changeset] }

limits:
  ticket_cost: 8.00
```

**`import` lists library paths**, relative to `.forge/` like a prompt, read at the same commit as
the type that names them. Each section has its own rule, and each rule is the one that
section's existing semantics already imply:

- **`commands` are imported whole.** Every command a library declares is declared in the type.
  The validator has no rule against a command nothing invokes, so a type that uses two of a
  library's five pays nothing for the other three. **A command name declared twice is an error**,
  in two libraries or in a library and the type: the error is reported against the second library
  and names the first, or says the importing workflow declares it too. Overriding one is not offered:
  `build` should mean one thing in a project, and a type that needs another build names it
  `build_release`.
- **`defaults` are imported field by field, and the type's own win**, which is the nearest-first
  order `resources` already resolve in (`workflow-grammar-v1.md` § Resources). Two libraries
  setting the same field is an error, because neither is nearer.
- **`states` are never imported implicitly.** A library's states are templates, and a type takes
  one by naming it: `extends: <library state>`. Every state must be reachable from `initial`, and
  transitions are the type's own, so a state the type did not name would be an unreachable one —
  the validator's error, arriving from a file the author did not open. **The keys the type writes
  replace the library's whole**, never merged into them: a `budget` in the type is the budget, not
  a patch to one. A deep merge saves a line and costs the reader the ability to see what a key
  holds by looking at one place.
- **Nothing else may be in a library**: no `version`, `initial`, `transitions`, `limits` or
  `import`. Transitions are what makes a type a type; and **imports are one level deep**, so there
  are no cycles to detect and no diamond to order.

**A library is validated only through the types that import it.** It is not a workflow — a state
template in one need not have `inputs` — so there is nothing to check it against alone, and a
state template no type extends is never checked at all. That is the price of templates, and it
is paid: nothing lists a library or what imports it, so an orphaned template is found by reading
the library. A listing on the project page would be the remedy if it turns out to matter; it is
not built.

**Resolution happens before parsing, and what is pinned is the result.** A pure function in
`forge_core` takes the type's decoded map and a reader — a function from a path to its text at
the commit, the same shape as the `prompt_exists` and `file_exists` callbacks `Parser` already
takes — and returns a plain v1 map with no `import` and no `extends` in it. That map is what is
validated and what admission stores in `tickets.workflow`. This is not a convenience; it is
required. `Tickets.parsed_workflow/1` re-parses the stored map with `Parser.from_map/1` and no
repository, on every read of a ticket's workflow — the board, the queue, the engine — so a stored
map that still said `import` could not be read anywhere. It also keeps pinning honest: a ticket
holds exactly the definition it runs, a later edit to a library reaches it only through a re-pin,
and `workflow_commit` with the ticket's type reproduces it.

**An error names the file it came from.** `ForgeCore.Error` locates by a dotted path into one map,
and after flattening every path looks as though it is in the type file. The resolver records
where each command, default field and state key came from, and an error under one is reported as
`common.yml: states.implementing.budget.turns: …`. Without it, a typo in a library is reported
against a file that does not contain it, three times, once per type.

## Pinning and re-pinning

**A ticket records its type**: `tickets.ticket_type`, a string, nil for a ticket admitted from the
single file. Beside `workflow_commit` it names the file a re-pin reads. `ticket.admitted` carries
it.

**A re-pin reads the same type at the default branch's head** (`Forge.Engine.repin/2`), with
every guard it has now, and one more: a type whose file is gone refuses the re-pin, naming the
file. A project that moves from the single file to `workflows/` leaves its open tickets with nil
and nothing to re-pin from, and the refusal says so rather than guessing which new type they are.

**Drift stops counting other types.** `Tickets.drift/2` reports any change under `.forge/` since
the pin. A change to `spike.yml` is not drift for a bug, so the diff leaves out
`.forge/workflows/` files other than the ticket's own. Libraries, prompts and scripts still count
whoever uses them: knowing which ones this type imports means reading the file at the pin, and a
false "something changed" costs a glance where a missed one costs a ticket failing on a fixed
script.

## Admission

**A type is required when the project has more than one, implied when its directory holds one,
and refused on the single file**, which has none to name. There is no default type. A default is
how a bug quietly runs the feature lifecycle — the more expensive one — and nobody notices until
the plan arrives for approval. The API takes `ticket_type` beside
`title` and `body`, as do `Operator.admit/3` and `mix forge.admit`, and
`Tickets.prepare_admission/2` reads that type's file.

**The form offers every type, and nothing is preselected.** Every type is parsed *before* the
operator types, as the form already resolved the one workflow (`ui.md` § Creating things), and
the chosen type's description and the state it starts in are said beneath the select. A type
whose file does not parse — its own or a library's error — is offered marked *does not parse*,
and choosing it says why and leaves the form unable to submit; the others admit. A broken library
therefore marks every type that imports it, which is correct: none of them would admit.

## Proposals

**A proposal may name a type, and a person confirms it.** The agent knows more about what it
found than a person reading two paragraphs does, and a proposal accepted with the right type
preselected is one tap rather than two. So a proposal's only front matter is an optional
`type:`:

```markdown
---
type: bug
---
# Saving twice loses the first slot

…
```

This changed `ticket-proposals.md` § Shape, which said a proposal has no front matter. The reason
given there still holds and is kept: a proposal is written with `parse: false`, so nothing about
it can take down the result it rides in. `ForgeCore.Proposal.parse/1` reads the one key itself and
strips it, and the ticket document admitted from it is still `# title\n\nbody`. Any other key, or
front matter that does not close, is a malformed proposal, kept verbatim and never acceptable
(`ticket-proposals.md` § Malformed degrades, never drops).

**At accept, the suggestion is preselected only if it is a type now.** Types are read at the
default branch's head when a person decides, months perhaps after the agent wrote it — the same
reason the workflow pins at accept and not at propose. A suggestion that names no current type
preselects nothing and says which type was suggested. On a project with one type the suggestion
is ignored. `POST …/proposals/:version_id/accept` takes `ticket_type` under the admission rule,
and **only a type left unsaid falls back to the suggestion**: an API call with no `ticket_type`
takes it, while the page's select, which sends the type it shows, sends an empty string only when
a person has chosen none — and that is admitted as none, which a project with several types
refuses.

## What a job is told

An agent cannot suggest a type it has not been shown. **The backlog's index gains a section
listing the types**: each type's name, the state it starts in and its description, read at the
default branch's head when the backlog is composed, and a type that does not parse marked as such.
It is in the index, and so in the backlog's hash, like everything else handed over unpinned
(`ticket-proposals.md` § Reading the backlog). A section rather than a `types.md` of its own:
the index is what every agent reads first, and a new file would have needed the worker to learn
to write it. The ticket table gains a type column, and each ticket file's header its type,
because without it a bug in `implementing` and a feature in `implementing` read the same. A
project with the single file gets none of this, and its index is unchanged.

That puts git reads into `Forge.Backlog.compose/2`, which before read only the database, on every
assignment — `Tickets.types/2` parses each type. If that shows, it is memoised by the head's sha;
it is not worth doing before it shows.

The job's own manifest names its ticket's type beside its number and title. It is information,
not a switch: a prompt shared by two types that behaves differently by type is a branch hidden
from the workflow file, and the right form of that is two states.

## The board

**One lane per type, each with its own columns** (`ForgeWeb.Operator.Board.lanes/2`). The columns
are the workflow's topology (`ui.md`), and they came from one ticket's pinned workflow — the
lowest-numbered visible ticket's (`Board.workflow/1`) — which with types draws a bug's states in a
feature's columns. Within a project each type is a lane headed by its name, and the lane's columns
come from the lowest-numbered ticket of that type, by the same rule. A column is addressed by
project, type and state, not project and state, so `implementing` in two types is two columns; a
column of the single file's lane keeps the address it always had. Both boards draw lanes with one
component, `Board.board/1`.

A type's lane is always headed by its name: with several types and tickets of only one of them on
the board, the columns would otherwise not say whose they are. A type with no tickets has no lane,
since empty columns are its workflow and the project page shows those. A project with the single
file draws no heading and is unchanged. Tickets left with a nil type in a project that has since
moved to `workflows/` are a lane of their own, headed `workflow.yml`. Below `sm` the board already
stacks a state per section; the type heading goes above its states.

## The project page

The "workflow the next ticket will pin" table (`ui.md` § The project page) becomes one per type,
under the type's name and description, with a broken type shown as its error. The ticket page
names its type beside its state.

## What this changed elsewhere

Each of these was updated with the part it describes:

- `decisions.md` § Lifecycle: a project defines its lifecycles in one or more definition files,
  one per ticket type, and the type is pinned with the workflow at admission.
- `workflow-grammar-v1.md`: § Location gains the directory form; `description`, `import` and
  `extends` join the grammar, with the library rules. It is compiled into the release, and a
  conversation bootstrapping a project is handed it.
- `ticket-proposals.md`: § Shape (the one key of front matter), § Reading the backlog (the
  types section, the type column).
- `job-prompt.md` and the preamble: "do not edit `.forge/workflow.yml`, `.forge/agents/` or
  `.forge/commands/`" becomes "do not edit anything under `.forge/`". Libraries and type files can
  sit anywhere there, and pinning, not the list, is what enforces it (`commands.md`).
- `ui.md`: § Creating things (the type select), § The project page, the board, § The phone.
- `api-and-ui.md`: `ticket_type` on admission and on accepting a proposal.
- `core/priv/chat-preamble.md`: a conversation bootstrapping a project writes the single file
  unless asked for types.

## Deliberately not here

- **Changing a ticket's type.** A re-pin to another type would reuse every guard `repin/2` has,
  and the one that matters is that the ticket's current state exists in the new workflow — which
  a bug sitting in `reproducing` will never meet in a feature workflow. Cancelling and admitting
  again covers it, and the cancelled ticket keeps its record. If retyping is wanted, it is a re-pin
  with a type argument, not a new mechanism.
- **A default type**, for the reason in § Admission.
- **Labels, priorities, components.** Not types (§ A type is a workflow).
- **Types made or edited in the product.** A type is a file in the repository, for the reason a
  workflow is (`ui.md` § Creating things).
- **Nested imports, imported transitions, a deep merge, overriding an imported command.** Each is
  a rule a reader has to run in their head to know what a type does.
- **Per-type permissions or credential pools.** Nothing has shown that a type is the boundary
  either should follow.

## Open

- Whether `/board`, every project at once, stays readable with lanes. It is decided by looking at
  a real one, not here.
- Whether drift should read the type's imports at the pin to stop counting libraries it does not
  use. It costs one git read per ticket page and is worth it only if false drift turns out to be
  common.
