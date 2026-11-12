#!/usr/bin/env bash
# Proof of the SQL Server Extended Events reader (migration 0065, internal/mssql/xe.go, xe_shred.go, batch.go): the
# sessions exist only where a DBA ran the printed script, the reader stores each event once from a cursor, and the
# server's own sessions are read and never touched.
#
# Needs: curl, python3, docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox) reachable on
# PGVIGIL_MSSQL_ADDR (default localhost:1433), its sa password in MSSQL_SA_PASSWORD, psql, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# Needs too: the container's own user is root. sqfile copies each script in as a file only its owner reads and
# sqlcmd opens it as the container's user: on the 2019 and later images, which run as the user mssql unless told
# otherwise (docker run --user root, a compose file's user: root), part B fails at that read.
# The server must have NO event session named pgvigil_* before the run (part A needs a server without them).
# The proof makes its own repository database, one SQL Server login (VIEW SERVER STATE, VIEW ANY DEFINITION), one
# database, and the four sessions of ONE random install id, created by sa from the printed script as a DBA would;
# it drops them all at the end and deletes the event files of its own slow session. Part E lowers the server's
# 'blocked process threshold (s)' to 5; the old value (and 'show advanced options') is put back on every exit path
# from the first time the printed script runs on the server (part B) to the end.
# No other session is created, altered, stopped or dropped: part M compares system_health and AlwaysOn_health before and after.
#
# Expected (written before the first run):
#  A. a server without the sessions: `collect -once mssql_xe` exits 0 and prints neither "error" nor "partial";
#     mssql_xe_state holds four rows (deadlocks, blocked, slow, attention), each 'not installed'; the deadlocks row
#     says source system_health and mssql_deadlocks holds as many system_health rows as sa counts
#     xml_deadlock_report events of the last 45 days in system_health's files. After ONE read no 'a capture is not
#     installed' finding shows; after the second read exactly one does (info), naming the four captures.
#  B. the read login alone cannot create a session: the printed script run as the monitoring login fails, its error
#     text is shown and names the missing permission, and no pgvigil session exists afterwards.
#  C. the printed script run by sa (its settings edited as a DBA would: threshold 5 ms, 1 MB files, 512 KB memory)
#     creates and starts four sessions named pgvigil_<id>_<capture>; a second run says 'exists, left as it is' four
#     times; 'blocked process threshold (s)' is the same before and after; the next read stores four 'running' rows
#     with the session names, the targets (ring_buffer x3, event_file for slow) and source product.
#  D. a deadlock the proof provokes between two of its own sessions is stored ONCE (one row whose databases are the
#     proof's), from the product's session, with one victim, two processes, both statements (each process's own
#     UPDATE batch), the victim's spid among them, the object each of the two waited on, and the graph XML whole; a second read
#     leaves one row. The finding 'deadlocks in the last hour' shows for the instance.
#  E. a blocked-process report: with the threshold at 5 s, a session blocked about 14 s behind an open transaction
#     gives at least one stored report whose blocked statement is the waiter's UPDATE, whose blocking statement (the
#     head's input buffer) is the head's batch, whose blocking spid is the head's, wait_ms at least 5000; the
#     threshold is back at its old value afterwards and the state row carries the threshold read (5).
#  F. a slow batch over the threshold: one sql_batch_completed row with the proof's marker, duration_ms within 250 ms
#     of the batch's own measured elapsed time, the login, host and database of the run, and query_hash and
#     query_plan_hash as 0x and 16 hex digits, the query_hash equal to the one the batch itself read for its slow
#     statement from sys.dm_exec_query_stats before it ended.
#  G. an attention from a cancelled query (a client timeout of 2 s on a 30 s wait): one row with the marker statement
#     and the session id; the state row's counter is at least 1.
#  H. a second read stores nothing twice: the counts of D, E, F and G are unchanged and the cursors did not move back.
#  I. 2,000 slow events in two halves with a read between them (the event file rolls over between and within: sa
#     counts more than one file): after the last read exactly 2,000 marker completions are stored, none missing and
#     none twice, and the cursor of the slow session moved at least four times in separate imports (batches of 500).
#  K. the cursor's file gone: with the stored cursor pointed at a file name that does not exist, the next read falls
#     back to reading the files by event time, stores nothing twice (still exactly 2,000), says so in the state
#     row's note, and leaves a cursor on a real file.
#  L. stopped is its own state and holds for two reads: after sa stops the attention session the next read says
#     'stopped' with no finding; the read after shows 'a capture is stopped' (warning) naming attention.
#  J. AlwaysOn_health, where Always On is enabled (SKIPPED with its reason where it is not): the 'ag' state row says
#     running, mssql_ag_events holds as many availability_replica_state_change rows as sa counts in the session's
#     files for the last 45 days.
#  P. the pages' API (pgvigil serve on the proof's repository, curl): /api/mssql/xe returns its eight parts, the
#     captures' states (attention stopped by then), the proof's deadlock, the head statement's group, the bulk
#     batches as ONE shape of at least 2,000 events, the attention and the two findings; ?part=state returns that
#     part alone and an unknown part is a 400; the deadlock's detail holds two processes (one victim, both
#     statements) and two resources with owners and waiters; the .xdl download is the stored graph, byte for byte,
#     as an attachment named deadlock-<instance>-<time>.xdl; an unknown deadlock is a 404 and a malformed key a 400;
#     the reports of the head and the 500 slowest events of the bulk shape come back by their keys.
#  S. two instances' imports at the same time, sixty calls each, one with a slow completion and one with an
#     availability group event, every call in a month not opened yet (no server needed): no call fails (with the
#     months opened first and the parents locked afterwards, half the calls ended in "deadlock detected") and
#     sixty rows of each are stored.
#  R. the collector's role (pgvigil_collector) reads a cursor through import_mssql_cursor, is refused the cursor table
#     itself, and imports a batch.
#  F and G also carry a control character (0x01) inside the statement's text: the event is stored, with U+FFFD where
#     the character was and no control character left (SQL Server itself writes the character into the event as the
#     text '&#1;', taking a '[' before it with it: measured; a character reference of that kind outside a CDATA
#     section fails the XML decoder, and one such event must not cost the read).
#  M also: after the drop the reader is back on system_health, which holds the proof's deadlock too; the deadlock
#     stays ONE row (source product).
#  M. nothing else was touched: system_health and AlwaysOn_health (name, running, start time) are the same before and
#     after (the sandbox is shared: another tool's session that changed meanwhile is named, not judged); the drop
#     script printed by pgvigil drops exactly the four; the read after it says 'not installed' four times again.
#  N. NOT PROVEN HERE: the Azure SQL Database and Managed Instance forms of the script (no such endpoint: the text is
#     checked by the unit test only); part J (AlwaysOn_health) on SQL Server 2016 (one server, no Windows cluster:
#     SKIPPED there); an event file's Windows path on any version but 2016 (2017 and later run as Linux containers);
#     a ring buffer whose events left before a read (the 'missed' count is the import function's arithmetic, checked
#     in part O by hand); SQL Server 2016 before SP3 (SP1, SP2) and editions other than Developer (docs/sqlserver-2016.md,
#     Not proven). Proven elsewhere: SQL Server 2017, 2019, 2022 and 2025 by scripts/proof-mssql-versions.sh,
#     which runs this proof on each (docs/sqlserver.md, Versions); SQL Server 2016 SP3 on one Windows server by
#     scripts/proof-mssql-2016.sh, the slow session's event files read by their Windows path in the instance's Log
#     folder (docs/sqlserver-2016.md).
#  O. the loss arithmetic and the engine guard, on the repository alone: a state row whose ring buffer took 50 more
#     events than the read found stores missed_events 50 with lost_at set and fires 'the ring buffer dropped
#     events'; import_mssql_xe on a PostgreSQL instance raises 'is not a SQL Server instance'.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
ID=p$SUF                                   # the install id of this run's sessions
REPO_DB=pgvigil_xeproof_$SUF
L1=pgv_xe_$SUF; DB=pgvxe_$SUF; HOSTA=pgvxea$SUF; HOSTB=pgvxeb$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw)
CFG=$(mktemp); OUT=$(mktemp); DDL=$(mktemp); DROP=$(mktemp); BEFORE=$(mktemp); AFTER=$(mktemp)
OLD_BPT=; OLD_ADV=; MADE_REPO=; MADE_L1=; MADE_DB=; MADE_SESS=; SRVPID=
fail() { echo "FAIL: $*" >&2; exit 1; }
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
sq() { docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -I -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# a script file run by sa, as a DBA would in a query window
sqfile() {
  docker cp -q "$1" "$CT:/tmp/pgvxe_$SUF.sql"
  local rc=0
  docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U "${2:-sa}" -C -I -b -d master -i "/tmp/pgvxe_$SUF.sql" || rc=$?
  docker exec -u 0 "$CT" rm -f "/tmp/pgvxe_$SUF.sql"
  return $rc
}
# a workload batch under a host name the proof's counts filter on
work() { docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -I -H "$1" -d "$DB" "${@:3}" -Q "$2"; }
cleanup() {
  rc=$?
  set +e
  if [ -n "$OLD_BPT" ]; then
    sq "EXEC sys.sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sys.sp_configure 'blocked process threshold (s)', $OLD_BPT; RECONFIGURE; EXEC sys.sp_configure 'show advanced options', ${OLD_ADV:-0}; RECONFIGURE;" >/dev/null 2>&1 \
      || echo "CLEANUP: 'blocked process threshold (s)' was NOT put back to $OLD_BPT (show advanced options: ${OLD_ADV:-0})" >&2
  fi
  # only what THIS run created, each by its own flag and its exact name
  if [ -n "$MADE_SESS" ]; then
    for c in deadlocks blocked slow attention; do
      sq "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'pgvigil_${ID}_$c') DROP EVENT SESSION [pgvigil_${ID}_$c] ON SERVER;" >/dev/null 2>&1 || echo "CLEANUP: session pgvigil_${ID}_$c not dropped" >&2
    done
    docker exec "$CT" bash -c "rm -f /var/opt/mssql/log/pgvigil_${ID}_slow_0_*.xel" >/dev/null 2>&1 || echo "CLEANUP: the event files of pgvigil_${ID}_slow were not deleted" >&2
  fi
  if [ -n "$MADE_DB" ]; then sq "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null 2>&1 || echo "CLEANUP: database $DB not dropped" >&2; fi
  if [ -n "$MADE_L1" ]; then sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; fi
  if [ -n "$MADE_REPO" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  if [ -n "$SRVPID" ]; then kill "$SRVPID" >/dev/null 2>&1; fi   # the proof's own server, by its own pid
  rm -f "$CFG" "$OUT" "$DDL" "$DROP" "$BEFORE" "$AFTER" "$CFG.serve" "$OUT.serve" "$OUT.ids" "$OUT.hdr" "$OUT.head" "$OUT.f"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
[ "$(sq "SELECT COUNT(*) FROM sys.server_event_sessions WHERE name LIKE N'pgvigil[_]%'")" = 0 ] \
  || fail "the server already has a pgvigil_* event session: $(sq "SELECT name FROM sys.server_event_sessions WHERE name LIKE N'pgvigil[_]%'" | tr '\n' ' '); the proof needs a server without them"
# the server's sessions that are not this run's: name, running, and when the running session was started (milliseconds:
# the DMV's create_time is computed from the clock at each read and moves by a few of them)
others() { sq "SELECT d.name, CASE WHEN r.name IS NULL THEN 0 ELSE 1 END, ISNULL(DATEDIFF_BIG(millisecond, '2020-01-01', r.create_time), 0) FROM sys.server_event_sessions d LEFT JOIN sys.dm_xe_sessions r ON r.name = d.name WHERE d.name NOT LIKE N'pgvigil[_]${ID}[_]%' ORDER BY d.name"; }
others > "$BEFORE"
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
sq "CREATE LOGIN [$L1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF;"; MADE_L1=1
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];"
sq "CREATE DATABASE [$DB];"; MADE_DB=1
sq "CREATE TABLE dbo.dl_a (id int PRIMARY KEY, v int); CREATE TABLE dbo.dl_b (id int PRIMARY KEY, v int); INSERT dbo.dl_a VALUES (1, 0); INSERT dbo.dl_b VALUES (1, 0);" "$DB"
export MSSQL_MON_DSN="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export PGVIGIL_MSSQL_XE_BATCH=500
N1=proof-xe-$SUF; NP=proof-xe-pg-$SUF
CTL=$'\x01'                                # a control character XML 1.0 forbids, inside two statements' text (parts F, G)
export PG_MON_DSN="$ADMIN_DSN"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N1
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
  - name: $NP
    dsn: env:PG_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
# every move of a cursor, one row per import that moved it (part I counts the batches)
q "create table public.cursor_moves (at timestamptz default clock_timestamp(), source text, file_name text, file_offset bigint, last_event_at timestamptz, last_seq bigint);
   create function public.cursor_move() returns trigger language plpgsql as \$\$ begin insert into public.cursor_moves (source, file_name, file_offset, last_event_at, last_seq) values (new.source, new.file_name, new.file_offset, new.last_event_at, new.last_seq); return new; end \$\$;
   create trigger cursor_move after insert or update on pgvigil.mssql_cursor for each row execute function public.cursor_move();" >/dev/null
# one read; the run must end clean (no error, no partial)
xe() {
  "$BIN" collect -config "$CFG" -once mssql_xe -instance "$N1" 2>&1 | tee "$OUT"
  grep -q "^$N1 mssql_xe: [0-9]* row(s)" "$OUT" || fail "$1: the run did not end with a row count"
  if grep -qiE "partial|error|failed" "$OUT"; then fail "$1: the run says partial or error"; fi
}
# read until a read finds nothing new in the files and buffers (at most 12 reads: a first read of system_health)
xe_all() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    xe "$1"
    [ "$(q "select count(*) from pgvigil.mssql_xe_state s join pgvigil.instances i using (instance_id) where i.name='$N1' and s.note like '%time was up%'")" = 0 ] && return 0
  done
  fail "$1: the reader did not catch up in 12 reads"
}
settle() { sleep 7; }   # the sessions dispatch every 5 seconds

echo "--- A. a server without the sessions"
SA_SH_DL=$(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) WHERE object_name = N'xml_deadlock_report' AND CAST(event_data AS xml).value('(event/@timestamp)[1]', 'datetime2') > DATEADD(day, -45, SYSUTCDATETIME())")
xe A
iid=$(q "select instance_id from pgvigil.instances where name='$N1'")
[ "$(q "select max(reads_in_state) from pgvigil.mssql_xe_state where instance_id=$iid and capture <> 'ag'")" = 1 ] || fail "A: the first read is not read 1"
[ "$(q "select count(*) from pgvigil.mssql_xe_findings where instance_id=$iid and check_name='a capture is not installed'")" = 0 ] || fail "A: the finding fired after one read"
xe_all A
[ "$(q "select string_agg(capture || '=' || state, ',' order by capture) from pgvigil.mssql_xe_state where instance_id=$iid and capture <> 'ag'")" \
  = "attention=not installed,blocked=not installed,deadlocks=not installed,slow=not installed" ] \
  || fail "A: the state rows: $(q "select capture, state from pgvigil.mssql_xe_state where instance_id=$iid")"
[ "$(q "select source from pgvigil.mssql_xe_state where instance_id=$iid and capture='deadlocks'")" = system_health ] || fail "A: the deadlocks row's source"
[ "$(q "select count(*) from pgvigil.mssql_deadlocks where instance_id=$iid and source='system_health'")" = "$SA_SH_DL" ] \
  || fail "A: system_health deadlocks stored $(q "select count(*) from pgvigil.mssql_deadlocks where instance_id=$iid") , sa counts $SA_SH_DL"
echo "  system_health deadlock reports of the last 45 days: sa counts $SA_SH_DL, stored $SA_SH_DL"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='mssql_xe'")" = ok ] || fail "A: collection_dates"
[ "$(q "select severity || '|' || object from pgvigil.mssql_xe_findings where instance_id=$iid and check_name='a capture is not installed'")" = "info|attention, blocked, deadlocks, slow" ] \
  || fail "A: the finding after two reads: $(q "select severity, object from pgvigil.mssql_xe_findings where instance_id=$iid")"
