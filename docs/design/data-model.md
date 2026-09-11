# Core data model

Scope: what milestone 1 persists. Users, roles and workers are present from the start so team
use and the worker tier are additions, not rewrites. All ids are UUIDs. Times are UTC.

## Entities

**project** — `name`, `repo_path` (bare repository on the orchestrator), `default_branch`.

**ticket** — `project_id`, `number` (per project, human-facing), `title`, `body`,
`base_commit`, `branch` (`ticket/<number>`), `workflow` (parsed definition, JSON),
`workflow_commit`, `state` (a state name from the pinned workflow), `status`
(`active | stuck | done | cancelled`), `cost_usd` (denormalised sum over jobs).

**job** — one execution of one job state. `ticket_id`, `state`, `attempt` (per ticket and
state), `parent_job_id` (null in v1), `spec` (immutable, JSON: prompt path and content hash,
input manifest as `[{artifact_id, version}]`, `env`, `commit`, budgets, permitted children,
which is empty in v1), `status` (`pending | running | waiting | hibernated | finished`),
`outcome` (`converged | did_not_converge | budget_exhausted | error | cancelled`, null until
finished), `declared_outcome` (the workflow outcome the agent selected, null unless converged),
`turns`, `cost_usd`, `harness_session_id` (opaque, nullable, an optimisation only),
`worker_id` (nullable), `started_at`, `finished_at`.

**artifact** — `ticket_id`, `name` (as in the workflow, e.g. `plan.md`), `kind`
(`document | blob | presentation`). Unique per ticket and name. Holds no content.

**artifact_version** — `artifact_id`, `version` (1, 2, 3 per artifact), `author`
(`{job, id}` or `{user, id}`), `content` (documents: the text), `blob_uri` (blobs),
`content_hash`, `meta` (parsed front matter, JSON), `inserted_at`. Never updated or deleted.

**question** — `artifact_version_id`, `key` (stable within the document), `anchor` (the
passage it concerns), `text`, `options` (list), `default`, `blocking` (bool),
`assumption` (non-blocking only: what the job proceeded with). Extracted from a document
version at write time.

**answer** — `question_id`, `user_id`, `choice`, `text` (free-form, optional),
`artifact_version_id` of the `answers` document version that records it. Answers are
themselves versioned, attributed artifacts; this row is the queryable index.

**approval** — `artifact_version_id`, `user_id`, `decision` (`approved | rejected`),
`comment`, `transition` (`{from, to}`), `inserted_at`. Approval attaches to a version. A
newer version has no approval until it gets one.

**event** — `seq` (bigserial), `ticket_id`, `job_id` (both nullable), `actor`
(`system`, `{user, id}` or `{job, id}`), `type` (dotted, e.g. `ticket.admitted`,
`job.started`, `job.harness.tool_use`, `question.answered`, `transition.taken`),
`payload` (JSON), `inserted_at`. Append only.

**user** — from the Phoenix auth generator: `email`, `hashed_password`, plus `role`
(`operator` only in v1; `approver`, `promoter`, `spender` reserved).

**worker** — `provider`, `provider_id`, `status`, `token_hash`, `memory_budget`,
`last_seen_at`. Empty until milestone 3; the local worker manager registers as one row.

## Statechart persistence

The ticket's current state is `ticket.state`. The history is the `transition.taken` events.
There is no in-memory statechart: the engine is a pure function
`(workflow, state, outcome, transition_counts) -> transition | :stuck`, and every application
of it writes the ticket row and an event in one transaction.

Live jobs are processes only while `status` is `running`: one supervised process per job,
registered by job id. A job in `waiting` (blocked on a human) or `hibernated` has no process.
On boot, any job still marked `running` is set to `hibernated`; resume rebuilds it from the
branch and the manifest. Transitions from `waiting` back to `running` start a new process.

## Invariants

- A job's `spec` is written once. Resumption reads it; nothing rewrites it.
- `artifact_version` rows are insert-only. Editing is a new version. Human edits carry a user
  author.
- The input manifest references versions, so a job's basis is answerable after later
  versions exist. The job view flags inputs that have newer versions.
- Approvals, answers and transitions reference specific versions, never "latest".
- Every mutation writes an event in the same transaction. In production the database role the
  platform uses has no `UPDATE` or `DELETE` on `event` and `artifact_version`.
- Budgets in `spec` are copied from the pinned workflow at job creation and are never read
  from anywhere else afterwards.

## Not in v1, but shaped for

`parent_job_id` and `spec.permitted_children` carry subagents. `worker_id` carries the
worker tier. `role` carries multi-user. `artifact.kind = presentation` exists but nothing
renders it yet.
