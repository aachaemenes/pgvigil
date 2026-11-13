#!/usr/bin/env bash
# Proof of the Waiting tasks tab (task 177, darling-open D01): pgvigil's read of sys.dm_os_waiting_tasks equals
# PerformanceMonitor's own read of the same server at the same moment, its decoded resource equals a hand read of the
# catalog, the PostgreSQL twin equals a hand read of pg_stat_activity, and both pages render under `pgvigil serve` in a
# headless Chromium with every link landing where it should. Runs on a Linux box with docker (the project's build box).
#
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest), go, psql, curl, python3, node, npm, chromium, git, and
#   ADMIN_DSN        a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                    user=postgres dbname=postgres'); the proof makes its own pgvigil repository database and a scratch
#                    database there and drops both at the end.
#   PGVIGIL_SHOTS    where the page shots go (default: a folder of the run, removed with it)
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment, never a command line.
#
# Expected (written before the first run):
#  A. a SQL Server 2022 container: a database pgvwait with a 200,000-row table; a head session (host pgvw_h) holds an X
#     key lock on id 1 in an open transaction and then waits WAITFOR (a benign wait); a blocked UPDATE of id 1 (host
#     pgvw_b1) waits LCK_M_X on that key; a parallel COUNT(*) of the table (host pgvw_b2, MAXDOP 4, a parallel plan
#     preferred) waits on the same row with more than one task.
#  B. two reads of `pgvigil collect -once mssql_waiting_tasks` through a monitor login (VIEW SERVER STATE; a user in
#     pgvwait with VIEW DEFINITION):
#     B1 PerformanceMonitor's own query (WaitingTasksCollector.cs, verbatim) run as the same login just before and just
#        after the second read returns, for the two blocked sessions, the same multiset of (session, wait type, blocker,
#        database) as pgvigil stored, pgvigil's benign list applied to both;
#     B2 the blocked UPDATE's key resource is decoded to pgvwait.dbo.pgvwait_t, index pk_pgvwait_t, as a hand read of
#        pgvwait's sys.partitions for the resource's hobt id says;
#     B3 the parallel request has more than one row (one per waiting task), as many as PerformanceMonitor's read has;
#     B4 no THREADPOOL finding for the instance (no task waits THREADPOOL; a THREADPOOL provocation is not proven here);
#     B5 the WHERE clause: a session blocked inside a database named PerformanceMonitor (host pgvw_pm) waits in
#        sys.dm_os_waiting_tasks and is in neither PerformanceMonitor's read nor pgvigil's rows (the comparison uses
#        PerformanceMonitor's own ignore list, IgnoredWaitDefaults.All, on both sides). [added after review s177-4]
#     B6 the ignore list: the head (host pgvw_h) waits WAITFOR, one of IgnoredWaitDefaults.All, in a hand read of
#        sys.dm_os_waiting_tasks, and is in neither PerformanceMonitor's read nor pgvigil's rows (B1 compares only the
#        blocked sessions, so without B6 a collector that kept the benign waits would pass); PerformanceMonitor's read
#        before its ignore list does hold the head's WAITFOR row (its WHERE keeps the head). [added after s177-final1]
#  C. the PostgreSQL twin: in a scratch database a row is updated in an open transaction, the same row updated by a
#     second session; after `pgvigil collect -once activity`, pg_waiting_at holds the second session with
#     Lock:transactionid and blocking_pids = {the first session's pid}, as pg_stat_activity and pg_blocking_pids read
#     just before the sample say.
#  D. `pgvigil serve` built from a copy of this tree with the join's wiring (scripts/proof-darling-waiting-join.patch)
#     and, while the join does not hold it, rel-join-w1 962c116's pages.ts fix (scripts/proof-darling-waiting-base.patch)
#     applied (on the release join neither patch file is in the tree: the run fails unless web/src/main.ts names
#     mssqlWaitingView, and the tree is used as it is)
#     and the web bundle rebuilt: GET /api/waiting returns 2 reads, the newest read's tasks equal to the
#     store's rows, and the PostgreSQL waiter.
#  E. the pages in a headless Chromium signed in as a UI user: #/mssql_waiting?i=<id> shows the tiles of the newest read
#     as the store holds them (tasks, sessions, blocked by another session, THREADPOOL 0) and as many grid rows as the
#     read [s177-proof1 counted a parallel task blocked by its own session as blocked; the tile no longer does]; a wait type in
#     the grid lands on wt=<it> with only its rows; 'show every wait' lands back; Earlier lands on the first read and
#     Later on the second, each at= the read's exact time as the API gives it and the 'Read at' line naming another read
#     [the exact-time check added after review s177-4]; a wait type of 'Wait types over the range' lands filtered on the
#     read where it was last seen, with rows; the Waits tab's wait type
#     (#/mssql_waits) lands on #/mssql_waiting with wt; #/waiting?i=<pg id> shows the waiter and its wait link lands
#     filtered. Both pages shot in the light and the dark theme.
# NOT PROVEN HERE: a THREADPOOL wait (the finding), a page-latch resource decoded through sys.dm_db_page_info, a read
# of more than 2,000 tasks (the cap), Azure SQL and SQL Server 2016-2019, the PostgreSQL lock's target relation (not
# sampled).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvw-sql-$SUF; HOSTN=pgvw$SUF; LBL=pgvigil-proof=s177
PGDB=pgv_wait_$SUF; SCR=pgv_wait_scr_$SUF; MON=pgv_wmon_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=; BG=()
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
printf 'SQLCMDPASSWORD=%s\n' "$MON_PW" > "$TMPD/mon.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  for p in "${BG[@]}"; do kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  for d in "$PGDB" "$SCR"; do
    psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $d WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $d not dropped" >&2
  done
  rm -rf "$TMPD"
}
trap cleanup EXIT
# sq: T-SQL as sa (stdin, never a command line); sqmon: as the monitor login; sqok: output not wanted, a failure loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqmon() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/mon.env" "$SQL" /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$MON" -C -b -W -h -1 -s "|" -d master -i /dev/stdin; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
# urlq: the value through the environment, never an argument (a password is one)
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
for t in docker go psql curl python3 node npm chromium git; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== A. the waiting tasks on a SQL Server 2022 container =="
docker run -d --name "$SQL" --hostname "$HOSTN" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
ready=
for _ in $(seq 1 90); do ready=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true); [[ "$ready" == 1 ]] && break; sleep 2; done
[[ "$ready" == 1 ]] || fail "A: the SQL Server container did not come up in 180 s"
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
sqok "A: the database" "CREATE DATABASE pgvwait;"
sqok "A: the table" "CREATE TABLE dbo.pgvwait_t (id int NOT NULL CONSTRAINT pk_pgvwait_t PRIMARY KEY, pad char(200) NOT NULL DEFAULT 'a');
  INSERT dbo.pgvwait_t (id) SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvwait
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON];"
sqok "A: the monitor's user" "CREATE USER [$MON] FOR LOGIN [$MON]; GRANT VIEW DEFINITION TO [$MON];" pgvwait
# the sessions: each a sqlcmd of its own, named by its host (-H)
sess() { printf '%s\n' "$2" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -d pgvwait -H "$0" -i /dev/stdin' "$1" >/dev/null 2>&1 & BG+=($!); }
sid() { sq "SELECT MIN(session_id) FROM sys.dm_exec_sessions WHERE host_name = '$1'"; }
sess pgvw_h "BEGIN TRAN; UPDATE dbo.pgvwait_t SET pad = 'h' WHERE id = 1; WAITFOR DELAY '00:15:00';"
for _ in $(seq 1 30); do H=$(sid pgvw_h); [[ "$H" =~ ^[0-9]+$ ]] && [[ "$(sq "SELECT COUNT(*) FROM sys.dm_tran_locks WHERE request_session_id = $H AND resource_type = 'KEY' AND request_mode = 'X'")" == 1 ]] && break; sleep 1; done
[[ "${H:-}" =~ ^[0-9]+$ ]] || fail "A: the head session did not take its lock"
sess pgvw_b1 "UPDATE dbo.pgvwait_t SET pad = 'b' WHERE id = 1;"
sess pgvw_b2 "SELECT COUNT(*) FROM dbo.pgvwait_t WHERE pad <> 'z' OPTION (MAXDOP 4, USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE'));"
B1=; B2=; n2=0
for _ in $(seq 1 60); do
  B1=$(sid pgvw_b1); B2=$(sid pgvw_b2)
  if [[ "$B1" =~ ^[0-9]+$ && "$B2" =~ ^[0-9]+$ ]]; then
    w1=$(sq "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE session_id = $B1 AND wait_type = 'LCK_M_X'")
    n2=$(sq "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE session_id = $B2")
    l2=$(sq "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE session_id = $B2 AND wait_type LIKE 'LCK_M_S%'")
    [[ "$w1" == 1 && "$l2" -ge 1 && "$n2" -ge 2 ]] && break
  fi
  sleep 1
done
[[ "${w1:-0}" == 1 ]] || fail "A: the blocked UPDATE does not wait LCK_M_X (session ${B1:-?})"
(( n2 >= 2 )) || fail "A: the parallel COUNT(*) has $n2 waiting task(s), not more than one (session ${B2:-?}; a serial plan?)"
# B5's fixture: the same chain inside a database named PerformanceMonitor (PerformanceMonitor leaves its own database out)
sqok "A: the PerformanceMonitor database" "CREATE DATABASE PerformanceMonitor;"
sqok "A: its table" "CREATE TABLE dbo.pm_t (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0); INSERT dbo.pm_t (id) VALUES (1);" PerformanceMonitor
spm() { printf '%s\n' "$2" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -d PerformanceMonitor -H "$0" -i /dev/stdin' "$1" >/dev/null 2>&1 & BG+=($!); }
spm pgvw_pmh "BEGIN TRAN; UPDATE dbo.pm_t SET v = 1 WHERE id = 1; WAITFOR DELAY '00:15:00';"
sleep 2
spm pgvw_pm "UPDATE dbo.pm_t SET v = 2 WHERE id = 1;"
for _ in $(seq 1 30); do B3=$(sid pgvw_pm); [[ "$B3" =~ ^[0-9]+$ ]] && [[ "$(sq "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE session_id = $B3 AND wait_type = 'LCK_M_X'")" == 1 ]] && break; sleep 1; done
[[ "${B3:-}" =~ ^[0-9]+$ ]] || fail "A: the PerformanceMonitor-database session does not wait"
echo "ok   A: head $H holds the key; $B1 waits LCK_M_X; the parallel request $B2 waits with $n2 tasks; $B3 waits inside PerformanceMonitor"

echo "== B. pgvigil's read against PerformanceMonitor's =="
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $SCR" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
SCRDSN="$ADMIN_DSN"; SCRDSN="${SCRDSN/dbname=postgres/dbname=$SCR}"; [[ "$SCRDSN" == *"dbname=$SCR"* ]] || SCRDSN="$SCRDSN dbname=$SCR"
export PGV_W_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
export PGV_W_PG="$SCRDSN"
cat > "$TMPD/w.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_W_MON
  - name: pgbox
    dsn: env:PGV_W_PG
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/w.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
# PerformanceMonitor's query, verbatim (PerformanceMonitor.Collectors/WaitingTasksCollector.cs, v3.12.0; its
# /*EXCLUSION_FILTER*/ splice empty, as with no excluded database)
cat > "$TMPD/pm.sql" <<'EOF'
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT /* PerformanceMonitorLite */
    session_id = wt.session_id,
    wait_type = wt.wait_type,
    wait_duration_ms = wt.wait_duration_ms,
    /* #6896: a memory-grant wait can name this collector's own session as the blocker. The wait is real, so keep the row and drop the blocker. */
    blocking_session_id = NULLIF(wt.blocking_session_id, @@SPID),
    database_name = d.name
FROM sys.dm_os_waiting_tasks AS wt
LEFT JOIN sys.dm_exec_requests AS er
  ON er.session_id = wt.session_id
LEFT JOIN sys.databases AS d
  ON d.database_id = er.database_id
WHERE wt.session_id >= 50
AND   wt.session_id <> @@SPID
AND   wt.wait_type IS NOT NULL
AND   er.database_id <> ISNULL(DB_ID(N'PerformanceMonitor'), 0)

OPTION(RECOMPILE);
EOF
PGVIGIL_PRINT_BENIGN=1 go test -count=1 -run '^TestPrintBenign$' -v ./internal/mssql 2>/dev/null | sed -n 's/^benign //p' | sort > "$TMPD/benign.txt"
(( $(wc -l < "$TMPD/benign.txt") > 20 )) || fail "B: pgvigil's benign list was not printed"
# pm: PerformanceMonitor's read as '<session>|<wait>|<blocker>|<database>', the benign waits left out, sorted
pm() { sqmon "$(cat "$TMPD/pm.sql")" | awk -F'|' 'NF>=5 {gsub(/ /,"",$1); gsub(/ /,"",$2); b=$4; if (b=="NULL") b=""; d=$5; if (d=="NULL") d=""; print $1"|"$2"|"b"|"d}' | grep -vwFf "$TMPD/benign.txt" | sort || true; }
"$TMPD/pgvigil" collect -config "$TMPD/w.yaml" -instance sqlbox -once mssql_waiting_tasks >"$TMPD/c1.out" 2>&1 || { cat "$TMPD/c1.out" >&2; fail "B: the first collect"; }
sleep 2
pm > "$TMPD/pm_before.txt"
"$TMPD/pgvigil" collect -config "$TMPD/w.yaml" -instance sqlbox -once mssql_waiting_tasks >"$TMPD/c2.out" 2>&1 || { cat "$TMPD/c2.out" >&2; fail "B: the second collect"; }
pm > "$TMPD/pm_after.txt"
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
[[ "$(pq "SELECT count(*) FROM pgvigil.mssql_waiting_summary WHERE instance_id = $SB")" == 2 ]] || fail "B: the store holds $(pq "SELECT count(*) FROM pgvigil.mssql_waiting_summary WHERE instance_id = $SB") reads, not 2"
LAST=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_waiting_summary WHERE instance_id = $SB")
pq "SELECT session_id || '|' || wait_type || '|' || coalesce(blocking_session_id::text, '') || '|' || coalesce(database_name, '')
      FROM pgvigil.mssql_waiting_tasks WHERE instance_id = $SB AND snapshot_at = '$LAST'" | sort > "$TMPD/pgv.txt"
mine() { grep -E "^($B1|$B2)\|" "$1" || true; }
if ! diff <(mine "$TMPD/pm_before.txt") <(mine "$TMPD/pgv.txt") >"$TMPD/d1" || ! diff <(mine "$TMPD/pm_after.txt") <(mine "$TMPD/pgv.txt") >"$TMPD/d2"; then
  echo "PerformanceMonitor before:"; mine "$TMPD/pm_before.txt"; echo "pgvigil:"; mine "$TMPD/pgv.txt"; echo "PerformanceMonitor after:"; mine "$TMPD/pm_after.txt"
  fail "B1: pgvigil's rows for sessions $B1 and $B2 differ from PerformanceMonitor's read"
fi
nb1=$(mine "$TMPD/pgv.txt" | wc -l)
echo "ok   B1: sessions $B1 and $B2: $nb1 row(s), the same (session, wait, blocker, database) multiset as PerformanceMonitor's own read before and after the collect"
RES=$(sq "SELECT resource_description FROM sys.dm_os_waiting_tasks WHERE session_id = $B1 AND wait_type = 'LCK_M_X'")
HOBT=$(echo "$RES" | sed -n 's/.*hobtid=\([0-9]*\).*/\1/p')
[[ "$HOBT" =~ ^[0-9]+$ ]] || fail "B2: no hobt id in the resource '$RES'"
HAND=$(sq "SELECT DB_NAME() + '.' + OBJECT_SCHEMA_NAME(p.object_id) + '.' + OBJECT_NAME(p.object_id) + '|' + i.name FROM sys.partitions p JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id WHERE p.hobt_id = $HOBT" pgvwait)
GOT=$(pq "SELECT object_name || '|' || index_name FROM pgvigil.mssql_waiting_tasks WHERE instance_id = $SB AND snapshot_at = '$LAST' AND session_id = $B1 AND wait_type = 'LCK_M_X'")
[[ "$HAND" == "pgvwait.dbo.pgvwait_t|pk_pgvwait_t" && "$GOT" == "$HAND" ]] || fail "B2: the decoded resource '$GOT', the hand read '$HAND' (want pgvwait.dbo.pgvwait_t|pk_pgvwait_t)"
echo "ok   B2: the key resource (hobt $HOBT) decoded to $GOT, as pgvwait's sys.partitions reads"
pmn=$(grep -c "^$B2|" "$TMPD/pm_after.txt" || true); pgn=$(grep -c "^$B2|" "$TMPD/pgv.txt" || true)
ctx=$(pq "SELECT count(DISTINCT exec_context_id) FROM pgvigil.mssql_waiting_tasks WHERE instance_id = $SB AND snapshot_at = '$LAST' AND session_id = $B2")
(( pgn > 1 && pgn == pmn )) || fail "B3: the parallel request has $pgn stored row(s), PerformanceMonitor's read $pmn"
echo "ok   B3: the parallel request $B2: $pgn tasks stored over $ctx exec context(s), as many as PerformanceMonitor's read"
[[ "$(pq "SELECT count(*) FROM pgvigil.mssql_waiting_findings WHERE instance_id = $SB")" == 0 ]] || fail "B4: a THREADPOOL finding without a THREADPOOL wait"
echo "ok   B4: no THREADPOOL finding (threadpool $(pq "SELECT threadpool FROM pgvigil.mssql_waiting_summary WHERE instance_id = $SB AND snapshot_at = '$LAST'"))"
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE session_id = $B3")" -ge 1 ]] || fail "B5: session $B3 no longer waits"
! grep -q "^$B3|" "$TMPD/pm_before.txt" "$TMPD/pm_after.txt" "$TMPD/pgv.txt" || fail "B5: session $B3 (inside PerformanceMonitor) is in a read: $(grep -h "^$B3|" "$TMPD/pm_before.txt" "$TMPD/pm_after.txt" "$TMPD/pgv.txt" | head -3)"
echo "ok   B5: session $B3 waits inside PerformanceMonitor and is in neither PerformanceMonitor's read nor pgvigil's rows"
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE session_id = $H AND wait_type = 'WAITFOR'")" -ge 1 ]] || fail "B6: the head $H does not wait WAITFOR"
grep -qx 'WAITFOR' "$TMPD/benign.txt" || fail "B6: WAITFOR is not in pgvigil's copy of PerformanceMonitor's ignore list"
sqmon "$(cat "$TMPD/pm.sql")" > "$TMPD/pm_raw.txt" || fail "B6: PerformanceMonitor's read (unfiltered)"
[[ "$(awk -F'|' 'NF>=5 {gsub(/ /,"",$1); gsub(/ /,"",$2); print $1"|"$2}' "$TMPD/pm_raw.txt" | grep -cx "$H|WAITFOR" || true)" -ge 1 ]] \
  || fail "B6: PerformanceMonitor's read before its ignore list has no WAITFOR row for the head $H (its WHERE drops the head, so B6 would test nothing)"
