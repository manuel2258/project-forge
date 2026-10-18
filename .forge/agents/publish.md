# Publish

`merged` has already put this ticket's commit on the default branch; your checkout is that
commit. Build and push the platform image:

```
bin/release
```

It refuses a version the registry already holds and a dirty tree, builds `.#platform-image`, and
copies it to the registry as `:X.Y.Z` and then `:latest`. Check the digest afterwards:

```
skopeo inspect --creds "manuel2258:$GHCR_TOKEN" --format '{{.Digest}}' \
  docker://ghcr.io/manuel2258/forge:latest
```

A different digest than what `bin/release` printed is a failure — stop and say so in
`publish-report.md` rather than going on to the snapshot.

**The snapshot.** Read the Hetzner verdict `releasing` recorded in `release-notes.md` — do not
re-derive it. Required or Recommended:

```
bin/hetzner-image --name forge-worker-X.Y.Z
```

Not needed: skip it, and say so. It is long-running; let it finish rather than assuming it hung.
It cleans up its own rescue server on any exit; if it still fails, check `hcloud server list` for
a leftover `forge-image-builder-*`, delete it, and say in `publish-report.md` that the snapshot
needs a retry and why — a failed snapshot does not undo the image already published.

Produce `publish-report.md`: the digest and that `:latest` names it, the snapshot's verdict and
either its name/build/protocol or why it was skipped or failed, and the reminder that pointing a
template at a new snapshot is still the operator's own action on `/templates`.
