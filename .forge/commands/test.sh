#!/usr/bin/env bash
# One project's tests, run as a forge command: `test <core|worker|platform> [mix test args...]`.
# `$0` is the pinned copy in $FORGE_JOB, not the checkout, so the repository is found by `cd`ing
# into $FORGE_CHECKOUT (`docs/design/commands.md`).
#
# **This exists so that an agent never runs a suite by hand.** An agent's slice is one core, a
# platform test file that waits on the database takes minutes there, and a run that outlives the
# job's wall clock throws away everything the job spent. A command runs on the command pool with
# the cores the gate gets, and an agent may invoke several at once: `[test platform
# test/forge/a_test.exs]` next to `[test worker]`.
#
# Arguments after the project go to `mix test` untouched (a file, `file:LINE`, `--stale`,
# `--only tag`). No `--cover`: the floor is the gate's, and a partial run would fail it.
# Exit status is `mix test`'s; 2 is the machine, not the change (as `check.sh`).
set -euo pipefail
cd "$FORGE_CHECKOUT"

project="${1:-}"
case "$project" in
  core | worker | platform) shift ;;
  *)
    echo "usage: test <core|worker|platform> [mix test args...]" >&2
    exit 2
    ;;
esac

missing=()
command -v mix > /dev/null 2>&1 || missing+=(mix)
if [ "$project" = platform ]; then
  for tool in initdb pg_ctl psql; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
  done
fi
if [ ${#missing[@]} -gt 0 ]; then
  echo "the tests cannot run on this machine: no ${missing[*]}" >&2
  echo "this is the machine, not the change — nothing was checked" >&2
  exit 2
fi

# shellcheck source=bin/lib/mix-cache.sh
. bin/lib/mix-cache.sh
forge_mix_cache_ensure "$PWD"

if [ "$project" = platform ]; then
  # A throwaway postgres on a unix socket, as `bin/check` starts one (`bin/lib/test-postgres.sh`).
  # Always our own here: a command machine has none, and this one never reads an operator's.
  # shellcheck source=bin/lib/test-postgres.sh
  . bin/lib/test-postgres.sh
  trap forge_test_postgres_stop EXIT
  echo "==> postgres"
  forge_test_postgres_start
fi

cd "$project"
mix deps.get > /dev/null
echo "==> $project: mix test $*"
env MIX_ENV=test mix test "$@"
