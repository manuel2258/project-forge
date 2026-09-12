# shellcheck shell=bash
# Shared helpers for bin/measure: logging, workload configuration, run directories, phases
# and result records. See docs/design/measurement-harness.md.

FORGE_M_SCHEMA_VERSION=1

# Set by bin/measure before anything else is sourced.
: "${FORGE_M_ROOT:?bin/measure must export FORGE_M_ROOT}"
: "${FORGE_M_SCRATCH:=$FORGE_M_ROOT/.measure}"

# 1 prints the plan and executes nothing; 1 in FORGE_M_FAKE substitutes the two privileged
# layers so the self-test can run without systemd or btrfs.
: "${FORGE_M_DRY_RUN:=0}"
: "${FORGE_M_FAKE:=0}"
# 1 runs builds under the user manager instead of the system manager. Only after preflight
# has proved the memory controller is delegated: without it MemoryMax= is silently ignored.
: "${FORGE_M_USER_UNITS:=0}"
# An operator-supplied btrfs mountpoint, used in place of the loopback image.
: "${FORGE_M_BTRFS_MOUNT:=}"
# 1 accepts a volume left mounted by an earlier run instead of refusing to start.
: "${FORGE_M_REUSE:=0}"

# --- output ------------------------------------------------------------------

section() {
  echo "==> $*"
}

info() {
  echo "    $*"
}

warn() {
  echo "    warning: $*" >&2
}

die() {
  echo "measure: $*" >&2
  exit 1
}

# Every command that touches the machine goes through here, so --dry-run is honoured in one
# place and the plan it prints is the commands that would have run.
run() {
  if [ "$FORGE_M_DRY_RUN" = 1 ]; then
    printf '    would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

have() {
  command -v "$1" > /dev/null 2>&1
}

now_ns() {
  # $EPOCHREALTIME is seconds.microseconds; date -u +%s%N is the fallback for bash < 5.
  if [ -n "${EPOCHREALTIME:-}" ]; then
    echo "${EPOCHREALTIME/./}000"
  else
    date -u +%s%N
  fi
}

utc_stamp() {
  date -u +%Y-%m-%dT%H-%M-%SZ
}

# --- collected failures ------------------------------------------------------
#
# A two-hour run that stops at minute ninety because rsync is missing is the failure mode
# worth engineering against, so checks accumulate and are reported once.

FORGE_M_FAILURES=()

fail_add() {
  FORGE_M_FAILURES+=("$1")
}

fail_report() {
  [ "${#FORGE_M_FAILURES[@]}" -eq 0 ] && return 0
  echo "measure: ${#FORGE_M_FAILURES[@]} precondition(s) not met:" >&2
  local failure
  for failure in "${FORGE_M_FAILURES[@]}"; do
    echo "  - $failure" >&2
  done
  exit 1
}

# --- JSON --------------------------------------------------------------------

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

json_value() {
  local v=$1
  case $v in
    true | false | null) printf '%s' "$v" ;;
    '' | *[!0-9.eE+-]* | *[!0-9]*[!0-9.]*) printf '"%s"' "$(json_escape "$v")" ;;
    *)
      # Bare number only when it really is one; anything else stays a string.
      if [[ $v =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$v"
      else
        printf '"%s"' "$(json_escape "$v")"
      fi
      ;;
  esac
}

# record key=value ... -- one line appended to run.jsonl. Appending as the run proceeds is
# what makes a crash at minute ninety keep everything up to minute eighty-nine.
record() {
  local out=$FORGE_M_RUN_DIR/run.jsonl
  local line first=1 pair key value
  line=$(printf '{"schema_version":%s' "$FORGE_M_SCHEMA_VERSION")
  line+=$(printf ',"run_id":"%s","workload":"%s","dry_run":%s' \
    "$FORGE_M_RUN_ID" "${workload_name:-unknown}" \
    "$([ "$FORGE_M_FAKE" = 1 ] || [ "$FORGE_M_DRY_RUN" = 1 ] && echo true || echo false)")
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    line+=$(printf ',"%s":%s' "$key" "$(json_value "$value")")
    first=0
  done
  : "$first"
  line+='}'
  if [ "$FORGE_M_DRY_RUN" = 1 ]; then
    info "would record: $line"
    return 0
  fi
  printf '%s\n' "$line" >> "$out"
}

# --- phases ------------------------------------------------------------------
#
# The timing primitive. measure_run is built on it, and M4's per-phase timestamps are
# ordinary phases, which is what keeps the results table single.

declare -A FORGE_M_PHASE_START=()

phase_begin() {
  FORGE_M_PHASE_START[$1]=$(now_ns)
}

phase_end() {
  local name=$1 status=${2:-ok} start end
  start=${FORGE_M_PHASE_START[$name]:-}
  [ -n "$start" ] || die "phase_end $name without phase_begin"
  end=$(now_ns)
  unset "FORGE_M_PHASE_START[$name]"
  record "measurement=$FORGE_M_MEASUREMENT" "phase=$name" "label=$name" \
    "wall_ns_total=$((end - start))" "status=$status"
}

# --- run directory -----------------------------------------------------------

run_dir_init() {
  local subcommand=$1
  FORGE_M_RUN_ID="$(utc_stamp)-$subcommand"
  FORGE_M_RUN_DIR=$FORGE_M_SCRATCH/results/${workload_name:-unknown}/$FORGE_M_RUN_ID
  FORGE_M_MEASUREMENT=$subcommand
  export FORGE_M_RUN_ID FORGE_M_RUN_DIR FORGE_M_MEASUREMENT
  [ "$FORGE_M_DRY_RUN" = 1 ] && return 0
  mkdir -p "$FORGE_M_RUN_DIR"/{logs,stats,census}
  # One symlink per subcommand as well as the shared one, because a run of m2 otherwise
  # hides the m1 run that `report` with no --run would want.
  ln -sfn "$FORGE_M_RUN_ID" "$(dirname "$FORGE_M_RUN_DIR")/latest"
  ln -sfn "$FORGE_M_RUN_ID" "$(dirname "$FORGE_M_RUN_DIR")/latest-$subcommand"
  env_json_write
  info "results: $FORGE_M_RUN_DIR"
}

env_json_write() {
  local kernel systemd btrfs cores memkb governor
  kernel=$(uname -sr)
  systemd=$(systemctl --version 2> /dev/null | head -1 || echo unknown)
  # First line only: btrfs --version prints a second line of build features, and a newline
  # inside the string breaks the bullet list the report renders from it. sed rather than
  # head, which would close the pipe early and turn pipefail into a spurious "absent".
  btrfs=$(btrfs --version 2> /dev/null | sed -n 1p || echo absent)
  cores=$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 0)
  memkb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2> /dev/null || echo 0)
  governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2> /dev/null || echo unknown)
  {
    printf '{\n'
    printf '  "kernel": %s,\n' "$(json_value "$kernel")"
    printf '  "systemd": %s,\n' "$(json_value "$systemd")"
    printf '  "btrfs_progs": %s,\n' "$(json_value "$btrfs")"
    printf '  "cores": %s,\n' "$(json_value "$cores")"
    printf '  "mem_total_kb": %s,\n' "$(json_value "$memkb")"
    printf '  "cpu_governor": %s,\n' "$(json_value "$governor")"
    printf '  "slice_mode": %s,\n' "$(json_value "$(slice_mode)")"
    printf '  "fake_layers": %s,\n' "$([ "$FORGE_M_FAKE" = 1 ] && echo true || echo false)"
    printf '  "workload": %s,\n' "$(json_value "${workload_name:-unknown}")"
    printf '  "workload_repo": %s,\n' "$(json_value "${workload_repo:-}")"
    printf '  "workload_commit": %s,\n' "$(json_value "${workload_commit:-}")"
    printf '  "forge_commit": %s,\n' "$(json_value "$(git -C "$FORGE_M_ROOT" rev-parse --short HEAD 2> /dev/null || echo unknown)")"
    printf '  "harness_schema": %s\n' "$FORGE_M_SCHEMA_VERSION"
    printf '}\n'
  } > "$FORGE_M_RUN_DIR/env.json"
}

