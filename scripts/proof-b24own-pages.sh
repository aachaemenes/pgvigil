#!/usr/bin/env bash
# Proof of B24 OWN's pages (pgvigil's own sessions hidden by default, with a switch): Running queries on both engines,
# Waiting tasks on both, the Queries page, the alert page's reads and the fleet Running page's longest-statement pick.
# The design: its design notes (O1-O4, the FOLD O5-O8 and P1). The server half's own proof is proof-b24own.sh (collection, the flags, the API).
# Needs: go, psql, curl, python3, ss, node, npm, chromium, rsync, and
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 13+ cluster as a superuser: the proof seeds the demo fleet
#                      (7 days) into a repository database of its own and drops it on every exit path the shell can catch
#   PGVIGIL_OWN_SHOTS  a folder: the five own pages with the switch off, light and dark (the design's P2); unset = none
# The tree is copied into the proof's folder; the wiring patches and the web bundle are applied and built THERE (P3).
#
# Staged (no collector: the pages read stored reads): one newest read T on a SQL Server and a PostgreSQL instance of the
# demo fleet, its summary copied from the instance's newest read, its rows planted -
#   SQL Server  901 own idle (sleeping, no transaction), 902 own running 40 s (waiting on PAGEIOLATCH_SH, no blocker),
#               903 an application's request running 10 s, 904 'pgvigil-x' of another login (idle, not own),
#               905 own, blocked by 903 (LCK_M_S); waiting tasks of 902, 903 and 905.
#   PostgreSQL  70001 own idle, 70002 own active 40 s (an IO wait), 70003 an application's active 10 s (blocks 70005),
#               70004 'pgvigil-x' of another login (idle, not own), 70005 own, waiting on 70003's lock.
# Expected (written before the first run):
#  O1 Running queries (PostgreSQL) by default: 70003, 70004, 70005 listed, 70001 and 70002 not; 70005 marked 'pgvigil';
#     the switch 'Show pgvigil's own sessions (2 hidden)'; the status line says 'includes 3 of pgvigil's own'. Ticked:
#     own=1 in the address, 70001 and 70002 listed and marked; Earlier then Latest keep own=1 and the five rows.
#  O2 Running queries (SQL Server) by default: 903, 904, 905 listed (905 marked), 901 and 902 not; the switch '(2
#     hidden)'; 'includes 3 of pgvigil's own'. Ticked: own=1; a slider step Earlier: every mssql/running request the page
#     sends carries own=1 (CDP); Latest: 901 and 902 listed.
#  O2b Waiting tasks (SQL Server): 905's and 903's tasks listed, 902's not; '(1 hidden)'; the wait-types grid's line
#     'pgvigil's own tasks are left out unless the switch is on'. O2c Waiting backends (PostgreSQL): 70005 listed, 70002
#     not, '(1 hidden)'. O2d Queries (SQL Server): the Active queries grid says '(2 hidden)' and lists no 901 / 902.
#  O3 an alert page (the first of the demo's alerts list): every mssql/running or activity read it sends carries own=1,
#     and its 'Running queries' link carries own=1.
#  O4 GET /api/running/fleet: the SQL Server instance's longest statement is 903's, the PostgreSQL instance's 70003's -
#     not the own 40 s statements a page would hide.
#  O9 the read before T (a demo read; the staging sets 0265's applied_at to T - 1 s, an upgrade just before read T) says
#     'this read is from before pgvigil marked its own sessions: nothing in it is hidden'; read T does not.
#  O10 (added after green run 1: 70001 hidden but not counted) own_shown_pg for an idle backend with no transaction answers
#     false and own_shown_mssql for an open transaction of unknown age true - never NULL. Red before rel-b24own d9eeffa0.
#     [review part 2 L3: + own_shown_pg for a backend with no state yet: false, red before rel-b24own 3938ff82]
#  Rows of the review fold, part 2 (FALLBACK; each red on 1c6f1c9a, the code before it, then green):
#  O1 switch (M3) the focus is back on the switch after the tick. O1 / O2 (M2) the words name the one count n belongs
#     to: '3 of the sessions above are pgvigil's own'; O2b '2 of the waiting tasks above are pgvigil's own' (902, 905).
#  O2 steps (L7) the read before T on SQL Server says the before-0265 note too.
#  O2e (M1) SQL Server Running queries: Earlier (the slider, no navigation), then tick: own=1 and at= in the address, the
#     snapshot shown the earlier one. O2f (L5) wait=LCK_M_S: '(2 hidden in this snapshot)'.
#  NOT PROVEN: L1 (Longest wait follows the switch) - the staged read's longest task is a shown one; L4 (the alert page's
#  marks) - the demo's alerts read snapshots stored before 0265 (no is_own); a strip drag carrying own=1 - the strip
#  calls the slider's own load() (read from the code). Each traced from the code.
#  Red on rel-viewsb's base (the server halves, no page wiring): O1, O2, O2b-O2d FAIL 'no own switch'; O3 FAIL (no own=1
#  on its reads); O4 FAIL (the pick is 902 / 70002); O9 not reached (it runs inside O1, which stops at 'no own switch').
set -uo pipefail
: "${PGVIGIL_ADMIN_DSN:?}"
cd "$(dirname "$0")/.."
SUF=$RANDOM; REPO=pgvigil_op_$SUF; U1=op$SUF; U1PW=a$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 || echo "CLEANUP: $REPO not dropped" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go psql curl python3 ss node npm chromium rsync; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}
SRC=$WORK/src; mkdir -p "$SRC"
rsync -a --exclude .git --exclude web/node_modules --exclude bin ./ "$SRC/" || fail "copy the tree"
for p in proof-views-wiring.patch proof-b24own-wiring.patch; do
  if [[ -f "$SRC/scripts/$p" ]] && (cd "$SRC" && git apply --check "scripts/$p" 2>/dev/null); then
    (cd "$SRC" && git apply "scripts/$p") || fail "the wiring patch $p"
    echo "wiring applied to the copy: $p"
  fi
