#!/usr/bin/env bash
# Proof of blocking counted in waits, the hour arm, the monitor's own deadlocks left out, the spike against the hour's
# usual, and the PostgreSQL deadlock finding (migration 0165; internal/web/q_healthcal.go, q_ack.go; web/src/healthcal.ts).
#
# Runs on a box with docker (no local server): it starts its own SQL Server 2022 container (as root, a random sa password
# that is never printed) and its own PostgreSQL container (trust on 127.0.0.1), and removes both on every exit path.
# Needs: docker, psql, curl, python3, and
#   PGVIGIL_BIN   the binary (default bin/pgvigil) of the tree under proof, its bundle current
#   PGVIGIL_B10_MSSQL_IMAGE / PGVIGIL_B10_PG_IMAGE   default mcr.microsoft.com/mssql/server:2022-latest / postgres:18
# The SQL Server part is the real path (the printed Extended Events script run by sa as a DBA would, the blocked process
# threshold at 5 s on the proof's own container); every other part is arithmetic on rows the proof writes into instances
# of its own (names proof-b10-*), so each rule is held exactly and the run is short.
#
# A wait (PerformanceMonitor 3.13's rule): one (blocked, blocking) pair whose start, the event's time less its wait, is
# within 2 s of the pair's previous start; a self-wait (blocked = blocking) is no wait. SQL Server: the blocked-process
# reports; for an hour with none, the blocked rows of the requests snapshots. PostgreSQL: a session's Lock waits in
# activity_sample, split where a sample is missed (a gap over 1.5 sample intervals, the median gap between snapshots).
#
# Expected (written before the first run; RED = what the tree before this change does):
#  A. ONE WAIT, real. A head holds a row lock 80 s, a waiter blocks behind it from 2 s in: mssql_blocked_reports holds
#     12 or more reports of that pair; pgvigil.mssql_block_waits(instance, from, to) gives ONE row for the pair, its
#     wait at least 70 s, its source 'report'; GET /api/healthcal's day and GET /api/ack's live part count blocking 1 for
#     the instance. RED: mssql_block_waits does not exist; the day and the live part count the reports (count > 1).
#  B. THE HOUR ARM, real: after A, 'blocking events in the last hour' (warning) for the instance, its detail '1 wait in
#     the last hour, the longest 7x.x s'. After the first read pgvigil.mssql_monitor_app holds the collector's own
#     APP_NAME() for the instance ('pgvigil'). RED: no such finding; no such table.
#  C. three waits of 25 s in the hour (synthetic, reports every 5 s): 3 waits; 'blocking events in the last hour'
#     shows, '3 waits in the last hour, the longest 25.0 s'. RED: no finding.
#  D. three waits of 12 s (synthetic): 3 waits, the day and the live part read 3; no hour finding. RED: 6 (the reports).
#  E. the hold: C's waits and a standing 'a blocking chain' (the newest requests snapshot, a head whose victims wait
#     40 s): the hour finding is not shown while the chain stands, 'a blocking chain' is (name unchanged); after a newer
#     snapshot with no chain, the hour finding shows. RED: no hour finding either way.
#  F. 0065's 'blocked-process reports naming the same head statement' keeps its name; on C its detail counts waits
#     ('3 wait(s) in the last hour'). RED: '15 report(s) in the last hour'.
#  G. no reports in the hour (the session stopped): requests snapshots 15 s apart show session 61 blocked by 55 in four
#     of them (waits 10 / 25 / 40 / 55 s: one start) and session 62 blocked by 55 in two whose starts are 9 s apart:
#     3 waits, source 'snapshot'; beside them session 63 in a 2 s LCK_M_S wait and session 64 in a 30 s PAGELATCH_EX
#     wait behind 55: no wait (under the threshold of 5 s; not a lock). RED: mssql_block_waits does not exist.
#  H. the monitor's own deadlocks: with mssql_monitor_app 'pgvigil' for the instance, a deadlock whose every victim's
#     program is 'pgvigil' is not counted, one with a user victim is, one with two victims (pgvigil and a user) is:
#     'deadlocks in the last hour' says '2 deadlock(s)', the day and the live part count 2; mssql_deadlocks still
#     holds 3. RED: 3. Then an import whose monitor_app row is empty (the driver's default name, go-mssqldb: a
#     connection string naming none) removes the stored name: the finding counts 3.
#  I. the spike: pgvigil.mssql_block_hourly seeded with 4 weeks of the same weekday and hour at 2 waits and 1
#     deadlock, the last hour at 9 waits and 4 deadlocks: 'blocking at 3x this hour''s usual' and 'deadlocks at 3x this
#     hour''s usual' (warning); a second instance with one week of history and 6 waits: the blocking one fires worded
#     as a first occurrence ('no usual yet'); a third with 4 weeks and 4 waits (under the floor of 5): none; a fourth with
#     4 weeks at 0 and 6 waits: fires, its detail 'none in this weekday and hour over the 4 weeks before' (never empty).
#     pgvigil.rollup_block_hourly(at) writes one row per instance and finished hour since its first sight (the hours
#     counted, not assumed), A's hour with its 1 wait, again a no-op; an hour is rolled once it ended 15 minutes ago (not
#     at 10 past the next hour, at 20 past); an instance first seen 3 days ago gets 24 hours per call (24, then 48).
#     RED: no table.
#  J. PostgreSQL (activity_sample every 15 s): pid 101 waits on a Lock in samples 0-60 s and again 105-135 s under the
#     same query_start (a 45 s gap, over two intervals): 2 waits; pid 102 waits 30 s once: 1; pgvigil.pg_block_waits
#     gives 3, the day and the live part 3, and the hour arm fires (3 waits, the longest 60 s). RED: 2 (one per query).
#     J2, sampled once a minute (snapshots at 0, 60, 61, 120, 180 s: the median gap 59 s): pid 104 in a Lock wait at 0 and
#     120 s and not waiting at 60 s = 2 waits; pid 106 in a Lock wait at 0, 60 and 120 s = 1 wait; 3 in all. RED: 5 (the
#     1 s near-duplicate as the smallest gap splits 106 into three; without it, 'two intervals' would merge 104's two).
#  K. PostgreSQL deadlocks (log_events kind 'deadlock'): a pair of statements not seen in 30 days fires 'a deadlock
#     between a new pair of statements' (warning) naming both; 5 deadlocks of a known pair in an hour fire 'deadlocks
#     in the last hour' (warning); 2 of a known pair: neither. RED: no PostgreSQL deadlock finding.
#  L. one window per wait: a SQL Server wait seen from 20 s before an hour's end to 20 s after it (reports every 5 s) and
#     a PostgreSQL one sampled across the same end: each function gives 0 for the hour before the end and 1 for the
#     hour after; a wait that ended 30 s before the end: 1 and 0. RED: 1 and 1 (counted in both windows).
#  M. the rollup's own door (pgvigil.import_block_hourly, which `pgvigil run` calls at 16 past each hour for every
#     engine): a PostgreSQL instance first seen 29 days ago with one Lock wait in the same weekday and hour 1, 2, 3 and 4
#     weeks back and 6 in the last finished hour, its hours written ONLY by the door called in time order (one call a
#     day: 24 hours a call, then 16 past the last hour): 'blocking at 3x this hour''s usual' fires off its floor - '6
#     waits in the hour from ..., 6.0 times its usual of 1.0', not 'no usual yet'. RED: no import_block_hourly.
#  N. two callers in the same minute, both a login IN ROLE pgvigil_collector (the door's reason: run's own login):
#     one holds the door 3 s, the other calls 1 s in: the second returns 0, the first writes the instance's hours,
#     each hour one row. RED: no import_block_hourly.
#  O. a capped call (p_limit 2), 3 hours later: each call but the last writes 2, the last fewer; the first call's
#     hours are the oldest (no later call writes an hour before them); an uncapped call after them writes 0, each
#     instance-hour one row. RED: no import_block_hourly.
#  P. the next call's wait, repo.NextBlockHourly's own SQL read from internal/repo/blockhourly.go: under TimeZone UTC
#     it lands at 16 past a UTC hour, under Asia/Kathmandu (+5:45) at 16 past the local hour (31 past UTC), within the
#     hour. RED: no such SQL.
#  (Not here: that `pgvigil run` calls the door - a run over the 16th minute would show the call.)
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
MIMG=${PGVIGIL_B10_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}; PIMG=${PGVIGIL_B10_PG_IMAGE:-postgres:18}
SUF=$RANDOM; ID=b$SUF; MCT=pgvb10ms_$SUF; PCT=pgvb10pg_$SUF; DB=pgvb10_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); L1=pgv_b10_$SUF; P1=$(pw)
CFG=$(mktemp); OUT=$(mktemp); DDL=$(mktemp)
MPORT=$((20000 + SUF % 10000)); PPORT=$((30000 + SUF % 10000)); PORT=$((40000 + SUF % 10000)); SRVPID=
bad=0
fail() { echo "FAIL: $*" >&2; exit 1; }
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (got '$1', want '$2')"; bad=$((bad + 1)); fi; }
cleanup() {
  rc=$?; set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" >/dev/null 2>&1
  docker rm -f "$MCT" "$PCT" >/dev/null 2>&1 || echo "CLEANUP: containers $MCT / $PCT not removed" >&2
  rm -f "$CFG" "$OUT" "$DDL" "$OUT.head" "$OUT.serve" "$OUT.n1" "${LF:-}"
  exit $rc
}
trap cleanup EXIT
export SQLCMDPASSWORD="$SAPW" MSSQL_SA_PASSWORD="$SAPW"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# the password by name from this shell's environment: never on a command line (ps) - docker inspect still shows the
# container's environment to the docker group while the container lives (the run's own container, removed at the end)
docker run -d --name "$MCT" --user root -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_MEMORY_LIMIT_MB=2048 -p "127.0.0.1:$MPORT:1433" "$MIMG" >/dev/null
docker run -d --name "$PCT" -e POSTGRES_HOST_AUTH_METHOD=trust -p "127.0.0.1:$PPORT:5432" "$PIMG" -c max_connections=300 >/dev/null
sq() { docker exec -e SQLCMDPASSWORD "$MCT" $SQLCMD -S localhost -U sa -C -I -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
work() { docker exec -e SQLCMDPASSWORD "$MCT" $SQLCMD -S localhost -U sa -C -I -d "$DB" "${@:2}" -Q "$1"; }
sqfile() { docker cp -q "$1" "$MCT:/tmp/b10_$SUF.sql"; docker exec -e SQLCMDPASSWORD "$MCT" $SQLCMD -S localhost -U sa -C -I -b -d master -i "/tmp/b10_$SUF.sql"; }
for i in $(seq 1 60); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 3; done; sq "SELECT 1" >/dev/null || fail "SQL Server did not start in 180 s"
for i in $(seq 1 30); do psql "host=127.0.0.1 port=$PPORT user=postgres" -XAtqc "select 1" >/dev/null 2>&1 && break; sleep 2; done
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$PPORT user=postgres dbname=postgres"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
# the login's password through a file copied into the container (sqlcmd -Q would show it in ps), removed at once
LF=$(umask 077; mktemp)
printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [%s]; GRANT VIEW ANY DEFINITION TO [%s]; CREATE DATABASE [%s];\n" "$L1" "$P1" "$L1" "$L1" "$DB" > "$LF"
sqfile "$LF" >/dev/null || { rm -f "$LF"; fail "the monitor login"; }
rm -f "$LF"; docker exec "$MCT" rm -f "/tmp/b10_$SUF.sql"
sq "CREATE TABLE dbo.b10 (id int PRIMARY KEY, v int); INSERT dbo.b10 VALUES (1, 0);" "$DB"
export MSSQL_MON_DSN="sqlserver://$L1:$P1@127.0.0.1:$MPORT?database=master&encrypt=true&TrustServerCertificate=true"
N1=proof-b10-ms-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N1
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
xe() { "$BIN" collect -config "$CFG" -once mssql_xe -instance "$N1" > "$OUT" 2>&1 || { cat "$OUT"; fail "$1: mssql_xe read"; }; }
fn() { [ "$(q "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname = '$1'")" != 0 ]; }
tab() { [ "$(q "select to_regclass('pgvigil.$1') is not null")" = t ]; }
# the findings as the pages read them; the slice's own view (blocking_findings) beside them until it is wired into
# pgvigil.findings (then read there, once)
fsrc() { if tab blocking_findings && [ "$(q "select pg_get_viewdef('pgvigil.findings'::regclass) like '%blocking_findings%'")" = f ]; then
    echo "(select instance_id, severity, setting, detail from pgvigil.findings union all select instance_id, severity, check_name, detail from pgvigil.blocking_findings)"
  else echo "(select instance_id, severity, setting, detail from pgvigil.findings)"; fi; }
finding() { q "select coalesce(string_agg(severity || '|' || detail, ' / '), '') from $(fsrc) f where instance_id = $1 and setting = '$2'"; }
has() { [ -n "$(q "select 1 from $(fsrc) f where instance_id = $1 and setting = '$2' limit 1")" ] && echo yes || echo no; }
waits() { if fn "$1"; then q "select count(*) from pgvigil.$1($2, now() - interval '1 hour', now())"; else echo "no $1"; fi; }
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login > "$OUT.serve" 2>&1 & SRVPID=$!
for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/health" && break; sleep 1; done
# the day's and the live part's blocking / deadlocks for an instance, from the routes the pages read: the calendar
# needs instance= and gives a table of days (columns + rows, no instance_id): the key summed over the month's days (the
# proof's rows lie within the last half hour: a run in the first half hour of a UTC month would read too few); the
# live part is a table with an instance_id column
api() {
  if [ "$1" = healthcal ]; then
    curl -s "http://127.0.0.1:$PORT/api/healthcal?instance=$2" | python3 -I -c '
import json, sys
d, key = json.load(sys.stdin), sys.argv[1]
t = d.get("days") or {}
cols, rows = t.get("columns") or [], t.get("rows") or []
print(sum(int(r[cols.index(key)] or 0) for r in rows) if key in cols else "none")' "$3"
    return
  fi
  # the live part (a table: columns + rows) narrowed by instance=; its row by the instance_id column
  curl -s "http://127.0.0.1:$PORT/api/$1?instance=$2" | python3 -I -c '
import json, sys
d, iid, key = json.load(sys.stdin), int(sys.argv[1]), sys.argv[2]
def tables(x):
    if isinstance(x, dict):
        if isinstance(x.get("columns"), list) and isinstance(x.get("rows"), list): yield x
        for y in x.values(): yield from tables(y)
    elif isinstance(x, list):
        for y in x: yield from tables(y)
v = [r[t["columns"].index(key)] for t in tables(d) if "instance_id" in t["columns"] and key in t["columns"]
     for r in t["rows"] if r[t["columns"].index("instance_id")] == iid]
print(v[-1] if v else "none")' "$2" "$3"
}
syn() {   # a synthetic instance of this proof (its engine: sqlserver or postgres): its id
  q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
       values ('proof-b10-$1-$SUF', '$( [ "$2" = sqlserver ] && echo sqlserver || echo onprem )', '{env:proofb10}', now(), now(), true, '$2') returning instance_id" | head -1
}
# the reports SQL Server writes for one wait: every 5 s while it lasts, its wait so far (the threshold 5 s)
reports() {   # instance, blocked, blocking, start (seconds before now), length (s), head statement
  q "select pgvigil.mssql_event_partition('mssql_blocked_reports', now());
     insert into pgvigil.mssql_blocked_reports (instance_id, event_at, event_key, snapshot_at, database_name, wait_ms, blocked_spid,
            blocking_spid, blocked_statement, blocking_statement, head_key)
     select $1, now() - make_interval(secs => $4) + make_interval(secs => k * 5), 'b10-$2-$3-$4-' || k, now(), 'b10', k * 5000, $2, $3,
            'UPDATE dbo.t SET v = 1', '$6', md5('$6')
       from generate_series(1, floor($5 / 5.0)::int) k" >/dev/null
}

echo "--- A. one wait, real (threshold 5 s on the proof's own server, the printed script run by sa)"
sq "EXEC sys.sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sys.sp_configure 'blocked process threshold (s)', 5; RECONFIGURE;" >/dev/null
"$BIN" mssql-xe -print -install-id "$ID" > "$DDL"
sqfile "$DDL" > "$OUT" 2>&1 || { cat "$OUT"; fail "A: the printed script"; }
xe A0
MSID=$(q "select instance_id from pgvigil.instances where name = '$N1'")
( work "BEGIN TRAN; UPDATE dbo.b10 SET v = 10 WHERE id = 1; SELECT @@SPID; WAITFOR DELAY '00:01:20'; ROLLBACK;" -h -1 -W > "$OUT.head" 2>&1 || true ) & W1=$!
sleep 2
( work "UPDATE dbo.b10 SET v = 11 WHERE id = 1;" > /dev/null 2>&1 || true ) & W2=$!
wait $W1 $W2; sleep 7; xe A
check "$(q "select count(*) >= 12 from pgvigil.mssql_blocked_reports where instance_id = $MSID and database_name = '$DB'")" t "A: 12 or more reports of the pair stored"
if fn mssql_block_waits; then
  check "$(q "select count(*) || '|' || bool_and(wait_ms >= 70000) || '|' || min(source) from pgvigil.mssql_block_waits($MSID, now() - interval '1 hour', now())")" "1|true|report" "A: the reports are ONE wait of 70 s or more"
else check "no mssql_block_waits" "1|true|report" "A: the reports are ONE wait of 70 s or more"; fi
check "$(api healthcal "$MSID" blocking)" 1 "A: the day counts 1 wait"
check "$(api ack "$MSID" blocking)" 1 "A: the live part counts 1 wait"
grep -q "waits/hr" web/src/healthcal.ts && echo "ok   A: healthcal.ts names 'waits/hr'" || { echo "FAIL A: healthcal.ts does not name 'waits/hr'"; bad=$((bad + 1)); }

echo "--- B. the hour arm, real; the monitor's own APP_NAME stored"
check "$(has "$MSID" 'blocking events in the last hour')" yes "B: one wait of 60 s or more fires 'blocking events in the last hour'"
check "$(finding "$MSID" 'blocking events in the last hour' | grep -cE '^warning\|1 wait in the last hour, the longest 7[0-9]\.[0-9] s')" 1 "B: warning, '1 wait in the last hour, the longest 7x.x s'"
if tab mssql_monitor_app; then check "$(q "select app_name from pgvigil.mssql_monitor_app where instance_id = $MSID")" pgvigil "B: the collector's APP_NAME() stored"
else check "no mssql_monitor_app" pgvigil "B: the collector's APP_NAME() stored"; fi

echo "--- C. three waits of 25 s"
C=$(syn c sqlserver); reports "$C" 71 70 1500 25 'BEGIN TRAN; UPDATE dbo.t'; reports "$C" 72 70 1000 25 'BEGIN TRAN; UPDATE dbo.t'; reports "$C" 73 70 500 25 'BEGIN TRAN; UPDATE dbo.t'
check "$(waits mssql_block_waits "$C")" 3 "C: three waits"
check "$(finding "$C" 'blocking events in the last hour')" "warning|3 waits in the last hour, the longest 25.0 s" "C: the hour arm fires"

echo "--- D. three waits of 12 s"
D=$(syn d sqlserver); reports "$D" 81 80 1500 12 'BEGIN TRAN; UPDATE dbo.u'; reports "$D" 82 80 1000 12 'BEGIN TRAN; UPDATE dbo.u'; reports "$D" 83 80 500 12 'BEGIN TRAN; UPDATE dbo.u'
check "$(waits mssql_block_waits "$D")" 3 "D: three waits"
check "$(api healthcal "$D" blocking)|$(api ack "$D" blocking)" "3|3" "D: the day and the live part read 3 waits"
check "$(has "$D" 'blocking events in the last hour')" no "D: three 12 s waits do not fire"

echo "--- E. the hold while 'a blocking chain' stands"
E=$(syn e sqlserver); reports "$E" 71 70 1500 25 'BEGIN TRAN; UPDATE dbo.t'; reports "$E" 72 70 1000 25 'BEGIN TRAN; UPDATE dbo.t'; reports "$E" 73 70 500 25 'BEGIN TRAN; UPDATE dbo.t'
q "select pgvigil.mssql_ensure_day_partition('mssql_blocking', now());   -- mssql_requests_summary is a plain table (0064): no partition
   insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, source, sessions, requests, blocked, heads, longest_wait_ms) values ($E, now() - interval '20 seconds', 'dmv', 5, 2, 1, 1, 40000);
   insert into pgvigil.mssql_blocking (instance_id, snapshot_at, head_session_id, victims, longest_wait_ms, in_snapshot) values ($E, now() - interval '20 seconds', 70, 1, 40000, true)" >/dev/null