echo "A: OK"

echo "--- B. the read login alone cannot create a session"
# from here on the printed script runs on the server: whatever it would make or change is undone on every exit path
OLD_ADV=$(sq "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'show advanced options'")
OLD_BPT=$(sq "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'blocked process threshold (s)'")
MADE_SESS=1
"$BIN" mssql-xe -print -install-id "$ID" > "$DDL"
grep -q "CREATE EVENT SESSION \[pgvigil_${ID}_slow\] ON SERVER" "$DDL" || fail "B: the printed script"
if SQLCMDPASSWORD="$P1" sqfile "$DDL" "$L1" >"$OUT" 2>&1; then cat "$OUT"; fail "B: the monitoring login ran the script"; fi
echo "  what the monitoring login gets:"; sed 's/^/    /' "$OUT" | head -8
grep -qiE "permission|does not have" "$OUT" || fail "B: the error does not name a permission"
[ "$(grep -c '^NOT created: pgvigil_'"$ID"'_' "$OUT")" = 4 ] || fail "B: the script did not say 'NOT created' four times"
if grep -qE '^(created|started): ' "$OUT"; then fail "B: the script claims a session it did not make"; fi
[ "$(sq "SELECT COUNT(*) FROM sys.server_event_sessions WHERE name LIKE N'pgvigil[_]${ID}[_]%'")" = 0 ] || fail "B: a session exists after the refused run"
echo "B: OK"

