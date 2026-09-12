# shellcheck shell=bash
# Preconditions. Collects every failure and reports once: a two-hour run that stops at minute
# ninety because rsync is missing is the failure mode worth engineering against.
# See docs/design/measurement-harness.md.
#
# Workload keys come from the config that common.sh sources.
# shellcheck disable=SC2154

preflight_binaries() {
  local needed=(git rsync jq awk sed find) missing
  [ -n "${workload_env:-}" ] && needed+=(nix)
  if [ "$FORGE_M_FAKE" != 1 ]; then
    needed+=(systemd-run systemctl btrfs mkfs.btrfs losetup)
  fi
  for missing in "${needed[@]}"; do
    have "$missing" || fail_add "$missing is not on PATH (nix develop .#measure provides it)"
  done
  if ! find . -maxdepth 0 -printf '' > /dev/null 2>&1; then
    fail_add "find does not support -printf; the census needs GNU findutils"
  fi
}

preflight_cgroups() {
  [ "$FORGE_M_FAKE" = 1 ] && return 0
  if [ "$(uname -s)" != Linux ]; then
    fail_add "the measurements are a Linux host's: no cgroups, no btrfs, no systemd elsewhere"
    return 0
  fi
  if [ ! -r /sys/fs/cgroup/cgroup.controllers ]; then
    fail_add "no cgroup v2 at /sys/fs/cgroup (unified hierarchy required)"
    return 0
  fi
  grep -qw memory /sys/fs/cgroup/cgroup.controllers ||
    fail_add "the cgroup v2 memory controller is not available, so no peak can be read"
}

# Capability, not version: probe a throwaway unit rather than asserting a systemd release.
preflight_units() {
  local client manager
  [ "$FORGE_M_FAKE" = 1 ] && return 0
  have systemctl && have systemd-run || return 0

  client=$(systemd-run --version 2> /dev/null | head -1 | awk '{print $2}')
  manager=$(systemctl --version 2> /dev/null | head -1 | awk '{print $2}')
  if [ -n "$client" ] && [ -n "$manager" ] && [ "$client" != "$manager" ]; then
    fail_add "systemd-run ($client) and the host manager ($manager) disagree; put /run/current-system/sw/bin first on PATH and keep pkgs.systemd out of the shell"
  fi

  if [ "$(slice_mode)" = system ] && ! sudo -n true 2> /dev/null; then
    fail_add "sudo -n fails: system units need passwordless sudo for systemd-run, mount, umount, losetup, btrfs and drop_caches (or set FORGE_M_USER_UNITS=1)"
    return 0
  fi

  if ! preflight_probe_unit; then
    fail_add "a probe unit could not read its own memory.peak; the kernel or the slice does not account memory"
  fi

  if [ "$(slice_mode)" = user ]; then
    local delegate
    # user@N.service is a *system* unit: asking the user manager about it always answers no.
    delegate=$(systemctl show "user@$(id -u).service" -p Delegate --value 2> /dev/null || echo no)
    [ "$delegate" = yes ] ||
      fail_add "the user manager has no delegation, so MemoryMax= would be silently ignored"
  fi
}

preflight_probe_unit() {
  local -a argv
  if [ "$(slice_mode)" = user ]; then
    argv=(systemd-run --user)
  else
    argv=(sudo systemd-run)
  fi
  # The $cg inside the probe belongs to the probe's own shell, not to this one.
  # shellcheck disable=SC2016
  "${argv[@]}" --quiet --unit="forge-measure-probe-$$" --service-type=exec --wait --pipe \
    --property=MemoryAccounting=yes --property=MemoryMax=infinity \
    -- bash -c 'cg=$(sed -n "s|^0::||p" /proc/self/cgroup); test -r "/sys/fs/cgroup$cg/memory.peak"' \
    > /dev/null 2>&1
}

preflight_workload() {
  local repo=$FORGE_M_WORKLOAD_DIR/repo entry sha
  [ -d "$repo/.git" ] || return 0
  git -C "$repo" rev-parse --verify --quiet "$workload_commit^{commit}" > /dev/null ||
    fail_add "workload_commit $workload_commit does not resolve in $repo"
  for entry in "${m2_branches[@]}"; do
    sha=${entry#*:}
    git -C "$repo" rev-parse --verify --quiet "$sha^{commit}" > /dev/null ||
      fail_add "m2_branches entry '$entry' does not resolve in $repo"
  done
}

preflight_environment() {
  [ -n "${workload_env:-}" ] || return 0
  have nix || return 0
  [ "$FORGE_M_DRY_RUN" = 1 ] && return 0
  [ -d "$FORGE_M_WORKLOAD_DIR/warm" ] || return 0
  # Also warms Nix's evaluation cache, so it is not counted against the first build.
  (cd "$FORGE_M_WORKLOAD_DIR/warm" && nix develop ".#${workload_env}" --command true) > /dev/null 2>&1 ||
    fail_add "nix develop .#${workload_env} fails in $FORGE_M_WORKLOAD_DIR/warm"
}

preflight_space() {
  local free_kb
  free_kb=$(df -Pk "$FORGE_M_SCRATCH" 2> /dev/null | awk 'NR == 2 {print $4}')
  [ -n "$free_kb" ] || return 0
  if [ "$free_kb" -lt $((8 * 1024 * 1024)) ]; then
    fail_add "$((free_kb / 1024 / 1024)) GiB free under $FORGE_M_SCRATCH; the volume alone wants $m2_volume_size"
  fi
}

preflight_warnings() {
  local swap governor
  swap=$(awk 'NR == 2 {print $3}' /proc/swaps 2> /dev/null || echo 0)
  [ -n "$swap" ] && [ "$swap" != 0 ] &&
    warn "swap is on; MemorySwapMax=0 keeps the peak honest but the host may still thrash"
  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2> /dev/null || echo unknown)
  [ "$governor" != performance ] && [ "$governor" != unknown ] &&
    warn "CPU governor is $governor; wall times will vary with clock behaviour"
  [ "${repeats:-1}" -eq 1 ] && warn "repeats=1: a single sample is noise, 3 is the recommendation"
  [ -z "$FORGE_M_BTRFS_MOUNT" ] &&
    warn "no FORGE_M_BTRFS_MOUNT: M2 uses a loopback image, whose wall times are indicative"
  return 0
}

preflight_all() {
  mkdir -p "$FORGE_M_SCRATCH"
  preflight_binaries
  preflight_cgroups
  preflight_units
  preflight_workload
  preflight_environment
  preflight_space
}

cmd_preflight() {
  [ $# -eq 0 ] || die "preflight: unknown argument $1"
  section "preflight for workload $workload_name"
  preflight_all
  [ "$FORGE_M_REUSE" = 1 ] || vol_check_stale
  preflight_warnings
  fail_report
  info "ready: $(slice_mode) slices, volume $FORGE_M_VOLUME"
}