check "$(has "$E" 'a blocking chain')|$(has "$E" 'blocking events in the last hour')" "yes|no" "E: 'a blocking chain' stands, the hour finding held"
q "insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, source, sessions, requests, blocked, heads, longest_wait_ms) values ($E, now(), 'dmv', 5, 0, 0, 0, 0)" >/dev/null
check "$(has "$E" 'a blocking chain')|$(has "$E" 'blocking events in the last hour')" "no|yes" "E: the chain gone, the hour finding shows"

echo "--- F. 0065's head-statement finding counts waits"
check "$(finding "$C" 'blocked-process reports naming the same head statement' | grep -c '^warning|3 wait(s) in the last hour')" 1 "F: its name kept, its detail '3 wait(s) in the last hour'"

echo "--- G. an hour with no reports: the requests snapshots"
G=$(syn g sqlserver)
q "select pgvigil.mssql_ensure_day_partition('mssql_requests', now());
   insert into pgvigil.mssql_requests (instance_id, snapshot_at, session_id, request_id, status, wait_type, wait_ms, blocking_session_id, is_user_process, database_name)
   select $G, t0 + make_interval(secs => k * 15), 61, 0, 'suspended', 'LCK_M_X', 10000 + k * 15000, 55, true, 'b10'
     from (select now() - interval '10 minutes' t0) x, generate_series(0, 3) k
   union all select $G, now() - interval '8 minutes', 62, 0, 'suspended', 'LCK_M_X', 5000, 55, true, 'b10'
   union all select $G, now() - interval '8 minutes' + interval '15 seconds', 62, 0, 'suspended', 'LCK_M_X', 11000, 55, true, 'b10'
   union all select $G, now() - interval '7 minutes', 63, 0, 'suspended', 'LCK_M_S', 2000, 55, true, 'b10'
   union all select $G, now() - interval '7 minutes', 64, 0, 'suspended', 'PAGELATCH_EX', 30000, 55, true, 'b10'" >/dev/null
