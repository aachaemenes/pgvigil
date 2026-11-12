#!/usr/bin/env bash
# Proof of the Memory page in sp_PressureDetector's and PerformanceMonitor's shape (task 177, darling-open D13): the
# grants per resource pool and per semaphore over a window and at the newest read, the timeouts and forced grants, the
# resource monitor's low-memory notifications, the caches, the plan cache by type with its bloat level, the queries
# with grants (and their cost), the workload groups and pools, and the memory findings (0119), against
# sp_PressureDetector's own logged output and PerformanceMonitor's own collector queries on the same server.
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest), go, psql, curl, python3, node, npm, chromium, and:
#   ADMIN_DSN         a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                     user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_PROC_DIR  the procedure's own source (default .lab/procs, git-ignored): sp_PressureDetector.sql (DarlingData,
#                     MIT); never fetched.
#   PGVIGIL_SHOTS     where the page shots go (default: a folder of the run, removed with it)
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# The two PerformanceMonitor 3.12.0 reads below (MemoryGrantsCollector.cs, PlanCacheStatsCollector.cs) are quoted
# verbatim from its source: MIT License, Copyright (c) Erik Darling, Darling Data LLC.
#
# Expected (written before the first run):
#  A. a SQL Server 2022 container (8 GB for the container, max server memory 4096 MB) with sp_PressureDetector
#     installed; a database pgvmem with a 300,000-row table and a memory-optimized table loaded with about 1.2 GB
#     (MEMORYCLERK_XTP over 1,000 MB and over 25 % of 4,096 MB); a resource pool pgvmem_pool (MAX_MEMORY_PERCENT 10)
#     and a workload group pgvmem_grp (REQUEST_MEMORY_GRANT_TIMEOUT_SEC 1, REQUEST_MAX_MEMORY_GRANT_PERCENT 50) that a
#     classifier gives every session whose host name starts pgvm_rg.
#  B. read #0 (mssql_instance, mssql_services, mssql_memory), then in pgvmem_grp: a holder that takes half the pool's
#     grant (MIN_GRANT_PERCENT 100 of the group's 50 %) and holds it (its rows are not read by the client), 12 askers with
#     MIN_GRANT_PERCENT 100 (most time out after 1 s: error 8645) and 12 without it (forced grants) for 20 s; 2,000 single-use ad hoc
#     statements; one default-pool query with MIN_GRANT_PERCENT 100 held (a grant over 15 % of Maximum Workspace
#     Memory); then a second holder takes the pool's other half and 6 askers run 20 s (nothing left even for their
#     minimum: they time out; each batch of sessions is seen connected before its end is awaited [after s177g-12: the
#     wait counted 0 before they connected]) [after s177g-5: with half the pool free an asker past its 1 s got a forced grant, 138, and
#     none timed out]. The hand read of sys.dm_exec_query_resource_semaphores: pgvmem_pool's timeout_error_count grew
#     (and forced_grant_count, said, not required). Then the group's timeout goes to 600 s and 6 more holders ask: all
#     wait behind the two (a steady state); read #1 by pgvigil, then PerformanceMonitor's plan cache and semaphore reads, sp_PressureDetector
#     @what_to_check = 'memory' logged to tables, the same run unlogged (its XML columns) and the hand reads, all
#     within seconds, the grants unchanged between them.
#  C. equal, read #1 against the sources:
#     C1 per semaphore with a max target: pgvigil's newest = sp_PressureDetector's _Memory rows (granted and used in GB
#        to 2 places, grantees, waiters, timeouts and forced grants since the start exact, max target within 2 %) and =
#        PerformanceMonitor's MemoryGrantsCollector rows (MB to 2 places, the same rule); target, total and available
#        move with the memory broker between reads (s177g-8 to -10: 20 to 100 MB, 2 to 9 %), so pgvigil's lie between two
#        hand reads of the DMV just before and just after its read #1 [after s177g-10]; every semaphore (the
#        small-query one included) in pgvigil's per-semaphore rows;
#     C2 sp_PressureDetector's max_memory_grant_cap (group, max grant percent) = pgvigil's workload groups, its
#        total_reduced_memory_grant_count per pool = the largest of the pool's groups;
#     C3 sp_PressureDetector's 'Non-Buffer Pool Memory: Top Five' = pgvigil's five largest clerk types but the buffer
#        pool (GB to 2 places, within 0.01 GB), its stolen memory = pgvigil's within 3 % (s177g-8: 1.73 / 1.77 GB);
#     C4 sp_PressureDetector's _MemoryQueries = pgvigil's grants now: the same sessions, requested, granted, ideal and
#        required memory (GB to 2 places), queue, wait order, next candidate, DOP; the 6 waiters with no grant time;
#        every grant's query cost > 0;
#     C5 sp_PressureDetector's cache_memory: each cache over 0.01 GB in both, within 0.01 GB;
#     C6 PerformanceMonitor's plan cache by type = pgvigil's, plans and sizes exact but for Adhoc, Prepared and Parse
#        Tree (the reads' own statements and system views: within 10 plans); single-use over 20 % (bloat MEDIUM or worse) with optimize for ad hoc off;
#     C7 the window over reads #0-#1: pgvmem_pool's timeouts and forced grants = the hand reads' growth.
#  D. a low-memory notification: a 1 GB table read into the buffer pool (committed over 2,700 MB), then max server
#     memory cut from 4096 to 2560 MB (XTP's 1.3 GB still fits) [after s177g-11: a cut to 1536 MB left too little
#     beside XTP and logins failed]; read #2 (and one more);
#     the hand read of RING_BUFFER_RESOURCE_MONITOR: every record id of this server start is stored once (two reads did
#     not double it), each with the same notification and indicators; sp_PressureDetector's low_memory list (indicator
#     over 1) is in pgvigil's rows (time within 1 s); at least one record with an indicator of 2 or more. The two source
#     reads come after read #2: records past it (by id, by time) are not compared [after review s177g-review9].
#  E. the findings (mssql_memory_findings_between) over reads #0-#2: memory grant timeouts on pgvmem_pool, a low memory
#     notification, high memory use for In-Memory OLTP and In-Memory OLTP in use; over reads #0-#1 (the newest read is
#     #1, the grants still held): a memory grant over 15 % of max workspace (the default-pool holder's session), plan
#     cache bloat with optimize for ad hoc workloads off; the two
#     rules the container cannot provoke, checked on stored rows of their own (a sample with TokenAndPermUserStore at 15 %
#     and 10.0 % of 2 GB of clerks raises the token-cache finding, at 9.99 % and 5 % none; 1 GB of clerks raises it, 1 KB
#     less none; the engine service's IFI flag false raises the IFI finding, true none, the flag restored as read; check 46
#     at 150 MB + 1 KB raises, 150 MB not; the bloat levels at 20 / 30 / 50 % and just over) [edges after review
#     s177g-review9], each removed after.
#  F. `pgvigil serve`: GET /api/mssql/memory over the window: every D13 part answers, its row counts = the functions'.
#  G. #/mssqlmemory over the window in headless Chromium, light and dark: every D13 section present with its rows (the
#     pool and semaphore grids, the pressure events, the grants now, the workload groups, the caches, the plan cache by
#     type), no error box; shots of both themes (the full page); every link and every control (check box, button) of the
#     page clicked once, each in a click table with its landing (a link: the page it opens and no error box; a control:
#     the page still there, no error box).
# NOT PROVEN HERE (when B prints DIFFERENT): a live grant timeout (the rule then checked on stored rows in E);
#   the token-cache and IFI findings on a server that has them (rules checked on stored rows); SQL Server
#   2016-2019, Azure SQL Managed Instance and Amazon RDS (a read the server refuses is a 'skip' row, read in the code);
#   the findings arm on the Findings tab (the lead's join line, 0119's header).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
PROCS=${PGVIGIL_PROC_DIR:-.lab/procs}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvm-sql-$SUF; LBL=pgvigil-proof=d13
PGDB=pgv_mem_$SUF; MON=pgv_mmon_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=; BG=()
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
# sq: T-SQL as sa (stdin, never a command line; -I: QUOTED_IDENTIFIER ON, which the xml methods need); sqok: output not
# wanted, a failure loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
# sqx: the same with XML columns whole (-y 0; sqlcmd refuses -y with -W and with -h, so the columns come padded, with headers)
sqx() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -s "|" -y 0 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
# sess <host> <batch>: sa runs the batch as host <host> in a process group of its own; sesshold: the same, its output
# never read (the pipe fills and the query holds its grant in ASYNC_NETWORK_IO)
cat > "$TMPD/sess.sh" <<'SESS'
printf '%s\nGO\n' "$4" | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$SA_PW exec '"$5"' -S localhost -U sa -C -d pgvmem -H "$0" -i /dev/stdin' "$3" >/dev/null 2>&1
SESS
cat > "$TMPD/hold.sh" <<'HOLD'
{ printf '%s\nGO\n' "$4"; sleep 900; } | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$SA_PW exec '"$5"' -S localhost -U sa -C -d pgvmem -H "$0"' "$3" | sleep 900
HOLD
sess() { setsid bash "$TMPD/sess.sh" "$SQL" "$TMPD/sa.env" "$1" "$2" "$SQLCMD" & BG+=($!); }
sesshold() { setsid bash "$TMPD/hold.sh" "$SQL" "$TMPD/sa.env" "$1" "$2" "$SQLCMD" & BG+=($!); }
# seen <pattern> <n>: wait until n sessions of the pattern are connected (a launch is not a connection)
seen() { local n=0; for _ in $(seq 1 60); do n=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name LIKE '$1'" 2>/dev/null || echo 0); (( n >= $2 )) && return 0; sleep 0.5; done; fail "$3: $n of $2 session(s) $1 connected"; }
gone() { local n=x; for _ in $(seq 1 "${2:-90}"); do n=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name LIKE '$1'" 2>/dev/null || echo x); [[ "$n" == 0 ]] && return 0; sleep 1; done; fail "$3: sessions $1 did not end ($n left)"; }
killhost() { sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; ' FROM sys.dm_exec_sessions WHERE host_name LIKE '$1' AND session_id <> @@SPID; EXEC (@s);" >/dev/null 2>&1 || true; }
for t in docker go psql curl python3 node npm chromium setsid; do command -v "$t" >/dev/null || fail "needs $t"; done
[[ -s "$PROCS/sp_PressureDetector.sql" ]] || fail "needs $PROCS/sp_PressureDetector.sql (the procedure's own source)"
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== A. the container =="
docker run -d --name "$SQL" --label "$LBL" --memory 8g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
up() { local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done
  docker ps -a --filter "name=$SQL" --format '{{.Status}}' >&2; docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "A: the SQL Server container did not come up in 300 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
docker cp "$PROCS/sp_PressureDetector.sql" "$SQL:/tmp/pd.sql" >/dev/null
docker exec --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -d master -i /tmp/pd.sql' >"$TMPD/install.out" 2>&1 || { tail -5 "$TMPD/install.out"; fail "A: installing sp_PressureDetector"; }
echo "A: sp_PressureDetector installed (sha256 $(sha256sum "$PROCS/sp_PressureDetector.sql" | cut -c1-12))"
sqok "A: the server options" "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', 4096; RECONFIGURE;"
sqok "A: the databases" "CREATE DATABASE pgvmem; ALTER DATABASE pgvmem SET RECOVERY SIMPLE; CREATE DATABASE pgvmem_out;
  ALTER DATABASE pgvmem ADD FILEGROUP pgvmem_mo CONTAINS MEMORY_OPTIMIZED_DATA;
  ALTER DATABASE pgvmem ADD FILE (NAME = pgvmem_mo, FILENAME = '/var/opt/mssql/data/pgvmem_mo') TO FILEGROUP pgvmem_mo;"
sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL CONSTRAINT pk_t PRIMARY KEY, pad char(400) NOT NULL DEFAULT 'a', k int NOT NULL DEFAULT 0);
  INSERT dbo.t (id, k) SELECT TOP (300000) n, CHECKSUM(NEWID()) FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b) x;" pgvmem
sqok "A: a 1 GB table for the buffer pool" "CREATE TABLE dbo.big (id int NOT NULL CONSTRAINT pk_big PRIMARY KEY, pad char(500) NOT NULL DEFAULT 'b');
  INSERT dbo.big (id) SELECT TOP (2000000) n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN (SELECT TOP (10) 1 AS z FROM sys.all_objects) c) x;" pgvmem
sqok "A: the memory-optimized table" "CREATE TABLE dbo.mo (id int NOT NULL PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 2097152), pad char(1000) NOT NULL)
  WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY);" pgvmem
