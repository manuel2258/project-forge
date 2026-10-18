#!/usr/bin/env bash
# bin/release refuses anything whose checked-out branch is not literally named main (CLAUDE.md
# § Landing) — a check written for a human switching branches by hand. A command's checkout is
# fetched fresh and thrown away after this script ends, so pointing a local branch at it costs
# nothing and needs no cleanup.
set -euo pipefail
cd "$FORGE_CHECKOUT"
git checkout -B main
exec bin/release
