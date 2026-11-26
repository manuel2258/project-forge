# Outside work (ticket 79)

The standard for work on a ticket done **outside forge's machines** — on a person's own PC, by them or
by an agent they run there — and for what forge does with it. Code follows this note; a change of
mind updates it first.

## The idea

A person, or an agent with a project token, can **take over** an open ticket, push to its branch
with the project's ordinary git token, and **hand it back** to a step of their choosing. What was
pushed becomes the ticket's recorded change, and every later job is told. The same operations
open a ticket that is **already taken over** (outside work), so work can start on the PC too.

## Take-over: a hold with a name

`Forge.Engine.take_over/3` is `hold/2` that also writes who. A taken-over ticket is a held ticket
(`workflow-grammar-v1.md` § Holding a ticket): nothing starts, the engine takes no transition, the
merge queue skips it. `tickets.takeover_id` names the open row of `ticket_takeovers`, and a check
makes `takeover_id` imply `held_at`. One open take-over per ticket (a partial unique index), and
the refusal names who and since when, **the same person included**.

- Any open ticket, active or stuck, in any state of any type. Done and cancelled are refused
  (`{:not_holdable, status}`). An ordinary hold keeps its `held_at` and gains the name.
- **A run going asks for a choice**, every time: `running: :stop` cancels it as *Stop now* does
  (the state runs again on a hand-back to it), `running: :finish` leaves it and its outcome waits as
  for any hold. Without the choice `{:error, :running_choice}` and nothing is written; with no run
  going the choice is ignored. A job that is live but not running — made and not yet placed, or
  parked on a question — is withdrawn either way, because a hand-back to another step is refused
  while one is live (`Engine.no_live_job/1`) and the state runs again on a hand-back to it.
- `Forge.Tickets.started?/1` **counts a take-over as a start**, so a release never re-pins a
  taken-over ticket at the default branch's head and moves its branch under the pushes.
- A taken-over ticket is not locked in git: any token that may push the branch today still may.
  The hold says who is working, it is not an access rule.

The row records who (a person or a token, as an approval's author is), through which door (`page`,
`api` or `mcp`), the state and the branch head then. `ticket.taken_over` is logged with the actor.

## Hand-back

`Forge.Engine.hand_back/3` (`to`, default the state it rests in; `note`; `via`), in two phases:

1. **What was pushed is recorded, in a transaction of its own.** When `ticket/N` differs from the
   commit of the latest `changeset` version — or, with none, from the base — it is written as a new
   `changeset` version authored by whoever hands back, and the base follows as it does for a job's
   result (`Forge.Jobs.put_base/5`). It goes first so every later check reads it: the merge check,
   the approval an edge or a merging jump records, the pending approval. **A hand-back refused after
   it leaves that version recorded and the ticket taken over**; a second try records nothing new.
2. **The take-over is closed and the move made, in one transaction**: the row's hand-back half
   (who, door, step, note, head, `commits`, the version), the hold cleared, `ticket.handed_back`
   logged, and then —
   - another step: `Engine.choose/4`, the declared transition when one leads there and a jump
     otherwise, with the refusals each has (a step whose job needs a document with no version is
     refused; the documents can be written first). A refusal rolls the whole of it back.
   - the same step of a stuck ticket that `retryable?/1` accepts: `retry/3`.
   - the same step otherwise: the hold is released as `release/2` releases it, replaying what waited.

