#!/usr/bin/env bash
set -euo pipefail
cd "$FORGE_CHECKOUT"
exec bin/hetzner-image --check
