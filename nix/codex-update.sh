#!/usr/bin/env bash
# Installs or updates Codex CLI on a worker, for `codex-update.service` (nix/worker-image.nix) and
# for the worker suite, which runs it against a stand-in `curl` (worker/test/forge_worker/codex_update_test.exs).
#
# Usage: codex-update.sh HOME URL STATUS_FILE FETCH_TIMEOUT PROBE_TIMEOUT KILL_AFTER
#
#   HOME          the directory holding `bin/` — the link `bin/codex` is the install's front door, and
#                 each release unpacks into `codex/codex.XXXXXX` beside it
#   URL           the release's `codex-package` tarball
#   STATUS_FILE   where the outcome is written, for `ForgeWorker.ClaudeUpdate.status/2`
#
# **What is installed is the whole package, not the `codex` binary.** Codex runs every shell and
# tool call through `codex-code-mode-host`, which it looks for beside its own resolved executable;
# the lone `codex` asset has no such file, and every tool call on a machine installed from it failed
# closed (docs/design/codex.md § On the image). The package holds `bin/codex`, the host,
# `bin/codex-exec-server`, `codex-path/rg` and `codex-resources/`, and no top-level directory.
#
# **The replace is all-or-nothing** because it is one `rename(2)`: the release is unpacked into a
# directory of its own **on the same filesystem**, checked whole, and only then does `bin/codex`
# become a link to it, by making the new link beside the old one and moving it over. A fetch that
# dies half way, or a package with a part missing, leaves the install that was there as it was.
set +e
set -uo pipefail
umask 022

home=$1
url=$2
status_file=$3
fetch_timeout=$4
probe_timeout=$5
kill_after=$6

link=$home/bin/codex
store=$home/codex

rm -f "$status_file"

# The installed version, or nothing at all, and **nothing when the install is not whole**: a
# `codex` that answers `--version` with no `codex-code-mode-host` beside it is the defect this
# script was rewritten for, and reading it as installed would call a machine migrating from one at
# the same version `skipped`, and a failed fetch over it not a failure. Beside it means beside the
# executable once its links are followed, which is where Codex looks.
installed() {
  [ -x "$link" ] || return 0
  local host
  host=$(dirname "$(readlink -f "$link")")/codex-code-mode-host
  [ -f "$host" ] && [ -x "$host" ] || return 0
  timeout -k "$kill_after" "$probe_timeout" "$link" --version 2> /dev/null | head -1 || true
}

# Everything the package's own manifest says Codex needs, and the host, found and executable. A
# path in the manifest that is absolute or climbs out of the package is refused, because it is
# joined to a directory and run.
verify() {
  local dir=$1 manifest entrypoint exec_server rel
  manifest=$dir/codex-package.json
  [ -f "$manifest" ] || {
    echo "the release held no codex-package.json"
    return 1
  }
  entrypoint=$(jq -er '.entrypoint' "$manifest" 2> /dev/null) || {
    echo "codex-package.json names no entrypoint"
    return 1
  }
  exec_server=$(jq -er '.execServer' "$manifest" 2> /dev/null) || {
    echo "codex-package.json names no execServer"
    return 1
  }
  for rel in "$entrypoint" "$exec_server" bin/codex-code-mode-host; do
    case "$rel" in
      /* | *..*)
        echo "codex-package.json names $rel, which is not inside the package"
        return 1
        ;;
    esac
    if [ ! -f "$dir/$rel" ] || [ ! -x "$dir/$rel" ]; then
      echo "the release held no executable $rel"
      return 1
    fi
  done
  timeout -k "$kill_after" "$probe_timeout" "$dir/$entrypoint" --version > /dev/null 2>&1 || {
    echo "$entrypoint did not answer --version"
    return 1
  }
}

log=$(mktemp)
before=$(installed)
status=0
dir=""

mkdir -p "$home/bin" "$store" || status=$?

if [ "$status" -eq 0 ]; then
  dir=$(mktemp -d "$store/codex.XXXXXX") || status=$?
fi

if [ "$status" -eq 0 ]; then
  echo "codex-update: fetching $url"
  # `--no-same-owner`: the release's files are owned by whoever built it, and nothing here should
  # rest on that uid being one nobody holds. Only `root` honours the archive's owner, so this is an
  # equivalent mutant in the worker suite, which does not run as root: no test of it can fail.
  # shellcheck disable=SC2016  # the single quotes are the point: `bash -c` expands them
  timeout -k "$kill_after" "$fetch_timeout" bash -c \
    'set -o pipefail; curl -fsSL --proto "=https" --proto-redir "=https" --max-time 100 "$1" | tar --no-same-owner -xz -C "$2"' \
    bash "$url" "$dir" > "$log" 2>&1 || status=$?
fi

if [ "$status" -eq 0 ]; then
  # `a+rX` on the directory itself too: `mktemp -d` made it 700 and a job's user has to walk in. A
  # tarball with a `./` entry would reset it; the real one has no top-level entry at all.
  chmod -R a+rX "$dir"
  if why=$(verify "$dir"); then
    entry=$(jq -r '.entrypoint' "$dir/codex-package.json")
    # The new link goes beside the old and is renamed over it: a `mv -T` of one link onto another
    # is `rename(2)`, which no reader sees half done. It also replaces the lone binary an earlier
    # image left at this path.
    # A `$link.new` a killed run left between its `ln` and its `mv` would make this `ln` fail on
    # every boot after, so it goes first.
    rm -f "$link.new"
    if ln -s "$dir/$entry" "$link.new" && mv -T "$link.new" "$link"; then
      :
    else
      status=1
      rm -f "$link.new"
      echo "could not put the new install in place" > "$log"
    fi
  else
    echo "$why" > "$log"
    status=1
  fi
fi

# What stays under the store is the directory the link points at, and nothing else: that clears the
# one a failed run just unpacked as well as the one a run that was killed left behind.
real=$(readlink -f "$link" 2> /dev/null || true)
for candidate in "$store"/*/ "$store"/.[!.]*/; do
  [ -d "$candidate" ] || continue
  candidate=${candidate%/}
  case "$real" in
    "$(readlink -f "$candidate")"/*) ;;
    *) rm -rf "$candidate" ;;
  esac
done

after=$(installed)

if [ -z "$after" ] || [ "$status" -ne 0 ]; then
  outcome=failed
elif [ "$after" != "$before" ]; then
  outcome=succeeded
else
  outcome=skipped
fi

error=""
if [ "$outcome" = failed ]; then
  # What curl said comes first and is the cause: the lines after it are tar and gzip complaining
  # that nothing arrived, which `tail` alone kept in its place.
  error=$(grep '^curl:' "$log" | head -1 | cut -c 1-400 || true)
  [ -n "$error" ] || error=$(grep -v '^[[:space:]]*$' "$log" | tail -3 | tr '\n' ' ' | cut -c 1-400 || true)
  [ -n "$error" ] || error="exit status $status, and it said nothing"
fi

# jq rather than printf: the error is whatever curl or tar said, and a quote or a backslash in it
# must not produce a file `ClaudeUpdate.status/2` cannot read.
if jq -n --arg outcome "$outcome" --arg version "$after" --arg error "$error" \
  '{ outcome: $outcome }
     + (if $version == "" then {} else { version: $version } end)
     + (if $error == "" then {} else { error: $error } end)' > "$log.json"; then
  mv "$log.json" "$status_file"
fi

rm -rf "$log" "$log.json"
echo "codex-update: $outcome ${after:-none}"
exit 0
