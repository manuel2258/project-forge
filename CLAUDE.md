# forge

Read `docs/vision.md` for what this is, `docs/decisions.md` for what is settled, and
`docs/poc-plan.md` for what is being built and in what order. Design notes for the current
milestone live in `docs/design/`; code follows them, and a change of mind updates the note first.

`docs/design/ui.md` is the standard for every operator surface and `docs/design/capacity.md` for
how consumption is modelled and drawn. Read both before changing anything the operator sees.

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

`docs/design/provisioning.md` is the standard for what a job asks for and where a machine comes
from: resources declared per job, a gate on kind as well as memory and cores, worker templates as
a recipe the platform creates from, per-user provider credentials, and a driver registry in place
of one global provider. It supersedes the single `slice_bytes` gate in
`docs/design/worker-tier.md` § Scheduling and is read together with `docs/design/commands.md`,
which holds the grammar half. **It is built**, `resources` on a *command* included. The Hetzner
driver has created and destroyed real Hetzner machines; none has yet connected to a platform and
run a job.

`docs/design/commands.md` is the standard for commands: a fixed script a workflow declares once,
run as a job of its own — by a command state on entry, its exit statuses mapped to an outcome, or
by an agent that writes `$FORGE_JOB/invoke.json` and parks until its commands are done. **It is
built**, and so are groups of files (`name/*` in `produces`, for an agent or a command): each file a
blob on the ticket, uploaded under a prefix token of the job's own, and downloaded rather than shown
unless it is small text. What a real build looks like on a real command pool is unobserved here:
the worker's side is tested against scripts in a temporary directory, not against `nix develop` on
a machine.

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

It lints the shell (shellcheck, shfmt) and runs `mix check` in every project: compile with
warnings as errors, format check, Credo strict, tests with coverage. A commit that does not pass
the gate is not made.

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
`GITHUB_TOKEN`, and builds the Hetzner worker snapshot with `HCLOUD_TOKEN` and the ssh key in
`HETZNER_PRIVATE_KEY` when the worker changed — checking every credential before it writes
anything (`bin/hetzner-image --check` for the Hetzner ones), and stopping to report only when
something fails. Pointing a template at a new snapshot stays the operator's.

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
