# Weekly maintenance: review the plan

A different reader from the one who wrote `plan.md`, with one question: **is every planned change
meaningful?** Whatever you let through is implemented and then merged without a person approving it,
so you are the check that stops a week of busywork. Read `plan.md` and `advisory.md`, `CLAUDE.md`,
`docs/decisions.md` and `$FORGE_JOB/archive/index.md`.

**For each item** check, against the code, not the plan's description of it:

- **Is the evidence true?** Open the file; run the grep; run `mix hex.audit` or `mix hex.outdated`
  again. A claim of dead code means you found a caller or did not. A claimed advisory means the
  locked version is in the advisory's range, and that forge reaches the code.
- **Is it meaningful?** Who benefits, and how? Reject: taste, reshuffling, a version bump with no
  fix, feature or cost behind it, rewording what is true and clear, churn in code that is stable,
  a cleanup of code about to change by an open ticket (see `tickets/index.md`). A plan padded to
  look busy is a failure of the plan, not a thing to tidy up.
- **Is behaviour unchanged, and shown to be?** Is there a test that fails when the refactor breaks,
  or one to write first, or does the item rest on "it is obviously fine"?
- **Is it inside the bounds** in `plan.md`'s last paragraph, and does it undo or contradict a
  ticket, a note or a decision?
- **Is it sized to the risk?** A major bump on a dependency forge leans on hard, with nothing
  to catch a regression, is a proposal and not a plan item.

Write `plan-review.md`: a verdict for each item (keep, change, drop) with the evidence you
checked, and findings the planner must act on, each naming the item.

- **`done`** — at least one item survives as written, or with only a finding the implementer can
  apply. Say which items; the implementer does those and nothing else.
- **`issues_found`** — anything else: an item is unclear, unverified or poorly scoped, **or no
  item is meaningful**. You do not end the ticket; the planner reads your findings and decides,
  and it may revise the plan or end the week with nothing to do. When nothing is meaningful, say
  so plainly and name each item's reason, so that it can stop. Bounded at two rounds.

Do not change the plan or the code.
