# shellcheck shell=bash
# The self-test: all three measurements against a fake workload, with the two privileged
# layers substituted, so the harness is verifiable on a machine that cannot run a
# measurement. Every record it writes is stamped dry_run, and the report refuses the
# docs-ready form. See docs/design/measurement-harness.md.
#
# Workload keys come from the config that common.sh sources; FORGE_M_FAKE and the REPORT_*
# variables are read by the libraries this drives.
# shellcheck disable=SC2154,SC2034

SELFTEST_FAILURES=0

selftest_origin() {
  echo "$FORGE_M_SCRATCH/selftest/origin"
}

# A repository whose build writes files and allocates a few hundred megabytes, with four
# branches to check out. No compiler, no Nix, no systemd.
selftest_fixture() {
  local origin branch
  origin=$(selftest_origin)
  rm -rf "$FORGE_M_SCRATCH/selftest"
  mkdir -p "$origin/src"

  cat > "$origin/build.sh" << 'BUILD'
#!/usr/bin/env bash
# A stand-in for a real build: the project's own sources always recompile, dependencies only
# when their outputs are missing, and the whole thing wants a measurable amount of memory.
set -euo pipefail
mkdir -p build/own build/dep
for source in src/*.c; do
  cp "$source" "build/own/$(basename "$source" .c).o"
done
for unit in $(seq 1 20); do
  [ -f "build/dep/lib-$unit.o" ] || head -c 4096 /dev/zero > "build/dep/lib-$unit.o"
done
awk 'BEGIN { for (i = 0; i < 400000; i++) a[i] = i "x" }'
BUILD

  cat > "$origin/link.sh" << 'LINK'
#!/usr/bin/env bash
# The stand-in for the heaviest step: one output, more memory than the compile.
set -euo pipefail
mkdir -p build
cat build/own/*.o build/dep/*.o > build/app
awk 'BEGIN { for (i = 0; i < 900000; i++) a[i] = i "y" }'
LINK

  chmod +x "$origin/build.sh" "$origin/link.sh"
  for unit in 1 2 3; do
    echo "int unit$unit(void) { return $unit; }" > "$origin/src/unit$unit.c"
  done

  git -C "$origin" init --quiet --initial-branch=main
  git -C "$origin" -c user.email=selftest@forge -c user.name=selftest add -A
  git -C "$origin" -c user.email=selftest@forge -c user.name=selftest \
    commit --quiet -m "selftest fixture"
  for branch in one two three four; do
    git -C "$origin" checkout --quiet -b "$branch" main
    echo "// $branch" >> "$origin/src/unit1.c"
    echo "int ${branch}_only(void) { return 1; }" > "$origin/src/$branch.c"
    git -C "$origin" -c user.email=selftest@forge -c user.name=selftest add -A
    git -C "$origin" -c user.email=selftest@forge -c user.name=selftest \
      commit --quiet -m "branch $branch"
  done
  git -C "$origin" checkout --quiet main
}

selftest_expect() {
  local what=$1 got=$2 want=$3
  if [ "$got" = "$want" ]; then
    info "ok: $what = $got"
  else
    echo "    FAILED: $what = $got, expected $want" >&2
    SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
  fi
}

selftest_expect_min() {
  local what=$1 got=$2 least=$3
  if [ "${got:-0}" -ge "$least" ]; then
    info "ok: $what = $got"
  else
    echo "    FAILED: $what = $got, expected at least $least" >&2
    SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
  fi
}

selftest_count() {
  jq -s "$1 | length" "$FORGE_M_RUN_DIR/run.jsonl"
}

cmd_selftest() {
  [ $# -eq 0 ] || die "selftest: unknown argument $1"
  local needed
  for needed in jq git rsync awk; do
    have "$needed" || die "selftest needs $needed (nix develop .#measure)"
  done

  FORGE_M_FAKE=1
  section "fixture"
  selftest_fixture
  workload_load selftest
  info "origin: $(selftest_origin)"

  section "m1"
  cmd_m1
  selftest_expect "m1 verdicts" "$(selftest_count 'map(select(.label | endswith("-verdict")))')" 3
  selftest_expect "variant (a) not applicable" \
    "$(jq -rs 'map(select(.label == "a-verdict")) | .[0].reason' "$FORGE_M_RUN_DIR/run.jsonl")" \
    "workload_has_no_dep_closure_builder"
  selftest_expect_min "m1 records" "$(selftest_count '.')" 10
  selftest_expect "every record is stamped dry_run" \
    "$(selftest_count 'map(select(.dry_run != true))')" 0

  section "m2"
  cmd_m2
  selftest_expect "m2 rounds" "$(selftest_count 'map(select(.label | startswith("level-")))')" 3
  # Level 1 runs every branch serially now, so ten builds, not seven.
  selftest_expect "m2 builds" "$(selftest_count 'map(select(.concurrency != null and .branch != null))')" 10
  selftest_expect "per-branch contention readings" \
    "$(selftest_count 'map(select(.label | startswith("contention-")))')" 4
  selftest_expect "the verdict compares branches with themselves" \
    "$(jq -rs 'map(select(.label == "scaling-verdict")) | .[0] | has("throughput_efficiency")' "$FORGE_M_RUN_DIR/run.jsonl")" \
    "true"
  selftest_expect "exclusive readings" \
    "$(selftest_count 'map(select(.label | startswith("exclusive-l4")))')" 4

  section "m3"
  cmd_m3 --sweep
  selftest_expect_min "m3 measured builds" \
    "$(selftest_count 'map(select(.measurement == "m3" and .status == "measured"))')" 4
  # The floor is the guard against a sweep that binds on the wrong workload ever
  # recommending a slice smaller than a build already seen to need. This host has no cgroup
  # accounting, so the peaks are zero and the sweep above had nothing to work around: the
  # floor is exercised directly, with a peak the fake builds will never reach.
  M3_PEAK=$((512 * 1024 * 1024))
  m3_sweep debug
  selftest_expect "the recommendation is never below the peak it swept around" \
    "$(jq -rs --argjson peak "$M3_PEAK" '
        (map(select(.measurement == "m3" and .label == "recommendation")) | last) as $record
        | if $record == null then "no-recommendation"
          elif ($record.memory_max // 0) >= $peak then "true"
          else "false" end
      ' "$FORGE_M_RUN_DIR/run.jsonl")" \
    "true"

  section "report"
  local rendered section_heading
  rendered=$(cmd_report --run "$FORGE_M_RUN_DIR")
  case $rendered in
    *"DRY RUN"*) info "ok: the report refuses to pass the self-test off as evidence" ;;
    *)
      echo "    FAILED: no DRY RUN banner in the report" >&2
      SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
      ;;
  esac
  case $rendered in
    *"Paste the sections above"*)
      echo "    FAILED: the report offered the docs-ready form for a dry run" >&2
      SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
      ;;
    *) info "ok: no docs-ready form" ;;
  esac

  # The renderer against checked-in records, which is the only way to check issue #4's
  # wrap-up requirement without a real run.
  section "report fixtures"
  rendered=$(cmd_report --run "$FORGE_M_ROOT/measure/testdata/report/all-fail")
  case $rendered in
    *"maintained btrfs blob"*)
      info "ok: with no passing variant the report states the consequence"
      ;;
    *)
      echo "    FAILED: the all-fail fixture did not produce the btrfs-blob sentence" >&2
      SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
      ;;
  esac
  case $rendered in
    *"toolchain_has_no_compilation_cache"* | *"workload_has_no_dep_closure_builder"*)
      info "ok: a not_applicable variant says why in the table"
      ;;
    *)
      echo "    FAILED: no not_applicable reason rendered" >&2
      SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
      ;;
  esac

  rendered=$(cmd_report --run "$FORGE_M_ROOT/measure/testdata/report/one-pass")
  case $rendered in
    *"maintained btrfs blob"*)
      echo "    FAILED: the risk sentence appeared even though a variant passed" >&2
      SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
      ;;
    *) info "ok: one passing variant keeps the risk sentence out" ;;
  esac
  for section_heading in "M2 copy-on-write divergence" "M3 peak build memory" "Other records"; do
    case $rendered in
      *"$section_heading"*) info "ok: $section_heading rendered" ;;
      *)
        echo "    FAILED: no $section_heading section" >&2
        SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
        ;;
    esac
  done

  section "selftest"
  if [ "$SELFTEST_FAILURES" -eq 0 ]; then
    info "all checks passed"
  else
    die "$SELFTEST_FAILURES check(s) failed"
  fi
}
