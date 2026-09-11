# Job prompt and the agent's interface

Scope: how a job's agent learns what to do, where inputs and outputs live, and how it asks
questions. The interface is files, not tools, so any harness with a filesystem can run a job.

## Three layers, one composed prompt

1. **Platform preamble.** Owned by forge, versioned in `core/`, identical for every job on
   every project. States the contract below. Its hash is part of the job spec.
2. **Project state prompt.** The file named by `prompt` in the workflow, e.g.
   `.forge/agents/refine.md`. Says what this kind of document is and how the project wants it
   written. Read at the pinned commit.
3. **Job manifest.** Rendered from the immutable spec: ticket title and number, each input
   with its path and version, each `produces` entry with its target path, the allowed
   outcomes, the budgets.

The repository's own `CLAUDE.md` is read by Claude Code as usual; project conventions need no
special handling.

## Job directory

Outside the worktree, so nothing in it can be committed by accident:

```
$FORGE_JOB/spec.json                # the immutable spec, for reference
$FORGE_JOB/inputs/ticket.md         # reserved input: the ticket body
$FORGE_JOB/inputs/refinement.md     # pinned version, read-only
$FORGE_JOB/inputs/answers.md        # present after any question was answered
$FORGE_JOB/out/plan.md              # written by the agent
```

The path is passed as an environment variable and repeated in the manifest. `changeset` has
no file: it is the branch.

## The contract, as the preamble states it

- Read the inputs. Do the work described by the state prompt. Commit code to the current
  branch with ordinary commits; history is squashed later.
- Write each declared output to its path under `out/`. Do not write anything else there;
  undeclared files are rejected and the job ends with outcome `error`.
- Begin each document with YAML front matter containing `outcome`, one of the values listed
  in the manifest, or `did_not_converge` if the work could not be completed.
- Ask questions inside the document, next to the passage they concern, as fenced
  `question` blocks. Prefer few, specific questions with a recommended default. State the
  assumption taken for non-blocking questions and continue. Use `blocking: true` only when
  no reasonable assumption exists.
- Budgets are fixed. Stop when told to; the platform enforces them regardless.
- Do not edit `.forge/workflow.yml` or anything under `.forge/agents/` in this job.

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

When the collected document contains an open question with `blocking: true`, the worker does
not evaluate outcomes. The job's status becomes `waiting`, its process ends, and the question
enters the queue. On answer, the platform writes a new version of the `answers` artifact,
adds it to the job's inputs, and resumes the same job, same attempt, with a continuation
prompt naming the answer. Resume uses the harness session where available and a fresh
invocation otherwise. Front matter written before the block is ignored until the job ends
without open blocking questions. There is no timeout and no automatic fallback.

Non-blocking questions do not stop anything. They are recorded, shown in the queue as
digested items, and their answers arrive as inputs to whichever job runs next on the ticket.

## Reserved for later

Prefix groups (`screenshots/*`) for blob outputs with an open member count. The validator
rejects the form in v1 with a message saying it is reserved.
