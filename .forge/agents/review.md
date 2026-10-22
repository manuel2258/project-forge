# Review

Run the `review` skill (`.claude/skills/review/SKILL.md`) against this ticket's changeset, over
`git diff origin/main..HEAD`.

## A later round is not the first round again

`report.md` is an input here, and it is this state's own last version: when it is present, you
have been round before and it says what you found. **Scope the round to that.** Verify the fixes
to the findings it lists, reproducing each as step 4 requires, then review what has changed since
the commit that version reviewed — not the whole changeset over again.

This is where the money goes. Ticket 7's second review cost $21.96 re-deriving a diff it had
already read, because `report.md` was not an input and nothing told it what it had already found;
its eighth, scoped to one integration and sixteen mutations, cost $4.13 and was the more useful
document. A full re-read of unchanged code is not thoroughness, it is the same reading bought
twice.

What a later round still owes the person: say which findings are closed and how you checked,
which survived, and what the new work brought with it. A closed finding is worth a line, not a
re-litigation.

## The lenses, and the model each runs on

Four lenses: the skill's three — correctness and security; whether the new tests can fail, proven
by mutating the code and re-running them; DRY, KISS and design-note fidelity — and
`refinement.md`'s acceptance criteria, which this state adds so that a change passing all three
and still missing what it was asked for is a finding.

How many reviewers that is, the skill's step 1 decides from the size of the diff, and it still
does. Below a few hundred lines, one reviewer carries correctness, DRY/design-fidelity and the
criteria together; past that, split them.

**Two of the four lenses run on `sonnet`, and for the same reason: their answer is a comparison,
not a judgement.**

- *The mutation lens, always its own reviewer.* Breaking a line, re-running the tests it covers
  and reporting which noticed is mechanical, with a right answer the output shows.
- *DRY, KISS and design-note fidelity.* Whether a note still describes the code is read off the
  two texts. Ticket 7's rounds are the evidence: every finding this lens produced was a
  comparison anyone could check — the stated reason for a protocol bump backwards in both the
  note and the function's own doc, two measured figures wrong (48 ms written as two seconds;
  13,107 as tens of thousands), a stale comment three lines from the one it had corrected. None
  of them needed the larger model to see, and paying for it on all four lenses is how a review
  reaches $29.69.

**Correctness and security, and `refinement.md`'s acceptance criteria, stay on this job's model.**
Those are the readings where judgement is the whole value, and they are where this state earns
its budget: the three findings on ticket 7 that a person would otherwise have lived with — a
binary file taking the merge page down through the JSON encoder, `optional` letting a job discard
the outcome it declared, a 1 MiB cap bypassed through a gitlink — all came from them.

**The mutation lens reads the changeset's guards, not the suite.** Point it at the authorisation,
scoping, ordering, redaction and "must never" checks *this diff adds or touches*, and at the tests
this diff adds — not at the project's existing coverage, which is not this changeset's claim to
defend. Name the files. A mutation that cannot be caught is a finding only if the code has no
comment already saying so (`CLAUDE.md` § Testing).

**Reproducing a finding is yours and stays yours.** The skill's step 4 says to re-run the sharpest
findings before repeating them, and it means by hand, a command each — not by dispatching a
reviewer per finding. A verifier per finding is both the thing that eats this state's budget and a
delegation of the one judgement step 4 exists to keep.

**A lens you dispatch is a lens you wait for, in the same turn.** Never leave a reviewer running
in the background and end your turn: the job ends when your turn does, and the subagent is killed
unread. This has happened — ticket 7's `reviewing` attempts 6 and 7 both dispatched the mutation
lens in the background, both ended their turn, both had it killed, and both reported `done`. The
pass neither had run found two uncaught mutations when attempt 8 finally ran it in the foreground.
So: dispatch the lenses you need, then block on them before you say anything. If a lens cannot
finish at all, name it in the report as not run and take the verdict rule below — an unrun lens
named is worth something, an unrun lens reported as clean is worth less than nothing.

## Write `report.md` as you go

Create `report.md` as soon as you have confirmed a finding, and write it again as each later lens
reports in. Do not hold everything for one write at the end: this state can stop on its cost
budget inside a single turn of yours, and what is on disk then is the whole of what a person gets.
A report listing two confirmed findings and saying which lenses had not reported yet is worth a
great deal; an empty `out/` is worth nothing.

**Name the commit you reviewed, in every version.** `git rev-parse HEAD` in the opening lines,
beside the base you diffed against. It is what makes the scoping above possible: the next round
reads this document to find out where to start, and a report that does not say what it covered
leaves it no choice but to read everything again. It is also what tells a person whether the
report beside the diff is the one for that diff.

**Every write leaves a whole document** — the front matter opened and closed, the prose finished.
A half-written file is not a shorter report, it is no report: a `report.md` whose `---` block is
open does not parse, so it is refused rather than stored and the person reaches `review_ready`
with nothing. Compose the new version and write it in one go, rather than appending to the file on
disk.

**The verdict is written last, and until then it is `did_not_converge`.** Every version you write
before the final lens has reported carries `outcome: did_not_converge`, whatever it has found so
far, because the job can end at any moment and whatever is on disk then *is* the outcome — the
engine reads the document, not your intent. A review that stops with lenses outstanding has no
verdict, and `did_not_converge` is how a state says so: it costs a bounded retry, where a
premature `done` costs a person merging work on a review that never ran.

Then, once every lens has reported: `outcome: issues_found` if anything survived verification.
`outcome: done` only when nothing did, or when something was found and held up under scrutiny as
acceptable — say which, and why, rather than letting it drop silently.

A ceiling is not your business here. A job stopped by its turn, cost or wall-clock budget is
`budget_exhausted` whatever the document says, and that edge goes forward to `presenting` so the
partial report reaches someone. What you control is the case where nothing stopped you and you
simply had not finished.

Do not fix anything here. Fixing is `implementing`'s job on the next pass, with this document as
its input.
