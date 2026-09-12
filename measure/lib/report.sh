# shellcheck shell=bash
# JSONL to markdown. Prints to standard output and never rewrites docs/measurements.md: that
# file is curated prose, and a script editing it would make the diff unreviewable. Sections
# are discovered from the data, so M4 appears in the same table when it exists.
# See docs/design/measurement-harness.md.
#
# Workload keys come from the config that common.sh sources, and the $names inside the jq
# programs are jq's own variables, which is why they must not be expanded by the shell.
# shellcheck disable=SC2154,SC2016

REPORT_JQ_PRELUDE='
  def ms: if . == null or . == 0 then "—" else ((. / 1000000) | floor | tostring) + " ms" end;
  def mib: if . == null or . == 0 then "—" else ((. / 1048576) | floor | tostring) + " MiB" end;
  def num: if . == null then "—" else (. | tostring) end;
'

report_jq() {
  jq -r -s "$REPORT_JQ_PRELUDE $1" "$REPORT_FILE"
}

report_header() {
  local env=$REPORT_DIR/env.json
  echo "### Run"
  echo
  if [ -f "$env" ]; then
    jq -r '
      "- Workload `\(.workload)` at `\(.workload_commit)`, repository `\(.workload_repo)`",
      "- Host: \(.kernel), \(.cores) cores, \((.mem_total_kb / 1048576) | floor) GiB, \(.systemd)",
      "- btrfs-progs: \(.btrfs_progs), cgroup slices: \(.slice_mode)",
      "- forge at `\(.forge_commit)`"
    ' "$env"
  else
    echo "- (no env.json)"
  fi
  echo
}

report_banner() {
  local fake
  fake=$(report_jq 'map(select(.dry_run == true)) | length')
  if [ "${fake:-0}" -gt 0 ]; then
    echo "> **DRY RUN.** These numbers come from the self-test's substituted layers: commands"
    echo "> did not run in a transient unit and the copy-on-write layer was plain directories."
    echo "> Not evidence. Do not paste into \`docs/measurements.md\`."
    echo
    REPORT_DOCS_READY=0
  fi
}

