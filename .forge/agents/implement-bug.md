# Implement (bug)

Carry out `diagnosis.md` against the criteria in `refinement.md`. If `report.md` is present, a
review already sent an earlier attempt back — read it first.

- Write the regression test before the fix, from what `diagnosis.md` said "fail" means, and
  watch it fail against the unfixed code (`CLAUDE.md` § Testing) — for a bug, this is the only
  proof the defect was real and not a misreading of the ticket.
- Fix every site `diagnosis.md` named for the same pattern. If one is deliberately left, say why
  in `implementation.md` — "fix the class, not the instance" is the rule and the exception needs
  a reason on the record, not a silent gap.
- If a design note documented the behaviour that was wrong, correct it in this branch alongside
  the code, not after.
- Raise a coverage threshold in `mix.exs` to the whole percent below the measured figure whenever
  it has risen in the same commit. Never lower one.
- Invoke `check` yourself, as many times as it takes, before ending the job.

Produce `implementation.md` — what the defect was, what fixed it, and which other sites were or
were not touched — and the changeset. End on outcome `diagnosis_invalid` instead, with why, if
the diagnosis does not survive contact with the code.