! grep -q "^$H|" "$TMPD/pm_before.txt" "$TMPD/pm_after.txt" "$TMPD/pgv.txt" || fail "B6: the head $H (WAITFOR) is in a read: $(grep -h "^$H|" "$TMPD/pm_before.txt" "$TMPD/pm_after.txt" "$TMPD/pgv.txt" | head -3 | tr '\n' ' ')"
echo "ok   B6: the head $H waits WAITFOR in sys.dm_os_waiting_tasks and is in neither read (PerformanceMonitor's ignore list applied by the collector)"
"$TMPD/pgvigil" collect -config "$TMPD/w.yaml" -instance sqlbox -once mssql_waits >/dev/null 2>&1 || true
sleep 3
"$TMPD/pgvigil" collect -config "$TMPD/w.yaml" -instance sqlbox -once mssql_waits >/dev/null 2>&1 || true

echo "== C. the PostgreSQL twin =="
psql "$SCRDSN" -Xqc "CREATE TABLE pgvw_t (id int PRIMARY KEY, v int); INSERT INTO pgvw_t VALUES (1, 0);" >/dev/null
psql "$SCRDSN" -Xq -c "SET application_name = 'pgvw_holder'" -c "BEGIN" -c "UPDATE pgvw_t SET v = 1 WHERE id = 1" -c "SELECT pg_sleep(900)" >/dev/null 2>&1 & BG+=($!)
for _ in $(seq 1 30); do HP=$(psql "$SCRDSN" -XAtqc "SELECT pid FROM pg_stat_activity WHERE application_name = 'pgvw_holder' AND wait_event = 'PgSleep'"); [[ "$HP" =~ ^[0-9]+$ ]] && break; sleep 0.5; done
[[ "${HP:-}" =~ ^[0-9]+$ ]] || fail "C: the holder did not start"
PGAPPNAME=pgvw_waiter psql "$SCRDSN" -Xqc "UPDATE pgvw_t SET v = 2 WHERE id = 1" >/dev/null 2>&1 & BG+=($!)
for _ in $(seq 1 30); do WP=$(psql "$SCRDSN" -XAtqc "SELECT pid FROM pg_stat_activity WHERE application_name = 'pgvw_waiter' AND wait_event_type = 'Lock'"); [[ "$WP" =~ ^[0-9]+$ ]] && break; sleep 0.5; done
[[ "${WP:-}" =~ ^[0-9]+$ ]] || fail "C: the waiter does not wait on a lock"
HANDPG=$(psql "$SCRDSN" -XAtqc "SELECT wait_event_type || ':' || wait_event || '|' || array_to_string(pg_blocking_pids(pid), ',') FROM pg_stat_activity WHERE pid = $WP")
"$TMPD/pgvigil" collect -config "$TMPD/w.yaml" -instance pgbox -once activity >"$TMPD/c3.out" 2>&1 || { cat "$TMPD/c3.out" >&2; fail "C: collect activity"; }
PGI=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'pgbox'")
GOTPG=$(pq "SELECT wait_event_type || ':' || wait_event || '|' || array_to_string(blocking_pids, ',') FROM pgvigil.pg_waiting_at($PGI, NULL, NULL) WHERE pid = $WP")
[[ "$HANDPG" == "Lock:transactionid|$HP" && "$GOTPG" == "$HANDPG" ]] || fail "C: the twin's row '$GOTPG', the hand read '$HANDPG' (want Lock:transactionid|$HP)"
echo "ok   C: the waiter $WP: $GOTPG, as pg_stat_activity and pg_blocking_pids read"

