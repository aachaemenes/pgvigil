#!/usr/bin/env bash
# Proof of the Collection Health tab (B6.2: DBA Dash 4.25.0's Checks > Collection Health at the root, a tag folder and
# an instance): a demo fleet is seeded into a throwaway database and served on loopback, three fixture instances the
# demo's minute tick never touches are added, and a headless Chromium runs scripts/collection-health-check.mjs (rows
# CH6 and CH7). Needs go, psql, chromium, node and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 240)
# The fixtures, four (their times from ONE clock read, CH_NOW, so the check grades them by their own times - the
# review B6f3 #3 / #12): fx-chcrit (activity ok 40 minutes before CH_NOW, then 3 failures in a row: critical
# '3 failure(s) in a row, failing 40 min'; its hourly row 1 ok 3 failed), fx-chrate (an hourly row of 5 ok 5 failed,
# the last run failed: critical by rate), fx-chskip (an hourly row of 5 skipped: N/A), fx-chhour (one failure 10
# minutes into CH_HOUR, the UTC hour before CH_NOW's, and its hourly row).
# Expected: 'collection health: <n> ok; 0 FAIL' - CH6 the tab drew at the root, the tag and fx-chcrit, its columns in
# DBA Dash's order, Show 'Row per collection per instance' by default, each of the four status words alone = the API's
# count for it, every row drawn, the tag and instance levels by their rows, no status ticked (the charts still drawn),
# the status rule in docs/collection-health.md's words (both halves: 'from the last success to the latest failure'
# twice), Row per collection's columns, the Runs and Cost charts, one whole hour said hourly, Import Lag's sentence;
# CH7 the Summary's cell of fx-chcrit and of a SQL Server row on that instance's tab, fx-chcrit's row critical in the
# grid and the API, the grid's statuses = the API's, the Instance name on its own tab, Failed (3 listed) and Errors
# (3 listed) landings, Last Failure's window = fx-chcrit's own ok time (CH_NOW - 40 min, within a second) .. its last
# failure + 1 h and its landing (3 listed), Instances opened on grain=instance, Failed -> the counted window
# (fx-chhour: Failed 1, 1 listed, from CH_HOUR + 20 min), the error list's window on the page's clock, fx-chrate
# critical by rate, fx-chskip N/A. RED BASES: a tree before B6.2 FAILs every row (rc 1); c87c8d84 gives 'Failed 1,
# 0 listed' on the counted-window row, 34537176 'Failed 0: no link' (its hours rounded up).
# NOT HERE: CH8 - scripts/proof-a11y.sh (axe over every root and instance tab, both themes: the new tab is in its list
# once router.ts names it) and scripts/proof-clickmap.sh / frame-check.mjs over the new tab.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_chealth_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
# stop: TERM, up to 10 s for the process to end, then KILL
stop() { local p=$1 i; kill "$p" 2>/dev/null || return 0; for i in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.2; done; kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; }
cleanup() {
  [[ -n "$SRV" ]] && stop "$SRV" || true
  [[ -n "$CHR" ]] && stop "$CHR" || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || { sleep 1; rm -rf "$WORK"; } || echo "warning: $WORK left behind" >&2
}
trap cleanup EXIT
for t in chromium node psql go; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done
# a stale bundle is said, not refused: the red run must reach every row
grep -q 'ch-show' internal/web/dist/app.js || echo "WARN: the web bundle has no Collection Health tab (older than web/src/collection_health.ts, or a tree before B6.2)"

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$WORK/pgvigil" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s"; }
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "== the fixtures: fx-chcrit, fx-chrate, fx-chskip, fx-chhour (PostgreSQL, no tag)"
# one clock read for every fixture time (UTC, timestamp without zone): the check grades the rows against these
CH_NOW=$(q "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS')")
CH_HOUR=$(q "select to_char(date_trunc('hour', '$CH_NOW'::timestamp) - interval '1 hour', 'YYYY-MM-DD HH24:MI:SS')")
NOWZ="'$CH_NOW'::timestamp at time zone 'UTC'"
HOURZ="'$CH_HOUR'::timestamp at time zone 'UTC'"
q "insert into pgvigil.instances (name, platform, engine) values ('fx-chcrit', 'onprem', 'postgres'), ('fx-chrate', 'onprem', 'postgres'), ('fx-chskip', 'onprem', 'postgres')" >/dev/null
# each run its own statement, oldest first, as a collector writes them: the run status keeps the newest run and an
# older one written late never moves it back (0166's collection_run_status_take). One SELECT over a join called
# log_collection in the plan's row order - on the box (vis-b6ch4) the newest failure first, and fx-chcrit read
# '1 failure(s) in a row, never succeeded'
logrun() { q "select pgvigil.log_collection(i.instance_id, 'activity', $NOWZ - interval '$2', 10, '$3', $4) from pgvigil.instances i where i.name = '$1'" >/dev/null; }
logrun fx-chcrit '40 min' ok null
logrun fx-chcrit '30 min' error "'proof: failed 1'"
logrun fx-chcrit '15 min' error "'proof: failed 2'"
logrun fx-chrate '5 min' ok null
logrun fx-chcrit '0 min' error "'proof: failed 3'"
logrun fx-chrate '0 min' error "'proof: failed'"
logrun fx-chskip '0 min' skipped "'proof: not on this kind of server'"
q "select pgvigil.import_collection_health('proof', jsonb_build_object('health', jsonb_agg(jsonb_build_object('instance', x.name, 'collection', 'activity',
     'hour', date_trunc('hour', '$CH_NOW'::timestamp) at time zone 'UTC', 'runs', x.ok + x.err, 'ok', x.ok, 'partial', 0, 'error', x.err, 'skipped', x.skip,
     'rows', 1, 'dur_ms_sum', 10 * (x.ok + x.err), 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0, 'interval_s', 60))))
     from (values ('fx-chcrit', 1, 3, 0), ('fx-chrate', 5, 5, 0), ('fx-chskip', 0, 0, 5)) x(name, ok, err, skip)" >/dev/null

