# Ticket proposals

An agent that notices work outside the ticket it is on has nowhere to put it. It says so in a
document nobody reads back, or it does the work and widens the change, or it is lost. This note
is the standard for the third option: **any job may propose a ticket, and no job may write one**
— and for what a job is given to read so that it proposes something new.

A proposal is a document. Accepting it admits a ticket.

## Propose, never write

An agent's write scope is its own ticket, everywhere else in the system. A job reaches its
repository with a credential scoped to exactly one ref and the `pre-receive` hook refuses
anything else — another ticket's branch, the default branch, a deletion
(`docs/design/git-hosting.md`). **Ticket state is not the exception to the rule git already
enforces.**

So a job may say a ticket should exist. It may not create one, set a state, take a transition, or
touch a ticket that is not its own. Creating work spends money and takes a slice, and
`docs/vision.md` is explicit that an agent may never widen its own envelope. Admission is the
human act that widens it, and it already exists: `Forge.Tickets.admit/3`.

This also makes loops a non-problem. Ticket A's job proposes B, whose job proposes C — and it
terminates, because a person stands between each pair. There is no `propose_depth` and there does
not need to be one.

## Any job, and no grammar key

Every job may already ask a question. Nothing in `.forge/workflow.yml` permits it; it is in the
platform preamble, identical on every project, and the grammar has no `question` key at all. A
proposal is the same shape of thing — something the agent noticed that only a person can decide —
so it is permitted the same way, for every job, with no declaration.

The alternative was a per-state key (`can_propose: { tickets: 3 }`, in the `can_spawn` idiom).
It is rejected, and not only for being more grammar. **Discovery is not predictable by state.**
An implementing job that finds a follow-up in a state whose author did not think to declare
`can_propose` would either drop the finding or fail the job over it, and a silent drop is what
`docs/poc-plan.md` § Definition of usable rules out.

What bounds it is a cap on proposals per job, held by the platform beside the daily spend cap.
Not a workflow key: how many follow-ups an agent may raise is not the project's business to
declare, for the same reason the state that discovers them cannot be known in advance.

## Shape

**One proposal is one document artifact, at one version.** Not several proposals in one
`proposals.md`: bundling them is what forces acceptance to attach to part of a version, and
approval in this system attaches to a whole one (`docs/design/data-model.md`). Every awkwardness
in the bundled form — stable keys per block, a second block type in `ForgeCore.Document`, a row
per proposal, an open-ness rule parallel to the one questions already have — is a consequence of
the bundling and disappears without it.

**A proposal's only front matter is the ticket type it suggests.** It is an H1 and prose, written
with `parse: false`, which makes it byte-identical to the `ticket` document admission already
writes (`"# #{title}\n\n#{body}"`, also `parse: false`, in `Tickets.put_admit/5`) — preceded,
when the agent suggests a type, by `---`, `type: <name>`, `---`, which `ForgeCore.Proposal` reads
as one line of one key and never as YAML (`ticket-types.md` § Proposals). The title is the H1.
Accepting splits it back off and admits it by the same steps `admit/3` runs (§ Accepting) — a
proposal is a `ticket` document that has not been admitted yet, and that is the whole mechanism;
the type it suggests chooses the workflow and never reaches the ticket's body.

This is also the one thing that had to be got right rather than merely chosen, and the reason is
not the one it first looks like. `Artifacts.put_version/7` parses every document unless
`parse: false`, and a proposal is written **in the multi that records the job's whole result** —
its documents, its cost, its outcome, its event. `Document.parse/1` refuses a malformed
`question` block, so without `parse: false` a proposal could take all of that down with it and
the run would look as though it had never reported. A proposal is not worth a job's outcome.

The guess worth naming, because it is the one a reader makes and it is wrong: that the danger is
an unanswerable question in the queue. It is not. `Artifacts.open_questions/1` is scoped by
`ticket_id` and a proposal is scoped to its job, so the queue never sees a question written
against one. The rows would be dead rather than dangerous. A test asserting the queue stayed
empty passed with `parse: false` removed, which is what a mutation is for.

## Scope: the job, not the ticket

