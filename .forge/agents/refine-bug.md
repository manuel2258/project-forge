# Refine (bug)

Write `refinement.md` in the same three sections every ticket uses, framed around what's wrong
rather than what's new:

1. **The idea.** Current behaviour versus expected behaviour, each in a sentence, plus exact
   reproduction steps — a command, a URL, an input — if the ticket doesn't already give them
   precisely enough that `diagnosing` can act without guessing.
2. **Acceptance criteria.** Each one a case that is wrong today and must be right after the fix.
   Include, explicitly, that a regression test exists which fails against the current code and
   passes once the fix lands — not optional for a bug ticket, the way it might be debatable
   elsewhere.
3. **Out of scope.** Related wrongness this ticket does not fix. A bug report is where "while
   I'm in here" temptation is strongest; name what you're leaving so nobody expands the fix into
   a cleanup.

Read `CLAUDE.md`, `docs/decisions.md`, and whichever `docs/design/*.md` notes the area touches,
before writing any of this — a fix that would contradict a settled decision is a question for the
human, not a criterion. Ask a blocking question next to the criterion or non-goal it concerns
whenever the ticket leaves it ambiguous.

A human approves this document before `diagnosing` runs. Do not describe the cause or the fix
here — only what's wrong and what "fixed" means.
