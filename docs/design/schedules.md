# Schedules

A workflow file may say that a ticket of its own type is admitted on a clock — a weekly cleanup, a
monthly dependency check — so that a regular piece of work need not wait for a person to press
*new ticket*. **A schedule admits an ordinary ticket**: it pins its workflow at admission and runs
it with its own branch, budget, approvals and merge, exactly as one a person admitted by hand
would. The schedule replaces only the person pressing the button.

`workflow-grammar-v1.md` § Schedules is the grammar an agent writing the file reads: the entry's
four keys, the cron dialect, UTC. This note is the platform's side — what is kept, what *on* means,
when a schedule fires, what becomes of a failure — and is read by whoever changes the runner, not
handed to jobs. `ui.md` § Workflow and § What each kind shows draw it.

## The model

**The file declares and a person turns on.** A schedule's cron line, title and body are in a
workflow file at the default branch's head, read again whenever that head moves. The platform keeps
one `schedules` row per schedule anyone has ever switched on (`Forge.Schedules.Schedule`): the
project, the type whose file declares it (null for the single `.forge/workflow.yml`), its name, who
switched it on and when, the time it fires after, the cron line last read for it (kept current by
every pass that reads the file), the last ticket
it admitted, its problem, and whether that problem has an open queue item.

- **A schedule with no row is off**, and so is one whose row has no `enabled_by_id`. *On* is
  `enabled_by_id` being set, and the table's checks say that `enabled_at` and `fires_after` are set
  with it.
- **A project nobody has switched a schedule on for is never read by the runner.** The runner
  looks at the projects that have a row that is on or has an alert open (`Schedules.tick/2`'s
  first query), and at no other: a project with no schedules behaves exactly as it did, down to
  not having its repository touched.
- The row is kept when the schedule is switched off or leaves its file, for its last ticket and its
  record. Nothing deletes it but the project it belongs to.

**A schedule is named by its file and its name**: `(project, type, name)`, with a unique index that
treats the single file's null type as one place. A renamed schedule is a new one and starts off. A
schedule is declared in the file of the type it admits and **never in the release type's**, which a
schedule may not start (`ticket-types.md` § Releases); the validator refuses it.

## Switching on and off

Only a project admin switches a schedule, and **every ticket it admits is admitted in that admin's
name**, because every ticket that spends money has a person behind it and a file reaches the
default branch by a merge, by an admin token's direct push, or folded into a larger change an agent
proposed. Switching on is therefore the act of admission, made once in advance
(`ticket-proposals.md` § Propose, never write).

- **Switching on** (`Forge.Operator.switch_schedule_on/4`) reads the file at the head and refuses
  `:schedule_gone` (the file no longer declares it), `:schedule_unreadable` (its file does not parse,
  or there is no workflow) or `:already_on`, writing nothing. It sets `fires_after` to *now*: **a
  schedule fires only for times after it was switched on**, so switching on never admits a ticket
  for a time already past, including times that passed while it was off. A schedule switched on at
  exactly a due minute does not fire for that minute.
- **Switching off** asks nothing and clears the schedule's problem and its open item with it.
- The page asks first when switching on, saying what it admits, how often in words
  (`ForgeCore.Cron.describe/1`), and that each ticket is admitted in the person's name.
- Both are `%User{}`-only `:manage` operations: a member's request is refused in the operation and
  changes nothing, and a project token, whatever its access, cannot reach them at all — the operation
  takes no token, and the API route refuses one first (`identity.md` § Where the guard lives).
- Another admin may switch a schedule on again, in their own name, whenever it is off.

## Firing

Every thirty seconds (`:schedule_poll_ms`) the runner (`Forge.Schedules.Runner`, started beside the
job scheduler and so never in the tests, which drive `Schedules.tick/2` with a clock of their own)
does one pass, in a task, one at a time. For each schedule that is on:

1. **The due time** is the latest time its cron line names in `(fires_after, now]`, if there is
   one. One rule covers an on-time firing and a catch-up after downtime.
