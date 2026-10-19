#!/usr/bin/env bash
# The quality gate, run as a forge command. `$0` is the pinned copy in $FORGE_JOB, not the
# checkout, so bin/check is found by `cd`ing into $FORGE_CHECKOUT rather than from dirname "$0".
set -euo pipefail
cd "$FORGE_CHECKOUT"

# **Status 2 is "could not run", which the workflow maps to `gate_unavailable` rather than to
# `checks_failed`** (`.forge/common.yml`). The bound on going back to `implementing` exists for a
# fix that keeps failing; ticket 1 spent all three of it on machines that had no Hex and no
# database, so the fix was never checked by the platform at all. Only the machine is judged here
# — anything the gate itself decides stays the gate's, and comes back as its own exit status.
#
# `bin/check` installs Hex and starts a throwaway postgres when they are missing
# (`CLAUDE.md` § Quality gate), so what is left to refuse on is a machine that cannot do even
# that: no devshell, or no way to get a database. Each is named, because "exit 2" on its own
# tells whoever reads the log nothing.
missing=()
for tool in mix shellcheck shfmt; do
  command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
done

# A database either answers already or can be started from the devshell's own binaries. Neither
# is the same question as "is postgres installed", which is why both are asked.
if ! command -v pg_isready > /dev/null 2>&1 || ! pg_isready -h localhost -p 5432 -q; then
  for tool in initdb pg_ctl; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
  done
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "the gate cannot run on this machine: no ${missing[*]}" >&2
  echo "this is the machine, not the change — nothing was checked" >&2
  exit 2
fi

exec bin/check
