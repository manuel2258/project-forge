# Core data model

Scope: what the platform persists — milestone 1's tables, and what conversations, the worker
tier, identity, provisioning and inference credentials added to them. Users, roles and workers were present from the
start so that team use and the worker tier would be additions, not rewrites; the one that did not
survive is `users.role`, which project membership replaced (see **user**). All ids are UUIDs.
Times are UTC.

## Entities

**project** — `name`, `repo_path` (bare repository on the orchestrator; the API only ever
sets `<repos_dir>/<name>.git`, an arbitrary path needs the command line), `default_branch`,
`seed_id` (the seed a worker fetches for this project, set by `mix forge.seed.publish`; null means
none was ever published and the job clones cold — `design/storage.md`), `model` and `effort` (the
project's defaults when a state names neither; null means the machine's).
A mirror is deliberately **not** a column: it lives in the repository's own `git config` under
`forge.mirror.<name>.url`, because the `post-receive` hook is what pushes it and a hook can read
only git config. See `design/git-hosting.md`.

**ticket** — `project_id`, `number` (per project, human-facing, allocated under a lock on
the project row), `title`, `body`, `base_commit`, `branch` (`ticket/<number>`), `workflow`
(parsed definition, JSON), `workflow_commit`, `state` (a state name from the pinned
workflow), `status` (`active | stuck | done | cancelled`), `cost_usd` (denormalised sum
over jobs), `pending_transition` (set while a transition waits for approval).

