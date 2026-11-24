# API and operator UI (milestone 2)

The API is the product surface; the web UI is one client of the same operations. The intent is
that every human action on a project's work exists once, in `Forge.Operator`, reachable up to
three ways — the JSON API, the LiveView pages, and the Mix tasks — none of which holds logic of
its own. It is not wholly so: not every operation has all three, and some human writes live
outside `Operator` altogether (§ Operations).

## Operations

`Forge.Operator`, taking the acting user — a project token for the operations a token may do (`identity.md` § Where the guard lives):

- `answer(ticket, user, key, %{choice, text})` — records the answer; resumes the waiting job
  when none of its blocking questions remain open.
- `answer_all(ticket, user, version_id, answers)` — a document's answers together, in one
  transaction, resuming the job once (`design/job-prompt.md` § Answering a document's questions
  at once).
- `decide(ticket, user, :approved | :rejected, comment)` — decides the pending transition.
- `transition(ticket, user, to, opts)` — moves the ticket to a state by hand: by the declared transition that resolves to it, or by a jump when none does (`design/workflow-grammar-v1.md` § Jumping). `opts` may carry `jump: true | false`, the kind the caller drew, refused when the target is the other.
- `retry(ticket, user)` — runs the state the ticket rests in again
  (`design/workflow-grammar-v1.md` § Running a state again).
- `retry(ticket, user, opts)` also takes `note:` and `raise:` (the ticket's cap, in weighted tokens);
  `extend(ticket, user, job_id, attrs)` — reopens the job that ran out of budget with `tokens`, `turns`,
  `note` and `raise` (`design/workflow-grammar-v1.md` § Extending a job). Both pass the guard inside
  the act's transaction.
- `cancel(ticket, user)`, `restore(ticket, user)` — cancels a ticket, hiding it everywhere, and
  brings it back (`design/workflow-grammar-v1.md` § Cancelling a ticket).
- `edit(ticket, user, name, content)` — writes a new version of a document.
- `accept_proposal(version_id, user, comment, ticket_type)` — admits a ticket proposal as a
  ticket, of the type the person chose or else the one it suggests (`ticket-types.md` § Proposals).
- `decline_proposal(version_id, user, comment)` — records that it will not be.
- `admit(project, user, attrs)` — admits a ticket.
- `start_release(project, user, note)` — starts the project's release, the workflow that sets
  `release: true`, with the note as its body. A project admin's (`:manage`); there is no API route
  (`ticket-types.md` § Releases).
- `open_chat(project, user, text, opts)`, `send_chat(chat, user, text, opts)`,
  `answer_chat(chat, user, reply, answers)`, `stop_chat(chat, user)`,
  `close_chat(chat, user)`, `merge_chat(chat, user)` — a
  conversation's life; see `design/conversations.md`.
- `set_model(project, user, model)`, `issue_token(project, user, opts)`,
  `revoke_token(project, user, token_id)` — project settings, which need the admin capability.

The first eight return `{:ok, ticket}` or `{:error, reason}` and, on success, notify subscribers
of the ticket so open pages refresh.

The two proposal operations break that shape, and it is worth saying exactly how rather than
leaving it to be found. They take no ticket, because a proposal belongs to the job that wrote it
and a project chat's has no ticket anywhere near it. `accept_proposal/4` returns the ticket it
*made* rather than one it was about, and notifies that ticket and the proposal's origin;
`decline_proposal/3` returns `{:ok, %Forge.Proposals.Decision{}}`. Neither notifies anything for
a project chat's proposal, which has no ticket to notify — an open project page does not refresh
on that decision and is reloaded.

**Conversations and project settings have no API route.** They are reached from the pages;
tokens also from `mix forge.git.token` and conversations from `mix forge.chat`, which go to the
contexts directly — the command line is past every gate there is. The API registers a project
through `Forge.Projects.register_named/3`, as the create view does.

**The API admits a ticket through `admit/3`, as the page does.** It used to call
`Forge.Tickets.admit/3` after finding the project among the caller's own, which was a second
guard with its own model of who may admit — a membership row of any role, where `Operator` asks
`:use` — and the two would have parted the day a role that cannot admit exists. The controller
now resolves the project by name alone and lets `admit/3` refuse; a refusal answers 404 with the
same body as a project that does not exist, because not a member and does not exist are the same
answer (`design/identity.md` § Projects and members). The membership check runs before the
ticket is validated, so a malformed request into somebody else's project is 404 too, never a 422
that says the project is there.

**Some human writes are not here.** Membership is guarded where it is changed, in
`Forge.Projects` (`design/identity.md` § Where the guard lives), and so are mirrors
(`put_mirror`, `delete_mirror`). Worker templates and provider credentials are one user's own
and live in `Forge.Provisioning`; minting a permanent worker is `Forge.Workers.mint/2`, whose owner
the workers page takes from the session and never from the request, and setting its figures is
`Forge.Workers.set_offer/3`, which reads the machine scoped to its owner; approving,
suspending and promoting accounts is `Forge.Accounts`, which refuses anyone who is not a node
admin.

## JSON API

Base path `/api/v1`. Authentication: `Authorization: Bearer <token>`, and there are two kinds of
bearer, tried in this order.

- **A user token**, created with `mix forge.token EMAIL --name NAME`, stored hashed in the users'
  token table under context `api`, shown once. Requests act as that user; every mutation is
  attributed and audited like any other.
- **A project token**, issued by a project's admin on its settings page (`git-hosting.md`
  § One project token, two doors): the same secret that opens git, with API access *read* or
  *write*. It reaches its own project and no other: another project's ticket, artifact or proposal
  answers 404 with the body of a missing one. A write is authored by **`api`** — event actor
  `{"kind": "api", "id": token id, "name": token name}` — and never by the person who issued the
  token; the name is copied into the event and version so drawing them needs no lookup, and a
  revoked token reads the same. A job's token is refused (401).

