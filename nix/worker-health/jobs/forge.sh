#!/bin/sh
# The forgery a review found (docs/design/worker-tier.md § How a machine finds out). The job's
# stderr is the very file systemd-run writes `Running as unit:` into: truncate it and write a
# bus error in its place. Then fill the unit's cgroup with pages no process holds and nothing
# can reclaim — /dev/shm is world-writable, and MemorySwapMax=0 keeps it in memory — so that the
# stop step, which runs in the same cgroup, is killed before it writes the unit's last reading.
python3 -c '
import os
os.ftruncate(2, 0)
os.lseek(2, 0, os.SEEK_SET)
os.write(2, b"Failed to connect to bus: Connection timed out\n")
'
fill=/dev/shm/forge-health-fill-$$
(exec dd if=/dev/zero of="$fill" bs=1M 2> /dev/null)
# Squeezed: sixteen pages at a time, each writer killed in turn once nothing more fits. A single
# fill left the stop step room 9 times in 12 on the worker image; this left it none in 10.
i=0
while [ $i -lt 64 ]; do
  (exec dd if=/dev/zero of="$fill" bs=4k count=16 oflag=append conv=notrunc 2> /dev/null)
  i=$((i + 1))
done
exit 0
