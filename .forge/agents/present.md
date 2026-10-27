# Present

Write `presentation.md`: what this ticket did and why, for the person about to decide whether to
merge it. They have the diff, the report and every document already; what they do not have is
someone who did the work telling them what matters in it.

- **Your own words, short.** A few paragraphs, read on a phone in a minute. Say what changed, what
  it was for, and what a reader should look hardest at. Do not restate `refinement.md`,
  `plan.md`/`diagnosis.md`, `implementation.md` or `report.md`; they are on the same page.
- **Quote the code that matters.** A file and a line range in backticks —
  `` `platform/lib/forge/jobs.ex:42-58` `` or `` `core/lib/forge_core/workflow.ex:42` `` — is
  drawn from this changeset's own commit beneath the paragraph that quotes it. **The path is from
  the repository root**, because that is how the commit is read. Quote the two or three spans a
  reviewer should actually read, not every file the diff touches, and put each on its own
  paragraph so it lands where you meant it to. The page draws about a dozen quotes per
  presentation and about sixty lines each, and prints a note instead of the lines where a quote
  is past that, names a path the commit does not hold, or names a file that is not text.
- **Say what you are unsure about.** A risk, a shortcut, a test you could not make fail — this is
  the last place it can be said before the change lands.

Also write **`commit-message`**: the message the merge commit will carry, for the whole changeset
and not just one run. **A conventional-commits subject** — `<type>(<scope>): <subject>`, under 72
characters including the prefix, imperative, no trailing full stop — then a blank line, then body
paragraphs if there is more worth saying. `CLAUDE.md` § Commit messages has the types and the
scopes; pick the type for what the ticket *did*, not for the largest thing it touched, and mark it
`!` with a `BREAKING CHANGE:` footer if it carries a migration or a worker protocol bump. No front
matter, no trailers — nothing generates `Ticket:` or `Approved-by:` lines any more, and *who*
approved is recorded in the commit's author field by git itself. **Nobody edits it.** It is drawn read-only above the approve control, and the
merge writes it exactly as you left it, so write it as a git message and not as a note to the
operator.

Unlike the presentation, this one is **never optional**: the merge has nothing to say without it,
and a run that finishes without writing it sticks the ticket here.

**Your manifest says whether `presentation.md` is optional**, because the workflow decides that and
not this prompt. If it says you may finish without writing it, and there is genuinely nothing to
say that the diff and the report do not already say, then finish without writing it rather than
padding. If it does not say so, the document is required: write it, and keep it short.

Nothing downstream reads the presentation, and nobody approves either document. Change no code
here: the ticket's work is finished by the time you are asked for this.
