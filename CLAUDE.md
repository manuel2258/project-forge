# forge

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

Read `docs/vision.md` for what this is, `docs/decisions.md` for what is settled, and
`docs/poc-plan.md` for what is being built and in what order. Design notes for the current
milestone live in `docs/design/`; code follows them, and a change of mind updates the note first.

`docs/design/ui.md` is the standard for every operator surface and `docs/design/capacity.md` for
how consumption is modelled and drawn. Read both before changing anything the operator sees.
`ui.md` describes the redesign vendored under `docs/design/ui/` — every screen by id in
`screens/final-design.dc.html`, with the deviations a later UX pass made recorded in the note itself.
**It is built**, every area of it; its § Not built yet lists what the code does not do yet.

`docs/design/ui.md` § The installed app (ticket 62) is the standard for forge on a phone's Home Screen:
the manifest and its shortcuts, the status bar, the icon's badge, the tidying of notifications that
no longer wait, the offline page, what the service worker keeps and the iPhone's message. **It is
built and headless-checked**; its *Not verified here* is what a first real phone has to confirm.

`docs/design/worker-tier.md` § The command copy is the standard for what a command may keep for its
ticket's next command: `keep_build` and `warm_start` on a command, a copy of its own on the machine
that is never shared with another ticket, an agent job or a conversation, the scheduler's two-minute
wait for the machine holding it, **Clear** as an epoch, and the two lines a command's log gains. **It
is built** (ticket 76), and **no saving is measured**: no machine that has the new worker has run a
real ticket's commands (its § Open). Forge's own commands opt in to nothing yet.

`docs/design/outside-work.md` is the standard for work done outside forge's machines: **taking a ticket
over** (a hold with a person's or a token's name on it, which a release counts as handing back), **handing it
back** to a step of the hander's choosing with what was pushed recorded as the ticket's `changeset`, and the
rest of ticket 79 (outside work opened from a start commit, what later jobs are told, a job's push that never
removes a commit someone else pushed, an MCP endpoint, the screens). **It is built** (ticket 79), and **none
of it has run with a real agent on a real PC**: its § Not built, and not verified says what the suite could
not. It is a migration and a worker protocol bump (17).

`docs/design/conversations.md` is the standard for chats — the work that does not fit a workflow
state.

`docs/design/ticket-proposals.md` is the standard for what an agent may say about the project
itself: any job may propose a ticket, no job may write one, and every job is handed the project's
tickets to read.

`docs/design/identity.md` is the standard for who a user is, which projects they reach, and whose
credential funds the work. Its first step is built: approval, `node_admin`, project membership,
read scoping, and a guard on every human write. So is OIDC: providers from the environment, an
`identities` table, and a pending account on first login that a node admin still has to approve.
The rest of that step arrived in two notes, and nothing of it remains: `provider_credentials` and
`worker_templates` with `docs/design/provisioning.md`, and the inference `credential`, worker
ownership, `jobs.credential_id` and per-credential spend with `docs/design/credentials.md`.
`identity.md`'s § Sequencing records what an independent review found in the first attempt,
which is worth reading before writing the next guard.

`docs/design/credentials.md` is the standard for inference credentials: a user owns them, a
job — not a machine — holds one, picked from its project's pool when it starts, and the node's own
`ANTHROPIC_API_KEY` is not read. **It is built**: credentials checked on save and managed from
`/users/settings`, machines owned and assigned by their owners, and each job running on a
credential from its project's pool, sealed to the worker in its assignment — picked by passing
over the rate-limited ones and preferring the one that has spent least today, moving off one that
becomes limited, and resuming rather than failing when a limit stops it mid-run. Spend is
recorded per run, and each credential's five-hour and weekly windows are drawn on its settings
row and in the top bar. How a real limit reads is still third-party accounts, unobserved here.
What it leaves out on purpose is in its § Deliberately not here.

