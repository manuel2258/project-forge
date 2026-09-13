# shellcheck shell=bash
# The isolation cross: four concurrent builds with one under a ceiling below its own peak.
# M2 runs four together but never under a binding ceiling; M3 binds one but always alone.
# This is the crossing, and it is the only measurement of the claim the worker tier rests on —
# an out-of-memory build kills one job, not the machine.
# See docs/design/measurement-harness.md § The isolation cross.
#
# Workload keys come from the config that common.sh sources.
# shellcheck disable=SC2154

declare -A ISO_WALL=()
declare -A ISO_PEAK=()
declare -A ISO_STATUS=()
declare -A ISO_OOM=()
ISO_ROUNDS=(control)
ISO_KEEP=0

# One build in one snapshot, run in the background by iso_round. `FORGE_M_MEMORY_MAX` is
# assigned here rather than by the caller because a background function call is a subshell:
# the ceiling reaches this build and no other, which is the whole point of the round.
iso_build_one() {
  local round=$1 index=$2 tree=$3 cmd=$4 branch=$5 ceiling=$6
  # Read by measure_run, which shellcheck cannot see from here.
  # shellcheck disable=SC2034
  local FORGE_M_MEMORY_MAX=$ceiling

  measure_run "$round-b$index" "$tree" "$cmd"
  measure_record \
    "branch=$branch" \
    "round=$round" \
    "concurrency=4" \
    "constrained=$([ "$ceiling" = infinity ] && echo false || echo true)" \
    "status=measured"

  # The parent cannot see a subshell's variables, so the round's readings come back through
  # the stats file measure_run already wrote.
  printf '%s\n' "$MR_STATUS" > "$FORGE_M_RUN_DIR/stats/$round-b$index.exit"
}

iso_round() {
  local round=$1 cmd=$2 ceiling=$3 index snap branch sha

  section "$round round"
  ISO_ROUNDS+=("$round")
  for ((index = 0; index < 4; index++)); do
    snap=$FORGE_M_VOLUME/iso-$round-b$index
    branch=$(m2_branch_name "${m2_branches[$index]}")
    sha=$(m2_branch_sha "${m2_branches[$index]}")
    subvol_delete "$snap"
    snapshot_create "$FORGE_M_VOLUME/seed" "$snap"
    run git -C "$snap/src" checkout --quiet --detach "$sha" ||
      die "branch $branch ($sha) does not resolve in the snapshot"
  done
  fs_sync

  for ((index = 0; index < 4; index++)); do
    snap=$FORGE_M_VOLUME/iso-$round-b$index
    branch=$(m2_branch_name "${m2_branches[$index]}")
    # Only branch 0 is constrained, and only in the crossed round. Three neighbours with no
    # ceiling are what makes this a test of isolation rather than of four ceilings.
    if [ "$index" -eq 0 ]; then
      iso_build_one "$round" "$index" "$snap/src" "$cmd" "$branch" "$ceiling" &
    else
      iso_build_one "$round" "$index" "$snap/src" "$cmd" "$branch" infinity &
    fi
  done
  wait

  iso_collect "$round"
}

# Everything the round's builds left behind, read after the last of them so the harness never
# competes with what it is timing.
iso_collect() {
  local round=$1 index label wall peak oom status
  for ((index = 0; index < 4; index++)); do
    label=$round-b$index
    wall=$(awk -F= '/^wall_ns_build=/ {print $2}' "$FORGE_M_RUN_DIR/stats/$label.env" 2> /dev/null)
    peak=$(awk -F= '/^mem_peak_bytes=/ {print $2}' "$FORGE_M_RUN_DIR/stats/$label.env" 2> /dev/null)
    oom=$(awk -F= '/^oom_kills=/ {print $2}' "$FORGE_M_RUN_DIR/stats/$label.env" 2> /dev/null)
    status=$(cat "$FORGE_M_RUN_DIR/stats/$label.exit" 2> /dev/null)
    ISO_WALL[$label]=${wall:-0}
    ISO_PEAK[$label]=${peak:-0}
    ISO_OOM[$label]=${oom:-0}
    ISO_STATUS[$label]=${status:-0}
    info "$label: exit ${ISO_STATUS[$label]}, peak $((${ISO_PEAK[$label]} / 1024 / 1024)) MiB, $((${ISO_WALL[$label]} / 1000000)) ms"
  done
}

# A fraction of the peak the same branch reached in the control round, so the ceiling is below
# this build's peak on this machine rather than a number someone wrote down once.
#
# Every lookup below goes through a variable holding the key. An associative subscript is a
# string, and shfmt reads `[control-b0]` as arithmetic and would space it out into a different
# key — silently, since a missing key is just empty.
iso_ceiling() {
  local factor=$1 key=control-b0 peak
  peak=${ISO_PEAK[$key]:-0}
  [ "$peak" -gt 0 ] || return 1
  awk -v p="$peak" -v f="$factor" 'BEGIN { printf "%d", p * f }'
}

# Did the ceiling actually kill this round's victim? A non-zero exit is enough on its own: the
# OOM killer's own record is the better evidence but it is not always there to read, and a
# build that exits non-zero under a ceiling it did not have before did not fail for fun.
iso_victim_killed() {
  local victim=$1-b0
  [ "${ISO_OOM[$victim]:-0}" -gt 0 ] || [ "${ISO_STATUS[$victim]:-0}" -ne 0 ]
}

