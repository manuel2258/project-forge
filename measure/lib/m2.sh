# shellcheck shell=bash
# M2, copy-on-write divergence. A btrfs subvolume holding the warm worktree and its build
# directory, snapshotted, a different realistic branch built in each.
# See docs/design/measurement-harness.md.
#
# Workload keys come from the config that common.sh sources.
# shellcheck disable=SC2154

declare -A M2_MAKESPAN=()
declare -A M2_WALL=()
M2_LEVELS=(1 2 4)
M2_KEEP=0
M2_REUSE=0

m2_branch_name() {
  echo "${1%%:*}"
}

m2_branch_sha() {
  echo "${1#*:}"
}

# One build in one snapshot, run in the background by m2_round. It appends its own record,
# because the parent cannot see a subshell's variables.
m2_build_one() {
  local label=$1 tree=$2 cmd=$3 branch=$4 concurrency=$5
  local before=$FORGE_M_RUN_DIR/census/$label.before.tsv
  local after=$FORGE_M_RUN_DIR/census/$label.after.tsv
  local changes=$FORGE_M_RUN_DIR/census/$label.changes.tsv

  census_take "$tree/$build_dir" "$before"
  measure_run "$label" "$tree" "$cmd"
  census_take "$tree/$build_dir" "$after"
  census_diff "$before" "$after" "$changes"
  census_classify "$changes"

  measure_record \
    "branch=$branch" \
    "concurrency=$concurrency" \
    "files_created=$CENSUS_CREATED" \
    "files_modified=$CENSUS_MODIFIED" \
    "bytes_written=$CENSUS_BYTES" \
    "own_rebuilds=$CENSUS_OWN" \
    "dep_rebuilds=$CENSUS_DEP" \
    "classification=$CENSUS_CLASSIFICATION" \
    "status=measured"
}

# A snapshot that has been built in is warm and cannot serve a second round, so every round
# gets its own snapshots: ten in all, four for the serial reference and two and four above it.
# Level 1 is the uncontended reference and runs every branch, one at a time, so that both
# sides of every ratio in m2_verdicts do the same work. Levels above it run their builds
# simultaneously.
m2_round_width() {
  if [ "$1" -eq 1 ]; then
    echo "${#m2_branches[@]}"
  else
    echo "$1"
  fi
}

# A snapshot that has been built in is warm and cannot serve a second round, so every round
# gets its own snapshots.
m2_round() {
  local level=$1 cmd=$2 index snap branch sha label t0 t1 wall max=0 sum=0 width
  local -a labels=()
  width=$(m2_round_width "$level")
  section "level $level"

  for ((index = 0; index < width; index++)); do
    snap=$FORGE_M_VOLUME/l$level-b$index
    branch=$(m2_branch_name "${m2_branches[$index]}")
    sha=$(m2_branch_sha "${m2_branches[$index]}")
    subvol_delete "$snap"
    snapshot_create "$FORGE_M_VOLUME/seed" "$snap"
    run git -C "$snap/src" checkout --quiet --detach "$sha" ||
      die "branch $branch ($sha) does not resolve in the snapshot"
    labels+=("l$level-b$index")
  done
  fs_sync

  t0=$(now_ns)
  for ((index = 0; index < width; index++)); do
    snap=$FORGE_M_VOLUME/l$level-b$index
    branch=$(m2_branch_name "${m2_branches[$index]}")
    if [ "$level" -eq 1 ]; then
      m2_build_one "l$level-b$index" "$snap/src" "$cmd" "$branch" "$level"
    else
      m2_build_one "l$level-b$index" "$snap/src" "$cmd" "$branch" "$level" &
    fi
  done
  wait
  t1=$(now_ns)

  # All accounting after the round's last build, so the harness never competes with what it
  # is timing.
  index=0
  for label in "${labels[@]}"; do
    wall=$(awk -F= '/^wall_ns_build=/ {print $2}' "$FORGE_M_RUN_DIR/stats/$label.env" 2> /dev/null)
    wall=${wall:-0}
    M2_WALL[$level - $index]=$wall
    sum=$((sum + wall))
    [ "$wall" -gt "$max" ] && max=$wall
    index=$((index + 1))
  done

  record "measurement=m2" "label=level-$level" "concurrency=$level" "builds=$width" \
    "makespan_ns=$((t1 - t0))" "max_wall_ns=$max" "sum_wall_ns=$sum" "status=measured"
  info "level $level: $width build(s), makespan $(((t1 - t0) / 1000000)) ms, slowest $((max / 1000000)) ms"
  M2_MAKESPAN[$level]=$((t1 - t0))
}

m2_space() {
  local index snap branch exclusive total=0
  section "space"
  fs_sync
  for ((index = 0; index < 4; index++)); do
    snap=$FORGE_M_VOLUME/l4-b$index
    branch=$(m2_branch_name "${m2_branches[$index]}")
    exclusive=$(exclusive_bytes "$snap")
    exclusive=${exclusive:-0}
    total=$((total + exclusive))
    record "measurement=m2" "label=exclusive-l4-b$index" "branch=$branch" \
      "exclusive_bytes=$exclusive" "status=measured"
    info "l4-b$index ($branch): $((exclusive / 1024 / 1024)) MiB exclusive"
  done
  record "measurement=m2" "label=exclusive-total" "exclusive_bytes=$total" "status=measured"
  qgroup_report "$FORGE_M_RUN_DIR/stats/qgroup.txt"
}

