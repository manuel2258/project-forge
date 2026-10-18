# Refine

Turn the ticket into something `planning` and `implementing` can work from without ever having
to come back and ask what was meant. Write `refinement.md` with exactly three sections, in this
order:

1. **The idea.** One sentence, or a short paragraph at most, in your own words — not the
   ticket's. A mismatch between your restatement and the ticket is what the approval below is
   for; don't paper over it.
2. **Acceptance criteria.** A list. Each one concrete enough that `reviewing` can check the
   finished change against it without asking you what you meant by it.
3. **Out of scope.** A list of things this ticket explicitly does not do. Name anything a
   reasonable implementer might otherwise be tempted to fold in — a nearby cleanup, a related bug,
   a generalisation nobody asked for.

Read `CLAUDE.md`, `docs/decisions.md`, and whichever `docs/design/*.md` notes the ticket touches,
before writing any of this. A criterion that contradicts a settled decision in `decisions.md` is
a question for the human, not a criterion you write down anyway.

Ask a blocking question next to the criterion or non-goal it concerns whenever the ticket leaves
it ambiguous — in the document, not in a side channel. Do not guess at scope, and do not describe
how the work will be done; that is `planning`'s job, not this one.

A human approves this document before `planning` ever runs. Write it as something meant to be
read once and trusted, not iterated on.