2. **What is due is decided on the definition the admission pins.** `fire/4` calls
   `Tickets.prepare_admission/2`, finds the schedule in the workflow *it* read, recomputes the due
   time from *that* cron line and takes the title and body from it, so the title and body are always
   from the commit the ticket pins. The runner's own cached read only decides which rows to look at.
3. **Who it acts as.** At that moment the platform asks whether the admin it acts for may still
   admit — `Access.can?` for both `:use` (admission's guard) and `:manage` (the switch's) — and if
   not admits nothing and switches the schedule off (§ Switching itself off). The role as it was when
   the schedule was switched on is not relied on: a role changed some other way is still caught.
4. **One transaction.** Its first step locks the row and compares it with what the pass read — the
   same `fires_after` and the same admin — and moves `fires_after` to the due time; the admission
   follows in the same transaction. A restart, or a second firing from a stale read, finds the
   cursor moved and writes nothing: **a schedule fires at most once for any one due time**.
5. The ticket is titled `<title> · <UTC date it was due>`, has the schedule's body, is of the file's
   type (none, for the single file), starts at once and in no milestone, and its `ticket.admitted`
   event carries `"schedule" => %{"id", "name", "due_at", "admin"}` beside the actor, the admin.

**It fires whether or not tickets it admitted earlier are still open.** Tickets may pile up; the
ticket cap and the node's daily spend cap still bound what they spend, and no lower bound is put on
how often a cron line may fire.

**Times missed while the platform was down are made up by one ticket**, dated by the latest, and the
schedule carries on from its next time — not one per missed time.

**Once on, a schedule follows the file.** Its cron line, title and body are read at the time it
fires, so an edit that merges applies without anyone switching it again, a higher frequency or a
different body included. A cron line edited while on that newly names a time already passed since
`fires_after` fires once for it: a Monday schedule that has fired, edited on a Wednesday to name Tuesday,
admits a ticket dated that Tuesday at the next pass, and the ticket says so in its title. Only a person, the schedule leaving the file, or its admin losing
the right to admit switches it off.

## A file that does not read

When a schedule comes due and its file cannot be admitted from — it does not parse, the workflow is
gone, or admission refuses — **no ticket is admitted**, the failure and its reason are recorded on
the schedule (in the words the ticket form refuses in, `ForgeWeb.Operator.Admission.explain/1`, for
what admission refuses; a failure inside the admission's own transaction says which step failed and
why, as `admitting it failed at :ticket: …`), and
**nothing tries again before its next time**: the cursor moves to the due time like any firing's. A
file that stops parsing is not a schedule leaving it: its switches are kept, and each that is on
fails when due until the file is fixed. For that the row keeps the cron line it last read.

## Leaving the file

A schedule has **left** when the workflow files read and the type is not among them, or its file
parses and does not name it. It is then switched off for good: its problem and its open item cleared
(by the pass that sees it leave — and a pass visits only the schedules that are on or have an item
open, so one that switched itself off and was then dismissed is not visited, and keeps its problem
until an admin switches it on; if its name comes back, the page draws that old problem on it),
`schedule.switched_off` recorded with the platform as its actor (when it was on; an off schedule whose
alert is cleared by leaving records nothing), and **no item made** — nothing is
left to fix. A schedule that comes back under the same name is off until an admin switches it on.

- A single-file schedule has left once the project moves to `.forge/workflows/`, and a type's
  once the project moves to the single file; neither layout implies a type for the other's rows, and
  `fire/4` refuses to admit a type a directory of one implies when the schedule named none.
- A layout that does not read — no workflow at all, or both forms — and a file that does not parse
  are *failures to read*, not departures.

## Switching itself off

A schedule whose admin stops being an admin of the project, is removed from it, or is suspended is
switched off **in the same transaction as the change** (`Schedules.put_withdrawn/4`, composed into
`Projects.put_member/4` for a demotion, `remove_member/3`, and `Accounts.suspend_user/2` across every
project) and recorded with why. The sentence is on the schedule and in the queue; another admin's
schedules are untouched. The host's own repair path, `Projects.grant_member/3`, runs no hook, which is why
`fire/4` asks again. After the commit each newly opened item is pushed and the pages told.

## Alerts