sqok "A: loading it" "INSERT dbo.mo (id, pad) SELECT TOP (1150000) n, 'x' FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN (SELECT TOP (10) 1 AS z FROM sys.all_objects) c) x;" pgvmem
XTP=$(sq "SELECT SUM(pages_kb) / 1024 FROM sys.dm_os_memory_clerks WHERE type = 'MEMORYCLERK_XTP'")
(( XTP > 1024 )) || fail "A: MEMORYCLERK_XTP holds $XTP MB (want over 1,024)"
sqok "A: the resource pool and the group" "CREATE RESOURCE POOL pgvmem_pool WITH (MAX_MEMORY_PERCENT = 10);
  CREATE WORKLOAD GROUP pgvmem_grp WITH (REQUEST_MEMORY_GRANT_TIMEOUT_SEC = 1, REQUEST_MAX_MEMORY_GRANT_PERCENT = 50) USING pgvmem_pool;"
sqok "A: the classifier" "GO
CREATE FUNCTION dbo.pgvmem_cls() RETURNS sysname WITH SCHEMABINDING AS
  BEGIN RETURN CASE WHEN HOST_NAME() LIKE N'pgvm[_]rg%' THEN N'pgvmem_grp' ELSE N'default' END; END;"
sqok "A: the classifier on" "ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.pgvmem_cls); ALTER RESOURCE GOVERNOR RECONFIGURE;"
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
echo "ok   A: max server memory 4096 MB, MEMORYCLERK_XTP $XTP MB, pgvmem_pool (10 %) and pgvmem_grp (1 s timeout) classified by host name"