`commits` is `git log F..head`, at most 20 `{sha, subject}` and a `more` count, where `F` is the
latest changeset's commit **when a job recorded it** and it descends from the head the take-over saw
(a job let finish is not counted as the person's), and that head otherwise. A version a hand-back
itself wrote, refused afterwards and tried again, is not a job's, so the retry counts the commits
again from the take-over's head.

**Releasing a taken-over ticket is a hand-back** to the step it rests in with no note
(`Engine.release/3` delegates). Any member of the project, or a token that may write, may hand
back, whoever took it over.

The note is at most 2,000 codepoints of valid UTF-8 with no NUL; `Forge.Operator` refuses a longer
one with `{:handback_note_too_long, limit}` and a bad one with `:bad_note`, and never cuts it.

## The guard

`Forge.Operator.take_over/3`, `hand_back/3` and `release/3` are guarded by `allow(ticket, actor,
:use)`, asked again inside the transaction that acts (`Engine`'s `:allow`). A read token and a
member of another project are refused; the JSON API's `POST …/take-over {running}` and `POST
…/hand-back {to, note}` are wrappers that pass `via: :api`. `Render.ticket` gains `taken_over`
(`by`, `at`, `via`, `state`).

## A job's push (built, platform and worker)

A job pushes with a lease (`worker-channel.md` § Protocol 17): its own last fetched or pushed sha,
so it may rewrite its own commits and never removes one someone else pushed. When the branch moved
under it, the worker keeps the run's work at `refs/forge/kept/<job id>` and reports `branch_moved`.
The platform then records **no changeset** for that run (`Forge.Jobs`' `put_changeset/4`), and
sticks the ticket with `cause: "branch_moved"` and `job_id`, `outcome`, `lease`, `kept`, `head` and
`arrived` (the commits `lease..head`, at most 20) and `pushers` in the `ticket.stuck` payload. A job's token may
write exactly its own kept ref (`Forge.Git.Tokens.allowed_refs/2`, `pre-receive`), never delete it.
Every workflow job and conversation needs protocol 17.

**A moved branch outranks a usage limit**: a result carrying `branch_moved` is recorded and sticks the
ticket even when the account's limit stopped the run (`Forge.Jobs.stopped_by_limit/1` is nil
for it, so `complete/2` does not requeue), because a requeue would resume the session and push over what arrived. **A
hibernation that carries `kept`** — a pause for an update that found the branch moved — is the end of
the run too, and `Forge.Jobs.hibernate/5` records it as the stop a result makes (the job finishes
`cancelled`, the ticket sticks with `kept` and no outcome, so *Keep the job's work* runs the state
again): a resume would believe its edits are in a tree that does not hold them and end `done` without
them. **A cancelled ticket's run keeps nothing**: its job is already finished when its `hibernated`
arrives, and cancelling revoked its token first, so the kept push is refused.

**`pushers`** is who pushed to the branch while the run went: the distinct `actor` maps (`{"kind":
"api", "id", "name"}` for a project token) of the ticket's `branch.pushed` events since the job
started, **less the job's own** (`{"kind": "job", "id": <this job>}`; another job's push on the same
ticket is listed, as a `job` actor). The git door logs that event (`git-hosting.md` § A job pushes
with a lease): `ref`, `from`, `to` and the token as actor. `Forge.Engine.branch_moved_stop/1` returns
the payload of a ticket's current moved-branch stop, or nil.

## Keeping the job's work

A ticket stuck for a moved branch has three ways out. *Run again* is `retry/3` and *Take over* is the
take-over above. **Keep the job's work**, `Forge.Engine.keep_work/3` (`Operator.keep_work/3`, `POST
/tickets/:project/:number/keep-work {job_id}`), merges the kept commit onto the head the branch has
now and carries on as the job's own outcome would have:

- `job_id` must be the job the ticket's latest stop names, and the ticket must still be stuck for it:
  a press on a stop that has since been left (by *Run again*, by keeping, by a take-over's hand-back)
  is refused `{:error, :stale_stop}`, so a second press does nothing. A stop whose kept ref is not in the
  repository (a reference the worker's token could not write is a failed run, not a stop) is refused
  `{:error, :nothing_kept}`.
- **Git first, then the record.** With the kept commit already an ancestor of the head nothing is
  merged. Otherwise `Merge.merge_tree/3` of the head and the kept commit, then one merge commit
  (parents head, kept; the platform as author), pushed by the platform's own push with a lease on
  the head it read — the update step's pattern (`Forge.Update`). A clash is `{:error,
  {:kept_work_conflicts, paths}}` and the ticket stays stuck, with all three ways still offered.
  A push the platform could not make — the branch moved again, or a hook refused — is `{:error,
  :keep_push_failed}`, nothing written. A cap that has nothing left for the run again of a stop with no
  outcome is refused as `retry/3` refuses it, **after** the merge commit was pushed: the work is on the
  branch and the ticket stays stuck (git first, then the record).
- **Then one transaction**: a `changeset` version at the new head authored by whoever kept it, the
  base following (`Jobs.put_base/5`), the ticket unstuck, `ticket.work_kept` logged (`job_id`,
  `kept`, `from`, `to`, `merged`, `via`); then `put_after_job/4` with the job's declared outcome when
  the run had one — a held or taken-over ticket defers the transition as any hold does — and
  otherwise the state runs again.
- The guard is `allow(ticket, actor, :use)`, asked before the git work (a refused actor merges
  nothing) and again inside the transaction.

## What later jobs are told

**Every job created on a ticket after a hand-back is told**, beside what already ran: who took it
over, from when to when, who handed it back, the steps, the commits pushed meanwhile and the note.
It is not a workflow input, so no workflow changes and none can forget it. The spec's `outside`
(`ForgeCore.Job.Spec`) is filled by `Forge.Jobs.runtime_spec/1` **at assignment**, beside `base`,
for agent jobs and for a ticket's conversation alike — at assignment and not at creation, so what
a job is told is what is true when it is placed. (A take-over withdraws every job not yet running, so a
job placed after a hand-back is in practice one the hand-back made; no test can tell the two apart.) It holds every handed-back
take-over of the ticket, oldest first, one map each: `by` and `at` (who took it, as an event
actor, and when), `via`, `state`, `back_by`, `back_at`, `back_via`, `to`, `commits` (`{sha,
subject}`, at most 20, and `more`) and `note`. A take-over still open is not in it. The manifest
(`Forge.Prompt`) draws **## Worked on outside forge** after *How you got here*, a conversation's
just before *Context*; the note is in a fence under *They wrote:* as a comment is, so it is never
markup. A ticket nobody took over has no such section.

## Outside work: a ticket admitted already taken over

`Forge.Operator.admit/3` accepts `outside_work: true` in place of `on_hold`: the ticket is
admitted taken over by whoever opens it (a person, or the token), runs nothing, and is handed back
like any taken-over ticket. `outside_work: true` with `on_hold: false` is refused
(`:outside_work_starts`); `start_commit` without `outside_work` is refused
(`:start_commit_without_outside_work`). **`start_commit`** names the commit the branch is cut from
and the workflow is read at:

- It must be a **full commit id**: `\A[0-9a-f]{40}([0-9a-f]{24})?\z` — a branch or tag name, an
  abbreviation or anything beginning with `-` is `{:bad_start_commit, :not_a_commit_id}`.
- It is resolved by `Forge.Git.resolve/2` in the project's repository, and must be **reachable
  from some ref** (`Forge.Git.reachable?/2`, `git for-each-ref --contains`), otherwise
  `{:bad_start_commit, :unknown}`. The sha that resolves is the one the ticket type layout and
  workflow are read at and the one `Git.create_branch/3` cuts from: one lookup, one repository.
- A missing, unparsed or typeless workflow at it is refused as an admission at the default head is,
  before anything is written.
- **`base_commit` is where the start meets the default branch** (`Git.merge_base/3` of the default
  branch's head and the start), and `workflow_commit` is the start. A start on the default branch
  is its own base, as today. A start that shares no history with it is refused
  (`{:bad_start_commit, :no_common_history}`). Everything that shows the change reads
  `base_commit..head` already — Changes, the review, a job's `changeset` input, the manifest's
  *Base* — so another ticket's unmerged work under the start is in what a person approves. Once
  the ticket underneath lands as a squash, the change still shows that work until the branch is
  brought up to date.
- Admission writes the take-over row, the hold and `held_entry` as an on-hold admission does, and
  logs `ticket.admitted` (with `outside` and `start_commit`) and then `ticket.taken_over`.

The JSON API's `POST /projects/:project/tickets` takes `outside_work` and `start_commit`;
`GET /projects/:project` returns the project with its `git_url` and `ticket_types`, because an
agent cannot open a ticket without the types. A taken-over ticket's `Render.ticket` carries, with
`offers`, `steps`: every state of the pin with `edge` (the outcome of the transition that leads there
from the current state, or null where it is a jump) and `missing` (the documents a job there needs that have no version).

## The MCP endpoint (built)

`POST /mcp`, `ForgeWeb.Mcp` and `ForgeWeb.Mcp.Tools`: a second door with the API's bearers and
permissions, whose tools call the operations the API calls and say through which door each act came
(`via: "mcp"`). `docs/design/api-and-ui.md` § MCP is its standard — the protocol, the tools, the
`Origin` rule, the sentence every description ends with — and `identity.md` § The inventory of ways in
its guard. The `instructions` it hands an agent are the one place forge tells an outside agent how to
drive a ticket; forge defines no project file for it and reads none.

## Not built, and not verified

**Everything in this note is built**: the take-over and hand-back, a job's push and the moved-branch
stop with its three ways out, what later jobs are told, outside work from a start commit, the MCP
endpoint, and the screens (the band and its picker, *Take over* in the details, the rows and the
milestones' *Hand back*, Activity's lines, the forms' *Start now* default, the connect command beside a
new token, and the stuck item of a moved branch on the ticket page and in the queue).

**What differs from the plan** (`plan.md` § 5): MCP's tools call `Forge.Operator` as the API's
controllers do and render a refusal through `ForgeWeb.Api.Errors`, which asks the API's own fallback
table; there is no `TicketOps` layer between them, because the guard they share is `Forge.Operator`'s.

**Not verified here**, because nothing in this repository can: a real agent on a real PC driving a
ticket through `/mcp` with a project token over the internet; `git push` of a PC's clone through a
reverse proxy to a ticket branch while a job runs; a worker at protocol 17 running a real harness
against a branch somebody moved (the suite moves it with a stand-in harness,
`fake_claude.sh`'s `moves_branch`); and the screens on a real phone.

**Known limits.** The commit a hand-back records is read once, before its transaction: a push that
lands between that read and the move is not in the version recorded, and so not merged, until the
ticket is taken over and handed back again. A moved-branch
stop is never repaired by the worker: the work is kept at `refs/forge/kept/<job id>` and no ref is
ever deleted, so a busy ticket accumulates one per stop.
