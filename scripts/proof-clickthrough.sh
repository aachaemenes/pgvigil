#!/usr/bin/env bash
# Proof of the web UI's click-through (the pre-publish walk; run before a tag and on request, not in CI): every
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
# Expected (the ninth run, written before it): the eighth ran as expected but for one row outside the file - the bar's
# 'Today', listed as 'Today 20h 59m' and clicked after 21:00, when the picker words it '21h' (a length drops its zero
# part): no control of the listed words, 'step gone'. A control's words now leave out a meta span beside its name:
#   the grader's self-test: 14 of 14 cases; the expected file: 12 rows; no 'the busy rule's fixture' line and no 'the
#     signature's fixture' line
#   the click map: its own verdict line (524 links, 0 FAIL)
#   listed: 182 pages (root 62, pg 64, ms 56) in 4 shards; the grade's pages 183 (root 63); every page settled
#   the walk: the longest driver about the eighth run's 3288 s, chromium started once per driver
#   the grade: the bar's ten range items by their names alone ('bar B Range: Last hour > bar B Today', 'bar B Week to
#     date'; no length in a path), each navigates; no 'not reached' bar row; the eighth run's rows otherwise - Pick
#     series All 75 to 79 (77 in the eighth: two charts drawn that the seventh did not reach), 6 Columns, Reset all,
#     Latest, Compare, the re-reads 12 to 15 (drives' and collectiondates' Refresh grade redraws in some runs; the
#     likely cause drives' 'Updated ... (<age> ago)' line read with a new age), mssql_running's Later and Latest, the deadlock Graph 1
#     and its '[2]' redraws, the two Draw rows 0 or 1 each (the seed decides; 0 in the eighth, both drew; a Draw '[2]'
#     that only reads is a row outside the file), Admin's Servers and the alert page's 'at the firing' 1 each, the
#     'current' rows 2; 'tree: 0 leaf(s) found on the second look'; no tree leaf NOTHING; 'click-through: OK (...)', rc 0
#   beside the run: every path in the eighth's rows and not in the ninth's (or the reverse) is a control with a meta
#     span - the ten range items
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); DB="pgvigil_click_$RANDOM"; SRV=""; CHR=""; DRV=(); MADE=""
OUT="${PGVIGIL_CLICKTHROUGH_OUT:-$WORK/out}"; mkdir -p "$OUT/shots"
N="${PGVIGIL_CLICK_DRIVERS:-4}"
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  for p in "${DRV[@]}"; do kill "$p" 2>/dev/null || true; done
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  # only the database this run made (a name another run drew is never dropped); set -u never stops the cleanup
  [[ -n "$MADE" ]] && psql "${PGVIGIL_ADMIN_DSN:-} dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  # each Chromium's own log beside the run's output (a browser that exits or is lost says why there)
  mkdir -p "$OUT/chrome-logs" 2>/dev/null && cp "$WORK"/clickthrough-list-*/*-chrome.log "$WORK"/drv-*/*-chrome.log "$OUT/chrome-logs/" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for t in chromium node curl ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
# a free port, never one this run handed out before (kept in a file: each call runs in a $(...) subshell)
freeport() { local p; for _ in $(seq 1 60); do p=$((21000 + RANDOM % 11500)); grep -qx "$p" "$WORK/ports" 2>/dev/null && continue; ss -Htan "sport = :$p" | grep -q . || { echo "$p" >> "$WORK/ports"; echo $p; return; }; done; echo 0; }

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
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || fail "create database $DB"; MADE=1
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
TMPDIR="$WORK" node scripts/clickthrough.mjs list "$(freeport)" "$URL" "$OUT/pages.json" "$N" 2> "$OUT/list.log" || { tail -5 "$OUT/list.log"; fail "the page list"; }

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
