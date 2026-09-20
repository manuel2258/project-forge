# Git hosting

Scope: how the platform serves, guards and mirrors the repositories it owns, and how a ticket's
branch becomes a commit on the default branch. This note is the standard for milestone 4 — code
follows it, and a change of mind updates it first.

The governing idea, from `vision.md`: the platform hosts its own repositories so merge approval is
a state in the machine rather than a link to somewhere else, hooks enforce the branch discipline
mechanically rather than by convention, and a repository is never on only one machine.

## What is served

One scope, `/git/<project>.git/...`, served **before the router** from the endpoint. It takes
HTTP Basic with a per-job token, not the operator session and not the API bearer, so neither
router pipeline fits it; and the request body is a packfile that has to reach `git http-backend`
unread, which is not what a pipeline ending in `Plug.Parsers` is for.

Exactly three paths answer. Everything else is `404`:

| Request | Service | Needs |
|---|---|---|
| `GET /git/<p>.git/info/refs?service=git-upload-pack` | advertise for fetch | read |
| `GET /git/<p>.git/info/refs?service=git-receive-pack` | advertise for push | write |
| `POST /git/<p>.git/git-upload-pack` | fetch | read |
| `POST /git/<p>.git/git-receive-pack` | push | write |

**The dumb protocol is not served.** No `/objects/...`, no `/HEAD`, no `/objects/info/packs`.
Those paths let a reader walk loose objects without ever naming a service, which is a bypass of
the one place capability is checked. A client that cannot speak the smart protocol is a client
from before 2010.

`PATH_INFO` is assembled from the *resolved project's* repository basename plus one of the four
tails above — never from the raw request — so `GIT_PROJECT_ROOT` cannot be traversed to a sibling
repository.

## How a repository comes into being

`Forge.Projects.register/2` reserves the name in the database **before** it touches the
filesystem. The `unique_constraint` on `name` is the authority on who owns a repository path, so
a registration for a name that already exists fails at the insert and the git steps — `init_bare`,
the hooks, `symbolic-ref HEAD`, the initial commit — never run. Without this ordering a second
caller, a member of nothing, could register an existing project's name and, before the uniqueness
check rejected them, rewrite that project's `HEAD` and `forge.defaultBranch` (desyncing the
default-branch guard § The per-job token depends on) and leave its clones empty. The guard is the
**name, not the directory**: a directory that already exists is imported as is (push first, then
register), which is why the check cannot simply refuse a pre-existing path. The git work runs last
and inside the transaction, so a failure rolls the row back and removes only a directory this
registration created — never an imported one.

`default_branch` is validated on the way in (`Forge.Projects.Project.changeset/2`), because it
reaches `git config forge.defaultBranch`, `symbolic-ref HEAD` and the pre-receive hook: an
unvalidated value such as `-rf`, `../evil` or one with a space either poisons the repository or
fails deep inside git as a 500.

## Why `git http-backend`

`git http-backend` is the smart protocol. Reimplementing `upload-pack` and `receive-pack` in
Elixir would mean owning protocol v2 negotiation, the ref advertisement, shallow and partial
clones, and `GIT_PROTOCOL` capability strings — the surface that fails subtly and late. The CGI
program is what every other self-hosted forge wraps, and it is one `System.cmd/3`.

### Talking to a CGI program from the BEAM

Erlang ports cannot half-close stdin and `System.cmd/3` offers no stdin at all, so a child that
reads its request body from stdin would block forever. All three of the child's streams are
therefore files:

```
sh -c 'exec git http-backend <"$1" >"$2" 2>"$3"' forge-git IN OUT ERR
```

The request body is streamed into `IN` a megabyte at a time with `Plug.Conn.read_body/2`, so a
push of any size costs a bounded amount of memory. The response is read back out of `OUT` with
`Plug.Conn.send_file/5` at the offset where the CGI headers end, so a clone's packfile goes
kernel → file → socket and never becomes a binary on the heap.

**Known limit:** the whole response is produced before the first byte reaches the client, so
there is no sideband progress during a clone. On a PoC that runs on one machine this is invisible.
The fix, when it stops being invisible, is a `Port` with `CONTENT_LENGTH` set — the child then
reads exactly N bytes and never waits for EOF — at the cost of incremental CGI-header parsing,
backpressure and client-disconnect handling on the stream. That is an upgrade, not a rewrite.

### The environment, and the one dangerous default

`System.cmd/3`'s `:env` **merges with the BEAM's own environment rather than replacing it**. The
platform process sets `FORGE_INTERNAL=1` when it performs a merge, and that variable is what the
`pre-receive` hook accepts as authority to write the default branch. If it leaked into a CGI
child it would let any client with a job token rewrite the default branch. Every `FORGE_*`
variable the wrapper does not set is therefore passed explicitly as `nil`, which removes it.
That is the single highest-consequence line in this note, and it has a test of its own.