echo "--- C. the printed script, run by sa as the DBA would"
BPT0=$OLD_BPT
# the DBA's edits of the settings block: a 5 ms threshold, small files so the proof can roll them over
sed -i -e 's/^DECLARE @slow_ms          int = 1000;/DECLARE @slow_ms          int = 5;/' \
       -e 's/^DECLARE @slow_file_mb     int = 50;/DECLARE @slow_file_mb     int = 1;/' \
       -e 's/^DECLARE @slow_files       int = 4;/DECLARE @slow_files       int = 40;/' \
       -e 's/^DECLARE @slow_memory_kb   int = 4096;/DECLARE @slow_memory_kb   int = 512;/' "$DDL"
[ "$(grep -cE '^DECLARE @slow_(ms          int = 5|file_mb     int = 1|files       int = 40|memory_kb   int = 512);' "$DDL")" = 4 ] || fail "C: the settings block was not edited"
sqfile "$DDL" | tee "$OUT"
[ "$(grep -c '^created: pgvigil_'"$ID"'_' "$OUT")" = 4 ] && [ "$(grep -c '^started: pgvigil_'"$ID"'_' "$OUT")" = 4 ] || fail "C: four sessions created and started"
grep -q "blocked process threshold (s) *$BPT0" "$OUT" || fail "C: the script did not show the threshold in use ($BPT0)"
sqfile "$DDL" > "$OUT"
[ "$(grep -c '^exists, left as it is: pgvigil_'"$ID"'_' "$OUT")" = 4 ] || { cat "$OUT"; fail "C: a second run did not leave the four as they are"; }
[ "$(sq "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'blocked process threshold (s)'")" = "$BPT0" ] || fail "C: the script changed the blocked process threshold"
[ "$(sq "SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name LIKE N'pgvigil[_]${ID}[_]%'")" = 4 ] || fail "C: four running sessions"
xe C
[ "$(q "select string_agg(capture || '=' || state || '/' || target || '/' || source || '/' || session_name, ',' order by capture) from pgvigil.mssql_xe_state where instance_id=$iid and capture <> 'ag'")" \
  = "attention=running/ring_buffer/product/pgvigil_${ID}_attention,blocked=running/ring_buffer/product/pgvigil_${ID}_blocked,deadlocks=running/ring_buffer/product/pgvigil_${ID}_deadlocks,slow=running/event_file/product/pgvigil_${ID}_slow" ] \
  || fail "C: the state rows: $(q "select capture, state, target, source, session_name from pgvigil.mssql_xe_state where instance_id=$iid")"
