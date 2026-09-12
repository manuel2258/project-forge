# shellcheck shell=bash
# M1, build cache acceptance. Three variants, each measured as: restore a cache into a fresh
# worktree, build, count what rebuilt and compare against a warm local build.
# See docs/design/measurement-harness.md.
#
# Workload keys come from the config that common.sh sources.
# shellcheck disable=SC2154

M1_REPO=""
M1_WARM=""
M1_WARM_OWN_WALL=0
M1_WARM_OWN_FILES=0
M1_STATUS=""
M1_REASON=""
# Assignments the unit gets; record fields are passed to m1_build as arguments instead, so
# the two never get confused with each other.
M1_SETENV=()

m1_paths() {
  M1_REPO=$FORGE_M_WORKLOAD_DIR/repo
  M1_WARM=$FORGE_M_WORKLOAD_DIR/warm
}

# The warm tree is the reference, the rsync source for variant (c) and M2's seed source, so
# it is built once and kept.
m1_ensure_warm() {
  section "warm tree"
  run mkdir -p "$FORGE_M_WORKLOAD_DIR"
  if [ ! -d "$M1_REPO/.git" ]; then
    run git clone --quiet "$workload_repo" "$M1_REPO"
  fi
  run git -C "$M1_REPO" fetch --quiet --all --tags || true
  if [ ! -d "$M1_WARM" ]; then
    run git -C "$M1_REPO" worktree add --quiet --detach "$M1_WARM" "$workload_commit"
  fi
  info "repo:  $M1_REPO"
  info "warm:  $M1_WARM"
}

m1_fresh_worktree() {
  local path=$1
  run git -C "$M1_REPO" worktree remove --force "$path" > /dev/null 2>&1 || true
  run rm -rf "$path"
  run git -C "$M1_REPO" worktree add --quiet --detach "$path" "$workload_commit"
  run rm -rf "${path:?}/${build_dir:?}"
}

# One measured build with its census around it, producing exactly one record. Extra
# arguments are record fields; the unit's environment comes from M1_SETENV.
m1_build() {
  local label=$1 tree=$2 cmd=$3 variant=$4 status=$5 reason=$6
  shift 6
  local before=$FORGE_M_RUN_DIR/census/$label.before.tsv
  local after=$FORGE_M_RUN_DIR/census/$label.after.tsv
  local changes=$FORGE_M_RUN_DIR/census/$label.changes.tsv

  if [ "$FORGE_M_DRY_RUN" = 1 ]; then
    measure_run "$label" "$tree" "$cmd" "${M1_SETENV[@]}"
    return 0
  fi

  census_take "$tree/$build_dir" "$before"
  measure_run "$label" "$tree" "$cmd" "${M1_SETENV[@]}"
  census_take "$tree/$build_dir" "$after"
  census_diff "$before" "$after" "$changes"
  census_classify "$changes"
  census_parse_log "$MR_LOG" || true

  measure_record \
    "variant=$variant" \
    "profile=${FORGE_M_PROFILE:-debug}" \
    "files_created=$CENSUS_CREATED" \
    "files_modified=$CENSUS_MODIFIED" \
    "files_touched=$CENSUS_TOUCHED" \
    "files_deleted=$CENSUS_DELETED" \
    "bytes_written=$CENSUS_BYTES" \
    "own_rebuilds=$CENSUS_OWN" \
    "dep_rebuilds=$CENSUS_DEP" \
    "unclassified_rebuilds=$CENSUS_UNCLASSIFIED" \
    "classification=$CENSUS_CLASSIFICATION" \
    "status=$status" \
    "reason=$reason" \
    "$@"
}

# The three references, in this order, so the warm tree is left warm for variant (c) and M2.
m1_references() {
  local cmd=$1
  section "references"

  if [ -n "${clean_cmd:-}" ]; then
    workload_shell "$M1_WARM" "$clean_cmd" || true
  else
    run rm -rf "${M1_WARM:?}/${build_dir:?}"
  fi
  m1_build cold "$M1_WARM" "$cmd" reference ok "from an empty build directory"

  m1_build warm_noop "$M1_WARM" "$cmd" reference ok "nothing changed"

  run census_touch_own_sources "$M1_WARM"
  m1_build warm_own "$M1_WARM" "$cmd" reference ok "own sources invalidated"
  M1_WARM_OWN_WALL=$MR_WALL_NS_BUILD
  M1_WARM_OWN_FILES=$((CENSUS_CREATED + CENSUS_MODIFIED))
  info "warm_own: $((M1_WARM_OWN_WALL / 1000000)) ms, $M1_WARM_OWN_FILES files"
}

