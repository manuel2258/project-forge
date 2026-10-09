# Inference credentials: who funds a job, and how a job picks

Scope: the secret an agent authenticates with, who owns it, how a job comes to hold one, and what
the platform can say about what each one has spent. It carries out `identity.md` § Credentials
and replaces that section's mechanism, which put the credential on the machine: this note puts it
on the job.

`identity.md` stays the standard for who a user is and which projects they reach, and
`provisioning.md` for where a machine comes from and whose account pays for it by the hour. This
note is the third kind of money: the tokens a job spends while it runs.

§ Sequencing says what is built and what lands in which order.

## The credential belongs to the job, not to the machine

The first design — `identity.md` as written, and `worker-tier.md` § The worker image — gave a
machine one credential at creation, injected into the environment it boots with, and every job
that machine ran spent it. A worker template was to carry the credential its machines were made
with. It is simple, and three things about it are wrong once more than one credential exists:

- **Pooling is impossible.** A job cannot spread across several tokens if the token is a property
  of whatever machine it happened to land on. Two jobs on one machine spend one account however
  many the project has, and a rate-limited token idles every machine carrying it.
- **A second harness has nowhere to go.** A machine that boots with an Anthropic token has
  decided which harness every job on it runs, before any job exists.
- **Revocation cannot reach a running machine.** The token is in a file on its disk and in the
  environment of its release. `deploy.md` § Known limits recorded this: *rotating the agent
  credential reaches no existing machine.* The platform can refuse to create another, and
  nothing more.

So **a job chooses its credential when it starts, and the credential travels with the
assignment.** A machine holds none. What a machine offers is a harness it can run, which is a
binary on its image and not an account (§ What a worker offers now).

This reverses `worker-tier.md`'s reasoning that a credential "neither scoped to one job nor short
lived" does not belong in an assignment. That reasoning was about blast radius: a per-assignment
credential is in the job's slice, where the agent can read it. That is exactly where it already
was — the harness is the agent, and the agent's environment has always held the token. What
changes is that the machine no longer holds it *between* jobs, which is a smaller radius, not a
larger one.

## What a credential is

```
credentials
  user_id          the owner; nobody else reads, assigns or revokes it
  name             unique per owner
  harness          "claude_code" | ...        which driver it authenticates
  kind             "api_key" | "oauth" | ...  what the harness calls it
  secret           sealed, never loaded by an ordinary query
  daily_limit_usd  nullable; recorded, never enforced
  models           what the provider said it may use, at the last check
  checked_at       when that was
  revoked_at       set once, never cleared
```

**`harness` and `kind` are two columns because they are two questions.** Which driver the
secret is for decides which jobs may use it; what kind of secret it is decides how the driver
hands it over. Claude Code takes an API key as `ANTHROPIC_API_KEY` and a subscription token as
`CLAUDE_CODE_OAUTH_TOKEN`, and documented precedence puts the first above the second, so exactly
one is set and the other explicitly absent (`claude-code-events.md` § Environment and
credentials). A second harness is a module declaring its own kinds, not a migration. Both are
validated against the harness registry on save, the way a provider credential's provider is
validated against the driver registry (`provisioning.md` § Whose account).

**The secret is sealed with `Forge.Provisioning.Vault`**, under an associated-data label of its
own: a provider secret's ciphertext pasted into this column does not open, and the reverse does
not either. It is a map, like a provider credential's, so a harness that needs two fields is not a
migration; Claude Code needs one.

**It is never loaded by accident.** The field is `load_in_query: false` and `redact: true`: a
struct from an ordinary query does not carry even the ciphertext, and `inspect` would leave the
field out if it did. The readers are the check run again from the settings page and the function
that seals it for a worker, and both select it by name. A LiveView listing credentials therefore holds nothing secret in its assigns — not a
design intention but a consequence of the query, which is the only kind of guarantee worth having.