check "$(waits mssql_block_waits "$G")" 3 "G: 61 one wait over four snapshots, 62 two (starts 9 s apart); 63 (2 s) and 64 (a page latch) none"
fn mssql_block_waits && check "$(q "select string_agg(distinct source, ',') from pgvigil.mssql_block_waits($G, now() - interval '1 hour', now())")" snapshot "G: source 'snapshot'"

echo "--- H. the monitor's own deadlocks left out"
H=$(syn h sqlserver)
tab mssql_monitor_app && q "insert into pgvigil.mssql_monitor_app (instance_id, app_name, read_at) values ($H, 'pgvigil', now())" >/dev/null
q "select pgvigil.mssql_event_partition('mssql_deadlocks', now());
   insert into pgvigil.mssql_deadlocks (instance_id, event_at, event_key, snapshot_at, source, process_count, victim_count, victim_program, processes)
   values ($H, now() - interval '30 minutes', 'b10-h1', now(), 'product', 2, 1, 'pgvigil', '[{\"victim\": true, \"program\": \"pgvigil\"}, {\"victim\": false, \"program\": \"app\"}]'),
          ($H, now() - interval '20 minutes', 'b10-h2', now(), 'product', 2, 1, 'app', '[{\"victim\": true, \"program\": \"app\"}, {\"victim\": false, \"program\": \"pgvigil\"}]'),
          ($H, now() - interval '10 minutes', 'b10-h3', now(), 'product', 3, 2, 'pgvigil', '[{\"victim\": true, \"program\": \"pgvigil\"}, {\"victim\": true, \"program\": \"app\"}, {\"victim\": false, \"program\": \"app\"}]')" >/dev/null
