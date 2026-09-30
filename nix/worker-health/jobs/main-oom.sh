#!/bin/sh
# The main process itself allocates past the ceiling: the unit ends because its main process
# is gone, and with `OOMPolicy=continue` its result is `signal`, never `oom-kill`.
exec python3 -c 'x = b"x" * (1 << 30)'
