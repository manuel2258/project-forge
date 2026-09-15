# The platform you are running on

This describes the machinery around you. You do not have to read it to do ordinary work — your
own instructions come first — but it is here when what the platform does with your output is the
question.

## Tickets, states and jobs

A **ticket** is one piece of work. It moves through the **states** of the project's workflow, and
a state is entered by running a **job**: one agent, one prompt, one set of inputs, one set of
declared outputs. You are a job, or you are a conversation (below).

A job ends by declaring an **outcome** in the front matter of its first declared document. The
outcome selects which **transition** the ticket takes next. A job does not choose where the
ticket goes; it says what happened, and the workflow decides.

Jobs are disposable. The machine you are on is thrown away when you finish. What survives is what
you committed to the branch, and the documents you wrote to `$FORGE_JOB/out/`.

## Artifacts and versions

Every document a job writes becomes a new **version** of an **artifact** named by the workflow —
`plan.md` version 3, and so on. Versions are immutable and never overwritten. A later state that
lists `plan.md` in its inputs is handed an exact version, pinned when the job was created.

`changeset` is not a file: it is the diff of the branch's commits, recorded as a commit id.

A person can **approve** an exact version. That is what authorises a merge, and it is why nothing
in this product says "approve whatever is latest".

## Questions

A job asks inside the document it is writing, in a fenced `question` block, next to the passage
the question is about. A blocking question stops the job until a person answers; a non-blocking
one states the assumption the job proceeded with and carries on. The answers a person gives come
back to later jobs as `answers.md`.

## Branches and merging

A ticket has one branch, `ticket/<number>`. Every job of that ticket commits to it, so the work of
the jobs before you is already in the checkout you are in. There are no per-job branches.

A conversation has its own branch, `chat/<id>`.

**Nothing pushes to the default branch except the platform's own merge.** A credential is scoped
to exactly one ref, and the repository refuses everything else. Work reaches the default branch by
a person approving it and the platform merging it — never by a push from here.

## Conversations

A conversation is the other thing the platform runs: an agent a person talks to, in a project's or
a ticket's context, with no state, no outcome and no end until the person stops. It commits to its
own branch like a job and the person merges that branch if they want the work.

Bootstrapping a project — writing its first `.forge/workflow.yml` — is a conversation's job, not a
workflow's, because until that file exists there is no workflow to run.

## Spend

Every job has a turn and cost ceiling, and the node has a daily one. They are enforced by the
platform whatever you do, and a job stopped by a ceiling is recorded as having been stopped by it.

## Where things are

- `$FORGE_JOB/platform/` — this file, and `workflow-grammar.md`, which is what
  `.forge/workflow.yml` may contain and what the validator accepts.
- `$FORGE_JOB/inputs/` — what you were given, read-only.
- `$FORGE_JOB/out/` — what you write, if you are a job.
- `$FORGE_JOB/history/` — for a conversation about a ticket, what already ran on it.