# pass only when no dependency rebuilt, the file count is within the slack and the build was
# within the factor. not_applicable never becomes a pass; nor does an unmeasurable variant.
m1_verdict() {
  local wall=$1 files=$2 dep=$3 classification=$4 exit_status=$5 cold=${6:-ok}
  M1_STATUS=pass
  M1_REASON=""
  if [ "$exit_status" -ne 0 ]; then
    M1_STATUS=fail
    M1_REASON="the build exited $exit_status"
    return 0
  fi
  if [ "$classification" = none ]; then
    M1_STATUS=indeterminate
    M1_REASON="no own_paths and no parse_rebuilds, so nothing can say what rebuilt"
    return 0
  fi
  if [ "$cold" = none ]; then
    M1_STATUS=indeterminate
    M1_REASON="the page cache was not dropped, so the disk was not cold"
    return 0
  fi
  if [ "$dep" -gt 0 ]; then
    M1_STATUS=fail
    M1_REASON="$dep dependency artefacts rebuilt"
    return 0
  fi
  if [ "$M1_WARM_OWN_FILES" -gt 0 ] &&
    ! awk -v a="$files" -v b="$M1_WARM_OWN_FILES" -v s="$m1_file_slack" \
      'BEGIN { exit !(a <= b * s) }'; then
    M1_STATUS=fail
    M1_REASON="$files files written against warm_own's $M1_WARM_OWN_FILES"
    return 0
  fi
  if [ "$M1_WARM_OWN_WALL" -gt 0 ] &&
    ! awk -v a="$wall" -v b="$M1_WARM_OWN_WALL" -v f="$m1_time_factor" \
      'BEGIN { exit !(a <= b * f) }'; then
    M1_STATUS=fail
    M1_REASON="$((wall / 1000000)) ms against warm_own's $((M1_WARM_OWN_WALL / 1000000)) ms"
    return 0
  fi
  return 0
}

m1_record_verdict() {
  local variant=$1 cold=${2:-ok}
  if [ "$FORGE_M_DRY_RUN" = 1 ]; then
    info "would evaluate variant $variant against warm_own"
    return 0
  fi
  # MR_* are set by measure_run in exec.sh.
  # shellcheck disable=SC2153
  m1_verdict "$MR_WALL_NS_BUILD" "$((CENSUS_CREATED + CENSUS_MODIFIED))" \
    "$CENSUS_DEP" "$CENSUS_CLASSIFICATION" "$MR_STATUS" "$cold"
  record "measurement=m1" "label=$variant-verdict" "variant=$variant" \
    "status=$M1_STATUS" "reason=$M1_REASON"
  info "variant $variant: $M1_STATUS${M1_REASON:+ — $M1_REASON}"
}

m1_not_applicable() {
  local variant=$1 reason=$2
  record "measurement=m1" "label=$variant-verdict" "variant=$variant" \
    "status=not_applicable" "reason=$reason"
  info "variant $variant: not applicable — $reason"
}

# (a) A build directory produced by a Nix builder from the dependency closure alone.
m1_variant_a() {
  local cmd=$1 tree=$FORGE_M_WORKLOAD_DIR/m1a store t0 t1
  section "variant (a): dependency-closure build directory"
  if [ -z "${dep_seed_attr:-}" ]; then
    m1_not_applicable a "workload_has_no_dep_closure_builder"
    return 0
  fi
  m1_fresh_worktree "$tree"
  t0=$(now_ns)
  # dep_seed_attr is an attribute of the workload's flake, so it is evaluated in the
  # worktree. From forge's own root a bare `.#` would resolve to forge's flake instead.
  if [ "$FORGE_M_DRY_RUN" = 1 ]; then
    run bash -o pipefail -c "cd '$tree' && nix build --no-link --print-out-paths '$dep_seed_attr'"
    store=/nix/store/dry-run
  else
    store=$(cd "$tree" && nix build --no-link --print-out-paths "$dep_seed_attr") ||
      die "nix build $dep_seed_attr failed in $tree"
  fi
  run mkdir -p "$tree/$build_dir"
  # Store paths are read-only and the build has to write into what it is given.
  run cp -a "$store/${dep_seed_subpath}/." "$tree/$build_dir/"
  run chmod -R u+w "$tree/$build_dir"
  t1=$(now_ns)
  m1_build m1a "$tree" "$cmd" a measured "restored from $store" \
    "restore_wall_ns=$((t1 - t0))" \
    "restore_bytes=$(nix path-info -S --json "$store" 2> /dev/null | jq -r '.[0].closureSize // 0' 2> /dev/null || echo 0)"
  m1_record_verdict a
}

