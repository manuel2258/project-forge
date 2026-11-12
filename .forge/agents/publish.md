# Publish

Carry out what `release-notes.md` decided and was approved. **The merge is the last step of this
ticket, not this one** — nothing here lands on the default branch.

Bump `VERSION` to the approved version in the worktree, and file the approved changelog section
next to it:

```
printf '%s\n' X.Y.Z > VERSION
bin/changelog-add "$FORGE_JOB/inputs/changelog-section.md"
```

`bin/changelog-add` puts the section into `platform/priv/changelog.md` byte for byte, which is the
text a person approved with the notes, so do not edit it. It refuses a section that does not start
`## X.Y.Z` and one that differs from what the changelog already holds under that heading: either is
fatal, so end with `did_not_converge` and say why. Running it again on a section already filed does
nothing, which is how a second attempt finds this part done. You don't need to commit either file
yourself: invoking a command commits whatever is in the worktree first
(`docs/design/commands.md` § The ensured commit), so they just need to be there when you invoke,
and the image `release-build` builds carries the changelog.

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
operator's own action on `/templates` — and the changeset.

**`publish-report.md` carries `links:` in its front matter**, which the release record lists
(`docs/design/ticket-types.md` § The record, the tag, the history):

```
---
outcome: done
links:
  - label: "ghcr.io/manuel2258/forge:X.Y.Z (sha256:…)"
    url: "https://github.com/users/manuel2258/packages/container/package/forge"
  - label: "forge-worker-X.Y.Z (image 123456)"
    url: "https://console.hetzner.cloud/…"
---
```

One link for the platform image, labelled with its tag and digest. One for the Hetzner snapshot,
labelled with its name and id, **only when `hetzner-snapshot` made one** — a release that built no
snapshot has no snapshot link, and a snapshot that failed has none either. Each `url` must be an
absolute `https` URL. Neither command's log prints one, so they are built, and only from what the
logs do print:

- the image: `ghcr.io/<owner>/<name>` is the package page
  `https://github.com/users/<owner>/packages/container/package/<name>`, with the owner and name of
  the reference `release-build`'s log prints;
- the snapshot: the project's snapshots page `https://console.hetzner.cloud/projects/<id>/snapshots`
  when `hetzner-snapshot`'s log or its environment names the Hetzner project's id, and otherwise
  `https://console.hetzner.cloud/`, saying in `publish-report.md` that the link is the console and
  not the snapshot, because no URL for one image exists without the project.

Never write a link you did not build this way, and never one for a snapshot that was not made.

**How you end decides whether a person sees this before it lands.** The release notes were the
one approval; what you leave merges on its own.

- `outcome: done` in `publish-report.md`'s front matter when the image is published and the
  snapshot was made or not needed. The release merges as soon as the merge queue reaches it, and
  the ticket is finished.
- `outcome: snapshot_failed` when the verdict called for a snapshot and none was made. The image
  is out, so `VERSION` still has to land, but the ticket stops in `release_ready` until a person
  has read your report, retried the snapshot and approved the merge. Say there exactly what failed
  and the command that retries it.

Produce **`commit-message`** too — and **do not write a new one**. `release-notes.md`, in your
inputs, already carries the message this release's commit should use, and a human approved that
document before anything was built (`agents/release-plan.md`). Copy it out: the
`chore(release): X.Y.Z` subject, the blank line, the `Since v<last>: …` body, the worker protocol
line and migrations as the notes have them. No front matter and no trailers.

Writing your own instead is how the release finder came to find nothing: the version a person
approved stayed in a document and never reached git. **The subject is load-bearing** — it is what
the next release greps for to decide what has changed since
(`agents/release-plan.md`, `CLAUDE.md` § Commit messages) — so a subject of your own composition
does not merely read differently, it makes the next release compute the wrong range.

Where the notes and what you actually built disagree — a snapshot that was skipped, say — correct
that line and say so in `publish-report.md`, rather than composing the message afresh.

It is written to the commit exactly as you leave it, nobody edits it, and it is never optional, so
a run that finishes without it sticks the ticket here.
