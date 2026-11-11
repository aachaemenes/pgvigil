#!/usr/bin/env bash
# proof-site: the site (docs/, served as pgvigil.com) in a headless Chromium. docs/ is served on loopback as it is on
# GitHub Pages (static files), and scripts/site-check.mjs renders every page at 1440 and 390 px in the light and dark
# schemes. Needs python3, chromium, node and npm.
#   bash scripts/proof-site.sh [out dir, default .proof-site] [--no-net]
# Expected: one 'ok' line per page, width and scheme (no sideways scroll, the header held at the top after a scroll,
# the phone menu at 390 and the links at 1440, every image loaded, 0 axe nodes under WCAG 2.1 A / AA), one 'ok' line
# per link (200; only the skip link jumps inside a page), and 'site: ... as expected'; the PNGs in the out dir.
# axe-core 4.14.0 is installed into a temporary folder from npm (as proof-a11y.sh does).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-.proof-site}"; shift || true
WORK=$(mktemp -d); PORT=$((23000 + RANDOM % 8000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; [[ -n "$CHR" ]] && { kill "$CHR" 2>/dev/null; wait "$CHR" 2>/dev/null; } || true; rm -rf "$WORK"; }
trap cleanup EXIT
for t in python3 chromium node npm; do command -v $t >/dev/null || fail "$t is not on this machine"; done
(cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "npm install axe-core failed"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory docs > "$WORK/http.log" 2>&1 &
SRV=$!
for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.25; done
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --hide-scrollbars about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
rm -rf "$OUT"; mkdir -p "$OUT"
node scripts/site-check.mjs "$CDP" "http://127.0.0.1:$PORT/" "$WORK/node_modules/axe-core/axe.min.js" "$OUT" "$@" || fail "a check did not hold"
echo "OK: the site"
