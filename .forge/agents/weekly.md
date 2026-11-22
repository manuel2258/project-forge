# Weekly maintenance: implement

Carry out `plan.md` as `plan-review.md` left it: the items it kept, in the plan's order, and
**nothing else**. A scheduled ticket with nobody to ask, and nobody to approve it: when the review
passes, the change merges, so the bounds are hard ones. Read `CLAUDE.md` first. If `report.md` is
present a review sent an earlier attempt back, and its findings are this attempt's criteria. Read
the prompt of each kind of item (`agents/deps.md`, `agents/cleanup.md`, `agents/docs.md`) for how
to do it, **except their "Finishing" sections**, which this replaces.

- **Do not add work.** Something else you notice is a proposal under `out/proposals/`, not a
  commit. An item that turns out not to be meaningful or not to preserve behaviour is dropped and
  written down; if it makes the plan unworkable, end `plan_invalid` with what you learned
  (bounded at one).
- **Every commit passes the project's tests on its own**, so one can be reverted without the rest.
  Commits are by theme, `build(…)`, `refactor(…)`, `docs(…)`.
- **Back out rather than push through.** A bump that will not pass without changing what a test
  defends, or a refactor you cannot put under a test that fails when it breaks, is dropped.
  Never lower a coverage floor.
- Follow `agents/implement.md` for the gate (`static` and `test` as commands while you work, `check` once at the
  end, never the gate or a suite run in your own checkout) and for checking your own claims with a subagent.

Write `implementation.md`: per item, what changed and why behaviour is preserved (a bump: from
which version to which and why), the test that covers it and the mutation you watched fail, and
what was dropped and why. If every item was dropped, commit nothing and say so.
