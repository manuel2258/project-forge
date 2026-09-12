#!/usr/bin/env bash
# Runs inside the transient unit, as the last argument of `systemd-run -- nix develop
# .#<env> --command bash measure/lib/in_unit.sh <command>`. It times the build, reads the
# unit's own cgroup while the cgroup is still alive, and exits with the build's status so
# systemd's Result is meaningful. See docs/design/measurement-harness.md.
#
# Not `set -e`: a failing build is a data point and its stats still have to be written.
set -uo pipefail

cmd=${1:?usage: in_unit.sh <command>}
log=${FORGE_M_LOG:-/dev/null}
stats=${FORGE_M_STATS:-}

now_ns() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    echo "${EPOCHREALTIME/./}000"
  else
    date -u +%s%N
  fi
}

# /usr/bin/time reports the largest single process rather than the sum, so it is only used
# where there is no cgroup to read and the record says which reading it is.
rss_file=""
t0=$(now_ns)
if [ -x /usr/bin/time ] && [ ! -r "/sys/fs/cgroup$(sed -n 's|^0::||p' /proc/self/cgroup 2> /dev/null)/memory.peak" ]; then
  rss_file=$(mktemp)
  /usr/bin/time -v -o "$rss_file" bash -o pipefail -c "$cmd" > "$log" 2>&1
  status=$?
else
  bash -o pipefail -c "$cmd" > "$log" 2>&1
  status=$?
fi
t1=$(now_ns)

# The cgroup is resolved from the process's own line, so this works for a system unit, a
# user unit and (degrading to nothing) outside a unit entirely.
cgroup=""
rel=$(sed -n 's|^0::||p' /proc/self/cgroup 2> /dev/null)
[ -n "$rel" ] && [ -d "/sys/fs/cgroup$rel" ] && cgroup=/sys/fs/cgroup$rel

cg_read() {
  local file=$cgroup/$1
  if [ -n "$cgroup" ] && [ -r "$file" ]; then
    cat "$file"
  fi
}

mem_peak=$(cg_read memory.peak)
mem_swap_peak=$(cg_read memory.swap.peak)
pids_peak=$(cg_read pids.peak)
cpu_usec=$(cg_read cpu.stat | awk '/^usage_usec/ {print $2}')
oom_kills=$(cg_read memory.events | awk '/^oom_kill / {print $2}')
io_read=$(cg_read io.stat | grep -o 'rbytes=[0-9]*' | cut -d= -f2 | awk '{s += $1} END {print s + 0}')
io_write=$(cg_read io.stat | grep -o 'wbytes=[0-9]*' | cut -d= -f2 | awk '{s += $1} END {print s + 0}')

if [ -n "$mem_peak" ]; then
  source=cgroup
elif [ -n "$rss_file" ] && [ -r "$rss_file" ]; then
  mem_peak=$(awk '/Maximum resident set size/ {print $NF * 1024}' "$rss_file")
  source=time-v
  rm -f "$rss_file"
else
  source=none
fi

if [ -n "$stats" ]; then
  {
    echo "wall_ns_build=$((t1 - t0))"
    echo "exit_status=$status"
    echo "mem_peak_bytes=${mem_peak:-0}"
    echo "mem_peak_source=$source"
    echo "mem_swap_peak_bytes=${mem_swap_peak:-0}"
    echo "pids_peak=${pids_peak:-0}"
    echo "cpu_usec=${cpu_usec:-0}"
    echo "oom_kills=${oom_kills:-0}"
    echo "io_read_bytes=${io_read:-0}"
    echo "io_write_bytes=${io_write:-0}"
  } > "$stats"
fi

exit "$status"