`docs/design/codex.md` is the standard for the second harness, Codex CLI, on a ChatGPT login (held by
one run at a time, returned changed) or a Codex access token, and `docs/design/capacity.md` §
Usage in weighted tokens for how every run — Claude's too — is counted and capped in weighted
tokens, not dollars. **It is built** (ticket 43): usage counted in weighted tokens for both
harnesses and a run stopped by the worker once its tokens pass its budget, a job's harness and a
model and effort per harness, the two Codex credential kinds with a login held by one run and
handed back refreshed, the driver on `codex app-server`, a Codex session carried between machines,
and the screens; a worker needs protocol 11. **None of the Codex side has run against OpenAI**:
`docs/design/codex.md` § Not verified here is what a first real run has to confirm.

`docs/design/provisioning.md` is the standard for what a job asks for and where a machine comes
from: resources declared per job, a gate on kind as well as memory and cores, worker templates as
a recipe the platform creates from, per-user provider credentials, and a driver registry in place
of one global provider. It supersedes the single `slice_bytes` gate in
`docs/design/worker-tier.md` § Scheduling and is read together with `docs/design/commands.md`,
which holds the grammar half. **It is built**, `resources` on a *command* included. The Hetzner
driver has created and destroyed real Hetzner machines; none has yet connected to a platform and
run a job.

`docs/design/archive.md` is the standard for what a job may read of the project's past: every
ticket's documents and files in every version and a ledger of the jobs that ran, as a read-only
folder `$FORGE_JOB/archive/` that the worker serves over 9P and mounts, fetched when a file is
opened and pinned to nothing. **It is built** to the platform's door and the worker's server, with
the 9P messages spoken to the socket from the suite; the kernel mount itself needs a machine and has
not run here (its § Not verified here).

`docs/design/ticket-types.md` is the standard for ticket types: one workflow per type in
`.forge/workflows/<type>.yml`, chosen at admission with no default, libraries of commands,
defaults and state templates a type imports, and a proposal that may suggest a type a person
confirms. **It is built**; nothing yet has run on a real project with types.

`docs/design/schedules.md` is the standard for tickets admitted on a clock: a `schedules:` list in a
workflow file (a name, a five-field cron line read in UTC, a title and a body), a `schedules` row for
each one a project admin has switched on, and a runner that admits an ordinary ticket in that
admin's name when one comes due. **It is built**: the grammar and cron dialect in `core`, a
schedule off until a person switches it on and off again when it leaves its file or its admin loses
the right to admit (checked when it fires, not only when the role changes), one ticket however many
times were missed, a failure recorded and never retried before the next time, and an alert in the
queue and on the phone that a repeat does not push again; on the project page's Workflow view, in
the queue, over the JSON API and on a scheduled ticket's details. **Not verified here:** a runner
over days on a real node, pushes to real phones, and a scheduled ticket of a real agent type
merged end to end (`docs/design/schedules.md` § Not verified here). `.forge/workflows/weekly.yml` declares one,
`weekly-maintenance`, Mondays at 06:00 UTC.

`docs/design/commands.md` is the standard for commands: a fixed script a workflow declares once,
run as a job of its own — by a command state on entry, its exit statuses mapped to an outcome, or
by an agent that writes `$FORGE_JOB/invoke.json` and parks until its commands are done. **It is
built**, and so are groups of files (`name/*` in `produces`, for an agent or a command): each file a
blob on the ticket, uploaded under a prefix token of the job's own, and downloaded rather than shown
unless it is small text. What a real build looks like on a real command pool is unobserved here:
the worker's side is tested against scripts in a temporary directory, not against `nix develop` on
a machine.

`docs/design/secrets.md` is the standard for project secrets: values the platform never uses and
only carries, written by a project's admins, listed per state and per command in the workflow,
picked per conversation by the person opening it, and masked where that is easy. **It is built**:
secrets set, listed and deleted on project settings and sealed at rest; `secrets` on a job state
and a command, and picked when a conversation is opened; each run holding them in its environment,
sealed to its worker until spawn and needing protocol 6, a missing one sticking the ticket before
a machine; and the worker masking the value and its JSON-escaped form in everything it uploads
but commits and groups of files, holding no value between uses. What a real agent does with one
on a real machine is unobserved here. It says plainly that every project secret is readable by
every member, and its § Open holds the two checks a key no member should hold would need.

