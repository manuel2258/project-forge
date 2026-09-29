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

Jobs are disposable. Assume nothing on the machine outlives your job: what survives is what you
committed to the branch, and the documents you wrote to `$FORGE_JOB/out/`.

A document the platform cannot accept — missing, unparseable, an outcome the state does not allow
— is sent back to the job that wrote it, with what is wrong, before the job is reported. After two
such rounds the job ends in `error`.

## Artifacts and versions

Every document a job writes becomes a new **version** of an **artifact** named by the workflow —
`plan.md` version 3, and so on. Versions are immutable and never overwritten. A later state that
lists `plan.md` in its inputs is handed an exact version, pinned when the job was created.

A state can be entered more than once: a later state may send the ticket back with its reasons,
and a person resting the ticket in a state of theirs may write a document for the next job to
read. An input written only on such a return is absent the first time and named as such.

`changeset` is not a file: it is the diff of the branch's commits, recorded as a commit id.

A person can **approve** an exact version. That is what authorises a merge, and it is why nothing
in this product says "approve whatever is latest".

## Commands

A project may declare **commands**: fixed scripts, read from the workflow's pinned commit, that run
as jobs of their own, possibly on another machine. A state may run them on entry, and a job's manifest
may list commands its agent may run — by writing `$FORGE_JOB/invoke.json` and ending the run, which
parks the job until they are done and resumes it with their exit statuses and logs. A job
that a command state sent the ticket to — a build that failed, sending it back — is handed that
state's statuses and logs the same way, under *How you got here* in its manifest. The format is
in the manifest of a job that may; a job whose manifest lists none needs nothing from this section.

If you write or change a command script, know where it runs. It starts in the checkout, and
`$FORGE_CHECKOUT` names the checkout too. The script itself is not in it: what runs is the pinned
copy in the command job's own directory, so a path climbed from `dirname "$0"` leaves the
repository. `$FORGE_OUT` is where it writes its groups of files. Its `HOME` is empty and never
handed to another job, so a tool cache meant to carry from one job to the next — Gradle's, npm's, cargo's —
belongs inside the checkout and ignored by git, where the project's seed and the ticket's own
volume keep it.

## Questions

A job asks inside the document it is writing, in a fenced `question` block, next to the passage
the question is about. A blocking question stops the job until a person answers; a non-blocking
one states the assumption the job proceeded with and carries on. A person answers a document's
questions together and sends them at once, so the job that stopped resumes once, with every
answer, and every later job on the ticket is handed them as `answers.md`.

## Ticket proposals

Any job and any conversation may say a ticket should exist. None may create one: a proposal is a
document you write to `$FORGE_JOB/out/proposals/`, and a person accepts or declines it. It is
stored as `proposal-<your file name>`; the platform adds the prefix, so do not. Accepting
admits it as an ordinary ticket, pinning the project's workflow **at that moment** rather than
when it was proposed.

This is the same rule as everywhere else here — your write scope is your own ticket, and beyond
it you can only speak. It is also why proposing is free: nothing you write starts work, spends
money or takes a machine.

An accepted proposal becomes a ticket like any other; a declined one is recorded and is no longer
listed. `$FORGE_JOB/tickets/` is the project's tickets and its open proposals, as a snapshot taken
when your job started. A job that ends in `error` proposes nothing: what it wrote there is withheld.

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
own branch like a job and the person merges that branch if they want the work; closing the
conversation deletes a branch that was not merged, unless it would not merge cleanly.

Bootstrapping a project — writing its first `.forge/workflow.yml` — is a conversation's job, not a
workflow's, because until that file exists there is no workflow to run.

## Spend

Every job has a turn and cost ceiling, and the node has a daily one. They are enforced by the
platform whatever you do, and a job stopped by a ceiling is recorded as having been stopped by it.

## Where things are

- `$FORGE_JOB/platform/` — this file, and `workflow-grammar.md`, which is what
  `.forge/workflow.yml` may contain and what the validator accepts.
- `$FORGE_JOB/inputs/` — what you were given, read-only.
- `$FORGE_JOB/out/` — what you write: a job's declared outputs, or a conversation's documents.
- `$FORGE_JOB/history/` — for a conversation about a ticket, what already ran on it.
- `$FORGE_JOB/conversation.md` — for a conversation that was reopened, what was said before.
