# Pages: HTML a job writes, hosted by forge, with a live store

A job or a conversation can publish an HTML page on its ticket (a project chat, on itself): a page
with its own script, images and video, such as a form a person fills in over several days. Forge
hosts it at a sub-page of its own address, **sandboxed so that its script can never act as the person
viewing it**, and gives each page a live data store that what people type is saved into as they type,
that everyone with the page open sees, and that a later job reads and writes while it runs. Ticket 66
(`refinement.md` v11 is the requirement; this is the standard the code follows). It replaces the
ticket as filed — claude.ai Artifacts in jobs — which is dropped; `CLAUDE_CODE_ARTIFACT` is not set.

**Status: being built** (ticket 66). § Built and § Not built yet say what the code at this commit
does; read them before relying on a sentence below.

## What a page is

- **Declared** by a job state as `name@` in `produces` (`workflow-grammar-v1.md` § Semantics) and
  written to `$FORGE_JOB/out/<name>/`, flat, `index.html` required. A chat declares nothing and may
  write a page as it writes a document (`conversations.md`). Pages work for Claude Code and Codex
  alike; nothing about them names a harness.
- **Recorded as rows of its own over blobs it already knows how to keep.** Each file is a blob
  artifact `<page>/<file>`, written by `Artifacts.put_version/7` exactly as a group's member is, so
  serving, the archive's `<n>/<page>/<file>` and `decisions.md`'s three artifact kinds all stay as
  they are. A page's *store* is not an artifact.
- **Versioned.** A job's publish always makes a new page version. A chat turn makes one only when a
  file was added, removed or changed: a file whose sha256 equals that of the latest version of
  `<page>/<file>`, or that the worker reports by its hash alone (it already holds the bytes), reuses
  that artifact version and writes no new one. A file changed A→B→A is uploaded again and written as
  a new version, because the worker knows one hash per file. A page's store is untouched by
  a new version, and typing never makes a version.
- **Scoped** to a ticket, or to a project chat (`job_id`, as `artifacts` has two scopes). Who sees
  a page and its data is who sees its ticket — any member of the project — or whoever may open that
  chat. Nothing new decides it.

## Tables

One migration; all in the data model's terms (`data-model.md` § Pages).

- `pages`: id, project, `ticket_id` xor `job_id`, name, `seq`, `key_count`, `data_bytes`. Unique per
  scope and name.
- `page_versions`: page, version, the publishing job, `files` (file name → artifact version id).
  Append-only through `forge_append_only()`.
- `page_entries`: page, key, value (`jsonb`), counter, size, written_at, and exactly one of
  `user_id`, `job_id` or `token_id` (a `git_tokens` row).
- `page_outside`: user and page. The row's presence means the toggle is on.
- `page_bursts`: § The audit.

## The store

One per page, keyed by the page's name within its ticket or chat. Each key holds a JSON value, who
last wrote it, when, and a counter. `Forge.Pages` is the context: `list/get/put/delete/read_only/
subscribe/outside?/set_outside`, on a scope `{:ticket, id}` or `{:chat, job_id}` and with a writer
`{:user, id}`, `{:job, id}` or `{:token, id}`. Everything that changes a store ends there, and it
holds the read-only rule and the limits.

- **The counter is per page, not per key.** Every set or delete takes `pages.seq + 1` under a
  `FOR UPDATE` lock on the page row, so a key deleted and recreated never gets back a counter a job
  may still hold.
