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

## Anything a person sees gets its own criteria

**If the ticket touches a surface — a page, a row, a form, a label, a notification — read
`docs/design/ui.md` before writing a criterion about it**, and `docs/design/capacity.md` too where
what is drawn is consumption. `CLAUDE.md` makes both the standard for every operator surface, so a
criterion that contradicts one is the same mistake as a criterion that contradicts
`decisions.md`.

Then write criteria about the experience and not only about the data behind it. "The page shows
each credential's usage" is not something `reviewing` can check; "the credential's row draws its
five-hour and weekly windows as percentages, and says what it says when the credential has never
been used" is. What to name, each as its own criterion:

- **Who sees it.** A project member, a project admin, a node admin — what each may reach differs
  (`docs/design/identity.md`), so "visible on the project page" is three criteria or one
  ambiguity.
- **What it says with nothing to show.** `ui.md`'s rule is that an empty state names what would
  fill it rather than announcing absence. That makes the empty state a criterion, not a detail
  for whoever writes the template.
- **What it does while it waits and when it is refused.** A surface has three states besides the
  happy one: nothing yet, still loading, and not allowed.
- **What survives an interruption.** This is the failure this repository actually produces —
  `ui.md` has § A reconnect is not a reload for it, and the open ticket proposals still include
  forms that lose what was typed when the socket drops. If the ticket adds a form, a draft or a
  half-finished answer, a criterion saying what is still there after a reconnect is the most
  valuable one on the list.
- **The phone.** "A phone can do everything a laptop can": the layout changes with the width and
  what a person can reach and do does not. A criterion true only at laptop width is half a
  criterion.
- **What a long, large or hostile value does to it.** A 200-character name, a list of four
  hundred, a title with markup in it, a value that is absent. The page staying readable is a
  criterion; so is what it does instead of breaking.

Still what and not how. Which component, which colour, which breakpoint is `planning`'s decision
and `ui.md`'s rule; what you owe is what the person must be able to see and do, in words a review
can hold the finished page against.

Ask a blocking question next to the criterion or non-goal it concerns whenever the ticket leaves
it ambiguous — in the document, not in a side channel. Do not guess at scope, and do not describe
how the work will be done; that is `planning`'s job, not this one.

A human approves this document before `planning` ever runs. Write it as something meant to be
read once and trusted, not iterated on.
