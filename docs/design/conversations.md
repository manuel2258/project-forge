# Conversations

A conversation is an agent you can talk to, in a project's or a ticket's context, that can commit
and write artifacts like any job. It is the "meta job" — work that does not fit a workflow state,
done by talking rather than by declaring an outcome.

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

`project_id` is new because `jobs` does not have one: every job reaches its project through its
ticket (`jobs.ex:174`). A project chat has no ticket, so without it there is nothing to clone,
nothing to issue a token against, and no project to schedule it for. A CHECK constraint keeps the
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
| `job.harness.finished` | the turn boundary, carrying its cost |

Tool calls and the rest of the harness stream stay in the log beside them, unprojected — a
conversation is what a person said and what they were told, and the rest is available without
being in the way.

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

**A project chat** gets a worktree of the project's default branch at its head. It sees the
repository and nothing about tickets.

**A ticket chat** gets a worktree of the ticket's branch at its head, plus the ticket's artifacts
at their latest versions, laid out the way a job's `inputs/` are. It is the same context the
ticket's next job would get, which is the point: it is for asking about, or fixing, the work in
flight.

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

Context is composed once, at the first turn, and is not refreshed. A conversation that has been
open across a merge is looking at what it started with, and says so.

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

**The branch is deleted only after the pin exists**, and only when the merge succeeded.
`refs/forge/chat/<id>` is what keeps the merged commit reachable once `chat/<id>` is gone;
deleting first would leave it collectable in between, and "the branch is deleted when done" would
quietly mean the work was too. A merge that conflicted deletes nothing — there is nothing merged
for a pin to protect, and the branch is where the work still is.

**Artifacts are chat-scoped when a chat has no ticket.** `artifacts.ticket_id` becomes nullable
and gains a `job_id` beside it, with exactly one of the two set: a ticket's artifacts are the
ticket's as they are today, and a chat's belong to the conversation. A ticket chat writes against
its ticket, because that is the work it is about.

## Lifetime

- **A chat holds its slice while it lives.** First come, first served: a pending job waits for a
  free slice like any other, and a conversation is not evicted to make room. This is the same
  rule a job parked on a blocking question already follows, and its failure mode is the same and
  worse — a conversation nobody closed stalls the queue until it times out. The idle timeout is
  what bounds it, so the timeout is not a nicety.
- **Idle is measured from the last human message.** When it fires, the harness process ends and
  the machine is released. The conversation is not over: its transcript and messages persist and
  it can be reopened.
- **Reopening is cold.** The machine is gone, so a new process starts with the transcript
  replayed as context rather than `--resume`, which cannot find a session whose worktree no
  longer exists (`docs/design/claude-code-events.md` § Resume). If the same worker still holds
  the worktree, resuming warm is an optimisation and never a guarantee.
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
- **Ending one is something the platform can do alone.** `live?/1` counts `:pending`, so a
  conversation waiting for a worker is one every surface offers to end — and every other message
  to a conversation is a push, which for a chat with no `worker_id` logs that it was not
  delivered and returns `:ok`. Closing through that path left the row pending for ever with
  nothing said: on a running node, three conversations the gate could never place could also
  never be got rid of. So `close/2` records the ending itself when there is nobody to tell,
  which is what the worker's report would have caused anyway.
- **Kept for ever. The branch is deleted, the conversation is not.** An earlier draft said
  deleted after 30 days; that was reconsidered, and it was also not possible — `events` carries a
  `BEFORE UPDATE OR DELETE` trigger (`20260911201847_create_events.exs`) and `events.job_id` is
  `on_delete: :restrict`, so deleting a conversation means deleting from an append-only log. What
  is reclaimed is what is actually large and actually dead: `chat/<id>` is deleted once its work
  is merged or abandoned. A conversation is text, and text is not what fills a disk.

## Spend

**A conversation has no ceiling of its own.** The idle timeout bounds how long it lives and the
daily cap bounds what the node may spend; nothing bounds one conversation's share of that day.

This is the deliberate opposite of a job, which carries `budget.turns` and `budget.cost` from its
state, and it follows from what a conversation is: a person is at the keyboard, and the thing
that stops it is that they stop typing. A runaway chat is a chat you are having.

Its spend counts toward the daily cap like any job's, so a conversation that consumes the day's
allowance pauses the node — `docs/design/capacity.md` § Spend, where a pause is resolved by the
clock and keeps the ticket out of the queue. That is the backstop, and it is the only one.

**For that backstop to exist at all, spend is recorded per turn.** Today it is recorded when a job
ends, and a conversation does not end for hours — so `Spend.day_total/1` would read a live
conversation as having cost nothing, and the only spend protection the product has would not apply
to the one thing that can run unattended all day. Each turn writes its cost to its run as it
completes — the job row's cost is the sum of its runs, so a reopened conversation, a new process
whose total starts again, adds to what it had rather than replacing it (`credentials.md` § Spend)
— and each turn is invoked with `--max-budget-usd` set to what is left of the day. The
cap is therefore enforced twice: by the harness, per turn, and by the node when the day is gone.

**Cost is set, not added; turns are added.** The spike measured `total_cost_usd` as cumulative
across the session and `num_turns` as per turn. `progress_attrs/2` (`jobs.ex:551`) adds both, so
recording a turn's `total_cost_usd` the way a job's is recorded would count turn one's cost in
every later turn — by turn five a conversation reports several times what it spent, and the daily
cap trips early on money nobody spent. This is written down here because it is invisible: the
number is plausible, monotonic, and wrong.

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
`chat.message` followed by `chat.message_delivered`, and it is two events rather than one row
updated because the log cannot be updated.

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
| `turn` | → platform | **yes** | a turn ended: its index, its cost, the commit it made |

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
them, which is why the first echo is not reported as anyone's message being delivered.

**A conversation breaks the unacked map's key.** `Link.send_terminal/4` (`link.ex:413`) keys
unacked messages by `{job_id, message}`, which is sound when a job sends exactly one terminal
message. A conversation sends a `turn` per turn, so two unacked `turn`s for one chat would collide
and one would be dropped for ever — taking its cost with it. The key gains the turn index.

`close` exists because stdin EOF is enough to end the process cleanly — the spike measured that —
so closing a conversation is closing the pipe, not killing anything.

## In the queue, and on the phone

**A conversation waiting on a human appears in the queue**, as its own kind, with the project or
ticket it belongs to. It is literally what the queue is for: something that will not move until a
person acts.

**Every completed reply pushes.** Not every token — a turn ending is the event. This is a
deliberate widening of `decisions.md`'s "push notification for blocking questions; everything
else digested": a reply to a question you asked is the same shape of thing as an answer you are
owed, and the product's premise is that you asked it from a train platform.

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
a branch, a cost and a record. The conversation on one side; on the other the diff of
`chat/<id>` against the default branch, what it has written, what it has spent, and the merge
affordance. Its reply streams — see `docs/design/ui.md` § Motion and structure, which used to
forbid that and no longer does.

## Open

Nothing, now. What was open is above, decided. The first thing to disagree with a decision here
should change this note before it changes the code.
