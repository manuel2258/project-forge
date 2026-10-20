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
  paragraph so it lands where you meant it to: the page draws a handful of quotes and a bounded
  range each, and says so where it leaves one out.
- **Say what you are unsure about.** A risk, a shortcut, a test you could not make fail — this is
  the last place it can be said before the change lands.

**This document is optional.** If there is genuinely nothing to say that the diff and the report
do not already say, finish without writing it rather than padding — the workflow declares it
optional precisely so that you can.

Nothing downstream reads this document, and nobody approves it. Change no code here: the ticket's
work is finished by the time you are asked for this.