slice_mode() {
  if [ "$FORGE_M_FAKE" = 1 ]; then
    echo direct
  elif [ "$FORGE_M_USER_UNITS" = 1 ]; then
    echo user
  else
    echo system
  fi
}

# --- workload configuration --------------------------------------------------

# These defaults are the workload contract; the measurements read them, not this file.
# shellcheck disable=SC2034
workload_defaults() {
  workload_flake_subdir=.
  workload_env=""
  build_profiles=(debug)
  build_cmd_release=""
  clean_cmd=""
  build_timeout_seconds=7200
  own_sources=()
  own_paths=()
  dep_paths=()
  parse_rebuilds=""
  dep_seed_attr=""
  dep_seed_subpath=.
  cache_env=()
  cache_populate_cmd=""
  cache_stats_cmd=""
  cache_reset_cmd=""
  m2_branches=()
  m2_volume_size=80G
  m2_scaling_min_efficiency=0.5
  mem_probe_max=infinity
  mem_sweep_factors=(1.5 1.25 1.0 0.75)
  m3_sweep_max_inflation=1.25
  m3_safety_margin=1.1
  repeats=1
  build_jobs_env=()
  m1_time_factor=2
  m1_file_slack=1.10
}

workload_list() {
  find "$FORGE_M_ROOT/measure/workloads" -maxdepth 1 -name '*.sh' -printf '%f\n' |
    sed 's|\.sh$||' | sort | tr '\n' ' '
}

workload_load() {
  local name=$1 path
  path=$FORGE_M_ROOT/measure/workloads/$name.sh
  [ -f "$path" ] || die "no workload '$name' ($path). Available: $(workload_list)"
  workload_defaults
  FORGE_M_CACHE_DIR=$FORGE_M_SCRATCH/$name/cache
  FORGE_M_VOLUME=${FORGE_M_BTRFS_MOUNT:-$FORGE_M_SCRATCH/$name/vol}
  FORGE_M_WORKLOAD_DIR=$FORGE_M_SCRATCH/$name
  export FORGE_M_CACHE_DIR FORGE_M_VOLUME FORGE_M_SCRATCH FORGE_M_WORKLOAD_DIR
  # shellcheck source=/dev/null
  . "$path"
  workload_name=${workload_name:-$name}
}

# workload_validate key... -- the caller says what it needs, so M4 can require less.
workload_validate() {
  local key value
  for key in "$@"; do
    case $key in
      m2_branches)
        if [ "${#m2_branches[@]}" -lt 4 ]; then
          fail_add "workload $workload_name: m2_branches needs at least four 'name:sha' entries"
        fi
        ;;
      build_profiles | own_sources | own_paths)
        value="${key}[@]"
        if [ -z "${!value:-}" ]; then
          fail_add "workload $workload_name: $key is empty"
        fi
        ;;
      *)
        if [ -z "${!key:-}" ]; then
          fail_add "workload $workload_name: $key is not set"
        fi
        ;;
    esac
  done
}

# The build command for a profile, or empty when the workload has none.
build_cmd_for() {
  local profile=$1 var="build_cmd_$1"
  : "$profile"
  printf '%s' "${!var:-}"
}