`docs/design/changelog.md` is the standard for what forge tells the projects it hosts: a changelog
built into the platform, handed to every job and conversation as `$FORGE_JOB/platform/changelog.md`,
one section per release saying what a project must change or may adopt, and `.forge/forge-release`,
the one file in which a project records the release it was last brought up to, which the project page
reads and an agent moves when it upgrades the project. **It is built**; every release writes its own
section (§ Writing a section), and no agent has yet upgraded a real project by it.

`docs/design/workflow-grammar-v1.md` § Extending a job is the standard for what a person may do about
a job that ran out of budget: reopen it on its own session with more room and a note, or run the
state again with a note, each kept as a record of who, how much and why, and either may raise the
ticket's cap in the same step (`docs/design/capacity.md` § Four exhaustions). **It is built**
(ticket 58): the same job row and attempt runs again, its spec untouched, on the tokens and turns the
person gave — on top of what it has used — with `tickets.cap_raise` added to the workflow's cap
wherever the cap is read; the forms are on the ticket page and in the queue's stuck item, the
extensions are on the job page and in Activity, and the ledger counts them. It needs **worker
protocol 12** (the spec's `extension`, and `resumed` in the result). **Not verified here:** whether
Claude Code's `--max-turns` counts only the new turns of a `--resume`d session, which the rest of the
design assumes as the resume after a question already does; no real job has been extended.

`docs/design/attachments.md` is the standard for files people attach: a pool per ticket and per project
chat of `attachments/<file>` versions, staged under `upload/<id>`, claimed by the act they ride on,
handed to every run and to a chat each turn as a read-only folder `$FORGE_JOB/attachments/`, and
withdrawable by the attacher or a project admin — the one way a blob's bytes leave the store. **It is
built** (ticket 60), and it needs **worker protocol 13**; read it before changing anything an
operator attaches, and `docs/design/worker-channel.md` § Protocol 13 for the wire. **Not verified here:**
the bind mount on a real machine, whether Claude Code or Codex can read an image from the folder (Codex
has never run against OpenAI here), drop and paste on a phone, and a 500 MiB body through a proxy.

`docs/design/storage.md` § Retention is the standard for what the event log keeps: every lifecycle
event for good, and of a job's harness stream only `text`, `delivered`, `started`, `finished`,
`rate_limit` and `memory`, the rest swept 30 days after the job ended (`FORGE_HARNESS_RETENTION_DAYS`)
by a daily sweep and a trigger that shares its one list (`forge_event_swept/1`); `thinking_tokens` is
never recorded. **It is built** (ticket 64), with a job's stream, a ticket's and a conversation's
Activity, the raw log and Talk read a page at a time from the database and read back as far after a
dropped socket, and `limit` and `before` on the API's two event endpoints. **Not verified here:**
loading on a touch scroll on a real phone, and `VACUUM FULL` of a real node's `events` during a deploy.

`docs/design/git-hosting.md` § Git LFS is the standard for large files in a hosted repository: the LFS
batch API, download and upload beside the smart-HTTP requests with the same token, objects kept in
each bare repository's own `lfs/objects` (never in `Forge.Storage`), a `pre-receive` rule that a
pushed branch must not name an object forge does not hold, an LFS push to each mirror before its
refs, a daily deletion of objects nothing has used for 30 days, and **a worker that checks out, resets
and pushes with Git LFS** (protocol 14: no machine below it takes any job). **It is built** (ticket
65). **Not verified here:** GitHub's LFS endpoint with a real mirror, 2 GiB through a proxy, whether
git-lfs honours `http.followRedirects=false`, and a worker against a real platform's endpoint over
HTTP (`docs/design/git-hosting.md` § Git LFS). **Never commit** a `.gitattributes` naming `filter=lfs`,
or a valid pointer at such a path, to forge's own tree: forge is hosted on forge.

`docs/design/pages.md` is the standard for pages: an HTML page a job or a chat writes (`name@` in
`produces`, files flat in `out/<name>/`, `index.html` its entry), hosted by forge at a sub-page of its
own and **sandboxed** (`sandbox allow-scripts`, never `allow-same-origin`) so its script never acts as
the viewer, with a live store of JSON keys of its own that people fill in through a slim forge bar and
a running job reads and writes live through `/job/pages` (`$FORGE_PAGES_URL`), pinned to nothing. It
needs **worker protocol 16**; read it before touching anything a page's script can reach. **It is
being built** (ticket 66): its § Built and § Not built yet say what the code does. **Not verified
here:** iPhone Safari and video scrubbing on a phone, a Codex job's page against OpenAI, a real
worker against `/job/pages`, and Project Sundive's own page (`docs/design/pages.md` § Not verified here).

`docs/design/look.md` is the standard for looking at the platform: `bin/look` opens a page in
headless Chromium as a fixture user over a setup built from the suite's fixtures, runs steps and
takes screenshots, in a network namespace of its own with a database of its own. Every change to
`platform/lib/forge_web/` or `platform/assets/` is looked at by its implementer, judged by a
review lens and shown in the presentation. **It is built**; `bin/look` has run on one machine,
this ticket's (the gate's browser test has passed on a second), and its § Not verified here says what that leaves.

