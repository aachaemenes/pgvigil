#!/usr/bin/env bash
# proof-site: the site (docs/, served as pgvigil.com) in a headless Chromium. docs/ is served on loopback as it is on
# GitHub Pages (static files), and scripts/site-check.mjs renders every page at 1440 and 390 px in the light and dark
# schemes. Needs python3, chromium, node and npm.
#   bash scripts/proof-site.sh [--no-net]          (the PNGs go to .proof-site/, emptied first; PGVIGIL_SITE_OUT may name
#                                                  another folder whose name starts .proof-site)
# Expected: one 'ok' line per page, width and scheme (the scheme's page background, no sideways scroll, the header held
# at the top after a scroll, the phone menu at 390 opened with its six links and the links at 1440, every image
# loaded, 0 axe nodes under WCAG 2.1 A / AA and the heading and landmark rules), one 'ok' line per link (200, its
# #anchor on the page; only the skip link jumps inside a page; a 429 prints n/a), 'site: ... as expected'; the PNGs.
# axe-core 4.14.0 is installed into a temporary folder from npm (as proof-a11y.sh does).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${PGVIGIL_SITE_OUT:-.proof-site}"
[[ "$(basename "$OUT")" == .proof-site* ]] || { echo "FAIL: PGVIGIL_SITE_OUT must be a folder named .proof-site*" >&2; exit 1; }
WORK=$(mktemp -d); PORT=$((23000 + RANDOM % 8000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; [[ -n "$CHR" ]] && { kill "$CHR" 2>/dev/null; wait "$CHR" 2>/dev/null; } || true; rm -rf "$WORK"; }
trap cleanup EXIT
for t in python3 chromium node npm curl; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done
(cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "npm install axe-core failed"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory docs > "$WORK/http.log" 2>&1 &
SRV=$!
for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "http://127.0.0.1:$PORT/" >/dev/null || fail "the local server never answered on $PORT"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --hide-scrollbars about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
rm -rf "$OUT"; mkdir -p "$OUT"
node scripts/site-check.mjs "$CDP" "http://127.0.0.1:$PORT/" "$WORK/node_modules/axe-core/axe.min.js" "$OUT" "$@" || fail "a check did not hold"
echo "OK: the site"