**Revoked, not deleted, and revoking destroys the secret.** Jobs reference the row, so it stays;
the secret is overwritten with nothing in the same update that sets `revoked_at`, because a
revoked credential is one the owner wants to stop existing and nothing will ever need it back. A
database check says a row has a secret unless it is revoked.

### Checked on save

**A credential is tried before it is kept.** Saving one asks the provider for the models it may
use — `GET /v1/models`, the request the worker's probe used to make with the machine's token — and
three answers are possible:

- **Accepted.** The row is saved with the model list and `checked_at`.
- **Refused** (401 or 403). Nothing is saved, and the form says the provider refused it. A token
  pasted with a character missing is found here rather than at the first job, which would fail
  *Not logged in* on a machine somewhere and stick a ticket.
- **Unreachable.** The row is saved *unchecked*, with the reason. Refusing would make a node
  whose platform cannot reach the provider — the workers can, the platform might not — unable to
  hold a credential at all. An unchecked credential is usable, says so, and can be checked again.

The check is harness-specific and lives behind `Forge.Harness`, the platform's registry of
harness modules, beside `ForgeWorker.Harness` on the other side of the wire. The HTTP client is
injectable, so the tests answer it themselves.

**No error from the check carries the request.** Its headers are the secret. Every failure is
reduced to a fixed phrase — *timed out*, *HTTP 503* — before anything logs, stores or renders it,
because `inspect/1` on a library's error is how a client secret reached this repository's
production log once already: `Forge.Accounts.Oidc.describe_error/1` says how, and it is the same
class — an HTTP client's error carrying the request's headers.

**The model list moves with it.** `worker-channel.md` § What a worker offers had the machine ask
with its own token, because the list is the account's and the platform held none. The platform
now holds the accounts, so it asks, once per credential rather than once per machine join, and a
picker offers the models of the credentials in the project's pool — which is the set a job in
that project will actually run under.

## The pool

**project_credential** — `project_id`, `credential_id`. **The credential's owner creates this
row, and only for a project they are a member of** — `identity.md` § Workers' rule, applied to the
thing that now does the spending. A project admin cannot reach for somebody else's credential;
the owner decides which projects their money funds.

A project's **pool** is its assigned, unrevoked credentials. Several of them is pooling; one is
the common case and needs nothing else.

When the owner leaves the project, their assignments to it go in the same transaction as the
membership: a credential, a template or a machine does not keep funding a project its owner can no
longer see. The same holds for `project_template` and `project_worker`, which had the gap before
this note found it.

## How a job picks

At a job's **first** start, from its project's pool, for the job's harness:

1. Drop revoked credentials and credentials for another harness.
2. Drop credentials that are **rate-limited**: their latest `rate_limit` event reports a status
   not beginning `allowed`, with `resets_at` still in the future (§ Rate limits are per
   credential).
3. Of the rest, take the one that has **spent least today**; the oldest wins a tie.

`jobs.credential_id` records the choice, written in the transaction that marks the job running.

**At every later start** — a job resuming after a question, re-queued after its worker was lost
or after its credential's limit stopped it, a conversation reopened — **the job keeps its
credential while it is usable and not rate-limited**: not revoked, still in the project's pool,
same harness, and no window of it blocking.

- **Rate-limited, it moves if it can.** It picks again from the rest of the pool by the same
  rule, and starts on that. Only when every credential in the pool is limited does it wait,
  pending, until the earliest reset (§ A limit reached mid-run). Moving costs the prompt cache
  the session built on its first account; waiting hours for a reset with a free credential
  beside it costs more.
- **Unusable, it picks again** — its credential revoked, or taken out of the project.

Either move is an event, `job.credential_changed`, naming both. **Spend does not move with the
job**: each run is a row of its own carrying the credential it ran on (§ Spend), so a job that
ran on two credentials is on both of their figures, each for what it spent there.

