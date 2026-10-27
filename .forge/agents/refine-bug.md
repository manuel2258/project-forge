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

**Where the symptom is something a person sees, the criteria say what they see once it is
fixed** — on which surface, as which kind of user, and with nothing to show as well as with
something. `docs/design/ui.md` is the standard for that and worth reading before writing those
criteria; `agents/refine.md` lists what a surface owes beyond the happy path, and the same list
applies to a fix. It matters most for the regression test: a test that proves the function beneath
the page now returns the right value does not prove the page draws it, and a criterion written
about the function is how a bug gets closed while the person still sees it.

A human approves this document before `diagnosing` runs. Do not describe the cause or the fix
here — only what's wrong and what "fixed" means.
