#!/usr/bin/env bash
# The pages P25 added, on the demo (task 11b): a demo fleet is seeded into a throwaway database (-days 2) and served
# on loopback; a headless Chromium opens each new page in both themes (scripts/parity-s3-pages.mjs): a picture of
# each, axe-core's WCAG 2.1 A / AA rules at 0 violation nodes, and data on each - none on empty-state words alone.
# Needs go, psql, chromium, node and npm, and a PostgreSQL to hold the throwaway database:
#   PGVIGIL_ADMIN_DSN    keyword-form connection to a cluster as a login that may create a database (no dbname)
#   PGVIGIL_DEMO_WAIT_S  the seconds to wait for the seeded demo to serve (default 300)
#   PGVIGIL_SHOTS_OUT    where the pictures go (default ./parity-s3-shots)
# Expected: every page renders in both themes with rows or a chart and 0 violation nodes (the walk's exit 0).
# axe-core 4.14.0 is installed into the run's temporary folder from npm.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
OUT=${PGVIGIL_SHOTS_OUT:-parity-s3-shots}
WORK=$(mktemp -d); DB="pgvigil_s3pages_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""; MADE=
# review t11-6 NIT 12: a free pair of ports (ss -ltn), never a taken one read as "the demo serve died"
for _ in $(seq 1 20); do ss -ltn 2>/dev/null | grep -qE ":($PORT|$CDP)\b" || break; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); done
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  [[ -n "$MADE" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node npm psql go; do command -v $t >/dev/null || fail "$t is not on this machine"; done

echo "== build and seed the demo into $DB (-days 2), serve on 127.0.0.1:$PORT"
# review t11-6 BLOCKER 1: the binary embeds internal/web/dist - build the bundle from this tree, its wiring patches applied
# (a patch already applied is left alone: --forward's dry run refuses it)
for pt in PARITY-S3-wiring.patch NODETABS-wiring.patch; do
  if [[ -f scripts/$pt ]] && patch -p1 --dry-run -s --forward < scripts/$pt >/dev/null 2>&1; then patch -p1 -s --forward < scripts/$pt || fail "$pt did not apply"; fi
done
(cd web && npm ci --silent --no-audit --no-fund >/dev/null 2>&1 && npm run build >/dev/null 2>&1) || fail "the web bundle did not build"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null; MADE=1
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do
  grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break
  kill -0 $SRV 2>/dev/null || { tail -20 "$WORK/demo.log"; fail "the demo serve died"; }
  sleep 1
done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-300} s"; }

echo "== axe-core 4.14.0 and a headless Chromium on CDP $CDP"
(cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "npm install axe-core failed"
AXE="$WORK/node_modules/axe-core/axe.min.js"; [[ -f "$AXE" ]] || fail "axe.min.js not found after install"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the pages"
mkdir -p "$OUT"
timeout 1800 node scripts/parity-s3-pages.mjs "$CDP" "http://127.0.0.1:$PORT/" "$AXE" "$OUT" || fail "a page had no data or a violation (the FAIL lines above)"
echo "OK: every page rendered with data in both themes, 0 violation nodes; pictures in $OUT"
