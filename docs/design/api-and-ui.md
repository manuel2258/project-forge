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
- `transition(ticket, user, to, opts)` — takes a declared transition by hand.
- `retry(ticket, user)` — runs the state the ticket rests in again
  (`design/workflow-grammar-v1.md` § Running a state again).
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
  `close_chat(chat, user, reason)`, `reopen_chat(chat, user)`, `merge_chat(chat, user)` — a
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

A token with *read* gets 403 `forbidden` on every `POST`, decided before the ticket is looked up. A
project token is always refused (403) `POST /projects` and `GET /queue`, which are a person's, and
nothing here exposes settings, secrets, members, mirrors, tokens, conversations or workers to
it. Every refusal to authenticate is the same 401 body.

| Method and path | Purpose |
|---|---|
| `GET /me` | The token's user; for a project token, `{token: {id, name, project, git, api, expires_at}}` |
| `GET /queue` | The operator queue |
| `GET /projects`, `POST /projects` | List; register `{name, default_branch}` (repository created under the platform's repos directory) |
| `GET /tickets[?project=name][&state=s][&open=true]` | List tickets. `state` filters to one state name, `open=true` to status active or stuck; they combine. A project token needs no `project` |
| `POST /projects/:name/tickets` | Admit `{title, body, ticket_type}`; `ticket_type` is required when the project has more than one (`ticket-types.md`); naming the release type is refused with 422 `release_ticket_type`, saying a project admin starts it with Release on the project page |
| `GET /tickets/:project/:number` | Ticket with jobs, artifacts, open questions, pending transition |
| `GET /tickets/:project/:number/events` | The event timeline |
| `GET /tickets/:project/:number/review` | The merge decision: diff, documents, presentations, the commit message, answers, cost |
| `GET /tickets/:project/:number/jobs/:job_id` | Job with its spec and harness events |
| `GET /tickets/:project/:number/artifacts/:name[?version=n]` | A version with content |
| `GET /tickets/:project/:number/artifacts` | Every artifact (name, kind) with **all** its versions: number, id, author, `inserted_at`, `content_hash`, and `form` (`text`, `file` or `commit`). One call, no limit |
| `GET /tickets/:project/:number/artifacts/:name/:version/raw` | The version's stored bytes, `:name` one encoded segment (`group%2Ffile`). The listed `content_hash` is `sha256:` of exactly these bytes for anything a worker's result or a person wrote (a blob recorded without a hash, milestone 1's, lists `uri:…` instead). Text is `text/plain`, anything else an attachment, `nosniff` on both. A commit is 422 `not_a_file` naming the review endpoint; a version that is not a positive integer, or does not exist, is 404 |
| `POST /tickets/:project/:number/artifacts/:name` | New version `{content}` |
| `POST /tickets/:project/:number/answers` | `{key, choice, text}` |
| `POST /tickets/:project/:number/approve` | `{decision, comment}` |
| `POST /tickets/:project/:number/transition` | `{to, outcome, comment}` |
| `POST /tickets/:project/:number/retry` | Runs the state the ticket rests in again |
| `POST /tickets/:project/:number/cancel`, `…/restore` | Cancels the ticket; brings a cancelled one back — a cancelled release is refused with 409 `release_open` while another release is open (`ticket-types.md` § Releases) |
| `GET /projects/:project/proposals` | Open ticket proposals on the project, each with the `suggested_type` it names |
| `POST /proposals/:version_id/accept` | `{comment, ticket_type}`; answers with the ticket it admitted |
| `POST /proposals/:version_id/decline` | `{comment}` |

`GET …/review` serves each answer with an `author` — `{kind: "user", id, name: null}` or `{kind: "api", id, name}`.

A proposal is named by the **version** id, never the artifact's. A decision attaches to an exact
version, so an API that named the artifact would let a client accept text nobody had read. There
is no endpoint that edits a proposal: `POST /tickets/:project/:number/artifacts/:name` writes at
ticket scope and a proposal is scoped to its job.

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

Mobile-first LiveView, one column, large tap targets. Session login from the generated auth
flow; public registration is disabled. An account is created from the command line
(`mix forge.user.add`) or by a first login through a configured OIDC provider, which makes a
pending account that a node admin has to approve (`design/identity.md` § Approval).

- `/` — the queue: one card per item, answerable in place. A document's questions are one form
  — options to lock in, free text beside them, one Send (`design/ui.md` § Answering questions);
  approvals have approve and reject; stuck and review items list the transitions, and a
  stuck item says whether its state can be run again (`retry`).
  Non-blocking questions asked on their own follow the last card as a digest of lines, each
  leading to its ticket, and are not cards (`design/ui.md` § Not waiting on you); one asked in
  the same document as a blocking question is in that document's form instead, optional.
  `GET /queue` serves every one as an item of kind `assumption`.
- `/tickets/:project/:number` — timeline: state, cost, pending decision, open questions,
  jobs, artifacts with the latest document rendered, events.
- `/tickets/:project/:number/review` — the merge decision: the diff, the documents the change was
  built from, whatever an agent presented about it, the message its merge would commit, the
  questions answered, the total cost, and the approval that pins the changeset by version.
  Reached by a link from the queue's approval item and from the ticket page.
- `/tickets/:project/:number/jobs/:id` — the pinned manifest and the harness events.
- `/board` — tickets by state per project.

`/projects/:name` grows a Proposals section when the project has open ones: what each says, the
ticket or conversation it came from, and Accept and Decline. `/tickets/:project/:number` names
what that ticket's own jobs proposed in its rail and links to the project page, so the affordance
that commits exists in one place rather than two.

**Proposals are never queue items.** The queue's decisions are what will not move until a person
acts, and a proposal blocks nothing — no job waits on it and no ticket is stuck behind it. That is
not the whole queue any more: beneath the decisions it serves open non-blocking questions, as
`assumption` items that wait on nobody and that no count of what is waiting includes
(`design/ui.md` § Not waiting on you). A proposal is not among those either. It is decided on
the project page, where its Accept and Decline are, and counted in the daily digest. See
`design/ticket-proposals.md` § Where it surfaces.

Pages subscribe to their ticket (or all tickets for the queue and board) and reload when an
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
shows the notification and opens its link on tap: the work screen, on Decide for a ticket and on
Talk for a conversation.

## Message state

Every action is a LiveView event over the socket; the page shows a confirmation flash on
success and the reason on failure. A lost connection is shown by the framework's reconnect
banner — which is all it is shown by, so the banner must never be the notice that something was
also taken: on the operator's own surfaces, what was typed and not sent survives the rejoin that
follows it, and `design/ui.md` § A reconnect is not a reload holds both the mechanism and the
seven settings and log-in forms where it does not hold yet. Offline compose and retry queues
are out of the PoC.

## Documents in the browser

Documents are Markdown rendered server-side and sanitised before display, because agents
wrote them; inline code is escaped at the AST level since the renderer leaves it raw, and
front matter is stripped textually so an unparseable one never reaches the page. Open
questions are answered on the ticket's Decide tab, as one form per document
(`design/ui.md` § Answering questions).

## Not in this slice

Presentations, offline compose. The merge approval view arrived with milestone 4; the git
endpoint it reviews is documented in `git-hosting.md` and sits deliberately outside `/api/v1`,
because it takes HTTP Basic with a per-job token rather than the API bearer.