check "$(finding "$H" 'deadlocks in the last hour' | grep -c '2 deadlock(s) in the last hour')" 1 "H: 'deadlocks in the last hour' counts 2"
check "$(api healthcal "$H" deadlocks)|$(api ack "$H" deadlocks)" "2|2" "H: the day and the live part count 2"
check "$(q "select count(*) from pgvigil.mssql_deadlocks where instance_id = $H")" 3 "H: all 3 stay stored"
if tab mssql_monitor_app; then
  q "select pgvigil.import_mssql_xe($H, now(), '[{\"kind\": \"monitor_app\", \"app_name\": \"\"}]'::jsonb)" >/dev/null
  check "$(q "select count(*) from pgvigil.mssql_monitor_app where instance_id = $H")|$(finding "$H" 'deadlocks in the last hour' | grep -c '3 deadlock(s) in the last hour')" "0|1" "H: an empty name (the driver's default) removes the stored one: 3 counted"
fi

echo "--- I. the spike against the hour's usual"
if tab mssql_block_hourly; then
  I1=$(syn i1 sqlserver); I2=$(syn i2 sqlserver); I3=$(syn i3 sqlserver); I4=$(syn i4 sqlserver)
  q "insert into pgvigil.mssql_block_hourly (instance_id, hour, waits, deadlocks)
     select i, date_trunc('hour', now()) - interval '1 hour' - make_interval(weeks => w), 2, 1 from (values ($I1), ($I3)) v(i), generate_series(1, 4) w
     union all select $I2, date_trunc('hour', now()) - interval '1 hour' - interval '1 week', 2, 1
     union all select $I1, date_trunc('hour', now()) - interval '1 hour', 9, 4
     union all select $I2, date_trunc('hour', now()) - interval '1 hour', 6, 0
     union all select $I3, date_trunc('hour', now()) - interval '1 hour', 4, 0
     union all select $I4, date_trunc('hour', now()) - interval '1 hour' - make_interval(weeks => w), 0, 0 from generate_series(1, 4) w
     union all select $I4, date_trunc('hour', now()) - interval '1 hour', 6, 0" >/dev/null
  check "$(has "$I1" "blocking at 3x this hour''s usual")|$(has "$I1" "deadlocks at 3x this hour''s usual")" "yes|yes" "I: 9 waits and 4 deadlocks against 2 and 1 fire both"
  check "$(finding "$I2" "blocking at 3x this hour''s usual" | grep -c 'no usual yet')" 1 "I: one week of history fires on the floor, worded 'no usual yet'"
  check "$(has "$I3" "blocking at 3x this hour''s usual")" no "I: 4 waits are under the floor of 5"
  check "$(finding "$I4" "blocking at 3x this hour''s usual" | grep -c '^warning|6 waits in the hour from .*, none in this weekday and hour over the 4 weeks before$')" 1 "I: a usual of 0 and 6 waits: fires, its detail not empty"
  # the settle: the hour before T0 is rolled at T0 + 20 min, not at T0 + 10 min
  RS=$(syn rs sqlserver); q "update pgvigil.instances set first_seen = now() - interval '3 hours' where instance_id = $RS" >/dev/null
  T0=$(q "select date_trunc('hour', now())")
  rs() { q "select count(*) from pgvigil.mssql_block_hourly where instance_id = $RS and hour = '$T0'::timestamptz - interval '1 hour'"; }
  q "select pgvigil.rollup_block_hourly('$T0'::timestamptz + interval '10 minutes')" >/dev/null; S1=$(rs)
  q "select pgvigil.rollup_block_hourly('$T0'::timestamptz + interval '20 minutes')" >/dev/null; S2=$(rs)
  check "$S1|$S2" "0|1" "I: an hour is rolled once it ended 15 minutes ago (not at 10 past, at 20 past)"
  # A's instance: every finished hour since its first sight once, A's hour with its one wait (one fixed clock)
  q "delete from pgvigil.mssql_block_hourly where instance_id = $MSID" >/dev/null
  RT=$(q "select now() + interval '2 hours'")
  q "select pgvigil.rollup_block_hourly('$RT'::timestamptz)" >/dev/null; R1=$(q "select count(*) from pgvigil.mssql_block_hourly where instance_id = $MSID")
  q "select pgvigil.rollup_block_hourly('$RT'::timestamptz)" >/dev/null; R2=$(q "select count(*) from pgvigil.mssql_block_hourly where instance_id = $MSID")
  RE=$(q "select count(*) from pgvigil.instances i, generate_series(date_trunc('hour', i.first_seen), date_trunc('hour', '$RT'::timestamptz - interval '15 minutes') - interval '1 hour', interval '1 hour') g where i.instance_id = $MSID")
  RA=$(q "select coalesce((select waits from pgvigil.mssql_block_hourly where instance_id = $MSID and hour = (select date_trunc('hour', max(last_seen_at)) from pgvigil.mssql_block_waits($MSID, now() - interval '1 hour', now()))), -1)")
  check "$R1|$R2|$RA" "$RE|$RE|1" "I: the rollup writes each finished hour since the instance's first sight once ($RE), A's hour with its 1 wait"
  # the cap: 24 hours per instance per call
  RC=$(syn rc sqlserver); q "update pgvigil.instances set first_seen = now() - interval '3 days' where instance_id = $RC" >/dev/null
  rc() { q "select count(*) from pgvigil.mssql_block_hourly where instance_id = $RC"; }
  q "select pgvigil.rollup_block_hourly('$RT'::timestamptz)" >/dev/null; C1=$(rc)
  q "select pgvigil.rollup_block_hourly('$RT'::timestamptz)" >/dev/null; C2=$(rc)
  check "$C1|$C2" "24|48" "I: an instance first seen 3 days ago: 24 hours per call"
