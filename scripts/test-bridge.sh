#!/usr/bin/env bash
# Runs the photo_bridge.py unit tests, the tests of the fake bridge the Swift tests use, and the
# checks of the icloudpd launcher (run_icloudpd.py), with the bundled icloudpd runtime's interpreter.
# The tests use a fake iCloud service, so they need no account and no network.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$REPO_ROOT/Vendor/icloudpd-runtime/python/bin/python3.13"
if [ ! -x "$PYTHON" ]; then
    echo "error: $PYTHON is missing; run scripts/build-icloudpd.sh" >&2
    exit 1
fi
"$PYTHON" -I -B "$REPO_ROOT/UncloudTests/Bridge/test_bridge.py" "$REPO_ROOT/Uncloud/Helper/photo_bridge.py"
"$PYTHON" -I -B "$REPO_ROOT/UncloudTests/Bridge/test_fake_bridge.py"
"$PYTHON" -I -B "$REPO_ROOT/UncloudTests/Bridge/test_launcher.py" "$REPO_ROOT/Vendor/icloudpd-runtime/run_icloudpd.py"
