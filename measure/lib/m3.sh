# shellcheck shell=bash
# M3, peak build memory. Every M1 and M2 build already carried a peak; this adds the runs
# nothing else performs and turns them into a MemoryMax per slice.
# See docs/design/measurement-harness.md.
#
# Workload keys come from the config that common.sh sources, and FORGE_M_MEMORY_MAX is read
# by measure_run in exec.sh.
# shellcheck disable=SC2154,SC2034

M3_SWEEP=0
M3_PEAK=0

m3_measure_profile() {
  local profile=$1 cmd prepare heavy prep_var heavy_var
  cmd=$(build_cmd_for "$profile")
  if [ -z "$cmd" ]; then
    record "measurement=m3" "label=$profile" "profile=$profile" \
      "status=not_applicable" "reason=the workload has no build_cmd_$profile"
    info "profile $profile: not applicable — no build command"
    return 0
  fi

  section "profile $profile"
  # The undistorted peak: a binding ceiling would suppress it by forcing reclaim, and swap
  # would hide it, which is why MemorySwapMax=0 is set for every unit.
  FORGE_M_MEMORY_MAX=${mem_probe_max:-infinity}

  if [ -n "${clean_cmd:-}" ]; then
    workload_shell "$M1_WARM" "$clean_cmd" || true
  else
    run rm -rf "${M1_WARM:?}/${build_dir:?}"
  fi
  measure_run "$profile-cold" "$M1_WARM" "$cmd"
  measure_record "profile=$profile" "status=measured" "reason=from an empty build directory"
  m3_track_peak

  run census_touch_own_sources "$M1_WARM"
  measure_run "$profile-warm" "$M1_WARM" "$cmd"
  measure_record "profile=$profile" "status=measured" "reason=own sources invalidated"
  m3_track_peak

  prep_var="heaviest_step_prepare_$profile"
  heavy_var="heaviest_step_cmd_$profile"
  prepare=${!prep_var:-}
  heavy=${!heavy_var:-}
  if [ -z "$heavy" ]; then
    record "measurement=m3" "label=$profile-heaviest" "profile=$profile" \
      "status=not_applicable" "reason=toolchain_exposes_no_separable_heaviest_step"
    info "profile $profile: no separable heaviest step"
    return 0
  fi
  # Untimed and unmeasured: it only brings everything but the heaviest step up to date.
  [ -n "$prepare" ] && workload_shell "$M1_WARM" "$prepare"
  measure_run "$profile-heaviest" "$M1_WARM" "$heavy"
  measure_record "profile=$profile" "status=measured" "reason=the heaviest step alone"
  m3_track_peak
}

m3_track_peak() {
  [ "$FORGE_M_DRY_RUN" = 1 ] && return 0
  if [ "${MR_MEM_PEAK:-0}" -gt "$M3_PEAK" ] 2> /dev/null; then
    M3_PEAK=$MR_MEM_PEAK
  fi
}