else check "no mssql_block_hourly" "yes" "I: the spike against the hour's usual"; fi

echo "--- J. PostgreSQL waits split at a gap"
J=$(syn j postgres)
q "select pgvigil.ensure_month_partition('activity_sample', now());
   insert into pgvigil.activity_sample (instance_id, snapshot_at, pid, backend_start, datname, usename, state, wait_event_type, wait_event, query_start, blocking_pids)
   select $J, t0 + make_interval(secs => s), 101, t0 - interval '1 hour', 'b10', 'app', 'active', 'Lock', 'transactionid', t0 - interval '5 seconds', '{100}'
     from (select date_trunc('minute', now()) - interval '20 minutes' t0) x, unnest(array[0, 15, 30, 45, 60, 105, 120, 135]) s
   union all
   select $J, t0 + make_interval(secs => s), 102, t0 - interval '1 hour', 'b10', 'app', 'active', 'Lock', 'tuple', t0 + interval '300 seconds', '{100}'
     from (select date_trunc('minute', now()) - interval '20 minutes' t0) x, unnest(array[300, 315, 330]) s" >/dev/null
check "$(waits pg_block_waits "$J")" 3 "J: 101 two waits (a 45 s gap), 102 one"
check "$(api healthcal "$J" blocking)|$(api ack "$J" blocking)" "3|3" "J: the day and the live part read 3"
check "$(has "$J" 'blocking events in the last hour')" yes "J: the hour arm fires on PostgreSQL (3 waits, the longest 60 s)"
J2=$(syn j2 postgres)
q "insert into pgvigil.activity_sample (instance_id, snapshot_at, pid, backend_start, datname, usename, state, wait_event_type, wait_event, query_start, blocking_pids)
   select $J2, t0 + make_interval(secs => v.s), v.p, t0 - interval '1 hour', 'b10', 'app', 'active', v.wt, v.we, t0 - interval '5 seconds', v.bp
     from (select date_trunc('minute', now()) - interval '30 minutes' t0) x,
          (values (104, 0, 'Lock', 'transactionid', '{100}'::int[]), (104, 60, null, null, '{}'::int[]), (104, 120, 'Lock', 'transactionid', '{100}'),
                  (105, 0, null, null, '{}'), (105, 61, null, null, '{}'), (105, 180, null, null, '{}'),
                  (106, 0, 'Lock', 'tuple', '{100}'), (106, 60, 'Lock', 'tuple', '{100}'), (106, 120, 'Lock', 'tuple', '{100}')) v(p, s, wt, we, bp)" >/dev/null