[ "$(q "select count(*) from pgvigil.mssql_xe_findings where instance_id=$iid and check_name like 'a capture is%'")" = 0 ] || fail "C: a capture finding with four running sessions"
echo "C: OK"

echo "--- D. a deadlock between two of the proof's own sessions"
S1="BEGIN TRAN; UPDATE dbo.dl_a SET v = 1 WHERE id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.dl_b SET v = 1 WHERE id = 1; COMMIT;"
S2="BEGIN TRAN; UPDATE dbo.dl_b SET v = 2 WHERE id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.dl_a SET v = 2 WHERE id = 1; COMMIT;"
( work "$HOSTA" "$S1" >/dev/null 2>&1 || true ) & W1=$!
( work "$HOSTA" "$S2" >/dev/null 2>&1 || true ) & W2=$!
wait $W1 $W2
settle; xe D
dl() { q "select $1 from pgvigil.mssql_deadlocks where instance_id=$iid and database_names = '$DB'"; }
[ "$(dl "count(*)")" = 1 ] || fail "D: $(dl "count(*)") deadlock row(s) for $DB, want 1"
[ "$(dl "source || '|' || victim_count || '|' || process_count || '|' || object_names || '|' || (graph like '<deadlock>%</deadlock>')")" \
  = "product|1|2|$DB.dbo.dl_a, $DB.dbo.dl_b|true" ] || fail "D: the row: $(dl "source, victim_count, process_count, object_names, left(graph, 30)")"
[ "$(dl "(select count(*) from jsonb_array_elements(processes) p where p->>'statement' like 'BEGIN TRAN; UPDATE dbo.dl_a SET v = 1%') || '|' || (select count(*) from jsonb_array_elements(processes) p where p->>'statement' like 'BEGIN TRAN; UPDATE dbo.dl_b SET v = 2%')")" = "1|1" ] \
  || fail "D: both statements: $(dl "processes")"
[ "$(dl "(select count(*) from jsonb_array_elements(processes) p where (p->>'victim')::boolean and (p->>'spid')::int = victim_spid and p->>'waits_on' like '$DB.dbo.dl_%' and p->>'login' = 'sa' and p->>'host' = '$HOSTA')")" = 1 ] \
  || fail "D: the victim among the processes: $(dl "victim_spid, processes")"
[ "$(dl "victim_statement like 'BEGIN TRAN; UPDATE dbo.dl_%'")" = t ] || fail "D: the victim's statement"
[ "$(dl "(select count(distinct p->>'waits_on') from jsonb_array_elements(processes) p where p->>'waits_on' like '$DB.dbo.dl_%' and p->>'waits_mode' is not null)")" = 2 ] \
  || fail "D: the object each process waited on: $(dl "processes")"
xe D
[ "$(dl "count(*)")" = 1 ] || fail "D: stored twice after a second read"
[ "$(q "select severity from pgvigil.mssql_xe_findings where instance_id=$iid and check_name='deadlocks in the last hour'")" = warning ] || fail "D: the finding"
echo "D: OK (one deadlock, victim spid $(dl victim_spid))"

echo "--- E. a blocked-process report (threshold 5 s for the proof, the old value back afterwards)"
sq "EXEC sys.sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sys.sp_configure 'blocked process threshold (s)', 5; RECONFIGURE;" >/dev/null
HEAD="BEGIN TRAN; UPDATE dbo.dl_a SET v = 10 WHERE id = 1; SELECT @@SPID; WAITFOR DELAY '00:00:16'; ROLLBACK;"
WAITER="UPDATE dbo.dl_a SET v = 11 WHERE id = 1;"
( work "$HOSTA" "$HEAD" -h -1 -W > "$OUT.head" 2>&1 || true ) & W1=$!
sleep 2
( work "$HOSTA" "$WAITER" >/dev/null 2>&1 || true ) & W2=$!
wait $W1 $W2
HEAD_SPID=$(grep -oE '^[0-9]+$' "$OUT.head" | head -1); rm -f "$OUT.head"
[ -n "$HEAD_SPID" ] || fail "E: the head's spid was not read"
settle; xe E
bp() { q "select $1 from pgvigil.mssql_blocked_reports where instance_id=$iid and database_name = '$DB'"; }
[ "$(bp "count(*) >= 1")" = t ] || fail "E: no blocked-process report stored"
[ "$(bp "bool_and(blocked_statement like 'UPDATE dbo.dl_a SET v = 11%') || '|' || bool_and(blocking_statement like 'BEGIN TRAN; UPDATE dbo.dl_a SET v = 10%') || '|' || bool_and(blocking_spid = $HEAD_SPID) || '|' || bool_and(wait_ms >= 5000) || '|' || bool_and(blocked_host = '$HOSTA') || '|' || bool_and(report like '<blocked-process-report%')")" \
  = "true|true|true|true|true|true" ] || fail "E: the report: $(bp "blocked_statement, blocking_statement, blocking_spid, wait_ms, blocking_status")"
[ "$(q "select threshold_s from pgvigil.mssql_xe_state where instance_id=$iid and capture='blocked'")" = 5 ] || fail "E: the threshold in the state row"
echo "  $(bp "count(*)") report(s); head spid $HEAD_SPID, status $(bp "min(blocking_status)"), longest wait $(bp "max(wait_ms)") ms"
sq "EXEC sys.sp_configure 'blocked process threshold (s)', $OLD_BPT; RECONFIGURE; EXEC sys.sp_configure 'show advanced options', $OLD_ADV; RECONFIGURE;" >/dev/null
[ "$(sq "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'blocked process threshold (s)'")|$(sq "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'show advanced options'")" = "$OLD_BPT|$OLD_ADV" ] \
  || fail "E: the threshold or 'show advanced options' was not put back"
echo "E: OK"