What the wrapper does set:

| Variable | Value |
|---|---|
| `GIT_PROJECT_ROOT` | the repository's parent directory |
| `PATH_INFO` | `/<repo basename>/<whitelisted tail>` |
| `GIT_HTTP_EXPORT_ALL` | `1` — forge authorises, so no `git-daemon-export-ok` files |
| `REQUEST_METHOD`, `QUERY_STRING`, `CONTENT_TYPE`, `CONTENT_LENGTH` | from the request |
| `HTTP_CONTENT_ENCODING` | required: clients gzip upload-pack bodies, and `http-backend` inflates only when it sees this |
| `GIT_PROTOCOL` | required: without it every v2 client silently degrades to v0 |
| `REMOTE_USER` | `forge-job-<job id>`; becomes the reflog identity |
| `REMOTE_ADDR`, `SERVER_PROTOCOL`, `GATEWAY_INTERFACE`, `SERVER_SOFTWARE` | CGI hygiene |
| `FORGE_ALLOWED_REF` | the one ref this credential may write, e.g. `refs/heads/ticket/12` |
| `FORGE_TOKEN_ID`, `FORGE_TICKET_ID`, `FORGE_PROJECT` | identity for the hook's messages |
| `FORGE_INTERNAL` | **`nil`**, always |

`git http-backend` execs `receive-pack`, which execs the hooks, and custom environment variables
propagate untouched. This is convention rather than a documented contract, but it is the
mechanism GitLab uses for `GL_ID` and Gitea for `GITEA_PUSHER_*`, and it has been stable for as
long as either has existed.

## The per-job token

A git token is not a user token. It has no user, its scope is a ref rather than an account, and
its lifetime is a job rather than "until revoked" — so it is its own table, `git_tokens`, and only
the mechanics are borrowed from `Forge.Accounts.UserToken`: 32 random bytes, handed out once as
url-safe base64, stored as a sha256 hash, looked up by hash so no secret is ever string-compared.

- **Scope.** A project, a capability (`read` or `write`), and for a write token exactly one ref:
  `refs/heads/ticket/<n>` for a ticket's job, `refs/heads/chat/<uuid>` for a conversation, or the
  project's own default branch for the token an operator mints by hand (§ Issuing a token). A job
  is never issued the third.
- **Lifetime.** Absolute `expires_at`, the job's wall clock plus a margin. Absolute rather than
  computed from `inserted_at`, because a waiting job may legitimately need a longer one.
- **Issuance.** `Forge.Jobs.assign/2`, immediately before the job is handed to a worker — the
  single choke point every invocation passes. This was `start/1` while the platform ran jobs in
  its own BEAM; milestone 3 moved them to a worker and the choke point moved with them, which is
  the whole of what changed here (`docs/design/worker-tier.md` § Git).
- **Delivery.** In the assignment, and from there into the job's process environment as
  `FORGE_GIT_TOKEN`, through the runner's existing `{:secret, _}` path, so it reaches the
  environment and never argv — not the runner's, and not the transient unit's either, which names
  a secret without its value. **It is never written into the job's `spec`**, which is stored on
  the row forever. The worker holds it for the length of the job and dies with it.
- **Revocation.** When the job finishes or fails. A waiting job keeps its token; a resumed one is
  issued a fresh one. Rows are kept rather than deleted: they are the audit trail behind the
  `git.token.issued` and `git.token.revoked` events.

The username in the Basic credential is ignored; the convention is `forge:<token>` so the URL form
`http://forge:TOKEN@host/git/project.git` works with no credential helper.

## Hooks

Two generated scripts in every bare repository, rewritten at boot so an upgrade to a hook takes
effect on repositories that already exist. A generated file that is only ever written at creation
time is a landmine.

**Per-request facts travel in the environment; per-repository facts live in `git config`.** That
split is the rule and it is load-bearing. The allowed ref is per-request, so it cannot come from
config. The mirror must fire for a push the CGI never mediated — the platform's own merge — so it
cannot come from the environment. Repository config, under `forge.*`:

- `forge.defaultBranch` — explicit, though `HEAD` implies it.
- `forge.mirror` — a URL or a path; empty means no mirror.
- `forge.mirrorRefs` — a glob, default `refs/heads/<default>`.

There is deliberately **no `mirror_url` column on `projects`**: a column would be a second source
of truth that the hook, which is the enforcement point, cannot read.

### `pre-receive` — the branch discipline