# fx-chhour (the review of B6.2, part b #1): one failure logged 10 minutes into the previous UTC hour, its hourly row;
# a range that starts 20 minutes into that hour counts it in Failed (the hours from the one holding the start), and the
# list Failed opens must hold it
q "insert into pgvigil.instances (name, platform, engine) values ('fx-chhour', 'onprem', 'postgres')" >/dev/null
q "select pgvigil.log_collection(i.instance_id, 'activity', $HOURZ + interval '10 min', 10, 'error', 'proof: failed in the first partial hour')
     from pgvigil.instances i where i.name = 'fx-chhour'" >/dev/null
q "select pgvigil.import_collection_health('proof', jsonb_build_object('health', jsonb_build_array(jsonb_build_object('instance', 'fx-chhour', 'collection', 'activity',
     'hour', $HOURZ, 'runs', 1, 'ok', 0, 'partial', 0, 'error', 1, 'skipped', 0,
     'rows', 0, 'dur_ms_sum', 10, 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0, 'interval_s', 60))))" >/dev/null

# fx-chimport (the review of B6g-1 part b #2): an hour of 3 failed runs, 2 of them at the write of collected rows
# (import_failed 2), and their 3 errors logged: Failed reads 1 and Import Failed 2, each a link to the same list of 3
q "insert into pgvigil.instances (name, platform, engine) values ('fx-chimport', 'onprem', 'postgres')" >/dev/null
logrun fx-chimport '20 min' error "'proof: read failed'"
logrun fx-chimport '10 min' error "'proof: import failed 1'"
logrun fx-chimport '0 min' error "'proof: import failed 2'"
q "select pgvigil.import_collection_health('proof', jsonb_build_object('health', jsonb_build_array(jsonb_build_object('instance', 'fx-chimport', 'collection', 'activity',
     'hour', date_trunc('hour', '$CH_NOW'::timestamp) at time zone 'UTC', 'runs', 3, 'ok', 0, 'partial', 0, 'error', 3, 'skipped', 0,
     'rows', 0, 'dur_ms_sum', 30, 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0, 'interval_s', 60,
     'import_failed', 2, 'import_runs', 2, 'import_ms_sum', 8, 'import_ms_max', 5))))" >/dev/null
# B6g-3 (CH23): an hour before it of 2 ok runs, so the Collection Performance report of fx-chimport has two hours to
# chart (one read draws no chart); Failed and Import Failed stay 1 and 2 (CH17)
q "select pgvigil.import_collection_health('proof', jsonb_build_object('health', jsonb_build_array(jsonb_build_object('instance', 'fx-chimport', 'collection', 'activity',
     'hour', date_trunc('hour', '$CH_NOW'::timestamp) at time zone 'UTC' - interval '1 hour', 'runs', 2, 'ok', 2, 'partial', 0, 'error', 0, 'skipped', 0,
     'rows', 4, 'dur_ms_sum', 20, 'dur_ms_max', 12, 'over_half', 0, 'over_interval', 0, 'interval_s', 60,
     'import_failed', 0, 'import_runs', 2, 'import_ms_sum', 6, 'import_ms_max', 4))))" >/dev/null

echo "== a headless Chromium on CDP $CDP"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the tab"
rc=0
CH_NOW="${CH_NOW/ /T}Z" CH_HOUR="${CH_HOUR/ /T}Z" node scripts/collection-health-check.mjs "$CDP" "http://127.0.0.1:$PORT/" | tee "$WORK/ch.txt" || rc=$?
grep -q '^collection health: .*; 0 FAIL$' "$WORK/ch.txt" || fail "collection-health-check.mjs did not end with 0 FAIL (rc $rc)"
echo "OK: the Collection Health tab"
