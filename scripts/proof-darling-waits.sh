#!/usr/bin/env bash
# Proof of the wait findings (task 177, darling-open D03): on a SQL Server 2022 container the proof makes THREADPOOL,
# RESOURCE_SEMAPHORE, forced grants, range-lock waits, tempdb page latches and CPU pressure, collects mssql_waits,
# mssql_memory and mssql_tempdb with pgvigil around them, and compares pgvigil's findings over the window
# (pgvigil.mssql_wait_findings_between, 0115) with the procedures' own output on the same server: sp_BlitzFirst over
# its own sample inside the window, sp_PerfCheck and sp_Blitz since the server's start. Then the Waits page and its
# API under `pgvigil serve` in a headless Chromium, every link of the page clicked.
#
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest), go, psql, curl, python3, node, npm, chromium, git;
#   ADMIN_DSN         a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                     user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_PROC_DIR  the procedures' own source files (default .lab/procs, git-ignored): sp_PerfCheck.sql (DarlingData,
#                     MIT), sp_Blitz.sql and sp_BlitzFirst.sql (SQL Server First Responder Kit, MIT); never fetched.
#   PGVIGIL_SHOTS     where the page shots go (default: a folder of the run, removed with it)
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# Expected (written before the first full run; probes 1-2 found the provocations):
#  A. the container with max worker threads 128, max server memory 2048 MB, tempdb cut to 2 data files (so sp_PerfCheck's
#     tempdb check can fire: it wants fewer than 8 and no more than the CPUs), restarted; the three procedures installed.
#  B. window 1: the wait counters cleared, pgvigil's read #0 (mssql_waits, mssql_memory, mssql_tempdb), sp_BlitzFirst
#     (@Seconds 200, its findings into a table) sampling, then inside its sample: THREADPOOL (40 parallel scans behind
#     an exclusive lock, 128 workers), RESOURCE_SEMAPHORE (16 sorts with MIN_GRANT_PERCENT 100), forced grants ('query
#     wait (s)' 1 behind held grants), range locks (8 SERIALIZABLE range scans behind a key lock, more than 60 s in all),
#     tempdb page latches (32 sessions creating temp tables); sp_BlitzFirst ends; pgvigil's read #1; sp_PerfCheck and
#     sp_Blitz at once. Graded:
#     B1 sp_BlitzFirst CheckID 30: the same poison wait types as pgvigil's check-30 rows, each with the same seconds
#        (every provoked wait ends inside its sample, so its difference and pgvigil's are the same waits); THREADPOOL
#        and RESOURCE_SEMAPHORE among them.
#     B2 sp_PerfCheck: its numbers are over the time since the start (U), pgvigil's over the window read (W); the
#        counters were cleared at read #0, so a source share x U/W is the window's share. Each 6001 row of the source:
#        pgvigil has it with the same finding, its share = the source's x U/W within 2 %, and its priority = sp_PerfCheck's
#        own rule applied to that rescaled share and the source's average (exactly); a 6001 row pgvigil alone has must be
#        one the source leaves out by its 10 % of U (the denominator), else FAIL. Required on both sides (provoked):
#        6001 THREADPOOL, RESOURCE_SEMAPHORE and LCK_M_RS_S, 4101 (forced grants equal, priority equal) and 2010 (the
#        hours equal within 0.01, the data files and "up to" equal, priority equal, pgvigil's share = a hand read of the
#        page latch time / W within 2 %: the source's share divides two hour counts rounded to 0.01 and is not
#        rescalable). 6102 and 6101 when raised: on both sides, 6102 rescaled with its band, 6101 within 0.5 point and
#        the same priority; raised on neither = NOT PROVEN in window 1 (graded in C).
#     B3 sp_Blitz 107 (poison, since the start): each type it lists is a pgvigil check-30 row whose seconds equal its
#        D:HH:MM:SS within 2 s; 117: its forced grants equal the sum of pgvigil's differences over the semaphores; 121
#        (range locks) on both sides, its time within 2 s; 162 on neither (the container has one NUMA node, read back).
#     B4 the semaphores: pgvigil's rows of read #1 equal a hand read of sys.dm_exec_query_resource_semaphores taken
#        just before or just after it (target, max target, total, available, granted, used, grantees, waiters, both
#        counters); on the small-query semaphores (id 1) available / granted / used hold each reader's own query's
#        grant, so there they are compared as available + granted = total [run 2]; the forced grants of the window
#        equal the DMV's count since the start.
#  C. window 2: the counters cleared, read #2, 32 busy sessions for 30 s on 16 schedulers, read #3, sp_PerfCheck: its
#     signal wait ratio and label equal pgvigil's over (read #2, read #3] within 1 point, its 6101 row and priority on
#     both sides; its 6102 share x U2/W2 = pgvigil's within 2 % with the band's priority. [6102 added after review d03]
#  D. `pgvigil serve` built from a copy of the tree (the route and the findings arm are the release join's: web.go and
#     0190; a tree that still carries scripts/proof-darling-waits-wiring.patch gets it applied to the copy): GET /api/mssql/waitfindings over window 1 returns the function's findings (each row's check,
#     finding, wait and priority), roll-up and shares row counts, and its semaphores' forced grants and timeouts equal
#     mssql_grant_deltas over the window [content compared after review d03]; pgvigil.findings holds the view's rows.
#  E. #/mssql_waits over window 1 in a headless Chromium, light and dark: the tiles (signal wait ratio with its label,
#     SOS_SCHEDULER_YIELD), the findings, the roll-up and the semaphores grids as many rows as the API; every link of the
#     page clicked once (each distinct target), its landing named in a click table and none landing on an error or on
#     the Summary; the Findings tab shows the D03 rows. Shots of both themes.
# NOT PROVEN HERE: sp_Blitz 162 raising (one NUMA node), SQL Server 2016-2019, Azure SQL Managed Instance, RDS.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
STAGE=${PROOF_STAGE:-ALL}
PROCS=${PGVIGIL_PROC_DIR:-.lab/procs}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvdw-sql-$SUF; LBL=pgvigil-proof=s177c
PGDB=pgv_dw_$SUF; MON=pgv_dwmon_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); BG=(); SRVPID=; CHRPID=
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  for p in "${BG[@]}"; do kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# sq: T-SQL as sa (stdin; -I: QUOTED_IDENTIFIER on, as the procedures' output tables need); sqa: through the dedicated
# admin connection (answers while every worker is taken); sqok: output not wanted, a failure loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqa() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S admin:localhost -U sa -C -b -I -W -h -1 -s "|" -d master -i /dev/stdin'; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
# sess: a session of its own in the background, named by its host (-H)
sess() { printf '%s\n' "$2" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvdw -H "$0" -l 120 -i /dev/stdin' "$1" >"$TMPD/$1.out" 2>&1 & BG+=($!); }
# gone: wait (through the DAC) until no session of the host pattern is left
gone() { local n=x; for _ in $(seq 1 "${2:-90}"); do n=$(sqa "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name LIKE '$1'" 2>/dev/null || echo x); [[ "$n" == 0 ]] && return 0; sleep 1; done; fail "$3: sessions $1 did not end ($n left)"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
for t in docker go psql curl python3 node npm chromium git; do command -v "$t" >/dev/null || fail "needs $t"; done
for f in sp_PerfCheck.sql sp_Blitz.sql sp_BlitzFirst.sql; do [[ -s "$PROCS/$f" ]] || fail "needs $PROCS/$f (the procedure's own source)"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== A. the container =="
docker run -d --name "$SQL" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
up() { local r=; for _ in $(seq 1 90); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done; fail "A: the SQL Server container did not come up in 180 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
for f in sp_PerfCheck.sql sp_Blitz.sql sp_BlitzFirst.sql; do
  docker cp "$PROCS/$f" "$SQL:/tmp/$f" >/dev/null
  docker exec --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -d master -i "/tmp/$0"' "$f" >"$TMPD/install-$f.out" 2>&1 || { tail -5 "$TMPD/install-$f.out"; fail "A: installing $f"; }
  echo "A: $f installed (sha256 $(sha256sum "$PROCS/$f" | cut -c1-12))"
done
sqok "A: the server options" "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'remote admin connections', 1; EXEC sp_configure 'max worker threads', 128; EXEC sp_configure 'max server memory (MB)', 2048; RECONFIGURE;"
# tempdb to two data files: the others emptied and removed (they hold nothing on a server that just started)
for f in $(sq "SELECT name FROM tempdb.sys.database_files WHERE type_desc = 'ROWS' AND file_id > 3 ORDER BY file_id"); do
  sqok "A: tempdb file $f" "DBCC SHRINKFILE (N'$f', EMPTYFILE) WITH NO_INFOMSGS; ALTER DATABASE tempdb REMOVE FILE [$f];" tempdb
done
sqok "A: the database" "CREATE DATABASE pgvdw; ALTER DATABASE pgvdw SET RECOVERY SIMPLE; CREATE DATABASE pgvdw_out;"
sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL CONSTRAINT pk_t PRIMARY KEY, pad char(400) NOT NULL DEFAULT 'a', k int NOT NULL DEFAULT 0);
  INSERT dbo.t (id, k) SELECT TOP (300000) n, CHECKSUM(NEWID()) FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b) x;" pgvdw
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
docker restart "$SQL" >/dev/null; up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
read -r CPUS WORKERS TFILES NODES <<<"$(sq "SELECT (SELECT cpu_count FROM sys.dm_os_sys_info), (SELECT max_workers_count FROM sys.dm_os_sys_info), (SELECT COUNT(*) FROM tempdb.sys.database_files WHERE type_desc = 'ROWS'), (SELECT COUNT(*) FROM sys.dm_os_nodes WHERE node_id > 0 AND node_state_desc NOT LIKE '%DAC')" | tr '|' ' ')"
[[ "$WORKERS" == 128 && "$TFILES" == 2 ]] || fail "A: after the restart max workers $WORKERS (want 128), tempdb data files $TFILES (want 2)"
sqa "SELECT 1" >/dev/null || fail "A: the dedicated admin connection does not answer"
echo "ok   A: $CPUS CPUs, 128 workers, tempdb 2 data files, $NODES NUMA node(s) besides node 0 and the DAC's; the DAC answers"

echo "== B. window 1 =="
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_DW_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$TMPD/w.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_DW_MON
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/w.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
col() { for c in "$@"; do "$TMPD/pgvigil" collect -config "$TMPD/w.yaml" -instance sqlbox -once "$c" >"$TMPD/col-$c.out" 2>&1 || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
sqok "B: clear the wait counters" "DBCC SQLPERF ('sys.dm_os_wait_stats', CLEAR) WITH NO_INFOMSGS;"
col mssql_waits mssql_memory mssql_tempdb
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
R0=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_wait_state WHERE instance_id = $SB")
[[ -n "$R0" ]] || fail "B: read #0 stored no wait state"
BFSECS=230
printf "EXEC dbo.sp_BlitzFirst @Seconds = %s, @OutputDatabaseName = N'pgvdw_out', @OutputSchemaName = N'dbo', @OutputTableName = N'bf_findings', @CheckProcedureCache = 0, @ExpertMode = 0;\n" "$BFSECS" \
  | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d master -H pgvdw_bf -i /dev/stdin' >"$TMPD/bf.out" 2>&1 & BFPID=$!; BG+=($BFPID)
bfwait() { sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = 'pgvdw_bf' AND r.wait_type = 'WAITFOR'"; }
for _ in $(seq 1 60); do [[ "$(bfwait)" == 1 ]] && break; sleep 1; done
[[ "$(bfwait)" == 1 ]] || { cat "$TMPD/bf.out"; fail "B: sp_BlitzFirst never reached its sample's WAITFOR"; }
T_BF0=$(date +%s); echo "B: sp_BlitzFirst sampling ${BFSECS} s"
# THREADPOOL: the head lets go by itself after 25 s; the scans hold their workers until then
sess pgvdw_head "BEGIN TRAN; UPDATE dbo.t SET k = k + 1 WHERE id = 1; WAITFOR DELAY '00:00:25'; COMMIT;"
sleep 2
# the scans hold a worker per thread; 100 serial reads of the locked row hold one each (run 1: the scans alone, after
# the restart, left no task waiting for a worker)
for i in $(seq 1 40); do sess "pgvdw_tp$i" "SELECT COUNT(*) FROM dbo.t WHERE pad <> 'z' OPTION (MAXDOP 8, USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE'));"; done
for i in $(seq 1 100); do sess "pgvdw_tps$i" "SELECT k FROM dbo.t WHERE id = 1;"; done
sleep 12
TPNOW=$(sqa "SELECT COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type = 'THREADPOOL'" || echo "?")
sqa "SELECT 'B: waiting', wait_type, COUNT(*) FROM sys.dm_os_waiting_tasks WHERE wait_type IN ('THREADPOOL','LCK_M_S','LCK_M_IS','CXCONSUMER','CXSYNC_PORT','CXPACKET') GROUP BY wait_type; SELECT 'B: workers', SUM(current_workers_count), SUM(active_workers_count), SUM(work_queue_count) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE';" || true
[[ "$TPNOW" =~ ^[1-9] ]] || fail "B: no task waits THREADPOOL in the middle of the phase ($TPNOW): the provocation did not exhaust the workers"
gone 'pgvdw_tp%' 120 "B THREADPOOL"; gone pgvdw_head 30 "B THREADPOOL"
echo "B: THREADPOOL phase over at $(( $(date +%s) - T_BF0 )) s ($TPNOW task(s) waited THREADPOOL at its middle)"
SORTQ="SELECT TOP (1) a.id FROM dbo.t a ORDER BY a.pad DESC, a.k DESC OPTION (MIN_GRANT_PERCENT = 100, MAXDOP 1);"
LOOP="DECLARE @e datetime2 = DATEADD(SECOND, 25, SYSDATETIME()); WHILE SYSDATETIME() < @e BEGIN $SORTQ END"
for i in $(seq 1 16); do sess "pgvdw_rs$i" "$LOOP"; done
sleep 8; RSNOW=$(sq "SELECT SUM(waiter_count) FROM sys.dm_exec_query_resource_semaphores")
gone 'pgvdw_rs%' 90 "B RESOURCE_SEMAPHORE"
echo "B: RESOURCE_SEMAPHORE phase over at $(( $(date +%s) - T_BF0 )) s ($RSNOW waiter(s) at its middle)"
# forced grants: 'query wait (s)' at 1 behind held grants; the phase runs again (three times at most, while the sample
# has room) until the server counts a forced grant (runs 1-2 made 1 and 7, run 3 none)
sqok "B: query wait 1 s" "EXEC sp_configure 'query wait (s)', 1; RECONFIGURE;"
FLOOP="DECLARE @e datetime2 = DATEADD(SECOND, 20, SYSDATETIME()); WHILE SYSDATETIME() < @e BEGIN SELECT TOP (1) a.id FROM dbo.t a ORDER BY a.pad, a.k OPTION (MAXDOP 1); END"
FG=0
for fround in 1 2 3; do
  for i in $(seq 1 4); do sess "pgvdw_fh$i" "$LOOP"; done
  for i in $(seq 1 24); do sess "pgvdw_fg$i" "$FLOOP"; done
  gone 'pgvdw_f%' 90 "B forced grants"
  FG=$(sq "SELECT ISNULL(SUM(forced_grant_count), 0) FROM sys.dm_exec_query_resource_semaphores")
  echo "B: forced-grant round $fround: $FG forced grant(s) since the start"
  [ "$FG" -gt 0 ] && break
  (( $(date +%s) - T_BF0 < 100 )) || break
done
sqok "B: query wait back to -1" "EXEC sp_configure 'query wait (s)', -1; RECONFIGURE;"
[ "$FG" -gt 0 ] || fail "B: no forced grant in three rounds: the provocation did not take (sp_PerfCheck 4101 needs one)"
echo "B: forced-grant phase over at $(( $(date +%s) - T_BF0 )) s"
# range locks: a key held 14 s; eight SERIALIZABLE range scans over it wait LCK_M_RS_S
sess pgvdw_rh "BEGIN TRAN; UPDATE dbo.t SET k = k + 1 WHERE id = 500; WAITFOR DELAY '00:00:14'; COMMIT;"
sleep 1
for i in $(seq 1 8); do sess "pgvdw_rl$i" "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE; SELECT COUNT(*) FROM dbo.t WITH (INDEX(pk_t)) WHERE id BETWEEN 400 AND 600;"; done
gone 'pgvdw_r[hl]%' 60 "B range locks"
echo "B: range-lock phase over at $(( $(date +%s) - T_BF0 )) s"
TT="DECLARE @e datetime2 = DATEADD(SECOND, 20, SYSDATETIME()); WHILE SYSDATETIME() < @e BEGIN CREATE TABLE #x (a int, b char(100)); INSERT #x VALUES (1, 'x'); DROP TABLE #x; END"
for i in $(seq 1 32); do sess "pgvdw_tt$i" "$TT"; done
gone 'pgvdw_tt%' 60 "B tempdb"
T_END=$(( $(date +%s) - T_BF0 ))
echo "B: tempdb phase over at $T_END s"
(( T_END < BFSECS - 5 )) || fail "B: the provocations ran past sp_BlitzFirst's sample ($T_END s of $BFSECS)"
wait "$BFPID" || true
[[ "$(sq "SELECT COUNT(*) FROM dbo.bf_findings" pgvdw_out 2>/dev/null)" =~ ^[1-9] ]] || { tail -20 "$TMPD/bf.out"; fail "B: sp_BlitzFirst wrote no findings"; }
HAND1=$(sq "SELECT CAST(pool_id AS varchar) + '|' + CAST(resource_semaphore_id AS varchar) + '|' + ISNULL(CAST(target_memory_kb AS varchar), '') + '|' + ISNULL(CAST(max_target_memory_kb AS varchar), '') + '|' + ISNULL(CAST(total_memory_kb AS varchar), '') + '|' + ISNULL(CAST(available_memory_kb AS varchar), '') + '|' + ISNULL(CAST(granted_memory_kb AS varchar), '') + '|' + ISNULL(CAST(used_memory_kb AS varchar), '') + '|' + CAST(grantee_count AS varchar) + '|' + CAST(waiter_count AS varchar) + '|' + ISNULL(CAST(timeout_error_count AS varchar), '') + '|' + ISNULL(CAST(forced_grant_count AS varchar), '') FROM sys.dm_exec_query_resource_semaphores ORDER BY pool_id, resource_semaphore_id")
col mssql_waits mssql_memory mssql_tempdb
HAND2=$(sq "SELECT CAST(pool_id AS varchar) + '|' + CAST(resource_semaphore_id AS varchar) + '|' + ISNULL(CAST(target_memory_kb AS varchar), '') + '|' + ISNULL(CAST(max_target_memory_kb AS varchar), '') + '|' + ISNULL(CAST(total_memory_kb AS varchar), '') + '|' + ISNULL(CAST(available_memory_kb AS varchar), '') + '|' + ISNULL(CAST(granted_memory_kb AS varchar), '') + '|' + ISNULL(CAST(used_memory_kb AS varchar), '') + '|' + CAST(grantee_count AS varchar) + '|' + CAST(waiter_count AS varchar) + '|' + ISNULL(CAST(timeout_error_count AS varchar), '') + '|' + ISNULL(CAST(forced_grant_count AS varchar), '') FROM sys.dm_exec_query_resource_semaphores ORDER BY pool_id, resource_semaphore_id")
PL_MS=$(sq "SELECT SUM(wait_time_ms) FROM sys.dm_os_wait_stats WHERE wait_type IN ('PAGELATCH_UP', 'PAGELATCH_SH', 'PAGELATCH_EX')")
# sp_PerfCheck right away, the time since the start read in the same batch
sq "SELECT 'uptime_ms|' + CAST(DATEDIFF(MILLISECOND, sqlserver_start_time, SYSDATETIME()) AS varchar(20)) FROM sys.dm_os_sys_info; EXEC dbo.sp_PerfCheck;" > "$TMPD/pc1.out" 2>&1 || { tail -20 "$TMPD/pc1.out"; fail "B: sp_PerfCheck"; }
sq "EXEC dbo.sp_Blitz @CheckUserDatabaseObjects = 0, @CheckServerInfo = 0;" > "$TMPD/blitz.out" 2>&1 || { grep -m3 '^Msg' "$TMPD/blitz.out" >&2 || true; echo "B: sp_Blitz ended with an error (its rows are read anyway)"; }
R1=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_wait_state WHERE instance_id = $SB")
U_MS=$(sed -n 's/^uptime_ms|//p' "$TMPD/pc1.out" | head -1)
W_S=$(pq "SELECT covered_secs FROM pgvigil.mssql_wait_covered($SB, '$R0', '$R1')")
echo "B: window 1 = (read #0 $R0, read #1 $R1]: $W_S s read; sp_PerfCheck's time since the start $U_MS ms"
# the window ends after the later of read #1's waits and memory reads (run 4: the memory read landed more than a second
# after the waits read, outside a window cut at the waits read, and its forced grants with it)
R1M=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_memory_pool WHERE instance_id = $SB")
R1E=$(pq "SELECT greatest('$R1'::timestamptz, '$R1M'::timestamptz)")
F1=$(date -u -d "$R0" +%Y-%m-%dT%H:%M:%S.%3NZ); T1=$(date -u -d "$R1E + 1 second" +%Y-%m-%dT%H:%M:%SZ)
pq "SELECT source_check || '|' || check_name || '|' || coalesce(object, '') || '|' || source_priority || '|' || coalesce(value::text, '') || '|' || replace(detail, E'\\n', ' ') FROM pgvigil.mssql_wait_findings_between($SB, '$F1', '$T1') ORDER BY 1" > "$TMPD/pgv1.txt"
echo "pgvigil's findings over window 1:"; cut -d'|' -f1-5 "$TMPD/pgv1.txt" | sed 's/^/     /'
sq "SELECT CAST(CheckID AS varchar) + '|' + Finding + '|' + CAST(Priority AS varchar) + '|' + CAST(DetailsInt AS varchar) FROM dbo.bf_findings WHERE CheckID = 30 ORDER BY Finding" pgvdw_out > "$TMPD/bf30.txt" || true
grep -E '^(4101|6001|6101|6102|2010)\|' "$TMPD/pc1.out" > "$TMPD/pc1rows.txt" || true
echo "sp_BlitzFirst CheckID 30:"; sed 's/^/     /' "$TMPD/bf30.txt"; echo "sp_PerfCheck:"; cut -c1-200 "$TMPD/pc1rows.txt" | sed 's/^/     /'
python3 - "$TMPD/pgv1.txt" "$TMPD/bf30.txt" "$TMPD/pc1rows.txt" "$TMPD/blitz.out" "$U_MS" "$W_S" "$PL_MS" "$TMPD/b.verdict" <<'EOF' || fail "B: the findings differ from the procedures' (above)"
import re, sys
pgv_f, bf_f, pc_f, bl_f, u_ms, w_s, pl_ms, out = sys.argv[1:9]
U, W = float(u_ms) / 1000.0, float(w_s)
scale = U / W
bad, ok, np_ = [], [], []
P = {}
for l in open(pgv_f):
    if not l.strip():
        continue
    c, name, obj, pri, val, det = l.rstrip('\n').split('|', 5)
    P.setdefault(c, []).append(dict(name=name, obj=obj, pri=int(pri), val=float(val) if val else None, det=det))
CAT = {'Storage-Related Waits': 'I/O', 'Memory-Related Waits': 'Memory', 'Parallelism Waits': 'Parallelism', 'CPU / Scheduling Waits': 'CPU',
       'TempDB Contention Waits': 'TempDB Contention', 'Lock / Blocking Waits': 'Locking', 'Transaction Log Waits': 'Transaction Log'}
RES = ('Locking', 'Memory', 'I/O', 'TempDB Contention', 'Transaction Log', 'CPU')
def rule6001(cat, pct, avg, ms):  # sp_PerfCheck 2.11's priority CASE of check 6001
    if cat in RES:
        if pct >= 50 or (avg >= 1000 and ms >= 60000): return 20
        if pct >= 20 or (avg >= 250 and ms >= 60000): return 30
        return 40
    if cat == 'Parallelism':
        return 30 if pct >= 100 else 40
    return 40
def band(p): return 20 if p >= 50 else 30 if p >= 30 else 40
# B1: sp_BlitzFirst CheckID 30 against pgvigil's check-30 rows (exact seconds)
bf = {}
for l in open(bf_f):
    p = l.strip().split('|')
    if len(p) == 4 and p[0] == '30':
        bf[p[1]] = int(p[3])
pg30 = {r['name']: int(r['val']) for r in P.get('30', [])}
if bf != pg30:
    bad.append(f"B1 sp_BlitzFirst 30 {bf} != pgvigil {pg30}")
elif 'Poison Wait Detected: THREADPOOL' not in bf or 'Poison Wait Detected: RESOURCE_SEMAPHORE' not in bf:
    bad.append(f"B1 THREADPOOL and RESOURCE_SEMAPHORE are not both poison rows: {bf}")
else:
    ok.append("B1 sp_BlitzFirst CheckID 30 = pgvigil: " + ", ".join(f"{k[22:]} {v} s" for k, v in sorted(bf.items())))
# B2: sp_PerfCheck, its rule applied to its own numbers rescaled to the window
src = {}
for l in open(pc_f):
    p = l.rstrip('\n').split('|')
    if len(p) >= 8:
        src.setdefault(p[0], []).append(dict(pri=int(p[1]), finding=p[4], obj='' if p[6] == 'N/A' else p[6], det=p[7]))
mine6001 = {r['obj']: r for r in P.get('6001', [])}
src6001 = {r['obj']: r for r in src.get('6001', [])}
for obj in sorted(set(mine6001) | set(src6001)):
    s, m = src6001.get(obj), mine6001.get(obj)
    if s:
        sp = float(re.search(r'accounts for ([0-9.]+)% of server uptime', s['det']).group(1))
        avg = float(re.search(r'averaging ([0-9.]+) ms', s['det']).group(1))
        ms = sp / 100 * U * 1000
        exp = sp * scale
        cat = CAT.get(s['finding'], 'Other')
        want = rule6001(cat, round(exp, 2), avg, ms)
        if not m:
            bad.append(f"B2 6001 {obj}: only sp_PerfCheck ({sp} % of U = {exp:.2f} % of W, which pgvigil must list)")
        elif m['name'] != s['finding'] or abs(m['val'] - exp) > 0.02 * exp + 0.01 or m['pri'] != want:
            bad.append(f"B2 6001 {obj}: pgvigil {m['name']} {m['val']} priority {m['pri']}; sp_PerfCheck {s['finding']} {sp} x U/W = {exp:.2f}, its rule there gives {want}")
        else:
            ok.append(f"B2 6001 {obj}: pgvigil {m['val']} = sp_PerfCheck {sp} x U/W {exp:.2f}; priority {m['pri']} = the rule on the window ({want}; the source's own {s['pri']})")
    else:
        avg = float(re.search(r'averaging ([0-9.]+) ms', m['det']).group(1))
        ms = m['val'] / 100 * W * 1000
        su = m['val'] / scale
        if su <= 10 and not (avg > 1000 and ms >= 60000):
            ok.append(f"B2 6001 {obj}: pgvigil only ({m['val']} % of W = {su:.2f} % of U, under the source's 10 %: the denominator)")
        else:
            bad.append(f"B2 6001 {obj}: pgvigil only ({m['val']} % of W = {su:.2f} % of U, avg {avg} ms) - the source would list it")
for need in ('THREADPOOL (Potential worker thread exhaustion)', 'RESOURCE_SEMAPHORE (Queries waiting to get memory to run)', 'LCK_M_RS_S (Queries waiting to acquire locks)'):
    if need not in src6001 or need not in mine6001:
        bad.append(f"B2 6001 {need}: provoked, but not on both sides")
def one(cid):
    s = src.get(cid, []); m = P.get(cid, [])
    return (s[0] if s else None), (m[0] if m else None)
s, m = one('6102')
if s or m:
    if not (s and m):
        sp = float(re.search(r'account for ([0-9.]+)% of server uptime', s['det']).group(1)) if s else None
        bad.append(f"B2 6102 on one side only (sp_PerfCheck {sp}, pgvigil {m['val'] if m else None})")
    else:
        sp = float(re.search(r'account for ([0-9.]+)% of server uptime', s['det']).group(1)); exp = sp * scale
        if abs(m['val'] - exp) > 0.02 * exp + 0.01 or m['pri'] != band(round(exp, 2)):
            bad.append(f"B2 6102: pgvigil {m['val']} priority {m['pri']}; sp_PerfCheck {sp} x U/W = {exp:.2f} (priority there {band(round(exp, 2))})")
        else:
            ok.append(f"B2 6102: pgvigil {m['val']} = sp_PerfCheck {sp} x U/W {exp:.2f}; priority {m['pri']}")
else:
    np_.append("6102 raised on neither side in window 1 (graded in window 2)")
s, m = one('6101')
if s or m:
    if not (s and m) or abs(m['val'] - float(re.search(r'ratio is ([0-9.]+)%', s['det']).group(1))) > 0.5 or m['pri'] != s['pri']:
        bad.append(f"B2 6101: sp_PerfCheck {s and s['det'][:60]}, pgvigil {m and (m['val'], m['pri'])}")
    else:
        ok.append(f"B2 6101: pgvigil {m['val']} priority {m['pri']} = sp_PerfCheck")
else:
    np_.append("6101 raised on neither side in window 1 (THREADPOOL's time outweighs the signal waits; graded in window 2)")
s, m = one('4101')
if not (s and m):
    bad.append(f"B2 4101: provoked, on one side only ({bool(s)}, {bool(m)})")
else:
    sc = int(re.search(r'reports ([0-9]+) forced', s['det']).group(1))
    if int(m['val']) != sc or m['pri'] != s['pri']:
        bad.append(f"B2 4101: pgvigil {m['val']} priority {m['pri']}, sp_PerfCheck {sc} priority {s['pri']}")
    else:
        ok.append(f"B2 4101: {sc} forced grants, priority {m['pri']} on both")
s, m = one('2010')
if not (s and m):
    bad.append(f"B2 2010: provoked, on one side only ({bool(s)}, {bool(m)})")
else:
    sh, sf, su_ = re.search(r'spent ([0-9.]+) hours .* has ([0-9]+) data files\. Consider adding files up to ([0-9]+)', s['det']).groups()
    mh, mf, mu = re.search(r'spent ([0-9.]+) hours .* has ([0-9]+) data files\. Consider adding files up to ([0-9]+)', m['det']).groups()
    exp = float(pl_ms) * 100 / (W * 1000)
    if abs(float(sh) - float(mh)) > 0.011 or (sf, su_) != (mf, mu) or m['pri'] != s['pri'] or abs(m['val'] - exp) > 0.02 * exp:
        bad.append(f"B2 2010: pgvigil {mh} h, {mf} files, up to {mu}, {m['val']} %, priority {m['pri']}; sp_PerfCheck {sh} h, {sf}, {su_}, priority {s['pri']}; the hand read's page latch {pl_ms} ms / W = {exp:.2f} %")
    else:
        ok.append(f"B2 2010: {mh} h (sp_PerfCheck {sh} h), {mf} data files, up to {mu}, priority {m['pri']}; pgvigil's share {m['val']} = the hand read's page latch / W {exp:.2f}")
# B3: sp_Blitz 107, 117, 121, 162
bl = open(bl_f, errors='replace').read().splitlines()
def dhms(t):
    d, h, mi, se = map(int, re.match(r'(\d+):(\d+):(\d+):(\d+)', t).groups())
    return d * 86400 + h * 3600 + mi * 60 + se
for l in bl:
    mm = re.search(r'Poison Wait Detected: ([A-Z_]+)\|.*\|(\d+:\d+:\d+:\d+) of this wait', l)
    if mm:
        w, secs = mm.group(1), dhms(mm.group(2))
        got = pg30.get('Poison Wait Detected: ' + w)
        if got is None or abs(got - secs) > 2:
            bad.append(f"B3 sp_Blitz 107 {w} {secs} s, pgvigil {got}")
        else:
            ok.append(f"B3 sp_Blitz 107 {w}: {secs} s, pgvigil {got} s")
m117 = [int(x.group(1)) for x in (re.search(r'\|(\d+) forced grants reported', l) for l in bl) if x]
m121 = [dhms(x.group(1)) for x in (re.search(r'Serializable Locking\|.*\|(\d+:\d+:\d+:\d+) of LCK_M_R', l) for l in bl) if x]
p121 = [r['val'] for r in P.get('121', [])]
if m121 and p121 and abs(p121[0] / 1000 - m121[0]) <= 2:
    ok.append(f"B3 sp_Blitz 121 range locks: {m121[0]} s, pgvigil {p121[0] / 1000:.0f} s")
else:
    bad.append(f"B3 sp_Blitz 121: sp_Blitz {m121}, pgvigil {p121} ms")
if any('CMEMTHREAD and NUMA' in l for l in bl) or P.get('162'):
    bad.append("B3 162 raised on a one-node container")
else:
    np_.append("sp_Blitz 162 raised on neither side (one NUMA node): its raising is not proven")
open(out, 'w').write('117 ' + (str(m117[0]) if m117 else '-') + '\n')
print('\n'.join(['ok   ' + x for x in ok] + ['NOT PROVEN: ' + x for x in np_] + ['BAD  ' + x for x in bad]))
sys.exit(1 if bad else 0)
EOF
S117=$(sed -n 's/^117 //p' "$TMPD/b.verdict")
SUMF=$(pq "SELECT coalesce(sum(forced_grants), 0) FROM pgvigil.mssql_grant_deltas($SB, '$F1', '$T1')")
[[ "$S117" == "$SUMF" && "$SUMF" -gt 0 ]] || fail "B3: sp_Blitz 117's forced grants $S117, pgvigil's differences $SUMF (want equal and more than 0)"
echo "ok   B3 sp_Blitz 117: $S117 forced grants = the sum of pgvigil's differences"
MINE=$(pq "SELECT pool_id || '|' || semaphore_id || '|' || coalesce(target_kb::text, '') || '|' || coalesce(max_target_kb::text, '') || '|' || coalesce(total_kb::text, '') || '|' || coalesce(available_kb::text, '') || '|' || coalesce(granted_kb::text, '') || '|' || coalesce(used_kb::text, '') || '|' || grantees || '|' || waiters || '|' || coalesce(timeout_errors::text, '') || '|' || coalesce(forced_grants::text, '') FROM pgvigil.mssql_memory_pools_at($SB, NULL) ORDER BY pool_id, semaphore_id")
# each reader's own small query takes its grant from the small-query semaphore (id 1) of its pool while it reads (run
# 2: the collector 1168 KB granted, the hand read 1024 KB): on those rows available / granted / used are compared as
# available + granted = total on both sides; every other column, and every column of the regular semaphores, exactly
sem() { python3 -c '
import sys
for l in sys.stdin.read().split("\n"):
    p = l.split("|")
    if len(p) == 12 and p[1] == "1":
        ok = p[5] and p[6] and p[4] and int(p[5]) + int(p[6]) == int(p[4])
        p[5], p[6], p[7] = "", "", ""
        p.append("sum-ok" if ok else "sum-BAD")
    if l: print("|".join(p))'; }
[[ "$(sem <<<"$MINE")" == "$(sem <<<"$HAND1")" || "$(sem <<<"$MINE")" == "$(sem <<<"$HAND2")" ]] && ! grep -q 'sum-BAD' <<<"$(sem <<<"$MINE")" \
  || { printf 'pgvigil:\n%s\nbefore:\n%s\nafter:\n%s\n' "$MINE" "$HAND1" "$HAND2"; fail "B4: the stored semaphores equal neither hand read"; }
DMVF=$(sq "SELECT SUM(forced_grant_count) FROM sys.dm_exec_query_resource_semaphores")
[[ "$DMVF" == "$SUMF" ]] || fail "B4: forced grants since the start $DMVF, pgvigil's window $SUMF"
echo "ok   B4: the stored semaphores ($(wc -l <<<"$MINE") rows) equal a hand read around read #1; forced grants $SUMF = the DMV's count since the start"

echo "== C. window 2: CPU pressure =="
sqok "C: clear the wait counters" "DBCC SQLPERF ('sys.dm_os_wait_stats', CLEAR) WITH NO_INFOMSGS;"
col mssql_waits
R2=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_wait_state WHERE instance_id = $SB")
BUSY="DECLARE @e datetime2 = DATEADD(SECOND, 30, SYSDATETIME()), @i bigint = 0; WHILE SYSDATETIME() < @e SET @i += 1;"
for i in $(seq 1 32); do sess "pgvdw_cpu$i" "$BUSY"; done
gone 'pgvdw_cpu%' 90 "C"
col mssql_waits
sq "SELECT 'uptime_ms|' + CAST(DATEDIFF(MILLISECOND, sqlserver_start_time, SYSDATETIME()) AS varchar(20)) FROM sys.dm_os_sys_info; EXEC dbo.sp_PerfCheck;" > "$TMPD/pc2.out" 2>&1 || { tail -20 "$TMPD/pc2.out"; fail "C: sp_PerfCheck"; }
R3=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_wait_state WHERE instance_id = $SB")
F2=$(date -u -d "$R2" +%Y-%m-%dT%H:%M:%S.%3NZ); T2=$(date -u -d "$R3 + 1 second" +%Y-%m-%dT%H:%M:%SZ)
SRC_R=$(sed -n 's/^Signal Wait Ratio|\([0-9.]*\)% (\(.*\))$/\1|\2/p' "$TMPD/pc2.out" | head -1)
SRC_6101=$(grep -E '^6101\|' "$TMPD/pc2.out" | cut -d'|' -f2 || true)
MY_R=$(pq "SELECT signal_ratio || '|' || split_part(signal_label, ' - ', 1) FROM pgvigil.mssql_wait_shares_between($SB, '$F2', '$T2')")
MY_6101=$(pq "SELECT source_priority FROM pgvigil.mssql_wait_findings_between($SB, '$F2', '$T2') WHERE source_check = 6101")
python3 -c 'import sys; a, b = sys.argv[1].split("|"), sys.argv[2].split("|"); sys.exit(0 if abs(float(a[0]) - float(b[0])) <= 1.0 and a[1].split(" - ")[0] == b[1] else 1)' "$SRC_R" "$MY_R" \
  || fail "C: sp_PerfCheck's signal wait ratio '$SRC_R', pgvigil's '$MY_R'"
[[ -n "$SRC_6101" && "$SRC_6101" == "$MY_6101" ]] || fail "C: 6101 priority sp_PerfCheck '$SRC_6101', pgvigil '$MY_6101' (want both, equal)"
U2=$(sed -n 's/^uptime_ms|//p' "$TMPD/pc2.out" | head -1); W2=$(pq "SELECT covered_secs FROM pgvigil.mssql_wait_covered($SB, '$F2', '$T2')")
SRC_6102=$(grep -E '^6102\|' "$TMPD/pc2.out" | head -1 | awk -F'|' '{print $2"|"$8}' | sed -E 's/\|SOS_SCHEDULER_YIELD waits account for ([0-9.]+)%.*/|\1/')
MY_6102=$(pq "SELECT source_priority || '|' || value FROM pgvigil.mssql_wait_findings_between($SB, '$F2', '$T2') WHERE source_check = 6102")
python3 -c '
import sys
s, m, u, w = sys.argv[1], sys.argv[2], float(sys.argv[3]) / 1000, float(sys.argv[4])
sp, sv = s.split("|"); mp, mv = m.split("|"); exp = float(sv) * u / w
band = 20 if exp >= 50 else 30 if exp >= 30 else 40
sys.exit(0 if abs(float(mv) - exp) <= 0.02 * exp + 0.01 and int(mp) == band else 1)' "$SRC_6102" "$MY_6102" "$U2" "$W2" \
  || fail "C: 6102 sp_PerfCheck '$SRC_6102' (priority|% of U, U $U2 ms), pgvigil '$MY_6102' (priority|% of W, W $W2 s)"
echo "ok   C: signal wait ratio sp_PerfCheck $SRC_R, pgvigil $MY_R; 6101 priority $MY_6101 on both; 6102 sp_PerfCheck $SRC_6102 x U/W = pgvigil $MY_6102"
[[ "$STAGE" == BC ]] && { echo "proof-darling-waits: stages A-C OK"; exit 0; }

echo "== D. the API under pgvigil serve (the wiring applied to a copy) =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
P=scripts/proof-darling-waits-wiring.patch
if [ ! -f "$GSRC/$P" ]; then
  grep -q 'MSSQLWaitFindings' "$GSRC/internal/web/web.go" || fail "D: no $P and web.go has no /api/mssql/waitfindings route"
  echo "D: no $P in the tree: the release join carries the route and the arm (the tree is used as it is)"
elif (cd "$GSRC" && git apply --check -R "$P" 2>/dev/null); then echo "D: $P is already in this tree"
elif (cd "$GSRC" && git apply "$P" 2>"$TMPD/apply.err"); then echo "D: $P applied to the run's copy"
else fail "D: $P neither applies nor is applied: $(cat "$TMPD/apply.err")"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "D: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil-g" ./cmd/pgvigil) || fail "D: the build"
"$TMPD/pgvigil-g" migrate -config "$TMPD/w.yaml" >"$TMPD/migrate2.out" 2>&1 || { cat "$TMPD/migrate2.out" >&2; fail "D: migrate (the proof's join file)"; }
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil-g" user add -config "$TMPD/w.yaml" "$USR" >/dev/null 2>&1 || fail "D: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
"$TMPD/pgvigil-g" serve -config "$TMPD/w.yaml" -listen "127.0.0.1:$PORT" >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "D: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "D: the UI login"
curl -s -b "$TMPD/cj" "$U/api/mssql/waitfindings?instance=$SB&from=$F1&to=$T1" > "$TMPD/api.json"
NF=$(pq "SELECT count(*) FROM pgvigil.mssql_wait_findings_between($SB, '$F1', '$T1')"); NR=$(pq "SELECT count(*) FROM pgvigil.mssql_wait_rollup_between($SB, '$F1', '$T1')")
NP=$(pq "SELECT count(*) FROM pgvigil.mssql_memory_pools_at($SB, '$T1') WHERE snapshot_at > '$F1'")
read -r af ar ap ash <<<"$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); n=lambda k: len((d.get(k) or {}).get("rows") or []); print(n("findings"), n("rollup"), n("pools"), n("shares"))' "$TMPD/api.json")"
[[ "$af" == "$NF" && "$ar" == "$NR" && "$ap" == "$NP" && "$ash" == 1 ]] || fail "D: the API: $af findings, $ar roll-up rows, $ap semaphores, $ash shares row (want $NF, $NR, $NP, 1): $(head -c 300 "$TMPD/api.json")"
python3 - "$TMPD/api.json" "$TMPD/pgv1.txt" > "$TMPD/api-findings.cmp" <<'PY' || fail "D: the API's findings differ from the function's: $(cat "$TMPD/api-findings.cmp")"
import json, sys
d = json.load(open(sys.argv[1])); t = d['findings']; i = {c: n for n, c in enumerate(t['columns'])}
api = sorted(f"{r[i['source_check']]}|{r[i['check_name']]}|{r[i['object']] or ''}|{r[i['source_priority']]}" for r in t['rows'])
fn = sorted('|'.join(l.split('|')[:4]) for l in open(sys.argv[2]) if l.strip())
print(api if api != fn else 'equal'); sys.exit(0 if api == fn else 1)
PY
API_P=$(python3 - "$TMPD/api.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["pools"]; i = {c: n for n, c in enumerate(d["columns"])}
v = lambda x: "" if x is None else str(x)
print("\n".join(sorted(f"{r[i['pool_id']]}|{r[i['semaphore_id']]}|{v(r[i['forced_grants']])}|{v(r[i['timeout_errors']])}" for r in d["rows"])))
PY
)
FN_P=$(pq "SELECT p.pool_id || '|' || p.semaphore_id || '|' || coalesce(d.forced_grants::text, '') || '|' || coalesce(d.timeout_errors::text, '') FROM pgvigil.mssql_memory_pools_at($SB, '$T1') p LEFT JOIN pgvigil.mssql_grant_deltas($SB, '$F1', '$T1') d USING (pool_id, semaphore_id) WHERE p.snapshot_at > '$F1' ORDER BY 1" | sort)
[[ "$API_P" == "$FN_P" ]] || fail "D: the API's semaphores (pool|semaphore|forced|timeouts) differ from mssql_grant_deltas: API [$API_P] functions [$FN_P]"
NV=$(pq "SELECT count(*) FROM pgvigil.findings WHERE instance_id = $SB AND source = 'mssql_waits'")
NV2=$(pq "SELECT count(*) FROM pgvigil.mssql_waits_findings WHERE instance_id = $SB")
[[ "$NV" == "$NV2" && "$NV" -gt 0 ]] || fail "D: pgvigil.findings holds $NV mssql_waits rows, the view $NV2 (want equal, more than 0)"
echo "ok   D: GET /api/mssql/waitfindings over window 1: $af findings, $ar categories, $ap semaphores, the shares (= the functions); pgvigil.findings holds the view's $NV rows"

echo "== E. the Waits page in headless Chromium =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1100 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "E: chromium's CDP port never answered"
cat > "$TMPD/e.mjs" <<'JS'
// prints one line per check; the shell grades them
const [port, U, sb, from, to, shots] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0; })()`); if (ok) { await sleep(500); return true; } await sleep(200); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
const state = () => ev(`(() => { const m = document.querySelector('main');
  const tiles = Object.fromEntries([...m.querySelectorAll('.tile')].map(t => [t.querySelector('.tile-l')?.textContent, t.querySelector('.tile-v')?.textContent]));
  const after = (title) => { const h = [...m.querySelectorAll('h3')].find(x => x.textContent === title); let g = h?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE' && g.tagName !== 'H3') g = g.nextElementSibling; return g && g.tagName !== 'H3' ? [...g.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')).length : (h ? 0 : -1); };
  return JSON.stringify({ hash: location.hash, title: document.querySelector('main h2')?.textContent ?? '', tiles, findings: after('Findings over this range'), rollup: after('Wait time by category'), pools: after('Memory grants by resource pool'),
    errors: m.querySelectorAll('.error:not([role=status])').length, links: [...m.querySelectorAll('a[href]')].map(a => ({ t: a.textContent.trim(), h: a.getAttribute('href') })) }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.E_USR)}, password: ${JSON.stringify(process.env.E_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
const page = `#/mssql_waits?i=${sb}&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
for (const theme of ['light', 'dark']) {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  if (!await go(page)) { console.log(`FAIL render ${theme}`); continue; }
  const s = await state(); console.log(`page ${theme} ${JSON.stringify({ tiles: s.tiles, findings: s.findings, rollup: s.rollup, pools: s.pools, errors: s.errors })}`);
  await shot(`waits-d03-${theme}`);
}
// every link of the page, each distinct target once: where it lands
await go(page);
const links = (await state()).links; const seen = new Set();
for (const l of links) {
  if (seen.has(l.h)) continue; seen.add(l.h);
  if (!l.h.startsWith('#')) { console.log(`click ${JSON.stringify(l.t)} ${l.h} -> external (not followed)`); continue; }
  const ok = await go(l.h); const r = await state();
  const lands = r.hash.split('?')[0], wants = l.h.split('?')[0];
  console.log(`click ${JSON.stringify(l.t)} ${l.h} -> ${r.hash} title=${JSON.stringify(r.title)} errors=${r.errors} rendered=${ok} same=${lands === wants}`);
  await go(page);
}
await go(`#/findings?i=${sb}`);
const fcount = await ev(`[...document.querySelectorAll('main tbody tr')].filter(tr => /mssql_waits|Poison Wait Detected|Waits$|Forced Grants/.test(tr.textContent)).length`);
console.log(`findings-tab ${fcount}`); await shot('findings-d03-dark');
ws.close(); process.exit(0);
JS
out=$(E_USR="$USR" E_UPW="$UPW" node "$TMPD/e.mjs" "$CDP" "$U/" "$SB" "$F1" "$T1" "$SHOTS") || fail "E: the Chromium walk stopped: $out"
echo "$out"
echo "$out" | grep -q '^login 200$' || fail "E: the UI login in Chromium"
! echo "$out" | grep -q '^FAIL' || fail "E: a page did not render"
SR=$(pq "SELECT signal_ratio FROM pgvigil.mssql_wait_shares_between($SB, '$F1', '$T1')")
for theme in light dark; do
  line=$(echo "$out" | grep "^page $theme ")
  echo "$line" | grep -q "\"findings\":$NF," && echo "$line" | grep -q "\"rollup\":$NR," && echo "$line" | grep -q "\"pools\":$NP," && echo "$line" | grep -q '"errors":0' \
    && echo "$line" | grep -q 'signal wait ratio (sp_PerfCheck' || fail "E: the page ($theme): $line (want $NF findings, $NR categories, $NP semaphores, the sp_PerfCheck signal tile)"
done
CL=$(echo "$out" | grep -c '^click ' || true)
(( CL > 0 )) || fail "E: the page has no link"
! echo "$out" | grep '^click ' | grep -v 'external' | grep -q 'errors=[1-9]\|rendered=false\|same=false' || fail "E: a link landed wrong: $(echo "$out" | grep '^click ' | grep 'errors=[1-9]\|rendered=false\|same=false' | head -3)"
FT=$(echo "$out" | sed -n 's/^findings-tab //p')
(( FT >= NV )) || fail "E: the Findings tab shows $FT D03 row(s), the view $NV"
echo "ok   E: the page in light and dark ($NF findings, $NR categories, $NP semaphores, the signal ratio $SR % tile); $CL distinct link(s) clicked, each landing on its own page; the Findings tab shows the D03 rows; shots in $SHOTS"
echo "proof-darling-waits: OK (sp_BlitzFirst's poison waits equal; sp_PerfCheck's rows equal over the window with its own rule applied to its numbers rescaled from the time since the start, the provoked ones required; sp_Blitz's equal; the semaphores and forced grants equal the DMV; the page, its API's content and its links; the NOT PROVEN lines above stand)"