echo "--- F. a slow batch over the threshold"
MARK="pgvxe-slow-$SUF"
# the batch times itself and, before it ends, reads the query hash of its own slow statement from the plan cache
# (its own sql_handle, the statement with the most elapsed time): the cache is read in the same second, not later
work "$HOSTA" "SET NOCOUNT ON; /* $MARK ctl(${CTL}) */ DECLARE @t0 datetime2 = SYSDATETIME(); DECLARE @n bigint; SELECT @n = COUNT_BIG(*) FROM (SELECT TOP (800) name FROM sys.all_columns) a CROSS JOIN sys.all_columns b WHERE a.name < b.name OPTION (MAXDOP 1); SELECT 'elapsed=' + CAST(DATEDIFF(millisecond, @t0, SYSDATETIME()) AS varchar(20)); SELECT TOP (1) 'hash=' + CONVERT(varchar(18), qs.query_hash, 1) FROM sys.dm_exec_requests r JOIN sys.dm_exec_query_stats qs ON qs.sql_handle = r.sql_handle WHERE r.session_id = @@SPID ORDER BY qs.total_elapsed_time DESC;" -h -1 -W > "$OUT.f" 2>&1 || true
ELAPSED=$(sed -n 's/^elapsed=\([0-9]*\)$/\1/p' "$OUT.f" | head -1); SA_QH=$(sed -n 's/^hash=\(0x[0-9A-F]*\)$/\1/p' "$OUT.f" | head -1); rm -f "$OUT.f"
settle; xe F
sl() { q "select $1 from pgvigil.mssql_slow_events where instance_id=$iid and event_name='sql_batch_completed' and statement like '%$MARK%'"; }
[ "$(sl "count(*)")" = 1 ] || fail "F: $(sl "count(*)") completion row(s) with the marker, want 1"
[ "$(sl "(abs(duration_ms - $ELAPSED) <= 250) || '|' || login_name || '|' || host_name || '|' || database_name || '|' || (query_hash ~ '^0x[0-9A-F]{16}\$') || '|' || (query_plan_hash ~ '^0x[0-9A-F]{16}\$') || '|' || result")" \
  = "true|sa|$HOSTA|$DB|true|true|OK" ] || fail "F: the row (the batch measured $ELAPSED ms): $(sl "duration_ms, login_name, host_name, database_name, query_hash, query_plan_hash, result")"
[ "$(sl "statement ~ ('ctl.?' || U&'\\FFFD') and statement !~ '[\\x01-\\x08]'")" = t ] || fail "F: the control character in the batch's text: $(sl "encode(convert_to(substring(statement from 'ctl.{0,6}'), 'UTF8'), 'hex')")"
QH=$(sl query_hash)
[ -n "$SA_QH" ] || fail "F: the batch did not read its own query hash from the plan cache"
[ "$QH" = "$SA_QH" ] || fail "F: the stored query_hash $QH is not the plan cache's $SA_QH"
echo "F: OK (the batch measured $ELAPSED ms, stored $(sl "round(duration_ms)") ms, query_hash $QH)"

echo "--- G. an attention from a cancelled query"
AMARK="pgvxe-attn-$SUF"
work "$HOSTA" "/* $AMARK ctl(${CTL}) */ WAITFOR DELAY '00:00:30';" -t 2 >/dev/null 2>&1 || true
settle; xe G
at() { q "select $1 from pgvigil.mssql_attentions where instance_id=$iid and statement like '%$AMARK%'"; }
[ "$(at "count(*)")" = 1 ] || fail "G: $(at "count(*)") attention row(s) with the marker, want 1"
[ "$(at "(session_id > 50) || '|' || host_name || '|' || login_name || '|' || (interrupt_us >= 0)")" = "true|$HOSTA|sa|true" ] || fail "G: the row: $(at "session_id, host_name, login_name, interrupt_us")"
[ "$(q "select counter >= 1 from pgvigil.mssql_xe_state where instance_id=$iid and capture='attention'")" = t ] || fail "G: the counter"
[ "$(at "statement ~ ('ctl.?' || U&'\\FFFD') and statement !~ '[\\x01-\\x08]'")" = t ] || fail "G: the control character in the cancelled statement: $(at "encode(convert_to(substring(statement from 'ctl.{0,6}'), 'UTF8'), 'hex')")"
echo "G: OK"

echo "--- H. a second read stores nothing twice"
counts() { echo "$(dl "count(*)")|$(bp "count(*)")|$(sl "count(*)")|$(at "count(*)")"; }
C1=$(counts); CUR1=$(q "select string_agg(source || ':' || coalesce(file_offset::text, '') || ':' || coalesce(last_seq::text, ''), ',' order by source) from pgvigil.mssql_cursor where instance_id=$iid and source like 'pgvigil_%' and source not like '%_slow'")
xe H
[ "$(counts)" = "$C1" ] || fail "H: the counts moved from $C1 to $(counts)"
[ "$(q "select string_agg(source || ':' || coalesce(file_offset::text, '') || ':' || coalesce(last_seq::text, ''), ',' order by source) from pgvigil.mssql_cursor where instance_id=$iid and source like 'pgvigil_%' and source not like '%_slow'")" = "$CUR1" ] || fail "H: a ring buffer's cursor moved without a new event"
echo "H: OK ($C1)"

echo "--- I. 2,000 slow events, in two halves, read in batches of 500 across a rollover"
BMARK="pgvxe-bulk-$SUF"
# the slow session's event files are in the server's own log folder (its target names a file without a folder):
# /var/opt/mssql/log/ on Linux, the instance's Log folder on Windows
XELDIR=$(sq "SELECT LEFT(p, LEN(p) - CHARINDEX(CASE WHEN p LIKE N'%\%' THEN N'\' ELSE N'/' END, REVERSE(p)) + 1) FROM (SELECT CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(400)) AS p) x")
[ -n "$XELDIR" ] || fail "I: the server's log folder"
files() { sq "SELECT COUNT(DISTINCT file_name) FROM sys.fn_xe_file_target_read_file(N'${XELDIR}pgvigil_${ID}_slow*.xel', NULL, NULL, NULL)"; }
bulk() { docker exec -i -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -I -H "$HOSTB" -d "$DB" >/dev/null <<EOF
SET NOCOUNT ON; /* $BMARK $(printf 'x%.0s' $(seq 1 600)) */ WAITFOR DELAY '00:00:00.008';
GO 1000
EOF
}
bk() { q "select $1 from pgvigil.mssql_slow_events where instance_id=$iid and event_name='sql_batch_completed' and host_name='$HOSTB' and statement like '%$BMARK%'"; }
MOVES0=$(q "select count(*) from public.cursor_moves where source='pgvigil_${ID}_slow'")
bulk; settle; F1=$(files); xe_all I
[ "$(bk "count(*)")" = 1000 ] || fail "I: after the first half $(bk "count(*)") stored, want 1000"
bulk; settle; F2=$(files); xe_all I
[ "$F2" -gt 1 ] && [ "$F2" -gt "$F1" ] || fail "I: the event file did not roll over between the halves ($F1 then $F2 file(s))"
[ "$(bk "count(*)")" = 2000 ] || fail "I: $(bk "count(*)") stored, want 2000"
[ "$(bk "count(distinct (event_at, event_key))")" = 2000 ] || fail "I: a stored event twice"
MOVES=$(( $(q "select count(*) from public.cursor_moves where source='pgvigil_${ID}_slow'") - MOVES0 ))
[ "$MOVES" -ge 4 ] || fail "I: the cursor moved $MOVES time(s), want at least 4"
[ "$(q "select count(*) from (select file_name, file_offset, lag(file_name) over w as pf, lag(file_offset) over w as po from public.cursor_moves where source='pgvigil_${ID}_slow' window w as (order by at)) x where pf is not null and (file_name, file_offset) <= (pf, po)")" = 0 ] \
  || fail "I: the cursor moved back or stood still in an import"