- **Between people the later write wins** (a person's write is unconditional). **A job's, a chat's or
  a token's write names the counter it expects**, or `null` for a key it expects absent; the field is
  required, and a request that omits it is 400. A write whose expectation is wrong is refused and
  the writer is told the current value and counter.
- **Limits**, in `config :forge, Forge.Pages` so the suite can test them small:

  | | Limit |
  |---|---|
  | a value | 256 KiB of encoded JSON |
  | a key | 1 to 255 bytes of UTF-8 (the column's width), no control characters |
  | keys per page | 2,000 |
  | total keys and values per page | 4 MiB |

  They are checked against `key_count` and `data_bytes` on the page row, under the lock. A refusal
  names the limit and its number.
- **Read only.** On a done or cancelled ticket every page is read only: it opens and shows its data
  and every write — a person's, a chat's, a token's, a job's — is refused, the page saying why. The
  check is made at each write, so a jump that reopens the ticket makes them writable again. A project
  chat's page is read only once the chat has ended (`Conversations.ended?/1`). The reason is `done`, `cancelled` or
  `chat_ended` to a door or a screen; the spec's `read_only` says `"ended"` for the last. Read-only changes
  reach an open page from the global `"tickets"` and `"chats"` topics, each handler filtering by id
  before it does anything else.
- **A store may exist before its page has a version**, because a clone seeds data while its files are
  still in `out/`. A job may write the store of a page that has a row or of one its own state
  declares as `name@`; a chat may write any valid page name; a token or a person only an existing
  page. Docs and the archive list only pages that have a version.
- **Live and pinned to nothing**, as the archive is (`decisions.md`): a store is not an input, and no
  document version is ever made of it.

## Who may write, and where the guard lives

Three entrances, one rule. A person or token goes through `Forge.Operator.write_page/5` and
`Forge.Operator.set_page_outside/4`, which check membership (and a token's write access); a running
job or chat goes through `Forge.Pages.job_write/4`, which takes its scope from its own job row. All of
them end in `Forge.Pages`. **A guard must use the same model as the operation it guards**
(`CLAUDE.md`): the scope is never read from a request's path or body, only from the session, the
token or the job row.

## How a running job reaches the store

Through `/job/pages`, a door beside `/archive`, authorised the same way — the per-job git token
through `Git.Tokens.authorise_job/1`, which the agent already holds as `$FORGE_GIT_TOKEN`. The worker
adds `FORGE_PAGES_URL` (its `Config.platform_url()` plus `/job/pages`) to the agent's environment in
`git_env/1`, in `link.ex` and `conversation.ex`, so it is the same for both harnesses.

- `GET /job/pages` · `GET /job/pages/:name/data` · `GET`, `PUT`, `DELETE /job/pages/:name/data/:key`,
  the key as one encoded segment as artifact names are.
- **Scope comes from the token's job row, never from the path.** A `:workflow` job reaches its
  ticket's pages. A `:chat` reaches its ticket's if it is a ticket chat and its own otherwise (a
  chat's token carries no `ticket_id`). **A `:command` job is refused**: it has no manifest to be
  told of the door, and commands produce no page.
- **Access ends when the token is revoked**, which already happens at every end of a job or a chat
  process. Nothing a job holds reaches another ticket's store.
- **Answers:** `409 changed` with the current value and counter (or null); `409 read_only` with the
  reason; `413 limit` with the limit's name and its maximum; `404` for a page or key that does not
  exist; every token failure `401`, as on `/archive`.
- The same data over the JSON API, for a project token: `/api/v1/tickets/:project/:number/pages[/
  :name/data[/:key]]` (`api-and-ui.md`); `GET` is a token read, `PUT` and `DELETE` a token write,
  recorded under the token. The API has no chat routes.

## What a person's page does

A person always opens a page inside a forge page — an ordinary LiveView on its own live connection
as that person — and the sandboxed page talks only to it, by `postMessage`. **The page never holds a
session, a token or anything that could act as the person.**

- **`PageLive`** at `/tickets/:project/:number/pages/:name` and `/chats/:id/pages/:name`, in a
  `live_session :page` of its own with only `{UserAuth, :require_approved}`; being separate also
  forces a full page load on the way in. The process knows its own page: **no message names a page, a
  ticket or a project**.
- **`PageFrame`** (`assets/js/page_frame.js`) acts on a `message` only when `event.source ===
  iframe.contentWindow`, and accepts a fixed set of ops: `hello`, `get`, `all`, `set`, `delete`.
  Replies and changes go to the frame with `postMessage(msg, "*")`, since its origin is opaque; the
  frame cannot leave forge's addresses, so that is safe.
- **The library, `forge-page.js`** (`priv/page/forge-page.js`, read from the release's `priv` on each request): `forge.ready`
  resolving to `{viewer, readOnly, reason}`; `get(key)`; `all()`; `set(key, value)` and
  `delete(key)`, which resolve when saved and reject with the reason and limit when refused;
  `onChange(fn)`, which never reports the viewer's own writes back; `onReadOnly(fn)`. **A call made
  before the forge page around the frame has joined its socket waits for it** (the frame can load
  first, and a message sent then is heard by no one): only `hello` goes at
  once, asked again every 250 ms for a hundred tries and every two seconds after and never given
  up, and everything else follows its answer, however long that takes. It is a
  reserved file name served by the platform, and the worker refuses a page file of that name.
- **Typing.** The hook batches a page's sets and deletes, keeps the last value per key and sends a
  batch at most every 300 ms. A batch carries a client id (random per page load) and a sequence
  number; the server remembers the last sequence applied per page and client in an ETS table
  owned by `Forge.Pages.Batches` (a GenServer) and acknowledges a batch at or below it without applying it again, which is
  what keeps a batch from being applied twice across a reconnect. **A platform restart forgets the
  table**: a batch re-sent after one is applied again. It sets the same values and changes only the
  counters, but it can overwrite a write somebody else made in that window.
- **Others' changes** reach the page through PubSub `page:<id>`, from the LiveView to the hook to the
  frame, so everyone with the page open sees a change within about a second. A new version arrives as
  `{:page_published, …}` and the bar offers *newer version · reload*.
- **Unsent saves** are held by the hook while the socket is down and sent, in order, on rejoin
  (`ui.md` § Pages). A reload, a closed tab or another device keeps none, as with forge's other forms
  (`ui.md` § A reconnect is not a reload).

## Serving a page's files

The page is hosted on forge's own domain as a sub-page and sandboxed by the response, not by a
second domain (out of scope 9). `/page-files/:token/:file` serves each file.

- **The path carries a signed token, not the session.** A sandboxed document has an opaque origin and
  the session cookie is `SameSite=Lax`, so the browser sends none on the page's own requests. The
  page view mints a `Phoenix.Token` (salt `"forge page"`, 24 hours) over the viewer and the page
  version; the iframe's `src` is `/page-files/:token/index.html`, so the relative names `app.js` and
  `clip.webm` land under the same token. `PageFileController` **checks the viewer's reach again on
  every request**, so a member removed loses the files at once; the 24 hours only bounds a leaked
  path. The view signs a fresh path again when the frame reloads (the outside toggle, *newer
  version · reload*) and every 20 hours while it is open, which the hook applies only when no save is
  waiting, so a page left open for days keeps loading its own files. This is a second `Phoenix.Token` and the one that rides in a path (`storage.md`).
- **Headers on every file:** `sandbox allow-scripts` (**never `allow-same-origin`**), `form-action
  'none'`, `base-uri 'none'`, `frame-ancestors` set to `'self'` and forge's own origin, `Referrer-Policy:
  no-referrer` (so the path's token never leaves in a `Referer`), `nosniff`, and no session and no
  `set-cookie`. The content type comes from the file's extension.
- **Outside addresses.** With the toggle off, each fetch directive allows only the page's own files:
  `'self'` plus the endpoint's origin (both, in case a browser matches `'self'` differently in a
  sandbox), `'unsafe-inline'` and `'unsafe-eval'` for its own script, and `data:` and `blob:` for
  media — so no script, style, font, image, media or connection from another address loads and
  nothing typed into it can be sent elsewhere. With the toggle on, it is `*` plus `data:` and
  `blob:`.
- **The toggle is the viewer's own**, per page, in `page_outside`: every other viewer starts off; it
  lasts across new versions until the viewer switches it off, and **each switch is an event**
  (`page.outside_access`: on or off, who, which page). The bar names no address the page tried.
- **The iframe** carries `sandbox="allow-scripts"`, `referrerpolicy="no-referrer"` and
  `allowfullscreen`. The outer page keeps the router's `@csp`, whose `default-src 'self'` is the
  `frame-src` that stops the frame from navigating itself to an outside address; the browser test
  (`sandbox_pages_browser_test.exs`) loads the page under it and sees the frame's own navigation
  refused.
- **Range.** `PageFileController` answers `Range` with `206` and `Accept-Ranges` through
  `Forge.Storage.read_range/3`; every range gets at most 8 MiB a response, `416` when
  unsatisfiable. A request without `Range` takes the `Artifacts.served/2` path downloads use. Only
  this door is seekable (out of scope 13), which is what lets video scrub.
- **A page's files downloaded as files keep `default-src 'none'; sandbox`** (`ui.md` § Addressable
  artifact versions); only this door runs one, and an attached `.html` still never runs
  (`attachments.md`).

## Recording a publish

- **Worker.** `Dir.collect/3` treats a declared page's directory as neither missing nor undeclared; it
  is missing without `index.html`. A page stages flat names, refuses `forge-page.js` and applies a
  group's limits. `Blobs.upload/3` skips a file whose hash matches the spec's `pages` or the
  process's own last upload and reports `{name, hash, size}` with no key. A chat turn reports a
  directory in `out/` holding `index.html` as a page and any other directory as invalid.
- **Platform.** `Jobs.record/3` writes the page version; a missing `index.html` makes the job `error`
  through `ForgeCore.Job.Outcome` unless the page is `optional`. `Jobs.Blobs.outputs/3` and `put/5`
  accept page members, and a chat's assignment gets an outputs prefix with the conversation's
  long-lived prefix token. `Conversations.do_record_turn/4` records a turn's `pages` and
  `invalid_pages`. `runtime_spec/3` (called by `assignment/4`) fills the spec's `pages` (name, version, per file `{hash, size}`,
  keys, read_only, by, at), at run time and never stored. `step_contract/4` keeps pages.
- **Worker protocol 16** (`worker-channel.md` § Protocol 16): `pages: 16` in `protocol_needs/1` for
  every `:workflow` and `:chat` job; commands stay as they are and `minimum` stays 4.
- **Events.** `page.published` (page, version, file count, job), `page.data_changed` (the burst) and
  `page.outside_access`. The `artifact.version_written` events of a page's files stay in the log and are
  still drawn beside the `page.published` line by Activity, the job stream and the queue's
  since-line: **hiding them is not built** (§ Not built yet).

## The audit

**Every write is recorded as who made it, and when; the log is one event per writer per page per
burst, naming the keys changed and never a value** (a value is never written to the platform's log).

Each write upserts a `page_bursts` row (page, writer, opened, last, changes, keys capped at 50 names
plus a count) in the same transaction, so a crash loses no audit. `Forge.Pages.Bursts`, a sweeper
that runs every 15 seconds, closes a burst once its writer has written nothing to that page for 60
seconds, or 10 minutes after it opened, and writes one `page.data_changed` event in the same
transaction that deletes the row. It is off in the suite, which calls it directly, as with
`Attachments.Sweeper`. Activity shows the burst as one line, *made N changes to page X*: a count of writes, not of
keys, since forty edits to one field are forty changes. A burst's `key_count` is exact up to its 50
named keys and an upper bound after them. A value holding a NUL, or a key or a page name over 255
bytes, is refused, never stored (`jsonb` and `varchar(255)` would raise).

## The archive

`Forge.Archive.ticket/2` appends one inline `<page>@data.json` per page that has a version, holding
`{page, version, files, keys: {key: value}}` — values only, no writer or counter (`archive.md`
§ Layout). **Cloning a page is a job's or a chat's work, not forge's**: copy the files out of
`archive/<n>/<page>/` and seed the new store from that file. A project chat's page is not in the
archive. The data file is read only and reaches the project's own jobs and chats as the archive does.

## What it does not defend, said plainly

- **A page's files and a job's writes to the store are not masked for secrets** (`secrets.md`
  § Masking): rewriting a substring would break the data.
- **A value is hostile data.** Forge never renders one as markup; only the page draws it. A page name
  and a key name are text wherever forge shows them, and a long name is cut with the whole in its
  `title`.
- **There is no table of a page's data in forge's screens** (out of scope 7): the data is seen
  through the page, the archive and the API.
- **The sandbox is the whole defence against a page's script.** If it failed, a page would run in
  the viewer's session and could approve and merge, mint tokens, add members and read every project
  the viewer reaches — and the agent that writes it is steered by ticket text, attachments and
  fetched pages. The browser test (`platform/test/forge/look/sandbox_pages_browser_test.exs`) loads a hostile page that tries
  `document.cookie`, a credentialed `fetch` of `/` and `/api/v1/me`, `parent.document`,
  `top.location`, `window.open`, a form submitted to forge, `localStorage`, an outside image,
  navigating its own frame to an outside address and a nested frame posting to the top, and fails if
  any succeeds.
- **The ETS dedupe does not survive a platform restart** (§ What a person's page does).
- **The installed app does not keep a page**: the service worker keeps only the offline page and
  static files (`ui.md` § The installed app).

## Not in this ticket

Out of scope, agreed with the person on 2026-11-23: claude.ai Artifacts in jobs; a *Clone this page*
button for people; commands producing pages; rendering any HTML a job produces as a page; files in
the store; showing who else has a page open; a table of the data; keeping unsent saves across a
reload; a separate domain for pages; a per-address allow list; a frozen copy of the data in a job's
inputs; subfolders in a page; seekable downloads for every file; moving Project Sundive's existing
page; asking Claude or reaching connected services from a page.

## Built

Grammar and validator (`name@`, `optional`, `opens`, chat steps), the spec's `pages`, the prompt's
§ Pages and the chat preamble, worker protocol 16; the worker's staging, upload skipping and
`FORGE_PAGES_URL`; the migration and `Forge.Pages` with its limits, counters, read-only rule and
burst sweeper; recording of a job's and a chat's pages; `/job/pages`, the API routes, the signed
`/page-files` door with its headers and ranges, and the archive's `<page>@data.json`; `PageLive`,
the `PageFrame` hook and `forge-page.js`; the Docs row, *Wrote*, the decision pin and the queue
links; and a `bin/look` setup, `pages`. Each has tests in the suite, and
`test/forge/look/sandbox_pages_browser_test.exs` drives Chromium: a hostile page's script tries each way
out of its sandbox (cookie, parent, top, storage, `window.open`, credentialed fetches, an outside
image, a form posted to the top, a nested frame, a message naming another page) and none succeeds,
the bar is outside the frame, and three saves made while the socket is down arrive once each when
it is back. Its fixture pages carry the library inline because the look's guard wants a cookie on
every request and a sandboxed frame sends none.

## Not built yet

- Hiding a page file's own `artifact.version_written` line in Activity, the job stream and the
  queue's since-line, beside `page.published`.
- The page view's reads (`page:hello`, `get`, `all` and the pushed changes) are not re-checked
  against membership while the socket stays open: a member removed during a session keeps reading
  until it drops, while writes and `/page-files` are checked each time.
- "Nothing typed into it can be sent elsewhere" holds for what a content security policy covers; it
  does not cover WebRTC, and with the outside toggle on the frame's own policy allows any address.
- `bin/look` screenshots of the screens, at phone and desktop widths.
- A watched-failing mutation of any guard in this ticket (`CLAUDE.md` § Testing): the tests were
  written without being broken first.
- The changelog section (`changelog.md` § Writing a section).

## Not verified here

- **`'self'` in a sandboxed document**, and the parent's `frame-src` stopping a frame from navigating
  itself, are proven only in headless Chromium. **iPhone Safari is not checked**, and neither is
  video scrubbing on a phone or the installed app's safe areas around the frame.
- **Which address a sandboxed document's `'self'` stands for** was not established here. A page's
  fetch directives and its `frame-ancestors` therefore name `'self'`, the endpoint's configured URL
  **and the address the request itself came to**, so that a forge reached by another name still
  loads its pages. No test shows the extra source to be needed: in the browser test the configured
  URL and the request's address were the same.
- **Project Sundive's real page has not been tried.**
- That a Codex job writes a page and reads its store through `$FORGE_PAGES_URL` has not run against
  OpenAI (`codex.md` § Not verified here), nor has a real Claude Code job done it on a real worker.
- A worker at protocol 16 against a real platform's `/job/pages` over HTTP.
- This release's changelog section must name `name@`, `opens` and the reserved `forge-page.js`
  (`changelog.md` § Writing a section).
