# Commands

Scope: milestone 4. A *command* is a fixed script, declared in the workflow, that runs as its own
job on its own machine against a named commit. Two things invoke one: an agent, mid-job, when its
state allows it; and a state that is nothing but commands. `docs/design/workflow-grammar-v1.md`
carries the grammar; this note carries the mechanism and the reasoning.

**Commands are not built.** The grammar note marks `commands`, `invoke`, `may_invoke` and `exit`
as unimplemented, the parser rejects all four as unknown keys, and no `kind: :command` job exists
— `jobs.kind` is `:workflow | :chat`. What is settled is the shape.

**What this note argued for on the way is built**, because `docs/design/provisioning.md` took it:
`resources` on a state and under the workflow's `defaults`, with `cpu` as a gate dimension
(§ Resources); the cores and `accepts` a worker reports at `ready` (§ Worker pools); affinity on
resume (§ Always park); and the worker templates, `shapes/1` and driver registry that gave
`opts.size` a consumer. `resources` on a *command* is the one piece of that which waits for
commands.

**This is a resource-optimisation feature, not a sandbox.** An agent has a shell inside its slice
and can already run anything the environment provides. Nothing here takes that away, and a note
claiming it did would be false. What commands buy is four things, in descending order of worth:

1. **The agent and the workflow run the same script.** `verifying` invokes `build`; the agent
   invokes `build`. There is one definition, so the two cannot drift.
2. **The work leaves the agent's slice** — its own ceiling, its own machine, its own pool. The
   agent's slice is *released* while it runs (§ Always park), which is the optimisation this
   feature is for.
3. **Every invocation is a recorded job** with a log artifact, an exit status and a commit, so
   "it built twelve times and the tests failed twice" is on the timeline rather than buried in a
   transcript.
4. **Consumption control**: how many, how concurrent, how large.

## The shape

```yaml
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
  implementing:
    prompt: agents/implement.md
    env: implement
    may_invoke:
      build: { max: 40 }
      test: { max: 20, concurrent: 4 }
    ...

  verifying:
    invoke: [build, test]
    exit: { 0: done, "*": tests_failed }
```

`commands` is a top-level map because a command belongs to the project, not to one state: the
whole point is that `implementing` and `verifying` reach the same script.

**Arguments are freeform and are the agent's.** A command declares no parameter schema. The agent
supplies a list of strings, and the worker `exec`s the script with them as an argument vector —
never a string handed to a shell. That rule survives the absence of a sandbox on correctness
grounds alone: `--filter "foo bar"` must not word-split, and `sh -c` with interpolation is how it
would. A state's own `invoke` may name arguments the same way.

**What the agent may not vary is the script.** It is read at the ticket's pinned base commit, like
`.forge/workflow.yml` itself, not from the branch the agent is editing. Without that, "fixed
script" means nothing: an agent that can rewrite `build.sh` can make `build` mean anything, and
the `verifying` state would be running whatever the implementing agent left behind. The preamble
already forbids editing `.forge/workflow.yml` and `.forge/agents/`; `.forge/commands/` joins that
set, and the pinning enforces what the preamble asks.

The consequence is the familiar one from every CI system and should be stated rather than
discovered: **a ticket that changes a command script sees the change only after it merges.** That
is correct — a build script under review must not be the build script judging it — but the first
person to hit it will think it is a bug.

**The drift property is about the script, not the arguments.** With freeform argv, `verifying`
running `build` and an agent running `build --profile release` are no longer the same invocation.
The script cannot drift; the arguments can. That is a much weaker claim than "the agent and CI do
the same thing", and it is the true one. What keeps it useful is that the exact argument vector is
recorded on the invocation (§ Events), so what ran is answerable even though it is not derivable
from the workflow file.

## An invocation is a job

A command invocation is a row in `jobs` with `kind: :command` and `parent_job_id` set to the
invoking job, or null when a state invoked it directly. `spec.kind` already carries
`:workflow | :chat` and `parent_job_id` already exists for subagents
(`docs/design/data-model.md` § Not in v1, but shaped for), so this is a third kind rather than a
new object.