What a pick cannot do is refuse loudly or wait silently for the wrong reason, so the outcomes are
kept apart:

| state | what happens | who resolves it |
|---|---|---|
| nothing in the pool for this harness | the ticket sticks: *no credential is assigned to this project* | a person assigns one |
| everything in the pool is rate-limited | the job waits pending; the ticket stays active; the pass after the earliest reset starts it | time |
| its own credential is limited, another is free | the job moves to the free one and starts at once | — |
| a credential is found | the job goes on to be placed on a machine | — |

**The credential is resolved before a machine is.** A job with no credential does not ask for
capacity, so an empty pool never creates a machine that could run nothing — the loop
`provisioning.md` § A template that cannot make a working machine is taken out of service exists
to stop, arriving by a different door.

**A stuck ticket comes back by itself when the thing it waited on arrives.** Sticking for a reason
about *placement* — no template, no credential — records that cause on the `ticket.stuck` event,
and assigning a template, a machine or a credential to the project re-activates the tickets stuck
for it. Without that, a stuck ticket holding a pending job was a dead end: `Engine.choose/4`
refuses a transition while a job for the current state is live, so there was nothing a person
could do from the product once the missing piece arrived. That was already true of the
`{:no_template, _}` reasons; this closes it for them as well. If the assignment did not in fact
fix it, the next pass sticks the ticket again, which is one stick — and one push to the project's
members — rather than a loop.

**An arrival is anything that can turn the pass's answer from a stick into a machine**, and an
assignment is only the first. The tickets of every project concerned come back when:

- a template, a permanent machine or a credential is assigned to the project;
- a template assigned to it goes back into service — its owner's `Enable`, or the first `ready` of
  a machine made from its current image while its counter was at the limit (`provisioning.md`
  § A template that cannot make a working machine is taken out of service);
- a template assigned to it is edited in what it could hold (`provisioning.md` § Editing a
  template);
- the owner of a permanent machine assigned to it changes what the machine offers
  (`Workers.set_offer/3`: all three figures are ones the pass reads);
- a permanent machine assigned to it reports `ready` offering the gate something its row did not:
  memory where it had none, or a harness that takes other jobs — another driver, or per-job
  credentials where it had none. Those are the two things `ready` can widen. A machine assigned before it ever booted has neither, so the pass after its
  assignment sticks the ticket again, and its first report is when it actually arrives; a machine
  updated to a release that takes each job's credential arrives at the reconnect that says so.
  Cores and kinds are left out because `ready` only ever fills them from nothing, and nothing is
  ungated: it can narrow what a machine holds, never widen it. A machine the platform made is
  left out too — its figures are its template's, which arrives on its own — and counting it put
  every stuck ticket in the template's projects through an unstick and a re-stick, and a push,
  each time a machine booted. A reconnect reporting what it reported before is not an arrival:
  every worker reconnects when the platform restarts.

A wrong guess is not free: the next pass sticks the ticket again, and a ticket that goes stuck is
pushed to its project's members (`provisioning.md` § A template that cannot make a working
machine is taken out of service).

What is left out never decided a stick. A credential re-checked: the pool is its assigned,
unrevoked credentials, whatever the provider last said, and nothing un-revokes one. A machine
leaving `unhealthy`: one that could hold the job when empty makes it a queue, `at_capacity`,
whether healthy or not, and a queue sticks nothing. A machine given an owner (`Workers.adopt/2`):
which machines serve a project is read from assignments, not owners. **One gap is known.** A
machine's protocol is written at its join, before its `ready`, so a reconnect running a release
that speaks a newer protocol but reports the same harness is not seen as arriving; a ticket stuck
because its job needs a protocol no machine spoke waits for the next arrival of another kind.

A conversation has no ticket to stick. One whose project has an empty pool stays pending, which
is `provisioning.md` § The gate's standing gap for chats, not a new one.

## Rate limits are per credential