**A running job's own door to a page's store is not this API**: `/job/pages` takes the per-job git
token and reaches only the job's own ticket (`design/pages.md`), while this API still refuses a
job's token.

A token with *read* gets 403 `forbidden` on every `POST`, decided before the ticket is looked up. A
project token is always refused (403) `POST /projects` and `GET /queue`, which are a person's, and
nothing here exposes settings, secrets, members, mirrors, tokens, conversations or workers to
it. Every refusal to authenticate is the same 401 body.

| Method and path | Purpose |
|---|---|
| `POST /projects/:project/tickets`, `POST /proposals/:id/accept` | Admit; accept. **`on_hold` is required**, `true` or `false`, otherwise 422 `start_or_hold`; `milestone_id` is optional, and a milestone of another project or a closed one is 422 `milestone`. |
| `POST /tickets/:project/:number/{hold,release,stop}` | Put on hold; release (refused whole, 409/422, when a never-started ticket cannot be refreshed); stop the run a held ticket is finishing |
| `POST /tickets/:project/:number/title` `{title}`, `…/milestone` `{milestone_id}`, `…/move` `{to: top\|up\|down\|bottom}` or `{before: number}` | Retitle (a release's is 422 `release_title`); put in a milestone or none; order |
| `GET /projects/:project/milestones`, `POST` | List with order, current, closed, progress and ticket numbers in order; create `{name, description}` |
| `POST /projects/:project/milestones/:id` and `/:id/{current,close,reopen,move}` | Update; mark current (`current: false` unmarks); close; reopen; order. Other projects' ids answer 404. |
| `GET /projects/:project/schedules` | Every schedule the project's workflow files declare, with its type, cron line, title, body, whether it is on and by whom, the next time it fires, its last ticket's number, its problem and whether an alert is open, and `file_error` (null, or why its file does not parse). Where there is no workflow to read at all, the schedules that are on are listed by name with the reason in `file_error` and no title or body. Members and project tokens with read; another project's is 404. |
| `POST /projects/:project/schedules/{on,off}` `{type, name}` | Switch a schedule on or off — a project admin's session or own user token only, 403 for a member and for every project token; 409 `schedule_gone`, `schedule_unreadable`, `already_on`, `already_off` (`schedules.md`). `type` is absent for the single `.forge/workflow.yml`. |
| `POST /projects/:project/schedules/dismiss` `{type, name}` | Dismiss a schedule's queue item — any member, or a token with write; 409 `no_alert`. |
| `GET /me` | The token's user; for a project token, `{token: {id, name, project, git, api, expires_at}}` |
| `GET /queue` | The operator queue |
| `GET /projects`, `POST /projects` | List; register `{name, default_branch}` (repository created under the platform's repos directory) |
| `GET /tickets[?project=name][&state=s][&open=true]` | List tickets. `state` filters to one state name, `open=true` to status active or stuck; they combine. A project token needs no `project` |
| `POST /projects/:name/tickets` | Admit `{title, body, ticket_type, on_hold, milestone_id}` (`on_hold` required, below); `ticket_type` is required when the project has more than one (`ticket-types.md`); naming the release type is refused with 422 `release_ticket_type`, saying a project admin starts it with Release on the project page |
| `GET /tickets/:project/:number` | Ticket with jobs, artifacts, open questions, pending transition, and **`commands`** (the ticket's command jobs, oldest first, each as `GET …/jobs/:id` shows it, `warm` included); **`warm_build`** — `null` when the pinned workflow has no command with `keep_build`, otherwise `{copy}`, `copy` being null when the ticket has no usable copy and else the size, machine, command and arguments, commit and time of the one its next command goes to (the ticket page's block); and what a person may do about a job that ran out — `cap`, `cap_raise`, `workflow_cap`, `left`, `restart_need`, `retry` and `extend` (the offer: the job, what it used, the declared figures, the half the form starts at, whether turns are bounded), `extend` null when there is none, and only `cap`, `cap_raise`, `retry` (false) and `extend` (null) where the workflow no longer parses |
| `GET /tickets/:project/:number/events[?limit=n][&before=seq]` | The event timeline. `limit` (a whole number, 1 to 1000) and `before` (an event's `seq`) page it: the newest `limit` events whose `seq` is below `before`, oldest first as ever; either alone applies alone and neither is the whole timeline. Anything else is 400 naming the parameter, never clamped. `before` only bounds the ticket's own events |
| `GET /tickets/:project/:number/review` | The merge decision: diff, documents, presentations, the commit message, answers, cost |
| `GET /tickets/:project/:number/jobs/:job_id` | Job with **`warm`** (`source`, `from_job_id`, `kept`, `unkept`, `size`: a command's tree and build, null from a worker that does not report them), its spec and harness events (`limit` and `before` as on the ticket's events; a job's harness stream is swept thirty days after it ended, `storage.md` § Retention), its `runs` (each with the `extension_id` it started on and whether it `resumed`), its `extensions` (who, tokens, turns, note, the cap raise that came with it) and the `restart` that made it (who, note), null when none |
| `GET /tickets/:project/:number/artifacts/:name[?version=n]` | A version with content |
| `GET /tickets/:project/:number/artifacts` | Every artifact (name, kind) with **all** its versions: number, id, author, `inserted_at`, `content_hash`, and `form` (`text`, `file` or `commit`). One call, no limit |
| `GET /tickets/:project/:number/artifacts/:name/:version/raw` | The version's stored bytes, `:name` one encoded segment (`group%2Ffile`). The listed `content_hash` is `sha256:` of exactly these bytes for anything a worker's result or a person wrote (a blob recorded without a hash, milestone 1's, lists `uri:…` instead). Text is `text/plain`; a raster image blob (`.png` `.jpg` `.jpeg` `.gif` `.webp` `.avif`) is its `image/*` type, inline; anything else, `.svg` included, an attachment. `nosniff` and `content-security-policy: default-src 'none'; sandbox` on all (`ui.md` § Addressable artifact versions). A commit is 422 `not_a_file` naming the review endpoint; a version that is not a positive integer, or does not exist, is 404 |
| `POST /tickets/:project/:number/artifacts/:name` | New version `{content}` |
| `GET /tickets/:project/:number/pages` | The ticket's pages that have a version: name, version, files, `key_count`, `data_bytes`, `read_only` and why (`design/pages.md`). A project token with read |
| `GET /tickets/:project/:number/pages/:name/data` | The page's store: every key with its JSON value, counter, who last wrote it and when. A token read |
| `GET`, `PUT`, `DELETE /tickets/:project/:number/pages/:name/data/:key` | One key, `:key` one encoded segment. `PUT {value, counter}` and `DELETE {counter}` **require `counter`** — the one the writer last read, or `null` for a key it expects absent — and a request that omits it is 400; 409 `changed` with the current value and counter, 409 `read_only` with the reason, 413 `limit` naming the limit and its maximum, 404 for a page or key that does not exist. `PUT` and `DELETE` need a project token with *write*, and are recorded under the token. There are no chat routes |
| `DELETE /tickets/:project/:number/attachments/:file[/:version]` | Withdraws a person's file — every version, or one — with an optional `reason` (`design/attachments.md` § Withdrawing). A user token only; a project token is refused 403, and who may withdraw is the context's rule (the attacher or a project admin; a token's file by an admin). A withdrawn version's `…/raw` answers 410 `withdrawn` |
| `POST /tickets/:project/:number/answers` | `{key, choice, text}` |
| `POST /tickets/:project/:number/approve` | `{decision, comment}` |
| `POST /tickets/:project/:number/transition` | `{to, outcome, comment}` — `to` is any state of the pinned workflow; `outcome` asks for that declared edge only, and is refused when there is none; with none, a target no offered edge resolves to is a jump (`design/workflow-grammar-v1.md` § Jumping) |
| `POST /tickets/:project/:number/retry` | Runs the state the ticket rests in again; `{note, raise}` optional |
| `POST /tickets/:project/:number/jobs/:job_id/extend` | `{tokens, turns, note, raise}`: reopens the job that ran out of budget; refused 409 `not_extendable`, `job_live` or `step_live` and 422 for a bad figure, a long note (counted in codepoints, as the database counts it) or one the database could not store (a NUL byte, bytes that are not UTF-8), a raise that is not an amount, a raise nothing needs (`raise_not_needed`) or one short of the shortfall. A write token may; a read token or a job's may not |
| `POST /tickets/:project/:number/clear-warm-build` | Makes every warm copy of the ticket on every machine unusable (`worker-tier.md` § The command copy): its next command starts from the ticket's volume or the seed. A project member's session or user token, or a project token that may write, so any member; a read token is 403, a job's own token 401 as for every write on a ticket, a non-member 404. Answers with the ticket's `warm_build`. Records `ticket.warm_cleared` with who did it |
| `POST /tickets/:project/:number/cancel`, `…/restore` | Cancels the ticket; brings a cancelled one back — a cancelled release is refused with 409 `release_open` while another release is open (`ticket-types.md` § Releases) |
| `GET /projects/:project/proposals` | Open ticket proposals on the project, each with the `suggested_type` it names |
| `POST /proposals/:version_id/accept` | `{comment, ticket_type}`; answers with the ticket it admitted |
| `POST /proposals/:version_id/decline` | `{comment}` |

`GET …/review` serves each answer with an `author` — `{kind: "user", id, name: null}` or `{kind: "api", id, name}`.

A proposal is named by the **version** id, never the artifact's. A decision attaches to an exact
version, so an API that named the artifact would let a client accept text nobody had read. There
is no endpoint that edits a proposal: `POST /tickets/:project/:number/artifacts/:name` writes at
ticket scope and a proposal is scoped to its job.

**Files.** The writes that exist — admit, accept a proposal, a new artifact version, an answer, an
approval, a transition, a retry, an extend — also take `multipart/form-data` with the same fields and
`files[]` parts (`design/attachments.md`), under the same limits: 500 MiB a file, 10 with one act, a
pool of 100 files and 5 GiB. A request is **kept whole or refused whole**: a file that passes a limit
is 422 `attachments_refused` naming the file and the limit, and nothing is written; a body over the
limit is 413 in the API's JSON shape. A token with *read* is 403 before a byte is read, and a job's
token is refused. There are no chat endpoints, and a chat cannot be attached to through the API. JSON
requests are unchanged.

A question is served with its options as objects — `{label, detail, recommended}`, `detail` nil
only on a question recorded before options had one — and no `default`: the recommendation is the
option's flag. `POST …/answers` answers one key per call, as before; its `choice` must be one of
the question's labels, and it is refused with 422 otherwise. The pages send a document's answers
together (`Forge.Operator.answer_all/4`, `design/job-prompt.md` § Answering a document's questions
at once). The API does not, and a script answering several keys should know what that costs: each
call is its own transaction, the waiting job resumes on the call that answers its last blocking
question, and an answer sent after that one reaches the job's next run rather than this one.

Responses are plain JSON objects; errors are `{"error": {"reason": ..., "detail": ...}}`
with 400, 401, 403, 404, 409 or 422. No envelope, no HATEOAS, no versioning beyond the path.

## Pages

Mobile-first LiveView, drawn in one frame on every signed-in page (`design/ui.md` § The frame).
Session login from the generated auth flow; public registration is disabled. An account is created
from the command line (`mix forge.user.add`) or by a first login through a configured OIDC
provider, which makes a pending account that a node admin has to approve (`design/identity.md`
§ Approval).

The pages, as `design/ui.md` draws them in the redesign:

- `/` — the queue: one item per screen, oldest first, with *Later*, an *All* sheet and the end of
  the pass (`design/ui.md` § The queue). A document's questions are one card — options to lock in,
  free text beside them, one Send (`design/ui.md` § The question card); a stuck item offers its
  ways forward, including whether its state can be run again (`retry`) and whether the job that ran out can be extended (`extend`, the same offer the ticket carries). **An approval links to the
  ticket's Changes or Docs, where it is decided; the queue decides nothing.** Non-blocking
  questions asked on their own follow the pass as lines, each leading to its ticket
  (`design/ui.md` § Not waiting on you); one asked in the same document as a blocking question is
  in that document's card instead, optional. `GET /queue` serves every one as an item of kind
  `assumption`.
- `/tickets/:project/:number` — the ticket: Steps, Changes, Docs, Activity, and its decision row.
  **Changes is the merge decision**: the presentation, the diff, the commits, the documents the
  change was built from, the questions answered, the ticket's usage, and — in the decision row's
  panel — the message its merge would commit and the approval that pins the changeset by version.
- `/tickets/:project/:number/jobs/:id` — the pinned manifest and the harness events.
- `/projects`, `/projects/:name` (Tickets, Merge, Chats, Workflow, Proposals), its settings and
  its repository; `/chats`; `/workers` and `/templates`; `/usage`; `/accounts` for a node admin;
  `/users/settings`, the You page.

**There is no `/board` and no `/tickets/:project/:number/review` page** in the redesign: the
project's Tickets and Workflow replace the board, and the ticket's Changes replaces the review page.
The API's `GET …/review` stays — it is the merge decision as data, and nothing about it was a page.
Neither address answers any more: each lands on the Not found page inside the frame, which says
where it went (`design/ui.md` § Not found).

`/projects/:name` has a Proposals view: open ones grouped by the ticket or conversation they came
from, each with Admit and Decline, and the history of what became of them (`design/ui.md`
§ Proposals). `/tickets/:project/:number` names
what that ticket's own jobs proposed in its details (dropped from its title) and links to the
project page, so the affordance that commits exists in one place rather than two.

**Proposals are never queue items.** The queue's decisions are what will not move until a person
acts, and a proposal blocks nothing — no job waits on it and no ticket is stuck behind it. That is
not the whole queue any more: beneath the decisions it serves open non-blocking questions, as
`assumption` items that wait on nobody and that no count of what is waiting includes
(`design/ui.md` § Not waiting on you). A proposal is not among those either. It is decided on
the project page, where its Accept and Decline are, and counted in the daily digest. See
`design/ticket-proposals.md` § Where it surfaces.

Pages subscribe to their ticket (or all tickets for the queue) and reload when an
operation completes anywhere, including from the API or a running job.

## Push

Web Push through the browser's push service, with VAPID keys the operator generates once.
A subscription is stored per browser endpoint for the logged-in user. Whatever starts waiting on
a person is pushed as it starts — a blocking question, an approval, a stuck ticket, a ticket
resting where only a person can move it, a conversation's reply — and the rule is the queue's
`waiting?/1` (`Forge.Push.waiting/1`), so an assumption is not. `Forge.Push.Watch` hears each
ticket change and pushes what on it has started waiting since it last looked, once per time it
starts; a conversation's reply is pushed when its turn completes (`Forge.Push.chat_reply/1`).
Each is tagged per thing waiting, so a re-ask replaces rather than stacks. Everything else waits for
one digest push a day at a configured UTC hour, sent when the reader has something waiting, an
open non-blocking question or an open ticket proposal. The last two are counted separately in it
(`N assumed`, `N proposed`) and never in its title's `N waiting on you`, because they are not
waiting on anyone. Subscriptions the push service reports gone are deleted. The service worker
shows the notification and opens its link on tap: the ticket, on the view holding what waits, or
a conversation's Talk. A ticket's link names no view, so the ticket opens on the one holding what
waits (`Forge.Push.describe/1`). Each push carries its recipient's own `badge` — their queue count when
it is sent — and an item's carries `item: true`; the worker sets the badge, opens a link only on
forge's own origin, and closes the notifications that no longer wait (`design/ui.md` § The installed
app).

## Message state

Every action is a LiveView event over the socket; the page shows a toast on success and the
reason where the person acted on failure, and a lost connection is shown by the top bar itself
(`design/ui.md` § Transient states): a toast is the `:info` flash, a refusal is the page's own
state drawn beside what was pressed, and the top bar replaces the framework's reconnect banner.
That is all a lost connection is shown by, so it must never be the notice that
something was also taken: on the operator's own surfaces, what was typed and not sent survives the
rejoin that follows it, and `design/ui.md` § A reconnect is not a reload holds both the mechanism and the
six settings, worker and log-in forms where it does not hold yet (`reconnect_test.exs`
`@unrecoverable`). Offline compose and retry queues
are out of the PoC.

## Documents in the browser

Documents are Markdown rendered server-side and sanitised before display, because agents
wrote them; inline code is escaped at the AST level since the renderer leaves it raw, and
front matter is stripped textually so an unparseable one never reaches the page. Open
questions are answered in the question card, one per document, on the ticket and in the queue
(`design/ui.md` § The question card).

## Not in this slice

Presentations, offline compose. The merge approval view arrived with milestone 4; the git
endpoint it reviews is documented in `git-hosting.md` and sits deliberately outside `/api/v1`,
because it takes HTTP Basic with a per-job token rather than the API bearer.
