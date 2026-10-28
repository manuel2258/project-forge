# Secrets: what a project's work may read that the platform does not use

Scope: values a project's jobs need from outside the platform — a test-mode API key for the
service under development, a token a build fetches private packages with, a key a release is
published or deployed with — and how they reach the jobs and conversations the workflow names
them for, and no others.

**Built, all four steps of § Sequencing**: secrets are set, listed and deleted on project
settings; a job state or a command names the ones it receives and a conversation's are picked when
it is opened; each run holds them in its environment, sealed to its worker until it is spawned;
and what leaves the machine is masked. The operator settled the open choices on 2026-10-09: the
workflow is the access list for jobs, a person opening a conversation picks its secrets, values are
masked where that is easy, and project admins write secrets that every member can name
(`decisions.md` § Security and users). What a real agent does with one on a real machine is
unobserved here: the worker's side is tested against a fake harness.

## What is already a secret here, and what this is not

Three secrets reach a job today, and each is the platform's own: it chooses, uses or mints them.

- **The inference credential** (`credentials.md`): a user's, picked from the project's pool, used
  by the harness.
- **The provider credential** (`provisioning.md` § Whose account): a user's, used by a driver to
  make machines. It never reaches a job.
- **The git token** (`git-hosting.md` § The per-job token): minted per job, scoped to one ref.

A project secret is none of these. **The platform never uses it; it only carries it** from the
person who set it to the jobs that asked for it. What this note borrows from the three is
mechanism, not meaning: the Vault at rest, the per-job seal on the wire, and the runner's
`{:secret, _}` path into the environment.

## What a secret can protect, said first

**An agent holding a secret can do anything with it.** It runs with permissions bypassed because
the slice is the sandbox (`claude-code-events.md` § Invocation), it has a shell,
and its slice sets no network policy — nothing in `worker/` or `nix/` restricts a unit's
addresses. It can print the value, commit it, write it into a document or send it anywhere. A
preamble line asking it not to is a request.

**So a secret that reaches an agent is readable by every member of the project.** Any member can
open a conversation or write a ticket (`:use`, `decisions.md` § Security and users), and an agent
can be asked — or, reading a hostile issue or web page, tricked — into showing what it holds.
That is a property of agents rather than a defect of this design, and it is written here so that
no surface implies otherwise.

**A command is not safer for being a command.** The script is pinned at the ticket's base commit
(`commands.md` § The shape), but it runs in a checkout at the invocation's commit, which is the
agent's branch — and `build` and `test` run the code there: a `build.rs`, a test, a package's
install script, a Makefile target. A secret in a build command's environment is in the environment
of code the agent wrote. This is the lesson CI systems learned with workflows that run a
contributor's branch beside the repository's secrets.

So there is one boundary, and it is decided before the job starts: **which jobs receive the
secret.** Everything after that — masking, the manifest's instruction — is against accidents, not
against an agent or a member who means it.

## The workflow is the access list

**A job state or a command names the secrets it receives, and a ticket entering that state gets
them.** Nothing else grants one. A secret carries no setting of its own about where it may go, and
a job whose state does not name it does not hold it.

```yaml
commands:
  publish:
    run: .forge/commands/publish.sh
    timeout: 10m
    secrets: [CARGO_REGISTRY_TOKEN]

states:
  implementing:
    prompt: agents/implement.md
    secrets: [STRIPE_TEST_KEY]
    ...
```

- **`secrets` is a list of names, on a job state and on a command.** Not on a command state —
  each command brings its own, as it brings its own `env` — and not under `defaults`, because a
  default is a secret in every job, which is the thing being avoided.
- **Entering the state is the grant.** The job made for a ticket entering `implementing` holds
  `STRIPE_TEST_KEY` on every run it has. A command job holds what its command names, whoever
  invoked it: a state, or an agent whose state may invoke it. Nothing is inherited — an agent's
  secrets do not pass to the commands it invokes, and a command's do not pass back.