- A ref is never deleted.
- Only branches are written.
- The default branch is written only with authority over it, and only fast-forward. Authority is
  either `FORGE_INTERNAL=1`, which the platform's own merge sets and the CGI strips from every
  request it serves, or a credential whose `FORGE_ALLOWED_REF` *is* the default branch — the shape
  § Issuing a token describes and only an operator can mint. So the default branch is
  fast-forward-only by construction, and no credential a job holds can move it.
- Any other branch must be exactly the credential's `FORGE_ALLOWED_REF`, and must be
  `refs/heads/ticket/<number>`. One branch per ticket, enforced rather than assumed.
- A push with no `FORGE_ALLOWED_REF` and no `FORGE_INTERNAL` writes nothing.

### Non-fast-forward on a ticket branch: allowed, recorded, and pinned

`decisions.md` says a job commits freely and history is squashed. The squash happens at merge, so
the common case is append-only — but a resumed job amending its last commit, or a rebase onto a
moved base, is a rewrite, and refusing those would fail the job's own recovery path with a git
error the agent cannot act on.

**So the ticket branch accepts a rewrite and the default branch does not.** The ticket branch is
scratch space with exactly one writer, and the record that matters is not the ref: it is the
`changeset` artifact version, which pins `git:<sha>` in the database and is what an approval
attaches to. A ref moving does not move an approval.

The residual risk is that a rewrite makes an approved commit unreachable and therefore
collectable, and the merge would then act on an object that has gone. Two things close it:

1. On approval of `changeset`, the platform writes `refs/forge/approved/<ticket number>` at the
   approved sha. Under `refs/forge/*`, so it is neither a branch nor mirrored, and the object is
   permanently reachable.
2. `Forge.Merge.perform/2` verifies the approved sha still resolves, and refuses loudly rather
   than quietly merging whatever the branch head happens to be now.

The rewrite is also visible: the hook prints a note the pushing client sees, and the CGI wrapper
turns the hook's stderr into an event.

### `post-receive` — the mirror

Reads `forge.mirror` and pushes the refs matching `forge.mirrorRefs` to it.

- **The mirror never fails the push.** git ignores `post-receive`'s exit status anyway; saying so
  explicitly makes it a decision rather than an accident of git's semantics. A durability copy
  that can block work is worse than no copy. A failure is reported to the pushing client and
  logged, and the push stands.
- **Only the configured refs mirror, by default the default branch.** The mirror exists so one
  machine is never the only copy of the project. Publishing every ticket branch's scratch history
  to the project's external home is a different thing, and not one anybody asked for.

## The merge

A merge happens entirely in the object database of the bare repository. No checkout, no temporary
worktree, no filesystem cost:

```
git merge-tree --write-tree --messages <default head> <approved sha>
git commit-tree <tree> -p <default head> -m <message>
git push <bare repo path> <new sha>:refs/heads/<default>
```

`merge-tree` is a real three-way merge from the merge base; a non-zero exit lists the conflicted
paths, so conflict detection is free and costs nothing when there is no conflict. The commit's
author is the approving operator and its committer is forge, so *who approved* is recorded in git
itself and survives the platform. The message carries `Ticket:` and `Changeset:` trailers.

**The merge pushes rather than calling `update-ref`.** Pushing over the local transport spawns
`receive-pack` in the bare repository, which runs both hooks — so the merge is enforced by, and
mirrored by, exactly the code path a job's push takes. `update-ref` plus an explicit mirror call
would mean the branch discipline and the mirror each had two implementations, and the demo's
"mirrored" claim would be proven by a path no job ever takes. One rule, one enforcement point.

The new commit's parent is the current default head, so the push is a fast-forward and needs no
force; `pre-receive` asserts that.

`perform/2` is idempotent: if the approved sha is already an ancestor of the default branch it
returns without making a second commit. Safe to call twice, safe to retry.

### Where it runs, and what a conflict does

A git side effect cannot live inside an Ecto transaction that may roll back, and it cannot run
after the transaction either — a conflict would then leave the ticket reading `merged` while the
default branch never moved. The resolution is a **pre-flight check**, shaped like the existing
`no_live_job/1` guard:

1. Before the transaction, `Forge.Merge.check/1` runs `merge-tree` and nothing else. It has no
   side effect. On a conflict the approval is refused, nothing is recorded, and **the ticket stays
   in `review_ready`** — where the workflow does have edges out, back to `implementing`. Had the
   ticket been moved into terminal `merged` first, a stuck item there would offer no transitions
   at all, because a terminal state has none. That dead end is the reason for the pre-flight.
2. The transaction records the approvals, the transition and the events, as it does today.
3. After it commits, the entry action runs the merge for real.
4. A late failure — another merge moved the default branch between the check and the push — is
   retried once against the new head. If it still fails the ticket is stuck with the reason, and
   `Forge.Operator.retry_merge/2` is the one verb that closes the loop. Without it a merge
   failure is a dead end in the product.

