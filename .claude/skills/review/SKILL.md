---
name: review
description: Critically review unlanded work with independent subagents — correctness and security, whether the tests can fail, and DRY/KISS plus design-note fidelity. Findings only; fixing is a separate decision.
---

# review

A pass over work that is committed but not landed, done by reviewers who did not write it.

**Why it is not done in-process.** The author cannot see the assertion that matches the layout
instead of the feature, because the author is the one who thought it matched the feature. The
first run of this on a twelve-commit branch found five tests that asserted nothing, a security
guard that did not guard, and three commit messages claiming work that had not happened — none
of which the author had noticed while writing all of it.

## When

Before asking for landing, and any time the branch has grown past what one reading holds.

Not a substitute for `bin/check`. The gate says the code runs; this says whether it does what it
claims.

## Scope

`git log --oneline origin/main..HEAD` and `git diff origin/main..HEAD`. Run
`git fetch origin main` first so the range is honest.

## Steps

1. **Establish the range and its size.** If the diff is under a few hundred lines, one reviewer
   is enough and the lenses can be combined. Past that, split — three lenses over 3,000 lines
   beats one lens over 3,000 lines three times.

2. **Dispatch the reviewers in parallel**, one message, several agents. Each gets the range, one
   lens, and the standing instructions below. The lenses:

   - **Correctness and security.** New endpoints and their authentication; anything that
     validates then acts; totality of new pattern matches; queries without an index; secrets that
     have moved somewhere new; shell quoting; config that changes what a release binds or reads.
   - **Test correctness.** Whether the new tests can fail. This lens **mutation-tests**: it
     breaks the production code, re-runs, and reports which tests noticed. A finding here is
     worthless without that evidence.
   - **DRY, KISS and design-note fidelity.** How many copies of a thing exist now versus before;
     whether an extraction removed duplication or merely rehoused it; and every new or changed
     claim in `docs/design/` checked against the code. In this repository the notes are the
     standard (`CLAUDE.md`), so a note that says something the code does not is a defect and not
     a documentation nit — this is usually the highest-yield lens.

   Name the riskiest files explicitly in each prompt. A reviewer told where to look finds more
   than one told to look everywhere.

3. **Standing instructions for every reviewer**, in the prompt:

   - Verify; do not speculate. Every finding carries a concrete failure scenario — specific
     inputs or state, and the specific wrong outcome.
   - Where a claim is cheap to test, test it. Running the suite and probing the code is expected.
   - Report, do not fix. Fixing is the author's decision and a separate step.
   - Leave the tree exactly as found. Revert every experiment and confirm `git status --porcelain`
     is empty at the end.
   - Rank by severity, most severe first. Say plainly when nothing severe was found rather than
     inflating what is left.
   - List what was probed and held up, under its own heading. Knowing the confinement was
     attacked and refused `..` is worth as much as knowing it followed symlinks.

4. **Reproduce the sharpest findings yourself before repeating them.** Reviewers are wrong
   sometimes, and a finding you have not seen is a finding you cannot defend. This costs a
   command each and has twice caught a reviewer's misreading before it reached the user.

5. **Report.** Group by severity, not by reviewer. Say which findings land on your own claims —
   those are the ones the exercise was for. Keep what held up: it is the difference between "no
   problems found" and "attacked and did not break".

6. **Fix as a separate decision**, and when fixing:
   - One commit per category — security and correctness, tests, duplication and notes — never
     one commit for all of it.
   - Re-run the mutation after fixing a test that could not fail. A test you have not seen fail
     is still not a test.
   - Expect your own fixes to be wrong. In the first run, a filter on ticket events excluded the
     newly-admitted ticket it existed to show, and two new tests were themselves broken. The
     suite caught all three, which is the point.

## What the first run found, as a calibration

Every defect was the same shape: **a claim that nothing checked.** A moduledoc claiming a
confinement the code did not perform; a commit claiming duplication it had not removed; a comment
claiming workflow order above an alphabetical sort; five tests claiming behaviour they never
asserted. When a reviewer reports something that feels like a nit, ask whether it is this shape.
It usually is.

The rules distilled from it live in `CLAUDE.md` § Rules and `platform/AGENTS.md` § Testing, and
the one mechanised trap is `platform/test/forge_web/live/assertion_probe_test.exs`.