# The peaks M1 and M2 already recorded, so the table shows the maximum this workload has ever
# been seen to want, including under contention.
m3_aggregate_prior() {
  local dir max=0 peak label=""
  have jq || return 0
  for dir in "$FORGE_M_SCRATCH/results/$workload_name"/*/; do
    [ -f "$dir/run.jsonl" ] || continue
    peak=$(jq -s 'map(.mem_peak_bytes // 0) | max // 0' "$dir/run.jsonl" 2> /dev/null || echo 0)
    if [ "${peak:-0}" -gt "$max" ] 2> /dev/null; then
      max=$peak
      label=$(basename "$dir")
    fi
  done
  [ "$max" -gt 0 ] || return 0
  record "measurement=m3" "label=observed-max-peak" "mem_peak_bytes=$max" \
    "status=measured" "reason=highest peak in any run of this workload ($label)"
  info "highest peak across all runs: $((max / 1024 / 1024)) MiB ($label)"
  [ "$max" -gt "$M3_PEAK" ] && M3_PEAK=$max
  return 0
}

# The usable limit is not the peak: a build under mild pressure often still finishes, more
# slowly. The sweep is what turns a peak into a MemoryMax.
m3_sweep() {
  local profile=$1 cmd factor ceiling baseline=0 best="" best_wall=0 floor recommended reason
  cmd=$(build_cmd_for "$profile")
  [ -n "$cmd" ] || return 0
  [ "$M3_PEAK" -gt 0 ] || {
    warn "no peak to sweep around"
    return 0
  }
  section "sweep around $((M3_PEAK / 1024 / 1024)) MiB"
  for factor in "${mem_sweep_factors[@]}"; do
    ceiling=$(awk -v p="$M3_PEAK" -v f="$factor" 'BEGIN { printf "%d", p * f }')
    FORGE_M_MEMORY_MAX=$ceiling
    # Cold, because these ceilings were derived from a cold peak. A warm build binds on a
    # workload an order of magnitude smaller and would pass every ceiling trivially.
    if [ -n "${clean_cmd:-}" ]; then
      workload_shell "$M1_WARM" "$clean_cmd" || true
    else
      run rm -rf "${M1_WARM:?}/${build_dir:?}"
    fi
    measure_run "sweep-$profile-$factor" "$M1_WARM" "$cmd"
    measure_record "profile=$profile" "sweep_factor=$factor" "status=measured"
    m3_track_peak
    [ "$FORGE_M_DRY_RUN" = 1 ] && continue
    if [ "$MR_STATUS" -eq 0 ] && [ "$MR_OOM_KILLED" = false ]; then
      [ "$baseline" -eq 0 ] && baseline=$MR_WALL_NS_BUILD
      if awk -v w="$MR_WALL_NS_BUILD" -v b="$baseline" -v i="$m3_sweep_max_inflation" \
        'BEGIN { exit !(b > 0 && w <= b * i) }'; then
        best=$ceiling
        best_wall=$MR_WALL_NS_BUILD
      fi
    fi
  done

  [ "$FORGE_M_DRY_RUN" = 1 ] && return 0

  # The floor: whatever the sweep concludes, never recommend a slice smaller than a build
  # already seen to need. A sweep that binds correctly does not reach it.
  floor=$(awk -v p="$M3_PEAK" -v m="$m3_safety_margin" 'BEGIN { printf "%d", p * m }')
  if [ -n "$best" ]; then
    recommended=$(awk -v c="$best" -v m="$m3_safety_margin" 'BEGIN { printf "%d", c * m }')
    reason="smallest ceiling that finished within ${m3_sweep_max_inflation}x, plus a ${m3_safety_margin}x margin"
    if [ "$recommended" -lt "$floor" ]; then
      recommended=$floor
      reason="the observed peak of $((M3_PEAK / 1024 / 1024)) MiB plus a ${m3_safety_margin}x margin; the sweep concluded lower and was floored"
    fi
  else
    recommended=$floor
    reason="no swept ceiling both finished and stayed within ${m3_sweep_max_inflation}x, so the observed peak plus a ${m3_safety_margin}x margin is the floor"
  fi
  record "measurement=m3" "label=recommendation" "memory_max=$recommended" \
    "wall_ns_build=$best_wall" "status=measured" "reason=$reason"
  info "recommended MemoryMax: $((recommended / 1024 / 1024)) MiB per slice"
}

cmd_m3() {
  local profile
  while [ $# -gt 0 ]; do
    case $1 in
      --sweep)
        M3_SWEEP=1
        shift
        ;;
      --profile)
        build_profiles=("$2")
        shift 2
        ;;
      *) die "m3: unknown argument $1" ;;
    esac
  done

  workload_validate workload_repo workload_commit build_dir build_cmd_debug
  fail_report

  m1_paths
  run_dir_init m3
  m1_ensure_warm
  measure_env_baseline "$M1_WARM"

  for profile in "${build_profiles[@]}"; do
    m3_measure_profile "$profile"
  done
  m3_aggregate_prior

  if [ "$M3_SWEEP" = 1 ]; then
    m3_sweep "${build_profiles[-1]}"
  else
    info "no --sweep: the ceiling per slice is a judgement until it is run"
  fi

  section "results"
  cmd_report --run "$FORGE_M_RUN_DIR"
}
