# Job prompt and the agent's interface

Scope: how a job's agent learns what to do, where inputs and outputs live, and how it asks
questions. The interface is files, not tools, so any harness with a filesystem can run a job.

## Three layers, one composed prompt

1. **Platform preamble.** Owned by forge, versioned in `core/`, identical for every job on
   every project. States the contract below. Its hash is part of the job spec.
2. **Project state prompt.** The file named by `prompt` in the workflow, e.g.
   `.forge/agents/refine.md`. Says what this kind of document is and how the project wants it
   written. Read at the pinned commit.
3. **Job manifest.** Rendered from the spec as assigned — the immutable one, with `answers.md`
   appended once there are answers and the cost budget perhaps lowered (`capacity.md` § Spend
   caps): ticket title and number, how the job came to be in this state (§ How the job
   arrived), each input with its path and version, each optional input not yet written, each
   `produces` entry with its target path, the allowed outcomes, the budgets.

## How the job arrived

A job whose state can be entered more than once has to be told which time this is and why. A
second `implementing` job is there because something sent it back, and until this section it
learnt that only by noticing its inputs had changed.

The spec carries `entered`: the state the ticket came from, the outcome that selected the
transition, whether the engine or a person took it, and the person's comment when they gave one —
the note a tester leaves when sending a build back is exactly what the next job needs. The first
job of a ticket has none, and the manifest says it is the ticket's first state. Like the rest of
the spec it is written once, when the job is created, from the transition that created it.

**An optional input not yet written is named, not silently absent** (`workflow-grammar-v1.md`
§ Inputs). `implementing` on its first entry is told that `review.md` does not exist yet; on its
second, it is an input with a version like any other. An agent that could not tell those apart
would have to guess whether a missing file was a failure.

The repository's own `CLAUDE.md` is read by Claude Code as usual; project conventions need no
special handling.

## Job directory

Outside the worktree, so nothing in it can be committed by accident:

```
$FORGE_JOB/spec.json                     # the spec this run was assigned, for reference
$FORGE_JOB/prompt.md                     # the composed prompt, as the harness was given it
$FORGE_JOB/inputs/ticket                 # reserved input: the ticket body, no extension
$FORGE_JOB/inputs/refinement.md          # pinned version, read-only
$FORGE_JOB/inputs/answers.md             # present after any question was answered
$FORGE_JOB/out/plan.md                   # written by the agent
$FORGE_JOB/out/proposals/<name>.md       # ticket proposals, optional (ticket-proposals.md)
$FORGE_JOB/out/<group>/<file>            # a declared group's files, any number, any bytes
$FORGE_JOB/invoke.json                   # commands to run, written by an agent that may invoke
$FORGE_JOB/commands/<n>-<command>.log    # a resumed run's command logs, read-only
$FORGE_JOB/tickets/index.md              # the project's tickets and open proposals, read-only
$FORGE_JOB/tickets/<number>.md           # one ticket's body
$FORGE_JOB/conversation.md               # a reopened conversation's past, read-only
$FORGE_JOB/platform/platform.md          # how the platform works, read-only
$FORGE_JOB/platform/workflow-grammar.md  # workflow-grammar-v1.md as compiled in, read-only
$FORGE_JOB/home                          # HOME for the harness process
$FORGE_JOB/transcript-<n>.jsonl          # the harness's raw stdout, one file per run
$FORGE_JOB/stderr.log                    # the harness's stderr
```

`ForgeWorker.Job.Dir` owns the layout. `tickets/` is `ticket-proposals.md` § Reading the backlog;
a conversation's directory also holds `history/` (`conversations.md` § Context) and, once it has
been reopened, `conversation.md` — what was said before this process started, from the spec's
`replay` (`conversations.md` § Lifetime). `Dir.prepare/3` removes it when the spec carries none.

On a resume the spec, the prompt, `inputs/`, `platform/`, `tickets/` and `conversation.md` are
rewritten; `out/`,
`home` and earlier transcripts are kept. A run with no session to resume is a cold start and
clears `out/` as well (`Dir.prepare/3`). Artifact and state names are single path segments,
checked by the validator, so nothing in the workflow can name a path outside these directories.

A conversation declares nothing: every file it leaves in `out/` besides `proposals/` is a
document, recorded after each turn (`conversations.md` § Commits, `Dir.documents/1`). A
conversation never resumes a session, so every start of one is cold and begins with `out/`
empty; what it wrote before is in `inputs/` instead — the ticket's latest documents for a ticket
chat, and a project chat's own (`conversations.md` § Context).

