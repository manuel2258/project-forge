#!/usr/bin/env bash
# The guest half of nix/worker-health.nix: one subcommand per item, run as root on the worker
# image through the ssh door. Each prints what it saw, verbatim where the text is the point,
# and exits non-zero with a FAIL line when what it saw is not what the code and the design
# notes rely on. Units are started with the worker's own code (slice.exs), never with flags
# written here.
#
#     guest.sh identity | oom-child | oom-main | readings | secrets | forgery | wedge | health | reboot
set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
root=/var/lib/forge
export RELEASE_COOKIE=forge-no-distribution RELEASE_DISTRIBUTION=none RELEASE_TMP=/tmp

# Set by run_job, from the worker's own paths for the job. Every job id here differs in its first
# sixteen hex digits, because those are all the unit's and the user's names keep of it.
worker_dir="" stderr="" worktree="" unit="" status=0 wall_ms=0 probe_ms=0

fail() {
  echo "FAIL: $*"
  exit 1
}

# fw ACTION ID [MEM] — ForgeWorker.Slice.Systemd, through the release in the image.
fw() {
  FJ_ACTION=$1 FJ_ID=$2 FJ_MEM=${3:-536870912} FJ_FILE=${FJ_FILE:-} FJ_SECRET=${FJ_SECRET:-} \
    "$root/release/bin/forge_worker" eval "Code.eval_file(\"$here/slice.exs\")"
}

# run_job ID MEM JOB — the job's user and unit made by the worker's code, then run as the runner
# runs it: stdin from nowhere, stdout to a file, stderr to the job's stderr.log.
run_job() {
  local id=$1 mem=$2 job=$3 argv_file start
  local -a argv
  argv_file=$(mktemp)
  fw setup "$id" "$mem" > "$argv_file" || fail "the slice could not be set up: $(cat "$argv_file")"
  eval "$(fw paths "$id")"
  install -o "$(stat -c %U "$worktree")" -m 0755 "$here/jobs/$job" "$worktree/job.sh"
  mapfile -t argv < "$argv_file"
  start=$(date +%s%N)
  "${argv[@]}" > "$worker_dir/stdout.log" 2> "$stderr" < /dev/null
  status=$?
  wall_ms=$((($(date +%s%N) - start) / 1000000))
}

# probe — ForgeWorker.Slice.Systemd.probe/0, timed inside the release; fails unless it is :ok.
probe() {
  local answer
  answer=$(fw probe none)
  echo "probe/0: $answer"
  probe_ms=${answer%% *}
  [ "${answer#* }" = ":ok" ]
}

verbatim() {
  echo "--- $1"
  cat -v "$2"
  echo "---"
}

reading_has() {
  grep -qx "$1" "$worker_dir/at-exit.reading" || fail "the unit's last reading has no '$1'"
}

identity() {
  [ -s /etc/forge-worker.env ] || fail "there is no /etc/forge-worker.env"
  echo "boot $(cat /proc/sys/kernel/random/boot_id)"
  echo "env-sha256 $(sha256sum /etc/forge-worker.env | cut -d' ' -f1)"
  echo "systemd $(systemctl --version | head -1)"
  echo "kernel $(uname -r)"
  echo "cgroup $(stat -fc %T /sys/fs/cgroup)"
  grep -q '^FORGE_SSH_KEY=' /etc/forge-worker.env && fail "the ssh key line was left in the environment file"
  journalctl -b -u forge-worker-config -o cat | grep '^identity:' ||
    fail "forge-worker-config.service did not fetch an identity on this boot"
}

oom_child() {
  run_job a1a1a1a1-0000-4000-8000-000000000000 536870912 child-oom.sh
  echo "systemd-run exited $status after ${wall_ms}ms"
  verbatim stdout "$worker_dir/stdout.log"
  verbatim stderr "$stderr"
  verbatim at-exit.reading "$worker_dir/at-exit.reading"
  [ "$status" = 0 ] || fail "systemd-run exited $status; the main process should have lived"
  grep -qx 'child exit: 137' "$worker_dir/stdout.log" || fail "the child was not killed alone"
  grep -qx 'main still alive' "$worker_dir/stdout.log" || fail "the main process died with its child"
  grep -q '^Running as unit: forge-job-' "$stderr" || fail "no 'Running as unit:' line"
  [ "$(stat -c %U "$worker_dir/at-exit.reading")" = root ] || fail "the stop step did not run as root"
  reading_has 'events oom_kill 1'
  reading_has 'max 536870912'
  reading_has 'exit_code exited'
  reading_has 'exit_status 0'
  reading_has 'result success'
  fw ended a1a1a1a1-0000-4000-8000-000000000000 | tee "$worker_dir/ended"
  grep -q 'exit: %{code: "exited", status: "0", result: "success"}' "$worker_dir/ended" ||
    fail "ended/2 read the exit wrongly"
  grep -q 'oom_kills: 1' "$worker_dir/ended" || fail "ended/2 did not count the kill"
  grep -q 'last_line: ".*Killed.*python3' "$worker_dir/ended" ||
    fail "ended/2's last line is not the process's own"
}

