# Conversations

A conversation is an agent you can talk to, in a project's or a ticket's context, that can commit,
propose tickets and write artifacts like any job (§ Commits). It is the "meta job" — work that
does not fit a workflow state, done by talking rather than by declaring an outcome.

This note is the standard for it. Code follows; a change of mind updates this first.

## Why it is not a workflow

The engine's shape is: a state runs one job, the job ends with one outcome, the outcome selects
one transition. A conversation has no state, no single outcome and no end that the workflow
decides — it ends when a person stops talking. Expressing it as a self-looping state with a
blocking question per turn works (`docs/design/workflow-grammar-v1.md` permits it) and is a
disguise: the queue would fill with questions that are not questions, the ticket timeline would
record a "visit" per sentence, and every outcome would be a lie told to satisfy the engine.

So conversations are native. What they reuse is everything below the engine: the worker, the
slice, the worktree, the git endpoint, the store, the event log.

## The harness supports this directly, and this was measured

`claude --print --input-format stream-json --output-format stream-json` takes **realtime
streaming input**: one process, many user messages on stdin, output streaming back. A
conversation is therefore one long-lived harness process, not a `--resume` invocation per turn.

This note asserted that before anything checked it, which is the defect this repository produces
most often. `measure/lib/streaming.sh`, run by `bin/measure streaming`, now drives a real harness
through a FIFO and asserts each answer. What it found:

| Question | Answer |
|---|---|
| Alive after the first turn? | yes — one process, one `session_id` for the whole conversation |
| A `result` per turn? | yes. A turn is `system/init` … `result`; `init` repeats **per turn** |
| Does turn 2 remember turn 1? | yes — the context is the process |
| `num_turns` | **per turn** (it counts the agent's internal turns within one) |
| `total_cost_usd` | **cumulative across the session** |
| Interrupt without killing the process? | yes — a `control_request` on stdin cuts the turn; later turns are normal |
| A message sent mid-turn? | **the harness queues it** and delivers it as its own turn |
| `--replay-user-messages` | echoes each message **when it is delivered**, after the prior `result` |
| stdin EOF | ends the process cleanly |

Three of those change the design rather than confirm it, and each is picked up where it belongs:
cumulative cost in § Spend, harness-side queueing in § Turns, and the echo in § The wire.

That the process outlives a turn is why "stay active" is a property of the process rather than a
trick with sessions. `ForgeWorker.Harness.ClaudeCode` grows a second invocation shape; the driver's
`capabilities/0` gains `streaming_input`, so a harness that cannot do it is refused rather than
silently degraded.

## Shape

A conversation is **a job with a kind**. `jobs.kind` is `:workflow` or `:chat`; `state`, `spec`
and `ticket_id` become nullable, `project_id` is added, and a `:workflow` job is exactly what it
was — the migration backfills `kind` and `project_id` and changes nothing else.

`project_id` is new because `jobs` did not have one: every job reached its project through its
ticket, as `Jobs.assign/2` did — the ticket first, then the ticket's `project_id`. A project chat
has no ticket, so without it there is nothing to clone, nothing to issue a token against, and no
project to schedule it for. A CHECK constraint keeps the
two shapes honest — a workflow job has a ticket, a state and a spec; a chat has a project and none
of them.

The alternative — its own table — was rejected because a conversation wants everything a job
already has: a worker, a slice, a cost, a transcript, an event stream, a place on a page. Two
tables would mean two of each.

**What this costs, stated plainly:** every consumer that assumes a job has a state, a spec and a
ticket must learn otherwise. `Engine.after_job` must not run for a chat — a chat produces no
outcome and selects no transition. The scheduler, `Spend`, the queue and the job page all read
those fields. A `:chat` row with `state: nil` reaching `Engine.step/4` is the failure mode to
guard against, and the guard belongs at the one place jobs complete, not scattered.

| | `:workflow` | `:chat` |
|---|---|---|
| `ticket_id` | required | set for a ticket chat, null for a project chat |
| `state`, `spec` | required | null |
| `outcome` | one, decided by `ForgeCore.Job.Outcome` | none, ever |
| ends because | the harness finished | a person stopped talking, or a ceiling was hit |
| `turns` | the harness's count | the same, across the whole conversation |

**Messages are a projection of the event log, not a table.** An earlier draft of this note gave
them one — `conversation_messages(job_id, seq, role, body, …)` — and it was wrong: every message
already arrives as an event, `events.seq` already orders them, and the log is already append-only
by trigger. A table beside it would be a second copy of the same facts, kept in step by hand, and
the first time the two disagreed there would be no way to say which was the conversation.

So `Conversations.messages/1` folds `Events.for_job/1`:

| Event | Becomes |
|---|---|
| `chat.message` | a user message |
| `job.harness.delivered` | that message's state, once the harness has taken it (§ The wire) |
| `job.harness.text` | assistant text, appended within the current turn |
| `chat.turn` | the turn boundary, closing the reply and numbering it; the event also carries the turn's commit and `cost_usd` |

`chat.turn` is written by the platform when it records the turn (§ Spend). `job.harness.finished`
also arrives once a turn and is not the boundary. Tool calls and the rest of the harness stream
stay in the log beside them, unprojected — a conversation is what a person said and what they
were told, and the rest is available without being in the way.

## What it asks for

A conversation is the one job kind with nothing to declare: `resources` is a workflow state's
grammar (`commands.md` § Resources) and a chat has no state, so it fell off the end of the
resolution chain onto the platform's default. That default is now an agent's figure rather than a
cold build's (`provisioning.md` § What a job asks for), and **the person opening the conversation
may say instead**.

- **Memory and cores, on the create view, both optional.** Blank is the platform's own figure,
  which is what the placeholder shows. Memory is parsed by `ForgeCore.Workflow.Resources`, so
  `4GiB` means here exactly what it means in a workflow and on the templates page.
- **A figure that is not one is refused where it was typed, never replaced.** Starting a
  conversation on the default because `2 gigs` did not parse is the silent substitution
  `CLAUDE.md` names: a guard that quietly succeeds is not a guard. The context refuses a
  non-positive number for the same reason, for callers that are not the form.
- **Fixed for the life of the process, like the model.** Both are read when the harness starts,
  so a conversation that wants different ones is one you end and open again. Changing them on a
  running conversation is possible — the slice is a systemd unit and systemd will change a live
  unit's `MemoryMax` — and is not built; what it would need is a gate check against the worker's
  remaining budget and a verb on the wire.

**This is what makes a small machine usable.** The figures are what `Provisioning.holds?/2`
compares against a template, so a conversation that will compile something says so before it is
placed, and one that will not is no longer refused by a 2 GiB machine for a number it never
needed.

## Context

**A project chat** gets a worktree of the project's default branch at its head, plus the
documents it has written itself at their latest versions, laid out the way a job's `inputs/` are.
It sees nothing about tickets. On a first start there are none; after a reopen they are what the
earlier process wrote, and without them that would be gone from its view: a reopen is a cold
start, and a cold start clears `out/` (`job-prompt.md` § Job directory). Its proposals are not
among them — they are backlog, and an open one is already in `tickets/index.md`. A ticket chat
never had this gap, because what it writes is the ticket's and comes back as the ticket's (below).
Either kind that wants to change a document it wrote writes it to `out/` again, which records a
new version (§ Commits).

**A ticket chat** gets a worktree of the ticket's branch at its head, plus every document on the
ticket at its latest version, laid out the way a job's `inputs/` are. That is more than any one of
the ticket's jobs is handed — a job gets the inputs its state declares, pinned when the job was
created — and it is the point: a conversation is for asking about, or fixing, the work in flight,
and it should not have to guess which document was the one that mattered.

**It also gets what already ran.** `history/<state>/<attempt>/` per workflow job of the ticket,
oldest first: `job.md` — what it was, what it declared, what the engine concluded, what it wrote,
what it cost — and `transcript.jsonl`, everything that job's agent did. Without it a conversation
about a ticket can see the code and the documents but not *why* any of it is the way it is, which
is most of what there is to ask about.

**The transcript is fetched by the worker, not inlined.** Each runs past a hundred kilobytes and
a ticket has several, so inlining would put a megabyte through the channel and into the prompt on
every turn, whether it is read or not. What crosses the channel is the store key and a token —
exactly what the seed does, and what the store is for. The prompt names the folder and says the
files are large; an agent with file tools reads when it has a reason to.

There is no per-job branch to give it: every job of a ticket commits to the ticket's branch, so
their work is already in the worktree it starts from.

**A conversation gets its own preamble**, and this was not optional. It was handed the job
preamble — "you are one job in a ticket lifecycle", write the declared outputs "and stop",
`outcome` must be one of the allowed outcomes, a non-blocking question states the assumption it
proceeded with — every line of which contradicts the chat manifest in the same prompt. A
conversation has no outcome, no declared outputs, no assumptions, and nothing to stop for.
Reusing the document was not economy; it was instructing the agent to be a job. `chat-preamble.md`
says where it is, how to reach its context, that questions here always wait, and that the
conversation is not its to end.

Context is composed once per process, when it starts, and is not refreshed while it runs; a
reopen composes it again (§ Lifetime). A conversation that has been open across a merge is
looking at what it started with, and says so.

## Commits

A conversation commits to **`chat/<id>`**, a branch namespace the `pre-receive` hook learns
beside `ticket/<number>`. The id is the job's.

**One commit per turn, and they accumulate.** A job commits once, at the end, because it has an
end; a conversation has none until a person says so, so each turn is committed as it completes —
the platform records the branch head the moment it hears about a turn, and work that is not on the
branch is work a lost machine takes with it.

That this accumulates rather than amends was measured, not read: `Checkout.squash/3` resets to
`origin/<branch>` before committing, which looks as though every turn would rewrite the last into
one squashed commit. Pushing moves that remote-tracking ref, so turn two is built on turn one. The
opposite reading is equally plausible from the code and would quietly lose each turn's history,
which is why it is written down here with the reason.

This keeps a conversation's work out of a ticket's branch, which matters most for a ticket chat:
the ticket's branch is written by its jobs, and a chat writing the same ref would race them and
muddy what the changeset means. A chat that wants its work on the ticket is a chat that produces
a branch you merge.

**A chat's branch merges from the chat's own page.** That page is shaped like a ticket's: the
conversation, and beside it the diff of `chat/<id>` against the default branch, with a merge
affordance. `Forge.Merge` learns to take a ref rather than only a ticket's approved changeset,
and merges it the way it merges everything — `merge-tree` in the object database, pushed by path
so the repository's own hooks run.

This is a second route into the default branch, which the `pre-receive` hook exists to keep
singular, so it is worth being exact: both routes are the platform's own merge, both are guarded
by the same hook with `FORGE_INTERNAL`, and neither lets a job write the default branch. What
differs is what authorises it — a ticket's approved changeset version, or an operator pressing
merge on a diff they are looking at. It is one implementation with two callers, not two: the
ticket's functions and the chat's both build the same plan — repository, destination, source, the
ref that keeps it reachable, and what the commit should say — and hand it to the same merge.

**What the chat's merge takes is the branch as it is when merge is pressed, not the diff the page
drew.** `Merge.perform_chat/2` resolves `chat/<id>` at the click. A conversation that is still
running pushes at the end of every turn, and the page redraws only once that turn is recorded —
so a push that lands between the page's last redraw and the tap, or on a page whose socket has
dropped, is merged without anybody having seen it. A ticket's merge has no such gap, because it
merges the exact commit a person approved and refuses if that commit is gone. Closing it would
mean the page sending the head it drew and the merge refusing any other; that is not built.

**The branch is deleted only after the pin exists**, and only when the merge succeeded.
`refs/forge/chat/<id>` is what keeps the merged commit reachable once `chat/<id>` is gone;
deleting first would leave it collectable in between, and "the branch is deleted when done" would
quietly mean the work was too. A merge that conflicted deletes nothing — there is nothing merged
for a pin to protect, and the branch is where the work still is. Closing a conversation deletes
its branch by the same two rules (§ Lifetime).

**Artifacts are chat-scoped when a chat has no ticket.** `artifacts.ticket_id` becomes nullable
and gains a `job_id` beside it, with exactly one of the two set: a ticket's artifacts are the
ticket's as they are today, and a chat's belong to the conversation. A ticket chat writes against
its ticket, because that is the work it is about.

**What a conversation writes is recorded every turn.** A conversation declares nothing, so every
file it leaves in `$FORGE_JOB/out/` other than `proposals/` is a document it means to keep. The
worker reads them after each turn's commit and sends them with the turn
(`ForgeWorker.Job.Dir.documents/1`) — every turn rather than at the end, for the reason proposals
go every turn: `out/` is not committed, and a conversation that goes idle or loses its machine
loses what is only there. `Conversations.record_turn/2` records each one as a version, in the
scope above: the ticket's for a ticket chat, the conversation's for a project chat. A proposal
stays a proposal, scoped to the job that wrote it whichever kind of chat that is
(`ticket-proposals.md` § Scope: the job, not the ticket).

They are held to a workflow job's output rules where those apply, and the rules have one
definition each, shared rather than copied:

- **A name the platform does not keep for itself.** A single path segment — the workflow
  validator's rule, now `ForgeCore.Workflow.valid_name?/1` for both — and none of `ticket`,
  `answers.md`, `changeset`, `proposals`, `proposal-*` or `transcript-*`
  (`Workflow.document_name_error/1`). The transcript prefix is reserved whole, not only the names
  already taken: a chat that wrote `transcript-refining-1.jsonl` before that job finished left the
  job unable to record its result — the name was a document by then — and the worker re-sending
  it for ever. The validator refuses a workflow producing one for the same reason.
- **The job's own regular file, and text, and no larger than a mebibyte.** The worker is a more
  privileged user than the agent, and the agent owns the job directory — every path under it,
  `out` itself included, is the agent's to rearrange. `lstat` on `out/<name>` was the first
  guard here and it was decorative: it checks the last component and follows every one before
  it, so `rm -rf out && ln -s /etc out` exported whatever root could read, proposals included.
  So `read_text/2` opens the file once and asks the *handle*: a regular file, owned by the job
  directory's owner — the job's fresh Unix user, which owns nothing outside it. `out` and
  `out/proposals` are listed only when `lstat` says they are directories. Text is UTF-8 with no
  NUL and at most `ForgeCore.Document.max_bytes/0` (`Document.text_error/1`), because anything
  else cannot cross the channel as JSON or sit in a text column — and a document that cannot is
  not refused on its own, it takes the whole message carrying it. A NUL a YAML escape makes in
  front matter is refused by the parse, for the same column. That was true of a workflow job's
  outputs and proposals as well, which is why every reader of `out/` goes through the same
  `read_text/2`.
- **A document that parses**, by `ForgeCore.Document.parse/1` with the workflow's rules; and on
  a ticket, a name that is not already something other than a document — a blob, the
  changeset — whose kind a document version would contradict.
- **On a ticket, not a document a person's decision is waiting on.** Two of a ticket's documents
  are held that way, and a version the chat wrote over either changed the decision without the
  person seeing it:
  - **One carrying an open blocking question while a job of the ticket waits** — the two facts
    `Operator.answer/4` resumes on, asked of the same two functions (`Jobs.waiting_job/1`,
    `Artifacts.open_blocking_questions/1`). A question counts only on the latest version of its
    document, so a chat that rewrote `plan.md` without the block closed it: the job stayed
    `:waiting` with nothing open and nothing in the queue, `Engine.choose/4` refuses while a job
    is live, and nothing could resume it.
  - **One the ticket's pending transition is waiting to approve** (`Engine.awaiting_approval/1`).
    `Engine.decide/4` approves the latest version of each, so the approval attached to the
    chat's version, which the operator never saw.

  The file stays in `out/`, is re-reported every turn, and is written on the first turn after the
  question is answered or the approval decided — as any change the conversation makes to the
  ticket is, and the person has had their decision first. Asked before the turn's transaction like
  every check here, so a job that stops on its question in the moment between the two is not
  seen; the window is one turn's recording.

The worker checks the first two, so a file that can never be recorded is not sent every turn.
The platform checks all of them again: the wire is not a guard, and any of them failing inside
the turn's transaction would take the turn — its cost, its commit, its proposals — down with it,
and the worker re-sends a turn until it is acked. A file that fails is not recorded. Its reason
is on that turn's `chat.turn` event, as `refused_documents`, and the page lists it beside what
the conversation wrote, so a document that did not arrive is visible rather than merely absent.

**Idempotent by content, against what this conversation last wrote of that name.** `out/`
accumulates, so every turn re-reports every file, and a version is written only when the file
differs from the latest version *this conversation* wrote under that name. Not from the
artifact's latest: on a ticket that may be a job's or a person's since, and comparing against it
would write the conversation's stale copy back over the newer version every turn.

A version a ticket chat writes is the ticket's like any other, and **what reads it is what reads
any version on the ticket.** A job is handed the inputs its state declares, pinned when the job is
created (`core/priv/platform.md` § Artifacts and versions), and a state may declare only a name
some earlier state produces — so a chat's `plan.md` reaches the next job created in a state that
lists `plan.md`, a job already created keeps the version it was pinned to, and a `notes.md` no
state produces reaches no job at all. What reads every latest document is the next conversation
about the ticket (§ Context). An approval attaches to it if it is the latest version when the
approval is given, which is why one the pending transition is waiting on is refused above.

**Its questions are not questions.** A conversation's document is recorded the way a proposal is,
without extracting its `question` blocks (`parse: false`, with the front matter the check above
already parsed kept as the version's `meta`). A conversation asks in its reply, where the person
is (§ Asking a question); a block in a document it wrote used to become a blocking question on
the ticket, which then held a waiting job on something no one had been asked. The block is still
checked — it is part of what the parse refuses — and is otherwise text. What it cannot help doing
is replace: a question counts on the latest version only, so a chat's version of a document
closes the questions of the version before. An assumption dropped that way is dropped as a
person's edit drops one; a blocking question a job waits on is the case refused above.

## Lifetime

- **A chat holds its slice while it lives.** First come, first served: a pending job waits for a
  free slice like any other, and a conversation is not evicted to make room. This is the same
  rule a job parked on a blocking question already follows, and its failure mode is the same and
  worse — a conversation nobody closed stalls the queue until it times out. The idle timeout is
  what bounds it, so the timeout is not a nicety.
- **Idle is measured from the last human message.** When it fires, the harness process ends and
  the machine is released. The conversation is not over: its messages persist in the event log
  and it can be reopened.
- **Reopening is cold.** The machine is gone, so a new process starts with the conversation so
  far replayed as context — what was said, which is the projection and not the harness's
  transcript (below) — rather than `--resume`, which cannot find a session whose worktree no
  longer exists (`docs/design/claude-code-events.md` § Resume). If the same worker still holds
  the worktree, resuming warm is an optimisation and never a guarantee — and **the warm resume
  is not built.**

  **The replay is the projection, split at the agent's last reply.** `Conversations.opening/1`
  runs when a conversation is assigned. Everything up to the last assistant message in
  `messages/1` is the conversation so far — what the person said and what they were told —
  rendered oldest first into the spec's `replay`, which the worker writes read-only to
  `$FORGE_JOB/conversation.md` and the chat manifest names: this conversation was reopened, read
  that before you reply, it ends with your last reply, and the message at the end of this prompt
  is the next thing the person said, not the first. What the person said *after* the last reply
  is the spec's `prompt`. A conversation that has never been answered has no replay and its
  whole opening is the prompt, which is exactly a first start; so one rule covers both, and
  messages sent while a conversation waited for a machine — pushed to nobody before this — are
  answered rather than lost.

  It is the projection and not the harness's transcript because the projection is what was said.
  The transcript is every tool call as well, and it is not on the platform to replay from: the
  worker uploads it when the conversation ends, and `Conversations.ended/3` is passed only the
  commit and the reason, so no version records it.

  **Nothing waiting means nothing sent.** It used to be the first `chat.message` and no other
  (`opening_prompt/1` in `Forge.Jobs`), so a reopened conversation began by answering its opening
  message a second time, as though new, knowing nothing said after it — a billed turn nobody
  asked for, and a reply appearing on the page to a question from an hour ago. Now a reopen
  whose last word was the agent's has a spec with no prompt, and the worker holds the composed
  prompt — preamble, manifest, the pointer to the replay — until the person's next message,
  then sends the two as one message (`ForgeWorker.Job.Runner`'s `:hold_prompt`). The context
  and the question arrive in the same turn, and it is a turn somebody asked for. Sending the
  context on its own would have bought a turn in which the agent acknowledges having read
  something.

  **A file and not the prompt**, for the reason `history/` is one: it is read with the agent's
  own tools, and a long conversation does not become one enormous first message. It is not
  optional reading the way `history/` is, which is why the manifest says to read it first rather
  than when there is a reason to.

  What the split cannot see, stated so that it is not discovered: a turn that said nothing
  leaves the message before it looking unanswered, and it is answered again; and a message
  queued mid-turn that the process never took reads as answered, because the projection draws
  the rest of that turn's reply after it. Both need the process to have died at the wrong
  moment, and in both the person is there to say what was lost — § Lifetime's rule for a lost
  machine.

  Two more, narrower, and at every assignment rather than only a reopen. `Jobs.assign/2` marks
  the row running on its worker, then composes the opening, then pushes the assignment; `send/3`
  records a message, then pushes it to whichever worker the row names when it looks. So a message
  recorded before the opening is composed and pushed once the row names the worker is in the
  prompt, and — if its push reaches the worker after the assignment — is delivered again as a
  message: answered twice. And a message recorded after the opening is composed whose push
  overtakes the assignment reaches a worker with no such conversation, which logs it and drops
  it: it is in the log and was never in the prompt, so nothing answers it. Each window is the
  length of one assignment. Closing them wants sends held from the moment the row is marked until
  the worker has the job; that is not built.
- **Losing the worker mid-conversation loses uncommitted work**, and that is accepted. The
  process dies with its machine and the session with it; reopening is the same cold start as
  after a timeout. A workflow job is re-queued because nothing is watching it and its spec is
  enough to run it again — a conversation has a person in it, who can say what was lost. It is
  the exception, and the sweeps that make it happen are minutes long.
- **A conversation goes dormant, it is never re-queued.** `Jobs.recover/0` and
  `Workers.sweep_unreachable/0` put a running job back in the queue, which for a chat would mean
  every platform restart silently starting conversations nobody is in — each taking a slice and
  spending the day's allowance on a greeting. A chat goes `:hibernated` instead, which already
  means "stopped without an outcome" and is already excluded from `Workers.promised/1`. It shows
  as interrupted and waits for a person.
- **A conversation that is not live refuses a message; it does not record one.** `send/3` reads
  the status from the row — not from the caller's struct, which a page rendered minutes ago — and
  answers `{:error, :not_live}` without writing. Recording it would put a message in the
  transcript that was never delivered and never will be: the silent drop `docs/poc-plan.md`
  § Definition of usable rules out, wearing the transcript's authority.

  **Every affordance that sends is gone at the same moment**, and that is one rule rather than
  two. The send box was already swapped for Reopen; the one-tap answer rows were not, and an
  answer row *is* a send button — a real conversation on the dev node was tapped after it had
  stopped, and the tap was recorded and lost. `Conversations.live?/1` is the single definition
  the page, the queue and `send/3` all read, because a surface offering what the context then
  refuses is the trap `CLAUDE.md` names: a guard must use the same model as the operation it
  guards. What the reply *asked* stays legible either way — it is in the transcript, which is
  where it was said.
- **Reopening refuses a live conversation, and ending refuses one that is not.** The same line,
  asked the same way: the status read from the row, not the caller's struct, and `live?/1`.
  The page draws Reopen only on one side of it and End only on the other, but an event is
  anything the socket sends. A `reopen` on a running conversation set it `:pending` and cleared
  its `worker_id`, so every turn its worker then reported was refused by the channel's ownership
  check for ever, and the scheduler placed the conversation a second time. A close on one that
  had stopped either went to a machine no longer running it, or — with no worker on the row —
  recorded a second ending and dealt with the branch of a conversation that was already dormant,
  a decision nobody took. `reopen/1` answers `{:error, :live}` and `close/2`
  `{:error, :not_live}`, through `Forge.Operator` as everything a person does, and the page says
  so rather than acting.

  **Whether a close has anyone to tell is the status too, not the worker.** `close/2` asks the
  worker to end a `:running` conversation and records the ending itself for a `:pending` one. It
  used to ask whether the row named a worker, and a conversation can be `:pending` and still name
  one: `Jobs.assign/2` puts a row back to `:pending` when the assignment cannot be pushed, and
  leaves the worker it chose. Ending that one sent `close` to a machine that never had it, and the
  row stayed pending.
- **Ending one is something the platform can do alone.** `live?/1` counts `:pending`, so a
  conversation waiting for a worker is one every surface offers to end — and every other message
  to a conversation is a push, which for a chat with no `worker_id` logs that it was not
  delivered and returns `:ok`. Closing through that path left the row pending for ever with
  nothing said: on a running node, three conversations the gate could never place could also
  never be got rid of. So `close/2` records the ending itself when there is nobody to tell,
  which is what the worker's report would have caused anyway.
- **A conversation waiting for a machine says why.** A chat sticks nothing
  (`docs/design/provisioning.md` § The gate), so one that no template can hold, or one queued
  behind a full template or the daily cap, sat pending with nothing on its page but the status.
  The scheduler records the reason as a `job.waiting` event when it changes, and the page draws
  the latest where the reply will appear. It is not in the queue: a conversation is queued once
  the agent has replied and the next word is yours, and one that has not started has said
  nothing — which leaves the three template answers, where a person *is* being waited on,
  reachable only by opening the page.
- **Kept for ever. The branch is deleted, the conversation is not.** An earlier draft said
  deleted after 30 days; that was reconsidered, and it was also not possible — `events` carries a
  `BEFORE UPDATE OR DELETE` trigger (`20260911201847_create_events.exs`) and `events.job_id` is
  `on_delete: :restrict`, so deleting a conversation means deleting from an append-only log. What
  is reclaimed is what is actually large and actually dead: `chat/<id>` is deleted once its work
  is merged, by `Merge.perform_chat/2` after the pin exists (§ Commits), or abandoned (below). A
  conversation is text, and text is not what fills a disk.
- **Closing is abandoning, and the branch is dealt with when the ending is recorded.** `close/2`
  is how a person says they are done with a conversation — *End it* on the page, *End* on the
  chats list, and `mix forge.chat close` from a terminal, which asks nothing first and warns in
  its own documentation instead — so it is the abandon. Going idle, losing a machine and a
  platform restart are not a person deciding anything, and they keep the branch. The decision is
  made in `ended/3` for the reason `closed`, after the credential is revoked, and not when the
  person asks: a conversation with a machine finishes its last turn and pushes it before the
  worker reports, so deleting at the request would delete a branch the worker is about to push
  to, and the push would put it back. `Merge.abandon_chat/1` then does one of four things:

  | The branch, when the ending is recorded | What happens |
  |---|---|
  | its head is on the default branch | pinned at `refs/forge/chat/<id>`, then deleted — § Commits' order, for its reason |
  | unmerged, and it would merge cleanly | deleted, with nothing pinned: its commits become collectable |
  | it would not merge cleanly | kept |
  | already gone | nothing |

  The second row is the abandon, and the only thing here that reclaims what a merge did not. The
  person had a merge that worked, on the same page, and ended the conversation instead; the
  confirm on both pages says the branch goes, the page's own copy beside *End it* says it from
  the same definition, `mix forge.chat close` says it in its documentation, and the chat
  preamble tells the agent that what is not merged by then is discarded. The third row is
  § Commits' conflict rule applied to an ending: the branch is where the work still is, and the
  page's own advice for a conflict — take the change by hand — needs it. It asks the merge's own
  question (`merge-tree` in the object database, as `check_chat/1` does) rather than looking for
  a record that a merge once failed, because a guard must use the model of the operation it
  guards; a branch that would conflict and that nobody tried to merge is kept for the same
  reason. Each outcome is an event — `chat.branch_deleted` or `chat.branch_kept`, with the head —
  so the sha of discarded work is in the log for as long as the object database still holds it.

  **Closing is not terminal.** Every conversation that is not live can be reopened, a closed one
  included, so closing ends the branch and not the conversation. A reopen whose branch is gone
  makes it again where opening would — the default branch, or the ticket's, as it stands now —
  in the same transaction as the reopen, as `open/3` does, because a worker handed a branch that
  does not exist refuses the conversation minutes later. That also repairs a conversation merged
  and then reopened, whose branch `perform_chat/2` had deleted and which the worker used to
  refuse. `chat.reopened` says which (`kept` or `recreated`), the page says so beside Reopen,
  and the replay's manifest tells the new process that its checkout may not hold what the earlier
  replies describe (§ Lifetime, above).

  Two things this leaves, stated. A close asked for whose worker is lost before it reports is
  swept as a lost machine, and keeps its branch — the person's decision never reached `ended/3`.
  And a pin written by a merge that conflicted (`perform_chat/2` pins before it tries) is not
  removed by a later abandon, so the commit it names stays reachable.

## Spend

**A conversation has no ceiling of its own.** The idle timeout bounds how long it lives and the
daily cap bounds what the node may spend; nothing bounds one conversation's share of that day.

This is the deliberate opposite of a job, which carries `budget.turns` and `budget.cost` from its
state, and it follows from what a conversation is: a person is at the keyboard, and the thing
that stops it is that they stop typing. A runaway chat is a chat you are having.

Its spend counts toward the daily cap like any job's, so a conversation that consumes the day's
allowance pauses the node — `docs/design/capacity.md` § Spend caps, and § Four exhaustions,
three treatments, where a pause is resolved by the clock and keeps the ticket out of the queue.
That is the backstop, and it is the only one.

**For that backstop to exist at all, spend is recorded per turn.** Today it is recorded when a job
ends, and a conversation does not end for hours — so `Spend.day_total/1` would read a live
conversation as having cost nothing, and the only spend protection the product has would not apply
to the one thing that can run unattended all day. Each turn writes its cost to its run as it
completes — the job row's cost is the sum of its runs, so a reopened conversation, a new process
whose total starts again, adds to what it had rather than replacing it (`credentials.md` § Spend).

**The harness's ceiling is set once, not per turn.** What is left of the day is read when the
conversation is assigned — `remaining_today/0`, in `Jobs.assignment/4` — and passed as
`--max-budget-usd` when the process starts, or not at all when the day has no cap. It is not
refreshed as the day's spend moves: money spent elsewhere on the node after the conversation
started does not lower it, and a reopen is what reads it again. The cap is therefore enforced
twice: by the harness, at the figure it started with, and by the node, which assigns nothing once
the day is gone. Whether the harness measures its ceiling per turn or across the session has not
been measured; `bin/measure streaming` does not pass the flag.

**Cost is set on the run, and added across runs; turns are added.** The spike measured
`total_cost_usd` as cumulative across the session and `num_turns` as per turn.
`Jobs.progress_attrs/2` adds both, so recording a turn's `total_cost_usd` the way a job's is
recorded would count turn one's cost in every later turn — by turn five a conversation reports
several times what it spent, and the daily cap trips early on money nobody spent. This is written
down here because it is invisible: the number is plausible, monotonic, and wrong.

**A reopen is a new session, and its turns are its own.** The worker numbers turns from one in
every process. With `chat.turn` keyed on `(job, turn)` alone, a reopened conversation's turns
read as re-sends of the first session's and were dropped — commit, proposals and push with them.
`Conversations.record_turn/2` keys a turn on `(job, session, turn)`; what each process spent is
its run's (`Forge.Jobs.Runs`), which is what keeps a reopen from erasing the earlier spend.

## Turns

**A message sent while a turn is in flight queues, and can be forced.** Sending normally holds
the message and delivers it when the turn ends: nothing is lost and nothing is half-answered.
Beside it, a **force** that interrupts — it stops the turn where it is, keeps the partial reply,
and sends immediately. And a plain **Stop**, which ends the turn without sending anything.

Three controls rather than one because they are three intentions, and guessing between them from
one gesture is how a chat client loses a message. Queueing is the default because it is the one
that cannot cost anything; forcing is deliberate because the tokens already spent on the
interrupted turn are spent.

**The harness does the queueing itself**, which the spike established: a message written to stdin
mid-turn is held and delivered as its own turn once the current one ends, and `--replay-user-messages`
echoes it *at that moment* rather than on receipt. So the worker does not need a queue — it writes
the message and watches for the echo. What the platform owes the operator is the *state*: a message
that has been sent but not yet taken says so, and stops saying so when the echo arrives. That is
`chat.message` followed by `job.harness.delivered` carrying the message's id (§ The wire), and it
is two events rather than one row updated because the log cannot be updated.

**An interrupted turn is indistinguishable from a failed one**, which is the trap in force and
Stop. The spike measured it: a turn cut by a `control_request` reports
`subtype: "error_during_execution"`, `is_error: true` and a null result — exactly what a genuine
execution error reports. Only the worker knows it was asked to interrupt, so the worker labels it.
A conversation that renders an operator's own Stop as an error is the failure mode, and it is the
default one.

Interrupting is a `control_request` written to the same stdin, not the channel's `cancel`: `cancel`
ends the process, and for a conversation the process is the thing being kept.

## The wire

Four additions to `docs/design/worker-channel.md` § Messages. Nothing that exists changes.

| New | Direction | Acked | Meaning |
|---|---|---|---|
| `message` | → worker | — | a user message, written to the harness's stdin |
| `interrupt` | → worker | — | end this turn, keep the process |
| `close` | → worker | — | end the conversation, release the machine |
| `turn` | → platform | **yes** | a turn ended: its index, its cost, the commit it made, and the proposals and documents in `out/` (§ Commits) |

`turn` is acked because it carries the cost, and the cost is what the daily cap is computed from —
the one class of message § Delivery says must not be lost.

**Delivery is an event, not a sixth message.** An earlier draft added `message_delivered` to the
wire; it does not need to be there. The harness's echo already reaches the runner as an ordinary
harness event, and events already flow to the platform per event, unacked — which is exactly the
delivery guarantee an affordance like this wants. So delivery arrives as `job.harness.delivered`
with the message's id attached, and the wire grows four messages rather than five.

The id is attached by the worker because the harness cannot attach it: the echo carries the text
and nothing else. The conversation process keeps the ids of messages it has written and not yet
seen taken, oldest first, and the harness takes them in that order. The prompt is the first of
them, which is why the first echo is not reported as anyone's message being delivered — except
when a reopen holds it (§ Lifetime): then it rides inside the person's first message, and that
echo is the message's delivery.

**A conversation breaks the unacked map's key.** `ForgeWorker.Link` keyed unacked messages by
`{job_id, message}`, which is sound when a job sends exactly one terminal message. A conversation
sends a `turn` per turn, so two unacked `turn`s for one chat would collide and one would be dropped
for ever — taking its cost with it. So the key is the caller's: `send_acked/4` takes it,
`send_terminal/4` passes `{job_id, message}`, and a turn passes `{job_id, "turn", index}`.

`close` exists because stdin EOF is enough to end the process cleanly — the spike measured that —
so closing a conversation is closing the pipe, not killing anything.

## In the queue, and on the phone

**A conversation waiting on a human appears in the queue**, as its own kind, with the project or
ticket it belongs to. It is literally what the queue is for: something that will not move until a
person acts.

**Every completed reply pushes.** Not every token — a turn ending is the event. This is where
`decisions.md`'s push rule first widened past blocking questions, and it now names a
conversation's reply among everything that starts waiting on a human: a reply to a question you
asked is the same shape of thing as an answer you are owed, and the product's premise is that you
asked it from a train platform.

The cost of both together, stated so that it is visible rather than discovered: a conversation
you are in the middle of is an item in your inbox and a notification on your phone, and the
queue's promise that you can reach the end and be done now includes conversations you have not
finished having. If that turns out to be wrong it is these two decisions to revisit, not the
queue's discipline.

## Isolation

A conversation runs exactly as a job does — one transient systemd unit, one Unix user, one
worktree, `MemoryMax` and the rest — and differs only in how long it lasts. No second isolation
model, and the idle timeout is what bounds the duration the existing one was not designed for.
The user and the worktree are torn down when the process ends, as they are for a job.

## Asking a question

A conversation can ask, and it reuses the parser it already has. `ForgeCore.Document.parse/1`
extracts fenced `question` blocks from a body, and a message *is* a body — so an agent that wants
a structured answer writes the same block it would write into a document, and the platform renders
an answer row beneath the message: the options as one-tap buttons, plus free text, which is always
valid.

**`blocking` means nothing here, and the note says so rather than leaving it to be discovered.**
In a workflow a blocking question is what stops a job; in a conversation the turn has ended
anyway and the agent is waiting regardless. Every chat question is "blocking" because every chat
turn is. The flag is ignored for chats — `Document.parse(text, blocking: :always)`.

That option had to exist, and the reason is worth recording because "ignored" was not enough.
The parser requires an `assumption` on any non-blocking question — what the job proceeded with
instead — and a conversation has no instead. Without the option the rule does not merely mislead:
one question written without an assumption fails the parse of the **whole message**, so the
question disappears rather than being shown without its one-tap answers, and the reply reads as
though the agent asked nothing.

**The answer is a message, not an `answers` row.** Answering sends the chosen option — or what
you typed — as the next user message, so the agent sees it exactly where it expects to. Nothing
is written to `questions` or `answers`, because those hang off an artifact version and a message
is not one, and because **the transcript is already the record**: the question and the answer are
both in it, in order, with times. A second record would be a second truth.

What the block buys, then, is the affordance and nothing else: tapping an option instead of
typing it. That is worth having — it is the difference between answering from a phone and not —
and it is worth being clear that it is all it is.

The queue renders it too. A conversation waiting on you with a question in its last message gets
the same answer row the queue already draws for a job's blocking question, so a chat question can
be answered without opening the conversation.

## The page

A conversation's page is shaped like a ticket's, because it is the same kind of thing: work with
a branch, a cost and a record. The conversation is its Talk tab; the diff of `chat/<id>` against
the default branch, its commits and the merge affordance are Changes; what it has written —
rendered, every version a link to itself (`docs/design/ui.md` § Addressable artifact versions),
and what the last turn wrote that was not recorded, with why (§ Commits) — is Docs; what it has
spent is the rail. Its reply and its tool calls stream — see `docs/design/ui.md` § Motion and
structure, which used to forbid that and no longer does.

**The page is a work screen** (`docs/design/ui.md` § The work screen): tabs for Talk, Changes,
Docs and Activity, a composer that never leaves the viewport, and the rail as a sheet on a phone.
Two things it adds are this note's to state:

- **A transcript turn carries what the agent did, not only what it said.** The fold that builds
  the transcript from the event log used to keep four event types and drop the rest, and joined a
  turn's text blocks with nothing between them — so a turn was one run-on message in which the
  sentence before a tool call ran into the one after it. It now keeps the turn as a sequence:
  each text block as its own item, and each `tool_use` paired with its `tool_result` between
  them, in event order. The page draws that sequence (`docs/design/ui.md` § Talk). Nothing new is
  recorded; what was already recorded stops being thrown away on the way to the page. Notices and
  the other harness bookkeeping stay out of the transcript, and in the Activity tab behind their
  count. A subagent's calls fold under the `Task` that made them (`parent_tool_use_id`), and a
  subagent's text is not the agent's reply. A result pairs with its call by id wherever the call
  is, and a message sent mid-turn — recorded at once, and drawn where it was sent — splits the
  reply on the page without splitting the turn: the turn's end closes both halves. A new process
  closes a reply the last one was cut off in. The agent wrote every tool input, so a field in the
  wrong type is read as absent rather than trusted.

  **What was said and what was done are two readings of it.** `Conversations.transcript/1` is the
  whole sequence and is what the page draws, including a turn that has so far only acted — which
  is what a live line is. `Conversations.messages/1` is the same fold without the turns that said
  nothing, because its readers — the queue, the replay a reopened process reads, the reply push —
  are asking what was *said*: a turn that only acted is not a reply to wait on or to replay. Its
  `text` is the turn's text blocks with a blank line between each, where it used to be the blocks
  run together.
- **The conversation's job is read on its own page, not the job page's.** The job page is a
  workflow job's, reached from a ticket's timeline; a conversation's events are its Activity tab.

## Open

Nothing, now. What was open is above, decided. The first thing to disagree with a decision here
should change this note before it changes the code.