A schedule that fails to admit, or switches itself off, goes in the queue and pushes — a widening of
`decisions.md` § Interface, which was "what will not move until a person acts".

- **A problem is not an item.** `problem`, `problem_kind` (`failed` or `switched_off`) and
  `problem_at` are drawn on the schedule on the Workflow view and stay until the schedule next
  admits, is switched on or off, or leaves its file. `alerted_at` set is an open queue item.
- **A failure sets the problem, and opens an item and pushes only if none is open**; a further
  failure while one is open updates the problem and the item's text and does not push again.
- The item reaches **every member of the project** and no one else, as every queue item does, by
  the same rule for the phone (`Forge.Push.subscriptions/1`: no suspended or unapproved account). It
  counts towards what is waiting.
- **It leaves the queue** when the schedule next admits a ticket, when an admin switches it on or
  off, when it leaves the file, or when any member dismisses it. A dismissal clears the item only,
  records who, and leaves the problem on the schedule.

## The door

| Operation | Needs | Reached by |
|---|---|---|
| switch on, switch off | `:manage`, a `%User{}` | the Workflow view; `POST /api/v1/projects/:project/schedules/on` and `/off` with an admin's own user token |
| dismiss | `:use`, a user or a project token with API write | the queue; `POST …/schedules/dismiss` |
| read | a member, or a project token with API read | the Workflow view; `GET …/schedules` |

A project token is refused a switch whatever its access, because it acts as no person and holds no
`:manage`. Every route is classified in `test/support/token_routes.ex`. Nothing here is reachable by
a job or a conversation: **a job changes a schedule only as it changes a workflow**, a commit on its
own branch that a person merges.

## The pages

The project page's Workflow view lists, under each type, the schedules its file declares: name,
cron line and what it means in words, title, the next time it fires in the reader's own time (the
server draws UTC and a hook replaces it), whether it is on and by whom, the ticket it last admitted,
and its problem in the warning tone. An admin sees the switch. A type with none says how to add one
(`ui.md` § Workflow); the release type says nothing of the kind; a file that does not parse lists
the schedules that are on, by name, with the reason. Every word out of a file is text, wrapped, and
never markup — **but the body**, which is Markdown, sanitised as a document is, with single newlines
kept and nothing resolved (`ui.md` § Workflow; ticket 80 reverses ticket 61's criterion 29 for the
body alone, and the name, title and cron line stay text). A row's element id is a hash of its type and name, because a name may hold `.`, which
the confirmation's selector would read as a class. When the workflow cannot be read at all, the
schedules that are on are listed on their own, under the notice that says so, and may be switched off. A ticket a schedule admitted says which schedule, when it was due and in whose name,
on its details and in its Activity.

## Events

Each has the project set: `schedule.switched_on` (cron at the time), `schedule.switched_off` (a
user, or the platform with `reason` and `cause`: `left`, `demoted`, `removed`, `suspended`,
`cannot_admit`), `schedule.failed` (due time and reason), `schedule.dismissed`, and
`ticket.admitted` with the schedule.

## Deliberately not here

- **A cleanup type for forge's own repository.** `dev` starts in `refining`, a conversation, so a
  scheduled ticket of it would wait there every week, and `bug`'s `refining` is an agent's job that
  reproduces a defect, which a weekly cleanup is not; a type whose first state is an agent's and whose
  prompts are a cleanup's is a change to `.forge/` that follows this release.
- **A "run now" control.** Admitting a ticket of the type by hand covers it.
- **A schedule admitting on hold or into a milestone.** Its tickets start at once and in no
  milestone; holds and milestones apply to them by hand afterwards.
- **Triggers other than time**, a per-schedule time zone, a floor on how often a schedule fires, and
  skipping a firing while an earlier ticket is open.
- **A forecast of what a schedule will spend.**
- **A retry of a failed firing before the next time.**

## Not verified here

- A runner over days on a real node: the pass is tested with a clock the test holds, and the runner
  with a fast poll, never across a restart of the real process.
- Pushes to real phones; the test sender records them.
- A schedule firing a real agent ticket end to end, from a merged file to a merged change.
- The local-time hook in a browser on a real machine other than the one `bin/look` ran on.