oom_main() {
  run_job a2a2a2a2-0000-4000-8000-000000000000 536870912 main-oom.sh
  echo "systemd-run exited $status after ${wall_ms}ms"
  verbatim stderr "$stderr"
  verbatim at-exit.reading "$worker_dir/at-exit.reading"
  [ "$status" = 255 ] || fail "systemd-run exited $status for a killed main process, not 255"
  grep -q 'Finished with result: signal$' "$stderr" || fail "the summary's result is not 'signal'"
  reading_has 'exit_code killed'
  reading_has 'exit_status KILL'
  reading_has 'result signal'
  reading_has 'events oom_kill 1'
  fw ended a2a2a2a2-0000-4000-8000-000000000000 | tee "$worker_dir/ended"
  grep -q 'exit: %{code: "killed", status: "KILL", result: "signal"}' "$worker_dir/ended" ||
    fail "ended/2 read the exit wrongly"
}

readings() {
  local id=a3a3a3a3-0000-4000-8000-000000000000 cgroup file
  head -c 1G /dev/urandom > /var/tmp/forge-health-big
  chmod 0644 /var/tmp/forge-health-big
  # Out of the page cache, where root's writing left it charged to root's cgroup, so the job
  # has to read it in and pay for it.
  sync
  echo 3 > /proc/sys/vm/drop_caches

  run_job "$id" 536870912 pressure.sh &
  sleep 20
  eval "$(fw paths "$id")"
  cgroup=/sys/fs/cgroup/system.slice/$unit.service
  for file in memory.events memory.current memory.peak memory.max memory.pressure; do
    verbatim "$file" "$cgroup/$file"
  done
  fw memory "$id" | tee /tmp/forge-health-memory
  wait
  rm -f /var/tmp/forge-health-big

  grep -q 'ceiling: 536870912' /tmp/forge-health-memory || fail "memory/1 read no ceiling"
  grep -Eq 'max_events: [1-9]' /tmp/forge-health-memory || fail "memory/1 read no reclaim at the ceiling"
  grep -Eq 'pressure: ([1-9][0-9]*\.[0-9]+|0\.[0-9]*[1-9])' /tmp/forge-health-memory ||
    fail "memory/1 read no pressure, for a job stalled at its ceiling"
}

# A job given a secret holds it, and reads it from systemd's copy: the worker writes the file in
# its own directory, which the job's user cannot enter, hands the unit the file with
# `LoadCredential=`, and the loader inside the unit reads `$CREDENTIALS_DIRECTORY`
# (docs/design/secrets.md § Delivery). The first version on the image never got that far: systemd
# substituted the loader's `${CREDENTIALS_DIRECTORY-}` to nothing, the loader read the worker's own
# path instead, and every job given a secret died "Permission denied".
secrets() {
  local value="it's \${HOME} and \$1"
  FJ_SECRET=$value run_job c1c1c1c1-0000-4000-8000-000000000000 536870912 secret.sh
  echo "systemd-run exited $status after ${wall_ms}ms"
  verbatim stdout "$worker_dir/stdout.log"
  verbatim stderr "$stderr"
  rm -f "$worker_dir/secrets.env"
  [ "$status" = 0 ] || fail "systemd-run exited $status; the job could not load its secret"
  grep -qxF "secret: $value" "$worker_dir/stdout.log" ||
    fail "the job did not hold the secret as it was given"
  grep -qxF "credentials: /run/credentials/$unit.service" "$worker_dir/stdout.log" ||
    fail "the loader did not read the unit's credential"
}