`capacity.md` reads *the* window from the most recent `rate_limit` event, which is right with one
token and wrong with two: a limit is an account's, and the latest event on the node might be
another account's. So the platform stamps the job's `credential_id` onto every `rate_limit` event
it records, and a credential's window is the latest event carrying its id. The rule for reading it
is `capacity.md`'s unchanged — anything beginning `allowed` permits, anything else blocks until
`resets_at`, and a `resets_at` in the past means the window rolled over and nothing is known. A
report with no `resets_at` does not block either: it says nothing about when it would end, and a
job waiting on it would wait on nothing (`Forge.Credentials.limited/2`).

**A credential has one window per kind of limit.** Every report names its `rateLimitType` —
`five_hour` on all 87 recorded in `capacity.md`, `seven_day` by third-party reports — and a report
about one window says nothing about another. So a credential's windows are the latest report
*per type*, and it is limited while any of them blocks. Step 5 read only the latest report,
whatever its type, and a weekly block followed by a five-hour `allowed` would have looked free.

**`unifiedWindows`, if it arrives.** A third-party report shows newer Claude Code adding, to every
event, the utilization and reset of each window — `five_hour` and `seven_day` together. Nothing
recorded here carries it. The driver maps it when present and a window takes its utilization and
reset from whichever report about it is newest; whether it *blocks* still comes only from a
report's own status, because `unifiedWindows` carries none. So it is read if it comes, drawn
from (§ Showing the windows), and nothing decides on it.

**The stamp is the platform's, from the job's row, when the event arrives**
(`Forge.Jobs.record_harness_event/2`). Not looked up later through the job, because a job whose
credential was replaced would then carry its old account's window onto the new one; and written
over whatever the payload carried, `nil` included, because the payload is the worker's and one
naming a credential of its choosing would steer every pick away from somebody else's. What the
worker reports about the job's *own* credential is trusted: it is running the job with that
credential in its environment, so a false report costs no more than the job itself could. That
includes a reset years away, which nothing but a later report or the date clears; the owner sees
it on `/users/settings`. A reset past the end of the calendar is read as no reset at all, because
reading it would raise in every scheduler pass that did.

`claude-code-events.md` listed the mapping from `rate_limit_event` to `harness.rate_limit` as done
while the driver still let the message fall through to `harness.unknown`. It is mapped now,
because the pick reads it. **No rejecting status has been observed** (`capacity.md` § Open), so
the path that passes over a limited credential is written from the naming convention, and the
first window genuinely exhausted is what verifies it.

## A limit reached mid-run

Claude Code in `-p` mode does not wait out a limit — by third-party accounts, since none has been
recorded here: the process ends, with an error. Before this section that was a job ending
`error`, and the workflow went on as though the agent had failed at the work. It had not, and a
job stopped by its account's limit is not failed.

**How the platform knows: from the result, not the timeline.** The runner keeps the last
normalised `rate_limit` event of its run and reports it in the result's harness summary as
`rate_limit`. A run was **stopped by its limit** when it finished `error`, was not killed, and
that report blocks by § Rate limits' rule — a status not beginning `allowed`, a reset still ahead.
The timeline's events are unacked and best-effort (`worker-channel.md` § Delivery), so a lost one
would turn a limit back into a failure; a result is re-sent until the platform acks it. A
third-party report names the blocking status `rejected`; this repository has not seen one
(`capacity.md` § Open), so the rule is the naming convention's, and the first real exhaustion is
what checks it.

**What happens to the job.** The run is recorded like any other — cost, turns, session,
transcript, and the work, which the worker pushed to the branch before it reported
(`decisions.md`). Its documents are not: the job is not done, and its next run writes them. Then
the job goes back to `pending` instead of `finished`, keeping its harness session, and
`job.rate_limited` names the credential, the window and the reset — **in the same fields and under
the same stamp as a harness report**, so the windows read it as one. The timeline's own copy of
the report is unacked, and lost, it would leave the pick believing the credential free and
sending the job straight back to it. Its machine is released. On the next pass the pick decides exactly as at any later start: another credential
free, and the job moves and starts again at once; none, and it waits until the earliest reset,
after which the next pass starts it. Nobody is asked to do anything either way; the ticket stays
active and out of the queue, as `capacity.md` § Four exhaustions requires of a pause that time
resolves.

