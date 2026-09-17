# Identity, membership and who pays

Scope: who a user is, which projects they reach, and whose credential funds the work. It
replaces the shape the Phoenix generator left behind, and it is the note that turns
`decisions.md` § Security and users from a promise into a mechanism.

The relations land first because they are what is painful to retrofit; OIDC lands in the closing
step, where there is a real origin, TLS and redirect URIs. See § Sequencing, which records what
is built and what is not.

## What is there today

Worth stating plainly, because the gap is not where the decision record implies it is.

- Authentication is the generator's, unmodified: email and password, magic link, session
  tokens, and per-user API bearer tokens under the `api` context.
- **Authorization does not exist.** Every operator-facing route is
  `require_authenticated_user` and nothing else; the two that are not (`/store` and `/git`)
  authorise a token rather than a person, and stay that way. `user.role` — `operator | approver | promoter | spender` — is read in exactly one
  place, `GET /api/v1/me`, which echoes it back. It is a decorative column.
- **There is no user-to-project edge at all.** `project` is a name, a repository path, a
  default branch, a model and a seed. The queue, the board, `/projects` and the ticket list
  are global.
- What does exist is **attribution**: `answers`, `approvals`, `proposal_decisions` and
  `push_subscriptions` all carry `user_id`, and `artifact_version.author` is
  `{user, id} | {job, id}`.

So the audit trail is real and the gate in front of it is not. `decisions.md` says users and
roles are in the data model so that team use is an expansion rather than a rewrite; half of
that is true. Attribution is there, the relation is not.

## Two questions, kept apart

**Who are you** is authentication: local accounts and OIDC. **What may you touch** is
authorization: membership, roles, read scoping. OIDC answers the first and can be made to feed
the second; it is not allowed to. The reason is in § The IdP is not the authority.

## Authentication

Two methods, both first class, both landing at the same user row.

**Local accounts.** What exists now, kept: email, password, magic link. `mix forge.user.add`
creates one on the host. This is also the recovery path — a self-hosted platform whose only
door is an external IdP is bricked by a misconfigured redirect URI, and the machine's owner has
a shell.

**OIDC, against configured providers.** More than one issuer may be configured. A person
arrives at the login page, picks a provider, comes back, and **a user is created on the spot**.
No prior row, no invitation, no linking step.

Provisioning on first login is what makes the rest of this simple, and it moves one problem:
if any identity the IdP will authenticate gets a row, the row cannot mean anything on its own.
That is what § Approval is for.

### Identity is `(issuer, subject)`, never email

A new table, because the user table cannot carry this:

**identity** — `user_id`, `issuer`, `subject`, `email` (as claimed at the last login, for
display only), `last_login_at`. Unique on `(issuer, subject)`.

Email is not an identifier. It is mutable at the IdP, it is re-assignable by whoever runs the
IdP, and two issuers can assert the same address without any relationship between the people
behind them. `sub` is the stable one, and it is only stable *within* an issuer, which is why
the key is the pair.

A local account has no identity row; it has a `hashed_password`, which therefore becomes
nullable. A user has zero or more identities and at most one password.

**The same person arriving through two issuers becomes two users.** That is deliberate and it
follows from cutting the linking step: forge has nothing to link on that it would be safe to
believe. It costs a duplicate row and two approvals; it buys never having to decide whether an
`email_verified` claim from an arbitrary configured issuer is worth trusting with someone
else's project access.

## Approval

**The first login creates a pending account, for local and OIDC alike.** A pending user can log
in, and sees one thing: a page saying the account is waiting. No projects, no queue, no API. A
pending user's API token is refused for the same reason the session is.

A **node admin** approves it. Approval writes `users.approved_at` and a `user.approved` event
carrying the approving actor, like every other mutation.

This is the perimeter, and it is why the rest of the model can be permissive: an approved
account may create projects freely (§ Projects and members), because getting approved is the
step that means something.

Suspension is the reverse and is how a person leaves: `users.suspended_at`, sessions and tokens
refused. Users are never deleted — `answers`, `approvals` and `proposal_decisions` reference
them with `on_delete: :restrict` precisely so that the record of who decided what cannot be
erased by removing the decider.

### node_admin is account governance, and nothing else

`users.node_admin`, a boolean, seeded on the host (`mix forge.user.add --node-admin`). A node
admin may approve, suspend and promote. A node admin is **not** implicitly a member of any
project, does not appear in project queues, and does not read project artifacts. The flag
governs who is let into the building; it grants no room.