The path is passed as an environment variable and repeated in the manifest. `changeset` has
no file under `out/`: it is the branch. As an input it is `inputs/changeset`, the diff of the
ticket's branch against its base, taken when the job was created.

## The contract, as the preamble states it

- Read the inputs. Do the work described by the state prompt. Commit code to the current
  branch with ordinary commits; history is squashed later.
- Write each declared output to its path under `out/`. Do not write anything else there;
  undeclared files are rejected and the job ends with outcome `error`. The one exception is
  `out/proposals/`, which `Dir.collect/2` subtracts before it counts what is undeclared.
- Begin each document with YAML front matter containing `outcome`, one of the values listed
  in the manifest, or `did_not_converge` if the work could not be completed.
- Ask questions inside the document, next to the passage they concern, as fenced
  `question` blocks. Prefer few, specific questions with a recommended default. State the
  assumption taken for non-blocking questions and continue. Use `blocking: true` only when
  no reasonable assumption exists.
- Propose a ticket for work that is real but not this ticket's, instead of doing it or losing
  it: one file per proposal in `out/proposals/`, an H1 title and a body, with no front matter
  and no `question` blocks. A proposal is a suggestion; nothing runs until a person accepts it,
  and there is a limit per job (`ticket-proposals.md`).
- Read `tickets/index.md` before proposing. It lists every ticket on the project and every open
  proposal, as a snapshot; each ticket's file holds its body and nothing else.
- Budgets are fixed. Stop when told to; the platform enforces them regardless.
- Do not edit `.forge/workflow.yml`, anything under `.forge/agents/` or anything under
  `.forge/commands/` in this job.
- Do not write outside the repository and `$FORGE_JOB/out/` — and `$FORGE_JOB/invoke.json`, when
  the manifest lists commands this job may run.

## Output format

```markdown
---
outcome: done
---
# Plan

... prose ...

```question
key: storage-backend
anchor: "Persist the high score table"
text: Local file or the existing SQLite database?
options: [local-file, sqlite]
default: sqlite
blocking: false
assumption: sqlite
```
```

`key` is stable within the document and is how answers attach. `anchor` quotes the passage
so the queue can show the question in context. `options` is a short list; free text is
always allowed as an answer but is not offered as a tap.

## Blocking questions and `waiting`

A question is identified by its artifact and `key`. It is open while the latest version of
that artifact carries it and no version has received an answer for the key. An agent that
keeps the block in the document after resuming therefore does not ask again; the platform
passes the answered keys to the worker.

When the collected document contains an open question with `blocking: true`, the worker does
not evaluate outcomes. The job's status becomes `waiting`, its process ends, and the question
enters the queue. On answer, the platform writes a new version of the `answers.md` artifact,
adds it to the job's inputs, and resumes the same job, same attempt, with the harness session it
recorded. Front matter written before the block is ignored until the job ends without open
blocking questions. There is no timeout and no automatic fallback.

## Commands

A job whose state has `may_invoke` is told so in its manifest: each command it may run, how many
invocations of it remain, and how to ask — write `$FORGE_JOB/invoke.json`, a JSON array of
`{"command": …, "args": […]}`, and end the run. The run is then *parked*, not finished: its outputs
are not collected and no outcome is decided (`commands.md` § How an agent invokes). A job whose
state may not invoke is not told how: the preamble names the file only as one to leave alone
unless the manifest lists commands, and `platform.md` says what commands are without the format.
One it writes anyway is removed and ignored, so a stray file cannot turn a finished run into an
endless round of refusals.

**The results come back in the manifest, under *Commands you ran*.** Each invocation of the batch
that parked it: the command and its arguments, the commit it ran at, its exit status or why it has
none, how long it took, and where its log is — `$FORGE_JOB/commands/<n>-<command>.log`, fetched
from the store before the run starts. A refused invocation is listed with its reason. The section
is in the manifest rather than the continuation alone because a resume whose session did not
survive gets a cold start, and a cold start has to know what it asked for too.

### The continuation prompt

A run that resumes its harness session is handed a **continuation**, `Prompt.continuation/3`,
rather than the whole prompt again. The session already holds the preamble and the state prompt;
what it lacks is what happened while it was stopped:

1. **The answers** — `answers.md` as the spec pins it: its version, its path, and its text
   inline, fenced verbatim. That is every answer on the ticket, oldest first, so the ones this
   job stopped for are among the newest. Absent when the spec carries no answers input.
2. **The branch** — its name and the commit the worktree is at, which the worker reads from the
   checkout it has just made, as the job's user (`ForgeWorker.Job.Workspace.head/2`). The earlier
   run's work was committed and squashed when it stopped (`worker-tier.md` § Git), so the history
   is not the one the session remembers even though the files are, and the prompt says so.
