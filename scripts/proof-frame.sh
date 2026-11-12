#!/usr/bin/env bash
# Proof of the shared frame (the click-through's H): a demo fleet is seeded into a throwaway database and served on
# loopback, and a headless Chromium runs scripts/frame-check.mjs over it. Needs go, psql, chromium and node, the web
# bundle built (internal/web/dist/app.js) with web/node_modules in place, and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 240; a loaded machine seeds slower)
# Expected (written before the first run):
#   A filter      '>20' on Instances' sessions: n of 15 rows shown (filtered), 0 < n < 15, every shown value > 20
#   B export      the CSV export of the filtered grid: n data lines and the header
#   C menu        the grid's own three items first: 'Copy cell|Copy row|Copy all n rows shown|' (the grid tools' lines
#                 follow them); Escape with the focus outside the menu closes it
#   C clipboard   the cell's own words (1 line); the header and the row (2 lines); the header and n rows; 'Copied ...'
#   D own menu    a link and a filter field keep the browser's menu; at the window's corner the menu ends inside it
#   E unit filter '>500 MB' on Memory's 'size in cache' keeps exactly the cells shown over 500 MB, some rows dropped
#   F nested grid in a History panel: the inner 'Copy row' carries the inner header; the outer copy leaves the panel out
#   G tests pane  the Summary's Tests pane scrolled: its header within 2 px of the pane's top; one tab stop
#   H refresh     five choices on the Summary, Off stored as 0; the select disabled on Performance (not a live page)
#   I chart       a legend's double-click shows one series, a second shows all; the readout has a time and values
#   M chart menu  'Copy image|Save image|Copy data|Export data (CSV)', and '|Pick series' on a chart of two series or more;
#                 Copy data: a header of time and the series' names, a row per point, the time as YYYY-MM-DD HH:MM:SS;
#                 the chart says 'Copied <n> points'
#   J paging      a job's All runs over three days: n rows over 400, 200 drawn; Copy all n rows, still 200 drawn; 'Show 200
#                 more' draws 400 with the focus on the line; 'Show all' draws n, the line hidden, the focus on the grid
#   K pies        every pie on Storage: k slice(s) for k row(s), none stroked, 1.0000 turn(s)
#   L colours     solid by default: an OK cell rgb(0, 102, 56), a grid header rgb(0, 99, 163), 'Colours: solid'; one click:
#                 data-status quiet, the OK cell unfilled, stored 'quiet', kept on another page; a second click: solid again
#   tz            (offline, before the browser) 25 zone checks: New York, Sydney, Lord Howe, Santiago and Cairo at their
#                 daylight-saving edges, Kathmandu and Kolkata offsets, the calendar periods at a month and a year
#                 rollover, the 31-day cap: 'tz: 25 checks as expected'
#   N range       (the browser's own zone pinned to America/Los_Angeles) the panel: 'Quick ranges|Calendar periods|A start
#                 and an end|Type a range', 16 ranges, the zone chooser, inside the window; a range of 12:00-13:00 UTC in
#                 the inputs as 2026-01-15T04:00 and T05:00, the tag UTC-08:00; zone Asia/Tokyo: the tag UTC+09:00, the inputs T21:00 and
#                 T22:00, the button's window text as the zone writes it, the chooser the same node; an end typed as 23:00
#                 applied as 14:00Z; Yesterday: 24 h ending at the zone's midnight, no w=; Today: w=today, 'Range: Today',
#                 from the zone's midnight, the page live; a chart's legend and readout name the same minute, 17 h (16 in
#                 summer) ahead of the browser zone's; a Log events row as the zone writes its instant; after a reload the
#                 tag and the stored zone stand; Escape closes the panel with the focus on its button; Browser time: the
#                 browser's own offset, stored 'local'; a click outside closes it; another address with the focus in the
#                 open panel closes it and puts the focus on the range button
#   O time strip  erp01's Log events over a fixed day ending 3 min back: 60 steps, 'Whole range. Drag ...', every row in
#                 the grid; sorted by ms, a drag over steps 30-59: '<from> to <to>: k of n rows.' with k (> 0) the API's count
#                 for that half, k in the grid, still sorted, its count line 'k of n rows shown (the stretch ...)', 30 steps
#                 dimmed, 'Whole range' offered; its click: all rows, none dimmed, still sorted; Home, three right, two with
#                 Shift, Enter: the rows of steps 3-5 (> 0), 57 dimmed, and the same after the page is drawn again (visibilitychange); Shift+click on step 10: steps 3-10, 52 dimmed; Escape:
#                 all rows, 'Whole range' hidden; sql01's Deadlocks page has a strip exactly when its read holds 2 or more
#   P new page at its top  the fleet Summary (taller than the window) scrolled to its end; the lowest link in it to an
#                 instance's Summary clicked: that page seen rendered, taller than the window, at scrollY 0
#   task 152's cases (each one's comment in frame-check.mjs):
#   Q chart drag  erp01's Performance page over a fixed day, a drag from 40 % to 60 % of the first chart's plot: from / to
#                 in the address (whole minutes, within two minutes and a pixel of the dragged times), no w=, every chart
#                 drawn again inside that range
#   R one cursor  the pointer over the first chart's middle: a readout on every chart whose span holds that moment, each
#                 naming the same time
#   S setting     the first PostgreSQL instance with a 'setting' event in its frame read over three days: on its Performance
#                 page over two hours either side every chart holding the moment has a mark at that instant (within 2 % of
#                 the span), named with the event's words; another instance's page draws exactly its own events; the mark
#                 opens the Configuration page over ten minutes around it
#   T slices      erp01's Database info: a 'Databases by size' wedge opens its database's page; a pie of over five slices:
#                 Top 5 draws five wedges (four and 'other') and five legend rows, All every slice, the choice kept; the pie
#                 menu's four items, Copy data copies every slice under a header
#   U pick series a tick per series; the first unticked hides it on the legend and stays so after a redraw; All shows every
#                 series again; Done puts the focus back on the menu button
#   V steps       on 12:00-13:00 UTC: Earlier 11:00-12:00, Later 12:00-13:00, Zoom out 11:30-13:30, the key [ is Earlier; on
#                 the preset 1h Later disabled and Zoom out the preset 4h; the key ] on a range ending now changes nothing
#   W typed range 'now-6h' previews 'follows now' and Enter makes w=6h; 'now-1d/d to now/d' is yesterday (24 h from the
#                 zone's midnight before) as a fixed range; 'soon' refused in the preview, the address unchanged
#   X footer      on the Summary the instances as /api/instances counts them, the collections, the repository's size, the
#                 seat, the newest read and 'auto refresh every 30 s'; on a fixed Performance window 'auto refresh not on
#                 this page'
#   Y axes, limit erp01's Transactions chart has three axes, the right one 'rollbacks/s'; its Connections chart names
#                 max_connections at the frame read's value, a line within four times the chart's peak, else 'above the chart'
#   Z full window the button draws the chart over the window (fixed, the plot at least the window's width less 100 px),
#                 aria-pressed true; Escape puts it back at its width with the focus on the button
#   AA partial    erp01's Performance page over a day that starts a day before the demo's first read says where its data
#                 starts; over a day inside the seeded days no note
#   AB deadlocks  sql01's frame read over the fixed day holds as many deadlock marks as its deadlock read (api/mssql/xe
#                 part=deadlocks), drawn on a chart of its Performance page and in the chart's list
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

echo "== the zone arithmetic, offline (web/src/tz.ts and router.ts's periods at daylight-saving edges)"
[[ -x web/node_modules/.bin/esbuild ]] || fail "web/node_modules is missing (cd web && npm ci)"
printf "export * from './web/src/tz'; export { periodStart, capRange, MAX_RANGE_MS } from './web/src/router';" \
  | web/node_modules/.bin/esbuild --bundle --format=esm --loader=ts --log-level=warning --outfile="$WORK/tz.mjs"
node scripts/tz-check.mjs "$WORK/tz.mjs" || fail "the zone arithmetic did not hold"

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 3 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s (PGVIGIL_DEMO_WAIT_S raises the wait on a loaded machine)"; }

echo "== a headless Chromium on CDP $CDP"
mkdir -p "$WORK/dl"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the checks"
node scripts/frame-check.mjs "$CDP" "http://127.0.0.1:$PORT/" "$WORK/dl" || fail "a case did not hold"
echo "OK: the shared frame: filter, export, copy menu, clipboard, nested grid, tests pane, refresh, chart, chart menu, paging, pies, colours, range and zone, time strip"
