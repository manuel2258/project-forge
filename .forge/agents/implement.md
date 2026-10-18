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
  against its retry limit.

Produce `implementation.md` — what changed and why, in prose a reviewer can check against
`refinement.md` — and the changeset. End on outcome `plan_invalid` instead, with why, if the plan
does not survive contact with the code.