- **The list is reviewed, because the workflow is.** `.forge/workflow.yml` is read at the ticket's
  base commit and pinned at admission (`workflow-grammar-v1.md` § Pinning), so who receives a
  secret changes only by a merge a person approved, and an agent cannot grant itself one from its
  branch. A ticket admitted before the change keeps the list it was pinned with, until a person
  re-pins it (`workflow-grammar-v1.md` § Pinning).
- **A library can carry the list** (`ticket-types.md` § Imports). A command a library declares
  brings its `secrets` with it, and a state that `extends` a library's template takes the
  template's list unless it writes its own — the keys a type writes replace the template's whole,
  so `secrets: []` is how a type takes the template without its secrets. Either way the list is in
  `.forge/`, reviewed and pinned with the rest: what a ticket's jobs receive is what its type's
  workflow resolves to.
- **The validator checks the names and nothing else.** Well formed and not reserved (§ Names) is
  `forge_core`'s to reject; whether the project has such a secret is the platform's, when the job
  is scheduled and again when it is assigned, because secrets change after a workflow is pinned.

**What a listing hands the secret to is the workflow author's to see.** Naming a secret on an
agent's state hands it to the agent, and so to every member (§ What a secret can protect). Naming
it on a command hands it to the code at that command's commit, which for `build` and `test` is the
agent's branch. A production key belongs on a command state that runs after the approval, and on
nothing whose code an agent writes. The platform does not check that; the workflow says it, and
the merge that changes the workflow is where it is seen.

**Why list per state, when an agent's secrets are readable by every member anyway:** accidents
scale with exposure. A secret in every agent's environment is in every transcript that prints the
environment, every session file, every tool that dumps its environment when it crashes. A secret
in the one state that needs it is in that state's.

### Conversations

**A chat step is not this**: its secrets are the ones its state lists, and it waits on a missing
one as a job does — before a machine, recorded as its wait reason — except that it sticks no
ticket (`conversations.md` § A conversation that is a step). What follows is a plain
conversation's.

**A conversation's secrets are picked by the person opening it**, from the project's secrets,
none ticked by default. A conversation has no state to list them on, and it is a person deciding
in the moment rather than a workflow deciding in advance — which is what a conversation is for
(`conversations.md` § Why it is not a workflow). Who picked which is its `chat.opened` event: the
person opening it, and the names; each run's `job.secrets` says what it then held.

- **Fixed for the life of the process**, as its model and resources are (`conversations.md` § What
  it asks for). A process's environment cannot change under it.
- **A reopened conversation holds the same names**, at their current versions. One deleted since
  is not held, and both sides are told, rather than the agent finding the variable missing halfway
  through a turn: the conversation's page — *⚠ `STRIPE_TEST_KEY` was deleted and this conversation
  no longer holds it*, read from the latest run's `job.secrets` — and the agent, whose spec carries
  the gone names beside the held ones, so its manifest, or the continuation a resumed session
  reads, says which variables are no longer set (`job-prompt.md` § Secrets). The run goes ahead
  without it: a conversation is a person at the keyboard, who can open another.
- **The guard is in the context.** Opening a conversation is `:use`, so any member may pick any of
  the project's secrets; `Conversations.open/3` checks that each name is a live secret of that
  project and refuses the opening by name otherwise, because a form's list of boxes is not a guard
  and a name off the wire could be another project's or deleted since the page was drawn.

**What this means, said plainly: every project secret is readable by every member.** Any member
can open a conversation holding any secret and ask for it. The workflow's lists still decide what
*unattended* work holds, which is where accidents happen; they do not keep a secret from a member.
A key that a member must not hold does not belong in a project yet (§ Open).

## What a secret is

```
project_secrets
  project_id
  name        environment-variable shaped, unique among a project's live rows
  value       sealed, never loaded by an ordinary query
  version     1, 2, … — each set is a new version
  set_by_id   who set the current version
  set_at
  deleted_at  set once, never cleared
```

