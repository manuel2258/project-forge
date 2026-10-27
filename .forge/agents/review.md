# Review

Run the `review` skill (`.claude/skills/review/SKILL.md`) against this ticket's changeset, over
`git diff origin/main..HEAD`.

## A later round is not the first round again

`report.md` is an input here, and it is this state's own last version: when it is present, you
have been round before and it says what you found. **Scope the round to that.** Verify the fixes
to the findings it lists, reproducing each as step 4 requires, then review what has changed since
the commit that version reviewed — not the whole changeset over again.

This is where the money goes. Ticket 7's second review cost $21.96 re-deriving a diff it had
already read, because `report.md` was not an input and nothing told it what it had already found;
its eighth, scoped to one integration and sixteen mutations, cost $4.13 and was the more useful
document. A full re-read of unchanged code is not thoroughness, it is the same reading bought
twice.

What a later round still owes the person: say which findings are closed and how you checked,
which survived, and what the new work brought with it. A closed finding is worth a line, not a
re-litigation.

## The bar rises each round

`reviewing → implementing` on `issues_found` runs at most five times, and then the ticket sticks
for a person to unstick by hand. **Reaching that bound is a failure of this state, not a safety
net.** It was reached at three often enough to raise it, and the rounds it was reached on were
not rounds that kept finding defects — they were rounds that kept finding something.

Which round you are on, count from `$FORGE_JOB/history/reviewing/`: one folder per attempt that
has already run. Then:

**Round one is the full width of this prompt.** All four lenses, the whole changeset, everything
below.

**Round two and after, only a defect is a finding.** The list is short and it does not grow:

- Wrong behaviour, with the concrete inputs or state that produce it and the specific wrong
  output.
- A security, authorisation, scoping or redaction hole — anything that lets a request reach what
  it must not, or shows a person what they must not see.
- Data loss, a crash, or a path that leaves something half-written and unrecoverable.
- A test that cannot fail, proven by mutating the code it covers and re-running it. The mutation
  is the finding; without it there is nothing to report.
- A claim nothing checks: a `docs/design/` note, a moduledoc, a comment or a commit message that
  says something the code does not do. `CLAUDE.md` makes the notes the standard, so this stays a
  defect at every round and is not a documentation nit.
- An acceptance criterion in `refinement.md` that the change does not meet.

**Everything else stops being a finding after round one.** Naming, where a function lives, how it
is factored, two copies of a short thing, a comment that could be clearer, a `@spec` that could
be tighter, a test that could also assert something else, a structure you would have built
differently. Round one may say each of those once. A later round may not say any of them at all —
not a new one, and above all not one an earlier round already raised and `implementing` chose not
to take. That choice is made; re-raising it is how a review loop becomes an argument and spends
five rounds on it.

**And a defect is flagged however late it is found.** On round five, on the last round the bound
allows, on code the earlier rounds read and passed: if it is on the list above, it goes in
`report.md` and the verdict is `issues_found`. A ticket stuck in `reviewing` with a known bug
named in its report is a ticket a person can fix in a minute. A ticket merged with the same bug
unmentioned because the loop was nearly out of rounds is the one thing this state must never
produce. The bound bounds the loop; it does not lower this bar.

So by round two or three, `issues_found` should mean one thing: a defect from that list is still
open. If what is left is anything else, the verdict is `done` — and say in the report what you
are leaving and why, as the verdict rule below already requires, rather than letting it drop
silently.

## The lenses, and the model each runs on

Four lenses: the skill's three — correctness and security; whether the new tests can fail, proven
by mutating the code and re-running them; DRY, KISS and design-note fidelity — and
`refinement.md`'s acceptance criteria, which this state adds so that a change passing all three
and still missing what it was asked for is a finding.

How many reviewers that is, the skill's step 1 decides from the size of the diff, and it still
does — but the split follows the models and not only the size, because a reviewer cannot run on
two. Below a few hundred lines: **two reviewers**, one on `sonnet` carrying all three comparisons
(mutation, design fidelity, the criteria) and one on this job's model carrying correctness and
security alone. Past that, split the `sonnet` one into its three lenses; correctness stays its own
either way, and the mutation lens stays its own whenever it is not the small-diff case, because its
evidence is a command's output rather than a reading.

**And on a later round it is two lenses, not four.** § The bar rises each round already says a
later round reviews what changed since the commit the last `report.md` named; the lens list has to
follow, or "scoped" means reading the same 3,000 lines through four lenses again — which is what
ticket 7's $21.96 second round was. So, from round two:

- *Correctness and security over the new commits*, on this job's model. Always.
- *The mutation lens over the tests the new commits add*, on `sonnet`. Always, because each round
  brings new tests and they are the claim this round has to defend.
- *DRY, KISS and design-note fidelity, and the criteria* — **only if the new commits touched a
  `docs/design/` note, a moduledoc or comment that asserts something, or the subject of a
  criterion.** `git diff --stat <last reviewed commit>..HEAD -- docs/design` answers the first
  part in one command. If nothing did, say in the report that the lens was not needed and why —
  which is different from not run, and the verdict rule below is about the second.

Verifying the previous round's findings is not a lens and is not delegated: it is yours, by hand,
a command each, as § A later round is not the first round again and the skill's step 4 both say.