echo "== B. the provocations and the reads =="
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_M_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$TMPD/m.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_M_MON
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
col() { for c in "$@"; do "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance sqlbox -once "$c" >"$TMPD/col-$c.out" 2>&1 || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
semc() { sq "SELECT ISNULL(SUM(s.timeout_error_count), 0), ISNULL(SUM(s.forced_grant_count), 0) FROM sys.dm_exec_query_resource_semaphores s JOIN sys.dm_resource_governor_resource_pools p ON p.pool_id = s.pool_id WHERE p.name = 'pgvmem_pool' AND s.max_target_memory_kb IS NOT NULL" | tr '|' ' '; }
read -r T0 F0 <<<"$(semc)"
col mssql_instance mssql_services mssql_memory
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
R0=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_memory_sample WHERE instance_id = $SB")
[[ -n "$R0" ]] || fail "B: read #0 stored no memory sample"
HOLDQ="SELECT a.id, a.pad FROM dbo.t a ORDER BY a.pad DESC, a.k DESC OPTION (MIN_GRANT_PERCENT = 100, MAXDOP 1);"
sesshold pgvm_rgh1 "$HOLDQ"
sleep 4
ASK="DECLARE @e datetime2 = DATEADD(SECOND, 20, SYSDATETIME()); WHILE SYSDATETIME() < @e BEGIN BEGIN TRY SELECT TOP (1) a.id FROM dbo.t a ORDER BY a.pad, a.k OPTION (MIN_GRANT_PERCENT = 100, MAXDOP 1); END TRY BEGIN CATCH END CATCH END"
FORCE="DECLARE @e datetime2 = DATEADD(SECOND, 20, SYSDATETIME()); WHILE SYSDATETIME() < @e BEGIN BEGIN TRY SELECT TOP (1) a.id FROM dbo.t a ORDER BY a.pad, a.k OPTION (MAXDOP 1); END TRY BEGIN CATCH END CATCH END"
for i in $(seq 1 12); do sess "pgvm_rga$i" "$ASK"; sess "pgvm_rgf$i" "$FORCE"; done
ADHOC="DECLARE @i int = 0, @s nvarchar(200); WHILE @i < 2000 BEGIN SET @s = N'SELECT COUNT(*) FROM dbo.t WHERE id = ' + CAST(@i AS nvarchar(10)) + N' AND k <> ' + CAST(@i * 7 AS nvarchar(10)); EXEC (@s); SET @i += 1; END"
sess pgvm_adhoc "$ADHOC"
sesshold pgvm_big "SELECT a.id, a.pad FROM dbo.t a ORDER BY a.pad DESC, a.k OPTION (MIN_GRANT_PERCENT = 100, MAXDOP 1);"
seen 'pgvm[_]rg[af]%' 24 "B askers"   # (the ad hoc batch may be over by now: its effect is C6's bloat)
gone 'pgvm[_]rga%' 90 "B timeouts"; gone 'pgvm[_]rgf%' 90 "B forced"; gone pgvm_adhoc 120 "B ad hoc"
# a second holder takes the pool's other half: an asker then finds not even its minimum free and times out (8645)
sesshold pgvm_rgh2 "$HOLDQ"
G2=0; for _ in $(seq 1 30); do G2=$(sq "SELECT COUNT(*) FROM sys.dm_exec_query_memory_grants g JOIN sys.dm_exec_sessions s ON s.session_id = g.session_id WHERE s.host_name LIKE 'pgvm[_]rgh%' AND g.grant_time IS NOT NULL"); [[ "$G2" == 2 ]] && break; sleep 1; done
[[ "$G2" == 2 ]] || fail "B: $G2 holder(s) granted, want 2"
BIGASK="DECLARE @e datetime2 = DATEADD(SECOND, 20, SYSDATETIME()); WHILE SYSDATETIME() < @e BEGIN BEGIN TRY SELECT MAX(x.r1 + x.r2 + x.r3) FROM (SELECT ROW_NUMBER() OVER (ORDER BY a.pad, a.k) AS r1, ROW_NUMBER() OVER (ORDER BY a.k, a.pad) AS r2, ROW_NUMBER() OVER (ORDER BY a.pad DESC, a.id) AS r3 FROM dbo.t a) x OPTION (MAXDOP 8, MIN_GRANT_PERCENT = 100, USE HINT('ENABLE_PARALLEL_PLAN_PREFERENCE')); END TRY BEGIN CATCH END CATCH END"
for i in $(seq 1 6); do sess "pgvm_rgt$i" "$BIGASK"; done
seen 'pgvm[_]rgt%' 6 "B askers (pool full)"
gone 'pgvm[_]rgt%' 90 "B timeouts (pool full)"
read -r T1 F1 <<<"$(semc)"
(( T1 > T0 && F1 > F0 )) || echo "B: the pool's timeouts $T0 -> $T1, forced grants $F0 -> $F1 (both should grow)"
TLIVE=1; (( T1 > T0 )) || { TLIVE=0; echo "B: DIFFERENT: no grant timed out in pgvmem_pool ($T0 -> $T1): the timeout finding is checked on stored rows in E, NOT PROVEN live"; }
sqok "B: the group waits 600 s" "ALTER WORKLOAD GROUP pgvmem_grp WITH (REQUEST_MEMORY_GRANT_TIMEOUT_SEC = 600); ALTER RESOURCE GOVERNOR RECONFIGURE;"
for i in $(seq 1 6); do sesshold "pgvm_rgw$i" "$HOLDQ"; done
W=0; for _ in $(seq 1 30); do W=$(sq "SELECT COUNT(*) FROM sys.dm_exec_query_memory_grants WHERE grant_time IS NULL"); [[ "$W" == 6 ]] && break; sleep 1; done
[[ "$W" == 6 ]] || fail "B: $W grant waiter(s), want 6 (the steady state)"
BIG=$(sq "SELECT MIN(g.session_id) FROM sys.dm_exec_query_memory_grants g JOIN sys.dm_exec_sessions s ON s.session_id = g.session_id WHERE s.host_name = 'pgvm_big' AND g.grant_time IS NOT NULL")
[[ "$BIG" =~ ^[0-9]+$ ]] || fail "B: the default-pool holder has no grant"
sleep 2
# read #1, then the sources, the grants unchanged between them (the holders hold, the waiters wait); the semaphores'
# sizes move with the memory broker, so a hand read just before and just after read #1 brackets them
HSEM="SELECT resource_semaphore_id, pool_id, target_memory_kb, total_memory_kb, available_memory_kb FROM sys.dm_exec_query_resource_semaphores"
sq "$HSEM" >"$TMPD/hand-sem0.out" || fail "the read hand-sem0: $(cat "$TMPD/hand-sem0.out" 2>/dev/null | tail -3)"
col mssql_memory
sq "$HSEM" >"$TMPD/hand-sem1.out" || fail "the read hand-sem1: $(cat "$TMPD/hand-sem1.out" 2>/dev/null | tail -3)"
R1=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_memory_sample WHERE instance_id = $SB")
# PerformanceMonitor 3.12.0, MemoryGrantsCollector.cs QueryText, verbatim (MIT, Erik Darling, Darling Data LLC)
sq "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT /* PerformanceMonitorLite */
    resource_semaphore_id = deqrs.resource_semaphore_id,
    pool_id = deqrs.pool_id,
    target_memory_mb = CONVERT(decimal(18,2), deqrs.target_memory_kb / 1024.0),
    max_target_memory_mb = CONVERT(decimal(18,2), deqrs.max_target_memory_kb / 1024.0),
    total_memory_mb = CONVERT(decimal(18,2), deqrs.total_memory_kb / 1024.0),
    available_memory_mb = CONVERT(decimal(18,2), deqrs.available_memory_kb / 1024.0),
    granted_memory_mb = CONVERT(decimal(18,2), ISNULL(deqrs.granted_memory_kb, 0) / 1024.0),
    used_memory_mb = CONVERT(decimal(18,2), ISNULL(deqrs.used_memory_kb, 0) / 1024.0),
    grantee_count = deqrs.grantee_count,
    waiter_count = deqrs.waiter_count,
    timeout_error_count = ISNULL(deqrs.timeout_error_count, 0),
    forced_grant_count = ISNULL(deqrs.forced_grant_count, 0)
FROM sys.dm_exec_query_resource_semaphores AS deqrs
WHERE deqrs.max_target_memory_kb IS NOT NULL
OPTION(RECOMPILE);" >"$TMPD/pm-sem.out" || fail "B: PerformanceMonitor's semaphore read"
# PerformanceMonitor 3.12.0, PlanCacheStatsCollector.cs QueryText, verbatim but its last column (oldest_plan_create_time)
sq "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT /* PerformanceMonitorLite */
    cacheobjtype = cp.cacheobjtype,
    objtype = cp.objtype,
    total_plans = CONVERT(integer, COUNT_BIG(*)),
    total_size_mb = CONVERT(integer, SUM(CONVERT(bigint, cp.size_in_bytes)) / 1024 / 1024),
    single_use_plans = SUM(CASE WHEN cp.usecounts = 1 THEN 1 ELSE 0 END),
    single_use_size_mb = CONVERT(integer, SUM(CASE WHEN cp.usecounts = 1 THEN CONVERT(bigint, cp.size_in_bytes) ELSE 0 END) / 1024 / 1024),
    multi_use_plans = SUM(CASE WHEN cp.usecounts > 1 THEN 1 ELSE 0 END),
    multi_use_size_mb = CONVERT(integer, SUM(CASE WHEN cp.usecounts > 1 THEN CONVERT(bigint, cp.size_in_bytes) ELSE 0 END) / 1024 / 1024),
    avg_use_count = CONVERT(decimal(38,2), AVG(CONVERT(bigint, cp.usecounts)))
FROM sys.dm_exec_cached_plans AS cp
GROUP BY cp.cacheobjtype, cp.objtype;" >"$TMPD/pm-plan.out" || fail "B: PerformanceMonitor's plan cache read"
sqok "B: sp_PressureDetector logged" "EXEC dbo.sp_PressureDetector @what_to_check = 'memory', @skip_plan_xml = 1, @log_to_table = 1, @log_database_name = N'pgvmem_out', @log_schema_name = N'dbo', @log_table_name_prefix = N'pd';"
sqx "EXEC dbo.sp_PressureDetector @what_to_check = 'memory', @skip_queries = 1, @skip_plan_xml = 1;" >"$TMPD/pd-raw.out" 2>&1 || fail "B: sp_PressureDetector unlogged: $(tail -3 "$TMPD/pd-raw.out")"
sq "SELECT resource_semaphore_id, pool_id, ISNULL(CAST(max_target_memory_kb AS varchar(20)), 'NULL') FROM sys.dm_exec_query_resource_semaphores ORDER BY pool_id, resource_semaphore_id" >"$TMPD/hand-sem.out" || fail "the read hand-sem: $(cat "$TMPD/hand-sem.out" 2>/dev/null | tail -3)"
sq "SELECT memory_source, memory_consumer, memory_consumed_gb FROM dbo.pd_MemoryConsumers WHERE memory_source LIKE 'Non-Buffer Pool Memory%'" pgvmem_out >"$TMPD/pd-cons.out" || fail "the read pd-cons: $(cat "$TMPD/pd-cons.out" 2>/dev/null | tail -3)"
sq "SELECT resource_semaphore_id, pool_id, target_memory_gb, max_target_memory_gb, total_memory_gb, available_memory_gb, granted_memory_gb, used_memory_gb, grantee_count, waiter_count, timeout_error_count, forced_grant_count, ISNULL(total_reduced_memory_grant_count, -1), CAST(CAST(max_memory_grant_cap AS nvarchar(max)) AS nvarchar(4000)) FROM dbo.pd_Memory" pgvmem_out >"$TMPD/pd-mem.out" || fail "the read pd-mem: $(cat "$TMPD/pd-mem.out" 2>/dev/null | tail -3)"
sq "SELECT session_id, requested_memory_gb, granted_memory_gb, ideal_memory_gb, required_memory_gb, ISNULL(queue_id, -1), ISNULL(wait_order, -1), ISNULL(CAST(is_next_candidate AS int), -1), dop, CASE WHEN grant_time IS NULL THEN 0 ELSE 1 END FROM dbo.pd_MemoryQueries" pgvmem_out >"$TMPD/pd-q.out" || fail "the read pd-q: $(cat "$TMPD/pd-q.out" 2>/dev/null | tail -3)"
read -r T2 F2 <<<"$(semc)"
echo "B: read #1 at $R1; the pool's timeouts $T0 -> $T2, forced grants $F0 -> $F2; 6 waiters; the default-pool holder $BIG"
echo "ok   B: the provocations took (timeouts and forced grants grew in pgvmem_pool; 6 waiters at the steady state)"

echo "== C. read #1 against the sources =="
python3 - "$TMPD" "$PGDSN" "$SB" "$R1" "$R0" "$T0" "$F0" "$T2" "$F2" <<'PYEND' || fail "C: see above"
import sys, subprocess, re, json, decimal
D, dsn, sb, r1, r0, t0, f0, t2, f2 = sys.argv[1:]
def pq(q):
    return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', q], check=True, capture_output=True, text=True).stdout.splitlines() if l]
def rows(f):
    return [l.split('|') for l in open(f'{D}/{f}').read().splitlines() if l.strip() and not l.startswith('Warning')]
bad = []
Q = decimal.Decimal('0.01')
def gb(kb): return '' if kb in ('', None) else str((decimal.Decimal(int(kb)) / decimal.Decimal(1048576)).quantize(Q, rounding=decimal.ROUND_HALF_UP))
def mb(kb): return '' if kb in ('', None) else str((decimal.Decimal(int(kb)) / decimal.Decimal(1024)).quantize(Q, rounding=decimal.ROUND_HALF_UP))
def near(a, b): return a != '' and b != '' and abs(decimal.Decimal(a) - decimal.Decimal(b)) <= Q
def within(a, b, pct): return a != '' and b != '' and abs(decimal.Decimal(a) - decimal.Decimal(b)) <= max(Q, abs(decimal.Decimal(b)) * decimal.Decimal(pct) / 100)
# the semaphore's sizes (target, max target, total, available: the first four) move with the memory broker between two
# reads; granted, used and the counts are exact
# against a source read later: max target within 2 %, granted, used and the counts exact; target, total and available
# are the moment's (checked against the hand reads that bracket pgvigil's read, below)
def semeq(mine, theirs, pct): return within(mine[1], theirs[1], 2) and mine[4:] == theirs[4:]
br0 = {(r[0], r[1]): [int(x) for x in r[2:5]] for r in rows('hand-sem0.out')}
br1 = {(r[0], r[1]): [int(x) for x in r[2:5]] for r in rows('hand-sem1.out')}
# C1: per semaphore with a max target
ours = {(r[0], r[1]): r for r in pq(f"SELECT semaphore_id, pool_id, target_kb, max_target_kb, total_kb, available_kb, granted_kb, used_kb, grantees, waiters, timeouts_total, forced_total FROM pgvigil.mssql_grant_newest_between({sb}, '{r0}', '{r1}', true) WHERE max_target_kb IS NOT NULL")}
pd = {(r[0], r[1]): r for r in rows('pd-mem.out')}
if set(ours) != set(pd): bad.append(f"C1 semaphores: pgvigil {sorted(ours)} sp_PressureDetector {sorted(pd)}")
for k in set(ours) & set(pd):
    o, p = ours[k], pd[k]
    mine = [gb(x) for x in o[2:8]] + o[8:12]
    theirs = [str(decimal.Decimal(x)) for x in p[2:8]] + p[8:12]
    if not semeq(mine, theirs, 5): bad.append(f"C1 semaphore {k}: pgvigil {mine} sp_PressureDetector {theirs}")
pm = {(r[0], r[1]): r for r in rows('pm-sem.out')}
for k in set(ours) | set(pm):
    if k not in ours or k not in pm: bad.append(f"C1 PerformanceMonitor semaphore {k} in one read only"); continue
    o, p = ours[k], pm[k]
    mine = [mb(x) for x in o[2:8]] + o[8:12]
    theirs = [str(decimal.Decimal(x)) for x in p[2:8]] + p[8:12]
    if not semeq(mine, theirs, 2): bad.append(f"C1 PerformanceMonitor semaphore {k}: pgvigil {mine} PerformanceMonitor {theirs}")
for k, o in ours.items():
    if k not in br0 or k not in br1: bad.append(f"C1 semaphore {k} not in the bracketing hand reads"); continue
    for i, (name, v) in enumerate(zip(('target', 'total', 'available'), (o[2], o[4], o[5]))):
        lo, hi = min(br0[k][i], br1[k][i]), max(br0[k][i], br1[k][i])
        if not (lo <= int(v) <= hi): bad.append(f"C1 semaphore {k} {name}: pgvigil {v} KB outside the hand reads before / after it [{br0[k][i]}, {br1[k][i]}]")
alls = {(r[0], r[1]) for r in rows('hand-sem.out')}
oura = {(r[0], r[1]) for r in pq(f"SELECT semaphore_id, pool_id FROM pgvigil.mssql_grant_newest_between({sb}, '{r0}', '{r1}', true)")}
if alls != oura: bad.append(f"C1 every semaphore: the DMV {sorted(alls)} pgvigil {sorted(oura)}")
# C2: the grant cap and the reduced grants
cap = rows('pd-mem.out')[0][13]
capd = dict(re.findall(r'<group_name>([^<]*)</group_name><max_grant_percent>(\d+)</max_grant_percent>', cap))
ourc = {r[0]: r[1] for r in pq(f"SELECT group_name, max_grant_pct FROM pgvigil.mssql_rg_group WHERE instance_id = {sb}")}
if capd != ourc: bad.append(f"C2 grant cap: sp_PressureDetector {capd} pgvigil {ourc}")
red = {r[1]: r[12] for r in rows('pd-mem.out')}
ourr = {r[0]: r[1] for r in pq(f"SELECT pool_id, max(reduced_grants) FROM pgvigil.mssql_rg_group WHERE instance_id = {sb} GROUP BY pool_id")}
for p, v in red.items():
    if v != '-1' and ourr.get(p) != v: bad.append(f"C2 reduced grants pool {p}: sp_PressureDetector {v} pgvigil {ourr.get(p)}")
# C3: the five largest clerks but the buffer pool, and stolen memory
cons = rows('pd-cons.out')
top5 = [(r[1], r[2]) for r in cons if r[0] == 'Non-Buffer Pool Memory: Top Five']
oc = pq(f"SELECT clerk_type, pages_kb FROM pgvigil.mssql_memory_clerk WHERE instance_id = {sb} AND snapshot_at = '{r1}' AND clerk_type NOT IN ('MEMORYCLERK_SQLBUFFERPOOL', '(other)') ORDER BY pages_kb DESC LIMIT 5")
mine5 = dict((r[0], gb(r[1])) for r in oc); theirs5 = dict((a, str(decimal.Decimal(b))) for a, b in top5)
if set(mine5) != set(theirs5) or not all(near(mine5[k], theirs5[k]) for k in mine5): bad.append(f"C3 top five: pgvigil {sorted(mine5.items())} sp_PressureDetector {sorted(theirs5.items())}")
st = [r[2] for r in cons if r[0] == 'Non-Buffer Pool Memory: Total']
ost = pq(f"SELECT stolen_kb FROM pgvigil.mssql_memory_sample WHERE instance_id = {sb} AND snapshot_at = '{r1}'")[0][0]
if not st or not within(gb(ost), str(decimal.Decimal(st[0])), 3): bad.append(f"C3 stolen: sp_PressureDetector {st} pgvigil {gb(ost)} GB")
# C4: the grants now
q = {r[0]: r for r in rows('pd-q.out')}
og = {r[0]: r for r in pq(f"SELECT session_id, requested_kb, granted_kb, ideal_kb, required_kb, coalesce(queue_id, -1), coalesce(wait_order, -1), coalesce(is_next_candidate::int, -1), dop, CASE WHEN grant_at IS NULL THEN 0 ELSE 1 END, coalesce(query_cost, 0) > 0 FROM pgvigil.mssql_memory_grant_query WHERE instance_id = {sb} AND snapshot_at = '{r1}'")}
if set(q) != set(og): bad.append(f"C4 sessions: sp_PressureDetector {sorted(q)} pgvigil {sorted(og)}")
for s in set(q) & set(og):
    o, p = og[s], q[s]
    mine = [gb(o[1]), gb(o[2]) if o[2] else '', gb(o[3]), gb(o[4])] + o[5:10]
    theirs = [str(decimal.Decimal(x)) if x not in ('', 'NULL') else '' for x in p[1:5]] + p[5:10]
    if mine != theirs: bad.append(f"C4 session {s}: pgvigil {mine} sp_PressureDetector {theirs}")
    if o[10] != 't': bad.append(f"C4 session {s}: no query cost")
waiting = sum(1 for o in og.values() if o[9] == '0')
if waiting != 6: bad.append(f"C4 waiters without a grant time: {waiting}, want 6")
# C5: the caches (sp_PressureDetector's XML from the unlogged run)
raw = open(f'{D}/pd-raw.out').read()
caches = re.findall(r'<cache><name>([^<]*)</name><pages_gb>([0-9.]+)</pages_gb>', raw)
oca = {r[0]: gb(r[1]) for r in pq(f"SELECT cache_name, pages_kb FROM pgvigil.mssql_memory_cache WHERE instance_id = {sb} AND snapshot_at = '{r1}'")}
if not caches: bad.append("C5 no cache in sp_PressureDetector's output")
for n, g in caches:
    if decimal.Decimal(g) > Q and not near(oca.get(n, ''), str(decimal.Decimal(g))): bad.append(f"C5 cache {n}: sp_PressureDetector {g} pgvigil {oca.get(n)}")
for n, g in oca.items():
    if decimal.Decimal(g) > Q and n not in dict(caches): bad.append(f"C5 cache {n} ({g} GB) not in sp_PressureDetector's")
# C6: the plan cache by type
pmp = {(r[0], r[1]): r for r in rows('pm-plan.out')}
op = {(r[0], r[1]): r for r in pq(f"SELECT cache_type, object_type, plans, size_kb / 1024, single_use_plans, single_use_kb / 1024, multi_use_plans, multi_use_kb / 1024 FROM pgvigil.mssql_plancache_type WHERE instance_id = {sb} AND snapshot_at = '{r1}'")}
for k in set(pmp) | set(op):
    if k not in pmp or k not in op:
        if k[1] not in ('Adhoc', 'Prepared') and k[0] != 'Parse Tree': bad.append(f"C6 plan cache {k} in one read only")
        continue
    a, b = op[k][2:8], pmp[k][2:8]
    if k[1] in ('Adhoc', 'Prepared') or k[0] == 'Parse Tree':
        if abs(int(a[0]) - int(b[0])) > 10: bad.append(f"C6 plan cache {k}: pgvigil {a} PerformanceMonitor {b} (over 10 plans apart)")
    elif a != b: bad.append(f"C6 plan cache {k}: pgvigil {a} PerformanceMonitor {b}")
s = pq(f"SELECT bloat_level, optimize_for_ad_hoc, single_use_pct FROM pgvigil.mssql_plancache_summary_between({sb}, '{r0}', '{r1}')")
if not s or s[0][0] == 'NORMAL' or s[0][1] != '0': bad.append(f"C6 bloat: {s}")
# C7: the window's growth
w = pq(f"SELECT timeouts, forced_grants FROM pgvigil.mssql_grant_window_between({sb}, '{r0}'::timestamptz - interval '1 second', '{r1}', false) WHERE pool_name = 'pgvmem_pool'")
if not w or [int(w[0][0]), int(w[0][1])] != [int(t2) - int(t0), int(f2) - int(f0)]:
    bad.append(f"C7 the window's timeouts and forced grants {w} (the hand reads' growth {int(t2) - int(t0)}, {int(f2) - int(f0)})")
for b in bad: print('DIFF', b)
print(f"C: {len(ours)} semaphore(s) with a max target, {len(oura)} in all, {len(og)} grant(s) ({waiting} waiting), {len(caches)} cache(s), {len(op)} plan cache type(s), bloat {s[0][0] if s else '-'} at {s[0][2] if s else '-'} %, the window's growth {w}")
sys.exit(1 if bad else 0)
PYEND
echo "ok   C: read #1 equals sp_PressureDetector's semaphores, grant cap, reduced grants, top five clerks, stolen memory, grants and caches, PerformanceMonitor's semaphores and plan cache by type, and the hand reads' growth over the window"

echo "== D. a low-memory notification =="
for h in 'pgvm[_]rg%' pgvm_big; do killhost "$h"; done
gone 'pgvm[_]rg%' 60 "D the holders"; gone pgvm_big 60 "D the big grant"
sqok "D: the big table into the buffer pool" "SELECT COUNT(*) FROM dbo.big WITH (INDEX(pk_big)) WHERE pad <> 'z';" pgvmem
COMMIT0=$(sq "SELECT committed_kb / 1024 FROM sys.dm_os_sys_info")
echo "D: committed $COMMIT0 MB before the cut to 2560 MB (MEMORYCLERK_XTP $XTP MB)"
(( COMMIT0 > 2700 )) || fail "D: committed $COMMIT0 MB: not enough above 2560 MB for the cut to make SQL Server shrink"
sqok "D: max server memory down" "EXEC sp_configure 'max server memory (MB)', 2560; RECONFIGURE;"
sleep 15
for _ in $(seq 1 30); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
echo "D: committed $(sq "SELECT committed_kb / 1024 FROM sys.dm_os_sys_info") MB after the cut"
col mssql_memory
col mssql_memory
R2=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_memory_sample WHERE instance_id = $SB")
sq "SELECT CAST(x.record.value('(/Record/@id)[1]', 'bigint') AS varchar(20)), x.record.value('(/Record/ResourceMonitor/Notification)[1]', 'varchar(60)'), ISNULL(x.record.value('(/Record/ResourceMonitor/IndicatorsProcess)[1]', 'int'), -1), ISNULL(x.record.value('(/Record/ResourceMonitor/IndicatorsSystem)[1]', 'int'), -1) FROM (SELECT CONVERT(xml, record) AS record FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_RESOURCE_MONITOR') x" >"$TMPD/hand-rb.out" || fail "the read hand-rb: $(cat "$TMPD/hand-rb.out" 2>/dev/null | tail -3)"
sqx "EXEC dbo.sp_PressureDetector @what_to_check = 'memory', @skip_queries = 1, @skip_plan_xml = 1;" >"$TMPD/pd-raw2.out" 2>&1 || fail "D: sp_PressureDetector"
python3 - "$TMPD" "$PGDSN" "$SB" "$R2" <<'PYEND' || fail "D: see above"
import sys, subprocess, re, datetime
D, dsn, sb, r2 = sys.argv[1:]
def pq(q):
    return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', q], check=True, capture_output=True, text=True).stdout.splitlines() if l]
hand = {r[0]: r[1:] for r in (l.split('|') for l in open(f'{D}/hand-rb.out').read().splitlines() if l.strip())}
ours = pq(f"SELECT record_id, notification, coalesce(ind_process, -1), coalesce(ind_system, -1), to_char(snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS') FROM pgvigil.mssql_memory_rmon WHERE instance_id = {sb}")
bad = []
# the sources are read after pgvigil's read #2: a record they hold past it is not pgvigil's yet
last = max((int(r[0]) for r in ours), default=-1)
hand = {k: v for k, v in hand.items() if int(k) <= last}
r2t = datetime.datetime.fromisoformat(pq(f"SELECT to_char('{r2}'::timestamptz AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS')")[0][0])
ids = [r[0] for r in ours]
if len(ids) != len(set(ids)): bad.append(f"D a record stored twice: {len(ids)} rows, {len(set(ids))} ids")
od = {r[0]: r[1:4] for r in ours}
for k, v in hand.items():
    if od.get(k) != [str(x) for x in v]: bad.append(f"D record {k}: the ring buffer {v} pgvigil {od.get(k)}")
hi = [r for r in ours if int(r[2]) >= 2 or int(r[3]) >= 2]
if not hi: bad.append("D no record with an indicator of 2 or more: the cut did not provoke one")
raw = open(f'{D}/pd-raw2.out').read()
low = re.findall(r'<memory><sample_time>([^<]*)</sample_time><notification_type>([^<]*)</notification_type><indicators_process>(\d+)</indicators_process><indicators_system>(\d+)</indicators_system>', raw)
low = [x for x in low if datetime.datetime.fromisoformat(x[0][:19]) <= r2t]
for t, n, ip, isy in low:
    ts = datetime.datetime.fromisoformat(t[:19])
    m = [r for r in ours if r[1] == n and r[2] == ip and r[3] == isy and abs((datetime.datetime.fromisoformat(r[4][:19]) - ts).total_seconds()) <= 1]
    if not m: bad.append(f"D sp_PressureDetector's low-memory sample {t} {n} {ip}/{isy} not in pgvigil's rows")
for b in bad: print('DIFF', b)
print(f"D: {len(hand)} ring buffer record(s), {len(ours)} stored once each; {len(hi)} with an indicator of 2 or more; sp_PressureDetector's low-memory list {len(low)} sample(s), each in pgvigil's rows")
sys.exit(1 if bad else 0)
PYEND
echo "ok   D: the resource monitor's records stored once each, equal to the ring buffer; sp_PressureDetector's low-memory samples among them"

echo "== E. the findings =="
F="pgvigil.mssql_memory_findings_between($SB, '$R0'::timestamptz - interval '1 second', '$R2')"
F1="pgvigil.mssql_memory_findings_between($SB, '$R0'::timestamptz - interval '1 second', '$R1')"
fnd() { pq "SELECT count(*) FROM $F WHERE check_name = '$1'${2:+ AND object = '$2'}"; }
fnd1() { pq "SELECT count(*) FROM $F1 WHERE check_name = '$1'${2:+ AND object = '$2'}"; }
if (( TLIVE )); then
  [[ "$(fnd 'memory grant timeouts' pgvmem_pool)" == 1 ]] || fail "E: no 'memory grant timeouts' on pgvmem_pool: $(pq "SELECT check_name, object FROM $F")"
else
  [[ "$(fnd 'memory grant timeouts')" == 0 ]] || fail "E: a 'memory grant timeouts' finding with no timeout"
  # the rule on stored rows of its own: a pool 999 read twice an hour before the run, its counter 0 then 3
  TT=$(pq "SELECT to_char(date_trunc('minute', now()) - interval '4 hours', 'YYYY-MM-DD HH24:MI:SSOF')")
  pq "SELECT pgvigil.ensure_month_partition('mssql_memory_pool', '$TT'::timestamptz - interval '1 minute'), pgvigil.ensure_month_partition('mssql_memory_pool', '$TT')" >/dev/null
  pq "INSERT INTO pgvigil.mssql_memory_pool (instance_id, snapshot_at, pool_id, pool_name, semaphore_id, max_target_kb, waiters, granted_kb, available_kb, timeout_errors, forced_grants)
      VALUES ($SB, '$TT'::timestamptz - interval '1 minute', 999, 'proofpool', 0, 1024, 0, 0, 1024, 0, 0), ($SB, '$TT', 999, 'proofpool', 0, 1024, 2, 1024, 0, 3, 0)" >/dev/null
  TF=$(pq "SELECT count(*) FROM pgvigil.mssql_memory_findings_between($SB, '$TT'::timestamptz - interval '30 seconds', '$TT') WHERE check_name = 'memory grant timeouts' AND object = 'proofpool' AND detail LIKE '3 memory grant request(s)%'")
  pq "DELETE FROM pgvigil.mssql_memory_pool WHERE instance_id = $SB AND pool_id = 999" >/dev/null
  [[ "$TF" == 1 ]] || fail "E: the timeout rule on stored rows (a counter 0 -> 3 raises it)"
  echo "E: 'memory grant timeouts' checked on stored rows (a pool's counter 0 -> 3 raises it); NOT PROVEN live"
fi
[[ "$(fnd 'low memory notification')" -ge 1 ]] || fail "E: no 'low memory notification'"
[[ "$(fnd 'high memory use for In-Memory OLTP')" == 1 && "$(fnd 'In-Memory OLTP in use')" == 1 ]] || fail "E: the In-Memory OLTP findings: $(pq "SELECT check_name, detail FROM $F WHERE object = 'MEMORYCLERK_XTP'")"
[[ "$(fnd1 'a memory grant over 15 % of max workspace' "session $BIG")" == 1 ]] || fail "E: no 15 % finding on session $BIG over reads #0-#1: $(pq "SELECT object, detail FROM $F1 WHERE check_name LIKE 'a memory grant%'")"
[[ "$(fnd1 'plan cache bloat with optimize for ad hoc workloads off')" == 1 ]] || fail "E: no plan cache bloat finding over reads #0-#1"
[[ "$(fnd 'memory leak in USERSTORE_TOKENPERM cache')" == 0 && "$(fnd 'instant file initialization off')" == 0 ]] || fail "E: a token-cache or IFI finding the server does not have"
# the two rules the container cannot provoke, on stored rows of their own (a sample in its own minute, then removed)
TS=$(pq "SELECT to_char(date_trunc('minute', now()) - interval '3 hours', 'YYYY-MM-DD HH24:MI:SSOF')")
for tb in mssql_memory_sample mssql_memory_pool mssql_memory_grant_query mssql_plancache_type; do pq "SELECT pgvigil.ensure_month_partition('$tb', '$TS'::timestamptz - interval '2 hours')" >/dev/null; pq "SELECT pgvigil.ensure_month_partition('$tb', '$TS')" >/dev/null; done
tok() { pq "INSERT INTO pgvigil.mssql_memory_sample (instance_id, snapshot_at, clerks_kb, tokenperm_kb) VALUES ($SB, '$TS', 2097152, $1)" >/dev/null
  pq "SELECT count(*) FROM pgvigil.mssql_memory_findings_between($SB, '$TS'::timestamptz - interval '1 minute', '$TS') WHERE check_name = 'memory leak in USERSTORE_TOKENPERM cache'"
  pq "DELETE FROM pgvigil.mssql_memory_sample WHERE instance_id = $SB AND snapshot_at = '$TS'" >/dev/null; }
[[ "$(tok 314573)" == 1 && "$(tok 104858)" == 0 && "$(tok 209716)" == 1 && "$(tok 209714)" == 0 ]] \
  || fail "E: the token-cache rule on stored rows (15 % and 10.0 % raise; 9.99 % and 5 % do not)"
tok1g() { pq "INSERT INTO pgvigil.mssql_memory_sample (instance_id, snapshot_at, clerks_kb, tokenperm_kb) VALUES ($SB, '$TS', $1, $2)" >/dev/null
  pq "SELECT count(*) FROM pgvigil.mssql_memory_findings_between($SB, '$TS'::timestamptz - interval '1 minute', '$TS') WHERE check_name = 'memory leak in USERSTORE_TOKENPERM cache'"
  pq "DELETE FROM pgvigil.mssql_memory_sample WHERE instance_id = $SB AND snapshot_at = '$TS'" >/dev/null; }
[[ "$(tok1g 1048576 157287)" == 1 && "$(tok1g 1048575 157287)" == 0 ]] || fail "E: the token-cache rule's 1 GB of clerks (1 GB raises, 1 KB less does not)"
# check 46 at its edge: Maximum Workspace 1,000 MB, the threshold 150 MB (a grant of 150 MB + 1 KB raises, 150 MB does not)
g46() { pq "INSERT INTO pgvigil.mssql_memory_sample (instance_id, snapshot_at, max_workspace_kb, max_grant_kb) VALUES ($SB, '$TS', 1024000, $1)" >/dev/null
  pq "INSERT INTO pgvigil.mssql_memory_grant_query (instance_id, snapshot_at, session_id, granted_kb) VALUES ($SB, '$TS', 4242, $1)" >/dev/null
  pq "SELECT count(*) FROM pgvigil.mssql_memory_findings_between($SB, '$TS'::timestamptz - interval '1 minute', '$TS') WHERE check_name = 'a memory grant over 15 % of max workspace'"
  pq "DELETE FROM pgvigil.mssql_memory_grant_query WHERE instance_id = $SB AND snapshot_at = '$TS'; DELETE FROM pgvigil.mssql_memory_sample WHERE instance_id = $SB AND snapshot_at = '$TS'" >/dev/null; }
[[ "$(g46 153601)" == 1 && "$(g46 153600)" == 0 ]] || fail "E: check 46's 15 % edge on stored rows"
# PerformanceMonitor's bloat levels at their edges (single-use plans of 1,000: 200 NORMAL, 201 MEDIUM, 301 HIGH, 501 CRITICAL)
blo() { pq "INSERT INTO pgvigil.mssql_plancache_type (instance_id, snapshot_at, cache_type, object_type, plans, single_use_plans, size_kb, single_use_kb) VALUES ($SB, '$TS', 'Compiled Plan', 'Adhoc', 1000, $1, 1000, $1)" >/dev/null
  pq "SELECT bloat_level FROM pgvigil.mssql_plancache_summary_between($SB, '$TS'::timestamptz - interval '1 minute', '$TS')"
  pq "DELETE FROM pgvigil.mssql_plancache_type WHERE instance_id = $SB AND snapshot_at = '$TS'" >/dev/null; }
[[ "$(blo 200)|$(blo 201)|$(blo 300)|$(blo 301)|$(blo 500)|$(blo 501)" == "NORMAL|MEDIUM|MEDIUM|HIGH|HIGH|CRITICAL" ]] || fail "E: the bloat levels' edges"
echo "E: on stored rows: the token cache at 10.0 % / 9.99 % and 1 GB / 1 GB - 1 KB, check 46 at 150 MB + 1 KB / 150 MB of a 1,000 MB workspace, the bloat levels at 20 / 30 / 50 % and just over"
ENG=$(pq "SELECT service_name FROM pgvigil.mssql_service WHERE instance_id = $SB AND service_name LIKE 'SQL Server (%' AND is_present LIMIT 1")
MADE_ENG=
if [[ -z "$ENG" ]]; then
  # the Linux container's sys.dm_server_services gives no engine row to store [s177g-15]: a row of the proof's own
  ENG="SQL Server (PGVPROOF)"; MADE_ENG=1
  pq "INSERT INTO pgvigil.mssql_service (instance_id, service_name, snapshot_at, ifi_enabled) VALUES ($SB, '$ENG', now(), NULL)" >/dev/null
fi
IFI0=$(pq "SELECT coalesce(ifi_enabled::text, 'NULL') FROM pgvigil.mssql_service WHERE instance_id = $SB AND service_name = '$ENG'")
ifiset() { pq "UPDATE pgvigil.mssql_service SET ifi_enabled = $1 WHERE instance_id = $SB AND service_name = '$ENG'" >/dev/null; }
ifiset false; IFIF=$(fnd 'instant file initialization off' "$ENG")
ifiset true; IFIT=$(fnd 'instant file initialization off' "$ENG")
case "$IFI0" in true|false) ifiset "$IFI0" ;; *) ifiset NULL ;; esac
[[ -n "$MADE_ENG" ]] && pq "DELETE FROM pgvigil.mssql_service WHERE instance_id = $SB AND service_name = '$ENG'" >/dev/null
[[ "$IFIF" == 1 && "$IFIT" == 0 ]] || fail "E: the IFI rule on the stored row (false: $IFIF finding(s), want 1; true: $IFIT, want 0)"
pq "SELECT severity || ' | ' || check_name || ' | ' || object FROM $F ORDER BY 1"
echo "ok   E: the six findings the server has raised over the window, none it does not have; the token-cache and IFI rules on stored rows (IFI as read: '$IFI0')"