**It belongs to the project, and `:manage` writes it** (`Forge.Access`: a project admin). A
staging key or a deploy key is the project's, not a person's: credentials are owned by users
because each is somebody's account, money and individual-use licence (`decisions.md`), and none
of that is true here. **Every member reads the list** — names, version, who set it and when, and
when a run last held it — because a workflow's author needs the names. Nobody reads a value back,
admins included.

**Not node-wide**, for `credentials.md` § The node's own key is gone's reason: a secret nobody owns
reaches projects whose admins never chose it.

**The value is a string, sealed with `Forge.Provisioning.Vault` under a label of its own**
(`forge/secrets/v1`), so another table's ciphertext pasted into this column does not open — the
label is the Vault's associated data and exists for exactly that. `load_in_query: false` and
`redact: true`, as on a credential, and two functions read the column by name: the key check,
which opens it only to prove the key, and `Secrets.resolve/2`, whose values only
`Secrets.for_wire/3` reads, to seal them for a worker.
Multi-line values — a PEM key — are allowed. **At most 32 KiB**, well under the kernel's
128 KiB for one environment string, which a process holding several has to hold at once. **At least
eight characters**, because a shorter one cannot be masked without mangling everything around it
(§ Masking), and a credential that short is not one. **No NUL byte**, which no environment can
carry. A browser's CRLF is read as a line break and the ends are trimmed, because a pasted token
picks up a newline more often than not; a key that needs a final newline gets one from the script
that writes it to a file.

**The node's key check opens them too.** They are sealed under the key `SECRET_KEY_BASE` derives,
so `Forge.Credentials.KeyCheck` samples them beside both kinds of credential (`deploy.md` § Secrets
file): a node holding only project secrets still refuses a key that opens none of them.

**Deleted, not removed, and deleting destroys the value.** Events name a secret by its row's id and
version, so the row stays — by the id, because a deleted name set again is a new row that starts at
version 1 again, and a name and a version would not say which secret; the value is overwritten with
nothing in the update that sets `deleted_at`, and a database check says a live row has a value —
`credentials.md` § What a credential is, for the same reasons. A deleted name may be set again, as a
new row.

## Names

**`^[A-Z][A-Z0-9_]{0,63}$`, and not reserved.** `ForgeCore.Secret` is the list, and it has two
sources, kept apart so each can be checked against its own:

- **Ours**: the prefixes `FORGE_`, `ANTHROPIC_`, `CLAUDE_`, `NODE_`, `BUN_`, `NPM_CONFIG_`,
  `NIX_`, `GIT_`, `SSL_` and `BASH_`, and the names `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`,
  `TERM`, `DISABLE_AUTOUPDATER` and the four proxy variables — everything the platform, the
  harness and the worker set or read, and every name the job's environment already carries. The
  worker's suite asserts that `ForgeWorker.Job.Exec`'s allowlist and every name the harness driver
  sets both stay inside it. `DISABLE_AUTOUPDATER` is the driver's
  (`worker-tier.md` § Updating a worker): a secret of that name would be loaded after it and win.
- **The harness's own**, copied verbatim from `claude-code` 2.1.266 — a version somebody read,
  and no longer one anything pins: the image carries no Claude Code and each machine installs its
  own (`worker-tier.md` § Updating a worker), so a worker's version moves without this repository
  changing. The variables it strips from a shell's environment (`SHELLOPTS`, `PS4`, `IFS`,
  `GCONV_PATH`, `LD_` and `LC_` among them), the search-path variables it lists beside them, and
  the 188 names and the patterns it treats as making a program run code (`MAKEFLAGS`, `PAGER`,
  `JAVA_TOOL_OPTIONS`, `RUSTC_WRAPPER`, any name ending `_PAGER` or `_EDITOR`, and the rest). When
  the package moves, they are read again: a harness that learns a new name has found one this list
  is missing.