# Two ratios, because "scale acceptably" is two questions. Neither uses makespan(level 1),
# which is dominated by environment entry and moves far more between identical runs than the
# four-way makespan does.
m2_verdicts() {
  local index branches ratio contention="" throughput="" longest=0 one four
  local status reason=""
  branches=$(m2_round_width 1)

  # Contention: the same branch against itself, uncontended and four ways.
  for ((index = 0; index < branches; index++)); do
    one=${M2_WALL[1 - $index]:-0}
    four=${M2_WALL[4 - $index]:-0}
    if [ "$one" -eq 0 ] || [ "$four" -eq 0 ]; then
      continue
    fi
    ratio=$(awk -v a="$one" -v b="$four" 'BEGIN { printf "%.3f", a / b }')
    record "measurement=m2" "label=contention-b$index" \
      "branch=$(m2_branch_name "${m2_branches[$index]}")" \
      "wall_ns_serial=$one" "wall_ns_concurrent=$four" "scaling_efficiency=$ratio" \
      "status=measured"
    contention="$contention $ratio"
    [ "$one" -gt "$longest" ] && longest=$one
  done

  if [ -z "$contention" ]; then
    record "measurement=m2" "label=scaling-verdict" "status=indeterminate" \
      "reason=levels 1 and 4 were not both run, so no branch can be compared with itself"
    info "scaling: indeterminate — levels 1 and 4 were not both run"
    return 0
  fi

  contention=$(awk -v list="$contention" 'BEGIN {
    count = split(list, parts, " ")
    for (i = 1; i <= count; i++) total += parts[i]
    printf "%.3f", total / count
  }')

  # Throughput: the four-way round against its critical-path bound, which is the longest
  # uncontended build. Not a quarter of the serial total: with jobs of different sizes no
  # scheduler beats the longest one.
  if [ "${M2_MAKESPAN[4]:-0}" -gt 0 ] && [ "$longest" -gt 0 ]; then
    throughput=$(awk -v a="$longest" -v b="${M2_MAKESPAN[4]}" 'BEGIN { printf "%.3f", a / b }')
  fi

  status=pass
  if ! awk -v e="$contention" -v m="$m2_scaling_min_efficiency" 'BEGIN { exit !(e >= m) }'; then
    status=fail
    reason="each build keeps only $contention of its uncontended speed"
  elif [ -n "$throughput" ] &&
    ! awk -v e="$throughput" -v m="$m2_scaling_min_efficiency" 'BEGIN { exit !(e >= m) }'; then
    status=fail
    reason="the four-way round reaches only $throughput of its critical-path bound"
  else
    reason="each build keeps $contention of its uncontended speed; the round reaches ${throughput:-—} of its critical-path bound"
  fi

  record "measurement=m2" "label=scaling-verdict" "scaling_efficiency=$contention" \
    "throughput_efficiency=${throughput:-0}" "status=$status" "reason=$reason"
  info "scaling: $status — $reason"
}

m2_teardown() {
  local level index
  [ "$M2_KEEP" = 1 ] && {
    info "keeping the volume (--keep)"
    return 0
  }
  section "teardown"
  for level in "${M2_LEVELS[@]}"; do
    for ((index = 0; index < $(m2_round_width "$level"); index++)); do
      subvol_delete "$FORGE_M_VOLUME/l$level-b$index"
    done
  done
  subvol_delete "$FORGE_M_VOLUME/seed"
  vol_down
}

cmd_m2() {
  local cmd level
  while [ $# -gt 0 ]; do
    case $1 in
      --levels)
        IFS=, read -r -a M2_LEVELS <<< "$2"
        shift 2
        ;;
      --keep)
        M2_KEEP=1
        shift
        ;;
      --reuse)
        M2_REUSE=1
        shift
        ;;
      *) die "m2: unknown argument $1" ;;
    esac
  done

  workload_validate workload_repo workload_commit build_dir build_cmd_debug m2_branches
  fail_report
  cmd=$(build_cmd_for debug)

  m1_paths
  run_dir_init m2
  [ "$M2_REUSE" = 1 ] || {
    vol_check_stale
    fail_report
  }
  m1_ensure_warm
  [ -d "$M1_WARM/$build_dir" ] || warn "no warm build directory; run m1 first for a realistic seed"

  vol_up
  # shellcheck disable=SC2064  # the paths are wanted as they are now
  trap "m2_teardown" EXIT INT TERM

  section "seed"
  subvol_delete "$FORGE_M_VOLUME/seed"
  seed_create "$M1_REPO" "$M1_WARM" "$FORGE_M_VOLUME/seed"

  for level in "${M2_LEVELS[@]}"; do
    m2_round "$level" "$cmd"
  done

  case " ${M2_LEVELS[*]} " in
    *" 4 "*) m2_space ;;
    *) warn "level 4 was not run, so no exclusive-bytes reading" ;;
  esac
  m2_verdicts

  section "results"
  cmd_report --run "$FORGE_M_RUN_DIR"
}
