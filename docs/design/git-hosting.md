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
- `forge.mirror.<name>.url` — where one mirror pushes. `<name>` is `[a-z0-9-]+`, so the key path
  can never be ambiguous about where the name ends.
- `forge.mirror.<name>.refs` — a glob, default `refs/heads/<default>`.
- `forge.mirror.<name>.user` — the username half of the credential, optional.
- `forge.mirror.<name>.lastStatus`, `.lastAt`, `.lastError`, `.lastOkAt` — written by the hook
  after every attempt, read by the pages that say whether the off-node copy is current.

**The token is deliberately not in that list**, and neither is a URL carrying one. See § What a
mirror URL may be.

There is deliberately **no `mirror_url` column on `projects`**: a column would be a second source
of truth that the hook, which is the enforcement point, cannot read.

**The migration from the old scalar runs at the same boot that rewrites the hooks.**
`Forge.Git.Hooks.install/2` is that one moment every repository passes, upgraded or not, so it is
where a pre-named-mirror repository's single `forge.mirror` (and `forge.mirrorRefs`) scalar is
converted into the named mirror `default`, then unset. It does nothing once any named mirror
exists — including a repository migrated by an earlier boot — so the conversion runs exactly
once per repository. **The URL is carried over even when the new rules would refuse it**, an
`ssh://` or `git@host:` remote from before mirrors spoke only https being the case that matters:
dropping it would make the mirror silently vanish, while keeping it lets the hook attempt the
push, fail, and write `lastStatus`/`lastError` the way any other refused URL does — so an
operator sees a mirror that stopped working rather than a mirror that was never there.

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

The rewrite is also visible: the hook prints a note on stderr, and `git http-backend` relays a
hook's stderr to the *pushing client* over the smart-HTTP sideband — the "remote: " lines a git
client prints. **It does not become an event.** That relay is embedded in the CGI's own stdout
(the response body), never written to the CGI's captured stderr, so `Forge.Git.Http.report/3`,
which reads that capture, sees nothing here. See § What the mirrors say about themselves for the
same gap on the mirror side.

### `post-receive` — the mirrors

Enumerates `forge.mirror.<name>.url`, and for each one pushes the refs matching that mirror's
glob. A project may have several; they are independent.

- **A mirror never fails the push.** git ignores `post-receive`'s exit status anyway; saying so
  explicitly makes it a decision rather than an accident of git's semantics. A durability copy
  that can block work is worse than no copy. A failure is reported to the pushing client and
  logged, and the push stands.
- **One mirror's failure is not another's.** Each is attempted, and the loop continues — which is
  why the hook sets `-u` and `-o pipefail` but never `-e`.
- **Only the configured refs mirror, by default the default branch.** The mirror exists so one
  machine is never the only copy of the project. Publishing every ticket branch's scratch history
  to the project's external home is a different thing, and not one anybody asked for.
- **A dead mirror costs seconds, not minutes.** `http.lowSpeedLimit` and `http.lowSpeedTime` bound
  it. Without them every push waits on git's own timeout, once per configured mirror, inside the
  push the person is watching.

### What a mirror URL may be

A mirror URL is attacker-adjacent input: a project admin sets it from the UI, and it becomes an
argument to `git push` on the platform's own machine. It is therefore an allowlist, enforced in
two places, and the list is short.

**`https://` and `http://`. Nothing else.** Not a local path, not `file://`, `ssh://`, `git://`,
scp-style `host:path`, and above all not `ext::`, which exists to run a command and would be a
remote shell in a text field. Nor may the URL begin with `-`, which `git push` would read as an
option rather than a remote — `--receive-pack=...` names a program to run. Nor may it contain
`::`, which is how every transport helper is spelled. Nor may it carry userinfo: credentials have
their own fields, and refusing `https://user:token@host` is what keeps "a URL this accepted is
safe to print" true by construction rather than by everyone remembering. A URL migrated from the
old scalar was never checked by these rules, which is why the read strips userinfo too — § The
credential.

**A local path is the one worth naming explicitly**, because it reads as harmless and is not.
`forge.mirror` used to accept "a URL or a path", and with mirrors settable from the UI that is a
one-field write into any other repository on the node — `/var/lib/forge/repos/other.git` is a
project admin escalating into a project they are not in.

`http://` is allowed and the settings page says what it costs: the credential crosses the network
in clear. It cannot reach the filesystem or execute anything, which is the property that matters
here, and a mirror to a host on the same private network is a real deployment.

**Checked where it is set and again where it is used.** `Forge.Projects` refuses to store a URL
that fails the rules, and the hook refuses to push one — a guard must use the same model as the
operation it guards, and a config file is editable by anything that can reach the disk. At push
time git is told the same thing a third way: `--end-of-options` before the URL, `protocol.allow =
never` with `https` and `http` set to `always`, and `http.followRedirects = false` so a mirror
host cannot bounce the push somewhere else.

**A push takes nothing.** It receives the remote's ref advertisement and its status report,
which is inherent and unavoidable, and beyond that fetches no objects, recurses no submodules and
writes nothing from the remote into this repository.

### The credential

