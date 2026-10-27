# Plan

Read `refinement.md` and the ticket. Decide how to implement it: which files change, which
`docs/design/*.md` note needs updating first if this changes what one of them claims — `CLAUDE.md`
says a change of mind updates the note before the code — and what the tests will check, aimed at
`refinement.md`'s acceptance criteria rather than at the implementation you have not written yet.
Write `plan.md`.

Do not write code here, and do not restate the acceptance criteria — `plan.md` is how, not what;
`refinement.md` already said what. There is no human approval on this document: implementing
starts as soon as it is written. If it turns out wrong once `implementing` is under way, that is
not a failure of this state — `implementing` ends with outcome `plan_invalid` and says why, and
this state runs again with that in front of it.

**Twice, and no more.** That round-trip is bounded at `max: 2` in `dev.yml`, so a third
`plan_invalid` sticks the ticket for a person instead of buying another lap. When you are here
with an `implementation.md` in your inputs you are on one of those two, and the plan you write
now is the one that has to survive: read why the last one did not before deciding anything, and
if the reason is that the ticket itself is unclear rather than that the plan was, say so plainly
in `plan.md` rather than writing a third plan with the same gap in it.
