# Implement

Carry out `plan.md` against the criteria in `refinement.md`. If `report.md` is present, a review
already ran against an earlier attempt and sent it back — read it first, and treat its findings
as the actual acceptance criteria for this attempt, not advice to weigh against your own judgement.

- If a design note's claim about the code changes, edit the note in this branch before the code
  that makes the claim true — not after, and not left for someone else (`CLAUDE.md`).
- Write the test with the code that needs it, in the same commit. Watch each new test fail before
  keeping it — break the code it covers, run the test, see red, put the code back
  (`CLAUDE.md` § Testing). A test nobody has watched fail is a claim, not a test.
- Aim mutations at guards, not at the happy path: authorisation, scoping, ordering, redaction,
  "must never" rules.
- Raise a coverage threshold in `mix.exs` to the whole percent below the measured figure whenever
  it has risen in the same commit. Never lower one — if the floor seems wrong, that is a question
  for the human, not a number to edit.
- Invoke `check` yourself, as many times as it takes, before ending the job. A failure you catch
  here costs this job a turn; one you don't costs a trip back through `checking` and counts
  against its retry limit. **If what is left of the cost budget will not carry the resume** — the
  job parks while the command runs and comes back with its context primed again, which is not
  free — run the gate's own commands in this checkout instead and say in `implementation.md`
  which you did. `check.sh` is `bin/check` behind a machine-capability guard, so the checks are
  the same ones; what the command adds is a clean machine's verdict. Every one of ticket 7's four
  attempts made this choice and each wrote a paragraph apologising for it: it is a legitimate
  choice, and this is it being written down rather than re-litigated per attempt.

## Check your own claims before you declare done

The cheapest finding is the one a $35 review never has to pay for. Ticket 7's second review
round cost $21.96 and $9.73 to fix, and most of what it reported was not code: the stated reason
for a protocol bump backwards in both a design note and the function's own doc, two measured
figures wrong (48 ms written as two seconds, 13,107 as tens of thousands), a stale comment three
lines from the one the same commit had corrected, five new guards with no failing mutation — one
of them under a comment asserting that the ordering "is asserted". Every one of those is a
comparison against the diff, and none of them needed a reviewer to find.

So before you write the outcome, dispatch a **`sonnet` subagent** over your own diff and
`implementation.md`, and wait for it in the same turn. What it buys is not a bigger or a smaller
mind — this job runs on `sonnet` too — it is a reader who did not write the diff and has no memory
of having meant something by it, which is the whole reason the `review` skill exists at all. Give it exactly this to do, and nothing
else — it is not a reviewer and must not fix anything:

- Every factual claim in `implementation.md` and in each design note this branch edited: is it
  true of the diff? Measured figures, counts, file and function names, "every", "none", "now
  always".
- Every claim that a mutation was watched failing: does the test it names actually fail when the
  line it covers is broken?
- Every comment the diff adds or touches that asserts something — "bounded at", "is asserted",
  "cannot" — against the code beside it.

**On an attempt a review sent back, point it at what this attempt changed first.** From the second
round on, most of what a review finds is what the last fix broke: a new branch with no test that
fails without it, a new sentence that is not true. Ticket 26's second review found "the fix opened
the dead end", and ticket 28's "the fix opened a new hole". The lines you just wrote are the ones
nobody has read yet.

Fix what it finds, in this job. What you cannot fix, say plainly in `implementation.md` rather
than leaving it to be found: a claim you have withdrawn costs nothing, and one a reviewer
catches costs a round trip.

**The last gate run is on the commit you end on.** What the subagent made you change is a change
like any other, and so is every edit after your last `check`. If anything changed since the last
passing run, invoke it again, or, when the budget will not carry the resume, run at least
`mix format` and `mix credo --strict` in each project you touched. Ticket 24's gate passed, the job
kept editing, and it ended on one line 128 characters long, which `checking` refused at the price
of a whole further attempt.

Produce `implementation.md` — what changed and why, in prose a reviewer can check against
`refinement.md` — and the changeset. End on outcome `plan_invalid` instead, with why, if the plan
does not survive contact with the code.

**That outcome is bounded at two** (`dev.yml`), so it is for a plan that is wrong and not for a
plan that is merely inconvenient: a step you can carry out differently and say so in
`implementation.md` is not `plan_invalid`. Say what specifically cannot be done and what you
learned that the plan did not know, because `planning` gets this document and has two tries.
