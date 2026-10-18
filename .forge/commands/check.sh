#!/usr/bin/env bash
# The quality gate, run as a forge command. `$0` is the pinned copy in $FORGE_JOB, not the
# checkout, so bin/check is found by `cd`ing into $FORGE_CHECKOUT rather than from dirname "$0".
set -euo pipefail
cd "$FORGE_CHECKOUT"
exec bin/check
