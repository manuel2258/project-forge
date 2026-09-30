#!/bin/sh
# A child that allocates past the unit's ceiling while the main process waits on it: under
# `OOMPolicy=continue` the child dies alone and the main process carries on.
python3 -c 'x = b"x" * (1 << 30)'
echo "child exit: $?"
echo "main still alive"