# Recorded, not asserted, apart from PID 1 answering afterwards: whether a forgery should be believed
# is the operator's open question (docs/design/worker-tier.md § Open), and a check that failed on
# either answer would be deciding it.
forgery() {
  local n id believed=0 kept=0 slowest=0
  for n in 1 2 3 4 5; do
    id=f${n}f${n}f${n}f${n}-0000-4000-8000-000000000000
    run_job "$id" 536870912 forge.sh
    if [ -e "$worker_dir/at-exit.reading" ]; then kept=$((kept + 1)); fi
    [ "$n" = 1 ] && verbatim "stderr of the first" "$stderr"
    if fw ended "$id" | grep -q 'unreachable: "systemd-run could not reach PID 1'; then
      believed=$((believed + 1))
    fi
    probe > /dev/null || fail "PID 1 did not answer a probe after a forgery"
    [ "$probe_ms" -gt "$slowest" ] && slowest=$probe_ms
    rm -f /dev/shm/forge-health-fill-*
  done
  echo "forgeries believed by ended/2: $believed of 5"
  echo "stop steps that wrote a reading anyway: $kept of 5"
  echo "PID 1 answered the probe after every one, the slowest in ${slowest}ms"
}

# The run that wedges PID 1, in the background: it takes 25 seconds to give up.
wedge_run() {
  run_job b1b1b1b1-0000-4000-8000-000000000000 2 started.sh
  echo "systemd-run exited $status after ${wall_ms}ms"
  verbatim stderr "$stderr"
  fw ended b1b1b1b1-0000-4000-8000-000000000000
}

wedge() {
  local first=/root/wedge-first.out wedging
  # The worker's own lines, from before the wedge: a wedged machine's kernel log floods the
  # journal and rotates away what came before it.
  setsid sh -c 'journalctl -f -n0 -u forge-worker -o short-precise |
    grep --line-buffered -v "disconnected from the platform" > /root/forge-worker.log' \
    > /dev/null 2>&1 < /dev/null &
  sleep 1
  date +%s > /root/wedge.at
  setsid "$0" wedge-run > "$first" 2>&1 < /dev/null &
  wedging=$!
  sleep 10

  echo "PID 1: $(ps -o stat=,wchan= -p 1)"
  if probe; then fail "PID 1 answered a probe ${probe_ms}ms into the wedge"; fi
  echo "the probe failed after ${probe_ms}ms"
  [ "$probe_ms" -lt 16000 ] || fail "the probe took ${probe_ms}ms to fail, past timeout's -k 5 10"

  run_job b2b2b2b2-0000-4000-8000-000000000000 536870912 started.sh
  echo "a second systemd-run exited $status after ${wall_ms}ms"
  verbatim "its stderr" "$stderr"
  [ "$status" != 0 ] || fail "a second systemd-run succeeded on a wedged PID 1"
  FJ_FILE=$stderr fw bus_error b2b2b2b2-0000-4000-8000-000000000000 | tee /tmp/forge-health-bus
  grep -qxF "\"$(head -1 "$stderr")\"" /tmp/forge-health-bus ||
    fail "bus_error/1 does not know the line systemd-run printed"
  fw ended b2b2b2b2-0000-4000-8000-000000000000 | tee /tmp/forge-health-ended
  grep -q 'unreachable: "systemd-run could not reach PID 1: ' /tmp/forge-health-ended ||
    fail "ended/2 did not believe a genuine bus error"

  wait "$wedging"
  echo "--- the run that wedged it"
  cat "$first"
  # It ends as the job's own failure, not the machine's: the probe is what finds the machine
  # (docs/design/worker-tier.md § How a machine finds out, and § Open for whether it should).
  grep -q '^systemd-run exited [1-9]' "$first" || fail "the run that wedged PID 1 did not fail"
  grep -q 'unreachable: nil' "$first" || fail "ended/2 took the run that wedged PID 1 for the machine's failure"
}

health() {
  local deadline line took
  deadline=$(($(date +%s) + 240))
  until grep -q 'PID 1 did not answer twice in a row' /root/forge-worker.log; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      cat /root/forge-worker.log
      fail "the worker did not mark itself unhealthy within four minutes"
    }
    sleep 5
  done
  cat /root/forge-worker.log
  line=$(grep -m1 'PID 1 did not answer twice in a row' /root/forge-worker.log)
  took=$(($(date -d "$(echo "$line" | cut -d' ' -f1-3)" +%s) - $(cat /root/wedge.at)))
  echo "marked unhealthy ${took}s after the wedge"
  # Two probes a minute apart, each given up on after ten seconds, and the first up to a minute
  # after the wedge began: 140 seconds at the most, and a little slack for a loaded machine.
  [ "$took" -gt 0 ] && [ "$took" -le 150 ] || fail "the worker took ${took}s to mark itself unhealthy"
}

case ${1:-} in
  identity) identity ;;
  oom-child) oom_child ;;
  oom-main) oom_main ;;
  readings) readings ;;
  secrets) secrets ;;
  forgery) forgery ;;
  wedge) wedge ;;
  wedge-run) wedge_run ;;
  health) health ;;
  reboot) fw reboot none ;;
  *) fail "unknown item: ${1:-}" ;;
esac
