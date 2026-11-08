# Implement (bug)

Carry out `diagnosis.md` against the criteria in `refinement.md`. If `report.md` is present, a
review already sent an earlier attempt back — read it first.

- Write the regression test before the fix, from what `diagnosis.md` said "fail" means, and
  watch it fail against the unfixed code (`CLAUDE.md` § Testing) — for a bug, this is the only
  proof the defect was real and not a misreading of the ticket.
- Fix every site `diagnosis.md` named for the same pattern. If one is deliberately left, say why
  in `implementation.md` — "fix the class, not the instance" is the rule and the exception needs
  a reason on the record, not a silent gap.
- If a design note documented the behaviour that was wrong, correct it in this branch alongside
  the code, not after.
- Raise a coverage threshold in `mix.exs` to the whole percent below the measured figure whenever
  it has risen in the same commit. Never lower one.
- Invoke `check` yourself, as many times as it takes, before ending the job. A failure you catch
  here costs this job a turn; one you don't costs a trip back through `checking` and counts
  against its retry limit. **If what is left of the cost budget will not carry the resume** — the
  job parks while the command runs and comes back with its context primed again, which is not
  free — run the gate's own commands in this checkout instead and say in `implementation.md`
  which you did. `check.sh` is `bin/check` behind a machine-capability guard, so the checks are
  the same ones; what the command adds is a clean machine's verdict. Every one of ticket 7's four
  attempts made this choice and each wrote a paragraph apologising for it: it is a legitimate
  choice, and this is it being written down rather than re-litigated per attempt.

## Screenshots, when the change is something a person sees

Run this when `git diff --stat origin/main..HEAD -- platform/lib/forge_web platform/assets` is not
empty — the web layer and its styles, which is also what `reviewing` checks. `docs/design/look.md`
has the tool; this is how to use it here.

- **Write or extend a setup** in `platform/test/support/look/setups/` for the screens you changed
  (the shipped `ticket` one shows the pattern), built from the suite's own fixtures. It is code,
  kept, and compiled by the gate: the next ticket on the same screen starts from it. **Never a
  project secret's value** in a setup or a step: they are made-up data, and a picture is not
  masked.
- **Look at each changed screen** with `bin/look --setup NAME --as USER < steps`, the steps on
  standard input and not saved: its main view at phone width and at desktop width, and every state
  a "What a person sees" criterion of `refinement.md` describes — empty, refused, waiting, a long
  or hostile value — at phone width, and at desktop width too where that layout differs. Name each
  file `<screen>-<state>-<phone|desktop>.png` in `$FORGE_JOB/out/screenshots/`. Photograph what
  changed, not the platform: there is no cap, and no reason to take the whole of it.
- **Read the pictures**, fix what is wrong against `docs/design/ui.md` and the criteria, and take
  them again. **Take the final set again as your last step, after your last change**, deleting any
  a later round no longer needs: nothing checks that you did, and a picture of old code reads as
  approved.
- **List the ones you kept** under `## Screenshots` in `implementation.md`: file, screen, state.
  If nothing visible changed, say in one sentence why instead. The review and the presentation
  show the pictures that list names and no others.
- **Pass the steps on standard input in an unquoted heredoc** (`<<EOF`, not `<<'EOF'`) so that
  `$FORGE_JOB` expands in a `shot` path (and so would any other `$` or backtick in a step, so keep
  those out); a relative path is relative to where you ran `bin/look`.
- **Exit 1 is yours to fix**: a failed step, or a step list, setup or user you got wrong, is the
  tool working, and so is a failing page; it names the step, and the fix is the page's or yours.
  That includes a page that breaks while logging in (a script error every page shares, a crash)
  and an app or stylesheet that will not build: the output says which, and none of them is a
  reason to finish without pictures. **Exit 2, or your own kill (137), means the tool could not
  run** — the browser, the namespace or the memory is the machine's, and the message says which.
  Say so and why in `implementation.md` and finish without screenshots; do not stop, and do not
  retry past one more try.

## Check your own claims before you declare done

The cheapest finding is the one a $40 review never has to pay for. Ticket 7's second review
round cost $21.96 and $9.73 to fix, and most of what it reported was not code: the stated reason
for a protocol bump backwards in both a design note and the function's own doc, two measured
figures wrong (48 ms written as two seconds, 13,107 as tens of thousands), a stale comment three
lines from the one the same commit had corrected, five new guards with no failing mutation — one
of them under a comment asserting that the ordering "is asserted". Every one of those is a
comparison against the diff, and none of them needed a reviewer to find.

So before you write the outcome, dispatch a **`sonnet` subagent** over your own diff and
`implementation.md`, and wait for it in the same turn. What it buys is not a bigger or a smaller
mind — this job runs on `sonnet` too — it is a reader who did not write the diff and has no memory
of having meant something by it, which is the whole reason the `review` skill exists at all. Give it exactly this to do, and nothing
else — it is not a reviewer and must not fix anything:

- Every factual claim in `implementation.md` and in each design note this branch edited: is it
  true of the diff? Measured figures, counts, file and function names, "every", "none", "now
  always".
- Every claim that a mutation was watched failing: does the test it names actually fail when the
  line it covers is broken?
- Every comment the diff adds or touches that asserts something — "bounded at", "is asserted",
  "cannot" — against the code beside it.

**On an attempt a review sent back, point it at what this attempt changed first.** From the second
round on, most of what a review finds is what the last fix broke: a new branch with no test that
fails without it, a new sentence that is not true. Ticket 26's second review found "the fix opened
the dead end", and ticket 28's "the fix opened a new hole". The lines you just wrote are the ones
nobody has read yet.

Fix what it finds, in this job. What you cannot fix, say plainly in `implementation.md` rather
than leaving it to be found: a claim you have withdrawn costs nothing, and one a reviewer
catches costs a round trip.

**The last gate run is on the commit you end on.** What the subagent made you change is a change
like any other, and so is every edit after your last `check`. If anything changed since the last
passing run, invoke it again, or, when the budget will not carry the resume, run at least
`mix format` and `mix credo --strict` in each project you touched. Ticket 24's gate passed, the job
kept editing, and it ended on one line 128 characters long, which `checking` refused at the price
of a whole further attempt.

Produce `implementation.md` — what the defect was, what fixed it, and which other sites were or
were not touched — and the changeset. End on outcome `diagnosis_invalid` instead, with why, if
the diagnosis does not survive contact with the code.

**That outcome is bounded at two** (`bug.yml`), so it is for a cause that is not the cause — not
for a fix that turned out to need more files than the diagnosis listed, which is yours to do and
to record. Say what you found that contradicts it, because `diagnosing` reads this and has two
tries.