**A resume the limit refused keeps its session.** Refused before the harness started, it looks
like a resume that never got going — no model, nothing done — which the platform re-queues fresh,
throwing the session away. The limit is asked first.

**Where it resumes.** The scheduler already offers a job to the machine that last ran it first
(`provisioning.md` § Affinity on resume). There the harness session is still on disk and the run continues
with `--resume`, on whichever credential the pick gave it. Anywhere else — the old machine
reclaimed while the job waited — the worker puts back the session file the last run uploaded
(`claude-code-events.md` § Resume). One that cannot be put back, or that the harness refuses, is
a resume that never started, which the platform re-queues as a fresh run
(`Forge.Jobs.complete/2`).
A fresh run starts from the branch, which holds everything the stopped run did: `decisions.md`'s
rule that resuming reconstructs from the branch and the manifest, never from the conversation.

**A job waiting for a reset holds no machine, and does not keep other machines up.** The idle
sweep ran only on a pass with nothing pending, and a job waiting for a reset *is* pending: one
limited job would have kept every idle machine on the node alive for as long as it waited, a
week for a weekly limit. The sweep now runs at the end of every pass whatever is pending
(`docs/design/worker-tier.md` § Idle destroy), so a limited job, which is given no machine, holds
none up. It records `limited` as its wait reason (`docs/design/provisioning.md` § The gate),
without a reset time: the reason is recorded once, and the soonest reset can move while it stays
`limited`, so a time in the sentence would go stale.

**What it leaves alone.** A resumed run gets its state's budget again, as a job resuming after a
question already does; the ticket allowance and the daily cap, which include the stopped run's
cost, bound the total. A conversation is not re-queued by itself: a person is in it, it goes
dormant as it does on any ending that was not the person's, and the pick applies when it is
opened again.

## Spend

**A credential's spend is a query over the runs that used it.** A job starts once or many times —
after a question, after a lost machine, after a limit — and each start is a **run**:

```
job_runs
  job_id         the job
  credential_id  what this run spent; nullable only for runs from before credentials
  worker_id      where it ran
  started_at     when this run started
  cost_usd       what it cost, recorded when it reports
  finished_at    set when it reports
```

A run is inserted in the transaction that marks its job running, and costed when it reports: a
workflow job's result, a conversation's turn. **A credential's figure for today is the sum over
its runs that started today in UTC**, and `Forge.Spend.day_total/1` sums the same rows for the
node, so the two add up rather than disagree about the edge of a day.

`jobs.credential_id` stays, as the credential the job is on *now*, which is what the pick reads.
It stopped being what spend is read from when a job became able to move: summed over jobs, a job
that ran on two credentials would have put all of its cost on the one it ended on. The old query
also put a job that resumed the next day wholly on the day it first started; per run, each day
has what was spent in it. The migration writes one run per job that ever started, with its
credential and its whole cost at its first start — exactly what both figures said before it.

`daily_limit_usd` is shown beside it and **enforced nowhere**, as `identity.md` § Credentials
decided. The ticket allowance and the node-wide daily cap keep enforcing exactly as before. The
pick does read spend, but only to prefer a credential; a credential over its limit is still
picked when it is the only one. `Forge.Credentials.spent_today/2` is the query.

Each row on `/users/settings` says what the credential spent today, the limit beside it with
*not enforced* written out, and *rate-limited until* the reset when it is (`ui.md` § Account
settings). That is what an owner with several credentials in a pool reads to see which one the
pool is leaning on.