This is the one global thing in the model, and it is deliberately the smallest one that works.
Bootstrapping is explicit rather than "whoever reached the login page first".

## Projects and members

**project_member** — `project_id`, `user_id`, `role` (`admin | member`), `inserted_at`. Unique
on `(project_id, user_id)`.

- **admin** — project settings, deleting the project, and managing membership.
- **member** — everything else the product does: admit tickets, answer questions, approve
  transitions and merges, edit documents, open conversations, decide proposals.

Two roles, not the vision's `approver | promoter | spender`. Those are capability names for a
model with more distinctions than there is evidence for; they are not lost, they are what this
expands into (§ The capability seam).

**Any approved user may register a project, and becomes its admin.** `POST /api/v1/projects`
stays as it is, gated on approval rather than on a role.

**There are no invitations.** A project admin adds a user who already exists, which every
approved user does by construction. This is the whole reason approval was worth putting in
front: with it, "add a member" needs no pending-membership row, no email matching, and no
bearer link in a chat message.

A project always has at least one admin. Removing or demoting the last one is refused.

Non-members do not see a project. Not its name, not its tickets, not that it exists.

### The relation holds because every object already reaches a project

`ticket.project_id`. `job.project_id`, non-null, added when conversations arrived. An artifact
belongs to a ticket or to a job, and both reach a project. So the check is always *resolve to
the project, look up the membership*, and there is no object that cannot answer.

### The capability seam

**No authorisation decision compares a role name.** It asks `Forge.Access.can?(scope,
capability)`, where the capability today is `:use` (member and admin) or `:manage` (admin). A
pure function expands the role; the call sites do not know how many roles there are.

That is the whole cost of leaving room for `approve`, `promote` and `spend` later: one
indirection, no extra table, no bespoke per-membership permission lists. Splitting `:use` later
changes the expansion and the migration, not the guards.

Two places do read the name, and neither is a decision about access: `last_admin?/2` counts the
rows carrying `:admin`, which is a rule about the role's cardinality rather than about what it
permits, and `members/1` ranks admins first for display. The rule was once written here as
"code never compares a role name", which was simply false — and the version of `members/1` that
made it look true sorted the stored strings, so "admins first" held because 'admin' precedes
'member' in the alphabet.

## Where the guard lives

`Forge.Operator` is the single place every human action exists, taking the acting user, and the
guard goes at the entrance of each of its functions.

That was a description of the intended design before it was a description of the code. A review
found seven human writes reaching their context directly — a conversation answered from the
queue with an id off the wire, everything on the settings page, admitting a ticket, opening a
chat — with nothing but a LiveView mount in front of them, which is the page again. They are
`Operator` functions now: `admit/3`, `open_chat/4`, `send_chat/4`, `stop_chat/2`, `close_chat/3`,
`reopen_chat/2`, `merge_chat/2`, `set_model/3`, `issue_token/3`, `revoke_token/3`.

**Membership is guarded where it is changed, which is `Forge.Projects`**, not in `Operator`.
Two rules live there because they are about the membership table itself: a caller needs
`:manage`, and a project always keeps an admin. The contexts keep unguarded functions for the
engine and for the command line, which is past every gate there is.

**Contexts take the acting user, not the scope.** The scope is built where a project is in
hand — at the web edge by `ForgeWeb.Access`, and inside `Operator` and `Projects` where the
guard runs. An earlier version of this note said contexts take a scope; they never did, and
saying so cost a reader the one hop that actually happens.

A LiveView that hides a button is cosmetics. The context refusing is the guard, and **the
mutation aimed at these rules removes the check in the context**, not the one in the template. A
test that only asserts a hidden button passes against a broken platform.

## Read scoping is the half that leaks

Refusing a mutation is easy to get right and easy to test. The holes are in reads, and every
one of these is a surface that is global today:

- `Forge.Queue` — the union over your memberships, on the page at `/` as well as in the API.
  Highest risk of a silent hole, and the one that had a context test and no page test.
- The board, `/projects`, `/tickets/new`, the ticket list API, and the chats list — which was
  named here for a month while `ChatsLive` still called `Conversations.summaries()` unqualified
  and handed every account the project name, the link and the last line of every transcript on
  the node. A surface named in a note is not a surface that is scoped.
- `ArtifactController` — serves bytes by project and number, needs membership.
- Push fan-out. `push_subscriptions` carries `user_id`; a blocking question must reach the
  people who may answer it and no one else — and not a suspended account, whose device would
  otherwise keep buzzing about projects it can no longer open.
- Every conversation write, because a chat id off the wire resolves to a project that may not be
  yours. The queue's answer buttons send exactly that.