# (b) A compilation cache made elsewhere, on another volume, read from a cold disk.
m1_variant_b() {
  local cmd=$1 tree=$FORGE_M_WORKLOAD_DIR/m1b cold
  section "variant (b): compilation cache"
  if [ "${#cache_env[@]}" -eq 0 ]; then
    m1_not_applicable b "toolchain_has_no_compilation_cache"
    return 0
  fi
  m1_cache_volume_up
  section "populating the cache"
  M1_SETENV=("${cache_env[@]}")
  if [ -n "${cache_populate_cmd:-}" ]; then
    workload_shell "$M1_WARM" "$cache_populate_cmd"
  else
    m1_build m1b-populate "$M1_WARM" "$cmd" b ok "cache population"
  fi
  if [ -n "${cache_reset_cmd:-}" ]; then
    workload_shell "$M1_WARM" "$cache_reset_cmd" || true
  fi
  m1_stats_capture before
  m1_fresh_worktree "$tree"
  cold=$(m1_go_cold)
  info "cold disk: $cold"
  m1_build m1b "$tree" "$cmd" b measured "cache on $FORGE_M_CACHE_DIR" \
    "cold_method=$cold"
  M1_SETENV=()
  m1_stats_capture after
  m1_record_verdict b "$cold"
}

# (c) The baseline: a warm build directory rsynced from a different checkout path, which is
# what exposes absolute-path and mtime sensitivity.
m1_variant_c() {
  local cmd=$1 tree=$FORGE_M_WORKLOAD_DIR/m1c-fresh-checkout embedded=0
  section "variant (c): rsynced warm build directory"
  m1_fresh_worktree "$tree"
  run mkdir -p "$tree/$build_dir"
  run rsync -aHAX --delete "$M1_WARM/$build_dir/" "$tree/$build_dir/"
  if [ "$FORGE_M_DRY_RUN" != 1 ]; then
    # One generic diagnostic that usually explains a failure instead of merely recording it.
    embedded=$({ grep -rlF --binary-files=text "$M1_WARM" "$tree/$build_dir" 2> /dev/null || true; } | wc -l)
    info "files embedding the old checkout path: $embedded"
  fi
  m1_build m1c "$tree" "$cmd" c measured "rsynced from $M1_WARM" \
    "embedded_old_path_files=$embedded"
  m1_record_verdict c
}

m1_cache_volume_up() {
  run mkdir -p "$FORGE_M_CACHE_DIR"
  [ "$FORGE_M_FAKE" = 1 ] && return 0
  mountpoint -q "$FORGE_M_CACHE_DIR" && return 0
  local img=$FORGE_M_WORKLOAD_DIR/cache.img
  if [ ! -f "$img" ]; then
    run truncate -s "$m2_volume_size" "$img"
    run mkfs.ext4 -q "$img"
  fi
  run sudo mount -o loop "$img" "$FORGE_M_CACHE_DIR"
  run sudo chown "$(id -u):$(id -g)" "$FORGE_M_CACHE_DIR"
}

# Unmount and remount drops that filesystem's page cache exactly; drop_caches covers the
# rest. Without root the run is recorded as not cold rather than pretending.
m1_go_cold() {
  if [ "$FORGE_M_FAKE" = 1 ]; then
    echo fake
    return 0
  fi
  local method=none
  if mountpoint -q "$FORGE_M_CACHE_DIR" 2> /dev/null; then
    if run sudo umount "$FORGE_M_CACHE_DIR" && run sudo mount -o loop \
      "$FORGE_M_WORKLOAD_DIR/cache.img" "$FORGE_M_CACHE_DIR"; then
      method=remount
    fi
  fi
  if run sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2> /dev/null; then
    if [ "$method" = remount ]; then
      method=remount+drop_caches
    else
      method=drop_caches
    fi
  fi
  echo "$method"
}

m1_stats_capture() {
  local when=$1
  [ -n "${cache_stats_cmd:-}" ] || return 0
  [ "$FORGE_M_DRY_RUN" = 1 ] && return 0
  workload_shell "$M1_WARM" "$cache_stats_cmd" \
    > "$FORGE_M_RUN_DIR/stats/cache-$when.txt" 2>&1 || true
}

cmd_m1() {
  local only=all profile=debug
  while [ $# -gt 0 ]; do
    case $1 in
      --only)
        only=$2
        shift 2
        ;;
      --profile)
        profile=$2
        shift 2
        ;;
      *) die "m1: unknown argument $1" ;;
    esac
  done

  workload_validate workload_repo workload_commit build_dir build_cmd_debug own_sources
  fail_report
  FORGE_M_PROFILE=$profile
  local cmd
  cmd=$(build_cmd_for "$profile")
  [ -n "$cmd" ] || die "workload $workload_name has no build_cmd_$profile"

  m1_paths
  run_dir_init m1
  m1_ensure_warm
  measure_env_baseline "$M1_WARM"
  m1_references "$cmd"

  case $only in
    all)
      m1_variant_a "$cmd"
      m1_variant_b "$cmd"
      m1_variant_c "$cmd"
      ;;
    a) m1_variant_a "$cmd" ;;
    b) m1_variant_b "$cmd" ;;
    c) m1_variant_c "$cmd" ;;
    *) die "m1: --only takes a, b or c" ;;
  esac

  section "results"
  cmd_report --run "$FORGE_M_RUN_DIR"
}