`artifacts` carries `ticket_id` and `job_id` with exactly one set, and uniqueness is per scope and
name. A proposal is scoped to the **job that wrote it**.

Scoping to the ticket does not work: three proposals from job 1 and two from job 4 would compete
in one per-ticket namespace, so the names would have to encode which job wrote them — which is
`job_id` spelled into a string. Per job, three names inside one job's output is trivial.

What it buys beyond that: provenance is exact — *which job proposed this*, not merely which ticket
— the ticket page reaches them through its jobs, and a conversation's proposals work without a
special case, because a conversation is a job.

**What this costs, stated plainly:** `job_id` on `artifacts` was added for chat artifacts, and the
schema says so — "a conversation with no ticket still writes". Using it for a workflow job's
proposals widens what the column means, from *this artifact belongs to a chat* to *this artifact
belongs to a job rather than to the ticket's record*. The constraint is unchanged and no existing
row moves, but the field means more than it did.

## The files

The agent writes `$FORGE_JOB/out/proposals/<name>.md`. One file, one proposal.

`ForgeWorker.Job.Dir.collect/2` computes `undeclared` as
`(written -- declared) -- [proposals]` against `Spec.document_outputs/1`, so the subdirectory is
subtracted there rather than named as a declared output. That subtraction is load-bearing rather
than tidy: an undeclared output is refused — the job is told and resumed to remove it, and ends in
`error` if it stays (`claude-code-events.md` § Correcting the outputs) — so without it a job that
proposed anything would be told to take its proposals back.

A reserved *directory* is a cleaner carve-out than a reserved filename. It is also why no group
of files may be called `proposals/*`: `out/proposals/` is this directory
(`workflow-grammar-v1.md` § Semantics).

**Stored as `proposal-<file>`, and the prefix is the discriminator.** A job-scoped artifact is a
proposal because its name says so, and nothing else does — job scope alone cannot say it, because
a project conversation's own documents are job-scoped too (`conversations.md` § Commits), and the
names they may take exclude this prefix for that reason. The agent's filename is kept after the prefix:
it is the only place the agent names what a proposal is about in a word, and the title names it in
a sentence. `ForgeCore.Workflow.proposal_artifact/1` and `proposal?/1` are the pair, and they are
tested together, because moving them apart means proposals written under one name and looked for
under another — which shows up as no proposals at all rather than as an error.

**A file already named `proposal-…` keeps its one prefix.** Nothing said whose the prefix was, and
agents reading the backlog, where open proposals are listed under their stored names, copied it:
six of one project's ten open proposals were stored as `proposal-proposal-…`, which is what the
person read. The preamble, the conversation's preamble and `platform.md` now say the platform adds
it, and `proposal_artifact/1` leaves a name that already carries it alone.

`proposals/` is never in `produces`, so it is never the first document in `produces`, so it never
carries the outcome. A job that writes nothing there is an ordinary job. The validator reserves
both shapes — the directory name and the `proposal-` prefix — as it already reserves `ticket` and
`answers.md`.

## Accepting

Acceptance admits the proposal's title and body by the steps `Tickets.admit/3` is made of, not by
calling it: `Tickets.prepare_admission/2` before the transaction, then `Tickets.put_admit/5`
inside `Proposals.accept/4`'s own multi, beside the decision. Nothing about admission changes: it
pins the workflow, allocates the number under the lock on the project row, writes the `ticket`
document, creates the first job and the branch.

**The workflow pins at accept time, not at propose time**, and the opposite reading is plausible
enough to write down. A proposal is not work in flight and holds nothing; it should run against
whatever the project declares when a person says go, which may be months after an agent thought
of it.

Acceptance and the admission it causes are one transaction. The decision row carries the new
ticket (§ Deciding), so the link is a foreign key in both directions rather than a payload field
to be dug out of the log, and the events are written beside it as every mutation's are. One
effect is outside the transaction: `put_admit/5` creates the branch in the repository, which an
accept rolled back after that step leaves behind with no ticket naming it — a stray ref, which is
collectable, where a stray ticket would spend money.

## Deciding

A decision on a proposal is its own row: the version it decided, the user, approve or reject, a
comment, and the ticket it created when accepted.