Everything follows from that and nothing has to be built twice: scheduling, the memory gate, the
slice, the worker channel's `assign`, cancellation, events, the timeline, and the orphan rule for
a ticket that moved on. A state's `invoke` list is the same object with no parent, which is why
this note has no separate account of "a command-only state" — there is no such thing, only a state
whose job is a command.

The cost is row count: forty builds on a ticket is forty rows. That is the right trade — they are
each a real execution with a real result — and the surfaces group them under the job that invoked
them.

A command job carries no harness, no credential, no model and no budget in turns or dollars. Its
spec is the script, the argv, the env, the commit, the resources and the timeout. Its outcome is
its exit status, mapped by the invoking state's `exit` map when a state invoked it, and returned
raw to the agent when an agent did.

## Always park

**A job waiting on a command is hibernated, never held open.** There is no inline mode.

The reason is the whole feature: a parked job holds no process, so its slice is freed. The agent's
memory and CPU share return to the worker for the length of the command, and the worker can take
other work or be destroyed. A spot eviction or an idle destroy while a twenty-minute test suite
runs costs nothing, because on the agent's side there is nothing running to lose.

The machinery exists. `docs/design/job-prompt.md` § Blocking questions and `waiting` parks a job,
refreshes its inputs and resumes the same job and attempt. This note relied on a continuation
prompt there, and one is built for answers (`job-prompt.md` § The continuation prompt): a run
that resumes its session is handed the answers, the branch and the manifest rather than the whole
prompt. It names answers and nothing else, so a resume after a command needs a section naming the
command's result beside them — the manifest would list the result as an input, but a session
that is not told an input is new has no reason to read it. `worker-tier.md` has
commit-and-hibernate with resume from branch and manifest; the channel already has `hibernated`
(`docs/design/worker-channel.md` § Messages). A command result is structurally what an answered
question is: an input appears, the job resumes. Only the party satisfying the wait differs — a
machine in seconds rather than a person in hours.

Waiting on many is the same park. The agent invokes *n* commands, the job parks once, and it
resumes when all *n* have landed. That is fan-out inside a job without the workflow-level fan-out
v1 rejects, and it is why the preamble tells the agent to invoke in batches rather than one at a
time.

**What always-park costs is tokens, not seconds.** Every resume is a harness resume, and
`docs/design/claude-code-events.md` § Resume says the session is reused where available and a
freshly composed prompt used otherwise. The fallback re-sends context, and context is the
expensive resource in this system — `docs/measurements.md` § M1 puts a warm build at 984 ms, so
the wall clock of a park is not what to watch. Two things follow: the preamble asks for batched
invocations, and `may_invoke`'s `max` is a cap on park cycles as much as on compute, so it should
be set with that in mind rather than as a generous safety number.

**Whether the harness session survives a park is not a measurement. It is a consequence, and the
answer was usually no.** This paragraph used to say measuring it was the first thing to do; two
facts settled it without a run. A parked job holds no slice — which is the whole point of the
feature — so a worker whose only job is parked has nothing running, goes `idle`, and is destroyed
on its period while the command is still going. And `Workers.assignable/1` was first-fit by
`inserted_at`, so even a machine that survived was not preferred for the resume. The second is
no longer true (below); the first still is. Claude Code's session lookup is per project directory
(`docs/design/claude-code-events.md` § Resume), so a different worker cannot find it.

Nothing about correctness turns on this — that note is explicit that *"resume is never required
for correctness, and no outcome depends on it"*, and `worker-tier.md` § Hibernation and resume
reconstructs from the branch and the manifest rather than the conversation. What it costs is a
re-composed prompt, and context is this system's expensive resource. So `max` should be set as a
cap on park cycles assuming the fallback, not the session.

**The lever that changes it is affinity, not measurement, and it is built.**
`Workers.assignable/2` prefers the worker the job last ran on and falls through to any other that
fits when that one is gone (`docs/design/provisioning.md` § Affinity on resume). What makes it
hit is the first fact's answer: a per-template idle period long enough on the agent side.

