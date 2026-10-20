# Review

Run the `review` skill (`.claude/skills/review/SKILL.md`) against this ticket's changeset, over
`git diff origin/main..HEAD`.

## The lenses, and the model each runs on

Dispatch exactly four reviewers, in parallel, one message. The skill's three, plus a fourth this
state adds so that a change which passes all three and still misses what it was asked for is a
finding:

| Lens | Model |
| --- | --- |
| Correctness and security | the job's own (`opus`) |
| DRY, KISS and design-note fidelity | the job's own (`opus`) |
| `refinement.md`'s acceptance criteria, one by one | the job's own (`opus`) |
| Test correctness, by mutation | `sonnet` |

Every per-finding verifier of the skill's step 4 runs on `sonnet` too.

**Why those two are not on the job's model.** Breaking a line, re-running the tests it covers and
confirming another reviewer's claim are mechanical: there is a right answer and the evidence is in
the output. The other three lenses are the readings where judgement is the whole value — the
skill calls design-note fidelity the highest-yield lens for that reason. The mutation lens and the
verifiers are also what the fan-out multiplies, a verifier per finding, so they are where the
budget goes if nothing says otherwise.

**The mutation lens reads the changeset's guards, not the suite.** Point it at the authorisation,
scoping, ordering, redaction and "must never" checks *this diff adds or touches*, and at the tests
this diff adds — not at the project's existing coverage, which is not this ticket's claim to
defend. Name the files. A mutation that cannot be caught is a finding only if the code has no
comment already saying so (`CLAUDE.md` § Testing).

## Write `report.md` as you go

Create `report.md` with the first finding you have confirmed, and update it as each later lens and
verifier reports in. Do not hold everything for one write at the end: this state can stop on its
cost budget inside a single turn of yours, and what is on disk then is the whole of what a person
gets. A report listing two confirmed findings and saying which lenses had not yet reported is
worth a great deal; an empty `out/` is worth nothing.

Set `outcome: issues_found` if anything survived verification. Set `outcome: done` only when
nothing did, or when something was found and held up under scrutiny as acceptable — say which, and
why, rather than letting it drop silently.

Do not fix anything here. Fixing is `implementing`'s job on the next pass, with this document as
its input.