done
(cd "$SRC/web" && npm ci --silent --no-audit --no-fund >/dev/null 2>&1 && npm run build --silent >/dev/null 2>"$WORK/web-build.err") || { tail -20 "$WORK/web-build.err" >&2; fail "the web bundle (npm ci; npm run build)"; }
BIN=$WORK/pgvigil
(cd "$SRC" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "go build"

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null || fail "create database"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
"$BIN" demo -dsn "$PGVIGIL_REPO_DSN" -days 7 > "$WORK/demo.log" 2>&1 || { tail -5 "$WORK/demo.log" >&2; fail "the demo seed"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/cfg.yaml"; CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { tail -5 "$WORK/migrate.out" >&2; fail "migrate"; }
PGVIGIL_PASSWORD=$U1PW "$BIN" user add -config "$CFG" "$U1" >/dev/null 2>&1 || fail "user add"
IMS=$(q "select s.instance_id from pgvigil.mssql_requests_summary s join pgvigil.instances i using (instance_id) where i.is_active and i.engine = 'sqlserver' group by 1 order by 1 limit 1")
IPG=$(q "select s.instance_id from pgvigil.activity_summary s join pgvigil.instances i using (instance_id) where i.is_active and i.engine <> 'sqlserver' group by 1 order by 1 limit 1")
[[ -n $IMS && -n $IPG ]] || fail "setup: the demo has no SQL Server instance with requests ($IMS) or no PostgreSQL instance with activity ($IPG)"
T=$(q "select date_trunc('second', now())")

# the staged read T: each row from a template row of the same instance, its fields overridden (jsonb_populate_record)
psql "$PGVIGIL_REPO_DSN" -Xq -v ON_ERROR_STOP=1 > "$WORK/stage.out" 2>&1 <<SQL || { cat "$WORK/stage.out" >&2; fail "staging read T"; }
\set t '''$T'''
BEGIN;
-- SQL Server: the summary, the requests, the waiting read
INSERT INTO pgvigil.mssql_requests_summary
SELECT (jsonb_populate_record(null::pgvigil.mssql_requests_summary, to_jsonb(s) || jsonb_build_object('snapshot_at', :t::timestamptz, 'server_utc', :t::timestamptz,
        'sessions', 5, 'requests', 3, 'blocked', 1, 'heads', 1, 'longest_wait_ms', 5000))).*
  FROM (SELECT * FROM pgvigil.mssql_requests_summary WHERE instance_id = $IMS ORDER BY snapshot_at DESC LIMIT 1) s;
INSERT INTO pgvigil.mssql_requests
SELECT (jsonb_populate_record(null::pgvigil.mssql_requests, to_jsonb(r) || o || jsonb_build_object('snapshot_at', :t::timestamptz))).*
  FROM (SELECT * FROM pgvigil.mssql_requests WHERE instance_id = $IMS ORDER BY snapshot_at DESC LIMIT 1) r,
       (SELECT jsonb_build_object('blocking_session_id', 0, 'open_tran', 0, 'transaction_id', null, 'tran_start', null, 'tran_log_bytes', null,
               'granted_memory_kb', 0, 'tempdb_alloc_kb', 0, 'tempdb_current_kb', 0, 'head_session_id', null, 'chain_depth', null,
               'victims', null, 'longest_victim_wait_ms', null, 'in_cycle', false, 'chain_note', null, 'wait_is_benign', false,
               'is_user_process', true, 'is_implicit_tran', false) || x AS o
          FROM (VALUES
            (jsonb_build_object('session_id', 901, 'request_id', null, 'status', 'sleeping', 'command', null, 'wait_type', null, 'wait_ms', null,
               'elapsed_ms', null, 'start_time', null, 'last_request_end', :t::timestamptz - interval '5 seconds', 'program_name', 'pgvigil',
               'login_name', 'pgvcol', 'is_own', true)),
            (jsonb_build_object('session_id', 902, 'request_id', 0, 'status', 'suspended', 'command', 'SELECT', 'wait_type', 'PAGEIOLATCH_SH', 'wait_ms', 20,
               'elapsed_ms', 40000, 'start_time', :t::timestamptz - interval '40 seconds', 'program_name', 'pgvigil', 'login_name', 'pgvcol', 'is_own', true)),
            (jsonb_build_object('session_id', 903, 'request_id', 0, 'status', 'running', 'command', 'UPDATE', 'wait_type', null, 'wait_ms', null,
               'elapsed_ms', 10000, 'start_time', :t::timestamptz - interval '10 seconds', 'program_name', 'OrderEntry', 'login_name', 'app', 'is_own', null,
               'open_tran', 1, 'tran_start', :t::timestamptz - interval '10 seconds')),
            (jsonb_build_object('session_id', 904, 'request_id', null, 'status', 'sleeping', 'command', null, 'wait_type', null, 'wait_ms', null,
               'elapsed_ms', null, 'start_time', null, 'program_name', 'pgvigil-x', 'login_name', 'someone', 'is_own', null)),
            (jsonb_build_object('session_id', 905, 'request_id', 0, 'status', 'suspended', 'command', 'SELECT', 'wait_type', 'LCK_M_S', 'wait_ms', 5000,
               'elapsed_ms', 5000, 'start_time', :t::timestamptz - interval '5 seconds', 'blocking_session_id', 903, 'program_name', 'pgvigil',
               'login_name', 'pgvcol', 'is_own', true))) v(x)) o;
-- the waiting read through its own import (the demo seeds none): the collector's payload shape, is_own on each task
SELECT pgvigil.import_mssql_waiting_tasks($IMS, :t::timestamptz, jsonb_build_array(
  jsonb_build_object('kind', 'summary', 'server_utc', :t::timestamptz, 'tasks', 3, 'stored', 3, 'sessions', 3, 'threadpool', 0,
                     'threadpool_longest_ms', null, 'decode_note', '', 'read_ms', 5),
  jsonb_build_object('kind', 'task', 'session_id', 902, 'exec_context_id', 0, 'wait_type', 'PAGEIOLATCH_SH', 'wait_ms', 20,
                     'request_status', 'suspended', 'command', 'SELECT', 'statement', 'SELECT 1 /* pgvigil */', 'is_own', true),
  jsonb_build_object('kind', 'task', 'session_id', 903, 'exec_context_id', 0, 'wait_type', 'WRITELOG', 'wait_ms', 3,
                     'request_status', 'running', 'command', 'UPDATE', 'statement', 'UPDATE dbo.orders SET n = n + 1', 'is_own', null),
  jsonb_build_object('kind', 'task', 'session_id', 905, 'exec_context_id', 0, 'wait_type', 'LCK_M_S', 'wait_ms', 5000,
                     'blocking_session_id', 903, 'blocking_exec_context_id', 0, 'resource_description', 'keylock hobtid=1',
                     'request_status', 'suspended', 'command', 'SELECT', 'statement', 'SELECT 2 /* pgvigil */', 'is_own', true)));
-- PostgreSQL: the summary and the sample
INSERT INTO pgvigil.activity_summary
SELECT (jsonb_populate_record(null::pgvigil.activity_summary, to_jsonb(s) || jsonb_build_object('snapshot_at', :t::timestamptz, 'total', 5, 'active', 3, 'idle_in_txn', 0))).*
  FROM (SELECT * FROM pgvigil.activity_summary WHERE instance_id = $IPG ORDER BY snapshot_at DESC LIMIT 1) s;
INSERT INTO pgvigil.activity_sample
SELECT (jsonb_populate_record(null::pgvigil.activity_sample, to_jsonb(a) || jsonb_build_object('backend_type', 'client backend', 'leader_pid', null,
        'blocking_pids', '{}'::int[], 'is_blocker', false, 'xact_start', null, 'backend_xmin', null) || x || jsonb_build_object('snapshot_at', :t::timestamptz))).*
  FROM (SELECT * FROM pgvigil.activity_sample WHERE instance_id = $IPG ORDER BY snapshot_at DESC LIMIT 1) a,
       (VALUES (jsonb_build_object('pid', 70001, 'application_name', 'pgvigil', 'usename', 'pgvcol', 'state', 'idle', 'wait_event_type', 'Client', 'wait_event', 'ClientRead',
                 'query_start', :t::timestamptz - interval '5 seconds', 'state_change', :t::timestamptz - interval '5 seconds', 'is_own', true)),
               (jsonb_build_object('pid', 70002, 'application_name', 'pgvigil', 'usename', 'pgvcol', 'state', 'active', 'wait_event_type', 'IO', 'wait_event', 'DataFileRead',
                 'query_start', :t::timestamptz - interval '40 seconds', 'state_change', :t::timestamptz - interval '40 seconds',
                 'xact_start', :t::timestamptz - interval '40 seconds', 'is_own', true)),
               (jsonb_build_object('pid', 70003, 'application_name', 'orders', 'usename', 'app', 'state', 'active', 'wait_event_type', null, 'wait_event', null,
                 'query_start', :t::timestamptz - interval '10 seconds', 'state_change', :t::timestamptz - interval '10 seconds',
                 'xact_start', :t::timestamptz - interval '10 seconds', 'is_blocker', true, 'is_own', null)),
               (jsonb_build_object('pid', 70004, 'application_name', 'pgvigil-x', 'usename', 'someone', 'state', 'idle', 'wait_event_type', 'Client', 'wait_event', 'ClientRead',
                 'query_start', :t::timestamptz - interval '5 seconds', 'state_change', :t::timestamptz - interval '5 seconds', 'is_own', null)),
               (jsonb_build_object('pid', 70005, 'application_name', 'pgvigil', 'usename', 'pgvcol', 'state', 'active', 'wait_event_type', 'Lock', 'wait_event', 'transactionid',
                 'blocking_pids', '{70003}'::int[], 'query_start', :t::timestamptz - interval '5 seconds', 'state_change', :t::timestamptz - interval '5 seconds',
                 'xact_start', :t::timestamptz - interval '5 seconds', 'is_own', true))) v(x);
-- O9's upgrade: 0265 applied one second before read T (the demo applies it when its seed starts and stamps its reads up
-- to the seed's end, so without this no read is from before it)
UPDATE pgvigil.schema_version SET applied_at = :t::timestamptz - interval '1 second' WHERE version LIKE '0265\_%';
COMMIT;
SQL
[[ $(q "select max(snapshot_at) < '$T'::timestamptz - interval '1 second' from pgvigil.activity_summary where instance_id = $IPG and snapshot_at < '$T'") == t ]] \
  || fail "setup: PostgreSQL instance $IPG has no read older than 0265's staged applied_at ($T - 1 s)"
[[ $(q "select max(snapshot_at) < '$T'::timestamptz - interval '1 second' from pgvigil.mssql_requests_summary where instance_id = $IMS and snapshot_at < '$T'") == t ]] \
  || fail "setup: SQL Server instance $IMS has no read older than 0265's staged applied_at ($T - 1 s)"
ok "setup: the demo fleet in $REPO; read $T staged on SQL Server instance $IMS and PostgreSQL instance $IPG; 0265 applied at T - 1 s"
# O10: the never-hidden tests answer true or false, never NULL (a NULL hide left a row out of the grid and out of the count)
O10=$(q "select coalesce(pgvigil.own_shown_pg('Client', false, 'idle', now(), now(), null, now())::text, 'NULL') || ' ' ||
               coalesce(pgvigil.own_shown_mssql(51, 0, null, false, null, null, 1, null, 0, 0, null, now())::text, 'NULL') || ' ' ||
               coalesce(pgvigil.own_shown_pg(null, false, null, null, null, null, now())::text, 'NULL')" 2>&1)
O10OK=0; [[ $O10 == 'false true false' ]] && O10OK=1
(( O10OK )) && ok "O10: own_shown_pg (idle, no transaction) false; own_shown_mssql (an open transaction of unknown age) true; own_shown_pg (no state yet) false" \
  || echo "FAIL O10: own_shown_pg / own_shown_mssql / own_shown_pg (no state) answered '$O10', want 'false true false'"

PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 150); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.2; done
kill -0 "$SRV" 2>/dev/null || { tail -5 "$WORK/serve.log" >&2; fail "serve exited"; }
J=$WORK/j
[[ $(curl -s -o /dev/null -w '%{http_code}' -c "$J" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$U1\",\"password\":\"$U1PW\"}" "$U/api/login") == 200 ]] || fail "the API login"

# O4: the fleet pick (curl)
curl -s -b "$J" -H 'X-Pgvigil: 1' "$U/api/running/fleet" > "$WORK/fleet.json"
GOT=$(python3 -c "
import json; d=json.load(open('$WORK/fleet.json')); t=d.get('rows') or d
rows=[dict(zip(t['columns'], r)) for r in (t.get('rows') or [])]
m={r['instance_id']: r.get('longest_stmt_session') for r in rows}
print(m.get($IMS), m.get($IPG))")
O4=0; [[ $GOT == "903 70003" ]] && O4=1
(( O4 )) && ok "O4: the fleet's longest statements: SQL Server 903, PostgreSQL 70003 (the own 40 s statements a page hides are skipped)" || echo "FAIL O4: the fleet's longest statements (SQL Server, PostgreSQL): $GOT, want 903 70003"

CDP=$(freeport)
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
OP_U=$U1 OP_PW=$U1PW OP_MS=$IMS OP_PG=$IPG OP_SHOTS=${PGVIGIL_OWN_SHOTS:-} node "$SRC/scripts/own-pages-check.mjs" "$CDP" "$U/" | tee "$WORK/check.txt"
rc=${PIPESTATUS[0]}
(( rc == 0 && O4 && O10OK )) || fail "own-pages-check: $(grep -c '^FAIL' "$WORK/check.txt") case(s) failed; O4 $( ((O4)) && echo ok || echo failed); O10 $( ((O10OK)) && echo ok || echo failed)"
echo "PASS: proof-b24own-pages"