The URL stays printable and the secret lives beside it, in git's own credential store — a file
outside the repositories tree, mode 0600, one line per host, with the hook pushing under
`credential.helper=store --file=...` and `GIT_TERMINAL_PROMPT=0`.

This is the same shape the job side already uses (§ The job's own git): the credential reaches
git through a helper, never through argv and never through the URL. It buys three things. The
token never appears in `ps`. A URL these rules accepted carries no userinfo, so every surface
that renders a mirror — the settings page, the project page, the hook's own output, the event
log, a stored error — prints it as it stands, and leak-prevention is a property of the shape
rather than a rule five call sites have to keep. And because the store is keyed by host, a mirror
pointed at another host is handed no credential at all: git looks the host up, finds nothing, and
with prompting off simply fails.

**The exception is a migrated mirror, and it is handled in two places rather than in every
template.** The old scalar `forge.mirror` had no credential store at all, so
`https://user:token@host/x.git` was the only way an operator could authenticate one and is the
likeliest thing a node upgrading has configured — and § Hooks carries such a URL over unmodified
on purpose, so the mirror reports as failing rather than vanishing. So the guarantee above is
about what these rules *store*, not about every string the config can hold, and two defensive
reads close the difference. `Forge.Git.Hooks.list_mirrors/1` strips userinfo from every URL it
reads back, which is the one read every surface goes through; the stored value keeps it, because
the hook still has to push with it. The hook's own `redact()` is the second: a failing push
echoes the URL into `lastError`, and a migrated URL there is exactly the input it exists for.

**The file is `<credentials dir>/<project>/<mirror>.credentials`**, a directory per project
rather than a `<project>-<mirror>` filename. Both names may contain hyphens, so the flat form is
ambiguous — project `a` with mirror `b-c` and project `a-b` with mirror `c` name one file — and
since git's store matches on host rather than on who wrote the line, one project's push could be
handed another project's token. Neither name may contain `/`, so the subdirectory is unambiguous
by construction rather than by escaping.

**Both halves are optional.** No token means no entry and an anonymous push, which is what a
public mirror wants. A token with no username gets `forge`, because the store's format needs one
and a host authenticating by token ignores it.

**The hook and `Forge.Git.Credentials.path/2` derive the same file two different ways, and they
agree only for a standard repository.** The hook finds its credential file from its own working
directory; `Credentials.path/2` builds it from `Forge.Projects.repos_dir/0` and the project's
name. Those name the same file only when the project's `repo_path` is `<repos_dir>/<name>.git` —
the address `register_named/3` guarantees and the bare `register/2` does not, since
`mix forge.project.add` and `Forge.Release.register_project/4` may point a project at an
arbitrary path. `Forge.Projects.put_mirror/5` enforces the invariant rather than leaving it
implicit: it refuses `{:error, :repo_path_not_standard}` before a token is ever written for a
project whose repository is not standard, because writing it anyway would put the credential
where `Credentials.path/2` says and leave the hook looking for it somewhere else — a mirror that
always fails authentication, visible only as a `lastError` nobody would connect to the cause.

### What the mirrors say about themselves

Each attempt writes `lastStatus`, `lastAt`, a redacted and truncated `lastError`, and on success
`lastOkAt`, into that mirror's own config. The hook writes them because the hook is the only thing
present on every push path — the CGI's and the platform's own merge, which no CGI mediates.

Two timestamps rather than one, because "failed" and "last good four days ago" are different
questions and an operator needs both: one says whether it is working, the other how stale the
off-node copy is.

The settings page lists them; the project page shows a mirror that is failing, because the
settings page is not where anybody looks.

**Neither outcome reaches the event log, for any push.** The success line moved from stdout to
stderr on the theory that `Forge.Git.Http.report/3` — which already turns a hook's `forge: `
lines from its captured stderr into `git.hook.said` events — would then record it. It does not:
`git http-backend` relays a hook's stderr to the client over the smart-HTTP sideband, and that
relay is embedded in the CGI's own *stdout*, never written to the fd `report/3` reads. So
`err_path` is empty after every push, `report/3` never fires, and no `git.hook.said` event is
created — not for a mirror outcome and not for the ticket-branch rewrite notice above. This was
verified by instrumenting `report/3` directly (`platform/test/forge_web/git_http_test.exs`, the
test on the CGI-mediated push and its neighbouring comment), independently confirmed by two
reviewers. Today a mirror's outcome reaches the pushing client's terminal and the repository's
own `git config` (§ above) — never the event log. Closing that gap needs `report/3` to parse the
pkt-line/side-band-64k response body instead of the CGI's stderr capture, which is a change to
`Forge.Git.Http` that this note does not yet describe.

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

  **And no ssh client either.** The mirror was the last caller, and it speaks https now, so
  `openssh` is gone from the image and from the NixOS module's service path. A deployment that
  mirrored over `git@host:` stops mirroring on upgrade and says so in the mirror's own status,
  which is the point of that status existing.
- **Sideband progress on a clone** — see the CGI limit above.
- **Reconciling a mirror** is still cut: a mirror that was unreachable is not retried and is not
  caught up, it is simply reported as failing until the next push to a matching ref succeeds.
  What is no longer cut is knowing — § What the mirrors say about themselves.

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
