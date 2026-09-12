# API and operator UI (milestone 2)

The API is the product surface; the web UI is one client of the same operations. Every human
action exists once, in `Forge.Operator`, and is reachable three ways: the JSON API, the
LiveView pages, and the Mix tasks. None of the three holds logic of its own.

## Operations

`Forge.Operator`, all taking the acting user:

- `answer(ticket, user, key, %{choice, text})` — records the answer; resumes the waiting job
  when none of its blocking questions remain open.
- `decide(ticket, user, :approved | :rejected, comment)` — decides the pending transition.
- `transition(ticket, user, to, opts)` — takes a declared transition by hand.
- `edit(ticket, user, name, content)` — writes a new version of a document.

Each returns `{:ok, ticket}` or `{:error, reason}` and, on success, notifies subscribers of
the ticket so open pages refresh.

## JSON API

Base path `/api/v1`. Authentication: `Authorization: Bearer <token>`. Tokens are per user,
created with `mix forge.token EMAIL --name NAME`, stored hashed in the users' token table
under context `api`, shown once. Requests act as that user; every mutation is attributed
and audited like any other.

| Method and path | Purpose |
|---|---|
| `GET /me` | The token's user |
| `GET /queue` | The operator queue |
| `GET /projects`, `POST /projects` | List, register |
| `GET /tickets[?project=name]` | List tickets |
| `POST /projects/:name/tickets` | Admit `{title, body}` |
| `GET /tickets/:project/:number` | Ticket with jobs, artifacts, open questions, pending transition |
| `GET /tickets/:project/:number/events` | The event timeline |
| `GET /tickets/:project/:number/jobs/:job_id` | Job with its spec and harness events |
| `GET /tickets/:project/:number/artifacts/:name[?version=n]` | A version with content |
| `POST /tickets/:project/:number/artifacts/:name` | New version `{content}` |
| `POST /tickets/:project/:number/answers` | `{key, choice, text}` |
| `POST /tickets/:project/:number/approve` | `{decision, comment}` |
| `POST /tickets/:project/:number/transition` | `{to, outcome, comment}` |

Responses are plain JSON objects; errors are `{"error": {"reason": ..., "detail": ...}}`
with 400, 401, 404, 409 or 422. No envelope, no HATEOAS, no versioning beyond the path.

## Pages

Mobile-first LiveView, one column, large tap targets. Session login from the generated auth
flow; public registration is disabled, users are created from the command line.

- `/` — the queue: one card per item, answerable in place. Options are buttons, free text a
  field; approvals have approve and reject; stuck and review items list the transitions.
- `/tickets/:project/:number` — timeline: state, cost, pending decision, open questions,
  jobs, artifacts with the latest document rendered, events.
- `/tickets/:project/:number/jobs/:id` — the pinned manifest and the harness events.
- `/board` — tickets by state per project.

Pages subscribe to their ticket (or all tickets for the queue and board) and reload when an
operation completes anywhere, including from the API or a running job.

## Message state

Every action is a LiveView event over the socket; the page shows a confirmation flash on
success and the reason on failure. A lost connection is shown by the framework's reconnect
banner. Offline compose and retry queues are out of the PoC.

## Documents in the browser

Documents are Markdown rendered server-side and sanitised before display, because agents
wrote them. Question blocks are shown as cards with their options next to the rendered text.

## Not in this slice

Web push (next slice), the merge approval view (milestone 4), presentations.