**This is a security rule, not tidiness.** `ANTHROPIC_BASE_URL` in a job's environment sends the
harness's requests — carrying a credential from the project's pool, which may be another member's
— to a host of the secret-setter's choosing, so a project admin could collect every pooled
credential through one secret. `HTTPS_PROXY` does the same to all of a job's traffic, and
`LD_PRELOAD` loads code into the harness. So do `NODE_OPTIONS` and `BUN_OPTIONS`: nixpkgs'
`claude-code` is a compiled JavaScript executable, and its binary names both. `BASH_ENV` runs a
file in every shell the harness starts, and `SHELLOPTS=xtrace` with a `PS4` holding a command
substitution runs that command in every bash, no file needed. The platform setting its own
variables after a secret's would not help: these are names it does not set. The list is every
name either source knows to redirect a job or load code into it, and nothing claims it is
complete.

**One list, in `forge_core`, read on both ends.** The changeset refuses a reserved name — on every
set, not only the first, so a name reserved later cannot be given a new value — and so does the
workflow's validator, on a `secrets` list. The worker refuses one again when it composes the
environment (`ForgeWorker.Job.Secrets.env/1`): the name is left out and said in the machine's log,
so a row written around the changeset or a platform older than the list cannot put one in front of
a harness. Two implementations of a rule that have to agree are two places for them to disagree.

## Delivery

**The job carries the names, from its creation.** `jobs.secret_names` is copied from the pinned
workflow's state, or the command, when the job is made, and for a conversation from what was
picked: the row says what the job asks for, whatever the project holds by then.

**Resolved twice.** By the scheduler before it asks for a machine, so that a job asking for a
secret the project lacks sticks its ticket and nothing is made for it — `credentials.md`'s order,
credential before machine. And again in `Jobs.assign/2`, the choke point where the git token is
minted and the credential sealed, because a secret can be deleted in between: a workflow job or a
command finding one gone goes back to pending, and the next pass sticks it.

| when | what happens | who resolves it |
|---|---|---|
| a state names a secret the project has not set | the ticket sticks: *the state `implementing` names `STRIPE_TEST_KEY`, which this project has not set; a project admin sets it in the project's settings* | an admin sets it, and the ticket comes back by itself |
| a command state's command names one | the same, naming *the command `publish`* | the same |
| an agent invokes a command that names one | the invocation is refused and the agent reads why, as for a `max` breach (`commands.md` § Limits) | an admin, then the agent again |
| a conversation picked one deleted since | the run holds the rest, and the page says which is gone (§ Conversations) | the person, by opening another |
| every name is set | delivered | — |

A stuck ticket coming back when the secret arrives is `credentials.md` § How a job picks'
mechanism, with one more kind of arrival: the first version of a secret, set under any name
(`Secrets.set/4` → `Engine.resume_placement/2`). Every ticket stuck for placement comes back, and
one whose state names something still unset sticks again on the next pass, as for a credential.

**On the wire, sealed for that worker and that job.** The assignment gains `secrets`: one sealed
JSON object of name to value, made by `ForgeCore.Job.Credential`'s cipher, and only when the job
names any — an assignment for a job that names none is what it always was. (A conversation whose
every pick was deleted names some and holds none: it carries an empty sealed object.) **The seal has a purpose.** Its
associated data was the job id alone, so a sealed credential and sealed secrets for the same job
would each have opened in the other's place; secrets are sealed under `secrets:` and the job id,
and a credential's associated data is unchanged, so an older machine still opens its own.

**A machine that would drop them gets none.** A job naming secrets asks for protocol 6
(`Jobs.protocol/1`, `worker-channel.md` § Versions): a worker older than this note reads
an assignment's unknown keys as nothing, and would run the job without them.