echo "I: OK (2,000 stored once each; $F1 then $F2 file(s); the cursor moved $MOVES times)"

echo "--- K. the cursor's file gone"
q "update pgvigil.mssql_cursor set file_name = '${XELDIR}pgvigil_${ID}_slow_0_100000000000000000.xel', file_offset = 4096 where instance_id=$iid and source='pgvigil_${ID}_slow'" >/dev/null
xe K
[ "$(bk "count(*)")" = 2000 ] || fail "K: $(bk "count(*)") stored after the fallback, want 2000"
[ "$(q "select note like '%could not be read%by event time%' from pgvigil.mssql_xe_state where instance_id=$iid and capture='slow'")" = t ] || fail "K: the note: $(q "select note from pgvigil.mssql_xe_state where instance_id=$iid and capture='slow'")"
[ "$(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'${XELDIR}pgvigil_${ID}_slow*.xel', NULL, NULL, NULL) WHERE file_name = N'$(q "select file_name from pgvigil.mssql_cursor where instance_id=$iid and source='pgvigil_${ID}_slow'")'")" -ge 1 ] || fail "K: the cursor is not on a real file"
echo "  the note: $(q "select left(note, 200) from pgvigil.mssql_xe_state where instance_id=$iid and capture='slow'")"
xe K
[ "$(bk "count(*)")" = 2000 ] || fail "K: the read after the fallback stored something twice"
echo "K: OK"

echo "--- L. stopped is its own state, and holds for two reads"
sq "ALTER EVENT SESSION [pgvigil_${ID}_attention] ON SERVER STATE = STOP;" >/dev/null
xe L
[ "$(q "select state || '|' || reads_in_state from pgvigil.mssql_xe_state where instance_id=$iid and capture='attention'")" = "stopped|1" ] || fail "L: the state after the stop: $(q "select state, reads_in_state from pgvigil.mssql_xe_state where instance_id=$iid and capture='attention'")"
[ "$(q "select count(*) from pgvigil.mssql_xe_findings where instance_id=$iid and check_name like 'a capture is%'")" = 0 ] || fail "L: a finding after one read"
xe L
[ "$(q "select severity || '|' || object from pgvigil.mssql_xe_findings where instance_id=$iid and check_name = 'a capture is stopped'")" = "warning|attention" ] || fail "L: the finding after two reads: $(q "select * from pgvigil.mssql_xe_findings where instance_id=$iid")"
[ "$(q "select count(*) from pgvigil.mssql_xe_findings where instance_id=$iid and check_name = 'a capture is not installed'")" = 0 ] || fail "L: stopped was called not installed"
echo "L: OK"

echo "--- J. AlwaysOn_health"
if [ "$(sq "SELECT CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS int)")" = 1 ] && [ "$(sq "SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name = 'AlwaysOn_health'")" = 1 ]; then
  SA_AG=$(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'AlwaysOn_health*.xel', NULL, NULL, NULL) WHERE object_name = N'availability_replica_state_change' AND CAST(event_data AS xml).value('(event/@timestamp)[1]', 'datetime2') > DATEADD(day, -45, SYSUTCDATETIME())")
  xe J
  [ "$(q "select state || '|' || source from pgvigil.mssql_xe_state where instance_id=$iid and capture='ag'")" = "running|AlwaysOn_health" ] || fail "J: the ag state row"
  [ "$(q "select count(*) from pgvigil.mssql_ag_events where instance_id=$iid and event_name='availability_replica_state_change'")" = "$SA_AG" ] \
    || fail "J: state changes stored $(q "select count(*) from pgvigil.mssql_ag_events where instance_id=$iid and event_name='availability_replica_state_change'"), sa counts $SA_AG"
  echo "J: OK ($SA_AG state change(s); $(q "select count(*) from pgvigil.mssql_ag_events where instance_id=$iid") event(s) stored: $(q "select string_agg(event_name || ' ' || n, ', ' order by event_name) from (select event_name, count(*) n from pgvigil.mssql_ag_events where instance_id=$iid group by 1) x"))"
else
  echo "J: SKIPPED (Always On is not enabled on $CT, or its AlwaysOn_health session is not running)"
fi

