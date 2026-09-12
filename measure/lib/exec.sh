# shellcheck shell=bash
# measure_exec and measure_run: the only place in the harness that knows how a command is
# executed. Today a transient systemd unit locally; M4 adds an ssh variant into the QEMU
# guest here and nowhere else. See docs/design/measurement-harness.md.

# The environment the unit gets, mirroring ForgeWorker.Job.Runner's @inherited list: a
# variable the worker forgets is then a variable the measurement also forgets.
FORGE_M_INHERITED=(
  PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE NIX_SSL_CERT_FILE NIX_PATH NIX_REMOTE
  NIX_CONFIG HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
)

# Results of the last measure_run. The caller merges them with its own fields and calls
# measure_record, so one build produces exactly one record.
MR_LABEL=""
MR_UNIT=""
MR_STATUS=0
MR_WALL_NS_TOTAL=0
MR_WALL_NS_BUILD=0
MR_MEM_PEAK=0
MR_MEM_PEAK_SOURCE=none
MR_MEM_SWAP_PEAK=0
MR_MEMORY_MAX=infinity
MR_CPU_USEC=0
MR_PIDS_PEAK=0
MR_IO_READ=0
MR_IO_WRITE=0
MR_OOM_KILLED=false
MR_LOG=""
MR_STATS_FILE=""

# measure_exec <unit> <workdir> <memory-max> <cpu-weight> <setenv-array-name> <command>
#
# Runs the command and returns its status. Nothing else in the harness calls systemd-run,
# and nothing else may assume the working directory is local.
measure_exec() {
  local unit=$1 workdir=$2 mem_max=$3 cpu_weight=$4 setenv_name=$5 cmd=$6
  local -a extra_setenv=()
  local key value
  eval "extra_setenv=(\"\${${setenv_name}[@]:-}\")"

  if [ "$FORGE_M_FAKE" = 1 ]; then
    # Self-test: no systemd. The substitution is stamped into every record.
    local -a assignments=()
    for value in "${extra_setenv[@]}"; do
      [ -n "$value" ] && assignments+=("$value")
    done
    (
      cd "$workdir" || exit 1
      for value in "${assignments[@]}"; do export "${value?}"; done
      export FORGE_M_STATS="$MR_STATS_FILE" FORGE_M_LOG="$MR_LOG"
      bash "$FORGE_M_ROOT/measure/lib/in_unit.sh" "$cmd"
    )
    return $?
  fi

  local -a argv=()
  if [ "$(slice_mode)" = user ]; then
    argv=(systemd-run --user)
  else
    argv=(sudo systemd-run --uid="$(id -u)" --gid="$(id -g)")
  fi
  # No --collect: it unloads the unit the moment it exits, taking MemoryPeak and the
  # journal's record of an OOM kill with it. The caller resets the unit itself.
  argv+=(
    --unit="$unit"
    --service-type=exec
    --wait
    --pipe
    --working-directory="$workdir"
    --property=MemoryAccounting=yes
    --property=MemoryMax="$mem_max"
    --property=MemorySwapMax=0
    --property=CPUAccounting=yes
    --property=IOAccounting=yes
    --property=TasksAccounting=yes
    --property=CPUWeight="$cpu_weight"
    --property=RuntimeMaxSec="${build_timeout_seconds:-7200}"
  )
  for key in "${FORGE_M_INHERITED[@]}"; do
    value=${!key:-}
    [ -n "$value" ] && argv+=(--setenv="$key=$value")
  done
  argv+=(--setenv="HOME=$HOME")
  for value in "${extra_setenv[@]}"; do
    [ -n "$value" ] && argv+=(--setenv="$value")
  done
  argv+=(--setenv="FORGE_M_STATS=$MR_STATS_FILE" --setenv="FORGE_M_LOG=$MR_LOG")

  if [ -n "${workload_env:-}" ]; then
    argv+=(-- nix develop ".#${workload_env}" --command bash "$FORGE_M_ROOT/measure/lib/in_unit.sh" "$cmd")
  else
    argv+=(-- bash "$FORGE_M_ROOT/measure/lib/in_unit.sh" "$cmd")
  fi

  if [ "$FORGE_M_DRY_RUN" = 1 ]; then
    printf '    would run:'
    printf ' %q' "${argv[@]}"
    printf '\n'
    return 0
  fi

  "${argv[@]}"
}

# workload_shell <workdir> <command>
#
# The workload's untimed helpers — clean, cache population, the heaviest step's preparation —
# in the same environment as the measured builds, just without a unit around them. Outside
# it they pick up whatever toolchain is on the operator's PATH, and a second compiler
# fingerprints the build directory differently: the prepare step then rebuilds the world and
# leaves the timed step to rebuild it again, which is not the heaviest step at all.
workload_shell() {
  local workdir=$1 cmd=$2
  if [ -n "${workload_env:-}" ]; then
    run bash -o pipefail -c \
      "cd ${workdir@Q} && nix develop '.#${workload_env}' --command bash -o pipefail -c ${cmd@Q}"
  else
    run bash -o pipefail -c "cd ${workdir@Q} && ${cmd}"
  fi
}