**Opened at spawn, into the process's environment, and into nothing else's.** The worker opens
them when the runner or a command spawns its process and writes them, shell-quoted, to a file in
the worker's own directory, which only root can enter; the unit is handed the file with
`LoadCredential=`, so systemd gives a copy to the unit's user alone, and a shell inside the
process loads it and `exec`s (`ForgeWorker.Job.Exec`, `worker-tier.md` § The job slice) — from
`$CREDENTIALS_DIRECTORY`, which is why the unit's command line is not expanded by systemd: the
first build let systemd rewrite the loader's test for that variable to nothing, and on the image
every run holding a secret died reading the root-only path. Never
`--setenv`: a unit's environment is a property systemd shows every user on the machine, so any
other job there — another project's on a shared template — could read it. Never an argument:
`env -i NAME="$NAME"` puts the value in `env`'s argv, readable in `/proc` by anyone. The first
build did both; the review found it, and the credential and git token had gone the same way since
before this note. The file is removed when the process ends. Secrets that will not open — a seal
for another job, another machine's token — fail the job before anything is spawned, rather than
running it without them. **The assignment's spec carries the names, never a value** — what the
run holds, and for a conversation what is gone — because it is written to `$FORGE_JOB/spec.json`
and is what the manifest reads. The row's own spec does not: what a job asks for is
`jobs.secret_names`, and what a run held is its `job.secrets`.

**The manifest names the variables, never their values** (`job-prompt.md` § Secrets), and
asks the agent not to print, commit or write them into a document. A request, and labelled as one
there too.

**A running job keeps the version it started with.** A new value reaches the next start — a
resume, a requeue, a reopened conversation, the next job. A process's environment cannot change
under it, and a credential swapped under a live agent would turn one bad value into any number of
half-finished jobs.

**Each run records what it held**: `job.secrets`, each secret's id, name and version, and for a
conversation the names it picked that are gone; never a value. It is what the settings row's *last
held* reads, and what a person asks after a leak: which jobs held version 3 of that secret.

## Masking

**What can carry a value off the machine by accident,** all of it uploaded by the worker: the
harness's events (the timeline every member reads), the transcript, the session file uploaded for
resume, a command's log (an artifact, and handed to the agent that invoked it), and what a run
reports — its documents and proposals, a conversation's turns, the reason a run ended or failed,
which can be the harness's last line of stderr or a hook's output — and the machine's log, read off
the machine by its owner, where a turn that could not be pushed quotes git.

**The worker replaces each value it delivered with `[secret NAME]`** in every one of them before
it leaves the machine: the exact value, and its JSON-escaped form — in both cases of a `\u`
escape, since Jason writes `\u001B` and the harness's own JSON `\u001b` — because events and
transcripts are JSON lines and a value with a newline or a quote appears escaped in them. Every
ending a run reports is masked in one place, the link's `report/4`, which they all pass through.
**Only that, because only that is easy.** Events arrive a line at a time and the rest are whole
files, so a substring search over each line or file is the whole mechanism — no decoding, no
scanning across a boundary. Each value is searched for on its own and overlapping matches are
merged, so two values that overlap leave neither's tail in the clear, and two secrets holding one
value are both named.

**No process holds the secrets to do it.** Masking needs the values after spawn, which
`credentials.md` § Delivery to the machine was built to avoid holding; so every masking call opens
the seal again and lets go of the values when it returns (`ForgeWorker.Job.Secrets`). The link,
the job's task, the runner and the conversation process keep the ciphertext the assignment brought,
and the suite asserts it of the link's and the runner's state. Opening a few kilobytes per event
is cheap beside the harness writing it. **What the harness prints is another matter:** a line it
wrote holding a value passes through the runner — its buffer, its last event, its result — and the
job's task unmasked until it leaves the machine, as all its output does, so a crash report in
between can carry it. That report is in the machine's journal, which is root's; nothing of it
reaches the platform unmasked. On disk, the values sit in the secrets file in the worker's own
directory, root's alone, for as long as the process runs (§ Delivery).
Masking on the platform instead would open every secret of a job for every event it records, and
still miss what the worker is the only one to see whole.

