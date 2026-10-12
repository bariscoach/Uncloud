#!/usr/bin/env bash
# Builds Uncloud in Release and packages it as dist/Uncloud-<version>.dmg, a compressed
# disk image with the app and an Applications shortcut to drag it onto.
# Usage: scripts/make-dmg.sh [--identity "Developer ID Application: …"]
#
# Without --identity the app is signed ad hoc: it runs on this Mac, but on other Macs
# Gatekeeper blocks the first launch until the user chooses Open Anyway in
# System Settings > Privacy & Security. Sign with a Developer ID and notarize to avoid that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="-"
while [ $# -gt 0 ]; do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

cd "$REPO_ROOT"
xcodegen generate --quiet

BUILD_DIR="$REPO_ROOT/build/release"
# No get-task-allow: a build for other people shouldn't let debuggers attach.
SIGNING=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
echo "Building Uncloud (Release)…"
xcodebuild -project Uncloud.xcodeproj -scheme Uncloud -configuration Release \
    -derivedDataPath "$BUILD_DIR" "${SIGNING[@]}" build >"$BUILD_DIR.log" 2>&1 \
    || { grep -E 'error:' "$BUILD_DIR.log" >&2 || tail -20 "$BUILD_DIR.log" >&2; echo "error: build failed (log: $BUILD_DIR.log)" >&2; exit 1; }

APP="$BUILD_DIR/Build/Products/Release/Uncloud.app"
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/uncloud-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Uncloud.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$REPO_ROOT/dist"
DMG="$REPO_ROOT/dist/Uncloud-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Uncloud $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"
hdiutil verify -quiet "$DMG"

echo "Built $DMG ($(du -h "$DMG" | cut -f1)), SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