`docs/design/workflow-grammar-v1.md` § Bringing the branch up to date is the standard for the update
step: a state with `on_enter: update`, which the platform runs itself with no job, that merges the
default branch into the ticket's branch (or moves it forward, or leaves it) through its own push,
re-pins the ticket's workflow at the commit it brought the code up to, moves the base, and sends a
conflict to the state it names. **It is built, on the platform alone** (ticket 57): the grammar, the
engine's step, the base in every job's manifest, and the screens; forge's own `dev.yml` and `bug.yml` use it once, as
`refresh` after an approved refinement, and it has not run on a real project.

## Layout

Three Mix projects joined by path dependencies. Not an umbrella.

- `core/` (`forge_core`): workflow parser, event schema, artifact types. No processes.
- `platform/` (`forge`): Phoenix + LiveView platform. Depends on core. Read `platform/AGENTS.md`
  for Phoenix and LiveView conventions.
- `worker/` (`forge_worker`): standalone release for the worker-side agent manager. Depends on core.
- `measure/` (bash): the measurement harness behind `bin/measure`. Not a Mix project.

`flake.nix` provides the devshell and builds both releases. Enter with `nix develop` or direnv.

## Quality gate

Run before every commit, from the repository root:

```
bin/check
```

It lints the shell (shellcheck, shfmt) and runs `mix check` in `core` and `worker`: compile with
warnings as errors, format check, Credo strict, tests with coverage. In `platform` it runs the
same checks, but the tests as **three partitions side by side** (`mix check.static`, then
`mix test --partitions 3 --cover` three times at once, then `mix test.coverage`, which is where
the coverage floor is now checked — a partitioned `--cover` run exports its coverage and reports
none). Each partition also has a `TMPDIR` of its own, and runs with the BEAM's scheduler busy-wait off
(`ERL_FLAGS="+sbwt none …"`: on two cores three spinning BEAMs take CPU from each other, `bin/check`'s
comment has the figures).
`mix check` in `platform` is still the one-process version, which is what to run by hand. A commit
that does not pass the gate is not made.