echo "== F. the API under pgvigil serve =="
(cd web && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "F: the web build"; }
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "F: user add"
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.out" >&2; fail "F: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "F: the API login"
FROM=$(python3 -c "import sys,urllib.parse as u; print(u.quote(sys.argv[1]))" "$(pq "SELECT to_char(('$R0'::timestamptz - interval '1 second') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")")
TO=$(python3 -c "import sys,urllib.parse as u; print(u.quote(sys.argv[1]))" "$(pq "SELECT to_char(('$R2'::timestamptz + interval '1 second') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")")
curl -fs -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/memory?instance=$SB&from=$FROM&to=$TO" >"$TMPD/api.json" || fail "F: GET /api/mssql/memory"
python3 - "$TMPD/api.json" "$PGDSN" "$SB" "$R0" "$R2" <<'PYEND' || fail "F: see above"
import sys, json, subprocess
f, dsn, sb, r0, r2 = sys.argv[1:]
d = json.load(open(f))
def n(q): return int(subprocess.run(['psql', dsn, '-XAtq', '-c', q], check=True, capture_output=True, text=True).stdout.strip())
w = f"{sb}, '{r0}'::timestamptz - interval '1 second', '{r2}'::timestamptz + interval '1 second'"
want = {'pools_window': f"SELECT count(*) FROM pgvigil.mssql_grant_window_between({w}, false)",
        'semaphores_window': f"SELECT count(*) FROM pgvigil.mssql_grant_window_between({w}, true)",
        'pools_newest': f"SELECT count(*) FROM pgvigil.mssql_grant_newest_between({w}, false)",
        'semaphores_newest': f"SELECT count(*) FROM pgvigil.mssql_grant_newest_between({w}, true)",
        'rmon_hourly': f"SELECT count(*) FROM pgvigil.mssql_memory_rmon_hourly({w})",
        'plancache': f"SELECT count(*) FROM pgvigil.mssql_plancache_summary_between({w})",
        'rg': f"SELECT count(*) FROM pgvigil.mssql_rg_group WHERE instance_id = {sb}"}
bad = []
def cnt(part):
    t = d.get(part)
    if t is None: return None
    return len(t.get('rows', t) if isinstance(t, dict) else t)
for p, q in want.items():
    if cnt(p) != n(q): bad.append(f"F {p}: the API {cnt(p)} rows, the function {n(q)}")
for p in ('pool_series', 'rmon', 'caches', 'plancache_types', 'plancache_trend', 'grants_now', 'skipped', 'checks'):
    if p not in d: bad.append(f"F {p}: no such part")
for b in bad: print('DIFF', b)
print('F: ' + ', '.join(f"{p} {cnt(p)}" for p in sorted(d)))
sys.exit(1 if bad else 0)
PYEND
echo "ok   F: every D13 part of /api/mssql/memory answers, the counted ones equal to their functions"

echo "== G. the Memory page in headless Chromium =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
setsid chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1100 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "G: chromium's CDP port never answered"
cat > "$TMPD/g.mjs" <<'JS'
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
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0 && !!m.querySelector('h2'); })()`); if (ok) { await sleep(500); return true; } await sleep(200); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
const SECTIONS = ['Memory pressure events', 'Memory grant pressure (every read of the range, per pool)', 'Memory grants (the newest read of the range, per pool: a moment, not the range)',
  'Resource semaphore pressure (every read of the range, per semaphore)', 'Resource semaphores (the newest read of the range)', 'Workload groups and resource pools (the newest read)',
  'Queries with memory grants (the newest read)', 'Caches (the newest read, the 20 largest)', 'Plan cache (the newest read)', 'Plan cache by type'];
const state = () => ev(`(() => { const m = document.querySelector('main');
  const after = (title) => { const h = [...m.querySelectorAll('h3')].find(x => x.textContent === title); if (!h) return -1; let g = h.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE' && g.tagName !== 'H3') g = g.nextElementSibling; return g && g.tagName !== 'H3' ? [...g.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')).length : 0; };
  return JSON.stringify({ hash: location.hash, title: m.querySelector('h2')?.textContent ?? '', sections: Object.fromEntries(${JSON.stringify(SECTIONS)}.map(s => [s, after(s)])),
    tiles: [...m.querySelectorAll('.tile')].length, errors: m.querySelectorAll('.error:not([role=status])').length,
    links: [...m.querySelectorAll('a[href]')].map(a => ({ t: a.textContent.trim(), h: a.getAttribute('href') })),
    controls: [...m.querySelectorAll('input, button, select')].length }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.G_USR)}, password: ${JSON.stringify(process.env.G_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
const page = `#/mssqlmemory?i=${sb}&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
for (const theme of ['light', 'dark']) {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  if (!await go(page)) { console.log(`FAIL render ${theme}`); continue; }
  const s = await state(); console.log(`page ${theme} ${JSON.stringify({ title: s.title, sections: s.sections, tiles: s.tiles, errors: s.errors, controls: s.controls })}`);
  await shot(`memory-d13-${theme}`);
}
// every link, each distinct target once: where it lands
await go(page);
const links = (await state()).links; const seen = new Set();
for (const l of links) {
  if (seen.has(l.h)) continue; seen.add(l.h);
  if (!l.h.startsWith('#')) { console.log(`click link ${JSON.stringify(l.t)} ${l.h} -> external (not followed)`); continue; }
  const ok = await go(l.h); const r = await state();
  console.log(`click link ${JSON.stringify(l.t)} ${l.h} -> ${r.hash} title=${JSON.stringify(r.title)} errors=${r.errors} rendered=${ok} same=${r.hash.split('?')[0] === l.h.split('?')[0]}`);
  await go(page);
}
// every control: clicked once in the page's order (a check box twice: back as it was), the page still there after
await go(page);
const n = (await state()).controls;
for (let i = 0; i < n; i++) {
  const what = await ev(`(() => { const c = [...document.querySelector('main').querySelectorAll('input, button, select')][${i}]; if (!c) return null;
    const lab = (c.closest('label')?.textContent || c.getAttribute('aria-label') || c.textContent || c.title || c.name || c.tagName).trim().slice(0, 60);
    const t = c.tagName === 'INPUT' ? c.type : c.tagName.toLowerCase();
    if (t === 'checkbox') { c.click(); c.click(); } else if (t === 'select') { c.dispatchEvent(new Event('change', { bubbles: true })); } else { c.click(); }
    return JSON.stringify({ t, lab }); })()`);
  if (!what) { console.log(`click control ${i} gone`); continue; }
  await sleep(400);
  const dlg = await ev(`(() => { const d = document.querySelector('dialog[open]'); if (d) { d.close(); return true; } return false; })()`);
  const r = await state();
  const w = JSON.parse(what);
  console.log(`click control ${i} ${w.t} ${JSON.stringify(w.lab)} -> ${r.hash.split('?')[0]} dialog=${dlg} errors=${r.errors} sections=${Object.values(r.sections).filter(v => v >= 0).length}`);
  if (r.hash.split('?')[0] !== '#/mssqlmemory') await go(page);
}
ws.close(); process.exit(0);
JS
FISO=$(pq "SELECT to_char(('$R0'::timestamptz - interval '1 second') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
TISO=$(pq "SELECT to_char(('$R2'::timestamptz + interval '1 second') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
out=$(G_USR="$USR" G_UPW="$UPW" node "$TMPD/g.mjs" "$CDP" "$U/" "$SB" "$FISO" "$TISO" "$SHOTS") || fail "G: the Chromium walk stopped: $out"
echo "$out"
echo "$out" | grep -q '^login 200$' || fail "G: the UI login in Chromium"
! echo "$out" | grep -q '^FAIL' || fail "G: a page did not render"
for theme in light dark; do
  line=$(echo "$out" | grep "^page $theme ") || fail "G: no page line ($theme)"
  python3 - "$line" <<'PYEND' || fail "G: the page ($theme): $line"
import json, sys
d = json.loads(sys.argv[1].split(' ', 2)[2]); s = d['sections']
need = ['Memory grant pressure (every read of the range, per pool)', 'Memory grants (the newest read of the range, per pool: a moment, not the range)',
        'Resource semaphore pressure (every read of the range, per semaphore)', 'Resource semaphores (the newest read of the range)',
        'Workload groups and resource pools (the newest read)', 'Caches (the newest read, the 20 largest)', 'Plan cache by type']
ok = all(s.get(k, -1) > 0 for k in need) and s.get('Memory pressure events', -1) >= 0 and s.get('Queries with memory grants (the newest read)', -1) >= 0 \
     and s.get('Plan cache (the newest read)', -1) >= 0 and d['errors'] == 0
sys.exit(0 if ok else 1)
PYEND
done
CL=$(echo "$out" | grep -c '^click ' || true)
(( CL > 0 )) || fail "G: nothing clicked"
! echo "$out" | grep '^click link' | grep -v 'external' | grep -q 'errors=[1-9]\|rendered=false\|same=false' || fail "G: a link landed wrong: $(echo "$out" | grep '^click link' | grep 'errors=[1-9]\|rendered=false\|same=false' | head -3)"
! echo "$out" | grep '^click control' | grep -q 'errors=[1-9]' || fail "G: a control left an error box: $(echo "$out" | grep '^click control' | grep 'errors=[1-9]' | head -3)"
echo "ok   G: the page in light and dark, every D13 section with its rows, no error box; $CL click(s) (links and controls) in the click table above, none landing on an error; shots in $SHOTS"
echo "proof-darling-memory: OK (sp_PressureDetector's semaphores, grant cap, reduced grants, top five clerks, stolen memory, grants, caches and low-memory list equal; PerformanceMonitor's semaphores and plan cache by type equal; the timeouts, forced grants and pressure notifications provoked and read back; the findings; the API and the page; the NOT PROVEN lines above stand)"