**What masking misses, said plainly:** a value base64-encoded, URL-encoded, reversed, or written in
two pieces — including the piece left when a truncation cut through it, as the harness's stderr
tail on a `starting` event is cut to its last 2 KiB before it is masked; a value the harness wrote
as a JSON number rather than a string. It catches the `env` dump and the echoed configuration file — the accidents — and
nothing that is trying.

**Commits are not masked, and neither are groups of files** (`commands.md` § Groups of files).
Rewriting a commit would change the agent's work, and the agent can push on its own with its git
token; a group's files are uploaded as they are, and may be binary, where a substring replaced is
a file broken. A push carrying a value is § Open.

**So the archive reads them too** (`archive.md`): a group's files are ticket files, and every job
and chat of the project can now open them — including one that holds none of the secrets the file
may contain. Commits were already such a channel, and a project's members can already download the
files; what changes is that an agent can. A value in a group's file is no more protected than a value
in a commit, and this is the same § Open.

## Surfaces

- **Project settings gains Secrets** (`ui.md` § Project settings): the list for every member; set,
  replace and delete for `:manage`, guarded in the context and not by the form (`decisions.md`).
- **The value field is write-only.** The form has no `phx-change`, so a value reaches the server
  once, on submit; it is passed to `Operator.set_secret/4` and never assigned, after a save or a
  refusal alike, and the form is rendered afresh after a save so the browser lets go of it. The
  provider-credential form's bug (`credentials.md` § Sequencing, step 2) is the precedent. The
  form's parameters are named `secret`, so `:filter_parameters` — `password`, `secret`, `token` —
  keeps the whole of them out of the request and event logs.
- **A crash report is not filtered**, and a LiveView that raises is logged with its last message —
  here, the form, value and all. So everything typed is checked before the database is asked
  anything, a malformed event is refused rather than raised on, and any failure of the save is
  caught and logged by its kind alone, never its reason or stacktrace, which can quote what they
  were given. What remains is a failure inside LiveView's own handling of the frame, before the
  page's handler runs; nothing on the page can catch that.
- **Each row says who receives it**: the commands and states of the default branch's workflows —
  every ticket type's, each named with its type when the project has types — that name it — the access list read backwards, which is the question a person setting a secret
  is actually asking — or *no state or command names it*; how many live conversations hold it; and
  when a run last held it. A default branch with no workflow yet says so, and one whose workflow
  is refused says that, in place of the list; a type whose workflow is refused is named as not
  read, since the list may be short by what it would have said.
- **The conversation create view** offers the project's secrets as unticked boxes, beside the
  model and the resources.
- **The job page** names the secrets and versions each run held — *`STRIPE_TEST_KEY` v2,
  `SENTRY_TOKEN` v1* — in both its asides. Nothing there is ever gone: the page shows workflow
  jobs and commands, which do not run without a secret they name.
- **The conversation page** says what it holds, and what it picked that is gone.
- **Events**: `secret.set` (id, name, version, who), `secret.deleted`, `job.secrets`, and the
  names on `chat.opened`. Never a value; audited like every other mutation.

## Deliberately not here

- **A person's own secret.** *Use my GitHub token in this chat* wants a secret owned by a user and
  reaching only conversations that user opens. It is a second owner model and waits for someone
  who needs it — and even then the conversation's transcript is read by every member.
- **Files.** The environment only. A command that needs a key file writes one under `$FORGE_JOB`
  from its variable.
- **A second list on the secret.** An earlier draft of this note gave each secret a *reach* the
  platform enforced beside the workflow — agents, or only commands at an approved commit. One list
  is simpler, and the workflow is already reviewed by the merge that changes it; § Open keeps the
  checks a list in a file cannot make.
- **Short-lived, minted secrets** — a cloud's workload identity, a registry's job token. The right
  end state for a production key, since there is then nothing long-lived to steal, and what the
  git token already is for git; each needs an issuer per provider.
- **Network egress control.** The one thing that would make a secret held by an agent containable
  rather than merely scoped. A separate design, and a large one.
- **Inheritance.** Secrets pass from nobody to anybody: not from an agent to the commands it
  invokes, not to a subagent, not from a ticket to its conversations.