3. **The manifest**, whole: it is short, it lists `answers.md` among the inputs, and it carries
   the budget as assigned, which the platform may have lowered since the session last saw it.

**Which prompt a run gets is decided where `--resume` is, from the same value.** The worker's
runner reads `resume_session` from the assignment: set, the continuation goes to stdin and the
driver adds `--resume`; unset, `Prompt.compose/2` and no flag. One value decides both, so the
prompt and the flag cannot disagree.

**Whether the session is really there is not predicted, by either side.** The platform could
compare the worker it picked with the job's `worker_id`, and the worker could look for Claude
Code's session file under the job's `home`, but both are a model of the harness's session lookup
rather than the lookup, and a guard must use the model of the operation it guards. The lookup is
`--resume` itself. When it finds nothing the harness exits before `system/init`, the platform
re-queues the job with no session (`claude-code-events.md` § Resume), and that run is a cold
start with the full composed prompt — so a continuation is never acted on by a session that did
not resume. That rests on the harness failing a missing session rather than starting a new one,
which is what `Forge.Jobs.complete/2` already reads; a harness that started afresh instead would
hand the continuation to an agent with no memory of the job. **That is unmeasured.** Nothing has
run `claude --resume` against a session id its home does not hold and recorded what it does:
`bin/measure streaming` does not resume, and no other measurement covers it. It is what the code
assumes, and it is the first thing to measure if a resumed job ever behaves as though it
remembers nothing.

**The worktree a continuation names has to be the branch.** A resume keeps the working tree it
finds, because an unfinished tree is what a resume is for. It used to skip the reset for a tree it
had only just made, too — a snapshot of the ticket's volume or the project's seed, which is on
whatever commit that volume was — so a resume on a machine without the job's own worktree ran on
the wrong tree, and the squash at its end pushed the difference as a commit reverting the ticket's
work. A snapshot is reset to the branch whatever the assignment says
(`ForgeWorker.Job.Workspace.prepare/3`); only a worktree that was already there is kept.

### Non-blocking questions

Non-blocking questions do not stop anything. They are recorded and shown on the ticket's page,
where they can be answered, and their answers arrive as inputs to whichever job runs next on the
ticket.

They are also **shown in the queue as digested items**, so that a question an agent carried on
past reaches someone who has not opened its ticket. `Forge.Queue` serves each open one as its own
kind, `:assumption` — never as a `:question`, so nothing that reads the queue can take it for
one that halted a job — and the queue page draws them beneath its decisions under *Not waiting
on you*, as lines that lead to the ticket rather than cards that answer in place
(`ui.md` § Not waiting on you). The daily digest push counts them apart from what is waiting
(`Forge.Push.digest/0`, `api-and-ui.md` § Push). They are never pushed on their own.

**Answering one changes no job's flow.** `Forge.Operator.answer/4` writes the answer and a new
`answers.md` version, then resumes the waiting job of the ticket's state only if no blocking
question on the ticket is still open — and a non-blocking answer closes none, so a job waiting on
a blocking question keeps waiting, and a job that is running or not yet started is untouched. The
answer reaches the next run through `answers.md`, which is how every answer reaches a job.

One case bends that, and it is a gap in editing rather than a rule of answering: a person's edit
that drops a blocking block while its job waits leaves the job waiting with nothing open, because
`Operator.edit/4` resumes nothing, and the next answer of any kind — a non-blocking one included —
then resumes it. The resume is the edit's, arriving late; the fix belongs to the edit. A person's
edit is the one way left to get there. A conversation about the ticket was the other — it writes
the ticket's documents every turn — and it is refused that document while the job waits, and
never raises a question of its own (`conversations.md` § Commits).

## Groups of files

A state producing `package/*` is told, in its manifest's outputs, to write any number of files to
`$FORGE_JOB/out/package/` (`workflow-grammar-v1.md` § Semantics). Each is kept as a blob, uploaded
when the run finishes — not when it parks or stops on a question, since `out/` is kept for the
resume and the run that finishes is the one whose files count. What cannot be kept is reported
with why: a file larger than the worker's cap (`max_blob_bytes`, a gibibyte unless configured), one
past the group's count cap (`max_blob_files`, a hundred), anything not a regular file the job owns,
and a name that is not an artifact name. None of those fails the job; a group has no minimum.

Only the group's directory is declared, as a directory: a *file* straight in `out/` named
`package` is kept out of `undeclared` like the directory would be, and reported instead under the
group, `package/*`, as "must be a directory, not a file". A directory under `out/` that is not a
declared group is undeclared.
