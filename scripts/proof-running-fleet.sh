#!/usr/bin/env bash
# Proof of Running queries in DBA Dash's shape (task 109): the fleet page (one row per instance's newest snapshot,
# both engines), a PostgreSQL instance's page (one line per session, the chain tree, Earlier / Later, the Blocked
# filter, the group-by), the SQL Server page in the same shape, and the shared statement viewer.
#
# Needs go, psql, chromium, node, python3, and
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_SHOTS      a folder: the pages' screenshots in both themes are saved there (default: none saved)
# The proof makes a throwaway repository database (random suffix), seeds the demo into it (one day), serves it on
# loopback on a random port, imports four instances of its own through the collectors' import functions
# (import_activity, import_mssql_requests), and drives a headless Chromium of its own over CDP. It stops the serve and
# the browser by their own pids and drops the database on every exit path; nothing that exists before the run is
# touched.
#
# Expected (written before the first run). S = the snapshot time the proof sets: the repository's now() minus 20 s.
# The proof's instances:
#   P1 PostgreSQL, two snapshots: S-60 s (two idle-in-transaction-free sessions) and S with nine sessions:
#      100 idle in transaction, transaction 600 s, its last statement an UPDATE (the head of a chain)
#      101 active, Lock transactionid, blocked by 100, query 120 s, a statement of over 80 characters
#      102 active, Lock tuple, blocked by 101, query 60 s
#      103 active, Lock transactionid, blocked by 100, query 30 s
#      104 active, LWLock, no blocker, query 10 s
#      105 active, IO DataFileRead, no blocker, query 300 s, transaction 300 s
#      106 and 107 active, Lock, each blocked by the other (a cycle: blocked, no head)
#      109 active, an IO wait whose blocking_pids still names 100 (not a Lock wait: not blocked)
#      its summary row: 9 sessions, 8 active, 1 idle in transaction
#   P2 PostgreSQL, one snapshot 600 s before S, one session, nothing blocked (stale)
#   P3 PostgreSQL, no snapshot at all
#   M  SQL Server, one snapshot at S (the server's clock S): 51 sleeping with an open transaction of 400 s and a last
#      batch of over 80 characters, the head of 52 (LCK_M_U 90 s, running 95 s) and 53 (LCK_M_S 40 s, behind 52);
#      54 running 200 s; 55 a request of 999 s waiting on idle background work (wait_is_benign); one blocking row
#      (head 51, 2 victims, the longest wait 90 s)
# A. /api/running/fleet: one row per active instance (the demo's fifteen and the proof's four), each once;
#    P1: postgres, sessions 9, active 8, idle_in_txn 1, blocked 5, heads 1, longest_wait_secs 120,
#        longest_stmt_secs 300, longest_stmt_session 105 with 105's statement, oldest_txn_secs 600, age 15-120 s;
#    P2: blocked 0, heads 0, longest_wait_secs null, age over 180 s; P3: snapshot_at null and every count null;
#    M:  sqlserver, sessions 5, active 4, idle_in_txn 1, blocked 2, heads 1, longest_wait_secs 90,
#        longest_stmt_secs 200 by session 54 (the benign 999 s request left out), oldest_txn_secs 400.
#    Every demo PostgreSQL row agrees with an independent read of its newest snapshot: blocked = the Lock waiters
#    that name a blocker, heads = the distinct heads pgvigil.blocking_chains() names; every demo SQL Server row's
#    blocked and heads = its newest mssql_requests_summary row's. The read answers in under 1 s.
# B. /api/running/snapshots for P1: at= omitted: shown S, earlier S-60, later null, latest S; at= S-30 s: shown S-60,
#    earlier null, later S; for P3 every step null; a bad at= and a missing instance are refused with 400.
# C. The fleet page #/running: one grid row per row of /api/running/fleet, none taller than 40 px (one line); the
#    status line begins 'Blocked sessions: <the sum of blocked> on <the instances with one>'; P2's age cell says
#    'stale' in a muted span; P3's snapshot cell says 'no snapshot'; P1's statement cell shows at most 83 characters;
#    'Blocked only' leaves exactly the instances with blocked over 0; a click on P1's sessions cell moves the address
#    to #/activity?i=<P1> with at= P1's snapshot time, and on M's to #/mssql_running?i=<M> with at=.
# D. P1's Running queries at S: the snapshot line names S; Earlier on, Later off; the sessions grid has 9 rows, none
#    taller than 40 px; the chain tree reads, in order, 100 (head, blocks 3), 101 (blocks 1), 102, 103, then 106 and
#    107 marked 'in a cycle (no head)'; the head's statement cell's title says it is the LAST statement; 101's
#    statement cell shows at most 83 characters, ending in '...'; the 'Blocked (5)' button pressed leaves 6 rows (the
#    five blocked and the head); unpressed, 'Group by state' folds the grid into 2 groups (active 8, idle in
#    transaction 1) and a group's name opens its 8 sessions; Earlier moves the address to at= S-60 s.
# E. The viewer: a click on 101's statement opens a modal dialog holding the whole statement (its full length) with
#    the focus inside it; Copy writes a result in its status line (Copied, or Not copied where the headless browser
#    refuses the clipboard); Escape closes and removes the dialog and the focus is back on the cell's button.
# F. M's Running queries at S: no paragraph on the page longer than 160 characters; at least two 'what is this'
#    buttons, each with a title; the sessions grid 5 rows, none taller than 40 px; every statement cell at most 83
#    characters; the status line begins 'Blocked sessions: 2'.
# G. Pages C, D and F render in the dark theme too (the same row counts); with PGVIGIL_SHOTS the screenshots of the
#    fleet page, P1's page, the viewer open, M's page and two demo instances' pages are saved in both themes.
# [review fold, expected before the rerun]
# H. M also has a snapshot at S - 3 h (one session, nothing blocked); the newest stays S, so A is unchanged.
#    H1. P1's page at S: 109 (an IO wait whose stale blocking_pids names 100) has an empty 'blocked by' cell.
#    H2. From P1's page at S-60 s: Later moves the address to at= S; Latest leaves no at= in the address.
#    H3. #/mssql_running?i=<M>&w=1h&at=<S - 3 h + 10 s>: the heading says 'the hour up to', the snapshot row names
#        S - 3 h, the sessions grid has 1 row.
#    H4. The viewer open again: a click 5 px inside its top-left corner (its own padding) leaves it open; a click
#        on the backdrop 10 px from the window's corner closes it.
#    H5. The Blocked filter pressed on P1's page; demo-rds-orders01's page opens with it unpressed (one state per
#        instance).
# NOT PROVEN HERE: an at= older than the 1,500 snapshots a long range's list keeps (the second widening rule: it
# needs a day of minute snapshots); the filter and group state across the 30-second redraw;
# the accessibility rules (scripts/proof-a11y.sh walks every tab once wired); the fleet read's cost
# at hundreds of instances; a screen reader's reading of the chain tree.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_runfleet_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""; MADE_DB=""
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  rc=$?
  [[ -n "$SRV" ]] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; } || true
  [[ -n "$CHR" ]] && { kill "$CHR" 2>/dev/null; wait "$CHR" 2>/dev/null; } || true
  [[ -n "$MADE_DB" ]] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $DB not dropped" >&2; }
  rm -rf "$WORK" || true
  exit $rc
}
trap cleanup EXIT
for t in chromium node psql python3 go curl; do command -v $t >/dev/null || fail "$t is not on this machine"; done