echo "--- P. the pages' API over the stored rows"
PORT=$((20000 + RANDOM % 20000))
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG.serve"
"$BIN" serve -config "$CFG.serve" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login >"$OUT.serve" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "P: serve exited: $(cat "$OUT.serve")"
U="http://127.0.0.1:$PORT/api/mssql/xe"
W="instance=$iid&from=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)&to=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)"
# jq-free: python reads the JSON the API returns
py() { python3 -c "$1" "${@:2}"; }
curl -fs "$U?$W" > "$OUT" || fail "P: /api/mssql/xe"
py 'import json, sys
d = json.load(open(sys.argv[1])); db, hb, mark = sys.argv[2], sys.argv[3], sys.argv[4]
rows = lambda k: [dict(zip(d[k]["columns"], r)) for r in d[k]["rows"]]
assert sorted(d) == ["ag_events", "attentions", "blocked", "deadlocks", "findings", "slow_series", "slow_shapes", "state"], sorted(d)
st = {r["capture"]: r for r in rows("state")}
assert all(st[c]["state"] == "running" for c in ("deadlocks", "blocked", "slow")) and st["attention"]["state"] == "stopped", st
dl = [r for r in rows("deadlocks") if r["database_names"] == db]
assert len(dl) == 1 and dl[0]["has_graph"] is True and dl[0]["process_count"] == 2, dl
heads = [r for r in rows("blocked") if (r["blocking_statement"] or "").startswith("BEGIN TRAN; UPDATE dbo.dl_a SET v = 10")]
assert len(heads) == 1 and heads[0]["reports"] >= 1 and heads[0]["head_key"], heads
bulk = [r for r in rows("slow_shapes") if "pgvxe-bulk" not in (r["shape"] or "") and (r["shape"] or "").startswith("SET NOCOUNT ON; WAITFOR DELAY ?")]
assert len(bulk) == 1 and int(bulk[0]["events"]) >= 2000, [(r["shape"], r["events"]) for r in rows("slow_shapes")][:8]
assert sum(int(r["events"]) for r in rows("slow_series")) >= 2001 and len(rows("slow_series")) >= 1
assert any(mark in (r["statement"] or "") for r in rows("attentions")), rows("attentions")
names = {r["check_name"] for r in rows("findings")}
assert "deadlocks in the last hour" in names and "a capture is stopped" in names, names
print(dl[0]["event_at"], dl[0]["event_key"], heads[0]["head_key"], bulk[0]["shape_key"])' "$OUT" "$DB" "$HOSTB" "$AMARK" > "$OUT.ids" || fail "P: the tabs' data"
read -r D_AT D_KEY H_KEY S_KEY < "$OUT.ids"
curl -fs "$U?$W&part=state" | py 'import json, sys; d = json.load(sys.stdin); assert list(d) == ["state"], list(d)' || fail "P: ?part=state"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U?$W&part=nope")" = 400 ] || fail "P: an unknown part was not refused"
curl -fs --get "$U/deadlock" --data-urlencode "instance=$iid" --data-urlencode "at=$D_AT" --data-urlencode "key=$D_KEY" > "$OUT" || fail "P: the deadlock's detail"
py 'import json, sys
d = json.load(open(sys.argv[1])); r = dict(zip(d["columns"], d["rows"][0]))
ps = r["processes"]; assert len(ps) == 2 and sum(1 for p in ps if p["victim"]) == 1 and all(p["statement"].startswith("BEGIN TRAN; UPDATE dbo.dl_") for p in ps), ps
assert len(r["resources"]) == 2 and all(x["owners"] and x["waiters"] for x in r["resources"]), r["resources"]' "$OUT" || fail "P: the deadlock's processes and resources"
curl -fs -D "$OUT.hdr" --get "$U/deadlock.xdl" --data-urlencode "instance=$iid" --data-urlencode "at=$D_AT" --data-urlencode "key=$D_KEY" > "$OUT" || fail "P: the .xdl download"
grep -qi '^content-disposition: attachment; filename="deadlock-proof-xe-'"$SUF"'-[0-9]\{8\}-[0-9]\{6\}\.xdl"' "$OUT.hdr" || { cat "$OUT.hdr"; fail "P: the download's header"; }
[ "$(head -c 10 "$OUT")" = "<deadlock>" ] && [ "$(q "select graph from pgvigil.mssql_deadlocks where instance_id=$iid and database_names='$DB'" | md5sum)" = "$( (cat "$OUT"; echo) | md5sum)" ] || fail "P: the downloaded graph is not the stored one"
[ "$(curl -s -o /dev/null -w '%{http_code}' --get "$U/deadlock.xdl" --data-urlencode "instance=$iid" --data-urlencode "at=$D_AT" --data-urlencode "key=00-0")" = 404 ] || fail "P: an unknown deadlock was not a 404"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/deadlock?instance=$iid&at=x&key=zz")" = 400 ] || fail "P: a bad key was not refused"
curl -fs "$U/blocked?$W&head=$H_KEY" | py 'import json, sys
d = json.load(sys.stdin); rs = [dict(zip(d["columns"], r)) for r in d["rows"]]
assert rs and all(r["blocked_statement"].startswith("UPDATE dbo.dl_a SET v = 11") and r["wait_ms"] >= 5000 for r in rs), rs' || fail "P: the reports of one head"
curl -fs "$U/slow?$W&shape=$S_KEY" | py 'import json, sys
d = json.load(sys.stdin); rs = [dict(zip(d["columns"], r)) for r in d["rows"]]
assert len(rs) == 500 and all(r["host_name"] == sys.argv[1] and "pgvxe-bulk" in r["statement"] for r in rs), len(rs)
ds = [float(r["duration_ms"]) for r in rs]
assert all(a >= b for a, b in zip(ds, ds[1:])), "not slowest first"' "$HOSTB" || fail "P: the events of one shape"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/slow?$W&shape=Robert%27)")" = 400 ] || fail "P: a bad shape key was not refused"
kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=
rm -f "$CFG.serve" "$OUT.serve" "$OUT.ids" "$OUT.hdr"
echo "P: OK"