echo "== D. the API under pgvigil serve (a copy of the tree, with the wiring patches when present) =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
for p in scripts/proof-darling-waiting-base.patch scripts/proof-darling-waiting-join.patch; do
  if [ ! -f "$GSRC/$p" ]; then
    grep -q mssqlWaitingView "$GSRC/web/src/main.ts" || fail "D: no $p and the tree lacks the join's wiring (web/src/main.ts has no mssqlWaitingView)"
    echo "D: no $p in the tree: the release join carries it (the tree is used as it is)"
  elif (cd "$GSRC" && git apply --check -R "$p" 2>/dev/null); then echo "D: $p is already in this tree"
  elif (cd "$GSRC" && git apply "$p" 2>"$TMPD/apply.err"); then echo "D: $p applied to the run's copy"
  else fail "D: $p neither applies nor is applied: $(cat "$TMPD/apply.err")"; fi
done
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "D: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil-g" ./cmd/pgvigil) || fail "D: the build"
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil-g" user add -config "$TMPD/w.yaml" "$USR" >/dev/null 2>&1 || fail "D: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
"$TMPD/pgvigil-g" serve -config "$TMPD/w.yaml" -listen "127.0.0.1:$PORT" >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "D: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "D: the UI login"
curl -s -b "$TMPD/cj" "$U/api/waiting?instance=$SB" > "$TMPD/api.json"
curl -s -b "$TMPD/cj" "$U/api/waiting?instance=$PGI" > "$TMPD/apipg.json"
api=$(python3 - "$TMPD/api.json" "$TMPD/apipg.json" "$WP" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); g = json.load(open(sys.argv[2]))
rows = lambda t: [dict(zip(t["columns"], r)) for r in (t or {}).get("rows") or []]
s, t = rows(d.get("snapshots")), rows(d.get("tasks"))
pg = [r for r in rows(g.get("pg")) if str(r.get("pid")) == sys.argv[3]]
print(len(s), len(t), len(pg), "|".join(sorted(f"{r['session_id']}|{r['wait_type']}|{'' if r['blocking_session_id'] is None else r['blocking_session_id']}|{r['database_name'] or ''}" for r in t)))
EOF
)
read -r ns nt npg arows <<<"$api"
[[ "$ns" == 2 && "$nt" == "$(wc -l < "$TMPD/pgv.txt")" && "$npg" == 1 ]] || fail "D: the API: $ns reads, $nt tasks, $npg PostgreSQL waiter (want 2, $(wc -l < "$TMPD/pgv.txt"), 1)"
[[ "$arows" == "$(paste -sd'|' "$TMPD/pgv.txt")" ]] || fail "D: the API's tasks differ from the store's rows"
echo "ok   D: GET /api/waiting: 2 reads, the newest read's $nt task(s) equal to the store's rows; the PostgreSQL waiter"