## Showing the windows

Two places, both drawn by `capacity.md`'s rules — the gauge only from a utilization the provider
reported, the countdown from any known reset, neutral and never accent.

- **Each row on `/users/settings`** carries its credential's windows: five-hour and weekly, each
  with its utilization when one was reported, its reset, and *rate-limited* in warning colour
  while it blocks. A credential that has never reported a window — an API key, as far as
  anything recorded here shows — draws none.
- **The top bar** carries a small gauge for the five-hour and the weekly window **of a set of
  credentials, chosen by the page**: on a page about a project — the project, a ticket, a job, a
  conversation in it — that project's pool, which is what its work draws on; everywhere else the
  viewer's own credentials. For each window the gauge is the **mean utilization** of the
  credentials in the set that have reported one, a limited credential counting as full, beside a
  countdown to the **soonest reset** in the set. What it averages over is said in its title —
  *2 of 3 reporting*: of the credentials that have a known window of that kind, how many gave a
  utilization — because a mean over the ones that happen to have reported is a different claim
  from one over all of them. A set in which nothing has reported a window draws nothing.

A project's pool holds other people's credentials, and the gauge over it is an aggregate of their
accounts' usage. That is shown to the project's members, whose work those credentials fund; with
one other person's credential in a pool, the aggregate is that person's usage, which is accepted
as the price of the gauge meaning *what this project can still draw on*. The rows on
`/users/settings`, which name a credential, stay the owner's alone.

## Delivery to the machine

The assignment gains a `credential`: its harness, its kind and its secret — **sealed for that
worker and that job**. The platform opens the Vault and seals again for the wire in one function,
so the plaintext never sits in an assignment map, a channel process's state or mailbox, or a crash
report of any of them.

- **The key is the worker's token.** The platform keeps the SHA-256 of a worker's token
  (`Forge.Workers.create/1`), and the worker holds the token and can compute the same digest; the
  key is derived from that digest. AES-256-GCM, a random nonce per seal, the job id as associated
  data so a sealed credential cannot be replayed into another job.
- **The worker opens it at spawn, inside the harness driver's credential function** — the same
  zero-arity function `ForgeWorker.Harness` already accepts so a secret never sits in process
  state. The runner, the conversation process and the channel process hold ciphertext only.
- **What this buys is logs and crash reports, not a second layer against the database.** Whoever
  can read `workers.token_hash` and a captured assignment can open it. Before this the machine's
  token was in its environment file, readable by root on that machine, for the machine's whole
  life; now it is in a job's environment for that job's run, which the agent could always read.
- **And in that job's environment only.** It went to the unit as `--setenv`, and a unit's
  environment is a property systemd shows every user on the machine, so every other job there
  could read it while the job ran. It now reaches the process through a file the unit is handed
  with `LoadCredential=`, as every secret does (`worker-tier.md` § The job slice,
  `secrets.md` § Delivery).

One implementation of the seal, in `forge_core`, used by both ends: two implementations of a
cipher that have to agree are two places to disagree.

## What a worker offers now

**A harness, not an account.** The `ready` probe keeps `claude --version` and the aliases and drops
the models request and `login`, both of which were questions about the machine's token. It adds
`"credential": "per_job"`, which is the worker saying it takes its credential from the assignment.

**The gate matches a job's harness against a worker's.** A worker serves a job when it reported
that harness and per-job credentials. **One that reported no harness takes no inference job**, and
that inverts the trap `worker-channel.md` § Open records: that a worker reporting no harness must
stay assignable, because filtering it out would idle the fleet on a network blip. That trap was
about the models request, which could fail; what remains of the probe cannot, so a current release
always reports a harness. A worker that reports none is running a release older than this, which
would ignore the assignment's credential and run the job on whatever is in its own environment — a
job the platform would then record against a credential it did not spend. Taking no work is the
honest answer, and the workers page says why.