echo "--- M. nothing else was touched; the printed drop script drops exactly the four"
"$BIN" mssql-xe -print -drop -install-id "$ID" > "$DROP"
[ "$(grep -c 'DROP EVENT SESSION' "$DROP")" = 4 ] && [ "$(grep -c "DROP EVENT SESSION \[pgvigil_${ID}_[a-z]*\] ON SERVER;" "$DROP")" = 4 ] || fail "M: the drop script drops something that is not one of the four"
sqfile "$DROP" | tee "$OUT"
[ "$(grep -c '^dropped: pgvigil_'"$ID"'_' "$OUT")" = 4 ] || fail "M: four sessions dropped"
[ "$(sq "SELECT COUNT(*) FROM sys.server_event_sessions WHERE name LIKE N'pgvigil[_]%'")" = 0 ] || fail "M: a pgvigil session is left"
docker exec "$CT" bash -c "rm -f /var/opt/mssql/log/pgvigil_${ID}_slow_0_*.xel"
MADE_SESS=; OLD_BPT=; OLD_ADV=
others > "$AFTER"
# the two sessions pgvigil reads (system_health, AlwaysOn_health) are there after the proof in the same state, started
# at the same time (within a second). The sandbox is shared: a session of another tool that came, went or restarted
# meanwhile is named and not judged (the proof creates and drops sessions by its own exact names only).
CHANGED=$(awk -F'|' 'NR == FNR { run[$1] = $2; at[$1] = $3; next }
                     { seen[$1] = 1; tag = ($1 == "system_health" || $1 == "AlwaysOn_health") ? "CHANGED: " : "another tool\x27s, not judged: "
                       if (!($1 in run)) { print "another tool\x27s, not judged: " $1 " is new"; next }
                       d = $3 - at[$1]; if (d < 0) d = -d
                       if ($2 != run[$1] || d > 1000) print tag $1 " running " run[$1] " -> " $2 ", started " at[$1] " -> " $3 }
                     END { for (n in run) if (!(n in seen)) print ((n == "system_health" || n == "AlwaysOn_health") ? "CHANGED: " : "another tool\x27s, not judged: ") n " is gone" }' "$BEFORE" "$AFTER")
[ -z "$CHANGED" ] || echo "$CHANGED" | sed 's/^/  /'
if echo "$CHANGED" | grep -q '^CHANGED: '; then fail "M: system_health or AlwaysOn_health changed during the proof"; fi
xe M
[ "$(q "select count(*) from pgvigil.mssql_xe_state where instance_id=$iid and capture <> 'ag' and state = 'not installed'")" = 4 ] || fail "M: the read after the drop"
# with the product's session gone the reader is back on system_health, which holds the proof's deadlock too: the
# same deadlock from the other session is the same row, not a second one
xe_all M
[ "$(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) WHERE object_name = N'xml_deadlock_report' AND CAST(event_data AS nvarchar(max)) LIKE N'%$DB.dbo.dl_a%'")" -ge 1 ] || fail "M: system_health does not hold the proof's deadlock (the check below would prove nothing)"
[ "$(dl "count(*) || '|' || min(source)")" = "1|product" ] || fail "M: the deadlock read again from system_health: $(dl "count(*), string_agg(source, ',')")"
echo "M: OK (system_health and AlwaysOn_health unchanged; four sessions dropped by the printed script)"

echo "--- O. the loss arithmetic and the engine guard, on the repository"
q "select pgvigil.import_mssql_xe($iid, now() + interval '1 minute', '[{\"kind\":\"state\",\"capture\":\"blocked\",\"state\":\"running\",\"source\":\"product\",\"session_name\":\"s_o\",\"target\":\"ring_buffer\",\"total_processed\":100,\"new_events\":100,\"dropped_events\":0}]'::jsonb)" >/dev/null
q "select pgvigil.import_mssql_xe($iid, now() + interval '2 minutes', '[{\"kind\":\"state\",\"capture\":\"blocked\",\"state\":\"running\",\"source\":\"product\",\"session_name\":\"s_o\",\"target\":\"ring_buffer\",\"total_processed\":180,\"new_events\":30,\"dropped_events\":0}]'::jsonb)" >/dev/null
[ "$(q "select missed_events || '|' || lost_events || '|' || (lost_at is not null) from pgvigil.mssql_xe_state where instance_id=$iid and capture='blocked'")" = "50|50|true" ] \
  || fail "O: the loss: $(q "select missed_events, lost_events, lost_at from pgvigil.mssql_xe_state where instance_id=$iid and capture='blocked'")"
# a session started again counts from zero: no loss is read into it
q "select pgvigil.import_mssql_xe($iid, now() + interval '3 minutes', '[{\"kind\":\"state\",\"capture\":\"blocked\",\"state\":\"running\",\"source\":\"product\",\"session_name\":\"s_o\",\"target\":\"ring_buffer\",\"total_processed\":4,\"new_events\":4,\"dropped_events\":0}]'::jsonb)" >/dev/null
[ "$(q "select missed_events from pgvigil.mssql_xe_state where instance_id=$iid and capture='blocked'")" = 0 ] || fail "O: a restarted session read as a loss"
pid=$(q "select pgvigil.ensure_instance('$NP', 'onprem', 'x', 170000, false, '{}')")
if q "select pgvigil.import_mssql_xe($pid, now(), '[]'::jsonb)" >"$OUT" 2>&1; then fail "O: the import ran on a PostgreSQL instance"; fi
grep -q "is not a SQL Server instance" "$OUT" || { cat "$OUT"; fail "O: the refusal's text"; }
echo "O: OK"

echo "--- R. the collector's role reads its cursor through its door and nothing else"
[ "$(q "set role pgvigil_collector; select count(*) from pgvigil.import_mssql_cursor($iid, 'system_health')" | tail -1)" = 1 ] || fail "R: pgvigil_collector cannot read a cursor through import_mssql_cursor"
if q "set role pgvigil_collector; select count(*) from pgvigil.mssql_cursor" >"$OUT" 2>&1; then fail "R: pgvigil_collector reads the cursor table itself"; fi
grep -q "permission denied" "$OUT" || { cat "$OUT"; fail "R: the refusal's text"; }
q "set role pgvigil_collector; select pgvigil.import_mssql_xe($iid, now() + interval '5 minutes', '[{\"kind\":\"cursor\",\"source\":\"r_check\",\"last_seq\":3}]'::jsonb)" >/dev/null || fail "R: pgvigil_collector cannot import"
[ "$(q "select last_seq from pgvigil.import_mssql_cursor($iid, 'r_check')")" = 3 ] || fail "R: the cursor the collector's role stored"
echo "R: OK"

echo "--- S. two instances import at once, each opening a new month on a different event table"
sa=$(q "select pgvigil.ensure_instance('proof-xe-sa-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
sb=$(q "select pgvigil.ensure_instance('proof-xe-sb-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
SA=$(mktemp); SB=$(mktemp)
( for k in $(seq 1 60); do echo "select pgvigil.import_mssql_xe($sa, now(), jsonb_build_array(jsonb_build_object('kind', 'slow', 'event_at', now() - interval '$k months', 'event_key', 'slow-$k', 'event_name', 'rpc_completed', 'duration_us', 1000000)));"; done | psql "$PGVIGIL_REPO_DSN" -XAtq >"$SA" 2>&1 ) &
( for k in $(seq 1 60); do echo "select pgvigil.import_mssql_xe($sb, now(), jsonb_build_array(jsonb_build_object('kind', 'ag_event', 'event_at', now() - interval '$k months', 'event_key', 'ag-$k', 'event_name', 'error_reported')));"; done | psql "$PGVIGIL_REPO_DSN" -XAtq >"$SB" 2>&1 ) &
wait
SE=$(cat "$SA" "$SB" | grep -c ERROR || true); SD=$(cat "$SA" "$SB" | grep ERROR | sort | uniq -c | head -3 || true); rm -f "$SA" "$SB"
[ "$SE" = 0 ] || fail "S: $SE import(s) failed: $SD"
[ "$(q "select (select count(*) from pgvigil.mssql_slow_events where instance_id=$sa) || '|' || (select count(*) from pgvigil.mssql_ag_events where instance_id=$sb)")" = "60|60" ] || fail "S: rows stored: $(q "select (select count(*) from pgvigil.mssql_slow_events where instance_id=$sa), (select count(*) from pgvigil.mssql_ag_events where instance_id=$sb)") (want 60|60)"
echo "S: OK"

echo "N: NOT PROVEN (the Azure SQL Database and Managed Instance forms, AlwaysOn_health on SQL Server 2016, an event file's Windows path on any version but 2016, a live ring buffer overrun, SQL Server 2016 before SP3 and editions other than Developer)"
echo "proof-mssql-xe: PASS (A-M, O, P, R, S)"
