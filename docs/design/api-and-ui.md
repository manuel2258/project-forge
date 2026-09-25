# API and operator UI (milestone 2)

The API is the product surface; the web UI is one client of the same operations. The intent is
that every human action on a project's work exists once, in `Forge.Operator`, reachable up to
three ways — the JSON API, the LiveView pages, and the Mix tasks — none of which holds logic of
its own. It is not wholly so: not every operation has all three, and some human writes live
outside `Operator` altogether (§ Operations).

## Operations

`Forge.Operator`, all taking the acting user:

- `answer(ticket, user, key, %{choice, text})` — records the answer; resumes the waiting job
  when none of its blocking questions remain open.
- `decide(ticket, user, :approved | :rejected, comment)` — decides the pending transition.
- `transition(ticket, user, to, opts)` — takes a declared transition by hand.
- `edit(ticket, user, name, content)` — writes a new version of a document.
- `accept_proposal(version_id, user, comment)` — admits a ticket proposal as a ticket.
- `decline_proposal(version_id, user, comment)` — records that it will not be.
- `admit(project, user, attrs)` — admits a ticket.
- `open_chat(project, user, text, opts)`, `send_chat(chat, user, text, opts)`,
  `stop_chat(chat, user)`, `close_chat(chat, user, reason)`, `reopen_chat(chat, user)`,
  `merge_chat(chat, user)` — a conversation's life; see `design/conversations.md`.
- `set_model(project, user, model)`, `issue_token(project, user, opts)`,
  `revoke_token(project, user, token_id)` — project settings, which need the admin capability.

The first four return `{:ok, ticket}` or `{:error, reason}` and, on success, notify subscribers
of the ticket so open pages refresh.

The two proposal operations break that shape, and it is worth saying exactly how rather than
leaving it to be found. They take no ticket, because a proposal belongs to the job that wrote it
and a project chat's has no ticket anywhere near it. `accept_proposal/3` returns the ticket it
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
and live in `Forge.Provisioning`; setting a permanent worker's figures is
`Forge.Workers.set_offer/3`, which reads the machine scoped to its owner; approving,
suspending and promoting accounts is `Forge.Accounts`, which refuses anyone who is not a node
admin.

## JSON API

Base path `/api/v1`. Authentication: `Authorization: Bearer <token>`. Tokens are per user,
created with `mix forge.token EMAIL --name NAME`, stored hashed in the users' token table
under context `api`, shown once. Requests act as that user; every mutation is attributed
and audited like any other.

| Method and path | Purpose |
|---|---|
| `GET /me` | The token's user |
| `GET /queue` | The operator queue |
| `GET /projects`, `POST /projects` | List; register `{name, default_branch}` (repository created under the platform's repos directory) |
| `GET /tickets[?project=name]` | List tickets |
| `POST /projects/:name/tickets` | Admit `{title, body}` |
| `GET /tickets/:project/:number` | Ticket with jobs, artifacts, open questions, pending transition |
| `GET /tickets/:project/:number/events` | The event timeline |
| `GET /tickets/:project/:number/review` | The merge decision: diff, documents, answers, cost |
| `GET /tickets/:project/:number/jobs/:job_id` | Job with its spec and harness events |
| `GET /tickets/:project/:number/artifacts/:name[?version=n]` | A version with content |
| `POST /tickets/:project/:number/artifacts/:name` | New version `{content}` |
| `POST /tickets/:project/:number/answers` | `{key, choice, text}` |
| `POST /tickets/:project/:number/approve` | `{decision, comment}` |
| `POST /tickets/:project/:number/transition` | `{to, outcome, comment}` |
| `GET /projects/:project/proposals` | Open ticket proposals on the project |
| `POST /proposals/:version_id/accept` | `{comment}`; answers with the ticket it admitted |
| `POST /proposals/:version_id/decline` | `{comment}` |

A proposal is named by the **version** id, never the artifact's. A decision attaches to an exact
version, so an API that named the artifact would let a client accept text nobody had read. There
is no endpoint that edits a proposal: `POST /tickets/:project/:number/artifacts/:name` writes at
ticket scope and a proposal is scoped to its job.

Responses are plain JSON objects; errors are `{"error": {"reason": ..., "detail": ...}}`
with 400, 401, 404, 409 or 422. No envelope, no HATEOAS, no versioning beyond the path.

## Pages

Mobile-first LiveView, one column, large tap targets. Session login from the generated auth
flow; public registration is disabled. An account is created from the command line
(`mix forge.user.add`) or by a first login through a configured OIDC provider, which makes a
pending account that a node admin has to approve (`design/identity.md` § Approval).

- `/` — the queue: one card per item, answerable in place. Options are buttons, free text a
  field; approvals have approve and reject; stuck and review items list the transitions.
  Non-blocking questions follow the last card as a digest of lines, each leading to its ticket,
  and are not cards (`design/ui.md` § Not waiting on you). `GET /queue` serves them as items of
  kind `assumption`.
- `/tickets/:project/:number` — timeline: state, cost, pending decision, open questions,
  jobs, artifacts with the latest document rendered, events.
- `/tickets/:project/:number/review` — the merge decision: the diff, the documents the change was
  built from, the questions answered, the total cost, and the approval that pins the changeset by
  version. Reached by a link from the queue's approval item and from the ticket page.
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
A subscription is stored per browser endpoint for the logged-in user. Blocking questions are
pushed as they appear, tagged per question so a re-ask replaces rather than stacks, and so is a
conversation's reply when a turn completes (`Forge.Push.chat_reply/2`). Everything else waits for
one digest push a day at a configured UTC hour, sent when the reader has something waiting, an
open non-blocking question or an open ticket proposal. The last two are counted separately in it
(`N assumed`, `N proposed`) and never in its title's `N waiting on you`, because they are not
waiting on anyone. Subscriptions the push service reports gone are deleted. The service worker
shows the notification and opens the ticket page on tap.

## Message state

Every action is a LiveView event over the socket; the page shows a confirmation flash on
success and the reason on failure. A lost connection is shown by the framework's reconnect
banner. Offline compose and retry queues are out of the PoC.

## Documents in the browser

Documents are Markdown rendered server-side and sanitised before display, because agents
wrote them; inline code is escaped at the AST level since the renderer leaves it raw, and
front matter is stripped textually so an unparseable one never reaches the page. Open
questions are shown as cards above the rendered text, each with its options as buttons.

## Not in this slice

Presentations, offline compose. The merge approval view arrived with milestone 4; the git
endpoint it reviews is documented in `git-hosting.md` and sits deliberately outside `/api/v1`,
because it takes HTTP Basic with a per-job token rather than the API bearer.
