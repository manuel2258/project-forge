# Identity, membership and who pays

Scope: who a user is, which projects they reach, and whose credential funds the work. It
replaces the shape the Phoenix generator left behind, and it is the note that turns
`decisions.md` § Security and users from a promise into a mechanism.

The relations landed first because they are what is painful to retrofit; OIDC followed once
there was a real origin, TLS and redirect URIs. See § Sequencing, which records what is built and
what is not.

## What was there before

Kept because the gap was not where the decision record implied it was.

- Authentication was the generator's, unmodified: email and password, magic link, session
  tokens, and per-user API bearer tokens under the `api` context.
- **Authorization did not exist.** Every operator-facing route was
  `require_authenticated_user` and nothing else. `user.role` — `operator | approver | promoter |
  spender` — was read in exactly one place, `GET /api/v1/me`, which echoed it back. It was a
  decorative column.
- **There was no user-to-project edge at all.** The queue, the board, `/projects` and the
  ticket list were global.
- What did exist was **attribution**: `answers`, `approvals`, `proposal_decisions` and
  `push_subscriptions` carry `user_id`, and an artifact version's `author` names a user, a job
  or the system.

So the audit trail was real and the gate in front of it was not. `decisions.md` says users and
roles are in the data model so that team use is an expansion rather than a rewrite; half of that
was true. **The other half is built now** (§ Sequencing): `users.role` was dropped by
`20260916100000_accounts_approval_and_node_admin` for approval and `node_admin`,
`project_members` is the edge, `Forge.Access` answers what a membership permits, and every
operator route also passes `require_approved_user` and the `:require_approved` mount. `/store` and
`/git` authorise a token rather than a person, and stay that way.

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

**The ID token's signing algorithm is configuration, not a constant.** `RS256` is the default
and is what almost every issuer uses, but an issuer on `ES256` or `PS512` could not be used at
all — `assent` compares the token's `alg` against one expected value and refuses anything else,
so the node answered every login from such an issuer with the same "could not be completed" an
unreachable issuer gets. `FORGE_OIDC_<ID>_ID_TOKEN_ALG` names it per provider. It is per
provider and not per node because the algorithm is the issuer's choice, and a node may have two.

Provisioning on first login is what makes the rest of this simple, and it moves one problem:
if any identity the IdP will authenticate gets a row, the row cannot mean anything on its own.
That is what § Approval is for.

### Identity is `(issuer, subject)`, never email

A new table, because the user table cannot carry this:

**identities** — `user_id`, `issuer`, `subject`, `email` (as claimed at the last login, for
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

### What the first implementation settled

Five things the paragraphs above leave open, each of which has one safe answer and several
tempting ones.

**An address already in use is refused, never adopted.** `users.email` is unique *and* `citext`,
so the comparison ignores case and `Admin@corp.com` does not get past an existing
`admin@corp.com`. Nothing in `Forge.Accounts` downcases anything, and nothing should start: the
guarantee is one mechanism in one place, and a second one in Elixir would be a second place for
it to disagree. An issuer asserting an address some account already holds cannot be provisioned. The login fails and says
so. Adopting the existing row instead is the attack this whole section exists to prevent: any
issuer an operator has configured could then mint `sub: anything, email: <the node admin's>`
and *be* them. The deliberate join is `Forge.Release.link_identity/3` on the host — one
identity attached to one named account by somebody with a shell, which is past every gate there
is anyway.

**No `email` claim, no login.** The row needs an address and there is nothing sensible to
invent. A provider whose scope does not yield one is misconfigured, and the message says which.
It stays display-only: `(issuer, subject)` is what is looked up, always.

**`state`, `nonce` and PKCE, in the session cookie, once.** The cookie is signed, `httpOnly` and
`SameSite=Lax`, which is what lets it survive the top-level redirect back from the issuer and
nothing else. All three are deleted when the callback reads them, so a replayed callback URL
finds nothing to match against. PKCE is `S256` and is sent whether or not the issuer advertises
it.

**A passwordless account is not a lesser one.** `users.hashed_password` was already nullable, so
an OIDC user simply has none: `User.valid_password?/2` answers false for them after a dummy hash
like it does for an unknown address, and the magic link and the settings page both still work.
That last part is the recovery path again — an account can give itself a password from
`/users/settings` and stop depending on an issuer that might be retired.

**The client is `assent`, not ours.** What an OIDC client actually is, past the redirect, is
JWKS fetching, `kid` selection, signature verification, and the `alg`, `aud`, `azp`, `exp` and
`nonce` rules. Every one of those is a line where a bug is an account takeover rather than a
wrong answer, and this note's own § Sequencing is a record of guards that were sound in the
place somebody looked. `Forge.Accounts.Oidc` is a wrapper: provider configuration in, a verified
`(issuer, subject, email)` out, and the HTTP client is injectable so the tests drive the whole
flow against an issuer they signed themselves.

## Approval

**The first login creates a pending account.** Only an OIDC login creates accounts: a local one
is made on the host (`mix forge.user.add`, approved as it is made), and the magic link goes only
to an address that already has an account. A pending user can log
in, and sees one thing: a page saying the account is waiting. No projects, no queue, no API. A
pending user's API token is refused for the same reason the session is.

A **node admin** approves it. Approval writes `users.approved_at` and a `user.approved` event
carrying the approving actor, like every other mutation.

This is the perimeter, and it is why the rest of the model can be permissive: an approved
account may create projects freely (§ Projects and members), because getting approved is the
step that means something.

Suspension is the reverse and is how a person leaves: `users.suspended_at`, sessions and tokens
refused. **An account that has decided anything is never deleted** — `answers`, `approvals` and
`proposal_decisions` reference users with `on_delete: :restrict` precisely so that the record of
who decided what cannot be erased by removing the decider.

**An account that has never been approved may be deleted, and that is the whole exception.**
Suspending a squatter is not enough on its own: the row keeps the address, `users.email` is
unique, and the person whose address it is can then never register — an issuer where anyone may
type any address into their own profile can park a colleague's address on the node permanently,
and § What the first implementation settled refuses to *adopt* such an address without freeing
it. Refusal has to be able to undo itself.

The line is approval rather than "has no rows", because approval is already the perimeter: a
pending account reaches no project, answers no question and decides no proposal, so it is by
construction outside the set the `restrict` references protect. Those references are also the
enforcement and not merely the motivation — deletion attempts the delete and lets the database
refuse it, rather than asking in Elixir whether the account has done anything and then deleting
on the strength of the answer. A guard must use the same model as the operation it guards, and
those are two models of "has this account acted" that can disagree under a race.

A node admin does it, it is the one governance action that is not reversible, and it writes a
`user.deleted` event naming the actor and the address freed — the record of the deletion outlives
the row, which is the property `restrict` exists to protect for everything else.

### node_admin is account governance, and nothing else

`users.node_admin`, a boolean, seeded on the host (`mix forge.user.add --node-admin`). A node
admin may approve, suspend and promote. A node admin is **not** implicitly a member of any
project, does not appear in project queues, and does not read project artifacts. The flag
governs who is let into the building; it grants no room.

This is the one global thing in the model, and it is deliberately the smallest one that works.
Bootstrapping is explicit rather than "whoever reached the login page first".

## Projects and members

**project_members** — `project_id`, `user_id`, `role` (`admin | member`), `inserted_at`. Unique
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

**And only an approved account is added.** `Projects.put_member/4` refuses an account that
`User.active?/1` refuses — pending, or suspended — with `:not_approved` or `:suspended`, after
the caller's own `:manage` check so that a non-admin learns nothing about anyone's account. It
used to take any row with an address, so a project admin could put a pending account in a
project: nothing it could use, since its session and token are turned away, but a
`project_members` row that `on_delete: :restrict` then held against the one deletion § Approval
allows, until somebody removed the membership first — and § Approval's claim that a pending
account is by construction outside the restricting tables was false for this one. A
suspended member keeps its row, because suspension is reversible and reinstating is one field;
it can be removed, and it cannot be given a new role. `grant_member/3`, the host's repair path,
does not ask.

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

The acting *user* is a `%User{}` or, for the eleven operations a project token may do (`answer`,
`answer_all`, `decide`, `transition`, `retry`, `cancel`, `restore`, `edit`, `admit`,
`accept_proposal`, `decline_proposal`), a `%Forge.Git.Token{}`. Both go through the same
`Forge.Access` call, a token's scope being `:use` only on its own project and only with API write.
Every other function still takes a `%User{}` only, so a token cannot reach one by construction.
Below `Operator` the actor is `{:user, id}` or `{:api, id, name}`, and answers, approvals and
proposal decisions carry `token_id` instead of `user_id` for the latter (a check constraint says
exactly one is set).

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

**Machines and templates are outside `Operator`, and guarded in their own contexts.** Provider
credentials and worker templates are `Forge.Provisioning`'s, and every human write there takes the
acting user and scopes itself to them — assigning a template to a project checks membership there,
as `Forge.Projects` does for members. Workers are `Forge.Workers`'s, and its human writes —
minting a permanent machine (`mint/2`), its figures (`set_offer/3`), the projects it serves
(`assign/3`, `unassign/3`) and ending one (`retire_by_owner/2`) — do the same.

Two of these were guarded only in the LiveView until a review listed them here as exceptions,
and they are recorded because the shape is the one this section keeps finding:

- **Saving a permanent worker's figures** was `WorkersLive` matching `managed: false` itself and
  then calling `Workers.update/2`, which takes no actor and casts every field the row has. It is
  `Workers.set_offer/3` now: it reads the row scoped to the caller, so somebody else's machine is
  `:not_found` exactly as a missing one is (§ Workers), refuses a machine the platform made, and
  casts only memory, cores and kinds, so the form cannot reach `managed`, `status` or a token hash
  by sending more fields. `update/2` stays for the platform's own writes — `busy/1`, `ready/2`,
  `release/1`, the sweeps — and no page or API route calls it.
- **Editing a template** was `Provisioning.update_template/2`, which took the row and no actor;
  ownership was `TemplatesLive` reading the row scoped to the caller before calling it. It is
  `update_template/3` now, taking the acting user and an id, reading the row scoped to them, and
  setting `user_id` itself as `create_template/2` does — so an edit can no more hand a template to
  somebody else than a form can create one in their name.

## Read scoping is the half that leaks

Refusing a mutation is easy to get right and easy to test. The holes are in reads, and every
one of these is a surface that is global today:

- `Forge.Queue` — the union over your memberships, on the page at `/` as well as in the API.
  Highest risk of a silent hole, and the one that had a context test and no page test.
- The board, `/projects`, `/tickets/new`, the ticket list API, and the chats list — which was
  named here for a month while `ChatsLive` still called `Conversations.summaries()` unqualified
  and handed every account the project name, the link and the last line of every transcript on
  the node. A surface named in a note is not a surface that is scoped.
- `ArtifactController` — serves bytes by project and number, or by conversation, and needs
  membership of the project either way.
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

API tokens stay platform-issued. A **user** token acts as its user and inherits that user's
memberships, so there is nothing to authorise separately. A **project** token (`git-hosting.md`
§ One project token, two doors) acts as **API**, not as the person who issued it: it holds `:use`
on its own project when its API access is *write*, never `:manage`, and nothing on any other
project. Accepting IdP-issued JWTs on `/api/v1` would buy
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

**credential** — `user_id`, `name`, `harness`, `kind` (`api_key | oauth` for Claude Code), the
secret, and `daily_limit_usd` (nullable). Revoked rather than deleted, because jobs reference it.
`docs/design/credentials.md` is the standard for it: what it is, how it is checked, how a job
picks one and how it reaches a machine.

One type covering both kinds, because the union already exists in the code: the worker harness
takes `{:api_key, value} | {:oauth, value}`. What changes is where it comes from — a row a person
owns rather than one variable for the whole node — and, since `credentials.md`, **what holds it: a
job, not a machine.** A job picks from its project's pool when it starts and the credential
travels with the assignment, so one machine can run jobs on several accounts and several
harnesses, and a pool of tokens is a thing a project can have.

**The node-wide `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` stop being read**, neither kept
as a fallback nor used as a seed; `credentials.md` § The node's own key is gone says why and what
an upgrade costs.

This is the answer to the standing open question of which credential funds execution. A
subscription is individual-use, so team use works by each person bringing their own; nothing
has to be decided centrally and no one is billed for anyone else by default.

**The daily limit is recorded, not enforced.** A credential's spend is a query over the runs
that used it (`credentials.md` § Spend); the figure is shown, and nothing refuses a job on account
of it.

Enforcement that exists today is untouched, and this is a deliberate reading rather than an
omission: the **ticket allowance** from the pinned workflow still sticks a ticket, and the
**node-wide daily cap** in configuration still pauses the node. `poc-plan.md`'s definition of
usable requires that a cap has stopped a runaway job, and `open-questions.md` records that it
has. Removing those to make room for an unenforced credential limit would un-meet a criterion
that is already met. The new concept starts as tracking; the old caps keep working.

### A provider credential is a second thing, not a second kind

`credential` above funds *inference*. Creating machines is funded too, and by a different secret:
a Hetzner token, or whatever the next provider wants. `docs/design/provisioning.md` § Whose
account puts it in its own table —

```
provider_credentials
  user_id, name,
  provider   "hetzner" | "local" | ...
  secret     encrypted map, shape owned by the driver
```

— rather than as a third `kind` here, and the reason is the sentence this section already committed
to: *a credential's spend is a query over the jobs that used it* — over their runs, since a job may
move between credentials (`credentials.md` § Spend). **Machine spend is not a query over jobs.** It
is hours times a rate and it accrues with nothing running. One table would make every existing
spend query carry a filter to stay correct, and would leave `daily_limit_usd` meaning two different
things on one row.

The secret is a map because providers disagree about how many fields they need — one token, a key
pair, a service-account document — and the driver validates its own shape on save. A new provider
is then a module and a config line, not a migration.

## Workers

**A worker is owned by a user.** `workers` gains `user_id`. The `managed` flag already
distinguishes a machine the platform may destroy from one the operator provisioned; ownership is
orthogonal to it and both kinds have an owner. A machine made from a template is its template's
owner's.

It carries **no inference credential**. That is `credentials.md`'s reversal: the first version of
this section gave a worker one credential and every job on it spent that, which made pooling
impossible, tied a machine to one harness before any job existed, and left revocation unable to
reach a machine that was already running.

**project_worker** — `project_id`, `worker_id`. **The worker's owner creates this row, and only
for a project they are a member of.** A project admin cannot reach for someone else's machine,
because a machine is paid for by its owner — their hardware, or the hourly bill of the provider
credential its template named — and the money stays with whoever spends it. The cost is that an
admin who needs capacity has to ask for it out of band, which on a node with one operator is not
a cost at all.

A job runs only on a worker assigned to its project. **A machine made from a template is assigned
through the template**, read when the job is placed rather than copied when the machine was made:
while its template is assigned to a project, its machines may run that project's jobs, and
unassigning the template stops them taking more at once. `provisioning.md` § Two tables says a
template's values are copied rather than read through; which projects a machine may serve is not a
value of the machine but its owner's standing consent, and consent withdrawn has to reach the
machines already running. `project_worker` rows are for permanent machines, which have no template
to be assigned through.

A project with no worker and no template assigned does not fail — its tickets stick with that as
the reason, through the mechanism that already exists for an exhausted allowance, and the queue
says so. Assigning one brings them back (`credentials.md` § How a job picks).

**When the owner leaves a project, their assignments to it go too** — templates, machines and
credentials, in the transaction that removes the membership. A person no longer in a project does
not keep funding it.

`jobs` gains `credential_id`, the credential the job is on now, and every start of a job records
the credential it ran on in `job_runs`. That is what makes spend per credential a query rather
than a running total somebody has to maintain (`credentials.md` § Spend).

### Minting a permanent machine

**Any approved user may mint a permanent machine of their own**, from *New machine* on
`/workers`. It used to be the host's alone — `mix forge.worker.new` — so a person with a
computer to give had to ask whoever held a shell for a token, and a deployed node could not
mint one at all: a release has no Mix, and nothing in `Forge.Release` did it.

**The owner is the caller, always.** The page's form has no owner field, so nothing on the wire
can name somebody else; the host's two ways — `mix forge.worker.new --owner` and
`Forge.Release.new_worker/2` — name an account, because a shell is past every gate there is. All
three are `Forge.Workers.mint/2`, which takes the owner and an optional project and returns the
row and the environment its machine needs — what a driver injects into a machine it makes: the
worker's id and token, the platform's address, and the model and the effort the node names, if
it names either. The Mix task adds the project's seed
and a token for it, which only the measurement harness reads.

**The owner is an account that may act**, read again when the machine is minted rather than
trusted from the caller. A page holds the user it mounted with, and an account suspended while
`/workers` was open could otherwise go on minting machines whose tokens outlive the suspension.
A pending one is refused as well, for the reason `put_member/4` refuses it (§ Projects and
members): a worker row is one `on_delete: :restrict` holds against the one deletion a pending
account may have.

**A project, when one is named, is held to the rule `assign/3` holds** — the owner is a member of
it — and that is checked before anything is written; the row and its assignment are then written
in one transaction, so a refusal leaves nothing behind to retire. With none, the machine serves
nothing until its owner assigns it, and its row says so. **Minting brings no stuck ticket back**,
as assigning does: nothing has joined with the row, and its first `ready` is what brings back the
tickets it can take. That keeps minting to the database, which is all a release command has.

**This widens nothing a person could already do.** Any approved user may create a template on
their own provider account (`provisioning.md` § Whose account) and choose its image from that
account's snapshots (§ Where a machine comes from), so a member could already put a machine they
control entirely in front of their project's jobs. A permanent machine is the same reach without
the provider: it serves only the projects its owner is in and assigned it to, and it is handed
what any machine serving those projects is handed — the job's sealed credential, the secrets its
state names, a git token for its ticket's branch. **It did widen one thing, and that was fixed rather
than accepted:** the scheduler waited for any `creating` row a project could use, so a minted
machine given figures and never booted stopped the project's templates making anything for as
long as it stood. Only a machine the platform made is waited for now (`provisioning.md` § The
gate).

**The environment is shown once.** Only the token's hash is kept, as for every token the product
issues (`ui.md` § Project settings), so the page shows the machine's environment at the moment it
is minted and never again. A lost one is a retired row and a fresh mint.

**Nothing limits how many.** A minted row is a line on its owner's page and holds no ceiling
(`worker-tier.md` § Managed and unmanaged); one that never became a machine reads *last seen
never* until its owner retires it. A person may already make any number of templates and
projects, and a cap on machines alone would be a number nothing else agrees with.

**A worker template is owned and assigned the same way.** `docs/design/provisioning.md` adds a
recipe the platform creates machines from, and it inherits this section whole: a template belongs
to a user, carries their provider credential, and reaches a project through `project_templates` —
`project_id`, `template_id` — which only its owner may create and only for a project they are a
member of. *A project admin cannot reach for someone else's template, because creating from it
spends its owner's credential and the money stays with whoever spends it.*

### The residual

A subscription credential assigned to a project other people work in runs jobs they authored on
its owner's subscription. That is the individual-use constraint returning, and this note does
not answer it. It is narrower than it was: when the credential was the machine's, it happened
because a machine was shared; now it happens because the owner assigned their credential to that
project, which is a decision with their name on it and an event beside it. It does not arise until
a second person exists on a node. Recorded in `open-questions.md` rather than decided here.

**A template assigned to two projects does the same for the hourly bill**, and it is worse in one
respect: a machine created for another project's work bills its owner while it idles towards
destruction, having run nothing of theirs at all. Same answer, same reason — not decided here,
and it does not arise until a second person exists on a node.

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
| `self` | Authenticated; acts only on the caller's own account, or on what it owns. |
| `pending_ok` | Authenticated but deliberately reachable before approval — the holding page. |
| `approved` | Approved account; no project involved. |
| `member` | Approved, and a member of the project the surface is about. |
| `manage` | Approved, and an **admin** of that project. |
| `node_admin` | The account-governance flag, which grants nothing on any project. |
| `token` | A platform-issued credential and no session: git, the blob store, a worker. |
| `local` | Changes nothing on the server. Page state only. |

What that comes to:

- **`member`** is most of the product: the queue and board, every project, ticket, review, job,
  chat and artifact page, the ticket and proposal endpoints of the JSON API (for a project token, classified in `test/support/token_routes.ex`),
  and every
  conversation write.
- **`manage`** is the settings actions — the model, the effort, the project's secrets, minting a
  git token and revoking one, membership, mirrors, and starting a release
  (`ticket-types.md` § Releases). A node admin who is not a member is not an admin of the project, and
  reaches nothing in it, so has no Release. The tokens are admin-only to *read* as well, because the
  token list names the ids the revoke button needs.
- **`approved`** is three: `/workers`, registering a project, and listing the projects you are
  in. `/workers` lists the caller's own machines only, because a row names the projects its
  machine serves.
- **`self`** is the caller's own account, and since machines, templates and credentials have
  owners it is theirs too: minting a machine, editing a machine's figures, a template, a
  credential. Every one reads the row scoped to the caller whatever id arrives, and a mint names
  no owner at all — it is the caller's. **Assigning any of them to a project is
  `member`**, and needs ownership as well — an admin of the project cannot reach for somebody
  else's. Minting into a project is an assignment too, and holds the same membership rule; the
  inventory records the action as `self` because without a project it reaches none.
- **`node_admin`** is one page.
- **Project tokens at `/api/v1`.** Every route is classified as readable by a token read, writable
  by a token write, or never for a token (`/projects` registration, `/queue`). The inventory test
  fails on an unclassified route (the table is `test/support/token_routes.ex`), and
  `ForgeWeb.Api.ProjectTokenTest` drives each class against a token that must be refused.
- **`token`** is three: `/git`, `/store/*key` and the worker socket. None of them carries a
  person. The LiveView socket is not one of them: it carries the session, and every route behind
  it sits in a `live_session` whose `on_mount` checks it.
- **`public`** is the three login routes, the two OIDC ones and the log-out — plus `/health`,
  which carries nothing and reads nothing. There is no registration route: accounts are made on
  the host or by an OIDC login, and then approved.

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

1. **Built.** `project_members`, the two roles, `Forge.Access`, `Scope` carrying the membership,
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
2. **Built, across two notes.** `provider_credentials`, `worker_templates`, `project_templates`
   and the provider registry that lets a credential name which driver it is for all arrived with
   `docs/design/provisioning.md`, which is where that pass turned out to live. The rest — the
   inference `credential`, worker ownership, `project_worker`, the project's credential pool,
   `jobs.credential_id` and per-credential spend — arrived with `docs/design/credentials.md`,
   which moved the credential from the machine to the job; its own § Sequencing records what
   landed in which order and what each step found on the way.
3. **Built, once there was a real origin to redirect to.** OIDC: providers configured from the
   environment, the `identities` table, provisioning on first login, and § What the first
   implementation settled above for the five questions the design left open.

   **What it did not change, and that is the point.** Approval is untouched: an OIDC login makes
   a pending account like any other, and a node admin still decides. Membership is untouched —
   no claim, group or role from an issuer reaches a project (§ The IdP is not the authority).
   Local accounts are untouched and remain the recovery path, which is why the host commands
   still exist and why `Forge.Release.create_operator/3` seeding the first node admin is a
   prerequisite for this rather than something it replaces.
