#!/bin/bash
# This fork installs only locally compiled source. Piping downloaded shell
# code into bash is intentionally unsupported.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/install-personal.sh" ]; then
    echo "Clone ammarabdulaziz/MacSai, then run bash scripts/install-personal.sh."
    exit 1
fi
exec bash "$SCRIPT_DIR/install-personal.sh" "$@"
