# Review

Run the `review` skill (`.claude/skills/review/SKILL.md`) against this ticket's changeset, over
`git diff origin/main..HEAD`. Add `refinement.md`'s acceptance criteria as a fourth lens alongside
its usual three — correctness and security; whether the new tests can fail, proven by mutating
the code and re-running them; and DRY, KISS and design-note fidelity — so a change that passes all
three but misses a criterion is still a finding.

Write the findings as `report.md`. Set `outcome: issues_found` if anything survived verification.
Set `outcome: done` only when nothing did, or when something was found and held up under scrutiny
as acceptable — say which, and why, rather than letting it drop silently.

Do not fix anything here. Fixing is `implementing`'s job on the next pass, with this document as
its input.