**job** — one execution of one job state, one command invocation, or one conversation. `kind`
(`workflow | command | chat`), `project_id`, `ticket_id`, `state`, `attempt` (per ticket and state
for a workflow job, per ticket for a command), `parent_job_id` (the job that invoked a command;
null otherwise),
`spec` (immutable, JSON: prompt text and path, inputs with name, version and content inlined, `env`,
`commit`, budgets, permitted children, which is empty in v1; `answers.md` and the answered keys are
added at run time, not stored; a command's is its script, argv, commit, env and timeout),
`status` (`pending | running | waiting | parked | hibernated | finished` — `parked` is a job waiting
on commands it invoked, holding no slice: `design/commands.md` § Always park), `exit_status` (a
command's, null for every other kind and for a command that ended without one),
`outcome` (`converged | did_not_converge | budget_exhausted | error | cancelled`, null until
finished), `declared_outcome` (the workflow outcome the agent selected, null unless converged),
`exhausted` (`turns | cost | wall_clock` — which ceiling stopped a `budget_exhausted` job, null
for every other and for one whose worker was too old to say; `design/capacity.md` § Four
exhaustions, three treatments), `turns`, `cost_usd` (what the job has used and what
its runs have cost between them — a conversation's read from them with `Runs.total/1`, a workflow
job's added up as each run reports; see **job_run** — and both running totals over every
invocation the job has had, so neither is commensurate with `spec.budget`, which is one
invocation's ceiling),
`harness_session_id` (opaque, nullable, an optimisation only), `session_blob` (the latest session
file the worker uploaded — its store key and the Claude Code version that wrote it — which a resume
on another machine puts back; `design/claude-code-events.md` § Resume), `resume_from_id` (the
previous attempt of the state whose session a new attempt forks, set when the ticket came back to
a state that attempt finished in, and cleared when a resume is refused), `worker_id` (nullable),
`credential_id` (the inference credential its current or last run spent, nullable until it first
starts), `model` and `effort` (a conversation's, chosen when it was opened; a workflow job's are
its state's and are not on the row), `memory_max` and `cores` (what the scheduler gates on,
resolved once at creation and never rewritten — `design/provisioning.md` § What a job asks for), `secret_names` (the project
secrets it asks for: its state's or command's `secrets`, or what was picked for a conversation —
names only, resolved to values at each assignment; `design/secrets.md` § Delivery), `started_at`,
`finished_at`.
Its timestamps are sub-second: jobs are read back in creation order and that order is the ticket's
timeline, so two jobs created within one second must still be ordered.

A chat is a job with a project, no spec and — unless it is a chat step — no state, and a ticket only when it is a ticket
chat — `design/conversations.md` § Shape. `ticket_id`, `state` and `spec` are therefore nullable,
and the CHECK constraint `jobs_kind_shape` is what says which shape a row must have: a workflow
row and a command row carry all three, a chat row has no spec and has a state only when it is a
chat step (`conversations.md` § A conversation that is a step), which needs a ticket. The `(ticket_id, state, attempt)`
unique index is partial, over workflow rows, because Postgres treats NULLs as distinct and would
otherwise constrain nothing.

**artifact** — `ticket_id` or `job_id` (exactly one, by the CHECK `artifacts_one_scope`: a
project conversation's documents and every conversation's proposals belong to the conversation,
and a ticket conversation's documents to its ticket — `design/conversations.md` § Commits), `name` (as in the workflow, e.g.
`plan.md`), `kind` (`document | blob | presentation`). Unique per scope and name, by two partial
unique indexes — one over rows with a ticket, one over rows with a job. Holds no content. The
`changeset` is a blob artifact whose versions record the branch head (`git:<sha>`) when a
job that produces it finishes, so approval attaches to an exact commit.

**artifact_version** — `artifact_id`, `version` (1, 2, 3 per artifact), `author`
(`{job, id}`, `{user, id}` or `{api, id, name}` — a project token, its name carried so a revoked one reads the same), `content` (documents: the text), `blob_uri` (blobs),
`content_hash`, `meta` (parsed front matter, JSON), `inserted_at`. Never updated or deleted.

**question** — `artifact_version_id`, `key` (stable within the document), `anchor` (the
passage it concerns), `text`, `options` (`jsonb`: a list of `{label, detail, recommended}`, at
most one recommended), `blocking` (bool), `assumption` (non-blocking only: what the job proceeded
with). Extracted from a document version at write time. There is no `default` column: the
recommendation is a flag on its option.

**answer** — `question_id`, `user_id` or `token_id` (exactly one, by a check constraint), `choice` (one of the question's labels, or nil), `text`
(free-form: the whole answer without a choice, a note beside one),
`artifact_version_id` of the `answers` document version that records it. Answers are
themselves versioned, attributed artifacts; this row is the queryable index.

**approval** — `artifact_version_id`, `user_id` or `token_id` (exactly one), `decision` (`approved | rejected`),
`comment`, `transition` (`{from, to}`), `inserted_at`. Approval attaches to a version. A
newer version has no approval until it gets one.

**proposal_decision** — `artifact_version_id` (unique), `user_id` or `token_id` (exactly one), `ticket_id` (set exactly
when accepted), `decision` (`accepted | declined`), `comment`. A person's decision on one ticket
proposal. Deliberately **not** an `approval`: `approvals.transition` is required because an
approval authorises an edge in the statechart and the engine reads it against a ticket's
`pending_transition`, and a proposal has no edge — what it authorises is admission. See
`design/ticket-proposals.md` § Deciding.

**event** — `seq` (bigserial), `project_id`, `ticket_id`, `job_id` (all nullable; `project_id`
is denormalised so "the events I may read" is one indexed query, and null means node-wide, which
only a node admin reads — `design/identity.md` § Read scoping is the half that leaks), `actor`
(`system`, `{user, id}`, `{job, id}` or `{api, id, name}`), `type` (dotted, e.g. `ticket.admitted`,
`job.started`, `job.harness.tool_use`, `question.answered`, `transition.taken`),
`payload` (JSON), `inserted_at`. Append only.

**user** — from the Phoenix auth generator: `email`, `hashed_password` (null for an account
that only logs in through an identity provider), plus `node_admin` (account governance only:
approve, suspend, promote; it reaches no project), `approved_at` and `suspended_at` (an account
acts only when approved and not suspended). The `role` column this entry once had
(`operator | approver | promoter | spender`) was dropped by `20260916100000`: what a user may
reach is per project, in **project_member**. See `design/identity.md` § Approval.

**identity** — `user_id`, `issuer`, `subject` (unique together), `email` (as claimed at the last
login, for display, never looked up by), `last_login_at`. An account at an external issuer; a
user has zero or more. `design/identity.md` § Identity is `(issuer, subject)`, never email.

**project_member** — `project_id`, `user_id` (unique together), `role` (`admin | member`).
`admin` is settings, deletion and membership; `member` is everything else. `Forge.Access` expands
the role into capabilities, and all but two readers go through it — `Projects`' last-admin rule
compares `:admin` by name (`design/identity.md` § The capability seam). `design/identity.md`
§ Projects and members.

**push_subscription** — `user_id`, `endpoint` (unique), `p256dh`, `auth`, `last_sent_at`. One
browser's Web Push subscription.

**worker** — `provider`, `provider_id`, `status` (`creating | ready | busy | idle | destroyed`),
`token_hash`, `memory_budget`, `cores`, `accepts` (the job kinds it takes), `managed` (whether the
platform made it and may destroy it — `design/worker-tier.md` § Managed and unmanaged), `harness`
and `reported` (what the machine said about its harness and about itself at `ready`, verbatim;
recorded, not scheduled on), `last_error` (what the driver said about a create that never became a
machine), `idle_since`, `last_seen_at`, `template_id` and `provider_credential_id` (provenance: the
recipe and the account it was made from, both null for a permanent machine, minted by
`Forge.Workers.mint/2`), `user_id` (its owner: the template's for a machine the platform made; for
a permanent one, whoever minted it from `/workers`, whoever the host named with `mix
forge.worker.new --owner` or `Forge.Release.new_worker/2`, or whoever adopted it).

**provider_credential** — `user_id`, `name` (unique per user), `provider`, `secret`. An account
at a machine provider (e.g. Hetzner) that a user owns; `secret` is a driver-shaped map encrypted
by `Forge.Provisioning.Vault` and never rendered. Not a harness credential.
`design/provisioning.md` § Whose account.

**worker_template** — `user_id`, `provider_credential_id` (null for a provider that needs no
account), `name` (unique per user), `provider`, `size` and `image` (opaque above the driver),
`memory`, `cores`, `accepts`, `max_workers`, `idle_ms`, `failures` (consecutive machines it
failed to make; disabled is derived from it, not stored) and `last_error`. A recipe: its values
are copied onto a worker at creation and never read back through. `design/provisioning.md` § Two
tables, and the second is only a recipe.

**project_template** — `project_id`, `template_id` (unique together). A template a project may
have machines made from, assigned by the template's owner.

**project_worker** — `project_id`, `worker_id` (unique together). A permanent machine a project
may run its jobs on, assigned by the machine's owner; one the platform made reaches projects
through its template instead. `design/identity.md` § Workers.

**credential** — `user_id`, `name`, `harness`, `kind` (the harness's kinds of secret — for Claude
Code `oauth` or `api_key`), `secret` (encrypted, never selected by default), `daily_limit_usd`,
`models` (what the check on save found it may use), `checked_at`, `check_error`, `revoked_at`. An
inference credential: what an agent authenticates with, owned by a user and never by a machine.
Revoked rather than deleted, because spend stays attributed to it. `design/credentials.md`.

**project_credential** — `project_id`, `credential_id` (unique together). A project's pool: the
credentials its jobs may be paid for with, assigned by each credential's owner.

**project_secret** — `project_id`, `name` (unique among the project's live ones), `value`
(encrypted, never selected by default), `version`, `set_by_id`, `set_at`, `deleted_at`. A value a
project's jobs may be handed and the platform never uses, written by a project admin. Deleted
rather than removed, and deleting destroys the value. `design/secrets.md`.

**job_run** — `job_id`, `credential_id`, `worker_id`, `started_at`, `finished_at`, `cost_usd`. One
process of a job: a resume, a requeue or a reopened conversation is a new run. Spend is recorded
here per credential, set from the harness's running total for that process (`Forge.Jobs.Runs`).

**git_token** — `project_id`, `ticket_id`, `job_id` (the last two nullable), `token_hash`,
`ref` (the one ref a `branch` token may update: `refs/heads/ticket/<n>` for a ticket's job,
`refs/heads/chat/<uuid>` for a conversation, or the project's default branch for the older
default-branch token, which no job is ever given), `name`, `git_access` (`none`, `reader`,
`branch`, `developer`, `admin`), `api_access` (`none`, `read`, `write`), `issued_by_id`,
`last_used_via` (`git`, `api`, or `archive` for a job's read of `docs/design/archive.md`),
`expires_at`, `revoked_at`, `last_used_at`. Answers, approvals
and proposal decisions have a `token_id` beside `user_id`, exactly one of the two set. The credential the git endpoint accepts. Not a user token: no user,
a ref rather than an account for a scope, and a job rather than "until revoked" for a lifetime.
Rows are revoked rather than deleted, because they are the audit trail behind the
`token.issued` and `token.revoked` events.

**merge_queue_entry** — `project_id`, `ticket_id` (unique: a ticket is queued once), `position`
(a database sequence, the order approvals were recorded in), `status` (`waiting`, `merging`,
`integrating`), `from_state`, `to_state`, `edge_outcome` (the edge's own outcome, to pick it again by
`ForgeCore.Engine.choose/4` among parallel edges), `outcome` (the job's outcome behind it, nil for a
person's choice),
`changeset_sha`, `changeset_version`, `commit_message_version` (what was current at the approval, replaced by the integrated changeset and
the latest message when an integration puts the row back in the line),
`approval_ids` (the approvals it recorded, so that exactly those are withdrawn), `entered_by`, `comment`. A
ticket has a row exactly while it is in the merge queue and rows are deleted when it leaves, so the
events (`merge_queue.entered`, `.returned`, `.taken_out`, `.left`) are the history. A partial unique
index on `(project_id) where status = 'merging'` is the guard on one merge at a time
(`workflow-grammar-v1.md` § The merge queue). An **approval** has a `withdrawn_at`: set when taking
the ticket out of the queue withdrew it; the row stays.

## Statechart persistence

The ticket's current state is `ticket.state`. The history is the `transition.taken` events.
There is no in-memory statechart: the engine is a pure function
`(workflow, state, outcome, transition_counts) -> transition | :stuck`, and every application
of it writes the ticket row and an event in one transaction.

The platform runs no job processes. A job is a process only while `status` is `running`, and
that process is on the worker it was assigned to: one supervised process per job there, keyed
by job id. A job in `waiting` (blocked on a human) or `hibernated` has none anywhere.
On boot, `Forge.Jobs.recover/0` deals with the rows a previous node left `running` that no
machine can report on any more — on a destroyed or missing worker row: a workflow job goes back to
`pending` for the scheduler to place again, a conversation goes `hibernated` until a person
resumes it. Every other `running` row is left for its machine to report on at its rejoin
(`docs/design/worker-channel.md` § A platform restart). Answering a waiting job's blocking questions sets it `pending` too; its next
run rebuilds from the branch and the manifest.

## Invariants

- A job's `spec` is written once. Resumption reads it; nothing rewrites it.
- `artifact_version` rows are insert-only. Editing is a new version. Human edits carry a user
  author.
- The input manifest references versions, so a job's basis is answerable after later
  versions exist. The job view flags inputs that have newer versions.
- Approvals, answers and transitions reference specific versions, never "latest".
- Every mutation writes an event in the same transaction. `event` and `artifact_version`
  rows are append-only, enforced by a database trigger.
- Recording a job's result never depends on what follows it: the result is one transaction,
  the engine's decision another; a follow-up that fails sticks the ticket with the reason.
- A job whose ticket moved on while it ran (a person took a transition) is recorded as
  orphaned and decides nothing. Human transitions are refused while a job for the current
  state is live.
- Budgets in `spec` are copied from the pinned workflow at job creation and the row is never
  rewritten. The *effective* cost budget a run is handed is the least of what the spec declared,
  what the ticket allowance has left and what the daily cap has left, computed at start and
  recorded as `job.budget_lowered` when it differs. The turn budget is the spec's, always.

## Not in v1, but shaped for

`parent_job_id` and `spec.permitted_children` carry subagents. `worker_id` carried the
worker tier, which has since arrived. `role` was to carry multi-user; it was dropped for
`node_admin` and `project_members` when multi-user arrived.
