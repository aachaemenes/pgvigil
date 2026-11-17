#!/usr/bin/env bash
# Proof of D421: the plan cache's and the procedures' extremes, sp_QuickieCache's diagnostics, the grant finding and
# dbatools' filter (migration 0342_mssql_cache_spread.sql; internal/mssql/plancache.go planCacheSpread, procstats.go
# procStatsSpread; internal/web/q_mssql_plancache.go part=extremes, q_mssql_procs.go) against a real SQL Server and,
# for what no fresh server can show (an idle plan beside a running one, an interval three hours old, 1,200 matching
# statements, seven days of reads at the collector's cap), on the proof's own repository rows.
#
# Needs: go (ONE binary is built into the temp folder, PGVIGIL_BIN names a built one instead; C2 runs go test rows
# either way), psql, curl, jq, ss, docker, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname and no password in it.
#   PGVIGIL_MSSQL_CONTAINER  an existing SQL Server sandbox container (PGVIGIL_MSSQL_ADDR, MSSQL_SA_PASSWORD). NOT set:
#                            the proof starts its own (MSSQL_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest)
#                            with a throwaway sa password made here, and removes it at the end.
#   PGVIGIL_SKIP_TIMINGS=1   leaves C10 and C11 out (they store about 10 million rows) and says so.
# It makes, and drops on every exit path the shell can catch: its repository database (pgvigil_cs_<n>), on the SQL
# Server one database and one login (random suffix and password), its own container. No server setting is changed;
# C6 empties the server's buffer pool six times (DBCC DROPCLEANBUFFERS): on a shared sandbox every database reads
# from disk again after it.
#
# Expected (written before the first run; the trial readings they rest on are SQL Server 2022 CU27's):
#  C1. The statement columns. Marked statements over cs_big (220,000 rows, about 11,600 pages), each one cached plan,
#      run AFTER a first read; a second read. For each (csrows, cssniff, csgate, csgrant, csreads1-3, cseven, csclr,
#      and cspar, an aggregate asked to prefer a parallel plan: its stored largest used threads is over 0)
#      the newest mssql_pc_extreme row of its query hash in the proof's database holds exactly sa's read of
#      sys.dm_exec_query_stats taken after the collection: min / max worker time, elapsed time, physical reads, rows,
#      spills; max and max used grant, min grant, min / max ideal grant; min DOP; min / max reserved and used threads;
#      plan_generation_num; and execution_count, total_worker_time, total_physical_reads as the counts since compile.
#      csclr (FORMAT() over 50,000 rows, run once before the first read and twice after it): the interval's clr_us
#      equals the rise of sa's total_clr_time between the two reads and is over 0. Every key the read's sample holds
#      has its extreme row, with the sample's executions and CPU.
#  C2. On the proof's repository (go test): the imports are the base's word for word beyond their marked arms; an
#      idle plan's extremes stay out of its key's interval; the CLR time is NULL, never 0, where the read before had
#      none; an older collector's payload stores NULL; the procedures the same; the rules' edges (100 times and not
#      99.9; over 3 executions; under 0.70, over 1.30 and not at them; no CPU leaves the reads' form, over an average
#      of 1,000; over 1 MB under 10 %); extremes names top's keys in top's order under every filter.
#  C3. The procedure cs_p, run once before the first read and twice after it (10 rows, then every row): its
#      mssql_proc_sample row of the second read holds sa's min / max worker, elapsed, logical reads, physical reads,
#      logical writes and spills of sys.dm_exec_procedure_stats.
#  C4. Row count variance: csrows (an INSERT ... SELECT of 1 row, then of 1,000) reads 'Row count variance (1 to 1000)'
#      in the API's extremes part; csgate does not.
#  C5. Parameter sniffing by CPU: cssniff (10 rows twice, every row twice: 4 executions) reads 'Parameter sniffing
#      (CPU '; csgate (10 rows once, every row twice: the same spread at exactly 3 executions) has no 'Parameter
#      sniffing' - the rule's gate. (cseven, four even runs, is printed, not graded: its CPU band is the box's.)
#  C6. Its physical-reads form: csreads1-3, each every row cold, warm, cold, warm (DROPCLEANBUFFERS before a cold
#      run): at least one reads 'Parameter sniffing (physical reads 0-' (the form shows only while the CPU stays
#      inside its band, which a loaded box can break for one of them; all three are printed).
#  C7. The grant finding: csgrant (a sort planned for every row, run for ten rows) holds a grant over 1 MB with under
#      10 % used; mssql_plancache_grant_findings has ONE row for the instance - info, 'wasteful memory grants',
#      'plan cache' - whose detail says 'in the last 3 hours' and names csgrant's hash; the API's findings part
#      carries it. With the proof's rows moved four hours back in the repository the view and the part hold none.
#  C8. The filter. On the live rows: min_executions=4 keeps exactly the keys a hand read of the sample's sums keeps,
#      in top and in extremes. On stored rows (three databases of 400 statements over 500 ms and 100 executions, 300
#      more under 100 executions: 1,500 in all): per_db=100 with dbatools' two floors gives 300 rows, 100 of each database - each
#      database's 100 highest averages - and matched 300; per_db=400 gives the 1,000 cap and matched 1200; no filter
#      gives 1,000 rows without a matched column; extremes names top's keys in top's order each time; a value out
#      of range is refused with 400.
#  P.  The API: /api/mssql/plancache answers with exactly its ten parts as before (no extremes); part=extremes with
#      exactly that one.
#  C10. The finding's cost: five instances with 35 reads of 3,000 statements in the last three hours (525,000 rows,
#      one statement in fifty with a wasteful grant): the view read for every instance at once, five times - each
#      instance's finding counts its 60 statements; the median under 10 s (the page reads' line; expected far
#      under: the partial index holds one row in fifty).
#  C11. The timings at the collector's cap over seven days (2,016 reads of 3,000 statements = 6.05 million rows of
#      mssql_pc_extreme): part=extremes five times, the median under the 10 s line; the procedures' part over 2,016
#      reads of 2,000 procedures with their extremes, three times, the median under the pool's 15 s (a first
#      measurement: the base has no figure for it). mssql_pc_sample has its 18 columns of 0092: the heatmap's and
#      the compare's measured readers read what they read before.
#  NOT PROVEN HERE: SQL Server 2016-2019 (the NULL forms of a column an older server lacks are Go rows), a statement
#  with several cached plans on a real server (C2's stored rows), RDS, Managed Instance, the pages in a browser
#  (their own check), the finding's arm of pgvigil.findings and the purge of mssql_pc_extreme's months (join lines).
set -euo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
for t in psql curl jq ss docker go; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_cs_$SUF
DPC=pvcs_$SUF
L1=pgv_cs_$SUF
N=proof-cs-$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw)
fail() { echo "FAIL: $*" >&2; exit 1; }
# the listening sockets are read once into a variable: 'ss | grep -q' under pipefail would call a taken port free
# whenever grep left before ss had finished writing
freeport() { local l p; l=$(ss -ltn); for p in $(seq "$1" "$2"); do grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " <<<"$l" || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_DB=; MADE_L=; MADE_CT=; SRV_PID=
CT=${PGVIGIL_MSSQL_CONTAINER:-}
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -t 600 -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
sqs() { docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -i /dev/stdin; }
cleanup() {
  rc=$?
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  if [ -n "$MADE_CT" ]; then
    docker rm -f -v "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2
  elif [ -n "$CT" ]; then
    [ -n "$MADE_DB" ] && { sq "IF DB_ID('$DPC') IS NOT NULL BEGIN ALTER DATABASE [$DPC] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DPC]; END" >/dev/null 2>&1 || echo "CLEANUP: database $DPC not dropped" >&2; }
    [ -n "$MADE_L" ] && { sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; }
  fi
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || true
  exit $rc
}
trap cleanup EXIT; trap 'exit 143' TERM; trap 'exit 130' INT

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then BIN=$WORK/pgvigil; (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"; fi

echo "--- the SQL Server"
if [ -n "$CT" ]; then
  ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}; : "${MSSQL_SA_PASSWORD:?the sa password of the sandbox}"
else
  CT=pgv-cs-mssql-$SUF; MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
  MPORT=$(freeport 22433 22499) || fail "no free port for the SQL Server container"; ADDR=127.0.0.1:$MPORT
  MADE_CT=1
  docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run"
fi
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
echo "  $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(80))")"

adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L1" "$P1" | sqs >/dev/null; MADE_L=1
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1]; GRANT CONNECT ANY DATABASE TO [$L1];" >/dev/null
export MS_MON="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
{ echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n' "$N"; } > "$CFG"
MADE_DB=1   # before the batch: a half-made database is still this run's to drop (the drop is guarded)
sq "CREATE DATABASE [$DPC]; ALTER DATABASE [$DPC] SET RECOVERY SIMPLE; ALTER DATABASE [$DPC] SET QUERY_STORE = OFF;" >/dev/null
sq "CREATE TABLE dbo.cs_big (id int IDENTITY PRIMARY KEY, pad char(400) NOT NULL);
    INSERT dbo.cs_big (pad) SELECT TOP (220000) REPLICATE(CHAR(65 + (ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) % 26)), 400) FROM sys.all_columns a CROSS JOIN sys.all_columns b;
    CREATE TABLE dbo.cs_sink (id int NOT NULL);" "$DPC" >/dev/null
sq "CREATE PROCEDURE dbo.cs_p @n int AS BEGIN SET NOCOUNT ON; DECLARE @r bigint; SELECT @r = COUNT_BIG(*) FROM dbo.cs_big WHERE id <= @n AND HASHBYTES('SHA2_256', pad) <> 0x00 OPTION (MAXDOP 1); INSERT dbo.cs_sink SELECT TOP (10) id FROM dbo.cs_big WHERE id <= @n; END" "$DPC" >/dev/null
echo "  cs_big: $(sq "SELECT CAST(SUM(used_page_count) AS varchar(20)) FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('dbo.cs_big')" "$DPC") pages"
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }
win() { echo "from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"; }
objs() { jq -c --arg p "$2" '.[$p] as $t | [$t.rows[] | [$t.columns, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }

# the marked statements: each a parameterized batch, so one cached plan whatever the value
SCAN="SELECT @r = COUNT_BIG(*) FROM dbo.cs_big WHERE id <= @n AND HASHBYTES(''SHA2_256'', pad) <> 0x00 OPTION (MAXDOP 1)"
# runscan <marker> <value>...: the scan once per value; a value 'cold:<n>' empties the buffer pool first
runscan() {
  local m=$1 b="DECLARE @r bigint;" v; shift
  for v in "$@"; do
    case $v in cold:*) b+=" CHECKPOINT; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;"; v=${v#cold:};; esac
    b+=" EXEC sys.sp_executesql N'$SCAN /*$m*/', N'@n int, @r bigint OUTPUT', @n = $v, @r = @r OUTPUT;"
  done
  sq "$b" "$DPC" >/dev/null
}
runclr() { local b="DECLARE @r int;" _; for _ in $(seq 1 "$1"); do b+=" EXEC sys.sp_executesql N'SELECT @r = MAX(LEN(FORMAT(id, N''N0''))) FROM dbo.cs_big WHERE id <= @n /*csclr*/', N'@n int, @r int OUTPUT', @n = 50000, @r = @r OUTPUT;"; done; sq "$b" "$DPC" >/dev/null; }
FIG="qs.min_worker_time, qs.max_worker_time, qs.min_elapsed_time, qs.max_elapsed_time, qs.min_physical_reads, qs.max_physical_reads, qs.min_rows, qs.max_rows, qs.min_spills, qs.max_spills, qs.max_grant_kb, qs.max_used_grant_kb, qs.min_grant_kb, qs.min_ideal_grant_kb, qs.max_ideal_grant_kb, qs.min_dop, qs.min_reserved_threads, qs.max_reserved_threads, qs.min_used_threads, qs.max_used_threads, qs.plan_generation_num, qs.execution_count, qs.total_worker_time, qs.total_physical_reads"
# XS <marker>: sa's read of the marked statement: hash|the 24 figures|total_clr_time (one line per cached statement)
XS() { sq "SELECT CONVERT(varchar(20), qs.query_hash, 1) + '|' + CONCAT_WS('|', $FIG) + '|' + CAST(qs.total_clr_time AS varchar(20)) FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE N'(@n int%/*$1*/%'"; }
# ES <hash>: the newest stored extreme row of the hash in the proof's database, the same 24 figures
ES() { q "select coalesce((select concat_ws('|', min_cpu_us, max_cpu_us, min_duration_us, max_duration_us, min_physical_reads, max_physical_reads, min_rows, max_rows, min_spills, max_spills, max_grant_kb, max_used_grant_kb, min_grant_kb, min_ideal_grant_kb, max_ideal_grant_kb, min_dop, min_reserved_threads, max_reserved_threads, min_used_threads, max_used_threads, plan_generation, life_executions, life_cpu_us, life_physical_reads) from pgvigil.mssql_pc_extreme where instance_id=$iid and database_id=$DBID and query_key='$1' order by snapshot_at desc limit 1), 'none')"; }
PFIG="ps.min_worker_time, ps.max_worker_time, ps.min_elapsed_time, ps.max_elapsed_time, ps.min_logical_reads, ps.max_logical_reads, ps.min_physical_reads, ps.max_physical_reads, ps.min_logical_writes, ps.max_logical_writes, ps.min_spills, ps.max_spills"

echo "--- the first read, then the workload"
runclr 1
sq "EXEC dbo.cs_p 10;" "$DPC" >/dev/null
collect mssql_plancache "$N" >/dev/null; collect mssql_procstats "$N" >/dev/null
iid=$(q "select instance_id from pgvigil.instances where name='$N'")
DBID=$(sq "SELECT DB_ID('$DPC')")
[ "$(q "select count(*) from pgvigil.mssql_pc_extreme where instance_id=$iid")" = 0 ] || fail "the first read stored an extreme row"
CLR0=$(XS csclr); [ "$(wc -l <<<"$CLR0")" = 1 ] || fail "csclr before the workload: $CLR0"
sq "EXEC sys.sp_executesql N'INSERT dbo.cs_sink SELECT id FROM dbo.cs_big WHERE id <= @n /*csrows*/', N'@n int', @n = 1; EXEC sys.sp_executesql N'INSERT dbo.cs_sink SELECT id FROM dbo.cs_big WHERE id <= @n /*csrows*/', N'@n int', @n = 1000;" "$DPC" >/dev/null
runscan cssniff 10 10 220000 220000
runscan csgate 10 220000 220000
runscan cseven 220000 220000 220000 220000
for k in 1 2 3; do runscan "csreads$k" cold:220000 220000 cold:220000 220000; done
sq "CREATE TABLE #s (id int, pad char(400)); DECLARE @i int = 0; WHILE @i < 2 BEGIN EXEC sys.sp_executesql N'INSERT #s SELECT TOP (2000000000) id, pad FROM dbo.cs_big WHERE id <= @n ORDER BY pad, id OPTION (OPTIMIZE FOR (@n = 220000), MAXDOP 1) /*csgrant*/', N'@n int', @n = 10; SET @i += 1; END" "$DPC" >/dev/null
runclr 2
sq "DECLARE @r bigint, @i int = 0; WHILE @i < 2 BEGIN EXEC sys.sp_executesql N'SELECT @r = COUNT_BIG(DISTINCT HASHBYTES(''SHA2_256'', pad)) FROM dbo.cs_big WHERE id <= @n OPTION (USE HINT(''ENABLE_PARALLEL_PLAN_PREFERENCE'')) /*cspar*/', N'@n int, @r bigint OUTPUT', @n = 220000, @r = @r OUTPUT; SET @i += 1; END" "$DPC" >/dev/null
sq "EXEC dbo.cs_p 10; EXEC dbo.cs_p 220000;" "$DPC" >/dev/null
sleep 1
collect mssql_plancache "$N"; collect mssql_procstats "$N"

echo "--- C1. the statement columns against sa's read"
declare -A HASHOF
for m in csrows cssniff csgate csgrant csreads1 csreads2 csreads3 cseven csclr cspar; do
  X=$(XS "$m"); [ "$(wc -l <<<"$X")" = 1 ] && [ -n "$X" ] || fail "C1: sa reads $(grep -c . <<<"$X") cached statements for $m, want 1"
  H=${X%%|*}; WANT=${X#*|}; WANT=${WANT%|*}; HASHOF[$m]=$H
  GOT=$(ES "$H")
  echo "  $m $H: $GOT"
  [ "$GOT" = "$WANT" ] || fail "C1: $m stored $GOT, sa reads $WANT"
done
CLR1=$(XS csclr)
WCLR=$(( ${CLR1##*|} - ${CLR0##*|} ))
GCLR=$(q "select coalesce((select clr_us::text from pgvigil.mssql_pc_extreme where instance_id=$iid and database_id=$DBID and query_key='${HASHOF[csclr]}' order by snapshot_at desc limit 1), 'none')")
echo "  csclr's interval: CLR time stored $GCLR us, the rise of sa's total_clr_time $WCLR us"
[ "$GCLR" = "$WCLR" ] && [ "$WCLR" -gt 0 ] || fail "C1: csclr's CLR time stored $GCLR, sa's rise $WCLR (over 0 wanted)"
PAR=$(q "select max_used_threads from pgvigil.mssql_pc_extreme where instance_id=$iid and database_id=$DBID and query_key='${HASHOF[cspar]}' order by snapshot_at desc limit 1")
echo "  cspar's largest used threads: $PAR"
[ "${PAR:-0}" -gt 0 ] || fail "C1: cspar ran with no parallel thread (max_used_threads $PAR): the Parallelism columns are not shown to hold a value"
[ "$(q "select count(*) from pgvigil.mssql_pc_sample m where m.instance_id=$iid and not exists (select 1 from pgvigil.mssql_pc_extreme e where e.instance_id=m.instance_id and e.snapshot_at=m.snapshot_at and e.database_id=m.database_id and e.query_key=m.query_key and e.executions=m.executions and e.cpu_us=m.cpu_us)")" = 0 ] || fail "C1: a sample row has no extreme row of its key, executions and CPU"
[ "$(q "select (select count(*) from pgvigil.mssql_pc_sample where instance_id=$iid) = (select count(*) from pgvigil.mssql_pc_extreme where instance_id=$iid)")" = t ] || fail "C1: the sample and the extremes differ in rows"
echo "C1: OK"

echo "--- C3. the procedure's extremes against sa's read"
PW=$(sq "SELECT CONCAT_WS('|', $PFIG) FROM sys.dm_exec_procedure_stats ps WHERE ps.database_id = DB_ID('$DPC') AND ps.object_id = OBJECT_ID('$DPC.dbo.cs_p')")
PG=$(q "select coalesce((select concat_ws('|', min_cpu_us, max_cpu_us, min_duration_us, max_duration_us, min_logical_reads, max_logical_reads, min_physical_reads, max_physical_reads, min_logical_writes, max_logical_writes, min_spills, max_spills) from pgvigil.mssql_proc_sample where instance_id=$iid and database_id=$DBID and object_name='cs_p' order by snapshot_at desc limit 1), 'none')")
echo "  cs_p: stored $PG"
[ "$PG" = "$PW" ] && [ -n "$PW" ] || fail "C3: cs_p stored $PG, sa reads $PW"
[ "$(q "select executions from pgvigil.mssql_proc_sample where instance_id=$iid and database_id=$DBID and object_name='cs_p' order by snapshot_at desc limit 1")" = 2 ] || fail "C3: cs_p's interval is not its 2 executions"
echo "C3: OK"

PORT=$(freeport 18340 18380) || fail "no free port for the UI"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "$U/mssql/plancache?instance=$iid&$(win)&db=$DBID" > "$WORK/pc.json" || fail "P: /api/mssql/plancache"
curl -fs "$U/mssql/plancache?instance=$iid&$(win)&db=$DBID&part=extremes" > "$WORK/ext.json" || fail "P: part=extremes"
PARTS=$(jq -r 'keys | sort | join(",")' "$WORK/pc.json")
[ "$PARTS" = "databases,duplicates,findings,health,reads,series,singles,state,top,totals" ] || fail "P: the page's parts are $PARTS"
[ "$(jq -r 'keys | join(",")' "$WORK/ext.json")" = "extremes" ] || fail "P: part=extremes answered $(jq -r 'keys | join(",")' "$WORK/ext.json")"
echo "P: OK"
# diag <marker>: the statement's diagnostics in the extremes part ('' for none)
diag() { objs "$WORK/ext.json" extremes | jq -r --arg h "${HASHOF[$1]}" '[.[] | select(.query_key == $h)] | if length == 1 then (.[0].diagnostics // "") else "ROWS:\(length)" end'; }

echo "--- C4. row count variance"
echo "  csrows: $(diag csrows)"
[ "$(diag csrows)" = "Row count variance (1 to 1000)" ] || fail "C4: csrows reads '$(diag csrows)'"
grep -q 'Row count variance' <<<"$(diag csgate)" && fail "C4: csgate reads '$(diag csgate)'"
echo "C4: OK"

echo "--- C5. parameter sniffing by CPU, and the gate"
echo "  cssniff: $(diag cssniff)"; echo "  csgate (3 executions): '$(diag csgate)'"; echo "  cseven (not graded): '$(diag cseven)'"
grep -q '^Parameter sniffing (CPU ' <<<"$(diag cssniff)" || fail "C5: cssniff reads '$(diag cssniff)'"
[ "$(q "select life_executions from pgvigil.mssql_pc_extreme where instance_id=$iid and query_key='${HASHOF[csgate]}' order by snapshot_at desc limit 1")" = 3 ] || fail "C5: csgate did not run exactly 3 times"
grep -q 'Parameter sniffing' <<<"$(diag csgate)" && fail "C5: csgate reads '$(diag csgate)' at 3 executions"
echo "C5: OK"

echo "--- C6. parameter sniffing by physical reads"
hit=0
for k in 1 2 3; do d=$(diag "csreads$k"); echo "  csreads$k: $d"; grep -q '^Parameter sniffing (physical reads 0-' <<<"$d" && hit=$((hit + 1)); done
[ "$hit" -ge 1 ] || fail "C6: none of the three cold / warm statements reads the physical-reads form"
echo "C6: OK ($hit of 3)"

echo "--- C7. the grant finding"
GH=${HASHOF[csgrant]}
echo "  csgrant: $(diag csgrant)"
grep -q 'Wasteful grant (' <<<"$(diag csgrant)" || fail "C7: csgrant's diagnostics read '$(diag csgrant)'"
F=$(q "select severity || '|' || check_name || '|' || object || '|' || detail from pgvigil.mssql_plancache_grant_findings where instance_id=$iid")
echo "  $F" | cut -c1-330
[ "$(grep -c . <<<"$F")" = 1 ] || fail "C7: the view holds $(grep -c . <<<"$F") rows for the instance, want 1"
grep -q '^info|wasteful memory grants|plan cache|' <<<"$F" && grep -q 'in the last 3 hours' <<<"$F" && grep -qF "$GH" <<<"$F" || fail "C7: the finding's words: $F"
[ "$(objs "$WORK/pc.json" findings | jq '[.[] | select(.check_name == "wasteful memory grants")] | length')" = 1 ] || fail "C7: the API's findings part lacks the finding"

echo "--- C8. the filter on the live rows"
HAND=$(q "select coalesce(string_agg(query_key, ',' order by cpu desc, query_key), '') from (select query_key, sum(cpu_us) cpu from pgvigil.mssql_pc_sample where instance_id=$iid and database_id=$DBID group by database_id, query_key having sum(executions) >= 4) x")
curl -fs "$U/mssql/plancache?instance=$iid&$(win)&db=$DBID&min_executions=4" > "$WORK/f.json" || fail "C8: the filtered read"
curl -fs "$U/mssql/plancache?instance=$iid&$(win)&db=$DBID&min_executions=4&part=extremes" > "$WORK/fx.json" || fail "C8: the filtered extremes"
[ "$(objs "$WORK/f.json" top | jq -r '[.[].query_key] | join(",")')" = "$HAND" ] && [ -n "$HAND" ] || fail "C8: min_executions=4 gives $(objs "$WORK/f.json" top | jq -r '[.[].query_key] | join(",")'), a hand read $HAND"
[ "$(objs "$WORK/fx.json" extremes | jq -r '[.[].query_key] | join(",")')" = "$HAND" ] || fail "C8: the filtered extremes name other keys than top"
echo "  min_executions=4 keeps $(tr ',' '\n' <<<"$HAND" | grep -c .) of $(objs "$WORK/pc.json" top | jq length) statements, as the hand read"
for bad in "min_avg_cpu_ms=-1" "min_executions=0" "per_db=1001" "per_db=x"; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/plancache?instance=$iid&$bad")" = 400 ] || fail "C8: $bad was not refused with 400"
done

echo "--- C7 again: the proof's rows moved four hours back"
q "select pgvigil.ensure_month_partition('mssql_pc_extreme', now() - interval '4 hours')" >/dev/null
q "update pgvigil.mssql_pc_extreme set snapshot_at = snapshot_at - interval '4 hours' where instance_id=$iid" >/dev/null
[ "$(q "select count(*) from pgvigil.mssql_plancache_grant_findings where instance_id=$iid")" = 0 ] || fail "C7: an interval four hours old still raises the finding"
[ "$(curl -fs "$U/mssql/plancache?instance=$iid&part=findings" | jq '[.findings.rows[]] | length')" = 0 ] || fail "C7: the API's findings part still holds a finding"
echo "C7: OK"

echo "--- C2. the repository rows (go test)"
(cd "$ROOT" && PGVIGIL_REPO_TEST_DSN="$PGVIGIL_ADMIN_DSN dbname=postgres" go test -count=1 -run 'TestImports0342AreTheBasePlusTheD421Arms|TestPlanCacheExtremesOnAStore|TestProcExtremesOnAStore|TestGrantFindingOnAStore' ./internal/repo > "$WORK/t1" 2>&1) || { tail -20 "$WORK/t1" >&2; fail "C2: the repo rows"; }
(cd "$ROOT" && PGVIGIL_REPO_TEST_DSN="$PGVIGIL_REPO_DSN" go test -count=1 -v -run 'TestPCFilterOf|TestPCFilteredStatements|TestPCDiagnosticsOnAStore|TestPlanCacheSpreadPartsOnAStore' ./internal/web > "$WORK/t2" 2>&1) || { grep -E '^(---|FAIL|ok)|_test.go' "$WORK/t2" | head -20 >&2; fail "C2: the web rows"; }
[ "$(grep -c '^--- PASS' "$WORK/t2")" = 4 ] && ! grep -q '^--- SKIP' "$WORK/t2" || fail "C2: the web rows did not all run: $(grep -E '^--- ' "$WORK/t2" | tr '\n' ' ')"
echo "C2: OK ($(tail -1 "$WORK/t1"); 4 web rows)"

echo "--- C8. the filter at the cap, on stored rows"
cap=$(q "select pgvigil.ensure_instance('proof-cs-cap-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 <<SQL
select pgvigil.ensure_month_partition(t, now() - interval '10 minutes') from unnest(array['mssql_pc_sample', 'mssql_pc_extreme', 'mssql_pc_read']) t;
create temp table cs_cap as
select d as database_id, format('D%s-K%s', d, lpad(k::text, 4, '0')) as query_key, case when k <= 400 then 100 + k else 50 end::bigint as executions,
       (600000 + k * 1000)::bigint * (case when k <= 400 then 100 + k else 50 end) as cpu_us
  from generate_series(11, 13) d, generate_series(1, 700) k where k <= 400 or d = 11;
insert into pgvigil.mssql_pc_sample (instance_id, snapshot_at, database_id, query_key, database_name, executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, row_count, spills, plans, interval_secs)
select $cap, date_trunc('minute', now()) - interval '10 minutes', database_id, query_key, 'db' || database_id, executions, cpu_us, cpu_us, 1, 0, 0, 1, 0, 1, 300 from cs_cap;
insert into pgvigil.mssql_pc_extreme (instance_id, snapshot_at, database_id, query_key, executions, cpu_us, interval_secs, life_executions, life_cpu_us, life_physical_reads)
select $cap, date_trunc('minute', now()) - interval '10 minutes', database_id, query_key, executions, cpu_us, 300, executions, cpu_us, 0 from cs_cap;
insert into pgvigil.mssql_pc_read (instance_id, snapshot_at, interval_secs, statements, capped) select $cap, date_trunc('minute', now()) - interval '10 minutes', 300, count(*), false from cs_cap;
SQL
capread() { curl -fs "$U/mssql/plancache?instance=$cap&$(win)&part=top$1" > "$WORK/ct.json" && curl -fs "$U/mssql/plancache?instance=$cap&$(win)&part=extremes$1" > "$WORK/cx.json" || fail "C8: the read at the cap ($1)"
  [ "$(objs "$WORK/ct.json" top | jq -c '[.[].query_key]')" = "$(objs "$WORK/cx.json" extremes | jq -c '[.[].query_key]')" ] || fail "C8: extremes names other keys than top ($1)"; }
capread "&min_avg_cpu_ms=500&min_executions=100&per_db=100"
S=$(objs "$WORK/ct.json" top | jq -r '"\(length)|\([.[] | select(.matched != 300)] | length)|\([.[].database_id] | group_by(.) | map(length) | join(","))|\([.[].query_key | .[5:] | tonumber] | min)"')
echo "  500 ms, 100 executions, 100 of each database: rows|rows whose matched is not 300|rows per database|the lowest statement number kept: $S"
[ "$S" = "300|0|100,100,100|301" ] || fail "C8: per_db=100 gives $S, want 300|0|100,100,100|301"
capread "&min_avg_cpu_ms=500&min_executions=100&per_db=400"
S=$(objs "$WORK/ct.json" top | jq -r '"\(length)|\(.[0].matched)|\([.[].database_id] | group_by(.) | map(length) | join(","))"')
echo "  the same, 400 of each database: rows|matched|rows per database: $S"
[ "${S%|*}" = "1000|1200" ] || fail "C8: per_db=400 gives $S, want 1000|1200|..."
capread ""
[ "$(objs "$WORK/ct.json" top | jq -r '"\(length)|\(.[0] | has("matched"))"')" = "1000|false" ] || fail "C8: no filter gives $(objs "$WORK/ct.json" top | jq -r '"\(length)|\(.[0] | has("matched"))"'), want 1000|false"
echo "C8: OK"

if [ -n "${PGVIGIL_SKIP_TIMINGS:-}" ]; then echo "C10, C11: NOT RUN (PGVIGIL_SKIP_TIMINGS)"; echo "PROOF OK (without C10 and C11)"; exit 0; fi
median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }

echo "--- C10. the finding's cost over five instances' last three hours"
psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 <<SQL
select pgvigil.ensure_month_partition('mssql_pc_extreme', now() - interval '3 hours');
insert into pgvigil.mssql_pc_extreme (instance_id, snapshot_at, database_id, query_key, executions, cpu_us, interval_secs, max_grant_kb, max_used_grant_kb, life_executions, life_cpu_us, life_physical_reads)
select i.id, date_trunc('minute', now()) - r * interval '5 minutes', 5 + k % 4, 'F' || k, 10, 1000 * k, 300,
       case when k % 50 = 0 then 200000 + k else 512 end, case when k % 50 = 0 then 100 else 400 end, 10 * r, 1000 * k, 0
  from (select pgvigil.ensure_instance('proof-cs-cost-$SUF-' || n, 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') as id from generate_series(1, 5) n) i,
       generate_series(1, 35) r, generate_series(1, 3000) k;
analyze pgvigil.mssql_pc_extreme;
SQL
COSTROWS=$(q "select count(*) from pgvigil.mssql_pc_extreme e join pgvigil.instances i using (instance_id) where i.name like 'proof-cs-cost-$SUF-%'")
for _ in 1 2 3 4 5; do t0=$(date +%s%N); FN=$(q "select count(*) || '|' || coalesce(min(detail), '') from pgvigil.mssql_plancache_grant_findings f join pgvigil.instances i using (instance_id) where i.name like 'proof-cs-cost-$SUF-%'"); echo $(( ($(date +%s%N) - t0) / 1000000 )); done > "$WORK/cost"
q "explain select * from pgvigil.mssql_plancache_grant_findings" | grep -iE 'index|seq scan' | head -4 | sed 's/^/  plan: /'
echo "  $COSTROWS rows; the view for every instance, ms: $(tr '\n' ' ' < "$WORK/cost")median $(median < "$WORK/cost"); findings ${FN%%|*}; one reads: $(cut -d'|' -f2 <<<"$FN" | cut -c1-110)..."
[ "${FN%%|*}" = 5 ] && grep -q '^60 cached statement(s) that ran in the last 3 hours' <<<"${FN#*|}" || fail "C10: the seeded instances' findings: $FN"
[ "$(median < "$WORK/cost")" -lt 10000 ] || fail "C10: the median is $(median < "$WORK/cost") ms"
echo "C10: OK"

echo "--- C11. the timings at the cap over seven days"
SAMPLECOLS=$(q "select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema='pgvigil' and table_name='mssql_pc_sample'")
[ "$SAMPLECOLS" = "instance_id,snapshot_at,database_id,query_key,database_name,executions,cpu_us,duration_us,logical_reads,physical_reads,logical_writes,row_count,spills,max_grant_kb,max_used_grant_kb,max_dop,plans,interval_secs" ] || fail "C11: mssql_pc_sample's columns are $SAMPLECOLS"
big=$(q "select pgvigil.ensure_instance('proof-cs-big-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
t0=$(date +%s)
psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 <<SQL
select pgvigil.ensure_month_partition(t, a) from unnest(array['mssql_pc_extreme', 'mssql_pc_read', 'mssql_proc_sample', 'mssql_proc_read']) t, unnest(array[now(), now() - interval '7 days']) a;
insert into pgvigil.mssql_pc_extreme (instance_id, snapshot_at, database_id, query_key, executions, cpu_us, interval_secs,
    min_cpu_us, max_cpu_us, min_duration_us, max_duration_us, min_physical_reads, max_physical_reads, min_rows, max_rows, min_spills, max_spills,
    max_grant_kb, max_used_grant_kb, min_grant_kb, min_ideal_grant_kb, max_ideal_grant_kb, min_dop, min_reserved_threads, max_reserved_threads,
    min_used_threads, max_used_threads, plan_generation, clr_us, life_executions, life_cpu_us, life_physical_reads)
select $big, date_trunc('minute', now()) - r * interval '5 minutes', 5 + k % 8, '0x' || lpad(to_hex(k::bigint * 2654435761), 16, '0'), 1 + (k + r) % 50, 1000 * (1 + (k * 7 + r) % 5000), 300,
       10 + k % 90, 1000 + (k * r) % 90000, 12 + k % 90, 1200 + (k * r) % 90000, 0, (k + r) % 500, 1, 1 + (k * r) % 2000, 0, k % 3,
       512 + k % 512, 100 + k % 400, 512, 600, 9000, 1, 0, k % 8, 0, k % 8, 1 + r % 4, k % 100, 100 * r + k, 100000 * r + k, r
  from generate_series(1, 2016) r, generate_series(1, 3000) k;
insert into pgvigil.mssql_pc_read (instance_id, snapshot_at, interval_secs, statements, capped)
select $big, date_trunc('minute', now()) - r * interval '5 minutes', 300, 3000, true from generate_series(1, 2016) r;
insert into pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc, executions, cpu_us, duration_us,
    logical_reads, physical_reads, logical_writes, interval_secs, spills, min_cpu_us, max_cpu_us, min_duration_us, max_duration_us, min_logical_reads, max_logical_reads,
    min_physical_reads, max_physical_reads, min_logical_writes, max_logical_writes, min_spills, max_spills)
select $big, date_trunc('minute', now()) - r * interval '5 minutes', 5 + k % 8, 1000 + k, 'db' || (5 + k % 8), 'dbo', 'p' || k, 'SQL_STORED_PROCEDURE', 1 + (k + r) % 50,
       1000 * (1 + (k * 7 + r) % 5000), 1200 * (1 + (k * 7 + r) % 5000), 100 + k, k % 50, k % 7, 300, k % 3, 10 + k % 90, 1000 + (k * r) % 90000, 12 + k % 90,
       1200 + (k * r) % 90000, 1, 100 + k, 0, k % 50, 0, k % 7, 0, k % 3
  from generate_series(1, 2016) r, generate_series(1, 2000) k;
insert into pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs)
select $big, date_trunc('minute', now()) - r * interval '5 minutes', 300, 2000 from generate_series(1, 2016) r;
analyze pgvigil.mssql_pc_extreme; analyze pgvigil.mssql_proc_sample;
SQL
echo "  stored in $(( $(date +%s) - t0 )) s: $(q "select (select count(*) from pgvigil.mssql_pc_extreme where instance_id=$big) || ' extreme rows, ' || (select count(*) from pgvigil.mssql_proc_sample where instance_id=$big) || ' procedure rows'")"
W7="from=$(date -u -d '-7 days -1 hour' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"
timed() { local n=$1 url=$2 i c; for i in $(seq 1 "$n"); do c=$(curl -s -o "$WORK/tm.json" -w '%{http_code} %{time_total}' "$url"); [ "${c%% *}" = 200 ] || { head -c 300 "$WORK/tm.json" >&2; fail "C11: $url answered ${c%% *}"; }; echo "${c##* }"; done; }
timed 5 "$U/mssql/plancache?instance=$big&$W7&part=extremes" > "$WORK/tx"
[ "$(jq '.extremes.rows | length' "$WORK/tm.json")" = 1000 ] || fail "C11: the extremes part gave $(jq '.extremes.rows | length' "$WORK/tm.json") rows"
echo "  part=extremes over 7 days, s: $(tr '\n' ' ' < "$WORK/tx")median $(median < "$WORK/tx")"
timed 3 "$U/mssql/procs?instance=$big&$W7&part=procs" > "$WORK/tp"
echo "  the procedures' part over 7 days (2,000 rows of 2,000 procedures), s: $(tr '\n' ' ' < "$WORK/tp")median $(median < "$WORK/tp")"
awk -v m="$(median < "$WORK/tx")" 'BEGIN { exit !(m < 10) }' || fail "C11: part=extremes' median is $(median < "$WORK/tx") s, the line is 10 s"
awk -v m="$(median < "$WORK/tp")" 'BEGIN { exit !(m < 15) }' || fail "C11: the procedures' part's median is $(median < "$WORK/tp") s, the pool's timeout is 15 s"
echo "C11: OK"
echo "PROOF OK"