echo "== build, seed the demo into $DB (one day), serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null; MADE_DB=1
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$WORK/pgvigil" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 1 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 240); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in 240 s"; }
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }

echo "== the proof's four instances"
SUF=$RANDOM
S=$(q -c "select to_char((date_trunc('second', now()) - interval '20 s') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
P1=$(q -c "insert into pgvigil.instances (name, platform) values ('proof-run-$SUF-p1', 'onprem') returning instance_id")
P2=$(q -c "insert into pgvigil.instances (name, platform) values ('proof-run-$SUF-p2', 'onprem') returning instance_id")
P3=$(q -c "insert into pgvigil.instances (name, platform) values ('proof-run-$SUF-p3', 'onprem') returning instance_id")
M=$(q -c "insert into pgvigil.instances (name, platform, engine) values ('proof-run-$SUF-m', 'onprem', 'sqlserver') returning instance_id")
LONG101="UPDATE accounts SET balance = balance + 1, updated_at = now(), note = 'proof row one hundred and one' WHERE id = 7 AND region = 'west'"
LONG51="UPDATE dbo.Orders SET ShippedAt = SYSUTCDATETIME(), Carrier = N'proof carrier for session fifty-one' WHERE OrderId = 4711"
q -v S="$S" -v P1="$P1" -v P2="$P2" -v M="$M" -v L101="$LONG101" -v L51="$LONG51" <<'SQL' >/dev/null
-- one session row of import_activity's payload
CREATE TEMP TABLE pv (pid int, state text, wet text, we text, bp int[], qs int, xs int, h bigint, query text, bt text DEFAULT 'client backend', blocker boolean DEFAULT false);
INSERT INTO pv VALUES
  (100, 'idle in transaction', 'Client', 'ClientRead', NULL, 590, 600, 910000000100, 'UPDATE accounts SET balance = balance - 1 WHERE id = 7', 'client backend', true),
  (101, 'active', 'Lock', 'transactionid', '{100}', 120, 125, 910000000101, :'L101', 'client backend', true),
  (102, 'active', 'Lock', 'tuple', '{101}', 60, 65, 910000000102, 'UPDATE accounts SET balance = 0 WHERE id = 7', 'client backend', false),
  (103, 'active', 'Lock', 'transactionid', '{100}', 30, 31, 910000000103, 'DELETE FROM accounts WHERE id = 7', 'client backend', false),
  (104, 'active', 'LWLock', 'BufferContent', NULL, 10, NULL, 910000000104, 'SELECT count(*) FROM ledger', 'client backend', false),
  (105, 'active', 'IO', 'DataFileRead', NULL, 300, 300, 910000000105, 'SELECT sum(amount) FROM ledger WHERE posted_at > now() - interval ''1 year''', 'client backend', false),
  (106, 'active', 'Lock', 'transactionid', '{107}', 15, 15, 910000000106, 'UPDATE stock SET qty = qty - 1 WHERE sku = 1', 'client backend', true),
  (107, 'active', 'Lock', 'transactionid', '{106}', 14, 15, 910000000107, 'UPDATE stock SET qty = qty - 1 WHERE sku = 2', 'client backend', true),
  (109, 'active', 'IO', 'DataFileRead', '{100}', 3, NULL, 910000000109, 'SELECT * FROM audit_log', 'client backend', false);
SELECT pgvigil.import_activity(:P1, :'S'::timestamptz,
  (SELECT jsonb_agg(jsonb_build_object('kind', 'session', 'pid', pid, 'state', state, 'wait_event_type', wet, 'wait_event', we,
            'blocking_pids', to_jsonb(bp), 'query_start', :'S'::timestamptz - make_interval(secs => qs),
            'xact_start', CASE WHEN xs IS NOT NULL THEN :'S'::timestamptz - make_interval(secs => xs) END,
            'state_change', :'S'::timestamptz - make_interval(secs => greatest(qs - 10, 0)),
            'backend_start', :'S'::timestamptz - interval '1 hour', 'datname', CASE WHEN pid < 105 THEN 'shop' ELSE 'ledger' END,
            'usename', CASE WHEN pid % 2 = 0 THEN 'app_rw' ELSE 'app_batch' END, 'application_name', 'proof-app', 'client', '10.0.0.' || pid,
            'query_hash', h, 'query', query, 'backend_type', bt, 'is_blocker', blocker, 'backend_xmin_age', 40))
     FROM pv) || jsonb_build_array(jsonb_build_object('kind', 'summary', 'total', 9, 'active', 8, 'idle', 0, 'idle_in_txn', 1, 'waiting_lock', 5)));
SELECT pgvigil.import_activity(:P1, :'S'::timestamptz - interval '60 s', jsonb_build_array(
  jsonb_build_object('kind', 'session', 'pid', 200, 'state', 'active', 'query_start', :'S'::timestamptz - interval '61 s', 'query_hash', 910000000200, 'query', 'SELECT 1', 'backend_type', 'client backend'),
  jsonb_build_object('kind', 'session', 'pid', 201, 'state', 'active', 'query_start', :'S'::timestamptz - interval '62 s', 'query_hash', 910000000200, 'query', 'SELECT 1', 'backend_type', 'client backend'),
  jsonb_build_object('kind', 'summary', 'total', 2, 'active', 2, 'idle', 0, 'idle_in_txn', 0, 'waiting_lock', 0)));
SELECT pgvigil.import_activity(:P2, :'S'::timestamptz - interval '600 s', jsonb_build_array(
  jsonb_build_object('kind', 'session', 'pid', 300, 'state', 'active', 'query_start', :'S'::timestamptz - interval '601 s', 'query_hash', 910000000300, 'query', 'SELECT 2', 'backend_type', 'client backend'),
  jsonb_build_object('kind', 'summary', 'total', 1, 'active', 1, 'idle', 0, 'idle_in_txn', 0, 'waiting_lock', 0)));
SELECT pgvigil.import_mssql_requests(:M, :'S'::timestamptz, jsonb_build_array(
  jsonb_build_object('kind', 'summary', 'server_utc', :'S'::timestamptz, 'source', 'dmv', 'source_note', 'proof', 'memory_grants_pending', 0, 'read_ms', 12),
  jsonb_build_object('kind', 'text', 'sql_handle', '0x0200000051', 'stmt_start', 0, 'stmt_end', -1, 'statement', :'L51', 'full_chars', length(:'L51')),
  jsonb_build_object('kind', 'text', 'sql_handle', '0x0200000052', 'stmt_start', 0, 'stmt_end', -1, 'statement', 'UPDATE dbo.Orders SET Status = 2 WHERE OrderId = 4711', 'full_chars', 52),
  jsonb_build_object('kind', 'text', 'sql_handle', '0x0200000053', 'stmt_start', 0, 'stmt_end', -1, 'statement', 'SELECT Status FROM dbo.Orders WITH (UPDLOCK) WHERE OrderId = 4711', 'full_chars', 64),
  jsonb_build_object('kind', 'text', 'sql_handle', '0x0200000054', 'stmt_start', 0, 'stmt_end', -1, 'statement', 'SELECT CustomerId, SUM(Total) FROM dbo.Orders GROUP BY CustomerId', 'full_chars', 64),
  jsonb_build_object('kind', 'request', 'session_id', 51, 'status', 'sleeping', 'open_tran', 1, 'tran_start', :'S'::timestamptz - interval '400 s',
    'sql_handle', '0x0200000051', 'stmt_start', 0, 'stmt_end', -1, 'login_name', 'app_orders', 'program_name', 'OrdersService', 'database_name', 'Shop',
    'head_session_id', 51, 'chain_depth', 0, 'victims', 2, 'longest_victim_wait_ms', 90000, 'is_user_process', 1),
  jsonb_build_object('kind', 'request', 'session_id', 52, 'request_id', 0, 'status', 'suspended', 'command', 'UPDATE', 'wait_type', 'LCK_M_U', 'wait_ms', 90000,
    'blocking_session_id', 51, 'open_tran', 1, 'tran_start', :'S'::timestamptz - interval '95 s', 'elapsed_ms', 95000, 'sql_handle', '0x0200000052', 'stmt_start', 0, 'stmt_end', -1,
    'login_name', 'app_orders', 'program_name', 'OrdersService', 'database_name', 'Shop', 'head_session_id', 51, 'chain_depth', 1, 'is_user_process', 1),
  jsonb_build_object('kind', 'request', 'session_id', 53, 'request_id', 0, 'status', 'suspended', 'command', 'SELECT', 'wait_type', 'LCK_M_S', 'wait_ms', 40000,
    'blocking_session_id', 52, 'open_tran', 0, 'elapsed_ms', 41000, 'sql_handle', '0x0200000053', 'stmt_start', 0, 'stmt_end', -1,
    'login_name', 'report', 'program_name', 'Reports', 'database_name', 'Shop', 'head_session_id', 51, 'chain_depth', 2, 'is_user_process', 1),
  jsonb_build_object('kind', 'request', 'session_id', 54, 'request_id', 0, 'status', 'running', 'command', 'SELECT', 'elapsed_ms', 200000,
    'sql_handle', '0x0200000054', 'stmt_start', 0, 'stmt_end', -1, 'login_name', 'report', 'program_name', 'Reports', 'database_name', 'Shop', 'is_user_process', 1),
  jsonb_build_object('kind', 'request', 'session_id', 55, 'request_id', 0, 'status', 'background', 'command', 'BRKR TASK', 'wait_type', 'BROKER_TRANSMITTER',
    'wait_ms', 999000, 'wait_is_benign', true, 'elapsed_ms', 999000, 'is_user_process', 0),
  jsonb_build_object('kind', 'blocking', 'head_session_id', 51, 'victims', 2, 'longest_wait_ms', 90000)));
SELECT pgvigil.import_mssql_requests(:M, :'S'::timestamptz - interval '3 hours', jsonb_build_array(
  jsonb_build_object('kind', 'summary', 'server_utc', :'S'::timestamptz - interval '3 hours', 'source', 'dmv', 'source_note', 'proof', 'memory_grants_pending', 0, 'read_ms', 9),
  jsonb_build_object('kind', 'request', 'session_id', 61, 'request_id', 0, 'status', 'running', 'command', 'SELECT', 'elapsed_ms', 1500,
    'login_name', 'report', 'program_name', 'Reports', 'database_name', 'Shop', 'is_user_process', 1)));
SQL
echo "S=$S P1=$P1 P2=$P2 P3=$P3 M=$M"

echo "== A, B: the API"
U="http://127.0.0.1:$PORT"
T0=$(date +%s%N); curl -fsS "$U/api/running/fleet" > "$WORK/fleet.json"; T1=$(date +%s%N)
FLEET_MS=$(( (T1 - T0) / 1000000 ))
J=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["rows"]; print(json.dumps([dict(zip(d["columns"], r)) for r in d["rows"]]))' "$WORK/fleet.json")
q -v J="$J" > "$WORK/truth.json" <<'SQL'
-- the independent read of every demo row, at the snapshot the fleet row names
SELECT coalesce(json_agg(json_build_object('id', f.instance_id, 'engine', f.engine,
         'blocked', CASE WHEN f.engine = 'sqlserver'
                         THEN (SELECT s.blocked FROM pgvigil.mssql_requests_summary s WHERE s.instance_id = f.instance_id AND s.snapshot_at = f.snapshot_at)
                         ELSE (SELECT count(*) FROM pgvigil.activity_sample a WHERE a.instance_id = f.instance_id AND a.snapshot_at = f.snapshot_at
                                  AND a.wait_event_type = 'Lock' AND cardinality(a.blocking_pids) > 0) END,
         'heads', CASE WHEN f.engine = 'sqlserver'
                       THEN (SELECT s.heads FROM pgvigil.mssql_requests_summary s WHERE s.instance_id = f.instance_id AND s.snapshot_at = f.snapshot_at)
                       ELSE (SELECT count(DISTINCT c.head_pid) FROM pgvigil.blocking_chains(f.instance_id, f.snapshot_at) c) END)), '[]')
  FROM json_to_recordset(:'J'::json) AS f(instance_id int, instance text, engine text, snapshot_at timestamptz)
 WHERE f.instance LIKE 'demo-%';
SQL
ACTIVE=$(q -c "select count(*) from pgvigil.instances where is_active")
S30=$(q -c "select to_char(('$S'::timestamptz - interval '30 s') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
for at in "" "$S30"; do
  curl -fsS "$U/api/running/snapshots?instance=$P1${at:+&at=$at}" >> "$WORK/steps.json"; echo >> "$WORK/steps.json"
done
curl -fsS "$U/api/running/snapshots?instance=$P3" >> "$WORK/steps.json"; echo >> "$WORK/steps.json"
BAD_AT=$(curl -s -o /dev/null -w '%{http_code}' "$U/api/running/snapshots?instance=$P1&at=yesterday")
NO_INST=$(curl -s -o /dev/null -w '%{http_code}' "$U/api/running/snapshots")
python3 - "$WORK" "$S" "$P1" "$P2" "$P3" "$M" "$ACTIVE" "$FLEET_MS" "$BAD_AT" "$NO_INST" "$LONG101" <<'PY'
import json, sys
from datetime import datetime, timedelta
work, S, P1, P2, P3, M, active, ms, bad, noinst, long101 = sys.argv[1:]
fails = []
def check(cond, what):
    print(('ok   ' if cond else 'FAIL ') + what)
    if not cond: fails.append(what)
d = json.load(open(work + '/fleet.json'))['rows']
rows = [dict(zip(d['columns'], r)) for r in d['rows']]
by = {r['instance_id']: r for r in rows}
check(len(rows) == int(active) and len(by) == len(rows), f"A: one row per active instance ({len(rows)} rows, {active} active, {len(by)} distinct)")
ts = lambda v: datetime.fromisoformat(v) if v else None
Sdt = datetime.fromisoformat(S.replace('Z', '+00:00'))
p1, p2, p3, m = by[int(P1)], by[int(P2)], by[int(P3)], by[int(M)]
want = dict(engine='postgres', sessions=9, active=8, idle_in_txn=1, blocked=5, heads=1, longest_wait_secs=120, longest_stmt_secs=300, longest_stmt_session=105, oldest_txn_secs=600)
check(all(p1[k] == v for k, v in want.items()), 'A: P1 ' + ', '.join(f'{k} {p1[k]}' for k in want))
check(ts(p1['snapshot_at']) == Sdt and 15 <= p1['age_secs'] <= 120, f"A: P1 snapshot {p1['snapshot_at']}, age {p1['age_secs']} s")
check(p1['longest_stmt'] is not None and p1['longest_stmt'].startswith('SELECT sum(amount) FROM ledger'), f"A: P1 longest statement is 105's ({(p1['longest_stmt'] or '')[:40]})")
check(p2['blocked'] == 0 and p2['heads'] == 0 and p2['longest_wait_secs'] is None and p2['age_secs'] > 180, f"A: P2 blocked {p2['blocked']}, heads {p2['heads']}, longest wait {p2['longest_wait_secs']}, age {p2['age_secs']} s (stale)")
check(p3['snapshot_at'] is None and all(p3[k] is None for k in ('sessions', 'active', 'idle_in_txn', 'blocked', 'heads', 'age_secs')), 'A: P3 no snapshot, every count null')
want = dict(engine='sqlserver', sessions=5, active=4, idle_in_txn=1, blocked=2, heads=1, longest_wait_secs=90, longest_stmt_secs=200, longest_stmt_session=54, oldest_txn_secs=400)
check(all(m[k] == v for k, v in want.items()), 'A: M ' + ', '.join(f'{k} {m[k]}' for k in want))
truth = json.load(open(work + '/truth.json'))
bad_rows = [t for t in truth if by[t['id']]['blocked'] != t['blocked'] or by[t['id']]['heads'] != t['heads']]
check(not bad_rows and len(truth) == 15, f"A: {len(truth)} demo rows agree with the independent read (blocked, heads); disagree: {bad_rows}")
check(any(t['blocked'] for t in truth), 'A: the demo has at least one instance with a blocked session (the check above is not vacuous)')
check(int(ms) < 1000, f'A: the fleet read took {ms} ms')
st = [json.loads(l) for l in open(work + '/steps.json') if l.strip()]
step = lambda j: {k: ts(v) for k, v in dict(zip(j['steps']['columns'], j['steps']['rows'][0])).items()}
a, b, c = step(st[0]), step(st[1]), step(st[2])
E = Sdt - timedelta(seconds=60)
check(a == dict(shown=Sdt, earlier=E, later=None, latest=Sdt), f'B: P1 latest steps {a}')
check(b == dict(shown=E, earlier=None, later=Sdt, latest=Sdt), f'B: P1 at S-30 steps {b}')
check(all(v is None for v in c.values()), f'B: P3 steps all null {c}')
check(bad == '400' and noinst == '400', f'B: a bad at= -> {bad}, no instance -> {noinst}')
open(work + '/api.ok', 'w').write('1' if not fails else '0')
PY
[[ $(cat "$WORK/api.ok") == 1 ]] || fail "the API checks"

echo "== C-G: the pages in a headless Chromium on CDP $CDP"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
DEMO_PG=$(q -c "select instance_id from pgvigil.instances where name = 'demo-rds-orders01'")
DEMO_MS=$(q -c "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'")
cat > "$WORK/ui.mjs" <<'JS'
const a = JSON.parse(process.argv[2]);
const fs = await import('node:fs');
const fleet = JSON.parse(fs.readFileSync(a.work + '/fleet.json', 'utf8')).rows;
const frows = fleet.rows.map(r => Object.fromEntries(fleet.columns.map((c, i) => [c, r[i]])));
const list = await (await fetch(`http://127.0.0.1:${a.cdp}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 15000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await ev(expr)) return true; await sleep(150); } return false; };
let fails = 0;
const check = (cond, what) => { console.log((cond ? 'ok   ' : 'FAIL ') + what); if (!cond) fails++; };
const go = async (hash, ready) => { await ev(`document.querySelector('main')?.replaceChildren(); 'ok'`); await cmd('Page.navigate', { url: a.u + '/' + hash }); await sleep(400); return until(ready); };
const shot = async (name, theme) => {
  if (!a.shots) return;
  const d = await cmd('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${a.shots}/running-${name}-${theme}.png`, Buffer.from(d.result.data, 'base64'));
};
// tallest body row of the grid under sel, and the row count
const rowsOf = sel => ev(`(() => { const t = document.querySelector(${JSON.stringify(sel)}); if (!t) return null; const rs = [...t.querySelectorAll('tbody tr')]; return { n: rs.length, max: Math.max(0, ...rs.map(r => r.getBoundingClientRect().height)) }; })()`);
const iso = v => new Date(v).toISOString();
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
for (const theme of ['light', 'dark']) {
  await go('#/summary', `!!document.querySelector('main table')`);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); sessionStorage.clear(); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  const T = `[${theme}] `;
  // C. the fleet page
  check(await go('#/running', `!!document.querySelector('.running-fleet table')`), T + 'C: the fleet page rendered');
  const fr = await rowsOf('.running-fleet table');
  check(fr && fr.n === frows.length && fr.max <= 40, T + `C: ${fr?.n} rows (API ${frows.length}), the tallest ${fr?.max} px`);
  // the status line against the grid it heads (the demo moves every minute: the API read of part A can be a minute older)
  const bcol = await ev(`(() => { const t = document.querySelector('.running-fleet table'); const i = [...t.querySelectorAll('thead th')].map(x => x.textContent).indexOf('blocked'); return [...t.querySelectorAll('tbody tr')].map(r => Number(r.cells[i].textContent.replace(/[^0-9]/g, '')) || 0); })()`);
  const blocked = bcol.reduce((s, n) => s + n, 0), withB = bcol.filter(n => n > 0).length;
  const status = await ev(`document.querySelector('.running-status')?.textContent ?? ''`);
  check(status.startsWith(`Blocked sessions: ${blocked} on ${withB} instance(s)`), T + `C: status line '${status.slice(0, 90)}'`);
  const cellOf = (name, col) => `(() => { const t = document.querySelector('.running-fleet table'); const h = [...t.querySelectorAll('thead th')].map(x => x.textContent); const i = h.indexOf(${JSON.stringify(col)}); const tr = [...t.querySelectorAll('tbody tr')].find(r => r.cells[0].textContent === ${JSON.stringify(name)}); return tr ? tr.cells[i] : null; })()`;
  check(await ev(`(() => { const c = ${cellOf(a.n2, 'age')}; return !!c && /stale/.test(c.textContent) && !!c.querySelector('span.meta'); })()`), T + 'C: P2 age cell says stale, muted');
  check(await ev(`(${cellOf(a.n3, 'snapshot')})?.textContent === 'no snapshot'`), T + 'C: P3 snapshot cell says no snapshot');
  const st1 = await ev(`(${cellOf(a.n1, 'statement')})?.textContent ?? ''`);
  check(st1.length > 0 && st1.length <= 83, T + `C: P1 statement cell ${st1.length} characters`);
  await ev(`[...document.querySelectorAll('button.toggle')].find(b => b.textContent === 'Blocked only').click(); 'ok'`);
  const fb = await rowsOf('.running-fleet table');
  check(fb && fb.n === withB, T + `C: Blocked only leaves ${fb?.n} rows (instances with blocked: ${withB})`);
  await ev(`[...document.querySelectorAll('button.toggle')].find(b => b.textContent === 'Blocked only').click(); 'ok'`);
  await shot('fleet', theme);
  await ev(`(${cellOf(a.n1, 'sessions')}).click(); 'ok'`);
  await until(`location.hash.startsWith('#/activity?')`, 3000);
  const h1 = await ev('location.hash'), q1 = new URLSearchParams(h1.split('?')[1]);
  check(h1.startsWith('#/activity?') && q1.get('i') === String(a.p1) && q1.get('at') && iso(q1.get('at')) === iso(a.s), T + `C: P1's row opens ${h1}`);
  await go('#/running', `!!document.querySelector('.running-fleet table')`);
  await ev(`(${cellOf(a.nm, 'sessions')}).click(); 'ok'`);
  await until(`location.hash.startsWith('#/mssql_running?')`, 3000);
  const h2 = await ev('location.hash'), q2 = new URLSearchParams(h2.split('?')[1]);
  check(h2.startsWith('#/mssql_running?') && q2.get('i') === String(a.m) && q2.get('at') && iso(q2.get('at')) === iso(a.s), T + `C: M's row opens ${h2}`);
  // D. P1's page at S
  check(await go(`#/activity?i=${a.p1}&w=1h&at=${encodeURIComponent(a.s)}`, `!!document.querySelector('.folded table')`), T + 'D: P1 page rendered');
  const snap = await ev(`document.querySelector('.snap-time')?.textContent ?? ''`);
  const btn = l => `[...document.querySelectorAll('.picker button')].find(b => b.textContent === ${JSON.stringify(l)})`;
  const want = await ev(`new Date(${JSON.stringify(a.s)}).toLocaleString(undefined, { hour12: false })`);
  check(snap === 'Snapshot ' + want && await ev(`!${btn('Earlier')}.disabled && ${btn('Later')}.disabled`), T + `D: '${snap}', Earlier on, Later off`);
  const sr = await rowsOf('.folded table');
  check(sr && sr.n === 9 && sr.max <= 40, T + `D: sessions ${sr?.n} rows, the tallest ${sr?.max} px`);
  const tree = await ev(`[...document.querySelectorAll('.chain-tree tbody tr')].map(r => [r.cells[0].textContent.replace(/[^0-9]/g, ''), r.cells[1].textContent, r.cells[2].textContent].join('|'))`);
  check(JSON.stringify(tree) === JSON.stringify(['100|head|3', '101|blocked, and blocks|1', '102|blocked|', '103|blocked|', '106|in a cycle (no head)|1', '107|in a cycle (no head)|1']), T + `D: tree ${JSON.stringify(tree)}`);
  const headTitle = await ev(`document.querySelector('.chain-tree tbody tr button.sqlcell')?.title ?? ''`);
  check(/LAST statement/.test(headTitle), T + `D: the head's statement title '${headTitle.slice(0, 60)}'`);
  const sessCell = pid => `[...document.querySelectorAll('.folded table tbody tr')].find(r => r.cells[0].textContent === '${pid}')?.querySelector('button.sqlcell')`;
  const c101 = await ev(`${sessCell(101)}?.textContent ?? ''`);
  check(c101.length <= 83 && c101.endsWith('...'), T + `D: 101's statement cell ${c101.length} characters '${c101.slice(-12)}'`);
  const bb = `[...document.querySelectorAll('.folded button.toggle')][0]`;
  check(await ev(`${bb}.textContent`) === 'Blocked (5)', T + 'D: the Blocked (5) button');
  await ev(`${bb}.click(); 'ok'`);
  const br = await rowsOf('.folded table');
  check(br?.n === 6, T + `D: Blocked pressed leaves ${br?.n} rows`);
  await ev(`${bb}.click(); (() => { const sel = document.querySelector('.folded select'); sel.value = 'state'; sel.dispatchEvent(new Event('change')); })(); 'ok'`);
  const groups = await ev(`[...document.querySelectorAll('.folded table tbody tr')].map(r => r.cells[0].textContent + '=' + r.cells[1].textContent)`);
  check(JSON.stringify(groups) === JSON.stringify(['active=8', 'idle in transaction=1']), T + `D: grouped by state ${JSON.stringify(groups)}`);
  await ev(`document.querySelector('.folded table tbody tr button').click(); 'ok'`);
  const gr = await rowsOf('.folded table');
  check(gr?.n === 8, T + `D: the group 'active' opens ${gr?.n} sessions`);
  await ev(`(() => { const sel = document.querySelector('.folded select'); sel.value = ''; sel.dispatchEvent(new Event('change')); })(); 'ok'`);
  await shot('pg-instance', theme);
  // H1. a stale blocker of a non-Lock wait is no blocker
  const by109 = await ev(`(() => { const t = document.querySelector('.folded table'); const i = [...t.querySelectorAll('thead th')].map(x => x.textContent).indexOf('blocked by'); const r = [...t.querySelectorAll('tbody tr')].find(x => x.cells[0].textContent === '109'); return r ? r.cells[i].textContent : null; })()`);
  check(by109 === '', T + `H1: 109's blocked by '${by109}'`);
  // E. the viewer on 101's statement
  await ev(`(() => { const b = ${sessCell(101)}; b.focus(); b.click(); })(); 'ok'`);
  const open = await ev(`(() => { const d = document.querySelector('dialog.sqlview'); return d ? { open: d.open, modal: d.matches(':modal'), len: d.querySelector('pre').textContent.length, inside: d.contains(document.activeElement) } : null; })()`);
  check(open && open.open && open.modal && open.len === a.long101.length && open.inside, T + `E: the viewer ${JSON.stringify(open)} (whole statement ${a.long101.length})`);
  await shot('viewer', theme);
  await ev(`document.querySelector('dialog.sqlview .sqlview-copy').click(); 'ok'`);
  await until(`/opied/.test(document.querySelector('dialog.sqlview [role=status]')?.textContent ?? '')`, 3000);
  console.log(T + 'E: Copy says: ' + await ev(`document.querySelector('dialog.sqlview [role=status]')?.textContent ?? ''`));
  check(/opied/.test(await ev(`document.querySelector('dialog.sqlview [role=status]')?.textContent ?? ''`)), T + 'E: Copy wrote a result');
  for (const type of ['keyDown', 'keyUp']) await cmd('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 });
  await sleep(200);
  const closed = await ev(`({ gone: !document.querySelector('dialog.sqlview'), back: document.activeElement === ${sessCell(101)} })`);
  check(closed.gone && closed.back, T + `E: Escape closed it ${JSON.stringify(closed)}`);
  // H4. a click in the dialog's own padding keeps it; a click on the backdrop closes it
  await ev(`(() => { const b = ${sessCell(101)}; b.focus(); b.click(); })(); 'ok'`);
  const box = await ev(`(() => { const r = document.querySelector('dialog.sqlview').getBoundingClientRect(); return { x: r.left + 5, y: r.top + 5 }; })()`);
  const click = async (x, y) => { for (const type of ['mousePressed', 'mouseReleased']) await cmd('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }); await sleep(150); };
  await click(box.x, box.y);
  const kept = await ev(`!!document.querySelector('dialog.sqlview')?.open`);
  await click(10, 10);
  const gone = await ev(`!document.querySelector('dialog.sqlview')`);
  check(kept && gone, T + `H4: a click in the padding kept it (${kept}), a backdrop click closed it (${gone})`);
  await ev(`${btn('Earlier')}.click(); 'ok'`);
  await until(`new URLSearchParams(location.hash.split('?')[1]).get('at') !== ${JSON.stringify(a.s)}`, 3000);
  const ea = new URLSearchParams((await ev('location.hash')).split('?')[1]).get('at');
  check(ea && iso(ea) === iso(new Date(new Date(a.s).getTime() - 60000)), T + `D: Earlier moves to at=${ea}`);
  // H2. Later and Latest from S-60 (the page at S-60 rendered first: its snapshot line names S-60)
  const s60 = new Date(Date.parse(a.s) - 60000).toISOString();
  await until(`document.querySelector('.snap-time')?.textContent === 'Snapshot ' + new Date(${JSON.stringify(s60)}).toLocaleString(undefined, { hour12: false })`, 8000);
  await ev(`${btn('Later')}.click(); 'ok'`);
  await until(`new URLSearchParams(location.hash.split('?')[1]).get('at') !== ${JSON.stringify(ea)}`, 3000);
  const la = new URLSearchParams((await ev('location.hash')).split('?')[1]).get('at');
  await until(`document.querySelector('.snap-time')?.textContent === 'Snapshot ' + new Date(${JSON.stringify(a.s)}).toLocaleString(undefined, { hour12: false })`, 8000);
  await ev(`${btn('Latest')}.click(); 'ok'`);
  await until(`!new URLSearchParams(location.hash.split('?')[1]).has('at')`, 3000);
  const lt = new URLSearchParams((await ev('location.hash')).split('?')[1]);
  check(la && iso(la) === iso(a.s) && !lt.has('at'), T + `H2: Later -> at=${la}, Latest -> at= ${lt.has('at') ? 'still there' : 'gone'}`);
  // H5. the Blocked filter is one instance's
  check(await go(`#/activity?i=${a.p1}&w=1h&at=${encodeURIComponent(a.s)}`, `!!document.querySelector('.folded table')`), T + 'H5: P1 page again');
  await ev(`${bb}.click(); 'ok'`);
  check(await go(`#/activity?i=${a.dpg}`, `!!document.querySelector('.folded table')`), T + 'H5: the demo page');
  check(await ev(`${bb}.getAttribute('aria-pressed')`) === 'false', T + 'H5: Blocked unpressed on another instance');
  // F. M's page
  check(await go(`#/mssql_running?i=${a.m}&w=1h&at=${encodeURIComponent(a.s)}`, `!!document.querySelector('.folded table')`), T + 'F: M page rendered');
  const longest = await ev(`Math.max(0, ...[...document.querySelectorAll('main p')].map(p => p.textContent.length))`);
  check(longest <= 160, T + `F: the longest paragraph ${longest} characters`);
  const whats = await ev(`[...document.querySelectorAll('main button.whatis')].map(b => b.title.length)`);
  check(whats.length >= 2 && whats.every(n => n > 20), T + `F: ${whats.length} 'what is this' buttons with titles`);
  const mr = await rowsOf('.folded table');
  check(mr?.n === 5 && mr.max <= 40, T + `F: sessions ${mr?.n} rows, the tallest ${mr?.max} px`);
  const mcells = await ev(`[...document.querySelectorAll('main button.sqlcell')].map(b => b.textContent.length)`);
  check(mcells.length >= 5 && mcells.every(n => n <= 83), T + `F: statement cells ${JSON.stringify(mcells)}`);
  const ms = await ev(`document.querySelector('.running-status')?.textContent ?? ''`);
  check(ms.startsWith('Blocked sessions: 2'), T + `F: status '${ms.slice(0, 70)}'`);
  await shot('mssql-instance', theme);
  // H3. an at= before the range: the hour up to it
  const old = new Date(Date.parse(a.s) - 3 * 3600e3 + 10e3).toISOString();
  check(await go(`#/mssql_running?i=${a.m}&w=1h&at=${encodeURIComponent(old)}`, `!!document.querySelector('.folded table')`), T + 'H3: M page at S-3h rendered');
  const h3 = await ev(`({ h: document.querySelector('main h2')?.textContent ?? '', s: document.querySelector('.snap-time')?.textContent ?? '', n: document.querySelectorAll('.folded table tbody tr').length,
    want: 'Snapshot ' + new Date(${JSON.stringify(new Date(Date.parse(a.s) - 3 * 3600e3).toISOString())}).toLocaleString(undefined, { hour12: false }) })`);
  check(h3.h.includes('the hour up to') && h3.s === h3.want && h3.n === 1, T + `H3: ${JSON.stringify(h3)}`);
  // the demo's own instances, for the record
  if (a.shots) {
    await go(`#/activity?i=${a.dpg}`, `!!document.querySelector('.folded table')`); await shot('demo-pg', theme);
    await go(`#/mssql_running?i=${a.dms}`, `!!document.querySelector('.folded table')`); await shot('demo-mssql', theme);
  }
}
ws.close();
console.log(fails ? `${fails} UI check(s) failed` : 'UI: every check passed');
process.exit(fails ? 1 : 0);
JS
ARGS=$(python3 -c 'import json,sys; print(json.dumps(dict(zip(["work","cdp","u","s","p1","m","n1","n2","n3","nm","long101","shots","dpg","dms"], sys.argv[1:]))))' \
  "$WORK" "$CDP" "$U" "$S" "$P1" "$M" "proof-run-$SUF-p1" "proof-run-$SUF-p2" "proof-run-$SUF-p3" "proof-run-$SUF-m" "$LONG101" "${PGVIGIL_SHOTS:-}" "$DEMO_PG" "$DEMO_MS")
node "$WORK/ui.mjs" "$ARGS" || fail "the UI checks"
echo "OK: running queries proven (API and pages, both themes); the fleet read took ${FLEET_MS} ms"
