# Documentation cleanup

A scheduled ticket with nobody to ask. Check what the documents claim against the repository and
correct what is not true. `CLAUDE.md` names the failure this exists for: **a note, comment or
commit message that asserts something unverified is the defect this repository produces most
often.** Files people attached are in `$FORGE_JOB/attachments/`.

If `report.md` is present a review sent an earlier attempt back, and its findings are this
attempt's criteria; `feedback.md`, from a person, comes above it.

## Scope

`CLAUDE.md`, `docs/vision.md`, `docs/design/*.md`, `platform/AGENTS.md`, the prompts under
`.forge/agents/`, `README`s, and comments in the code that assert something.

## How

- **Take the claims, not the prose.** For each note, list its checkable statements — counts,
  figures, function, module, file, flag and environment-variable names, "every", "none", "always",
  "never", worker protocol numbers, version numbers, "is built" and "not built yet" — and check
  each against the code, with a grep or by reading it. Run the count both ways.
- **Statuses.** A *Not built yet*, *Not verified here* or *Open* item that the code has since
  settled is moved or removed; one the code contradicts is corrected. Do not mark anything
  verified that nobody ran: if you cannot run it here, it stays unverified.
- **Links and references**: a path, section title or ticket a note points at that no longer
  exists. Fix the pointer; check every other note for the same one.
- **Duplication**: a fact stated in two notes that now disagree. Keep it in the note that owns it
  and point to it from the other.
- Where the note and the code disagree, **the note changes**, unless the code is plainly the one in
  error. Then leave both alone and propose a ticket under `out/proposals/`, as you do for any
  decision that is a person's.
- Do not touch `docs/decisions.md` or the vendored `docs/design/ui/` prototype. Do not change what a note *decides*.
- Fix the class: when one claim was wrong, grep for its siblings.

## Finishing

Commit as `docs(<scope>): …`, one theme per commit. `bin/check` runs: a note embedded in a release
(`flake.nix`'s `embeddedDocs`) is compiled, so run the gate once at the end. Write
`implementation.md`: every claim you changed with the evidence, and what you checked and found
true, in a line, so next week's run can skip it. If nothing is wrong, commit nothing and say so.