**Two suites on one machine do not collide on the endpoint.** The platform suite's endpoint
listens on a port the kernel picks (`port: 0` in `platform/config/test.exs`; `Forge.TestEndpoint`
publishes it to everything that builds a URL to it), where it used to take 4002 on the loopback
every job on a machine shares and the second suite died at boot with `:eaddrinuse`. Each partition
has a database (`forge_test<N>`), a data directory (`tmp/test<N>`) and, under `bin/check`, a
`TMPDIR` of its own. No test dials the endpoint on a number written down: one that does asks
`Forge.TestEndpoint` (the other port numbers in the tests are in URLs and arguments that are compared or validated, except port 1, which a few tests and Chromium's `--proxy-server` dial on purpose as an address with nothing on it).
**Not covered:** when `bin/check` can log in to an operator's own postgres on 5432 it uses it, and
two gates then share `forge_test1..3` as they shared `forge_test` before — the gate's own throwaway
postgres, which is what a machine with nothing on 5432 gets, is per run. This also does not close *Jobs on one
machine share a loopback*: the endpoint and chromedriver are still on the shared loopback, on a
port that changes each run.

**A test that waits does not wait for time.** The worker suite's `assert_receive_timeout` is 3 s
(`worker/test/test_helper.exs`), not ExUnit's 100 ms, which a busy machine overran on `LinkTest`'s
wait for `ready`. A timing a test asserts is driven by the test (`start_check` is sent by it, a
clock is a function it holds). A test that leaves a harness running has it killed before its
directory is removed (`ForgeWorker.Fixtures.reap/1`), and no test writes the archive mount to the
application environment, which concurrent tests share: `test_helper.exs` sets the routing mount
once, and it answers each test for the root that test registers
(`ForgeWorker.RecordingMount.watch/2`).

The platform suite runs `git lfs` and `flock`, which the devshell provides (`git-lfs`, `util-linux`):
the LFS tests fail rather than skip without them, so re-enter `nix develop` after the flake changes.

It installs Hex and starts a throwaway postgres first, when the machine has neither — a command
pool's machine has the devshell and nothing else, and without both the gate died before compiling
anything and again at "The database for Forge.Repo couldn't be created". An operator's own Hex and
postgres are left alone, and **whether there is a postgres to leave alone is decided by logging
in, not by asking whether something answers on 5432**: a server an earlier killed run left behind
answers that and then refuses the suite's credentials, and the gate skipped starting its own and
died at authentication. The one it starts listens on a unix socket in a directory only that run
can read and on no TCP port at all, so nothing else on a shared machine can reach it, there is no
password in `config/test.exs` for a job with a checkout to read, and whatever holds 5432 is
irrelevant. It goes when the run does.
`mix deps.get` runs every time, in every project, which is the one of the three steps that
writes to a checkout: it can rewrite `mix.lock` where `mix.exs` has moved on. None of them
relaxes a check — the suite runs against a real database either way.

The gate drives Chromium from the devshell: `platform/test/forge/look/browser_test.exs` and
`installed_app_test.exs` go through `Forge.Look`, so a broken browser setup fails here and not on the
next UI ticket. Their 27 tests start a Chromium each (counted at ticket 80, which added one) and cost about 100
seconds of wall time alone, about 110 CPU-seconds and 450 MiB at the peak (timed at ticket 68's 25 and not
since; it said "about 40 seconds" at eleven tests).
The gate builds the assets it loads (`tailwind forge`, `esbuild forge`) first, and needs `FORGE_CHROMIUM` and `FORGE_CHROMEDRIVER`, which
`nix develop` sets (`docs/design/look.md`).

It also points `MIX_HOME` and `HEX_HOME` at `.mix-home/` and `.hex-home/` inside the checkout,
so that Hex is installed and the registry fetched once per ticket rather than once per job: a
job's `HOME` is its own and goes with the job, while an ignored directory in the checkout is
carried in the ticket's volume from one of its **agent** jobs to the next on the same machine
(`docs/design/worker-tier.md` § The ticket volume). **A command job — which is what runs the gate
automatically — starts cold today:** the volume holds an agent job's sources, plus a build only if
that agent ran one by hand, and `implement.md` tells it not to. A command can keep its build for the
ticket's next command on that machine, but only when its definition in the workflow declares
`keep_build`, and **forge's own `check`, `static` and `test` declare none yet**
(`docs/design/worker-tier.md` § The command copy; `forge-commands-keep-their-build` is the
proposal). Until that merges, each run of them fetches and compiles every dependency. Exported for
the gate's own processes only; your `~/.mix` is not read and not written.

**Export the same two before running `mix` by hand**, which is also how an agent job leaves the
caches warm for the next one:

```
export MIX_HOME="$PWD/.mix-home" HEX_HOME="$PWD/.hex-home"
```

**What a warm job still recompiles** is its own sources, not its dependencies. Mix puts the
working directory into its compile manifest's cache key and a job's worktree is a new absolute
path every job, so the carried `_build/` keeps every Hex dependency compiled and rebuilds
`forge_core`, `forge` and `forge_worker` — 13 seconds for `platform` against 122 from fetched
deps. `worker-tier.md` § The ticket volume has the figures and why no build script can close the
rest.

`platform/priv/git-hooks/` holds the generated git hooks; the gate lints them with the rest of the
shell.

`measure/` holds the measurement harness (`bin/measure`, `docs/design/measurement-harness.md`).
The gate lints it but cannot run it: it needs btrfs, systemd and Nix on the operator's
machine. `bin/measure selftest` is what stands in for a test run.

## Coverage

`mix check` runs `test --cover` against a threshold set per project in `mix.exs`
(`test_coverage: [summary: [threshold: N]]` — nested under `:summary`, because a top-level
`:threshold` is silently ignored and leaves Elixir's default of 90 in force).

**The threshold is a floor and a ratchet.**

- **Raise it whenever the real figure has risen.** If the suite covers 91% and the floor says 83,
  the floor is not doing anything. Move it up to the whole percent below the measured figure as
  part of the same commit that raised the coverage.
- **Never lower it.** Not to make a commit pass, not because something was hard to test, not
  "temporarily". A change that drops coverage below the floor is a change that needs a test.
- **Lowering it requires a human to say so explicitly, for that change.** Not an agent's judgement
  that the code is untestable, and not a note in a commit message. If the floor seems wrong, stop
  and ask.

What the floor catches is the whole class of *nothing tests this at all* — a module, a LiveView, a
context with no test file. It says nothing about whether the tests that exist can fail, which is
what § Testing below is for.

## Testing

Tests are part of the implementation, not a step after it. A change that adds behaviour and no
test is not finished, and neither is one whose tests pass against the broken version.

- **Write the test with the code, in the same commit.** A commit that adds a rule and leaves
  testing it for later is a commit claiming something nothing checks.
- **Watch every new test fail before you keep it.** Break the code it covers — flip the
  comparison, drop the clause, return the wrong default — run the test, see it fail, put the code
  back. A test nobody has seen fail is not a test; it is a claim. This is the single highest-yield
  habit in this repository, and skipping it is how a suite reaches hundreds of green tests that
  defend nothing.
- **Mutate the guard, not the happy path.** The assertion that matters is the one that fails when
  the rule is removed. Authorisation, scoping, ordering, redaction and "must never" rules all
  deserve a mutation aimed squarely at them.
- **When a mutation cannot be caught, say so where it lives.** Some mutations change nothing
  observable — a `@spec`, a log line, a guard whose condition a caller already guarantees, a
  defence against behaviour the current dependency no longer exhibits. Write a comment at that
  code saying it is an equivalent mutant and why, so the next person does not write a test that
  cannot fail. **Never invent a test to cover one**: a test that passes against the broken code
  is worse than no test, because it claims cover it does not give.
- **A new test file is not a substitute for a failing mutation.** Coverage counts lines executed.
  Only a mutation says whether anything would notice them changing.

## Commit messages

**Conventional commits**, for every commit that survives onto `main`:

```
<type>(<scope>)!: <subject>
```

`type` is one of `feat` (something an operator or a job can see that is new or different), `fix`
(a defect), `docs` (notes and prose only), `refactor` (no behaviour change), `test` (tests only),
`build` (the flake, nix, a dependency, release plumbing) or `chore` (everything else). `scope` is
optional, and is the project or the area: `core`, `platform`, `worker`, `measure`, `workflow`,
`release`. `!` marks a breaking change, which here means a migration or a worker protocol bump,
and takes a `BREAKING CHANGE:` footer saying what breaks.

The subject is imperative, under 72 characters including the prefix, and carries no trailing full
stop. Then a blank line, then the body: what changed and why, in prose rather than a list of the
commits that were squashed, including why a dependency was added. Keep the attribution trailers a
session requires on a commit you make yourself. **A `commit-message` document carries none at
all** — the platform writes it to the merge commit exactly as it stands, and both the prompt that
asks a ticket for one (`.forge/agents/present.md`) and the one that asks a conversation
(`core/priv/chat-preamble.md` § The message your merge will carry) say no front matter and no
trailers.

**The commits this governs are the ones that survive**, because the rest do not: a branch lands as
one squashed commit (§ Landing), and a conversation's turn is squashed into one by the platform.
So it is the merge commit an agent writes as `commit-message`, the squash `land` writes, and the
release commit — not a job's working commits, which are thrown away.

**A release is `chore(release): X.Y.Z`**, and that subject is also a marker several places parse.
Anything looking for the last release must match it *and* the `Version X.Y.Z` subject used up to
0.15.0, or the first conventional release leaves every later one computing its diff from 0.15.0:

```
git log -1 --format=%h --grep='^chore(release): [0-9]' --grep='^Version [0-9]'
```

Multiple `--grep` are OR'd, and the parentheses are literal in git's default basic regex — both
checked against a throwaway repository rather than assumed. **The marker does not decide the
bump**: that stays the diff of `platform/priv/repo/migrations` and the worker protocol
(`.claude/skills/release/SKILL.md` § Steps), because a guard must use the same model as the
operation it guards and a `!` in a subject is a claim.

## Reviewing

Work that is committed but not landed gets a pass by reviewers who did not write it: the
`review` skill (`.claude/skills/review/SKILL.md`). It dispatches independent subagents — one on
correctness and security, one mutation-testing whether the new tests can fail, one on duplication
and whether the design notes still describe the code — and they report rather than fix.

`bin/check` says the code runs. This says whether it does what it claims, which is a different
question and the one this repository gets wrong more often.

## Landing

**Landing is never automatic. It happens when a human asks for it, and at no other time.**
Finishing the work, passing the gate and committing to the branch are not a reason to land;
neither is having landed something earlier in the same session. If the work looks ready, say so
and stop. Push the branch if it should be safe from a lost machine — that is not landing.

When asked, work lands on `main` directly, as one squashed commit per branch, fast-forward only.
Use the `land` skill (`.claude/skills/land/SKILL.md`); it rebases, resolves conflicts, squashes
and pushes. No pull requests, no merge commits.

**A landing is released without a second question.** `land` goes on to the `release` skill
(`.claude/skills/release/SKILL.md`), which decides the bump, publishes the platform image with
`GITHUB_TOKEN`, and publishes the worker image the platform is built knowing the checksum of —
checking every credential before it writes anything, and stopping to report only when something
fails. A release builds no Hetzner snapshot and needs no Hetzner credential: the platform builds one in
each account that needs it, on that account's own credential, the first time a template naming
`latest` asks for a machine there (`docs/design/provisioning.md` § Putting the release's image into
an account). The package holding the image has to be public, made so once by hand on GitHub.

## Rules

- Dependency versions are pinned. Do not loosen constraints to get something to compile.
- Prefer Phoenix generators for boilerplate, then edit the generated code.
- Read the docs of a library from `deps/<name>` before using an API you are not certain of.
- Do not add a dependency without saying why in the commit message.
- **A guard must use the same model as the operation it guards.** `Path.expand` is lexical and
  `File.read` follows symlinks, so a string check in front of a filesystem call is decorative.
  The same trap exists wherever validate-then-act uses two different models of the same thing.
- **Fix the class, not the instance.** After fixing a defect, grep for the pattern; fix every
  site or record in the commit message why one was left.
- **Check a claim before writing it down.** "Removed the duplication" means running the count
  both ways; "everything links to X" means grepping for the ones that do not. A note, a comment
  or a commit message that asserts something unverified is the defect this repository produces
  most often — the design notes are the standard precisely so that they can be checked against.
- A handler subscribed to a global topic filters before it does any work.
- Stage the files a commit is about. `git add -A` sweeps unrelated work into it.
