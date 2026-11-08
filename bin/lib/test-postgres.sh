# shellcheck shell=bash
# A throwaway postgres for one run, shared by `bin/check` and `bin/look`. Sourced, not run.
#
# The server listens on a unix socket in a directory of its own and on no TCP port at all.
# Nothing else on a shared machine can reach it, so there is no password to make and none to
# leak — `trust` on that socket is safe for the same reason `mktemp -d` is private — and
# whatever holds 5432 is simply irrelevant. A trusting superuser on 5432 would be a shell for
# every other process on the machine, since `COPY … FROM PROGRAM` runs as whoever runs the
# script, and a shared command-pool machine is the case this exists for.
#
# `platform/config/test.exs` reads FORGE_TEST_DB_SOCKET_DIR and connects there when it is set.
# Two runs on one machine each make their own directory, so they share no database either
# (`docs/design/look.md` § Security).
#
# Why `bin/check` starts one at all, and why it probes by logging in, is written beside the probe
# in `bin/check`: that decision is the gate's. This file is only the mechanism, so that a second
# caller does not copy it.

# Start the server and export FORGE_TEST_DB_SOCKET_DIR. Remember the directory in
# FORGE_TEST_PGROOT so `forge_test_postgres_stop` can find it; the caller owns the trap. Returns 1
# when the server would not start, explicitly, because a caller that tests the function
# (`forge_test_postgres_start || …`) turns `set -e` off inside it.
forge_test_postgres_start() {
  FORGE_TEST_PGROOT="$(mktemp -d)"
  initdb -U postgres --auth-local=trust -D "$FORGE_TEST_PGROOT/data" > /dev/null || return 1
  pg_ctl -D "$FORGE_TEST_PGROOT/data" -l "$FORGE_TEST_PGROOT/server.log" -w \
    -o "-c listen_addresses= -c unix_socket_directories=$FORGE_TEST_PGROOT" start > /dev/null || return 1
  FORGE_TEST_DB_SOCKET_DIR="$FORGE_TEST_PGROOT"
  export FORGE_TEST_PGROOT FORGE_TEST_DB_SOCKET_DIR
}

# Stop the server and remove its directory. Safe to call when none was started.
forge_test_postgres_stop() {
  [ -n "${FORGE_TEST_PGROOT:-}" ] || return 0
  pg_ctl -D "$FORGE_TEST_PGROOT/data" -m immediate stop > /dev/null 2>&1 || true
  rm -rf "$FORGE_TEST_PGROOT"
}
