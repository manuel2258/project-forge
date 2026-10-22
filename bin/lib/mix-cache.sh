# shellcheck shell=bash
# Where Mix's caches live for every script in this repository that runs `mix`. Sourced, not run.
#
# **Inside the checkout, so a ticket's next agent job inherits them.** An *agent* job, because
# only an agent job's worktree is promoted to the ticket's volume: the gate's automatic caller is
# the `check` command job, which snapshots that volume and discards its tree, so it reads a warm
# cache and never leaves one (`ForgeWorker.Link`).
#
# `mix local.hex` installs into MIX_HOME and Hex caches the package registry and the tarballs it
# downloads in HEX_HOME; both default under $HOME, and a job's HOME is a fresh directory made per
# job, thrown away with it. So however warm the checkout was — and `deps/` is carried, being an
# ignored directory inside it — every single job reinstalled Hex and refetched the registry.
# Pointed at ignored directories inside the checkout they are carried like `deps/` is, which is
# the pattern `docs/design/worker-tier.md` § The ticket volume prescribes for a tool's dependency
# cache.
#
# `_build/` is carried by the same mechanism and is nothing here's to arrange. It keeps every
# dependency compiled and rebuilds the three projects' own sources, because Mix puts the working
# directory in its compile cache key and a job's worktree is a new path every job — nothing here
# changes that either way, and `docs/design/worker-tier.md` § The ticket volume has the figures.
#
# An operator's own `~/.mix` and `~/.hex` are not read and not written: these are exported for the
# sourcing script's own processes and nothing else, so the first run after this change builds
# `.mix-home/` once and every run after it is as warm as before.
#
# Both functions take the repository root, which every script here has already `cd`'d to, and
# neither assumes anything of the environment it is called in.

# For the script that **owns** the caches: point Mix at them and install Hex when they are cold.
#
# A machine that has never run the gate — a command pool's, not an operator's — has an empty
# MIX_HOME, and `mix check` goes straight to compiling: no alias in any project installs Hex or
# fetches deps, so Mix dies asking for Hex before a single check runs. Hex and rebar are installed
# when they are absent and left alone when they are not, which is the whole saving on a warm
# machine; `mix deps.get` still runs every time, in every project, because a lock the deps do not
# match is the same cold-machine failure one commit later. Nothing here relaxes a check.
forge_mix_cache_ensure() {
  local root="$1"

  export MIX_HOME="$root/.mix-home"
  export HEX_HOME="$root/.hex-home"

  if ! mix hex.info > /dev/null 2>&1; then
    echo "==> hex"
    mix local.hex --force > /dev/null
    mix local.rebar --force > /dev/null
  fi
}

# For a script that only **borrows** what the gate built: use the checkout's caches when Hex
# answers out of them, and leave the environment alone when it does not.
#
# The question is asked with `mix hex.info` in the environment it would export, and not of the
# directory: a `.mix-home/` that exists and holds no archive is reachable by a bare `mkdir`, or by
# a gate run interrupted after Mix created it, and exporting that would take an operator whose
# `~/.mix` is warm from Hex to no Hex at all — precisely what this conditional exists to prevent.
forge_mix_cache_borrow() {
  local root="$1"

  if MIX_HOME="$root/.mix-home" HEX_HOME="$root/.hex-home" mix hex.info > /dev/null 2>&1; then
    export MIX_HOME="$root/.mix-home"
    export HEX_HOME="$root/.hex-home"
  fi
}
