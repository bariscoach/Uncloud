#!/usr/bin/env bash
# Runs the photo_bridge.py unit tests with the bundled icloudpd runtime's interpreter.
# The tests use a fake iCloud service, so they need no account and no network.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$REPO_ROOT/Vendor/icloudpd-runtime/python/bin/python3.13"
if [ ! -x "$PYTHON" ]; then
    echo "error: $PYTHON is missing; run scripts/build-icloudpd.sh" >&2
    exit 1
fi
exec "$PYTHON" -I -B "$REPO_ROOT/UncloudTests/Bridge/test_bridge.py" "$REPO_ROOT/Uncloud/Helper/photo_bridge.py"
