#!/usr/bin/env bash
# Proof that every text of the fleet Summary answers a click (scripts/summary-clicks.mjs), on the demo (PostgreSQL and
# SQL Server instances, two days) in a scratch database, served on loopback, with a headless Chromium. Needs go, node,
# chromium, psql, curl and a superuser connection without dbname.
#   PGVIGIL_ADMIN_DSN       the superuser connection (creates and drops the scratch database)
#   PGVIGIL_DEMO_WAIT_S     how long the demo may take to seed and serve (default 300)
#   PGVIGIL_SUMCLICK_OUT    the folder that gets summary-clicks.json and the pictures (default: a temporary one)
#   CLICK_ALL=1             every instance-grid cell, not one per column, engine and text shape
#   SUMCLICK_SCOPES         root,tag,instance (default all three): the fleet Summary, a tag folder, two instances
# Expected (written before the first run, 2026-11-14 18:3x PST):
#  RED on main 1aba474 and on rel-j14pre 70c86da (the fault as reported: many texts of the Summary, the Deadlocks
#  cell among them, do nothing on a click): FAIL rows at least for the Needs attention strip's reasons (their
#  text is one plain span: 'Deadlocks n (x/hr)', 'Blocking n (x/hr)' and the cells' words), for pgvigil's own instance
#  grid columns that are plain values (Total CPU ... Measured, Platform, Role, Sessions, Lock Waits, Last Sample), for
#  the counts line, and wherever a click's change lands below the fold only (the test grid's count and name buttons
#  that filter the instance grid out of view: 'nothing in view (a change below the fold only)'); the headings of a
#  column whose values are all equal show nothing (no sort mark). The exact list is the run's 'DEAD' lines.
#  RED, the instance Summary (added 18:4x PST, before its first run, after reading instheader.ts L165-171 / L267-273):
#  FAIL rows for the header's six chips (CPU, Threads, Memory, Blocking, Deadlocks, Collectors: plain div's, so a
#  click on 'Deadlocks' does nothing - the likeliest text of the report), the band word, the status line ('Online ·
#  last collect ...'), the reason line's words, and on 70c86da whatever of the verdict card is plain text.
#  GREEN: the same 0 FAIL there, the plain rows only headings and a properties table's labels.
#  GREEN after the fix: 'clicks: <n>; 0 FAIL; <k> plain' at every scope, the plain rows only DBA Dash's text cells
#  (Memory Dump / Crash restarts, Is Agent Running, DB Mail).
#  REVISED 2026-11-14 19:4x PST, before run 3 (the walk now clicks an instance page one text node at a time, so a
#  label is clicked apart from the links after it): on an instance page plain is also a properties table's VALUE
#  (DBA Dash's instance info is text), a label whose words end with ':' ('Not OK:', 'Not judged (...):') and a text
#  marked data-nolink (DB Mail, a page's own name). Every chip, health tile, the verdict word and sentence, each
#  verdict reason WITH its count, each acknowledged / not judged group, and each name of the counts line ('not read
#  yet', 'skipped') is a link. Run 3's own expectation: 0 FAIL at the root and the tag folder; on the two instance
#  pages FAIL rows may remain only in their grids' plain cells (a finding's severity, object, time) - read them, then
#  decide. A hang or a closed CDP socket is a FAIL line of its own ('the page hung ...'), never a silent exit.
#  REVISED 2026-11-14 22:0x PST, before run 4 (the review of 823e113 folded; this states what 823e113 widened after
#  run 3 and what the fold changed, so the expectation names every plain kind the walk ships): PLAIN kinds, all of
#  them - a heading; a label (a properties table's label, a dt, the health calendar's heads and month, an off-reason,
#  the chart legend's time row, words ending in ':'); a properties table's value; a text marked data-nolink; a
#  disabled control that says why (its title or the off-reason beside it); a grid cell (tbody td) whose row holds a
#  link or an enabled button (DBA Dash's grids: one link per row, text cells beside it). A link or a button is
#  tested BEFORE any of these, so a control inside a heading, a label or a value is clicked, never called plain.
#  The walk: the app's refresh is Off (paused) for the run, a same-address redraw waits until the old page is gone,
#  each scope is opened at the app's own address (w=1h) so a link to the page it is on changes nothing and FAILS,
#  the point clicked must be on the target (another element over it FAILS), a bare number is found again only in its
#  own box, the strip's '+n more' is clicked, texts over 80 characters are clicked too, and a landing outside the
#  tab strip says so. Expected at 823e113 + the fold: 'clicks: <n>; 0 FAIL; <k> plain' at the root, the tag folder
#  and both instance pages; on the SQL Server instance its header's Memory dumps / DB Mail reasons are plain
#  ('marked as text') and Instance Uptime 'opens a dialog or a menu'; on the PostgreSQL instance the properties
#  'sessions', 'failing collections' and 'last activity sample' are links ('lands on #/activity...' /
#  '#/collectiondates...'). Any FAIL row is read and its cause named, never argued away.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_sumclick_$RANDOM"; PORT=""; CDP=""; SRV=""; CHR=""
OUT=${PGVIGIL_SUMCLICK_OUT:-$WORK/out}
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql curl go ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || fail "no free port pair"; CDP=$((PORT + 1))

echo "== build, seed the demo into $DB and serve it on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build failed"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || fail "no scratch database"
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
T0=$SECONDS
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-300} s"; }
echo "the demo served after $((SECONDS - T0)) s"

echo "== the Summary's clicks (headless Chromium on CDP $CDP)"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
mkdir -p "$OUT"
node scripts/summary-clicks.mjs "$CDP" "http://127.0.0.1:$PORT/" "$OUT" | tee "$OUT/summary-clicks.txt"
RC=${PIPESTATUS[0]}
# a walk that clicked little proves little: both grids' headings and cells at each scope
for part in testhead testcell insthead instcell; do
  grep -q " | $part | " "$OUT/summary-clicks.txt" || fail "the walk clicked no $part"
done
[[ $RC == 0 ]] || fail "dead clicks on the Summary (the DEAD lines above)"
echo "PROOF OK: every text of the Summary answers a click"