**It is not an `approvals` row, and the pull to make it one should be resisted.** The shape
matches — a user, a decision, a comment, an exact version — but the meaning does not.
`approvals.transition` is required and validated as `%{"from" => state, "to" => state}` because an
approval in this system *authorises an edge in a statechart*: the engine reads it against a
ticket's `pending_transition`, and that is the whole of what it is for. A proposal has no ticket,
no pending transition and no edge; what it authorises is admission.

Making `transition` nullable to fit is the trade conversations.md wrote up for `jobs.kind` —
"every consumer that assumes a job has a state, a spec and a ticket must learn otherwise" — bought
here for nothing. The engine would gain rows it must never act on, in the one table whose entire
purpose is telling it which edges are authorised. The two are never compared, because nothing that
reads approvals for a ticket can reach a proposal's decision, so the "one truth" argument for
merging them does not apply either.

The row earns its keep beyond avoiding that. It carries `ticket_id`, set when accepted, which is
the provenance link in both directions as a foreign key rather than a payload field to be dug out
of the event log. It is the queryable index for a versioned, attributed record, which is exactly
what `docs/design/data-model.md` says `answer` is and for the same reason.

**Open-ness is the same rule questions already use**, without reusing their machinery: a proposal
is open while the latest version of its artifact has no decision. A newer version has no decision
until it gets one, so a decision never carries to text nobody has read.

**Nothing edits a proposal yet, and this note used to say otherwise.** It claimed the operator
rewrites a verbose title with `Operator.edit/4` — which takes a ticket and writes at ticket scope,
while a proposal is scoped to its job, so editing one by name silently creates a decoy artifact on
the ticket instead. The version-granular rule above is what *makes* editing safe when it arrives;
it is not the same thing as its existing. Until it does, a proposal is accepted as written or
declined.

**A declined proposal is a recorded decision, not a deletion.** It has to be one: recording is by
content (below), so a later job writing the same proposal again finds it already recorded and
decided, and it does not come back. A job is not shown declined proposals — `tickets/index.md`
lists only open ones — so one worded differently is a new proposal, and is decided again.

**Recording is idempotent by content**, which is what makes it safe to collect the same folder
more than once for one job. `out/proposals/` accumulates: a conversation reports it every turn, so
turn five re-reports what turn one wrote. Writing those again as new versions would *reopen* a
proposal the operator had already decided, because a decision attaches to a version and the
newest one would have none. A proposal whose text changed does get a new version, which is the
case this must not also swallow. A workflow job's folder likewise survives a park on a blocking
question, and there the platform does not lean on this: `Forge.Jobs` records proposals only from
a run that finished, never from one that stopped to wait.

**The cap is on the job, not on the call.** `Forge.Proposals.cap/0` is a platform setting beside
the daily spend cap, and what is already stored counts against it — otherwise a conversation could
add a capful every turn and have no cap at all. What goes over it is refused with an event naming
each file, never dropped.

## Malformed degrades, never drops

A proposal the platform cannot use — no H1, an empty body — is kept verbatim as a version, with
its reason recorded in the log, and shown as what it is: open, marked unreadable, declinable and
never acceptable, because `accept/4` parses the stored text rather than trusting it. It does not
fail the job.

The text is what matters and it is the part that was missing: an earlier version of this recorded
the filename and the error and dropped what the agent had written, which is the drop this section
forbids. Where there is no text to keep — a symlink, a directory, a file that would not open, a
file that is not the job's own — there is no version, and the reason in the log is all there
ever was. "The job's own" is decided by the file opened, not by its path, and `proposals`
itself is listed only when it is a directory and not a link standing in for one
(`conversations.md` § Commits has why: this path exported a file root could read).

`proposals/` is not in `produces` and carries no outcome, so nothing about the job's result
depends on it, and ending a finished implementation with `error` over a malformed side-channel
would trade real work for a typo. This is the same shape as `job.harness.unknown`, which keeps a
harness line the event mapping does not recognise rather than dropping it
(`docs/design/claude-code-events.md`).

## A failed job proposes nothing

A job that ends in `error` has its proposals **withheld**: none is recorded as a version, and
`proposals.withheld` names the files instead (`Forge.Jobs`, `put_proposals/3`). A job that ends
`did_not_converge` or on its budget still proposes; only `error` withholds.