check "$(waits pg_block_waits "$J2")" 3 "J2: once a minute with a near-duplicate snapshot: 104 two waits (not waiting at 60 s), 106 one"

echo "--- K. PostgreSQL deadlocks"
K1=$(syn k1 postgres); K2=$(syn k2 postgres); K3=$(syn k3 postgres)
dlk() {   # instance, minutes ago, key, statement a, statement b
  q "select pgvigil.ensure_month_partition('log_events', now() - make_interval(mins => $2));
     insert into pgvigil.log_events (instance_id, snapshot_at, kind, pid, datname, statement, detail, source, event_key)
     values ($1, now() - make_interval(mins => $2), 'deadlock', 4242, 'b10', '$4',
             'Process 4242 waits for ShareLock on transaction 7; blocked by process 4343.' || chr(10) || 'Process 4343 waits for ShareLock on transaction 8; blocked by process 4242.' || chr(10) || 'Process 4242: $4' || chr(10) || 'Process 4343: $5',
             'proof', 'b10-$1-$3')" >/dev/null
}
dlk "$K1" 10 n 'UPDATE a SET v = 1 WHERE id = 1' 'UPDATE b SET v = 1 WHERE id = 1'
for k in 1 2 3 4 5; do dlk "$K2" $((k * 5)) "h$k" 'UPDATE c SET v = 1 WHERE id = 1' 'UPDATE d SET v = 1 WHERE id = 1'; done
dlk "$K2" $((60 * 24 * 3)) old 'UPDATE c SET v = 1 WHERE id = 1' 'UPDATE d SET v = 1 WHERE id = 1'
dlk "$K3" $((60 * 24 * 3)) old 'UPDATE e SET v = 1 WHERE id = 1' 'UPDATE f SET v = 1 WHERE id = 1'
for k in 1 2; do dlk "$K3" $((k * 5)) "h$k" 'UPDATE e SET v = 1 WHERE id = 1' 'UPDATE f SET v = 1 WHERE id = 1'; done
check "$(has "$K1" 'a deadlock between a new pair of statements')" yes "K: a new pair fires"
check "$(finding "$K1" 'a deadlock between a new pair of statements' | grep -c 'UPDATE a SET v = 1.*UPDATE b SET v = 1')" 1 "K: the finding names both statements"
check "$(has "$K2" 'deadlocks in the last hour')|$(has "$K2" 'a deadlock between a new pair of statements')" "yes|no" "K: 5 of a known pair in an hour fire the count, not the new pair"
check "$(has "$K3" 'deadlocks in the last hour')|$(has "$K3" 'a deadlock between a new pair of statements')" "no|no" "K: 2 of a known pair fire neither"

