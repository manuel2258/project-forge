# Review

Run the `review` skill (`.claude/skills/review/SKILL.md`) against this ticket's changeset, over
`git diff origin/main..HEAD`.

## The lenses, and the model each runs on

Four lenses: the skill's three — correctness and security; whether the new tests can fail, proven
by mutating the code and re-running them; DRY, KISS and design-note fidelity — and
`refinement.md`'s acceptance criteria, which this state adds so that a change passing all three
and still missing what it was asked for is a finding.

How many reviewers that is, the skill's step 1 decides from the size of the diff, and it still
does. Below a few hundred lines, one reviewer carries correctness, DRY/design-fidelity and the
criteria together; past that, split them. **The mutation lens is always its own reviewer, and runs
on `sonnet`** — breaking a line, re-running the tests it covers and reporting which noticed is
mechanical, with a right answer the output shows. The other three are the readings where
judgement is the whole value, and they stay on this job's model.

**The mutation lens reads the changeset's guards, not the suite.** Point it at the authorisation,
scoping, ordering, redaction and "must never" checks *this diff adds or touches*, and at the tests
this diff adds — not at the project's existing coverage, which is not this changeset's claim to
defend. Name the files. A mutation that cannot be caught is a finding only if the code has no
comment already saying so (`CLAUDE.md` § Testing).

**Reproducing a finding is yours and stays yours.** The skill's step 4 says to re-run the sharpest
findings before repeating them, and it means by hand, a command each — not by dispatching a
reviewer per finding. A verifier per finding is both the thing that eats this state's budget and a
delegation of the one judgement step 4 exists to keep.

## Write `report.md` as you go

Create `report.md` as soon as you have confirmed a finding, and write it again as each later lens
reports in. Do not hold everything for one write at the end: this state can stop on its cost
budget inside a single turn of yours, and what is on disk then is the whole of what a person gets.
A report listing two confirmed findings and saying which lenses had not reported yet is worth a
great deal; an empty `out/` is worth nothing.

**Every write leaves a whole document** — the front matter opened and closed, the prose finished.
A half-written file is not a shorter report, it is no report: a `report.md` whose `---` block is
open does not parse, so it is refused rather than stored and the person reaches `review_ready`
with nothing. Compose the new version and write it in one go, rather than appending to the file on
disk.

Set `outcome: issues_found` if anything survived verification. Set `outcome: done` only when
nothing did, or when something was found and held up under scrutiny as acceptable — say which, and
why, rather than letting it drop silently.

Do not fix anything here. Fixing is `implementing`'s job on the next pass, with this document as
its input.
