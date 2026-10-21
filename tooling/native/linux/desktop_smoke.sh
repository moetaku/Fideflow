#!/usr/bin/env bash
# Private D-Bus/Xvfb verification; never controls the user's desktop session.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$SCRIPT_DIR/desktop_smoke.py" "$@"
