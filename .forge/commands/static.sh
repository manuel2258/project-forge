#!/usr/bin/env bash
# Everything the gate checks before it runs a test, as a forge command: shell lint, and in each
# Mix project compile with warnings as errors, format check and Credo strict (the platform's is
# its own `mix check.static`, which also builds the assets the browser test loads).
#
# **A failure here costs seconds and a failure in `check` costs a quarter of an hour**, so an agent
# invokes this first and `check` once, last. It runs on the command pool, never in the agent's own
# slice. Exit 1 is a finding; 2 is the machine (as `check.sh`).
set -euo pipefail
cd "$FORGE_CHECKOUT"

missing=()
for tool in mix shellcheck shfmt; do
  command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "the checks cannot run on this machine: no ${missing[*]}" >&2
  echo "this is the machine, not the change — nothing was checked" >&2
  exit 2
fi

# shellcheck source=bin/lib/mix-cache.sh
. bin/lib/mix-cache.sh
forge_mix_cache_ensure "$PWD"

# The same lists `bin/check` lints; keep the two together.
echo "==> shell"
shellcheck -x bin/check bin/measure bin/release bin/worker-update bin/e2e-chat bin/hetzner-image bin/look bin/changelog-add \
  bin/lib/*.sh measure/lib/*.sh measure/workloads/*.sh .forge/commands/*.sh \
  platform/priv/git-hooks/* platform/priv/hetzner/*.sh worker/test/support/*.sh nix/codex-update.sh nix/boot-menu.sh nix/system-update.sh nix/worker-health/*.sh nix/worker-health/jobs/*.sh nix/worker-update-boots/*.sh
shfmt -d -i 2 -ci -sr bin measure .forge/commands platform/priv/git-hooks platform/priv/hetzner worker/test/support nix/codex-update.sh nix/boot-menu.sh nix/system-update.sh nix/worker-health nix/worker-update-boots

for project in core worker; do
  echo "==> $project"
  (
    cd "$project"
    mix deps.get > /dev/null
    env MIX_ENV=test mix compile --warnings-as-errors
    env MIX_ENV=test mix format --check-formatted
    env MIX_ENV=test mix credo --strict
  )
done

echo "==> platform"
(
  cd platform
  mix deps.get > /dev/null
  env MIX_ENV=test mix check.static
)
