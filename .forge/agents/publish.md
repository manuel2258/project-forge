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

Produce **`commit-message`** too: the message the merge commit will carry for this whole release.
A summary line under about 70 characters, then a blank line, then body paragraphs if there is more
to say. No front matter and no trailers. It is drawn read-only above the merge control and written
to the commit exactly as you leave it — nobody edits it — and it is never optional, so a run that
finishes without it sticks the ticket here.
