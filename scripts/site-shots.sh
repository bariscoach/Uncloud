#!/usr/bin/env bash
# Screenshots of the download page (site/) at desktop and phone widths, light and dark, for design reviews.
# Usage: scripts/site-shots.sh <output folder>
# Serves site/ on a local port (file:// breaks the logo masks) and drives headless Chrome.
set -euo pipefail
OUT="${1:?usage: scripts/site-shots.sh <output folder>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT=$(( 8700 + RANDOM % 200 ))
mkdir -p "$OUT"
# The server root holds a link to site/ and a frame page: headless Chrome's narrowest window is 500px, so phone
# shots load the page in a 390px iframe.
SERVE="$(mktemp -d)"
ln -s "$ROOT/site" "$SERVE/site"
printf '<!doctype html><meta charset="utf-8"><body style="margin:0"><iframe src="/site/" width="390" height="%s" style="border:0;display:block"></iframe>' 9000 >"$SERVE/phone.html"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVE" >/dev/null 2>&1 &
SERVER=$!
PROFILE="$(mktemp -d)"
trap 'kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null || true; rm -rf "$PROFILE" "$SERVE"' EXIT
sleep 1
shot() { # name width height scheme(light|dark) [path]
    local scheme_flag=()
    [ "$4" = dark ] && scheme_flag=(--force-dark-mode --blink-settings=preferredColorScheme=0)
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$PROFILE" \
        --window-size="$2,$3" --virtual-time-budget=4000 ${scheme_flag[@]+"${scheme_flag[@]}"} \
        --screenshot="$OUT/$1.png" "http://127.0.0.1:$PORT/${5:-site/}" >/dev/null 2>&1
    echo "$OUT/$1.png"
}
shot desktop-light 1440 5200 light
shot desktop-dark 1440 5200 dark
shot hero-light 1440 900 light
shot hero-dark 1440 900 dark
# Phone shots are 500px wide images; the page is the left 390px. Sections below the fold may look faded there,
# because scroll reveals don't fire inside the frame; judge layout and overflow only.
shot phone-light 500 9000 light phone.html
shot phone-dark 500 9000 dark phone.html