The case that made this a rule: two refinements failed in production because their
`refinement.md` did not parse. The document was dropped with its questions, and the proposals
written beside it were recorded all the same — so a person was asked to decide follow-ups to scope
nobody had been shown, and declined one of them. A proposal is scoped by the work it sits next to;
when that work is thrown away, the proposal has nothing to be read against.

This is a drop, and it is bounded rather than silent. The event names every file, the transcript
keeps what the agent wrote, and the ticket's next run of the state — a retry, or the run the
correction loop makes before the job ever reports (`claude-code-events.md` § Correcting the
outputs) — proposes again from work that stands.

## Where it surfaces

**Proposals are digested, not queued.** The queue's decisions are what will not move until a
person acts, and a proposal blocks nothing — no job waits on it and no ticket is stuck behind it.
`docs/decisions.md` already draws this line: push for blocking questions, everything else
digested. The queue is no longer only decisions — open non-blocking questions follow them, as
`assumption` lines that no count of what is waiting includes (`ui.md` § Not waiting on you) —
and a proposal is not one of those either, for the two reasons below: how many there would be,
and that its decision belongs on the project page.

Putting them in the queue would be the more obvious choice and it is the wrong one. Eighteen jobs
proposing two each is how the queue's promise — that you can reach the end of it and be done —
stops being true, and it would be spent on the one class of item that could have waited.

They are decided on the project page, where every open proposal on the project is in one place:
what each says, where it came from, Accept and Decline. A ticket page *names* what its own jobs
proposed and links there rather than offering the decision too — the affordance that commits
belongs in one place, and two of them means one you did not open. The endpoints and the page
sections are in `docs/design/api-and-ui.md`; a proposal is named there by its **version** id,
never its artifact's, because a decision attaches to an exact version.

The daily digest counts them, under "proposed" rather than "waiting on you". Folding them into
that count would make the queue's promise — reach the end of it and be done — read as broken by
things that were never in it.

## Not in this

- **Modifying an existing ticket.** Retitling, closing as duplicate, re-scoping. Each needs a
  target, a decision and a story about racing that ticket's own running jobs, and nothing has yet
  shown they are needed. The rule above already says what the answer will have to look like when
  they are: propose, never write.
- **Rewriting the ticket body.** `ticket` is never produced, and it stays that way. It is the
  record of what the person asked for, and a refined statement of the problem is what
  `refinement.md` is. An agent that rewrites the ask leaves nothing to check the refinement
  against.
- **A ticket row in a pre-admission state.** Considered and rejected: `tickets.status` gaining
  `:proposed`, with `workflow`, `branch` and `state` nullable until admission. It gives a proposal
  a number and a lane on the board, and it costs a second shape of ticket that the scheduler,
  `Spend`, the queue and the board must each be taught to exclude — one place forgetting it is a
  proposal being scheduled. A document needs none of that, and admission stays the single door.

## Reading the backlog

Proposing without reading produces duplicates on the first day: three jobs on three tickets each
notice the same missing module and each propose it. So every job is given the project's tickets,
and — because a proposal is a document rather than a ticket row — the open proposals beside them.

**Every job, no grammar key, same as proposing.** An unread file costs nothing. Tokens are the
scarce thing here, not disk, and an agent does not spend them on a file it does not open.

```
$FORGE_JOB/tickets/index.md                       # one line per ticket and open proposal
$FORGE_JOB/tickets/12.md                          # ticket 12: header, then its body
$FORGE_JOB/tickets/proposals/proposal-<file>.md   # open, not yet admitted
```

Composed by `Forge.Backlog.compose/2` when the job is assigned, carried in the assignment beside
`seed` and `slice`, and written by `Dir.prepare/3` — for a conversation on the same terms as a
workflow job, because both reach the same `Runner.start_link/1`. It is rewritten whole on every
prepare, resume included: a file left from an earlier composition is a ticket the agent believes
still exists, which is worse than having no folder at all.

