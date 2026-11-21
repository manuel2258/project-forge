# Cleanup

A scheduled ticket, admitted on a clock with nobody to ask. Find code smells and bad practices in
this repository and refactor them **without changing behaviour**. Read `CLAUDE.md` first, and
`docs/decisions.md` and the design note of whatever you touch.

If `report.md` is present a review sent an earlier attempt back: its findings are this attempt's
acceptance criteria. If `feedback.md` is present a person declined the presented change: its
latest version is the criteria, above `report.md`. Files people attached are in
`$FORGE_JOB/attachments/`; read them when the ticket or feedback mentions one.

## Choosing the work

- **Look at what changed lately, and at what was never looked at.** `git log --since='30 days ago'
  --stat`, then the largest and most-churned modules. Read `$FORGE_JOB/archive/index.md` and
  `$FORGE_JOB/tickets/index.md` so that you do not redo, or undo, what a ticket decided.
- **Look for**: duplicated logic (count both ways before claiming it removed), functions and
  modules that do several things, dead code (grep every caller, including tests, templates and
  `.forge/`), stale or contradicting comments, swallowed errors, validate-then-act guards that use
  a different model from the operation they guard (`CLAUDE.md` § Rules), needless indirection, and
  Credo or shellcheck suppressions that no longer suppress anything.
- **Fix the class, not the instance**: when you find one, grep for the pattern and fix every site
  or say why one stays.
- **No line limit, but a reviewer must be able to follow it.** Do as much as is worth doing, in
  separate commits by theme (`refactor(core): …`, `refactor(platform): …`), each of which passes
  on its own, so that the reviewer can read them one at a time. Rank findings by value against
  risk and stop when the rest is not worth the risk; note what is left.
- **Everything in the repository is in scope**, tests and their support included: duplicated or
  slow fixtures, setups under `platform/test/support/look/setups/`, helpers, flaky waits, tests
  that pass against broken code (`CLAUDE.md` § Testing), scripts under `bin/` and
  `.forge/commands/`, and design notes that no longer describe the code. A test you change keeps
  or raises what it defends: show with a mutation that it still fails when the guard is broken.

## Bounds

- **Behaviour does not change.** No new feature, no changed output, no migration, no worker
  protocol bump, no dependency change, no coverage floor lowered. A fix that needs one is not
  cleanup: propose a ticket under `out/proposals/` and leave the code alone.
- **A refactor needs a test that would notice it going wrong.** If the code has none, write the
  test against the *old* code first, watch it pass, refactor, watch it pass again; then break the
  new code and watch it fail (`CLAUDE.md` § Testing). Do not touch code you cannot cover; list it.
- A design note that describes the code you change is updated in the same commit.
- Nothing under `.forge/workflows/`, `.forge/forge-release` or `docs/decisions.md`: those are a
  person's. Prompts and commands may be tidied only if a finding is about them.
- Doubtful that something is dead or wrong? Leave it and say so; a smell you were unsure of is a
  question for a person, not a deletion.

## Finishing

Follow `agents/implement.md` for running the gate (only the touched tests while you work, `check`
once at the end, exports of `MIX_HOME` and `HEX_HOME`) and for checking your own claims with a
subagent before you end. Commit in conventional form (`refactor(<scope>): …`).

Write `implementation.md`: what you looked at, what you changed and why each is behaviour
preserving, the test that covers each and the mutation you watched fail, and **what you found and
left alone** with a line each, so next week starts from it. If there was nothing worth changing,
say so, commit nothing and write that; do not invent a refactor.