# measure_run <label> <workdir> <command> [KEY=VALUE ...]
#
# One measured build. Sets the MR_* variables; the caller adds its own fields and calls
# measure_record, so one build is one record.
measure_run() {
  local label=$1 workdir=$2 cmd=$3
  shift 3
  # Passed to measure_exec by name, which is why shellcheck cannot see the use.
  # shellcheck disable=SC2034
  local -a setenv=("$@")
  local mem_max=${FORGE_M_MEMORY_MAX:-${mem_probe_max:-infinity}}
  local cpu_weight=${FORGE_M_CPU_WEIGHT:-100}
  local t0 t1 status=0

  MR_LABEL=$label
  MR_UNIT="forge-measure-${FORGE_M_RUN_ID}-${label}"
  MR_MEMORY_MAX=$mem_max
  MR_LOG=$FORGE_M_RUN_DIR/logs/$label.build.log
  MR_STATS_FILE=$FORGE_M_RUN_DIR/stats/$label.env
  MR_WALL_NS_BUILD=0
  MR_MEM_PEAK=0
  MR_MEM_PEAK_SOURCE=none
  MR_MEM_SWAP_PEAK=0
  MR_CPU_USEC=0
  MR_PIDS_PEAK=0
  MR_IO_READ=0
  MR_IO_WRITE=0
  MR_OOM_KILLED=false

  info "build $label: $cmd"
  [ "$FORGE_M_DRY_RUN" = 1 ] || rm -f "$MR_STATS_FILE"
  t0=$(now_ns)
  measure_exec "$MR_UNIT" "$workdir" "$mem_max" "$cpu_weight" setenv "$cmd" || status=$?
  t1=$(now_ns)
  MR_WALL_NS_TOTAL=$((t1 - t0))
  MR_STATUS=$status

  [ "$FORGE_M_DRY_RUN" = 1 ] && return 0

  measure_collect_stats
  measure_reset_unit
  if [ "$status" -ne 0 ]; then
    warn "build $label exited $status (log: $MR_LOG)"
  fi
  return 0
}

# The in-unit reading is authoritative; everything below it is a cross-check or a fallback,
# and mem_peak_source says which one produced the number in the table.
measure_collect_stats() {
  local key value shown
  if [ -r "$MR_STATS_FILE" ]; then
    while IFS='=' read -r key value; do
      case $key in
        wall_ns_build) MR_WALL_NS_BUILD=$value ;;
        mem_peak_bytes) MR_MEM_PEAK=$value ;;
        mem_peak_source) MR_MEM_PEAK_SOURCE=$value ;;
        mem_swap_peak_bytes) MR_MEM_SWAP_PEAK=$value ;;
        cpu_usec) MR_CPU_USEC=$value ;;
        pids_peak) MR_PIDS_PEAK=$value ;;
        io_read_bytes) MR_IO_READ=$value ;;
        io_write_bytes) MR_IO_WRITE=$value ;;
        oom_kills) [ "${value:-0}" -gt 0 ] && MR_OOM_KILLED=true ;;
        *) ;;
      esac
    done < "$MR_STATS_FILE"
  fi

  if [ "$FORGE_M_FAKE" = 1 ]; then
    [ "$MR_MEM_PEAK_SOURCE" = none ] && MR_MEM_PEAK_SOURCE=fake
    return 0
  fi

  if [ "${MR_MEM_PEAK:-0}" -eq 0 ] 2> /dev/null && have systemctl; then
    shown=$(measure_systemctl show --property=MemoryPeak --value "$MR_UNIT" 2> /dev/null || true)
    if [ -n "$shown" ] && [ "$shown" != '[not set]' ]; then
      MR_MEM_PEAK=$shown
      MR_MEM_PEAK_SOURCE=systemctl
    fi
  fi

  if [ "$MR_OOM_KILLED" = false ] && have journalctl; then
    if journalctl -u "$MR_UNIT" --no-pager -q 2> /dev/null | grep -qi 'out of memory\|oom-kill'; then
      MR_OOM_KILLED=true
    fi
  fi
}

measure_systemctl() {
  if [ "$(slice_mode)" = user ]; then
    systemctl --user "$@"
  else
    systemctl "$@"
  fi
}

measure_reset_unit() {
  have systemctl || return 0
  measure_systemctl reset-failed "$MR_UNIT" > /dev/null 2>&1 || true
}

# measure_record [KEY=VALUE ...] -- the MR_* fields plus whatever the caller measured.
measure_record() {
  record \
    "measurement=$FORGE_M_MEASUREMENT" \
    "label=$MR_LABEL" \
    "unit=$MR_UNIT" \
    "wall_ns_total=$MR_WALL_NS_TOTAL" \
    "wall_ns_build=$MR_WALL_NS_BUILD" \
    "exit_status=$MR_STATUS" \
    "mem_peak_bytes=$MR_MEM_PEAK" \
    "mem_peak_source=$MR_MEM_PEAK_SOURCE" \
    "mem_swap_peak_bytes=$MR_MEM_SWAP_PEAK" \
    "memory_max=$MR_MEMORY_MAX" \
    "cpu_usec=$MR_CPU_USEC" \
    "pids_peak=$MR_PIDS_PEAK" \
    "io_read_bytes=$MR_IO_READ" \
    "io_write_bytes=$MR_IO_WRITE" \
    "oom_killed=$MR_OOM_KILLED" \
    "$@"
}

# The environment-entry baseline: `nix develop --command true` under a unit, so the
# evaluator's own wall time and memory sit beside the build numbers. Not subtracted from
# them: the slice has to accommodate the evaluator too.
measure_env_baseline() {
  local workdir=$1
  measure_run env-baseline "$workdir" 'true'
  measure_record "status=ok" "notes=environment entry only"
}