**The event log gets a column.** `events` reaches a project only through `ticket_id` or
`job_id`, both nullable, so `project.registered` and system events have no path at all and
"events visible to me" has no clean query. Denormalise `project_id` onto the row, null for
genuinely node-wide events, which only node admins read.

That migration has a trap worth naming here rather than discovering: the append-only trigger on
`events` fires `BEFORE UPDATE OR DELETE`, so the backfill is blocked by the guarantee it is
part of. The migration drops the trigger, backfills, and re-creates it, in one transaction.

The store endpoint (`/store/*key`) is unchanged: it is the worker's door, authorised by a
short-lived token scoped to one key and one verb, and no user is involved.

API tokens stay platform-issued. They act as their user and inherit that user's memberships, so
there is nothing to authorise separately. Accepting IdP-issued JWTs on `/api/v1` would buy
service accounts at the cost of JWKS rotation, clock skew and a revocation story, for a surface
whose clients are `curl` and the Mix tasks. Not now; it is an addition, not a migration.

## The IdP is not the authority

Forge does not read `groups`, `roles` or any other claim to decide access. Ever.

Two reasons, and the second is the one that settles it. Membership derived from a claim is
revoked only at the next login, so the session lifetime becomes the revocation window. And
`decisions.md` requires every mutation to be audited into the event log — a role changed in
Keycloak is a change to who can spend money on this machine that leaves no trace here at all.

The IdP says who arrived. Forge says what they may do, in a row, with an event next to it.

## Credentials

Capacity and funding stop being node configuration and become things a user owns.

**credential** — `user_id`, `name`, `kind` (`subscription | api_key`), the secret, and
`daily_limit_usd` (nullable). Revoked rather than deleted, because jobs reference it.

One type covering both kinds, because the union already exists in the code: the worker harness
takes `{:api_key, value} | {:oauth, value}` and `runtime.exs` builds exactly that from the
environment. What changes is where it comes from — a row a person owns rather than one variable
for the whole node.

This is the answer to the standing open question of which credential funds execution. A
subscription is individual-use, so team use works by each person bringing their own; nothing
has to be decided centrally and no one is billed for anyone else by default.

**The daily limit is recorded, not enforced.** A credential's spend is a query over the jobs
that used it; the figure is shown, and nothing refuses a job on account of it.

Enforcement that exists today is untouched, and this is a deliberate reading rather than an
omission: the **ticket allowance** from the pinned workflow still sticks a ticket, and the
**node-wide daily cap** in configuration still pauses the node. `poc-plan.md`'s definition of
usable requires that a cap has stopped a runaway job, and `open-questions.md` records that it
has. Removing those to make room for an unenforced credential limit would un-meet a criterion
that is already met. The new concept starts as tracking; the old caps keep working.

## Workers

**A worker is owned by a user and carries one credential.** `workers` gains `user_id` and
`credential_id`. The `managed` flag already distinguishes a machine the platform may destroy
from one the operator provisioned; ownership is orthogonal to it and both kinds have an owner.

**project_worker** — `project_id`, `worker_id`. **The worker's owner creates this row, and only
for a project they are a member of.** A project admin cannot reach for someone else's machine,
because assigning it spends its owner's credential and the money stays with whoever spends it.
The cost is that an admin who needs capacity has to ask for it out of band, which on a node with
one operator is not a cost at all.

A job runs only on a worker assigned to its project. A project with no worker assigned does not
fail — its tickets stick with that as the reason, through the mechanism that already exists for
an exhausted allowance, and the queue says so.

`jobs` gains `credential_id`, copied from the worker's credential when the job starts and never
rewritten, like `spec`. That is what makes spend per credential a query rather than a running
total somebody has to maintain.

### The residual

A worker assigned to two projects runs jobs authored by other people on its owner's
subscription credential. That is the individual-use constraint returning through the back door,
and this note does not answer it — it is narrower than the original question, and it does not
arise until a second person exists on a node. Recorded in `open-questions.md` rather than
decided here.

## Deliberately not here

- **Organisations or teams above projects.** No second grouping level is motivated. The
  extension point, if it ever is, is a membership row whose subject is a user *or* a group.
- **Project visibility beyond membership.** No public or internal projects.
- **A second factor implemented here.** An OIDC provider does it better; a local account is the
  recovery path on a machine you already have a shell on.
- **SSH.** Being cut.

## The inventory of ways in