echo "--- L. one window per wait (an hour's end crossed)"
LS=$(syn ls sqlserver); LP=$(syn lp postgres); BEND="date_trunc('hour', now()) - interval '1 hour'"
q "select pgvigil.mssql_event_partition('mssql_blocked_reports', $BEND - interval '2 minutes'), pgvigil.mssql_event_partition('mssql_blocked_reports', $BEND + interval '1 minute');
   insert into pgvigil.mssql_blocked_reports (instance_id, event_at, event_key, snapshot_at, database_name, wait_ms, blocked_spid, blocking_spid, blocked_statement, blocking_statement, head_key)
   select $LS, $BEND - interval '20 seconds' + make_interval(secs => k * 5), 'b10-l-' || k, now(), 'b10', k * 5000, 91, 90, 'UPDATE dbo.l SET v = 1', 'UPDATE dbo.l', md5('l')
     from generate_series(1, 8) k
   union all
   select $LS, $BEND - interval '60 seconds' + make_interval(secs => k * 5), 'b10-l2-' || k, now(), 'b10', k * 5000, 92, 90, 'UPDATE dbo.l SET v = 2', 'UPDATE dbo.l', md5('l')
     from generate_series(1, 6) k" >/dev/null
q "select pgvigil.ensure_month_partition('activity_sample', $BEND - interval '1 minute'), pgvigil.ensure_month_partition('activity_sample', $BEND + interval '1 minute');
   insert into pgvigil.activity_sample (instance_id, snapshot_at, pid, backend_start, datname, usename, state, wait_event_type, wait_event, query_start, blocking_pids)
   select $LP, $BEND + make_interval(secs => s), 103, $BEND - interval '1 hour', 'b10', 'app', 'active', 'Lock', 'transactionid', $BEND - interval '30 seconds', '{100}'
     from unnest(array[-15, 0, 15]) s" >/dev/null
wl() { q "select (select count(*) from pgvigil.$1($2, $BEND - interval '1 hour', $BEND)$3) || '|' || (select count(*) from pgvigil.$1($2, $BEND, $BEND + interval '1 hour')$3)"; }
if fn mssql_block_waits; then
  check "$(wl mssql_block_waits "$LS" " where blocked_spid = 91")" "0|1" "L: SQL Server, a wait across the end: in the later hour only"
  check "$(wl mssql_block_waits "$LS" " where blocked_spid = 92")" "1|0" "L: SQL Server, a wait ended 30 s before the end: in the earlier hour only"
else check "no mssql_block_waits" "0|1" "L: SQL Server one window per wait"; fi
if fn pg_block_waits; then check "$(wl pg_block_waits "$LP" "")" "0|1" "L: PostgreSQL, a wait across the end: in the later hour only"
else check "no pg_block_waits" "0|1" "L: PostgreSQL one window per wait"; fi

echo "--- M. the rollup's hourly door: a PostgreSQL instance's spike off its floor"
if fn import_block_hourly; then
  M=$(syn m postgres); HM=$(q "select date_trunc('hour', now()) - interval '1 hour'")
  q "update pgvigil.instances set first_seen = '$HM'::timestamptz - interval '29 days' where instance_id = $M" >/dev/null
  for w in 4 3 2 1 0; do q "select pgvigil.ensure_month_partition('activity_sample', '$HM'::timestamptz - make_interval(weeks => $w))" >/dev/null; done
  q "insert into pgvigil.activity_sample (instance_id, snapshot_at, pid, backend_start, datname, usename, state, wait_event_type, wait_event, query_start, blocking_pids)
     select $M, '$HM'::timestamptz - make_interval(weeks => w) + interval '10 minutes', 200 + w, '$HM'::timestamptz - interval '40 days', 'b10', 'app', 'active', 'Lock', 'transactionid', '$HM'::timestamptz - make_interval(weeks => w), '{100}'
       from generate_series(1, 4) w
     union all
     select $M, '$HM'::timestamptz + interval '10 minutes', 300 + k, '$HM'::timestamptz - interval '40 days', 'b10', 'app', 'active', 'Lock', 'transactionid', '$HM'::timestamptz + make_interval(secs => k), '{100}'
       from generate_series(1, 6) k" >/dev/null
  q "DO \$m\$ DECLARE a timestamptz; BEGIN
       FOR a IN SELECT g FROM generate_series('$HM'::timestamptz - interval '28 days', '$HM'::timestamptz, interval '1 day') g ORDER BY g LOOP
         PERFORM pgvigil.import_block_hourly(a);
       END LOOP;
       PERFORM pgvigil.import_block_hourly('$HM'::timestamptz + interval '1 hour 16 minutes');
       PERFORM pgvigil.import_block_hourly('$HM'::timestamptz + interval '1 hour 16 minutes');
     END \$m\$" >/dev/null
  check "$(q "select count(*) from pgvigil.mssql_block_hourly where instance_id = $M and waits = 1")|$(q "select waits from pgvigil.mssql_block_hourly where instance_id = $M and hour = '$HM'::timestamptz")" "4|6" "M: the door wrote the 4 weekly hours (1 wait each) and the last (6)"
  check "$(finding "$M" "blocking at 3x this hour''s usual" | grep -c '^warning|6 waits in the hour from .*, 6.0 times its usual of 1.0 (this weekday and hour over 4 weeks)$')" 1 "M: the spike off its floor on PostgreSQL ('6.0 times its usual of 1.0')"
