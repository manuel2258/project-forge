# Publish

Carry out what `release-notes.md` decided and was approved. **The merge is the last step of this
ticket, not this one** — nothing here lands on the default branch.

Bump `VERSION` to the approved version in the worktree. You don't need to commit it yourself:
invoking a command commits whatever is in the worktree first (`docs/design/commands.md` § The
ensured commit), so the bump just needs to be there when you invoke.

Invoke `release-build` and wait for it. It builds and pushes the platform image, checks the
registry for a version already published, and prints the digest — read its log on resume. If it
failed — refused login, a version already there, the build itself, a digest that doesn't match
what it printed — that is fatal: end with `did_not_converge`, say why, and produce neither
`publish-report.md` nor the changeset. `VERSION` stays bumped on this ticket's branch, so the next
attempt finds that part already done.

Once `release-build` succeeds, act on the Hetzner verdict `release-notes.md` recorded. Required or
Recommended: invoke `hetzner-snapshot` with args `["--name", "forge-worker-X.Y.Z"]`. A snapshot
failure here is not fatal to the release already published — read its log, report that it needs a
retry and why, rather than discarding the image push that already succeeded. Not needed: skip it
and say so.

Produce `publish-report.md` — the digest from `release-build`'s log and that `:latest` names it,
the snapshot's verdict and either its name/build/protocol from `hetzner-snapshot`'s log or why it
was skipped or failed, and the reminder that pointing a template at a new snapshot is still the
operator's own action on `/templates` — and the changeset, now that there is something worth
approving.

Produce **`commit-message`** too — and **do not write a new one**. `release-notes.md`, in your
inputs, already carries the message this release's commit should use, and a human approved that
document before anything was built (`agents/release-plan.md`). Copy it out: the `Version X.Y.Z`
subject, the blank line, the `Since v<last>: …` body, the worker protocol line and migrations as
the notes have them. No front matter and no trailers.

Writing your own instead is how `git log --grep '^Version'` came to find nothing: the version a
person approved stayed in a document and never reached git. Where the notes and what you actually
built disagree — a snapshot that was skipped, say — correct that line and say so in
`publish-report.md`, rather than composing the message afresh.

It is written to the commit exactly as you leave it, nobody edits it, and it is never optional, so
a run that finishes without it sticks the ticket here.