## The job's own git

A job no longer works in a local worktree of the bare repository. It clones over the same HTTP
endpoint any other client uses, with its own token, and pushes its branch back when it ends. That
is what makes the credential, the hooks and the branch discipline load-bearing today rather than
in the milestone that adds a separate worker machine — and the module that does it lives in
`forge_worker`, so the worker tier inherits it unchanged rather than replacing it.

**And it did.** Milestone 3 landed beside this one and moved the caller from the platform to the
worker's own machine without changing `ForgeWorker.Checkout` at all beyond what the volume layer
needed: a `clean: false` for a worktree snapshotted from a seed, which has nothing a dead run left
in it and does have the warm build directory the seed exists to carry
(`docs/design/worker-tier.md` § Volumes and the seed). Every `git` invocation on a worker is still
in this one module, which is what keeps the credential's handling in one place.

- Clone `--branch <ticket branch> --single-branch` on a first run; fetch and reset on a later one,
  keeping the working tree on a resume.
- The credential never reaches argv: git runs with a `credential.helper` that prints
  `$FORGE_GIT_TOKEN`, and the variable is in the environment only.
- `user.name` and `user.email` are set on the clone. The harness runs with a private `HOME`, so
  there is no global identity and without this the agent's commits fail.
- The push is `--force`, because a job may rewrite its own branch. `pre-receive` is the guard.

## Not built, and named so the absence is a decision

- **SSH.** Cut, not pending. `deploy.md` described the operator pushing over SSH to the host, and
  that could never have worked: `nix/module.nix` gives `forge` no shell and no authorised keys, and
  even with both, `pre-receive` refuses a push carrying no authority over the default branch. sshd
  does not forward the environment, and accepting a client-supplied `FORGE_INTERNAL` would hand the
  network the one thing the hook exists to withhold. The default-branch token above replaces it, so
  every route into a repository is now the platform's own endpoint with a token it minted. An SSH
  front end with the same token model is still not in the PoC.
- **Sideband progress on a clone** — see the CGI limit above.
- **Mirroring more than a push hook** is on the PoC's cut list; there is no reconciliation, no
  retry queue and no mirror health surface.

## Issuing a token

`mix forge.git.token` was the only way to get one, which made the product's own instructions —
clone this, push a workflow — unfollowable without a terminal. `/projects/:name/settings` issues
them too, over `Forge.Git.Tokens.issue/2`, which is the same call the task makes.

The UI may issue exactly three shapes, because they are the three an operator has a use for: a
**read** token for the whole project, a **write** token scoped to one ticket's branch, and a
**write** token scoped to the project's default branch. It cannot mint a job-scoped token — those
belong to a job, are issued by the engine as part of an assignment, and are revoked when it ends.

Revocation from the UI is refused for a token a job holds, for the same reason: revoking it
mid-run fails that job, and nothing would record why.

### The default-branch token, and what it costs

The third shape exists for one case that has no other route: **importing a repository that already
exists**. A registered project holds a single empty commit (`Forge.Git.ensure_initial_commit/2`),
and putting a project's history into it is not a ticket, not a conversation and not a merge — there
is no branch to review, and the thing being imported is the base every branch would be cut from.
`deploy.md` used to answer this with SSH to the host, and § Not built says why that was never an
answer.

Changing a `.forge/workflow.yml` afterwards is *not* that case: `ForgeWeb.ProjectNewLive` already
routes it through a conversation on its own branch, merged like everything else, and that stays the
way to do it. The token makes it possible to do by hand; it does not become the recommended path,
and no page offers it as one.

It is a real weakening and worth stating as one. The property used to be *no credential that
reaches the network can move the default branch*. It is now *no credential a job holds can move
it, and one minted for it can, fast-forward only*. What keeps the change bounded:

- **It is a separate mint, never a widening of an existing one.** `Tokens.issue_for_job/3` mints
  a ticket's branch or a conversation's and nothing else, so no job credential can acquire this
  scope, and a leaked one still cannot reach the default branch.
- **Fast-forward only, in the hook.** The clause is shared with the platform's own merge, so a
  token cannot rewrite history the merge could not.
- **The same TTL and the same audit as every other token.** It expires, it is revocable from the
  page that minted it, and the row records what it could do and when it was last used.
- **Minting it is a deliberate choice of a third option**, in a dropdown that names the branch.

What it does not defend against is an operator's own token, taken while live, fast-forwarding the
default branch — which is the same authority the operator has by pressing merge, bounded by the
token's lifetime rather than the session's.
