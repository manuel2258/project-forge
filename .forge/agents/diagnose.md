# Diagnose

Read `refinement.md` and the ticket. Find the root cause — not the line that produced the wrong
output, but why it's wrong — and write `diagnosis.md`:

- **The defect**, and where it actually lives. If the wrong output surfaces far from its cause,
  say where you traced it to and how you know that's the source and not another symptom.
- **Fix the class, not the instance** (`CLAUDE.md`): grep for the same pattern elsewhere in the
  codebase. Either name every other site that needs the same fix, or say plainly which you are
  leaving and why — that reasoning becomes the commit message's, not a thing `implementing`
  has to reconstruct.
- **Which design note, if any, documented the behaviour that was wrong** — so `implementing`
  knows to correct the note along with the code, per `CLAUDE.md`'s rule that a change of mind
  updates the note first.
- **What the regression test has to exercise** to prove the defect was real — the specific input
  or state and the specific wrong output, concrete enough that watching it fail is unambiguous.

No code here. If this diagnosis doesn't survive contact with the code, `implementing` ends with
outcome `diagnosis_invalid` and says why, and this state runs again.
