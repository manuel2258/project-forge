#!/usr/bin/env bash
# A credential check split out of bin/release so refining can know it will fail before a human
# approves release-notes.md, not after.
set -euo pipefail
auth=$(mktemp)
trap 'rm -f "$auth"' EXIT
printf '{}' > "$auth"
printf '%s' "$GHCR_TOKEN" | skopeo login --authfile "$auth" -u manuel2258 --password-stdin ghcr.io
echo "ghcr.io login OK"