Every route, socket, LiveView action and channel message, with what each must satisfy. It is
recorded in `test/forge_web/authorization_inventory_test.exs` rather than only here, because a
table in a note is a claim: **a new route or action fails that test until somebody classifies
it.** Every hole this branch shipped was a surface that existed before anyone decided what
guarded it.

The vocabulary:

| | Means |
|---|---|
| `public` | No credential. The login pages and the log-out. |
| `self` | Authenticated; acts only on the caller's own account. |
| `pending_ok` | Authenticated but deliberately reachable before approval — the holding page. |
| `approved` | Approved account; no project involved. |
| `member` | Approved, and a member of the project the surface is about. |
| `manage` | Approved, and an **admin** of that project. |
| `node_admin` | The account-governance flag, which grants nothing on any project. |
| `token` | A platform-issued credential and no session: git, the blob store, a worker. |
| `local` | Changes nothing on the server. Page state only. |

What that comes to:

- **`member`** is most of the product: the queue and board, every project, ticket, review, job,
  chat and artifact page, all fifteen ticket and proposal endpoints of the JSON API, and every
  conversation write.
- **`manage`** is the four settings actions — the model, minting a token, revoking one, and
  membership. Credentials are admin-only to *read* as well, because the token list names the ids
  the revoke button needs.
- **`approved`** is three: `/workers` (machines, no project identity), registering a project, and
  listing the projects you are in.
- **`node_admin`** is one page.
- **`token`** is four: `/git`, `/store/*key`, and the two sockets. None of them carries a person.
- **`public`** is the three login routes and the log-out, and nothing else. There is no
  registration route: accounts are made on the host or by an OIDC login, and then approved.

Two results of the audit worth keeping:

- **The developer routes and the live-reload socket are compile-gated**, not merely unlinked.
  `/dev/dashboard` and `/dev/mailbox` are absent from any build where `:dev_routes` is unset, and
  the reload socket is absent wherever code reloading is off. The test asserts the socket rather
  than trusting the `if`.
- **A suspended account can still complete a login** — by password or magic link — and is then
  bounced straight back to the login page, because the session token never resolves. No access
  is granted at any point. It is a wart in what the operator sees, not a hole, and it is
  recorded here so that the next person to meet it knows which it is.

## Sequencing

1. **Built.** `project_member`, the two roles, `Forge.Access`, `Scope` carrying the membership,
   guards in `Forge.Operator` and in `Forge.Projects` for membership itself, read scoping across
   the queue, the board, both project lists, artifacts, the API and the push fan-out, and
   `events.project_id`. Approval, `node_admin`, the accounts page and the project's people
   section. Every user that existed became an approved node admin and an admin of every project
   that existed, so nothing visible changed — which was the point.

   **What the review found, because it is the shape this keeps taking.** The entrance guards
   were sound and every hole was somewhere that was neither an `Operator` function nor a mount:
   a `handle_event` holding a client-supplied id, a list page nobody re-read, the settings
   handlers, and the command line. Specifically —

   - `/chats` was never scoped, though § Read scoping named it, and the suite's own test was
     called *"every conversation on the node is listed, whichever project it belongs to"*. A
     test written before the boundary existed had become a test defending its absence.
   - The queue's `chat:answer` took a chat id off the wire and sent. An account in no project
     could put an instruction into any live conversation on the node, and the agent would act on
     it against that repository.
   - `put_member/4` refused *removing* the last admin but not *demoting* one, so an admin could
     set their own row to `member` and leave a project nobody could ever administer again.
   - `mix forge.project.add` and `Release.register_project/3` still passed no owner, so both
     documented commands made projects with no members: invisible to everyone, node admins
     included, repairable only with SQL. The comment claiming the command line could fix it was
     written without checking that a command existed. It did not.

   **And the blind spot underneath most of them:** every outsider in these suites was a member
   of *nothing*, which an inner join excludes whatever the project filter says. `Projects.role/2`
   could lose its project half and the suite returned one failure — an incidental
   `Ecto.MultipleResultsError`, not an assertion. Six guards could have been deleted green.

   Two earlier finds, same family. `require_approved_user` was dead, because every pending-account
   test went through a LiveView route where `on_mount` caught it first; the socket-join direction
   then turned out to be the untested one. And `Projects.put_member/4` checked nothing about its
   caller — the page hid the form, and hiding it was the only thing stopping anyone.
2. **With the worker tier's next pass.** `credential`, worker ownership, `project_worker`,
   `jobs.credential_id`, per-credential spend tracking.
3. **Closing step, on a real origin.** OIDC: configured providers, the `identity` table,
   provisioning on first login.