## The ensured commit

**Before an invocation is dispatched, the invoking job's worktree is committed on the ticket's
branch, and the invocation records that commit.** A command never runs against "whatever was on
disk"; it runs against a sha that is on the branch and in the record.

- **Nothing to commit means no commit.** The invocation records the current head. An empty commit
  to force a rebuild is not a thing this platform does — a command re-run is a new invocation of
  the same sha, which is more honest and shows up correctly on the timeline.
- **Commit noise is already paid for.** The contract in `job-prompt.md` has the agent making
  ordinary commits and says history is squashed later, so forty auto-commits cost nothing at
  merge.
- **Untracked-but-not-ignored files are staged; ignored files never are.** The commit has to pick
  up source files the agent created, which is what makes a blind sweep tempting and wrong — this
  is the trap that puts a build directory into the branch. It does not bite here, because the
  build directory is its own subvolume outside the worktree (`worker-tier.md` § Volumes and the
  seed), but the rule is stated because the next person to touch it will not know that.

This replaces an earlier idea — running the command on a btrfs snapshot of the live worktree — and
is better than it. A snapshot gives the command a frozen tree but nothing to call it; a commit
gives a name that the log, the event and the ticket can all refer to, and makes the result
reproducible by anyone later. The snapshot mechanism is still what the *command worker* uses, one
level down, to get a build directory (§ How a command gets the code).

## How a command gets the code

The command worker fetches the ticket's branch from the platform's git host at the recorded
commit, into a checkout on a snapshot of its warm seed, and runs the script in `nix develop
.#<env>` inside its slice.

**No per-job git token, and no write credential.** The `assign` message for a workflow job carries
a git endpoint with a per-job token scoped to the ticket branch; a command job carries neither.
What authorises the fetch is the **worker token the machine already holds** for the channel,
accepted by the platform's git host as a read credential. That is not a new secret and not one the
script ever sees. Saying "a command needs no credential" would be false — bytes do not arrive
unauthenticated — but the true statement is nearly as good: a command pool holds no Claude
credential, no write credential and nothing per job.

**A command worker is warm or it is not worth having.** The fetch is a delta against a checkout it
already has, on a snapshot of a seed it already holds. `docs/measurements.md` § M1 variant (c) is
exactly this case and is what makes the pool affordable: a warm build directory transplanted from
a different checkout path rebuilt only the project's own crate, at 1.34× a warm local build. A
command worker created per invocation would instead pay M4's cold start — seed fetch and Nix store
population, both of which M4 warns get worse on a real provider — for a build that M1 says takes a
second when warm.

## Resources

**The platform had one number for every job**: `config.exs` set `slice_bytes` to M3's peak plus
its margin, and `Forge.Jobs.Scheduler` read `Workers.slice_bytes/0` for a refine job and a
release build alike. `worker-tier.md` § Open named this and said per-state slices belong in the
grammar. Commands were the reason it could no longer wait: a command declaring the same 2.2 GiB
as a prose-refining agent is the gate doing nothing. **It has not been one number since**: a job
row carries the `memory_max` and `cores` it was admitted with, resolved once at creation, and the
scheduler places it by those. `slice_bytes` is what a workflow job declaring nothing gets, and
what a row from before the columns is read as.

**This section is the grammar half. `docs/design/provisioning.md` is the platform half** — what
the scheduler does with a declaration, how a worker says what it will take, and where a machine
that can satisfy one comes from. What is written here did not change when that note was written,
which is the useful part: the declaration was designed without knowing how it would be matched,
and it survived contact.

A `resources` map, valid on a job state and under the workflow's `defaults` — both built — and on
a command, which waits for commands:

```yaml
defaults:
  resources: { memory: 2200MiB, cpu: 1 }
```

Resolved nearest-first: the command's, then the state's, then `defaults`, then the platform's
`slice_bytes` and one core. This note first called that *the same chain `model` uses*, and it is
not: a model resolves the state's, then the project's `model` column — a setting on the project,
not a key in its workflow file — and there is no per-project `resources`. A project's default is
its workflow's `defaults`.

