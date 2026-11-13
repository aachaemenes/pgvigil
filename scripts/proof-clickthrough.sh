#!/usr/bin/env bash
# Proof of the web UI's click-through (the pre-publish walk, DONE-2; run before a tag and on request, not in CI): every
# page, tab, button, menu item and tree node of both engines clicked once on the demo, each click a row - landed where,
# opened what, off with which words, a write sent (held by the walk, so the demo's state never changes), or NOTHING -
# and a shot of each page. The demo fleet is seeded into a throwaway database and served on loopback (or
# PGVIGIL_DEMO_URL names a demo another proof already serves); the click map (scripts/click-check.mjs, proof-clickmap's)
# runs first on the same build and its links are rows; scripts/clickthrough.mjs lists the pages (the fleet root, one
# instance per engine, the Pooler, the drill pages, the first alert) and walks them in PGVIGIL_CLICK_DRIVERS drivers
# (default 4, each its own headless Chromium); scripts/clickthrough-grade.mjs merges the rows, writes the table, the
# JSON and the contact sheet, and grades the FAIL rows against scripts/clickthrough-expected.txt.
# Needs go, psql, chromium, node 22+, ss; the web bundle internal/web/dist/app.js built first (npm run build in web/).
#   PGVIGIL_ADMIN_DSN       keyword-form connection to a cluster as a login that may create a database (not needed
#                           with PGVIGIL_DEMO_URL)
#   PGVIGIL_DEMO_URL        a demo already served (http://127.0.0.1:<port>/): no build, no seed
#   PGVIGIL_DEMO_WAIT_S     seconds to wait for the seeded demo (default 300)
#   PGVIGIL_CLICK_DRIVERS   drivers in parallel (default 4)
#   PGVIGIL_CLICKTHROUGH_OUT a folder that gets the rows (clickthrough.json / .tsv), the contact sheet (contact.html),
#                           the shots (shots/), each driver's JSON and log, and the click map's JSON
# Expected (the first run, click-c1, on rel-click = rel-walk 3929810 (rel-join-w1 42ca98d + WALK DONE-1's files) + the
# click-through's files; written before it):
#   the grader's self-test: 9 of 9 cases
#   the click map: its own verdict line (proof-clickmap's driver; a FAIL there is a row 'click map FAIL', not a stop)
#   listed: about 165-180 pages - root about 59, PostgreSQL demo-onprem-erp01 about 55 with the Pooler of
#     demo-aurora-crm01, SQL Server demo-onprem-sql01 about 50, the drill pages and the first alert - in 4 shards
#   the walk: about 1,200-2,000 control rows and the tree's carets and leaves; every page settled; each driver about
#     10-25 min (no tool run waits: a Run is a held write)
#   the grade: FAIL 'click-through: FAIL (<n> FAIL row(s) outside the expected file)' - the expected file lists no row
#     before the first run, so every FAIL row is NEW: those rows, by cause with the smallest fix and its file, are WALK
#     DONE-2's table, listed in the expected file in the same commit; the second run's expected is 'click-through: OK'.
#     Most rows: link, navigates, redraws, dialog, menu, write held, disabled with its words; the rows that FAIL are
#     expected among NOTHING (a control the demo leaves inert), error / api (a read refused on the demo), not reached
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); DB="pgvigil_click_$RANDOM"; SRV=""; CHR=""; DRV=()
OUT="${PGVIGIL_CLICKTHROUGH_OUT:-$WORK/out}"; mkdir -p "$OUT/shots"
N="${PGVIGIL_CLICK_DRIVERS:-4}"
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  for p in "${DRV[@]}"; do kill "$p" 2>/dev/null || true; done
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  [[ -z "${PGVIGIL_DEMO_URL:-}" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
for t in chromium node curl ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
taken=" "
freeport() { local p; for _ in $(seq 1 60); do p=$((21000 + RANDOM % 11500)); [[ "$taken" == *" $p "* ]] && continue; ss -Htan "sport = :$p" | grep -q . || { taken+="$p "; echo $p; return; }; done; echo 0; }

echo "== the grader's self-test"
node scripts/clickthrough-grade.mjs --self-test || fail "the grader's self-test"

if [[ -n "${PGVIGIL_DEMO_URL:-}" ]]; then
  URL="${PGVIGIL_DEMO_URL%/}/"
  curl -fs "${URL}api/instances" >/dev/null || fail "PGVIGIL_DEMO_URL does not answer /api/instances: $URL"
  echo "== the demo already served at $URL"
else
  for t in go psql; do command -v $t >/dev/null || fail "$t is not on this machine"; done
  [[ -n "${PGVIGIL_ADMIN_DSN:-}" ]] || fail "PGVIGIL_ADMIN_DSN is not set (or set PGVIGIL_DEMO_URL)"
  PORT=$(freeport); [[ "$PORT" != 0 ]] || fail "no free port"
  echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || fail "create database $DB"
  "$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
  SRV=$!
  for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
  grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-300} s"; }
  URL="http://127.0.0.1:$PORT/"
fi

echo "== the click map on the same build (scripts/click-check.mjs)"
CDP=$(freeport)
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome-map" --no-first-run --disable-gpu --lang=en-US about:blank > "$WORK/chrome-map.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
node scripts/click-check.mjs "$CDP" "$URL" "$OUT/click.json" > "$OUT/click.txt" 2>&1; echo "the click map: rc $? - $(grep -E '^links: ' "$OUT/click.txt" | tail -1)"
kill "$CHR" 2>/dev/null; CHR=""

echo "== the pages"
node scripts/clickthrough.mjs list "$(freeport)" "$URL" "$OUT/pages.json" "$N" 2> "$OUT/list.log" || { tail -5 "$OUT/list.log"; fail "the page list"; }

echo "== the walk: $N drivers"
T=$(date +%s)
for k in $(seq 0 $((N - 1))); do
  node scripts/clickthrough.mjs walk "$(freeport)" "$URL" "$OUT/pages-$k.json" "$OUT/walk-$k.json" "$OUT/shots" "$WORK/drv-$k" 2> "$OUT/walk-$k.log" &
  DRV+=($!); sleep 2
done
rc=0; for p in "${DRV[@]}"; do wait "$p" || rc=$?; done; DRV=()
for k in $(seq 0 $((N - 1))); do echo "driver $k: $(tail -1 "$OUT/walk-$k.log")"; done
echo "the walk: $(( $(date +%s) - T )) s (drivers' worst rc $rc)"

echo "== the grade"
WALKS=(); for k in $(seq 0 $((N - 1))); do WALKS+=("$OUT/walk-$k.json"); done
node scripts/clickthrough-grade.mjs "$OUT" "$OUT/pages.json" "${WALKS[@]}" --click "$OUT/click.json" --shots "$OUT/shots" | tee "$OUT/grade.txt"
g=${PIPESTATUS[0]}
grep -q '^click-through: ' "$OUT/grade.txt" || fail "the grade ended without its verdict (rc $g)"
(( g == 0 )) || fail "$(grep '^click-through: ' "$OUT/grade.txt")"
echo "PROOF OK: $(grep '^click-through: ' "$OUT/grade.txt")"