A job's harness is `claude_code`, for both kinds that exist. The workflow grammar has no field for
it yet; when it does, the job's harness comes from there and nothing else in this note changes.

## The node's own key is gone

`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` in the platform's environment are **not read**.
Not as a fallback and not as a seed.

- **Not a fallback**, because a credential nobody owns that funds any job whose project has none
  is the node-wide substitution `provisioning.md` § Whose account removed for machines, arriving
  again for inference: work runs, on money nobody chose to spend on it, and no surface says so.
- **Not a seed**, because a secret read from the environment on some boot and written into
  somebody's account is a thing that happened to a person without them doing it, and a seed that
  runs only while the table is empty is a rule nobody will remember the day it matters.

**On upgrade, a node that ran on the environment's key stops running jobs until a person adds a
credential.** Every ticket sticks with *no credential is assigned to this project* — visible, in
the queue, saying what to do — and comes back by itself once one is assigned (§ How a job picks).
That is a stop, and it is deliberately a loud one: the alternative was every existing node
continuing to spend a key whose owner the product cannot name.

What the operator does, once: open `/users/settings`, add the token as a credential, assign it to
the projects it should fund. The variables can then be removed; leaving them set does nothing.

Machines are the other half of the upgrade. A worker made before it holds the old key in its
environment and a release that does not take one from an assignment, so it takes no inference job
(§ What a worker offers now): a managed one idles out and its replacement boots the new image, and
a permanent one needs `bin/worker-update`.

## Deliberately not here

- **Enforcing `daily_limit_usd`.** `identity.md` § Credentials decided it is tracking.
- **Holding a machine through a wait.** A job waiting for a reset lets its machine go, and its
  session goes with the job rather than the machine (`claude-code-events.md` § Resume). Holding
  the machine would save a download at the price of an idle machine billing for up to a week.
- **A conversation resuming by itself after a limit.** A person is in it, and they decide when it
  goes on; the pick moves it to a free credential when they do.
- **A pick weighted by anything but spend.** Least spent today is a spread, not a schedule; a
  pool whose members differ in size (an API key against a subscription) is served by the owner
  assigning the right ones.
- **Refusing to pool a subscription across people.** A subscription is individual-use, and
  assigning one to a project other people work in lets their jobs spend it. The owner does that
  on purpose now, where before it happened because a machine was shared; that is narrower, and it
  is still `identity.md`'s residual rather than something decided here.

## Sequencing

1. This note, and the notes it changes.
2. **Built.** `credentials`: the table, the seal, the check on save, revocation, and the section
   of `/users/settings` that lists, adds, checks and revokes them (`ui.md` § Account settings).
   Nothing funds a job from them yet.

   Two things it found on the way, both the same class as the credential itself. **A template
   could name somebody else's provider credential**: `Template.changeset/2` checked the
   credential's provider and not its owner, so an id off the wire made a template that created
   machines in another person's account. And **a typed token went back into the page**: the
   provider-credential form on `/templates` assigned every field of every `phx-change`, and
   `<.input>` renders a password field's value like any other, so the token sat in the
   LiveView's state and in the HTML. Both are closed, and `password`, `secret` and `token` are
   now all filtered from the request and event logs, where Phoenix filtered only the first.
3. **Built.** Machines have owners: `workers.user_id`, `project_worker`, the owner-only rule, a
   machine made from a template reaching the projects its template is assigned to, the gate
   matching a job's project, `/workers` showing the caller's own machines, and placement sticks
   that come back. `WorkersHaveOwners` backfills an existing node so that, with one operator,
   nothing visible changes: a machine made from a template is its owner's, any other is the only
   node admin's and serves every project they are in. With more than one node admin it will not
   guess, and `Forge.Release.own_worker/2` is the repair. Assigning a template, and leaving a
   project, are now in the event log and take effect on the leaver's templates and machines.
