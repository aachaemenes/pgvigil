#!/usr/bin/env bash
# Proof of the shared frame (the click-through's H): a demo fleet is seeded into a throwaway database and served on
# loopback, and a headless Chromium runs scripts/frame-check.mjs over it. Needs go, psql, chromium and node, the web
# bundle built (internal/web/dist/app.js), and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
# Expected (written before the first run):
#   A filter      '>20' on Instances' sessions: n of 15 rows shown (filtered), 0 < n < 15, every shown value > 20
#   B export      the CSV export of the filtered grid: n data lines and the header
#   C menu        'Copy cell|Copy row|Copy all n rows shown'; Escape with the focus outside the menu closes it
#   C clipboard   the cell's own words (1 line); the header and the row (2 lines); the header and n rows; 'Copied ...'
#   D own menu    a link and a filter field keep the browser's menu; at the window's corner the menu ends inside it
#   E unit filter '>500 MB' on Memory's 'size in cache' keeps exactly the cells shown over 500 MB, some rows dropped
#   F nested grid in a History panel: the inner 'Copy row' carries the inner header; the outer copy leaves the panel out
#   G tests pane  the Summary's Tests pane scrolled: its header within 2 px of the pane's top; one tab stop
#   H refresh     five choices on the Summary, Off stored as 0; the select disabled on Counters (not a live page)
#   I chart       a legend's double-click shows one series, a second shows all; the readout has a time and values
#   M chart menu  'Copy image|Save image|Copy data|Export data (CSV)'; Copy data: a header of time and the series' names,
#                 a row per point, the time as YYYY-MM-DD HH:MM:SS; the chart says 'Copied <n> points'
#   J paging      a job's All runs over three days: n rows over 400, 200 drawn; Copy all n rows, still 200 drawn; 'Show 200
#                 more' draws 400 with the focus on the line; 'Show all' draws n, the line hidden, the focus on the grid
#   K pies        every pie on Storage: k slice(s) for k row(s), none stroked, 1.0000 turn(s)
#   L colours     solid by default: an OK cell rgb(0, 102, 56), a grid header rgb(0, 99, 163), 'Colours: solid'; one click:
#                 data-status quiet, the OK cell unfilled, stored 'quiet', kept on another page; a second click: solid again
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_frame_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 3 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 240); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in 240 s"; }

echo "== a headless Chromium on CDP $CDP"
mkdir -p "$WORK/dl"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the checks"
node scripts/frame-check.mjs "$CDP" "http://127.0.0.1:$PORT/" "$WORK/dl" || fail "a case did not hold"
echo "OK: the shared frame: filter, export, copy menu, clipboard, nested grid, tests pane, refresh, chart, chart menu, paging, pies, colours"
