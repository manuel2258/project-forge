# Weekly maintenance: plan

A scheduled ticket with nobody to ask, and nobody to approve the change it ends in: **when the plan
is implemented and the review passes, the change merges.** This step decides whether there is
anything to do, and what. Read `CLAUDE.md`, `docs/decisions.md`, `$FORGE_JOB/tickets/index.md`, and
last week's `implementation.md` and `advisory.md` in `$FORGE_JOB/archive/`, where what was found
and left alone is written down. Files people attached are in `$FORGE_JOB/attachments/`.

**You do not need to do anything.** Most weeks there is nothing meaningful to change, and that is
the right answer: end with outcome `nothing_to_do` and write in `plan.md` what you looked at and
found fine, a line each. **A change is worth planning only if you can say who benefits and how**:
a vulnerability closed, a real bug or hazard removed, a thing a reader can no longer misread,
duplication that has already caused a divergence, a test that could not fail made to fail. Renaming
for taste, reshuffling, bumping a version because it exists, rewording a note that is true and
clear, and style Credo does not ask for are not meaningful. If in doubt, leave it out; a skipped
week costs nothing and a pointless merge costs a review.

If `plan-review.md` is present, the plan was sent back: its findings are the criteria for this
version. Drop an item it calls not meaningful; do not defend it. **You decide what follows**: revise the
plan for what it asks, or, if nothing meaningful is left (the review may say so outright), end
`nothing_to_do`. The review never ends the ticket; you do.

## Look, in this order

1. **Dependencies** (`agents/deps.md`, its audit section first, read-only here): `mix hex.audit` in
   `core/`, `platform/` and `worker/`, OSV for each locked package, `mix hex.outdated`, `flake.lock`
   and what the scripts fetch. A retired or vulnerable package is a priority item. A mere newer
   version is worth a bump only for a fix, a feature forge wants, or because falling further behind
   is costing something; say which.
2. **Cleanup** (`agents/cleanup.md`, its choosing section): smells and bad practices, tests and
   setups included.
3. **Documentation** (`agents/docs.md`): claims that are false or statuses the code has settled.
4. **Advisory** (`agents/advisory.md`, parts 1 and 2): write `advisory.md` (required, every week), and propose tickets
   under `out/proposals/` for what needs a decision. It is written every week, plan or no plan.

## `plan.md`

For each item, in the order the implementation should do them (dependencies, then cleanup, then
documentation): the **evidence** (file and line, advisory id, command output), **why it is
meaningful** and to whom, **what will change** and nothing beyond it, **how behaviour is shown
unchanged** (the test that covers it, or the test to write first), and the **risk**. Then **left
out**, with the reason, and what the audit **could not check**. Every item must be something the
implementer can do and the reviewer can verify without asking you.

Hard bounds, for the plan and so for the change: behaviour does not change; no migration, worker
protocol bump or dependency added or removed; nothing touching authorisation, credentials or
sealing beyond its own tidying; nothing under `.forge/workflows/`, `.forge/forge-release` or
`docs/decisions.md`; no coverage floor lowered. Anything needing a decision is a proposal.

End `done` with a plan of at least one item, or `nothing_to_do` with none.
