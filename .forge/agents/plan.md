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