else check "no import_block_hourly" "yes" "M: the rollup's hourly door"; fi

echo "--- N. two callers in the same minute"
if fn import_block_hourly; then
  NI=$(syn n postgres); q "update pgvigil.instances set first_seen = now() - interval '5 hours' where instance_id = $NI" >/dev/null
  q "CREATE ROLE b10_collector LOGIN IN ROLE pgvigil_collector" >/dev/null; CDSN="${PGVIGIL_REPO_DSN/user=postgres/user=b10_collector}"
  AT=$(q "select now()")
  ( psql "$CDSN" -XAtq -v ON_ERROR_STOP=1 -c "BEGIN" -c "select pgvigil.import_block_hourly('$AT'::timestamptz)" -c "select pg_sleep(3)" -c "COMMIT" > "$OUT.n1" 2>&1 ) & NP=$!
  sleep 1; N2=$(psql "$CDSN" -XAt -v ON_ERROR_STOP=1 -c "select pgvigil.import_block_hourly('$AT'::timestamptz)" 2>&1 || true); wait $NP || true; N1=$(head -1 "$OUT.n1")
  NE=$(q "select count(*) from pgvigil.instances i, generate_series(date_trunc('hour', i.first_seen), date_trunc('hour', '$AT'::timestamptz - interval '15 minutes') - interval '1 hour', interval '1 hour') g where i.instance_id = $NI")
  check "$N2|$(q "select count(*) || '/' || count(distinct hour) from pgvigil.mssql_block_hourly where instance_id = $NI")|$([ "${N1:-0}" -ge "$NE" ] 2>/dev/null && echo first-wrote || echo "first $N1")" "0|$NE/$NE|first-wrote" "N: the second caller returns 0, the first writes the $NE hours, each once"
else check "no import_block_hourly" "yes" "N: two callers in the same minute"; fi

echo "--- O. a capped call: the oldest hours first, repeated while it returns its cap"
if fn import_block_hourly; then
  # the rows before O (b10_o0) and the first call's own (b10_o1): the proof's own tables in public, gone with the container
  OT=$(q "select '$AT'::timestamptz + interval '3 hours'"); q "create table b10_o0 as select instance_id, hour from pgvigil.mssql_block_hourly" >/dev/null
  OB=$(q "select count(*) from pgvigil.mssql_block_hourly"); ON=()
  for k in $(seq 1 300); do
    n=$(q "select pgvigil.import_block_hourly('$OT'::timestamptz, 2)"); ON+=("$n")
    [ "$k" = 1 ] && q "create table b10_o1 as select instance_id, hour from pgvigil.mssql_block_hourly except select instance_id, hour from b10_o0" >/dev/null
    [ "$n" -lt 2 ] && break
  done
  OSUM=0; for n in "${ON[@]}"; do OSUM=$((OSUM + n)); done; OLAST=${ON[${#ON[@]}-1]}
  OFULL=$(for n in "${ON[@]:0:${#ON[@]}-1}"; do [ "$n" = 2 ] || echo x; done | grep -c x || true)
  OOLD=$(q "select count(*) from (select instance_id, hour from pgvigil.mssql_block_hourly except select instance_id, hour from b10_o0 except select instance_id, hour from b10_o1) x where x.hour < (select max(hour) from b10_o1)")
  check "$OFULL|$([ "$OLAST" -lt 2 ] && echo under)|$(( $(q "select count(*) from pgvigil.mssql_block_hourly") - OB ))|$OOLD|$(q "select pgvigil.import_block_hourly('$OT'::timestamptz)")|$(q "select count(*) - count(distinct (instance_id, hour)) from pgvigil.mssql_block_hourly")" \
    "0|under|$OSUM|0|0|0" "O: ${#ON[@]} capped calls of 2 wrote $OSUM, the first the oldest, nothing left, each hour once"
else check "no import_block_hourly" "yes" "O: a capped call"; fi

echo "--- P. the next call's wait in the repository's own zone (repo.NextBlockHourly's SQL)"
NX=$(sed -n 's/.*QueryRow(ctx, `\(SELECT extract(epoch FROM date_trunc[^`]*\)`).*/\1/p' "$(dirname "$0")/../internal/repo/blockhourly.go" 2>/dev/null)
if [ -n "$NX" ]; then
  pz() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "set timezone = '$1'" -c "select to_char(now() + make_interval(secs => w) + interval '30 seconds', 'MI') || '|' || to_char((now() + make_interval(secs => w) + interval '30 seconds') at time zone 'UTC', 'MI') || '|' || (w > 0 and w <= 3600) from ($NX) x(w)"; }
  check "$(pz UTC)" "16|16|true" "P: under UTC the next call is at 16 past the hour, within the hour"
  check "$(pz Asia/Kathmandu)" "16|31|true" "P: under +5:45 at 16 past the local hour (31 past UTC), within the hour"
else check "no NextBlockHourly SQL" "found" "P: the next call's wait"; fi

echo
[ "$bad" = 0 ] && echo "proof-b10-blocking: every row ok" || { echo "proof-b10-blocking: $bad row(s) FAIL"; exit 1; }