**Three of the four lenses run on `sonnet`, and for the same reason: their answer is a
comparison, not a judgement.**

- *The mutation lens.* Breaking a line, re-running the tests it covers and reporting which
  noticed is mechanical, with a right answer the output shows.
- *DRY, KISS and design-note fidelity.* Whether a note still describes the code is read off the
  two texts. Ticket 7's rounds are the evidence: every finding this lens produced was a
  comparison anyone could check — the stated reason for a protocol bump backwards in both the
  note and the function's own doc, two measured figures wrong (48 ms written as two seconds;
  13,107 as tens of thousands), a stale comment three lines from the one it had corrected. None
  of them needed the larger model to see, and paying for it on all four lenses is how a review
  reaches $29.69.
- *`refinement.md`'s acceptance criteria.* A criterion is written to be checkable without asking
  its author what it meant — that is the standard `agents/refine.md` holds `refining` to — so
  checking one is a comparison between a list and a diff, with the same right answer the other two
  have. **A criterion about a surface is checked against the surface**: the template, and the test
  that renders it. A context function returning the right value is not a page drawing it, and
  `refining` is now asked for criteria about the empty state, the refused state, the phone and
  what survives a reconnect — each of which is satisfied in a template or a LiveView test or
  nowhere. **What stands behind the criteria is the human approval on `refinement.md`**, not the model
  that reads them here: `refining` runs on `sonnet` too, and a person approves that document before
  `planning` ever runs, which is the one gate in the workflow this lens is downstream of.

**Correctness and security stays on this job's model, alone.** That is the reading where judgement
is the whole value, and it is where this state earns its budget: the three findings on ticket 7
that a person would otherwise have lived with — a binary file taking the merge page down through
the JSON encoder, `optional` letting a job discard the outcome it declared, a 1 MiB cap bypassed
through a gitlink — all came from it. It is also the lens that now carries the weight of
`implementing` running on `sonnet`: the writer got cheaper and this reader did not.

**The mutation lens reads the changeset's guards, not the suite.** Point it at the authorisation,
scoping, ordering, redaction and "must never" checks *this diff adds or touches*, and at the tests
this diff adds — not at the project's existing coverage, which is not this changeset's claim to
defend. Name the files. A mutation that cannot be caught is a finding only if the code has no
comment already saying so (`CLAUDE.md` § Testing).

**Reproducing a finding is yours and stays yours.** The skill's step 4 says to re-run the sharpest
findings before repeating them, and it means by hand, a command each — not by dispatching a
reviewer per finding. A verifier per finding is both the thing that eats this state's budget and a
delegation of the one judgement step 4 exists to keep.

**A lens you dispatch is a lens you wait for, in the same turn.** Never leave a reviewer running
in the background and end your turn: the job ends when your turn does, and the subagent is killed
unread. This has happened — ticket 7's `reviewing` attempts 6 and 7 both dispatched the mutation
lens in the background, both ended their turn, both had it killed, and both reported `done`. The
pass neither had run found two uncaught mutations when attempt 8 finally ran it in the foreground.
So: dispatch the lenses you need, then block on them before you say anything. If a lens cannot
finish at all, name it in the report as not run and take the verdict rule below — an unrun lens
named is worth something, an unrun lens reported as clean is worth less than nothing.

## Write `report.md` as you go

Create `report.md` as soon as you have confirmed a finding, and write it again as each later lens
reports in. Do not hold everything for one write at the end: this state can stop on its cost
budget inside a single turn of yours, and what is on disk then is the whole of what a person gets.
A report listing two confirmed findings and saying which lenses had not reported yet is worth a
great deal; an empty `out/` is worth nothing.

**Name the commit you reviewed, in every version.** `git rev-parse HEAD` in the opening lines,
beside the base you diffed against. It is what makes the scoping above possible: the next round
reads this document to find out where to start, and a report that does not say what it covered
leaves it no choice but to read everything again. It is also what tells a person whether the
report beside the diff is the one for that diff.

**Every write leaves a whole document** — the front matter opened and closed, the prose finished.
A half-written file is not a shorter report, it is no report: a `report.md` whose `---` block is
open does not parse, so it is refused rather than stored and the person reaches `review_ready`
with nothing. Compose the new version and write it in one go, rather than appending to the file on
disk.

**The verdict is written last, and until then it is `did_not_converge`.** Every version you write
before the final lens has reported carries `outcome: did_not_converge`, whatever it has found so
far, because the job can end at any moment and whatever is on disk then *is* the outcome — the
engine reads the document, not your intent. A review that stops with lenses outstanding has no
verdict, and `did_not_converge` is how a state says so: it costs a bounded retry, where a
premature `done` costs a person merging work on a review that never ran.

Then, once every lens has reported: `outcome: issues_found` if anything survived verification.
`outcome: done` only when nothing did, or when something was found and held up under scrutiny as
acceptable — say which, and why, rather than letting it drop silently.

A ceiling is not your business here. A job stopped by its turn, cost or wall-clock budget is
`budget_exhausted` whatever the document says, and that edge goes forward to `presenting` so the
partial report reaches someone. What you control is the case where nothing stopped you and you
simply had not finished.

Do not fix anything here. Fixing is `implementing`'s job on the next pass, with this document as
its input.
