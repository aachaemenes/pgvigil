#!/usr/bin/env bash
# Proof of the SQL Server CPU, memory, file IO and tempdb collections (migration 0074, internal/mssql/cpu.go,
# memory.go, fileio.go, tempdb.go) and their pages' API (internal/web/q_mssql_perf.go, the SQL Server parts of
# q_performance.go and q_perfsummary.go), against the SQL Server sandbox PAIR (real DMVs) and the demo.
#
# Needs: docker with the two SQL Server containers (PGVIGIL_MSSQL_CONTAINERS, default "mssql-sandbox mssql-sandbox2";
# the parts run on every server named, one too, as scripts/proof-mssql-2016.sh names one)
# reachable from this machine on PGVIGIL_MSSQL_ADDRS (default "localhost:1433 localhost:1434"), one sa password for
# both in MSSQL_SA_PASSWORD, psql, curl, jq, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# The proof makes its own repository databases (one for the servers, one for the demo), on each server two logins
# (random suffix, random passwords; three) and on the first server one database it writes about 24 MB into, and drops them
# at the end, on every exit path. It changes no server setting and nothing of tempdb.
#
# Expected (written before the first run), on EACH server of the pair:
#  A. as a login with VIEW SERVER STATE and VIEW ANY DEFINITION (the monitoring login): two runs of `collect -once mssql_cpu` with 300 batches sent between
#     them store every scheduler monitor record sa reads in the ring buffer, once (the second run adds only the
#     records written since the first: no record id is stored twice), the newest record's SQL Server per cent equals
#     sa's, and its idle per cent equals sa's on Windows and is NULL on a Linux host (corrected after the third run:
#     SQL Server on Linux writes SystemIdle 0 in every record, which read as a machine at 100 %; the collector now
#     drops it there and both sandboxes are Linux); mssql_sched_sample's schedulers and max workers equal sa's VISIBLE ONLINE count and
#     max_workers_count; the first row has no rates, the second has batch requests/s x its interval at least 300
#     and at most sa's own rise of Batch Requests/sec over the same span, and transactions/s not NULL.
#  B. `collect -once mssql_memory` as that login: physical memory equals sa's total_physical_memory_kb, Target
#     Server Memory equals sa's counter, the memory model equals sa's; at least 10 clerk rows, the 25 largest by
#     type in sa's order (the first is sa's largest), and the stored clerks plus '(other)' add up to the total; the
#     plan cache is the four cache stores' sum within 5 % of sa's read.
#  C. `collect -once mssql_fileio` twice with the proof database written between (24 MB of rows, a CHECKPOINT): the
#     second read stores a difference for the proof database's data file with at least 16 MB written and a log
#     difference with writes above zero; every stored file carries its name and type; the run is ok; the newest
#     counters are at or below sa's read taken after it (they only grow). A login with VIEW SERVER STATE alone: the
#     run is partial naming sys.master_files, the files are stored with their database names and NULL types.
#     (Corrected after the first run: the first text expected names and types without VIEW ANY DEFINITION, which
#     the collector's own rule says sys.master_files does not give.)
#  D. `collect -once mssql_tempdb`: data and log file counts, sizes and growth equal sa's read of
#     tempdb.sys.database_files; the CPU count equals sa's cpu_count; recommended = least(cpu_count, 8);
#     insufficient_files = data files < recommended; even_size and even_growth as sa's rows say; trace flags 1117 and
#     1118 as sa's DBCC TRACESTATUS says (off); flags_required false (SQL Server 2022); memopt_metadata as
#     SERVERPROPERTY says.
#  E. a login without VIEW SERVER STATE: mssql_cpu, mssql_memory and mssql_fileio are skipped naming the missing
#     right; mssql_tempdb is partial naming sys.dm_os_sys_info and stores the files with cpu_count NULL and
#     insufficient_files NULL (the check does not weigh what it cannot read).
# Then, without a server:
#  F. the findings' thresholds on imported rows of a second instance: tempdb with 4 data files on 16 CPUs (warning
#     'fewer data files than recommended'); files of 8 and 4 GB (warning 'differ in size'); a 10 % growth (info);
#     before 2016 with flag 1118 off (warning); none of these for 8 even files on 16 CPUs. CPU: twelve records at
#     96 % total (critical) and twelve at 50 % (nothing); ten reads with 2 runnable tasks per scheduler (warning
#     'scheduler pressure'); memory 'Available physical memory is low' (warning); grants waiting in 3 of 10 reads
#     (warning) and in 2 (nothing); ten reads with no runnable task and a work queue in five (warning 'scheduler
#     pressure', the worker arm); a data file at 60 ms over 2,000 reads (warning), at 120 ms (critical), at 60 ms
#     over 500 reads (nothing); a log at 25 ms over 2,000 writes (warning); a file of no known type (no VIEW ANY
#     DEFINITION) at 60 ms over 2,000 reads (nothing).
#  G. the four import functions refuse a PostgreSQL instance.
#  X. retries and out of order: a cpu payload imported twice at one time leaves one schedulers row and no doubled
#     record; a fileio payload older than the stored read stores nothing; a fileio read after a restart (start time
#     moved, counters lower) stores no difference and the next read does; a cpu read after a restart stores no rate
#     although its counter is higher (the start time alone stops it); a counter missing from one read gets its rate
#     over its own two-read interval (1,200 over 120 s = 10/s, not 20); every fileio read that took differences keeps
#     its seconds in mssql_fileio_read, an idle read too. (Added with the review's fold.)
#  P. the API on the servers' repository: /api/mssql/cpu, /memory, /fileio answer for the first server with rows in
#     cpu, latest, series, clerks, files; /api/mssql/tempdb lists both servers (every server the run names); /api/performance for the first
#     server has the parts cpu, db and io with rows; /api/perfsummary's mssql rows carry cpu_avg and mem_total_pct
#     for both servers (every server the run names), and read or write latency for the first (corrected after the third run: the second server
#     had no file IO between the proof's two reads, and no IO gives no latency).
#  DEMO. a two-day demo: DEMO-SQL01's Performance page has cpu, db and io rows on at least 100 steps, its CPU /
#     Memory / File IO pages hold rows, the fleet TempDB grid has three rows; the findings name sql01's tempdb (4
#     files on 16 CPUs) and sql03's uneven files, and none for sql02's tempdb; /api/perfsummary gives every SQL
#     Server instance a cpu_avg, a read_ms and a ple_min.
#  NOT PROVEN HERE: SQL Server 2016-2019 (both sandboxes are 2022), Windows (a drive letter as the tempdb volume),
#     Managed Instance and RDS, a login holding only VIEW SERVER PERFORMANCE STATE (the 2022 path of perfState), a
#     memory grant waiting on a real server, a ring buffer record id restarting after a real restart.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox pair}"
read -r -a CTS <<<"${PGVIGIL_MSSQL_CONTAINERS:-mssql-sandbox mssql-sandbox2}"
read -r -a ADDRS <<<"${PGVIGIL_MSSQL_ADDRS:-localhost:1433 localhost:1434}"
for t in psql curl jq docker; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_mssqlperf_$SUF; DEMO_DB=pgvigil_mssqlperfdemo_$SUF
L1=pgv_perf_$SUF; L2=pgv_perfbare_$SUF; L3=pgv_perfvss_$SUF; DB=pgvproof_perf_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw); P3=$(pw)
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
fail() { echo "FAIL: $*" >&2; exit 1; }
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MADE_REPO=; MADE_DEMO=; MADE_DB=; MADE_L=(); SRV_PID=; DEMO_PID=
# sq <container> <sql> [database]: as sa, the password through the environment by name
sq() { docker exec -e SQLCMDPASSWORD "$1" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${3:-master}" -Q "SET NOCOUNT ON; $2"; }
# sqs <container>: as sa, the batch on stdin (a login's password never rides a command line)
sqs() { docker exec -i -e SQLCMDPASSWORD "$1" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -i /dev/stdin; }
cleanup() {
  rc=$?
  for p in "$SRV_PID" "$DEMO_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  if [ -n "$MADE_DB" ]; then sq "${CTS[0]}" "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null 2>&1 || echo "CLEANUP: database $DB not dropped" >&2; fi
  for m in "${MADE_L[@]:-}"; do
    [ -n "$m" ] || continue
    sq "${m%%:*}" "IF SUSER_ID('${m#*:}') IS NOT NULL DROP LOGIN [${m#*:}];" >/dev/null 2>&1 || echo "CLEANUP: login ${m#*:} on ${m%%:*} not dropped" >&2
  done
  for d in "$REPO_DB:$MADE_REPO" "$DEMO_DB:$MADE_DEMO"; do
    [ -n "${d#*:}" ] && { psql "$ADMIN_DSN" -XAtq -c "drop database if exists ${d%%:*} with (force)" >/dev/null 2>&1 || echo "CLEANUP: database ${d%%:*} not dropped" >&2; }
  done
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

# the logins on both servers, the proof database on the first
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  for i in "${!CTS[@]}"; do
    ct=${CTS[$i]}; addr=${ADDRS[$i]}
    printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L1" "$P1" | sqs "$ct" >/dev/null; MADE_L+=("$ct:$L1")
    sq "$ct" "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];" >/dev/null
    printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L3" "$P3" | sqs "$ct" >/dev/null; MADE_L+=("$ct:$L3")
    sq "$ct" "GRANT VIEW SERVER STATE TO [$L3];" >/dev/null
    printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$L2" "$P2" | sqs "$ct" >/dev/null; MADE_L+=("$ct:$L2")
    export "MS_MON_$i=sqlserver://$L1:$P1@$addr?database=master&encrypt=true&TrustServerCertificate=true"
    export "MS_BARE_$i=sqlserver://$L2:$P2@$addr?database=master&encrypt=true&TrustServerCertificate=true"
    export "MS_VSS_$i=sqlserver://$L3:$P3@$addr?database=master&encrypt=true&TrustServerCertificate=true"
    printf '  - name: proof-perf-%s-%s\n    engine: sqlserver\n    dsn: env:MS_MON_%s\n' "$i" "$SUF" "$i"
    printf '  - name: proof-perfbare-%s-%s\n    engine: sqlserver\n    dsn: env:MS_BARE_%s\n' "$i" "$SUF" "$i"
    printf '  - name: proof-perfvss-%s-%s\n    engine: sqlserver\n    dsn: env:MS_VSS_%s\n' "$i" "$SUF" "$i"
  done
} > "$CFG"
sq "${CTS[0]}" "CREATE DATABASE [$DB]; ALTER DATABASE [$DB] SET RECOVERY SIMPLE;" >/dev/null; MADE_DB=1
sq "${CTS[0]}" "CREATE TABLE dbo.pv_rows (id int IDENTITY PRIMARY KEY, pad char(4000) NOT NULL);" "$DB" >/dev/null
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }

for i in "${!CTS[@]}"; do
  ct=${CTS[$i]}; N=proof-perf-$i-$SUF; NB=proof-perfbare-$i-$SUF
  echo "=== server $ct (${ADDRS[$i]})"
  echo "--- A. mssql_cpu as the monitoring login"
  ring() { sq "$ct" "SELECT COUNT(*) FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%'"; }
  batches() { sq "$ct" "SELECT cntr_value FROM sys.dm_os_performance_counters WHERE RTRIM(object_name) LIKE N'%:SQL Statistics' AND counter_name = N'Batch Requests/sec'"; }
  # the scheduler monitor writes its first record about a minute after the server starts: on a pair this proof is the
  # first to use (the versions run with only 'perf', setup 21 s), part A read an empty ring buffer and stored 0 records
  RW=0; for _ in $(seq 1 90); do RW=$(ring); [ "${RW:-0}" -ge 1 ] && break; sleep 1; done
  [ "${RW:-0}" -ge 1 ] || fail "A: the server's ring buffer holds no scheduler monitor record after 90 s (sa reads $RW)"
  B0=$(batches)
  collect mssql_cpu "$N" >/dev/null
  iid=$(q "select instance_id from pgvigil.instances where name='$N'")
  R1=$(q "select count(*) from pgvigil.mssql_cpu_sample where instance_id=$iid")
  [ "$R1" -ge 1 ] && [ "$R1" -le 256 ] || fail "A: $R1 ring buffer records stored"
  # 300 batches through one connection (GO 300 sends the batch 300 times)
  docker exec -e SQLCMDPASSWORD "$ct" bash -c "printf 'SELECT 1;\nGO 300\n' | /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -U sa -h -1 >/dev/null"
  sleep 2
  collect mssql_cpu "$N" >/dev/null
  B1=$(batches)
  SAR=$(ring)
  [ "$(q "select count(*) || '|' || count(distinct record_id) from pgvigil.mssql_cpu_sample where instance_id=$iid")" = "$SAR|$SAR" ] \
    || fail "A: the stored records $(q "select count(*) || '|' || count(distinct record_id) from pgvigil.mssql_cpu_sample where instance_id=$iid") (count|distinct ids), sa reads $SAR in the ring buffer"
  NEWEST=$(sq "$ct" "SELECT TOP 1 CAST(x.r.value('(./Record/@id)[1]','bigint') AS varchar(20)) + '|' + CAST(x.r.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int') AS varchar(5)) + '|' + CAST(x.r.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int') AS varchar(5)) FROM (SELECT [timestamp] AS ts, CONVERT(xml, record) AS r FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%') x ORDER BY x.ts DESC")
  # sys.dm_os_host_info arrived in SQL Server 2017; a server without it runs on Windows
  HOSTP=$(sq "$ct" "IF OBJECT_ID('sys.dm_os_host_info') IS NULL SELECT N'Windows' ELSE EXEC (N'SELECT host_platform FROM sys.dm_os_host_info')")
  [ "$HOSTP" = Linux ] && NEWEST="${NEWEST%|*}|"
  [ "$(q "select record_id || '|' || sql_pct || '|' || coalesce(idle_pct::text, '') from pgvigil.mssql_cpu_sample where instance_id=$iid order by record_id desc limit 1")" = "$NEWEST" ] \
    || fail "A: the newest record $(q "select record_id || '|' || sql_pct || '|' || coalesce(idle_pct::text, '') from pgvigil.mssql_cpu_sample where instance_id=$iid order by record_id desc limit 1"), want $NEWEST (host $HOSTP)"
  SAS=$(sq "$ct" "SELECT CAST(COUNT(*) AS varchar(10)) + '|' + CAST(MAX(si.max_workers_count) AS varchar(10)) FROM sys.dm_os_schedulers s CROSS JOIN sys.dm_os_sys_info si WHERE s.status = N'VISIBLE ONLINE'")
  [ "$(q "select string_agg(schedulers || '|' || max_workers, ',' order by snapshot_at) from pgvigil.mssql_sched_sample where instance_id=$iid")" = "$SAS,$SAS" ] \
    || fail "A: schedulers|max workers $(q "select string_agg(schedulers || '|' || max_workers, ',' order by snapshot_at) from pgvigil.mssql_sched_sample where instance_id=$iid"), sa $SAS"
  RISE=$((B1 - B0))
  RATE=$(q "select (batch_s is null) || '|' || coalesce(round(batch_s * interval_secs)::text, '') || '|' || (transactions_s is not null) from pgvigil.mssql_sched_sample where instance_id=$iid order by snapshot_at")
  IFS='|' read -r FIRSTNULL _ _ <<<"$(echo "$RATE" | sed -n 1p)"; IFS='|' read -r _ N2 TX2 <<<"$(echo "$RATE" | sed -n 2p)"
  echo "  batches over the interval: stored $N2, sa's counter rose $RISE"
  [ "$FIRSTNULL" = true ] && [ "$N2" -ge 300 ] && [ "$N2" -le "$RISE" ] && [ "$TX2" = true ] || fail "A: the rates: $RATE (sa's rise $RISE)"
  echo "A: OK"

  echo "--- B. mssql_memory"
  collect mssql_memory "$N" >/dev/null
  SAM=$(sq "$ct" "SELECT CAST(sm.total_physical_memory_kb AS varchar(20)) + '|' + CAST(si.sql_memory_model_desc AS varchar(20)) + '|' + (SELECT CAST(cntr_value AS varchar(20)) FROM sys.dm_os_performance_counters WHERE RTRIM(object_name) LIKE N'%:Memory Manager' AND counter_name = N'Target Server Memory (KB)') FROM sys.dm_os_sys_memory sm CROSS JOIN sys.dm_os_sys_info si")
  [ "$(q "select physical_kb || '|' || memory_model || '|' || target_kb from pgvigil.mssql_memory_sample where instance_id=$iid")" = "$SAM" ] \
    || fail "B: physical|model|target $(q "select physical_kb || '|' || memory_model || '|' || target_kb from pgvigil.mssql_memory_sample where instance_id=$iid"), sa $SAM"
  SATOP=$(sq "$ct" "SELECT TOP 1 type FROM sys.dm_os_memory_clerks GROUP BY type ORDER BY SUM(pages_kb) DESC")
  [ "$(q "select clerk_type from pgvigil.mssql_memory_clerk where instance_id=$iid order by pages_kb desc limit 1")" = "$SATOP" ] || fail "B: the largest clerk is not sa's $SATOP"
  [ "$(q "select (count(*) >= 10) || '|' || (sum(c.pages_kb) = max(m.clerks_kb)) from pgvigil.mssql_memory_clerk c join pgvigil.mssql_memory_sample m using (instance_id, snapshot_at) where c.instance_id=$iid")" = "true|true" ] \
    || fail "B: the clerks: $(q "select count(*), sum(c.pages_kb), max(m.clerks_kb) from pgvigil.mssql_memory_clerk c join pgvigil.mssql_memory_sample m using (instance_id, snapshot_at) where c.instance_id=$iid")"
  SAPC=$(sq "$ct" "SELECT SUM(pages_kb) FROM sys.dm_os_memory_clerks WHERE type IN (N'CACHESTORE_SQLCP', N'CACHESTORE_OBJCP', N'CACHESTORE_PHDR', N'CACHESTORE_XPROC')")
  [ "$(q "select abs(plan_cache_kb - $SAPC) <= 0.05 * greatest($SAPC, 1) + 1024 from pgvigil.mssql_memory_sample where instance_id=$iid")" = t ] \
    || fail "B: the plan cache $(q "select plan_cache_kb from pgvigil.mssql_memory_sample where instance_id=$iid") KB, sa $SAPC KB"
  echo "B: OK"

  echo "--- C. mssql_fileio"
  collect mssql_fileio "$N" >/dev/null
  if [ "$i" = 0 ]; then
    sq "$ct" "INSERT dbo.pv_rows (pad) SELECT TOP (6000) 'a' FROM sys.all_columns a CROSS JOIN sys.all_columns b; CHECKPOINT;" "$DB" >/dev/null
  fi
  sleep 2
  collect mssql_fileio "$N" >/dev/null
  grep -q "partial" "$OUT" && fail "C: the run is partial: $(cat "$OUT")"
  if [ "$i" = 0 ]; then
    GOT=$(q "select string_agg(type_desc || ':' || writes || ':' || write_bytes, ',' order by file_id) from pgvigil.mssql_fileio_sample where instance_id=$iid and database_name='$DB'")
    echo "  the proof database's differences (type:writes:bytes): $GOT"
    [ "$(q "select (sum(write_bytes) filter (where type_desc='ROWS') >= 16 * 1048576) || '|' || (sum(writes) filter (where type_desc='LOG') > 0) from pgvigil.mssql_fileio_sample where instance_id=$iid and database_name='$DB'")" = "true|true" ] \
      || fail "C: the proof database's writes: $GOT"
  fi
  # master's, tempdb's and msdb's files carry their names and types (the Linux build's internal model_* databases have no sys.master_files row)
  [ "$(q "select count(*) || '|' || count(*) filter (where file_name is null or type_desc is null) from pgvigil.mssql_fileio_last where instance_id=$iid and database_name in ('master', 'tempdb', 'msdb')")" = "$(sq "$ct" "SELECT CAST(COUNT(*) AS varchar(10)) FROM sys.master_files WHERE database_id IN (1, 2, 4)")|0" ] \
    || fail "C: the system databases' files: $(q "select count(*), count(file_name), count(type_desc) from pgvigil.mssql_fileio_last where instance_id=$iid and database_name in ('master', 'tempdb', 'msdb')")"
  SAF=$(sq "$ct" "SELECT CAST(SUM(num_of_writes) AS varchar(20)) + '|' + CAST(SUM(num_of_bytes_written) AS varchar(20)) FROM sys.dm_io_virtual_file_stats(NULL, NULL)")
  [ "$(q "select (sum(writes) <= ${SAF%%|*}) || '|' || (sum(write_bytes) <= ${SAF#*|}) from pgvigil.mssql_fileio_last where instance_id=$iid")" = "true|true" ] \
    || fail "C: the stored counters are above sa's later read"
  NV=proof-perfvss-$i-$SUF
  collect mssql_fileio "$NV" | grep -q "partial: sys.master_files" || fail "C: VIEW SERVER STATE alone: $(cat "$OUT")"
  iv=$(q "select instance_id from pgvigil.instances where name='$NV'")
  [ "$(q "select (count(*) > 0) || '|' || count(*) filter (where database_name is null) || '|' || count(*) filter (where type_desc is not null) from pgvigil.mssql_fileio_last where instance_id=$iv")" = "true|0|0" ] \
    || fail "C: VIEW SERVER STATE alone stored $(q "select count(*), count(database_name), count(type_desc) from pgvigil.mssql_fileio_last where instance_id=$iv")"
  echo "C: OK"

  echo "--- D. mssql_tempdb"
  collect mssql_tempdb "$N" >/dev/null
  SAT=$(sq "$ct" "SELECT CAST(SUM(CASE WHEN type_desc = 'ROWS' THEN 1 ELSE 0 END) AS varchar(5)) + '|' + CAST(SUM(CASE WHEN type_desc = 'LOG' THEN 1 ELSE 0 END) AS varchar(5)) + '|' + CAST(SUM(CASE WHEN type_desc = 'ROWS' THEN CAST(size AS bigint) * 8192 ELSE 0 END) AS varchar(20)) + '|' + CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS varchar(5)) + '|' + CASE WHEN MIN(CASE WHEN type_desc = 'ROWS' THEN size END) = MAX(CASE WHEN type_desc = 'ROWS' THEN size END) THEN 'true' ELSE 'false' END FROM tempdb.sys.database_files")
  IFS='|' read -r SND SNL SBYTES SCPU SEVEN <<<"$SAT"
  REC=$(( SCPU < 8 ? SCPU : 8 )); INS=$([ "$SND" -lt "$REC" ] && echo true || echo false)
  # (memory-optimized tempdb metadata arrived in SQL Server 2019: before it the server has no such property and
  # the collector stores no value, which both sides say as n/a)
  MO=$(sq "$ct" "SELECT CASE WHEN SERVERPROPERTY('IsTempDBMetadataMemoryOptimized') IS NULL THEN 'n/a' WHEN CAST(SERVERPROPERTY('IsTempDBMetadataMemoryOptimized') AS int) = 1 THEN 'true' ELSE 'false' END")
  WANT="$SND|$SNL|$SBYTES|$SCPU|$REC|$INS|$SEVEN|false|false|false|$MO"
  GOTT=$(q "select data_files || '|' || log_files || '|' || data_bytes || '|' || cpu_count || '|' || recommended_files || '|' || insufficient_files || '|' || even_size || '|' || tf1117 || '|' || tf1118 || '|' || flags_required || '|' || coalesce(memopt_metadata::text, 'n/a') from pgvigil.mssql_tempdb where instance_id=$iid")
  echo "  tempdb (data|log|bytes|cpus|recommended|insufficient|even|1117|1118|flags required|memopt): $GOTT"
  [ "$GOTT" = "$WANT" ] || fail "D: tempdb $GOTT, sa reads $WANT"
  [ "$(q "select count(*) from pgvigil.mssql_tempdb_files where instance_id=$iid")" = $((SND + SNL)) ] || fail "D: the file rows"
  echo "D: OK"

  echo "--- E. a login without VIEW SERVER STATE"
  for c in mssql_cpu mssql_memory mssql_fileio; do
    collect $c "$NB" | grep -q "skipped: the login lacks VIEW SERVER STATE" || fail "E: $c on the bare login: $(cat "$OUT")"
  done
  collect mssql_tempdb "$NB" | grep -q "partial: sys.dm_os_sys_info" || fail "E: mssql_tempdb on the bare login: $(cat "$OUT")"
  ib=$(q "select instance_id from pgvigil.instances where name='$NB'")
  [ "$(q "select coalesce(cpu_count::text, 'null') || '|' || coalesce(insufficient_files::text, 'null') || '|' || data_files from pgvigil.mssql_tempdb where instance_id=$ib")" = "null|null|$SND" ] \
    || fail "E: the bare login's tempdb row: $(q "select cpu_count, insufficient_files, data_files from pgvigil.mssql_tempdb where instance_id=$ib")"
  echo "E: OK"
done

echo "=== without a server"
echo "--- F. the findings' thresholds"
xi=$(q "select pgvigil.ensure_instance('proof-perf-x-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
xj=$(q "select pgvigil.ensure_instance('proof-perf-y-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
tdb() { # tdb <instance> <cpus> <flags_required> <file rows json>
  q "select pgvigil.import_mssql_tempdb($1, now(), ('[{\"kind\":\"server\",\"cpu_count\":$2,\"major\":16,\"tf1117\":0,\"tf1118\":0,\"flags_required\":$3,\"memopt_metadata\":0},' || '$4' || ']')::jsonb)" >/dev/null; }
f() { local id=$3; echo "{\"kind\":\"file\",\"file_id\":$id,\"file_name\":\"f$id\",\"type_desc\":\"ROWS\",\"size_bytes\":$1,\"growth_bytes\":$2,\"growth_pct\":${4:-0}}"; }
LOGF='{"kind":"file","file_id":2,"file_name":"templog","type_desc":"LOG","size_bytes":1073741824,"growth_bytes":67108864,"growth_pct":0}'
G=$((1 << 30))
tdb "$xi" 16 1 "$(f $((8*G)) 0 1 10),$(f $((4*G)) 67108864 3),$(f $((4*G)) 67108864 4),$(f $((4*G)) 67108864 5),$LOGF"
FX=$(q "select string_agg(severity || ':' || check_name, ',' order by check_name) from pgvigil.mssql_perf_findings where instance_id=$xi")
echo "  4 uneven files on 16 CPUs, 10 % growth, before 2016: $FX"
for want in "warning:tempdb has fewer data files than recommended" "warning:tempdb data files differ in size" "warning:tempdb data files differ in growth" \
            "info:a tempdb data file grows by per cent" "warning:tempdb trace flags 1117 / 1118 off before SQL Server 2016"; do
  case ",$FX," in *",$want,"*) ;; *) fail "F: missing $want";; esac
done
EVEN=""; for k in 1 3 4 5 6 7 8 9; do EVEN="$EVEN$(f $((4*G)) 67108864 $k),"; done
tdb "$xj" 16 0 "$EVEN$LOGF"
[ "$(q "select count(*) from pgvigil.mssql_perf_findings where instance_id=$xj")" = 0 ] || fail "F: 8 even files on 16 CPUs raised $(q "select string_agg(check_name, ',') from pgvigil.mssql_perf_findings where instance_id=$xj")"
cpurecs() { # cpurecs <instance> <sql %> <idle %> <first id>
  local rows=""; for k in $(seq 0 11); do rows="$rows{\"kind\":\"cpu\",\"record_id\":$(($4 + k)),\"sample_at\":\"$(date -u -d "-$((k + 1)) minutes" +%FT%TZ)\",\"sql_pct\":$2,\"idle_pct\":$3,\"other_pct\":$((100 - $2 - $3))},"; done
  q "select pgvigil.import_mssql_cpu($1, now(), '[{\"kind\":\"state\",\"server_utc\":\"$(date -u +%FT%T.%NZ)\",\"server_start\":\"2026-01-01T00:00:00Z\"},${rows%,}]'::jsonb)" >/dev/null; }
cpurecs "$xi" 90 4 1000
cpurecs "$xj" 45 50 1000
[ "$(q "select string_agg(severity, ',') from pgvigil.mssql_perf_findings where check_name='CPU at 90 % or more' and instance_id in ($xi, $xj)")" = critical ] \
  || fail "F: the CPU finding: $(q "select instance_id, severity from pgvigil.mssql_perf_findings where check_name='CPU at 90 % or more'")"
# ten schedulers reads, two runnable tasks per scheduler on $xi and none on $xj (the import's rows straight into the table: the rates do not matter here)
q "insert into pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, runnable_tasks, work_queue, current_workers, max_workers)
   select i, now() - make_interval(mins => k), 4, case when i = $xi then 8 else 0 end, 0, 50, 576 from generate_series(1, 10) k, unnest(array[$xi, $xj]) i" >/dev/null
q "select pgvigil.ensure_month_partition('mssql_memory_sample', now())" >/dev/null
q "insert into pgvigil.mssql_memory_sample (instance_id, snapshot_at, physical_kb, available_kb, system_state, process_kb, grants_pending, grants_waiting, sem_waiting, max_grant_kb)
   select i, now() - make_interval(mins => k), 16777216, 102400,
          case when i = $xi and k = 1 then 'Available physical memory is low' else 'Available physical memory is high' end, 8388608,
          case when k <= (case when i = $xi then 3 else 2 end) then 1 else 0 end, 0, 0, 1048576
     from generate_series(1, 10) k, unnest(array[$xi, $xj]) i" >/dev/null
xk=$(q "select pgvigil.ensure_instance('proof-perf-k-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
q "insert into pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, runnable_tasks, work_queue, current_workers, max_workers)
   select $xk, now() - make_interval(mins => k), 4, 0, case when k <= 5 then 3 else 0 end, 576, 576 from generate_series(1, 10) k" >/dev/null
[ "$(q "select count(*) from pgvigil.mssql_perf_findings where instance_id=$xk and check_name='scheduler pressure' and detail like 'tasks waited in the work queue in 5 of the last 10 reads%'")" = 1 ] \
  || fail "F: the work queue arm: $(q "select detail from pgvigil.mssql_perf_findings where instance_id=$xk")"
[ "$(q "select string_agg(instance_id || ':' || check_name, ',' order by check_name) from pgvigil.mssql_perf_findings where check_name in ('scheduler pressure', 'available physical memory is low', 'queries wait for memory grants') and instance_id in ($xi, $xj)")" \
  = "$xi:available physical memory is low,$xi:queries wait for memory grants,$xi:scheduler pressure" ] \
  || fail "F: scheduler / memory: $(q "select string_agg(instance_id || ':' || check_name, ',' order by check_name) from pgvigil.mssql_perf_findings where check_name in ('scheduler pressure', 'available physical memory is low', 'queries wait for memory grants') and instance_id in ($xi, $xj)")"
q "select pgvigil.ensure_month_partition('mssql_fileio_sample', now())" >/dev/null
q "insert into pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc, reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs) values
   ($xi, now() - interval '5 minutes', 5, 1, 'd60', 'd60', 'ROWS', 2000, 0, 120000, 0, 0, 0, 60),
   ($xi, now() - interval '5 minutes', 6, 1, 'd120', 'd120', 'ROWS', 2000, 0, 240000, 0, 0, 0, 60),
   ($xi, now() - interval '5 minutes', 7, 1, 'dfew', 'dfew', 'ROWS', 500, 0, 30000, 0, 0, 0, 60),
   ($xi, now() - interval '5 minutes', 7, 2, 'dfew', 'dlog', 'LOG', 0, 0, 0, 2000, 0, 50000, 60),
   ($xi, now() - interval '5 minutes', 8, 2, 'dnotype', NULL, NULL, 2000, 0, 120000, 0, 0, 0, 60)" >/dev/null
[ "$(q "select string_agg(severity || ':' || check_name || ':' || object, ',' order by object) from pgvigil.mssql_perf_findings where instance_id=$xi and check_name like 'slow%'")" \
  = "critical:slow data file reads:d120: d120,warning:slow data file reads:d60: d60,warning:slow log writes:dfew: dlog" ] \
  || fail "F: file IO: $(q "select string_agg(severity || ':' || check_name || ':' || object, ',' order by object) from pgvigil.mssql_perf_findings where instance_id=$xi and check_name like 'slow%'")"
echo "F: OK"

echo "--- G. the imports refuse a PostgreSQL instance"
pgi=$(q "select pgvigil.ensure_instance('proof-perf-pg-$SUF', 'postgres', 'x', 170000, false, '{}', 'postgres')")
for c in cpu memory fileio tempdb; do
  if q "select pgvigil.import_mssql_$c($pgi, now(), '[{\"kind\":\"state\",\"server_utc\":\"2026-01-01T00:00:00Z\"},{\"kind\":\"memory\"},{\"kind\":\"server\"},{\"kind\":\"file\",\"type_desc\":\"ROWS\"}]'::jsonb)" >/dev/null 2>"$OUT"; then
    fail "G: import_mssql_$c took a PostgreSQL instance"
  fi
  grep -q "is not a SQL Server instance" "$OUT" || fail "G: import_mssql_$c: $(cat "$OUT")"
done
echo "G: OK"

echo "--- X. retries, late reads and a restart"
xr=$(q "select pgvigil.ensure_instance('proof-perf-r-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
# six read times a minute apart, all from ONE look at the clock: a time taken later by its own `date` call sits the
# statements between the two calls further on, and the 60 s this part asserts became 61 on a busy machine
XB=$(date -u +%s); xt() { date -u -d "@$((XB - $1 * 60))" +%FT%TZ; }
T0=$(xt 10); T1=$(xt 9); T2=$(xt 8); T3=$(xt 7)
cpuX() { q "select pgvigil.import_mssql_cpu($xr, '$1', '[{\"kind\":\"state\",\"server_utc\":\"$1\",\"server_start\":\"$2\"},{\"kind\":\"cpu\",\"record_id\":7,\"sample_at\":\"$T0\",\"sql_pct\":5,\"idle_pct\":90,\"other_pct\":5},{\"kind\":\"sched\",\"schedulers\":4},{\"kind\":\"counter\",\"counter\":\"Batch Requests/sec\",\"value\":$3}]'::jsonb)" >/dev/null; }
cpuX "$T1" 2026-01-01T00:00:00Z 1000; cpuX "$T1" 2026-01-01T00:00:00Z 1000
[ "$(q "select (select count(*) from pgvigil.mssql_sched_sample where instance_id=$xr) || '|' || (select count(*) from pgvigil.mssql_cpu_sample where instance_id=$xr)")" = "1|1" ] || fail "X: a cpu payload imported twice"
cpuX "$T2" 2026-01-01T00:00:00Z 7000
[ "$(q "select batch_s from pgvigil.mssql_sched_sample where instance_id=$xr and snapshot_at='$T2'")" = 100 ] || fail "X: the rate (6000 batches in 60 s)"
cpuX "$T3" 2026-11-01T00:00:00Z 9000
[ "$(q "select coalesce(batch_s::text, 'null') from pgvigil.mssql_sched_sample where instance_id=$xr and snapshot_at='$T3'")" = null ] || fail "X: a rate across a restart"
fio() { q "select pgvigil.import_mssql_fileio($xr, '$1', '[{\"kind\":\"state\",\"server_utc\":\"$1\",\"server_start\":\"$2\"},{\"kind\":\"file\",\"database_id\":5,\"file_id\":1,\"database_name\":\"d\",\"file_name\":\"d\",\"type_desc\":\"ROWS\",\"reads\":$3,\"read_bytes\":$3,\"read_stall_ms\":$3,\"writes\":0,\"write_bytes\":0,\"write_stall_ms\":0}]'::jsonb)" >/dev/null; }
fio "$T1" 2026-01-01T00:00:00Z 100; fio "$T2" 2026-01-01T00:00:00Z 300; fio "$T0" 2026-01-01T00:00:00Z 50
[ "$(q "select string_agg(reads::text, ',' order by snapshot_at) from pgvigil.mssql_fileio_sample where instance_id=$xr")" = 200 ] || fail "X: fileio differences $(q "select string_agg(reads::text, ',') from pgvigil.mssql_fileio_sample where instance_id=$xr") (want 200 only: the late read stores nothing)"
fio "$T3" 2026-11-01T00:00:00Z 10
T4=$(xt 6); fio "$T4" 2026-11-01T00:00:00Z 40
[ "$(q "select string_agg(reads::text, ',' order by snapshot_at) from pgvigil.mssql_fileio_sample where instance_id=$xr")" = "200,30" ] || fail "X: after a restart $(q "select string_agg(reads::text, ',' order by snapshot_at) from pgvigil.mssql_fileio_sample where instance_id=$xr") (want 200,30)"
T5=$(xt 5); fio "$T5" 2026-11-01T00:00:00Z 40   # an idle read: no file moved
[ "$(q "select string_agg(round(interval_secs)::text || ':' || files, ',' order by snapshot_at) from pgvigil.mssql_fileio_read where instance_id=$xr")" = "60:1,60:1,60:0" ] \
  || fail "X: the reads' seconds $(q "select string_agg(round(interval_secs)::text || ':' || files, ',' order by snapshot_at) from pgvigil.mssql_fileio_read where instance_id=$xr") (want 60:1,60:1,60:0: T2, T4 and the idle T5)"
[ "$(q "select count(*) from pgvigil.mssql_fileio_sample where instance_id=$xr")" = 2 ] || fail "X: the idle read stored a difference"
xm=$(q "select pgvigil.ensure_instance('proof-perf-m-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
cnt() { q "select pgvigil.import_mssql_cpu($xm, '$1', '[{\"kind\":\"state\",\"server_utc\":\"$1\",\"server_start\":\"2026-01-01T00:00:00Z\"},{\"kind\":\"sched\",\"schedulers\":4}$2]'::jsonb)" >/dev/null; }
cnt "$T1" ',{"kind":"counter","counter":"Batch Requests/sec","value":1000},{"kind":"counter","counter":"Transactions/sec","value":1000}'
cnt "$T2" ',{"kind":"counter","counter":"Batch Requests/sec","value":2000}'
cnt "$T3" ',{"kind":"counter","counter":"Batch Requests/sec","value":3000},{"kind":"counter","counter":"Transactions/sec","value":2200}'
[ "$(q "select batch_s || '|' || transactions_s from pgvigil.mssql_sched_sample where instance_id=$xm and snapshot_at='$T3'")" = "16.667|10" ] \
  || fail "X: a counter missing from one read: $(q "select batch_s, transactions_s from pgvigil.mssql_sched_sample where instance_id=$xm and snapshot_at='$T3'") (want 16.667|10)"
echo "X: OK"

echo "--- P. the API on the servers' repository"
PORT=$(for p in $(seq 18190 18230); do ss -ltn | grep -qE "(127.0.0.1|\[::1\]):$p " || { echo $p; break; }; done)
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "$U/health" >/dev/null || { cat "$WORK/serve.log" >&2; fail "P: the UI did not serve"; }
i0=$(q "select instance_id from pgvigil.instances where name='proof-perf-0-$SUF'")
W="from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"
n() { jq "[.$2.rows[]] | length" "$1"; }
curl -fs "$U/mssql/cpu?instance=$i0&$W" > "$WORK/cpu.json"; curl -fs "$U/mssql/memory?instance=$i0&$W" > "$WORK/mem.json"
curl -fs "$U/mssql/fileio?instance=$i0&$W" > "$WORK/io.json"; curl -fs "$U/mssql/tempdb" > "$WORK/tdb.json"
curl -fs "$U/performance?instance=$i0&$W" > "$WORK/perf.json"; curl -fs "$U/perfsummary?$W" > "$WORK/ps.json"
echo "  cpu: latest $(n "$WORK/cpu.json" latest) cpu $(n "$WORK/cpu.json" cpu); memory: series $(n "$WORK/mem.json" series) clerks $(n "$WORK/mem.json" clerks); fileio: files $(n "$WORK/io.json" files); tempdb: $(n "$WORK/tdb.json" layout); performance: cpu $(n "$WORK/perf.json" cpu) db $(n "$WORK/perf.json" db) io $(n "$WORK/perf.json" io)"
for c in "$WORK/cpu.json:latest" "$WORK/cpu.json:cpu" "$WORK/mem.json:latest" "$WORK/mem.json:series" "$WORK/mem.json:clerks" "$WORK/io.json:files" "$WORK/perf.json:cpu" "$WORK/perf.json:db" "$WORK/perf.json:io"; do
  [ "$(n "${c%%:*}" "${c#*:}")" -ge 1 ] || fail "P: no rows in $(basename "${c%%:*}") part ${c#*:}"
done
# tempdb lists every server's monitoring login rows (both of the pair; one where the run is given one server, as the
# SQL Server 2016 proof does) and the bare logins' rows (cpu_count null), plus the F instances
[ "$(jq "[.layout.rows[] | select(.[1] | test(\"proof-perf-[0-9]+-$SUF\"))] | length" "$WORK/tdb.json")" = "${#CTS[@]}" ] || fail "P: tempdb does not list every server (${#CTS[@]})"
COLS=$(jq -c '.mssql.columns' "$WORK/ps.json")
PSOK=$(jq --argjson c "$COLS" -r "[.mssql.rows[] | select(.[\$c | index(\"instance\")] | test(\"proof-perf-[0-9]+-$SUF\")) | (.[\$c | index(\"cpu_avg\")] != null) and (.[\$c | index(\"mem_total_pct\")] != null)] | (length|tostring) + \":\" + (all|tostring)" "$WORK/ps.json")
IO0=$(jq --argjson c "$COLS" -r "[.mssql.rows[] | select(.[\$c | index(\"instance\")] == \"proof-perf-0-$SUF\") | (.[\$c | index(\"read_ms\")] != null) or (.[\$c | index(\"write_ms\")] != null)] | all" "$WORK/ps.json")
[ "$PSOK|$IO0" = "${#CTS[@]}:true|true" ] || fail "P: perfsummary's SQL Server rows ($PSOK): $(jq -c '.mssql.rows' "$WORK/ps.json" | head -c 600)"
echo "P: OK"

echo "--- DEMO. a two-day demo"
adm -c "create database $DEMO_DB"; MADE_DEMO=1
DPORT=$(for p in $(seq 18231 18270); do ss -ltn | grep -qE "(127.0.0.1|\[::1\]):$p " || { echo $p; break; }; done)
"$BIN" demo -dsn "$ADMIN_DSN dbname=$DEMO_DB" -days 2 -serve -listen 127.0.0.1:$DPORT > "$WORK/demo.log" 2>&1 & DEMO_PID=$!
for _ in $(seq 1 600); do grep -q "demo serving" "$WORK/demo.log" && break; kill -0 $DEMO_PID 2>/dev/null || break; sleep 1; done
grep -q "demo serving" "$WORK/demo.log" || { tail -5 "$WORK/demo.log" >&2; fail "DEMO: the demo never served"; }
D=http://127.0.0.1:$DPORT/api
dq() { psql "$ADMIN_DSN dbname=$DEMO_DB" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
s1=$(dq "select instance_id from pgvigil.instances where name like '%-sql01'"); s2=$(dq "select instance_id from pgvigil.instances where name like '%-sql02'"); s3=$(dq "select instance_id from pgvigil.instances where name like '%-sql03'")
DW="from=$(date -u -d '-12 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"
curl -fs "$D/performance?instance=$s1&$DW" > "$WORK/dperf.json"
echo "  sql01 Performance: cpu $(n "$WORK/dperf.json" cpu), db $(n "$WORK/dperf.json" db), io $(n "$WORK/dperf.json" io) steps"
for p in cpu db io; do [ "$(n "$WORK/dperf.json" $p)" -ge 100 ] || fail "DEMO: sql01's Performance part $p has $(n "$WORK/dperf.json" $p) steps"; done
curl -fs "$D/mssql/cpu?instance=$s1&$DW" > "$WORK/dcpu.json"; curl -fs "$D/mssql/memory?instance=$s1&$DW" > "$WORK/dmem.json"; curl -fs "$D/mssql/fileio?instance=$s1&$DW" > "$WORK/dio.json"
for c in "$WORK/dcpu.json:cpu" "$WORK/dcpu.json:sched" "$WORK/dcpu.json:counters" "$WORK/dmem.json:series" "$WORK/dmem.json:clerks" "$WORK/dmem.json:clerk_stats" "$WORK/dio.json:latency" "$WORK/dio.json:throughput" "$WORK/dio.json:files"; do
  [ "$(n "${c%%:*}" "${c#*:}")" -ge 1 ] || fail "DEMO: no rows in $(basename "${c%%:*}") part ${c#*:}"
done
curl -fs "$D/mssql/tempdb" > "$WORK/dtdb.json"
[ "$(n "$WORK/dtdb.json" layout)" = 3 ] || fail "DEMO: the fleet TempDB grid has $(n "$WORK/dtdb.json" layout) rows"
DF=$(dq "select string_agg(instance_id || ':' || check_name, ',' order by instance_id, check_name) from pgvigil.mssql_perf_findings where check_name like '%tempdb%'")
echo "  tempdb findings: $DF"
case ",$DF," in *",$s1:tempdb has fewer data files than recommended,"*) ;; *) fail "DEMO: sql01's tempdb finding";; esac
case ",$DF," in *",$s3:tempdb data files differ in size,"*) ;; *) fail "DEMO: sql03's uneven files";; esac
case ",$DF," in *",$s2:"*) fail "DEMO: sql02's tempdb raised a finding";; esac
curl -fs "$D/perfsummary?$DW" > "$WORK/dps.json"
DC=$(jq -c '.mssql.columns' "$WORK/dps.json")
DOK=$(jq --argjson c "$DC" -r '[.mssql.rows[] | (.[$c | index("cpu_avg")] != null) and (.[$c | index("read_ms")] != null) and (.[$c | index("ple_min")] != null)] | (length|tostring) + ":" + (all|tostring)' "$WORK/dps.json")
[ "$DOK" = "3:true" ] || fail "DEMO: perfsummary's SQL Server rows ($DOK)"
echo "DEMO: OK"

echo "NOT PROVEN HERE: SQL Server 2016-2019, Windows, Managed Instance, RDS, a VIEW SERVER PERFORMANCE STATE-only login, a real memory grant wait, a ring buffer after a real restart"
echo "proof-mssql-perf: PASS (A-E on ${#CTS[@]} servers, F, G, X, P, DEMO)"