| Key | Means | Enforced by |
|---|---|---|
| `memory` | The slice's hard ceiling, and what the scheduler's gate counts. | `MemoryMax`, with `MemorySwapMax=0` as now. |
| `cpu` | How many cores the scheduler *reserves* when placing the job. | The gate. Not a quota. |

**`cpu` is a reservation, not a cap, and that is the whole decision.** The obvious implementation
is `CPUQuota=400%`, and it is wrong here: `docs/decisions.md` chose proportional CPU shares
precisely so that an agent idle on inference donates its share to whoever is compiling, and
`worker-tier.md` § The job slice records equal `CPUWeight` for that reason. A quota would cap a
build at its declaration even on an otherwise idle machine, which trades the donation away to buy
predictability nothing has asked for. So `cpu` becomes a second dimension on the gate beside
memory — does this fit alongside what is running — and the slice still gets `CPUWeight`. A command
that finds the machine to itself uses all of it.

**The gate needed a number nothing reported.** `ready` carried `memory_budget` and the harness
offer and no core count, because until then nothing asked for one — every job was weighted
equally and `CPUWeight` needs no arithmetic. Without one a declared `cpu` is a number the
scheduler cannot check against anything, which is the decorative guard this repository keeps
writing. **`ready` carries `cores` now, and `accepts` beside it** (`docs/design/worker-channel.md`
§ What a worker offers). It was to be derived the way the memory budget is — what the machine
has, less what the system holds back — and is not: it is the logical processors online, or
`FORGE_CORES`, with no reserve (`docs/design/provisioning.md` § Open). A worker that omits it is
not gated on cores rather than read as having none.

**There is no `disk` key.** Build directories are the obvious third dimension and btrfs has the
quota groups to enforce one, but nothing has measured disk as the binding constraint — M2 found
159 MiB of exclusive bytes across four concurrent builds — and a key the platform accepts without
enforcing is worse than an absent one. § Open says where it would go.

**A declaration no worker can satisfy is a runtime failure, not a validation error.**
`forge_core` has no database and no network, so the validator cannot know what machines exist and
cannot reject `memory: 512GiB`. The scheduler must therefore distinguish *does not fit right now*
from *could never fit*, and stick the ticket with the reason in the second case — which it does,
as `{:no_template, :none_fit}` (`docs/design/provisioning.md` § The gate). This is the same
distinction `worker-tier.md` makes between a failed create and a machine somebody else owns, and
it fails the same way if it is not made: a job queued for ever against capacity that will never
exist.

**What this gives the provider driver.** `Forge.Provider`'s `opts.size` was an opaque optional
string that nothing derived. With declared resources the platform can size a machine from the
demand that is queued rather than being told a magic name, which is why `resources` is expressed
in bytes and cores rather than in t-shirt sizes. `docs/design/provisioning.md` § Where a machine
comes from collected on it, and all of it is built: a worker template carrying that opaque
string, a `shapes/1` callback so the operator picks from machines the driver actually offers, and
a registry in place of one global `impl/0`. The size is still a person's choice from that list:
the platform picks the smallest template assigned to the job's project that holds the demand
(`provisioning.md` § Whose account), not a size computed from it.

## Limits

`may_invoke` lists what a state's agent may call, and is the twin of `spec.permitted_children` —
a per-job allowlist, resolved at job creation from the pinned workflow and carried on the spec.

| Key | Means |
|---|---|
| `max` | How many invocations of this command this job may make. |
| `concurrent` | How many may be in flight at once. |

**A breach is a refusal the agent reads, not a job that dies.** An invocation past `max` returns
an error result — "no invocations of `build` remain" — and the agent decides what to do about it.
A killed job would throw away everything it had done for a limit it could have worked around, and
the budget model already behaves this way: budgets are enforced by the platform and the agent is
told, rather than being trusted or being shot.

**`concurrent` is the first thing that can starve an agent job.** Four concurrent commands are
four slices the gate has to find, and the scheduler currently has one queue and no notion of
priority. Until it does, the honest position is that a workflow which sets `concurrent` high on a
busy fleet will delay agent work, and the ordering policy is § Open.