report_m1() {
  local rows verdicts passes
  rows=$(report_jq 'map(select(.measurement == "m1" and (.label | endswith("-verdict") | not))) | length')
  [ "${rows:-0}" -gt 0 ] || return 0

  echo "### M1 build cache acceptance"
  echo
  echo "| Build | Variant | Own rebuilt | Dep rebuilt | Files written | Wall | ×warm_own | Peak | Verdict |"
  echo "|---|---|---|---|---|---|---|---|---|"
  report_jq '
    (map(select(.measurement == "m1"))) as $all
    | ($all | map(select(.label | endswith("-verdict")))) as $verdict_records
    | ($verdict_records | map({key: .variant, value: .}) | from_entries) as $verdicts
    | ($all | map(select(.label | endswith("-verdict") | not))) as $builds
    | ($builds | map(select(.label == "warm_own")) | first) as $warm
    | def verdict_cell($variant):
        ($verdicts[$variant // ""] // null)
        | if . == null then "—"
          else .status + (if (.reason // "") == "" then "" else " (" + .reason + ")" end)
          end;
      ($builds
        | map(
            "| `\(.label)` | \(.variant // "—") | \(.own_rebuilds | num) | \(.dep_rebuilds | num) "
            + "| \((.files_created // 0) + (.files_modified // 0)) | \(.wall_ns_build | ms) "
            + "| \(if $warm and ($warm.wall_ns_build // 0) > 0 and (.wall_ns_build // 0) > 0
                   then (((.wall_ns_build / $warm.wall_ns_build) * 100 | floor) / 100 | tostring) + "×"
                   else "—" end) "
            + "| \(.mem_peak_bytes | mib) | \(verdict_cell(.variant)) |"
          ))
      # A variant with no build of its own — not applicable, or a failure before the build —
      # still has to appear, or the table would quietly lose it.
      + ($verdict_records
        | map(select(.variant as $v | ($builds | map(.variant) | index($v)) == null))
        | map("| — | \(.variant) | — | — | — | — | — | — | \(verdict_cell(.variant)) |"))
    | .[]
  '
  echo

  verdicts=$(report_jq 'map(select(.measurement == "m1" and (.label | endswith("-verdict")))) | length')
  passes=$(report_jq 'map(select(.measurement == "m1" and (.label | endswith("-verdict")) and .status == "pass")) | length')
  if [ "${verdicts:-0}" -gt 0 ] && [ "${passes:-0}" -eq 0 ]; then
    echo "No cache form transplants. The seed becomes a maintained btrfs blob kept in the"
    echo "platform's store (\`docs/poc-plan.md\` § Risks). The design survives; the storage model"
    echo "gets heavier."
    echo
  fi
}

report_m2() {
  local rows
  rows=$(report_jq 'map(select(.measurement == "m2")) | length')
  [ "${rows:-0}" -gt 0 ] || return 0

  echo "### M2 copy-on-write divergence"
  echo
  echo "| Concurrency | Builds | Makespan | Slowest build | Sum of builds |"
  echo "|---|---|---|---|---|"
  report_jq '
    map(select(.measurement == "m2" and (.label | startswith("level-"))))
    | map("| \(.concurrency)\(if .concurrency == 1 then " (serial)" else "" end) | \(.builds // "—") "
        + "| \(.makespan_ns | ms) | \(.max_wall_ns | ms) | \(.sum_wall_ns | ms) |")
    | .[]
  '
  echo
  # The same branch against itself, uncontended and four ways: what the makespan comparison
  # could never say, because its two sides did different work.
  if [ "$(report_jq 'map(select(.label | startswith("contention-"))) | length')" -gt 0 ]; then
    echo "| Branch | Uncontended | Four ways | Keeps |"
    echo "|---|---|---|---|"
    report_jq '
      map(select(.measurement == "m2" and (.label | startswith("contention-"))))
      | map("| \(.branch // "—") | \(.wall_ns_serial | ms) | \(.wall_ns_concurrent | ms) "
          + "| \(.scaling_efficiency // "—") |")
      | .[]
    '
    echo
  fi
  echo "| Snapshot | Branch | Exclusive |"
  echo "|---|---|---|"
  report_jq '
    map(select(.measurement == "m2" and (.label | startswith("exclusive-"))))
    | map("| `\(.label)` | \(.branch // "—") | \(.exclusive_bytes | mib) |")
    | .[]
  '
  echo
  report_jq '
    map(select(.measurement == "m2" and .label == "scaling-verdict"))
    | map("Scaling: **\(.status)** — \(.reason).")
    | .[]
  '
  echo
}

report_m3() {
  local rows
  rows=$(report_jq 'map(select(.measurement == "m3")) | length')
  [ "${rows:-0}" -gt 0 ] || return 0

  echo "### M3 peak build memory"
  echo
  echo "| Build | Profile | MemoryMax | Peak | Wall | OOM | Status |"
  echo "|---|---|---|---|---|---|---|"
  report_jq '
    map(select(.measurement == "m3" and .label != "recommendation"))
    | map("| `\(.label)` | \(.profile // "—") | \(.memory_max // "—") | \(.mem_peak_bytes | mib) "
        + "| \(.wall_ns_build | ms) | \(.oom_killed // false) | \(.status // "—") |")
    | .[]
  '
  echo
  report_jq '
    map(select(.measurement == "m3" and .label == "recommendation"))
    | map(if .status == "measured"
          then "Recommended `MemoryMax` per slice: **\((.memory_max / 1048576) | floor) MiB** — \(.reason)."
          else "No `MemoryMax` recommendation: \(.reason)." end)
    | .[]
  '
  echo
}

# Anything the three sections above do not claim, so a measurement added later (M4's phases)
# still reaches the table.
report_other() {
  local rows
  rows=$(report_jq 'map(select(.measurement != "m1" and .measurement != "m2" and .measurement != "m3")) | length')
  [ "${rows:-0}" -gt 0 ] || return 0
  echo "### Other records"
  echo
  echo "| Measurement | Label | Phase | Wall | Peak | Status |"
  echo "|---|---|---|---|---|---|"
  report_jq '
    map(select(.measurement != "m1" and .measurement != "m2" and .measurement != "m3"))
    | map("| \(.measurement) | `\(.label)` | \(.phase // "—") | \(.wall_ns_total | ms) "
        + "| \(.mem_peak_bytes | mib) | \(.status // "—") |")
    | .[]
  '
  echo
}

cmd_report() {
  local dir=""
  while [ $# -gt 0 ]; do
    case $1 in
      --run)
        dir=$2
        shift 2
        ;;
      --measurement)
        dir=$FORGE_M_SCRATCH/results/${workload_name:-unknown}/latest-$2
        shift 2
        ;;
      *) die "report: unknown argument $1" ;;
    esac
  done
  have jq || die "report needs jq (nix develop .#measure)"

  if [ -z "$dir" ]; then
    dir=$FORGE_M_SCRATCH/results/${workload_name:-unknown}/latest
  fi
  [ -d "$dir" ] || die "no run directory at $dir"
  REPORT_DIR=$(cd "$dir" && pwd)
  REPORT_FILE=$REPORT_DIR/run.jsonl
  REPORT_DOCS_READY=1
  [ -f "$REPORT_FILE" ] || die "no run.jsonl in $REPORT_DIR"

  report_banner
  report_header
  report_m1
  report_m2
  report_m3
  report_other
  if [ "$REPORT_DOCS_READY" = 1 ]; then
    echo "_Paste the sections above into \`docs/measurements.md\` § Results and tick the boxes._"
  fi
}
