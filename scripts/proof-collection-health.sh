#!/usr/bin/env bash
# Proof of the Collection Health tab (B6.2: DBA Dash 4.25.0's Checks > Collection Health at the root, a tag folder and
# an instance): a demo fleet is seeded into a throwaway database and served on loopback, three fixture instances the
# demo's minute tick never touches are added, and a headless Chromium runs scripts/collection-health-check.mjs (rows
# CH6 and CH7). Needs go, psql, chromium, node and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 240)
# The fixtures: fx-chcrit (activity ok 40 minutes ago, then 3 failures in a row: critical '3 failure(s) in a row,
# failing 40 min'; its hourly row 1 ok 3 failed), fx-chrate (an hourly row of 5 ok 5 failed, the last run failed:
# critical by rate), fx-chskip (an hourly row of 5 skipped: N/A).
# Expected: 'collection health: <n> ok; 0 FAIL' - CH6 the tab drew at the root, the tag and fx-chcrit, its columns in
# DBA Dash's order, Show 'Row per collection per instance' by default, the four status words each alone, Row per
# collection's columns, the Runs and Cost charts and Import Lag's sentence; CH7 the Summary's cell of fx-chcrit and of a SQL Server row on that instance's tab, fx-chcrit's
# row critical in the grid and the API, the grid's statuses = the API's, the Instance name, Failed (3 listed) and Errors
# (3 listed) landings, Last Failure's window = the API's errors_from .. errors_to, Instances on grain=instance,
# fx-chrate critical by rate, fx-chskip N/A. On a tree before B6.2 every row FAILs (the red run; rc 1).
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
q "insert into pgvigil.instances (name, platform, engine) values ('fx-chcrit', 'onprem', 'postgres'), ('fx-chrate', 'onprem', 'postgres'), ('fx-chskip', 'onprem', 'postgres')" >/dev/null
q "select pgvigil.log_collection(i.instance_id, 'activity', now() - r.ago, 10, r.st, r.note)
     from pgvigil.instances i
     join (values ('fx-chcrit', interval '40 min', 'ok', null), ('fx-chcrit', interval '30 min', 'error', 'proof: failed 1'),
                  ('fx-chcrit', interval '15 min', 'error', 'proof: failed 2'), ('fx-chcrit', interval '0 min', 'error', 'proof: failed 3'),
                  ('fx-chrate', interval '5 min', 'ok', null), ('fx-chrate', interval '0 min', 'error', 'proof: failed'),
                  ('fx-chskip', interval '0 min', 'skipped', 'proof: not on this kind of server')) r(name, ago, st, note) on r.name = i.name" >/dev/null
q "select pgvigil.import_collection_health('proof', jsonb_build_object('health', jsonb_agg(jsonb_build_object('instance', x.name, 'collection', 'activity',
     'hour', date_trunc('hour', now() at time zone 'UTC') at time zone 'UTC', 'runs', x.ok + x.err, 'ok', x.ok, 'partial', 0, 'error', x.err, 'skipped', x.skip,
     'rows', 1, 'dur_ms_sum', 10 * (x.ok + x.err), 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0, 'interval_s', 60))))
     from (values ('fx-chcrit', 1, 3, 0), ('fx-chrate', 5, 5, 0), ('fx-chskip', 0, 0, 5)) x(name, ok, err, skip)" >/dev/null

# fx-chhour (the review of B6.2, part b #1): one failure logged 10 minutes into the previous UTC hour, its hourly row;
# a range that starts 20 minutes into that hour counts it in Failed (the hours from the one holding the start), and the
# list Failed opens must hold it
q "insert into pgvigil.instances (name, platform, engine) values ('fx-chhour', 'onprem', 'postgres')" >/dev/null
q "select pgvigil.log_collection(i.instance_id, 'activity', (date_trunc('hour', now() at time zone 'UTC') - interval '50 min') at time zone 'UTC', 10, 'error', 'proof: failed in the first partial hour')
     from pgvigil.instances i where i.name = 'fx-chhour'" >/dev/null
q "select pgvigil.import_collection_health('proof', jsonb_build_object('health', jsonb_build_array(jsonb_build_object('instance', 'fx-chhour', 'collection', 'activity',
     'hour', (date_trunc('hour', now() at time zone 'UTC') - interval '1 hour') at time zone 'UTC', 'runs', 1, 'ok', 0, 'partial', 0, 'error', 1, 'skipped', 0,
     'rows', 0, 'dur_ms_sum', 10, 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0, 'interval_s', 60))))" >/dev/null

echo "== a headless Chromium on CDP $CDP"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"

echo "== the tab"
rc=0
node scripts/collection-health-check.mjs "$CDP" "http://127.0.0.1:$PORT/" | tee "$WORK/ch.txt" || rc=$?
grep -q '^collection health: .*; 0 FAIL$' "$WORK/ch.txt" || fail "collection-health-check.mjs did not end with 0 FAIL (rc $rc)"
echo "OK: the Collection Health tab"