4. **Built.** The job holds the credential: `project_credential`, `jobs.credential_id`, the
   credential in the assignment sealed by `ForgeCore.Job.Credential`, the worker opening it at
   spawn (`ForgeWorker.Job.Credential`), the probe without an account, the gate on harness and
   `per_job`, model pickers reading the pool, and the node's key read by neither the platform nor
   a worker. The pick was *oldest first* until step 5. `mix forge.e2e.chat` asks for a credential
   in the project's pool and checks the conversation ran on one, which is the one place this is
   exercised against a real harness — and it cannot run in the gate.
5. **Built.** Spend and limits: the per-credential spend query over `Forge.Spend.day/1`'s day,
   `rate_limit_event` mapped to `harness.rate_limit` and stamped with the job's credential, the
   pick that passes over limited credentials and prefers the least spent today, a job that waits
   for its own credential's window rather than leaving it, and the readout on
   `/users/settings`. Everything limited leaves the job pending and the ticket active, which the
   scheduler already did for any answer that was not a stick; it is now asserted rather than
   inherited.

   What it found is the claim this note's § Rate limits records: `claude-code-events.md` called
   the mapping done while the driver dropped the message into `harness.unknown`, so nothing on
   the node had ever read a window. And one it closed before it opened: the event's payload is
   the worker's, so a stamp that kept a `credential_id` already present would have let one
   machine mark somebody else's credential limited.
6. This note's second revision: a job moves off a limited credential when another is free,
   § A limit reached mid-run, the run ledger in § Spend, windows per type, and § Showing the
   windows. It reverses step 5's *a job waits for its own credential*, on request, before the
   evidence § Deliberately not here named for it had arrived.
7. **Built.** Windows per type: `Forge.Credentials.windows/2`, the latest report per credential
   *and* `rateLimitType`, `unifiedWindows` mapped by the driver, and a credential limited until
   the last of its blocking windows resets. This closes the hole step 5 left, where a five-hour
   `allowed` hid a weekly block.

   Two things the tests settled rather than the design. A report with no usable type is a window
   of its own, `unknown`, so that a blocking one still blocks. And the rows come back from the
   query ordered by type, not by age — a report typed `7` before one with none — so which of two
   such reports is newer is read from its sequence, never from where it arrived.
8. **Built.** The run ledger: `job_runs` and `Forge.Jobs.Runs`, opened where a job is marked
   running and closed wherever it stops — a result, a failure, a cancel, a lost machine, a
   restart, a resume that never started, an assignment that never arrived, a conversation's end —
   `CreateJobRuns`' one run per started job, and both spend figures read from it.

   What it found: **a reopened conversation forgot what it had spent.** A turn's figure is its
   process's running total and was *set* on the job row, which is right within one process; a
   reopening is a new process, and its first turn replaced everything before it. The job's cost
   is now the sum of its runs, and a turn sets its own run's.
9. **Built.** A limit reached mid-run: the runner's `rate_limit` in the result, the job back to
   pending with its session and `job.rate_limited`, its machine released and its git token
   revoked, the pick moving a job off a limited credential, and the idle sweep no longer held off
   by a job waiting for a reset.

   What building it settled that the design had not: `job.rate_limited` is itself a window report,
   because the pick otherwise depended on an unacked event to know the credential was limited;
   and the limit is asked before a failed resume, because a resume the limit refused is
   indistinguishable from one whose session was gone. How a real limit reads is still the
   third-party accounts' — `worker/test/support/fake_claude.sh`'s `rate_limited` scenario is built
   from them — and the first real exhaustion is what checks it.
10. **Built.** Showing the windows: a line per reported window on each `/users/settings` row, and
    the gauge in the top bar — `Forge.Credentials.gauge/2` for the figure, `ForgeWeb.Capacity`
    for whose credentials, mounted on every approved page and switched to the project's pool by
    the six pages about one, after each has allowed the viewer.
