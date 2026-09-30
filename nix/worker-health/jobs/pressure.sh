#!/bin/sh
# Holds most of a 512 MiB ceiling and streams a 1 GiB file through the rest for 30 seconds, so
# the page cache is reclaimed at the ceiling over and over: `max` climbs in memory.events and
# the job stalls on memory, which is what memory.pressure's `full` line counts.
exec python3 -c '
import time
hold = b"x" * (470 << 20)
end = time.time() + 30
while time.time() < end:
    with open("/var/tmp/forge-health-big", "rb") as f:
        while f.read(1 << 20):
            pass
'
