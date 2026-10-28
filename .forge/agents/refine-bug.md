# Refine (bug)

Run this step the way `.forge/agents/refine.md` describes — a conversation that grills the person
one question at a time, with your recommendation on each, phase by phase, writing `refinement.md`
as it goes — and read that file first. This one says only what is different when the ticket is a
defect. The person approves the result with Accept, and `diagnosing` starts from it.

**Reproduce it before you ask how.** You have the checkout and the devshell. Try the ticket's steps
yourself, and come to the first question with what you saw: reproduced, with the output, or not,
with what you tried. A bug nobody can reproduce is the first thing to settle, not the last.

The same five phases, aimed at what is wrong:

1. **Pin down the defect.** What happens now and what should happen, a sentence each. The exact
   reproduction — a command, a URL, an input — precise enough that `diagnosing` can run it without
   guessing. Since when (`git log`, the archive), who meets it and how often. Every criterion is a
   case that is wrong today and must be right after the fix, and one of them is always that a
   regression test exists which fails against the current code and passes once the fix lands.
2. **What a person sees.** When the symptom is visible, what they see once it is fixed, on which
   surface, as which kind of user, and with nothing to show as well as with something.
   `refine.md`'s list of what a surface owes applies to a fix too. It matters most for the
   regression test: a test showing the function under the page now returns the right value does
   not show the page draws it, and a criterion written about the function is how a bug gets closed
   while the person still sees it.
3. **Security.** First, whether the bug is itself a security defect: something read or written by
   someone who should not reach it, a guard that can be passed, a secret shown. If it is, say so
   before anything else. It changes what the criteria must cover — every path to the same data, not
   only the one reported. Then whether the fix moves a guard, and the rest of `refine.md`'s list.
4. **Out of scope.** The related wrongness this ticket leaves alone. A bug is where "while I'm in
   here" pulls hardest, so name what is left, and file a proposal for anything that deserves one.
5. **Earlier work.** The ticket or commit that introduced it, if you can find it (`git log -S`,
   `git blame`, the archive); an earlier fix of the same defect somewhere else, since `CLAUDE.md`
   says to fix the class and not the instance; and the design note that described the wrong
   behaviour as right, which the fix will have to correct.

Record what you observed, not why it happens. The reproduction, its output and the commit that
introduced it are facts `diagnosing` can use. A theory of the cause, or of the fix, is
`diagnosing`'s to form from the code, and one written here is a theory it will anchor on.