## Open

- **A push carrying a value.** Ticket branches are not mirrored by default, but the merge is, and
  the mirror takes the default branch off the host (`git-hosting.md` § `post-receive`). Refusing
  in `pre-receive` needs the hook to ask the platform whether a pushed blob contains a value, and
  it has no channel for that today; the merge is a single choke point in the platform's own
  process, before the mirror, and may be the better place.
- **A key no member should hold.** A production deploy key is one: today any member reaches it
  through a conversation, and the workflow can name it on `test`, which runs the agent's branch. Two
  checks would close it, both the platform's because no list in a file can make them: the secret is
  never offered to a conversation, and it is delivered only to a command running at the ticket's
  approved commit — the sha its approved `changeset` version records, which is what an approval
  attaches to (`git-hosting.md` § Non-fast-forward on a ticket branch) — compared by equality, so an
  agent pushing past the approval cannot slip under it. Not `refs/forge/approved/<n>`: that ref is
  written when the changeset is merged, and a command before the merge would find none. Wanted the
  first time a project holds such a key, not before.

- **What it shares with credentials, and inherits.** Three behaviours are the credential's, and
  are fixed with it or not at all. `job.secrets` is recorded when the assignment is pushed, as the
  run is, so a machine that turns the assignment away (an unhealthy one) leaves a record of a run
  that held nothing. A secret this node cannot open — a rotated key the check passed — re-offers
  its job on every pass, logging each time, as an unreadable credential does. And a stick can lose
  a race with the secret's arrival, leaving a ticket stuck until the next arrival, as a
  credential's can (`Engine.stick/3` does not look again).

## Sequencing

1. This note. Done.
2. **Built.** `project_secrets` and `Forge.Secrets`; `Operator.set_secret/4` and `delete_secret/3`
   asking for `:manage`; `secret.set` and `secret.deleted`; the name rule as `ForgeCore.Secret`;
   the Secrets section on project settings; and the key check sampling project secrets. Nothing is
   delivered.

   What building it settled: the reserved list grew past this note's first draft — `NODE_` and
   `BUN_`, read off the harness binary itself, and `BASH_`, `LC_` and the names a shell reads — and
   a value may not carry a NUL byte. The project check on a deletion is made once, in the read, not
   repeated in the update: two copies of it could each be removed with the other hiding the
   mutation.

   An independent review (the `review` skill) then found, each reproduced before it was fixed:
   a NUL in a name reached Postgres before the name was checked, and the crash put the value in
   the error log (§ Surfaces); the reserved list missed names that run code, `SHELLOPTS` and `PS4`
   among them, which is why it now carries the harness's own lists (§ Names); events named a
   secret by name and version, which a deleted name set again repeats, so they carry its id; a
   deletion racing a replacement recorded the older version, so it locks the row it reads; and
   five tests that could not fail. `Forge.Credentials.revoke/2` had the repeated owner check this
   step removed from deletion, and lost it too.
3. **Built.** Listing and delivery: `secrets` on a state and a command, `jobs.secret_names`, the
   conversation's picker, the worker's half of the reserved-name check, the seal's purpose,
   protocol 6, the stick and its arrival, the refused invocation, the manifest section, the
   settings row's *received by* and *last held*, and the job and conversation pages.
4. **Built.** Masking, on the worker, in every event, report, transcript, session file and command
   log.

   What building 3 and 4 settled: the stick is the scheduler's, before a machine, and not the
   job's creation — the job carries the names and the pass decides, as for a credential. A
   conversation does not stick on a deleted secret; it runs with the rest and says so. The worker
   holds no value between uses (§ Masking), which the first draft of this note conceded it would.
   And a run's report is masked as well as its files, because a report carries the harness's last
   line of stderr. Each guard named in step 3 — the reserved-name check on both ends, a secret the
   state does not name, another project's secret picked for a conversation, the seal's purpose —
   and each masking site was mutated and seen to fail a test.
