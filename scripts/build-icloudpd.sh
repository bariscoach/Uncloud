#!/usr/bin/env bash
# Builds the bundled icloudpd runtime into Vendor/icloudpd-runtime/: a relocatable
# Python (python-build-standalone) with icloudpd installed from source, plus the
# run_icloudpd.py launcher. Every download is pinned and checked against its SHA-256.
# Usage: scripts/build-icloudpd.sh [--force]
set -euo pipefail

ICLOUDPD_VERSION=1.32.3
ICLOUDPD_COMMIT=9857dd88c4c7de49deb712b7d6b12193e23864b9
ICLOUDPD_SHA256=d340efa5bbd56d21aec9cd21f26233f3658836c1c7cdfc9393751e152ce9e300
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.13.15%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_SHA256=d3904bd6a072246e07aa0bdadee9a14e80521e42a943c0848059feb16a2816dc
RECIPE_REVISION=3  # bump when anything above or below changes, to force a rebuild

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/Vendor"
RUNTIME_DIR="$VENDOR_DIR/icloudpd-runtime"
STAMP="$ICLOUDPD_VERSION-$RECIPE_REVISION"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ "$FORCE" -eq 0 ] && [ "$(cat "$RUNTIME_DIR/.stamp" 2>/dev/null)" = "$STAMP" ]; then
    echo "icloudpd runtime $STAMP already built at $RUNTIME_DIR (use --force to rebuild)"
    exit 0
fi

download() {
    # download URL SHA256 DESTINATION
    curl --fail --silent --show-error --location --retry 3 -o "$3" "$1"
    echo "$2  $3" | shasum -a 256 -c - >/dev/null || { echo "error: checksum mismatch for $1" >&2; exit 1; }
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/icloudpd-runtime.XXXXXX")"
mkdir -p "$VENDOR_DIR"
STAGE="$(mktemp -d "$VENDOR_DIR/.icloudpd-runtime-staging.XXXXXX")"
trap 'rm -rf "$WORK" "$STAGE" "$VENDOR_DIR/icloudpd-runtime.old"' EXIT

echo "Downloading Python and icloudpd ${ICLOUDPD_VERSION}…"
download "$PYTHON_URL" "$PYTHON_SHA256" "$WORK/python.tar.gz"
download "https://github.com/icloud-photos-downloader/icloud_photos_downloader/archive/$ICLOUDPD_COMMIT.tar.gz" \
    "$ICLOUDPD_SHA256" "$WORK/icloudpd.tar.gz"

tar -xzf "$WORK/python.tar.gz" -C "$STAGE"   # creates $STAGE/python
PYTHON="$STAGE/python/bin/python3"
# The PyPI wheels of icloudpd wrap a prebuilt PyInstaller binary, whose launcher needs
# semaphores the app sandbox forbids, so install from source like Homebrew does.
"$PYTHON" -I -m pip install --quiet --disable-pip-version-check --no-warn-script-location "$WORK/icloudpd.tar.gz"

installed="$("$PYTHON" -I -c 'import importlib.metadata as m; print(m.version("icloudpd"))')"
if [ "$installed" != "$ICLOUDPD_VERSION" ]; then
    echo "error: installed icloudpd is $installed, expected $ICLOUDPD_VERSION" >&2
    exit 1
fi

# The app sandbox also forbids the named semaphores behind multiprocessing.Lock, which
# icloudpd's Counter uses. icloudpd runs single-threaded (--threads-num is always 1),
# so a thread lock and a plain value are equivalent. Patch them before icloudpd imports.
cat > "$STAGE/run_icloudpd.py" <<'PY'
import multiprocessing
import sys
import threading


class _Value:
    def __init__(self, typecode, value):
        self.value = value


multiprocessing.Lock = threading.Lock
multiprocessing.RawValue = _Value

from icloudpd.cli import cli

if __name__ == "__main__":
    sys.argv[0] = "icloudpd"
    sys.exit(cli())
PY

# Trim what icloudpd never uses, then precompile so nothing is written into the signed app.
LIB="$STAGE/python/lib/python3.13"
rm -rf "$STAGE/python/include" "$STAGE/python/share" \
    "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" \
    "$LIB/lib-dynload/_tkinter"*.so "$STAGE/python/lib/"tcl* "$STAGE/python/lib/"tk* "$STAGE/python/lib/itcl"* \
    "$LIB/site-packages/pip" "$LIB/site-packages/pip-"*.dist-info
find "$STAGE/python/bin" -mindepth 1 ! -name 'python3' ! -name 'python3.13' -delete
find "$STAGE" -name '__pycache__' -type d -prune -exec rm -rf {} +
"$PYTHON" -I -m compileall -q -j 0 "$LIB" "$STAGE/run_icloudpd.py" >/dev/null

echo "$STAMP" > "$STAGE/.stamp"

# Swap in the new runtime; both renames stay within Vendor/.
rm -rf "$VENDOR_DIR/icloudpd-runtime.old"
if [ -e "$RUNTIME_DIR" ]; then mv "$RUNTIME_DIR" "$VENDOR_DIR/icloudpd-runtime.old"; fi
mv "$STAGE" "$RUNTIME_DIR"
rm -rf "$VENDOR_DIR/icloudpd"  # the earlier PyInstaller build

echo "Built $RUNTIME_DIR ($(du -sh "$RUNTIME_DIR" | cut -f1)), icloudpd $installed"