**The file names cross the channel and are joined to a path, and the check on them is lexical.**
Each is expanded with `Path.expand` and required to sit directly in the folder, which is not the
model `File.write!` follows — the gap `CLAUDE.md` names. It is sound for a reason outside the
check: the folder is removed and recreated on every write, so nothing the agent planted survives
into it and an entry cannot make a subdirectory to hide a symlink in. `Dir.write_backlog_entry/2`
says so where it lives; a change that stops recreating the folder has to replace the check.

**The index is what an agent reads; the files are what it opens.** A line carries the number,
state, status and title — and the ticket's type, on a project that has types — enough to decide
whether the file is worth a read, and useless for anything else, which is the point. On such a
project the index also lists the types, each with the state it starts in and its description,
read from the default branch at composition, so a proposal can suggest one
(`ticket-types.md` § What a job is told). Without an index the agent greps blindly or opens everything.

**Bodies only here; the artifacts are in the archive.** `tickets/` is still a ticket's body and
nothing else, which is all that duplicate suppression and coordination need. Another ticket's
`plan.md` is its reasoning at versions this job did not pin, and it is not handed over as an input:
it can be read from `$FORGE_JOB/archive/`, a live folder that is pinned to nothing and says so
(`archive.md`). The inputs stay the contract; the archive is what a job may look at.

**Composed at every assignment, with its hash recorded.** It is a snapshot, not a pinned version,
and it is the one thing a job is handed that is not an artifact version — a generated index has no
version to pin. Recording the hash is what keeps "what was this built on?" answerable: not by
naming a version, but by making the snapshot reproducible from the log. `Jobs.assign/2` writes it
as `job.backlog` with the counts beside it, once per assignment — so a job resumed after a
blocking question, and a conversation reopened, is handed a fresh snapshot and logs a second
event for it. Within one run the view ages, and the index says when it was taken.

The hash covers the **bodies**, not only the index. Titles appear in both, so a hash over the
index alone looks correct on every change to a title and misses every change to a body — a
snapshot that cannot be reproduced from the log, with nothing saying so. A mutation found that;
no test had.

**Project-scoped, always.** A job on project A can never see project B's tickets. The index is
generated by the platform, so this is an invariant of the generator rather than a rule an agent
is asked to respect.

### A mounted filesystem, now

This section used to reject a mount that fetched on open; `CLAUDE.md` says a change of mind updates
the note before the code, and this is that. The person who owns the project has chosen it (ticket 24, for the
history of the project and not for this backlog, which stays a snapshot of bodies), so each of the
four objections is answered where it stood. The mount is `$FORGE_JOB/archive/`, in `archive.md`.

- *The cost it saves is disk, and a megabyte of bodies is nothing.* The cost it saves now is
  transfer: every version of every document and every uploaded file of a project, which can be
  gigabytes and which no job should be handed at every start. Bodies stay a snapshot.
- *A mount means a daemon, a namespace and a teardown that must not outlive the job.* There is no
  daemon: the server is a process under the job's run, listening on a socket in a directory of its own, mode 0700 and
  named at random; the mount is made once the slice has handed the job directory to the job's user and is released before `Slice.leave`, and
  the worker's start unmounts what a killed worker left, and `Dir.sweep` releases the one directory it removes.
- *A read is a round trip whose failure is `EIO` the agent did not expect.* The failure is bounded
  (10 s to connect, 30 s without progress), it fails the `open` and not a read half way, it names
  its cause as an errno, and the preamble says what each means. A failed fetch never leaves a file
  that looks complete.
- *It destroys pinning invisibly.* The prompt says in a sentence that the folder is live, versions
  are in the names so an agent can cite one, and the platform records which versions the job opened
  (`job.archive_read`). `inputs/` is unchanged.

## Open

Nothing. Both halves are built — every job may propose and every job is handed the backlog — and
the conversation half came with them, because a conversation is a job and writing its preamble
made the gap obvious: it promised proposals were recorded and nothing recorded them.

§ Not in this still holds, unchanged: modifying an existing ticket, rewriting a ticket body, and
a ticket row in a pre-admission state are all out, with their reasons. So is any grammar key —
`can_propose`, a per-state backlog opt-in, a declared cap — for the reason § Any job gives.

The first thing to disagree with a decision here should change this note before it changes the
code.