echo "== E. the pages in headless Chromium =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1000 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "E: chromium's CDP port never answered"
cat > "$TMPD/e.mjs" <<'JS'
// prints one line per check; the shell grades them
const [port, U, sb, pgi, shots] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0; })()`); if (ok) { await sleep(400); return true; } await sleep(200); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
const state = () => ev(`(() => { const m = document.querySelector('main'); const tiles = Object.fromEntries([...m.querySelectorAll('.tile')].map(t => [t.querySelector('.tile-l')?.textContent, t.querySelector('.tile-v')?.textContent]));
  const h3 = [...m.querySelectorAll('h3')].find(h => /^The (tasks|backends) of this/.test(h.textContent)); let g = h3?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE') g = g.nextElementSibling;
  const trs = g ? [...g.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')) : [];
  const waits = trs.map(tr => [...tr.querySelectorAll('a')].map(a => a.textContent)[0]).filter(Boolean);
  return JSON.stringify({ hash: location.hash, tiles, rows: trs.length, waits, errors: m.querySelectorAll('.error:not([role=status])').length,
    links: [...m.querySelectorAll('a')].map(a => ({ t: a.textContent, h: a.getAttribute('href') })) }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.E_USR)}, password: ${JSON.stringify(process.env.E_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
for (const theme of ['light', 'dark']) {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  if (!await go(`#/mssql_waiting?i=${sb}`)) { console.log(`FAIL render mssql ${theme}`); continue; }
  const s = await state(); console.log(`page mssql ${theme} ${JSON.stringify({ tiles: s.tiles, rows: s.rows, errors: s.errors })}`); await shot(`waiting-mssql-${theme}`);
  if (!await go(`#/waiting?i=${pgi}`)) { console.log(`FAIL render pg ${theme}`); continue; }
  const p = await state(); console.log(`page pg ${theme} ${JSON.stringify({ tiles: p.tiles, rows: p.rows, errors: p.errors })}`); await shot(`waiting-pg-${theme}`);
}
// the links (light theme state kept from the last page; dark is fine for links)
await go(`#/mssql_waiting?i=${sb}`);
let s = await state();
const wl = s.links.find(l => /wt=/.test(l.h ?? '') && s.waits.includes(l.t));
if (wl) { await go(wl.h); const f = await state(); console.log(`link grid-wait ${wl.t} hash=${f.hash.includes('wt=' + wl.t)} rows=${f.rows} only=${f.waits.every(w => w === wl.t)}`);
  const back = f.links.find(l => l.t === 'show every wait'); if (back) { await go(back.h); const b = await state(); console.log(`link show-every hash=${!b.hash.includes('wt=')} rows=${b.rows}`); } else console.log('link show-every missing'); }
else console.log('link grid-wait missing');
s = await state();
for (const name of ['Earlier', 'Later', 'Latest']) {
  await go(`#/mssql_waiting?i=${sb}`); s = await state();
  if (name !== 'Earlier') { const e = s.links.find(l => l.t === 'Earlier'); if (e) { await go(e.h); s = await state(); } }
  const l = s.links.find(x => x.t === name);
  if (!l) { console.log(`link ${name} missing`); continue; }
  await go(l.h); const r = await state();
  const at = new URLSearchParams(r.hash.split('?')[1] ?? '').get('at');
  // the read line by its own label: the instance header's chips are role 'group' too (instheader.ts chipEl)
  const read = await ev(`(document.querySelector('main [role=group][aria-label="Read at in view"]')?.textContent ?? '').split(' (')[0]`);
  console.log(`link ${name} at=${at ?? 'latest'} errors=${r.errors} read=${read}`);
}
await go(`#/mssql_waiting?i=${sb}`); s = await state();
// the range's wait types: the last links of the page (the tasks grid's come first)
const tl = s.links.filter(l => /wt=/.test(l.h ?? '')).pop();
if (tl) { await go(tl.h); const f = await state(); console.log(`link bytype ${tl.t} hash=${f.hash.includes('wt=' + tl.t)} only=${f.waits.every(w => w === tl.t)} rows=${f.rows}`); } else console.log('link bytype missing');
await go(`#/mssql_waits?i=${sb}`); s = await state();
const wa = s.links.find(l => (l.h ?? '').startsWith('#/mssql_waiting?'));
if (wa) { await go(wa.h); const f = await state(); console.log(`link waits-tab ${wa.t} landed=${f.hash.startsWith('#/mssql_waiting?') && f.hash.includes('wt=')} errors=${f.errors}`); } else console.log('link waits-tab missing');
await go(`#/waiting?i=${pgi}`); s = await state();
const pl = s.links.find(l => /wt=Lock/.test(l.h ?? ''));
if (pl) { await go(pl.h); const f = await state(); console.log(`link pg-wait ${pl.t} hash=${f.hash.includes('wt=')} only=${f.waits.every(w => w === pl.t)} rows=${f.rows}`); } else console.log('link pg-wait missing');
ws.close(); process.exit(0);
JS
out=$(E_USR="$USR" E_UPW="$UPW" node "$TMPD/e.mjs" "$CDP" "$U/" "$SB" "$PGI" "$SHOTS") || fail "E: the Chromium walk stopped: $out"
echo "$out"
echo "$out" | grep -q '^login 200$' || fail "E: the UI login in Chromium"
! echo "$out" | grep -q '^FAIL\|missing' || fail "E: a page or a link: $(echo "$out" | grep '^FAIL\|missing' | head -3)"
ST=$(pq "SELECT tasks FROM pgvigil.mssql_waiting_summary WHERE instance_id = $SB AND snapshot_at = '$LAST'"); SS=$(pq "SELECT sessions FROM pgvigil.mssql_waiting_summary WHERE instance_id = $SB AND snapshot_at = '$LAST'")
SBL=$(pq "SELECT count(*) FROM pgvigil.mssql_waiting_tasks WHERE instance_id = $SB AND snapshot_at = '$LAST' AND blocking_session_id IS NOT NULL AND blocking_session_id <> session_id")
NR=$(wc -l < "$TMPD/pgv.txt")
for theme in light dark; do
  line=$(echo "$out" | grep "^page mssql $theme ")
  echo "$line" | grep -q "\"Tasks waiting\":\"$ST\"" && echo "$line" | grep -q "\"Sessions\":\"$SS\"" && echo "$line" | grep -q "\"Blocked by a session\":\"$SBL\"" \
    && echo "$line" | grep -q '"THREADPOOL waiters":"0"' && echo "$line" | grep -q "\"rows\":$NR," && echo "$line" | grep -q '"errors":0' || fail "E: the SQL Server page ($theme): $line (want tasks $ST, sessions $SS, blocked $SBL, THREADPOOL 0, $NR rows)"
  echo "$out" | grep "^page pg $theme " | grep -q '"errors":0' || fail "E: the PostgreSQL page ($theme)"
done
# the two reads' times exactly as the API writes them
read -r FIRST SECOND <<<"$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); t=d["snapshots"]; i=t["columns"].index("snapshot_at"); print(*[r[i] for r in t["rows"]])' "$TMPD/api.json")"
[[ -n "$FIRST" && -n "$SECOND" && "$FIRST" != "$SECOND" ]] || fail "E: the API's two read times: '$FIRST' '$SECOND'"
echo "$out" | grep -q "^link grid-wait .* hash=true rows=[1-9][0-9]* only=true$" || fail "E: the grid's wait link"
echo "$out" | grep -q "^link show-every hash=true rows=$NR$" || fail "E: 'show every wait'"
echo "$out" | grep -qF "link Earlier at=$FIRST errors=0 read=" || fail "E: Earlier (want at=$FIRST exactly): $(echo "$out" | grep '^link Earlier')"
echo "$out" | grep -qF "link Later at=$SECOND errors=0 read=" || fail "E: Later (want at=$SECOND exactly): $(echo "$out" | grep '^link Later')"
echo "$out" | grep -q "^link Latest at=latest errors=0 read=" || fail "E: Latest"
rE=$(echo "$out" | sed -n 's/^link Earlier .* read=//p'); rL=$(echo "$out" | sed -n 's/^link Later .* read=//p'); rN=$(echo "$out" | sed -n 's/^link Latest .* read=//p')
[[ -n "$rE" && "$rE" != "$rL" && "$rN" == "$rL" ]] || fail "E: the 'Read at' lines: Earlier '$rE', Later '$rL', Latest '$rN' (want Earlier another read, Latest = Later)"
echo "$out" | grep -q "^link bytype .* hash=true only=true rows=[1-9]" || fail "E: a wait type of 'Wait types over the range' (it must land on rows)"
echo "$out" | grep -q "^link waits-tab .* landed=true errors=0$" || fail "E: the Waits tab's wait-type link"
echo "$out" | grep -q "^link pg-wait Lock:transactionid hash=true only=true rows=[1-9]" || fail "E: the PostgreSQL wait link"
echo "ok   E: both pages in light and dark (tiles = the store: tasks $ST, sessions $SS, blocked $SBL, THREADPOOL 0; $NR rows), every link landed; shots in $SHOTS"
echo "proof-darling-waiting: OK (PerformanceMonitor's read equal for the blocked sessions; the resource decoded as the catalog says; the PostgreSQL twin equal to pg_stat_activity; the pages and their links in Chromium)"