# Three questions, and the verdict names whichever failed. A victim that survived is not a
# pass: the ceiling did not bind, so nothing was learned about what happens when it does.
iso_verdicts() {
  local round=$1 factor=$2
  local index label control efficiency worst=1 worst_branch="" survivors=0
  local status=pass reason="" victim_killed=false
  local control_wall crossed_wall

  if iso_victim_killed "$round"; then
    victim_killed=true
  fi

  for ((index = 1; index < 4; index++)); do
    label=$round-b$index
    control=control-b$index
    [ "${ISO_STATUS[$label]:-1}" -eq 0 ] && survivors=$((survivors + 1))
    control_wall=${ISO_WALL[$control]:-0}
    crossed_wall=${ISO_WALL[$label]:-0}

    if [ "$control_wall" -gt 0 ] && [ "$crossed_wall" -gt 0 ]; then
      efficiency=$(awk -v a="$control_wall" -v b="$crossed_wall" 'BEGIN { printf "%.3f", a / b }')
      record "measurement=isolation" "label=neighbour-b$index" \
        "branch=$(m2_branch_name "${m2_branches[$index]}")" \
        "wall_ns_control=$control_wall" \
        "wall_ns_crossed=$crossed_wall" \
        "scaling_efficiency=$efficiency" "status=measured"
      if awk -v e="$efficiency" -v w="$worst" 'BEGIN { exit !(e < w) }'; then
        worst=$efficiency
        worst_branch=$(m2_branch_name "${m2_branches[$index]}")
      fi
    fi
  done

  if [ "$victim_killed" = false ]; then
    status=indeterminate
    reason="no ceiling down to $factor of the observed peak killed the constrained build, so nothing was learned about what happens when one does"
  elif [ "$survivors" -ne 3 ]; then
    status=fail
    reason="the ceiling killed the constrained build and $((3 - survivors)) of its neighbours"
  elif awk -v e="$worst" -v m="$isolation_min_efficiency" 'BEGIN { exit !(e < m) }'; then
    status=fail
    reason="every neighbour finished, but $worst_branch kept only $worst of its unconstrained speed"
  else
    reason="the constrained build was killed at its ceiling; all three neighbours finished, the slowest at $worst of its unconstrained speed"
  fi

  control="control-b0"
  record "measurement=isolation" "label=isolation-verdict" \
    "round=$round" "victim_factor=$factor" \
    "memory_max=${ISO_CEILING:-0}" \
    "mem_peak_bytes=${ISO_PEAK[$control]:-0}" \
    "oom_killed=$victim_killed" \
    "scaling_efficiency=$worst" "status=$status" "reason=$reason"
  info "isolation: $status — $reason"
}

iso_teardown() {
  local round index
  [ "$ISO_KEEP" = 1 ] && {
    info "keeping the volume (--keep)"
    return 0
  }
  section "teardown"
  for round in "${ISO_ROUNDS[@]}"; do
    for ((index = 0; index < 4; index++)); do
      subvol_delete "$FORGE_M_VOLUME/iso-$round-b$index"
    done
  done
  subvol_delete "$FORGE_M_VOLUME/seed"
  vol_down
}

cmd_isolation() {
  local cmd
  while [ $# -gt 0 ]; do
    case $1 in
      --keep)
        ISO_KEEP=1
        shift
        ;;
      *) die "isolation: unknown argument $1" ;;
    esac
  done

  workload_validate workload_repo workload_commit build_dir build_cmd_debug m2_branches
  [ "${#m2_branches[@]}" -ge 4 ] ||
    fail_add "isolation needs four branches in m2_branches, found ${#m2_branches[@]}"
  fail_report
  cmd=$(build_cmd_for debug)

  m1_paths
  run_dir_init isolation
  vol_check_stale
  fail_report
  m1_ensure_warm
  [ -d "$M1_WARM/$build_dir" ] || warn "no warm build directory; run m1 first for a realistic seed"

  vol_up
  trap "iso_teardown" EXIT INT TERM

  section "seed"
  subvol_delete "$FORGE_M_VOLUME/seed"
  seed_create "$M1_REPO" "$M1_WARM" "$FORGE_M_VOLUME/seed"

  iso_round control "$cmd" infinity

  if ! iso_ceiling "1" > /dev/null; then
    record "measurement=isolation" "label=isolation-verdict" "status=indeterminate" \
      "reason=the control round reported no peak for branch 0, so no ceiling could be derived"
    info "isolation: indeterminate — no peak to derive a ceiling from"
    section "results"
    cmd_report --run "$FORGE_M_RUN_DIR"
    return 0
  fi

  # Descending, because one fraction is a guess. The first run of this measurement set the
  # ceiling at half the observed peak: it bound — the victim's peak came out at exactly the
  # ceiling — and the build finished anyway, by reclaiming. That is M3's "usable limit is not
  # the peak" arriving from the other side, and it means a single factor cannot be relied on
  # to produce the kill this measurement exists to observe.
  local attempt=0 factor round=""
  for factor in "${isolation_victim_factors[@]}"; do
    attempt=$((attempt + 1))
    ISO_CEILING=$(iso_ceiling "$factor")
    round=crossed$attempt
    info "ceiling: $((ISO_CEILING / 1024 / 1024)) MiB, $factor of branch 0's control peak"
    iso_round "$round" "$cmd" "$ISO_CEILING"
    record "measurement=isolation" "label=$round-ceiling" "round=$round" \
      "victim_factor=$factor" "memory_max=$ISO_CEILING" "status=measured"
    iso_victim_killed "$round" && break
    warn "the ceiling at $factor did not kill the constrained build; going lower"
  done

  iso_verdicts "$round" "$factor"

  section "results"
  cmd_report --run "$FORGE_M_RUN_DIR"
}
