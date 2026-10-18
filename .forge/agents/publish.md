# Publish

Carry out what `release-notes.md` decided and was approved. **The merge is the last step of this
ticket, not this one** — nothing here lands on the default branch. You are still on the ticket's
own branch, which `bin/release` does not know by name.

Bump `VERSION` to the approved version and commit it, using the message `release-notes.md`
recorded — this commit is the changeset `release_ready` will be approved for, and it must exist
and be clean before `bin/release` will run at all.

`bin/release` refuses anything whose checked-out branch is not literally named `main`
(`CLAUDE.md` § Landing) — a check written for a human switching branches by hand, which a ticket's
own branch never satisfies. Point a local branch at this commit instead of fighting the check:

```
git branch -f main HEAD
git checkout main
bin/release
```

If it fails — refused login, a version already in the registry, the build itself, a digest that
does not match what it printed — that is fatal. End with `did_not_converge`, say why, and produce
neither `publish-report.md` nor the changeset: there is nothing yet worth a human approving, and
`VERSION` stays bumped on this ticket's branch for the next attempt to find already done.

Once the image is confirmed published, switch back (`git checkout <the ticket's own branch>`) and
act on the Hetzner verdict `release-notes.md` recorded:

```
bin/hetzner-image --name forge-worker-X.Y.Z   # Required or Recommended
```

A snapshot failure here is not fatal to the release already published — report it and the retry
command, rather than discarding the image push that already succeeded. Not needed: skip it and
say so.

Produce `publish-report.md` — the digest and that `:latest` names it, the snapshot's verdict and
either its name/build/protocol or why it was skipped or failed, and the reminder that pointing a
template at a new snapshot is still the operator's own action on `/templates` — and the changeset
holding the `VERSION` commit, now that there is something worth approving.