## Events and the timeline

Each invocation writes events on the invoking job's timeline as well as its own:
`command.invoked` (name, argv, commit), `command.started` (worker), `command.finished` (exit,
duration), with the log arriving as an artifact version named by `produces`.

The argv is on the event because with freeform arguments it is no longer derivable from the
workflow file. That is the cost of dropping the parameter schema, and it is cheap: one field, and
"what actually ran" stays answerable for ever.

## Worker pools

Commands make the fleet heterogeneous for the first time, along a line that matters:

| | Agent workers | Command workers |
|---|---|---|
| Holds the Claude credential | yes | **no** |
| Holds a git write credential | yes, per job | no |
| Dominant resource | memory, and inference latency | CPU |
| Utilisation | bursty; parks release the slice | saturating while running |
| Losing one mid-job | costs the run | costs nothing re-runnable |
| Project toolchain | only if the agent builds locally | always |

**There is no pool, and there is no class.** This section used to argue that the split needed no
concept at all: a command job needs no harness, so a worker holding no Claude credential is
*already* one that can only take commands. That is true and it is not enough, because it only
fences one direction. It says nothing about the case the split exists for — **keeping inference
off the expensive machine** — since a worker that *does* hold the credential will take anything
the memory gate admits, including a refine job landing on a box bought for builds.

What closes it is one column. `workers.accepts` lists the job kinds a machine will take, and the
gate reads `job.kind in worker.accepts` beside the resources. A build machine declares
`[:command]` and inference can never reach it; a small machine declares `[:workflow, :chat]`, or
all three if the operator wants it to absorb spillover. Two mid-sized commands share a node
because both are commands and both fit — no bucket had to be invented for them.

`docs/design/provisioning.md` § There are no classes is where this lives, along with the reason a
named class was drafted and dropped: the name carries nothing the job's `kind` and the worker's
`accepts` do not already carry, and a misspelt class name is a job that schedules nowhere and
errors never.

## What this gives up

- **An agent that cannot invoke is unaffected, and that is deliberate.** A state with no
  `may_invoke` runs exactly as it does today, shell and all. This feature is opt-in per state, so
  a workflow that never adopts it never pays for it.
- **Local iteration is still faster than a command.** A warm local build is 984 ms (M1); a command
  is a commit, a dispatch, a fetch and a park. An agent told to use `build` for a one-line syntax
  check is being made slower and more expensive. The preamble should say what commands are *for* —
  the expensive, the shared, the verdict-bearing — rather than presenting them as the way to run
  anything.
- **Two execution paths now exist for the same work**, and they can disagree if a project's local
  environment and its command script diverge. The single definition removes the script from that
  risk; it does not remove the environment from it.

## Open

- **Ordering between agent jobs and command jobs** when the gate is full. `concurrent` makes
  starvation possible and the scheduler has no priority. `docs/design/provisioning.md` § The gate
  removes the half that mattered — a per-template `max_workers` stops one kind of work eating the
  fleet — and leaves the other: an unplaceable job is skipped and the pass continues, so a large
  job can be jumped by small ones indefinitely. An age-based reservation is the fix and neither
  note builds it.
- **Whether affinity on resume pays.** It is built (§ Always park), and § Always park no longer
  asks whether the harness session survives a park, because the topology answers it. What is open
  is the size of the prize — how many tokens a re-composed prompt costs against a resumed
  session — and that one *is* a measurement, on the operator's real project rather than on a
  sample.
- **`disk` in `resources`.** Wanted the first time a build directory fills a worker; needs btrfs
  quota groups on the build subvolume and a free-space dimension on the gate.
- **`arch` in `resources`.** A project whose toolchain is x86-only cannot run commands on an Arm
  pool, while its agents could. Nothing needs it until a fleet is mixed, and the place it would go
  is here.
- **Re-running a command on the same commit** is currently a new invocation with the same sha and
  no caching. Whether a repeat should be answered from the previous result is a dogfooding
  question; answering it wrongly hides a flaky test.
