#!/usr/bin/env bash
# Proof of task 177 D14 (darling-open D14): CPU, schedulers, the performance counters and the sessions in
# sp_PressureDetector's and PerformanceMonitor's shape - mssql_cpu's 'perfmon' rows and new scheduler columns,
# mssql_activity (sessions by application / host / database, the sessions holding tempdb, the per-database counters,
# the CPU details), 0124's functions and findings, the CPU, Connections, Metrics, TempDB, File IO and Jobs pages -
# against sp_PressureDetector's own logged output, PerformanceMonitor's own session query and hand reads on the same
# server.
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest), go, psql, curl, python3, node, npm, chromium, and:
#   ADMIN_DSN         a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                     user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_PROC_DIR  the procedure's own source (default .lab/procs, git-ignored): sp_PressureDetector.sql (DarlingData,
#                     MIT, darlingdata-20261101); never fetched.
#   PGVIGIL_SHOTS     where the page shots go (default: a folder of the run, removed with it)
#   PGVIGIL_WIRING    1 (default) applies scripts/proof-darling-cpu-wiring.patch (router.ts, main.ts, web.go: the
#                     lead's files) to this copy when the tree lacks the Connections route; 0 = the tree as it is.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# PerformanceMonitor 3.12.0's SessionStatsCollector read below is quoted verbatim from its source: MIT License,
# Copyright (c) Erik Darling, Darling Data LLC.
#
# Expected (written before the first run):
#  A. a SQL Server 2022 container with sp_PressureDetector installed, remote admin connections 1 (the DAC), three
#     user databases, a monitor login (VIEW SERVER STATE, VIEW ANY DEFINITION; an msdb user with db_datareader for
#     mssql_jobs).
#  B. two mssql_cpu and two mssql_activity reads at rest (a write load between the activity reads): the 'perfmon' rows
#     stored as mssql_counter_sample per series; the four throughput rates of mssql_sched_sample as before (0074's
#     import, unchanged) and offline CPUs 0 with the nodes online = all; mssql_cpu_info holds sp_PressureDetector's
#     CPU details; a cumulative counter's stored rate = (value - value before) / the reads' interval; a gauge stored at
#     0 is a row.
#  C. sp_PressureDetector logged (@log_to_table) right after pgvigil's reads: every perfmon row it logs (its 59
#     names, value over 0) is a series pgvigil stored at the read before it, every cumulative one at a value not above
#     sp_PressureDetector's and not below a hand read taken before pgvigil's; the CPU details equal its own read.
#  D. sessions: 5 sessions as host pgvc_h1 in pgvcpu, 3 as host pgvc_h2 in pgvcpu2, an idle one holding a temp table:
#     the activity read's groups (application, host, database) equal a hand read of the same filter and
#     PerformanceMonitor's own SessionStatsCollector read per application (its exclusion aside); the totals equal a
#     hand read of PerformanceMonitor's summary definitions (the sessions over 50: sessions, sleeping, background, the
#     databases); the idle session's tempdb (allocated, current, user,
#     internal; the running tasks' part 0) equals sys.dm_db_session_space_usage read by hand.
#  E. CPU pressure: 3 CPU-bound sessions per scheduler for 100 s: pgvigil's reads during it show runnable tasks > 0
#     and, at the requests read within 30 s, runnable requests over 10 % of 4 or more; sp_PressureDetector's logged
#     thread row at the same moment has threads waiting for CPU > 0 and its high_runnable_percent line; after it, the
#     scheduler monitor's record of 50 % or more SQL Server CPU is stored and is among sp_PressureDetector's logged CPU
#     events (the same percentage, the time within 1.5 s: sp_PressureDetector adds whole seconds, (timestamp - ms_ticks)
#     / 1000 in integer arithmetic, L3933, where pgvigil adds milliseconds, so the two times differ by up to 1 s and the
#     reads' own moments).
#  F. a worker shortage: max worker threads 128 and 200 sessions sending 2-second batches (the churn of spike4): pgvigil's
#     own collection runs log in and read work_queue > 0 and THREADPOOL > 0 with max workers 128, between DAC reads
#     before and after that both show a queue; sp_PressureDetector run over the DAC shows requests waiting for threads;
#     pgvigil's level HIGH (the levels themselves are G's table). Then a standing shortage (250 sessions held behind one
#     lock, about twice the workers; before each of up to three attempts a wait of up to 60 s for every online
#     scheduler to have a queue): a collection fails to connect and is logged as 'connect: ...' (D30), which the CPU
#     page marks 'possibly a worker shortage'. Why s177i-9's login got in under a standing shortage is not established
#     (its DAC read had only the total queue, 27); each attempt prints its scheduler state and a row per scheduler. If
#     all three attempts get in, the log says NOT PROVEN live (and whether every scheduler had queued) and the note is
#     proven on a stored connect failure (import_connect_failure).
#  G. the rules on stored rows: mssql_sched_levels on a table of cases (pgvigil's and PerformanceMonitor's levels and
#     PerformanceMonitor's recommendation, each band's edge); 'other processes use the CPU' at 50.0 % over 10 records
#     raises, 49.9 % or 9 records none; 'a transaction open for a long time' idle 30 min warning, 29 min none, 4 h
#     critical, running 4 h warning (never critical), running 3 h 59 none; 'slow data file writes' at 100.1 ms over
#     1,000 writes raises, 100 ms or 999 writes none; Running now's p95 and % of average equal a hand computation on the
#     stored job runs.
#  H. pgvigil serve: GET /api/mssql/cpu, /connections, /counters (one series picked), /fileio, /tempdb answer every
#     part, the counted ones equal to their functions.
#  I. the pages in headless Chromium, light and dark: CPU (pgvigil's verdict and PerformanceMonitor's labelled line equal to
#     the API's, the thread row, THREADPOOL, the CPU details, the connect-failure note), Connections (the tiles and the
#     three grids with the stored rows), Metrics (the counter grid's rows = the API's, the five default series charted,
#     a box checked and cleared), TempDB (the holders), File IO (KB per read / write, the log flushes), Jobs (p95, % of
#     average); no error box; every link and control of the CPU and Connections pages clicked with its landing in the
#     click table; shots of each page and theme. Before mssql_tempdb and mssql_fileio ever read (an early walk, light,
#     after a fresh temp-table session and an mssql_activity read, over its own window end): TempDB shows the holders
#     (at least 1, the count of mssql_session_tempdb_newest taken right after the walk), File IO no file grid and the
#     log flush rows of mssql_log_flush_between over that window. Then mssql_jobs, mssql_tempdb and two mssql_fileio
#     reads around a write, the stored running job and its runs, a window end taken again, and the main walk; its
#     holders at least 1.
# NOT PROVEN HERE: 'other processes' on a live server (a Linux host writes no idle figure; the rule on stored rows);
#   a live transaction open 30 minutes (stored rows); offline CPUs and an offline NUMA node (the container has none);
#   a job running live (SQL Agent is off in the container: stored rows); SQL Server 2016-2019, Managed Instance, RDS.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
PROCS=${PGVIGIL_PROC_DIR:-.lab/procs}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvc-sql-$SUF; LBL=pgvigil-proof=d14
PGDB=pgv_cpu_$SUF; MON=pgv_cmon_$SUF; USR=proofdba$SUF
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
# sq: T-SQL as sa (stdin; -I: QUOTED_IDENTIFIER ON); dac: the same over the dedicated admin connection; sqok: loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-120}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
dac() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout 120 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S admin:localhost -U sa -C -b -I -W -h -1 -s "|" -d master -i /dev/stdin'; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
dacok() { local out; out=$(dac "$2" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
# hold <host> <db> <batch>: sa runs the batch as host <host> in database <db> and keeps the session open (sleeping)
cat > "$TMPD/hold.sh" <<'HOLD'
{ printf '%s\nGO\n' "$4"; sleep 1200; } | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$SA_PW exec '"$6"' -S localhost -U sa -C -d "$1" -H "$0" -l 120' "$3" "$5" >/dev/null 2>&1
HOLD
hold() { setsid bash "$TMPD/hold.sh" "$SQL" "$TMPD/sa.env" "$1" "$3" "$2" "$SQLCMD" & BG+=($!); }
# churn <host> <batches>: one session sending the batches one after another (each a request of its own)
cat > "$TMPD/churn.sh" <<'CH'
printf '%s\n' "$4" | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$SA_PW exec '"$5"' -S localhost -U sa -C -d pgvcpu -H "$0" -l 120' "$3" >/dev/null 2>&1
CH
churn() { setsid bash "$TMPD/churn.sh" "$SQL" "$TMPD/sa.env" "$1" "$2" "$SQLCMD" & BG+=($!); }
seen() { local n=0; for _ in $(seq 1 120); do n=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name LIKE '$1'" 2>/dev/null || echo 0); (( n >= $2 )) && return 0; sleep 0.5; done; fail "$3: $n of $2 session(s) $1 connected"; }
killhost() { dac "DECLARE @s nvarchar(max) = N''; SELECT @s += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; ' FROM sys.dm_exec_sessions WHERE host_name LIKE '$1' AND session_id <> @@SPID; EXEC (@s);" >/dev/null 2>&1 || true; }
stopbg() { for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || true; done; BG=(); }
for t in docker go psql curl python3 node npm chromium setsid; do command -v "$t" >/dev/null || fail "needs $t"; done
[[ -s "$PROCS/sp_PressureDetector.sql" ]] || fail "needs $PROCS/sp_PressureDetector.sql (the procedure's own source)"
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && ! grep -q 'mssql/connections' internal/web/web.go; then
  git apply scripts/proof-darling-cpu-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-darling-cpu-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (router.ts, main.ts, web.go)"
fi

echo "== A. the container =="
docker run -d --name "$SQL" --label "$LBL" --memory 8g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
up() { local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done
  docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "A: the SQL Server container did not come up in 300 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
docker cp "$PROCS/sp_PressureDetector.sql" "$SQL:/tmp/pd.sql" >/dev/null
docker exec --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -d master -i /tmp/pd.sql' >"$TMPD/install.out" 2>&1 || { tail -5 "$TMPD/install.out"; fail "A: installing sp_PressureDetector"; }
sqok "A: the server options" "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'remote admin connections', 1; RECONFIGURE;"
sqok "A: the databases" "CREATE DATABASE pgvcpu; CREATE DATABASE pgvcpu2; CREATE DATABASE pgvc_out; ALTER DATABASE pgvcpu SET RECOVERY SIMPLE;"
sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0, pad char(500) NOT NULL DEFAULT 'a');
  INSERT dbo.t (id) SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvcpu
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
sqok "A: the monitor's msdb user (mssql_jobs reads msdb)" "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb
dacok "A: the DAC" "SELECT 1"
echo "ok   A: SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"), sp_PressureDetector (sha256 $(sha256sum "$PROCS/sp_PressureDetector.sql" | cut -c1-12)), the DAC answers, 3 user databases"

echo "== B. the reads at rest =="
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_C_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
cat > "$TMPD/m.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_C_MON
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
col() { for c in "$@"; do timeout 120 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance sqlbox -once "$c" >"$TMPD/col-$c.out" 2>&1 || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
col mssql_instance mssql_cpu mssql_activity mssql_requests mssql_waiting_tasks
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
sleep 8
sqok "B: a write load" "UPDATE dbo.t SET v = v + 1; UPDATE dbo.t SET v = v + 1; CHECKPOINT;" pgvcpu
col mssql_cpu mssql_activity
python3 - "$PGDSN" "$SB" <<'PYEND' || fail "B: see above"
import sys, subprocess
dsn, sb = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
bad = []
reads = q(f"SELECT scope, count(*), max(rows_read) FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} GROUP BY scope ORDER BY scope")
if [r[0] for r in reads] != ['database', 'instance'] or any(int(r[1]) != 2 for r in reads): bad.append(f"B reads per scope: {reads} (want 2 database, 2 instance)")
# the rate of each cumulative series at the second read = the raw difference over the interval
rr = q(f"""SELECT k.object, k.counter, k.inst, s2.value - s1.value, extract(epoch FROM c2.server_utc - c1.server_utc), s2.rate
  FROM pgvigil.mssql_counter_series k
  JOIN pgvigil.mssql_counter_read c1 ON c1.instance_id = {sb} AND c1.scope = CASE WHEN k.object IN ('Databases', 'Database Replica') THEN 'database' ELSE 'instance' END
  JOIN pgvigil.mssql_counter_read c2 ON c2.instance_id = {sb} AND c2.scope = c1.scope AND c2.snapshot_at > c1.snapshot_at
  JOIN pgvigil.mssql_counter_sample s1 ON s1.series_id = k.series_id AND s1.snapshot_at = c1.snapshot_at
  JOIN pgvigil.mssql_counter_sample s2 ON s2.series_id = k.series_id AND s2.snapshot_at = c2.snapshot_at
 WHERE k.instance_id = {sb} AND k.cntr_type IN (272696576, 272696320)""")
n = 0
for o, c, i, d, secs, rate in rr:
    n += 1
    want = int(d) / float(secs)
    if rate == '' or abs(float(rate) - want) > max(0.0015, abs(want) * 1e-6): bad.append(f"B rate {o}|{c}|{i}: stored {rate}, (value - value before) / interval = {want:.3f}")
if n < 20: bad.append(f"B only {n} cumulative series with two reads")
g0 = q(f"SELECT count(*) FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_series k USING (series_id) WHERE s.instance_id = {sb} AND k.cntr_type IN (65792, 65536) AND s.value = 0")
if int(g0[0][0]) == 0: bad.append("B no gauge stored at 0 (Processes blocked, Memory Grants Pending ... read 0 at rest)")
cz = q(f"SELECT count(*) FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_series k USING (series_id) WHERE s.instance_id = {sb} AND k.cntr_type IN (272696576, 272696320) AND s.value = 0")
if int(cz[0][0]) != 0: bad.append(f"B {cz[0][0]} cumulative row(s) stored at a raw 0")
sch = q(f"SELECT count(*), count(batch_s), min(offline_cpus), bool_and(nodes_online = nodes_total AND nodes_total > 0) FROM pgvigil.mssql_sched_sample WHERE instance_id = {sb}")[0]
if sch[0] != '2' or sch[1] != '1' or sch[2] != '0' or sch[3] != 't': bad.append(f"B scheduler rows {sch} (want 2 reads, the second with rates, offline 0, nodes online = all)")
lf = q(f"SELECT count(*) FROM pgvigil.mssql_log_flush_between({sb}, now() - interval '1 hour', now()) WHERE database_name = 'pgvcpu' AND avg_bytes_s > 0")
if lf[0][0] != '1': bad.append("B no log flush rate for pgvcpu after the write load")
info = q(f"SELECT info->>'cpu_count', info->>'scheduler_count' FROM pgvigil.mssql_cpu_info WHERE instance_id = {sb}")
if not info or not info[0][0]: bad.append(f"B CPU details {info}")
size = q(f"""SELECT c.scope, round(avg(n.rows)), (SELECT round(avg(pg_column_size(s.*))) FROM pgvigil.mssql_counter_sample s WHERE s.instance_id = {sb})
  FROM pgvigil.mssql_counter_read c CROSS JOIN LATERAL (SELECT count(*) AS rows FROM pgvigil.mssql_counter_sample s WHERE s.instance_id = {sb} AND s.snapshot_at = c.snapshot_at
   AND EXISTS (SELECT 1 FROM pgvigil.mssql_counter_series k WHERE k.series_id = s.series_id AND (k.object IN ('Databases', 'Database Replica')) = (c.scope = 'database'))) n
 WHERE c.instance_id = {sb} GROUP BY c.scope ORDER BY c.scope""")
for b in bad: print('DIFF', b)
print(f"B: {n} cumulative series' rates = the raw difference over the interval; gauges at 0 stored {g0[0][0]}; reads {reads}; scheduler {sch}; CPU details {info}")
print(f"B sizing (stored rows per read by scope, the average row's bytes): {size}")
sys.exit(1 if bad else 0)
PYEND
echo "ok   B: the counters stored per series with their rates, gauges at 0 kept, the four throughput rates and the scheduler pieces, the log flush per database, the CPU details"

echo "== C. the counters against sp_PressureDetector and hand reads =="
LIST=$(grep -o 'N.Forwarded Records/sec.*N.Lock Timeouts/sec.' "$PROCS/sp_PressureDetector.sql" | head -1 || true)
[[ -n "$LIST" ]] || LIST=$(python3 - "$PROCS/sp_PressureDetector.sql" <<'PYEND'
import re, sys
t = open(sys.argv[1]).read().split('AND   p.counter_name IN')[1].split(');')[0]
print(', '.join("N'" + n + "'" for n in re.findall(r"N'([^']+)'", t)))
PYEND
)
sq "SELECT RTRIM(object_name) + '|' + RTRIM(counter_name) + '|' + CASE WHEN LEN(RTRIM(instance_name)) > 0 THEN RTRIM(instance_name) ELSE N'_Total' END + '|' + CAST(cntr_value AS varchar(30))
  FROM sys.dm_os_performance_counters WHERE cntr_type IN (272696576, 272696320) AND cntr_value > 0" >"$TMPD/hand-before.out" || fail "C: the hand read before"
col mssql_cpu mssql_activity
sq "SELECT RTRIM(object_name) + '|' + RTRIM(counter_name) + '|' + CASE WHEN LEN(RTRIM(instance_name)) > 0 THEN RTRIM(instance_name) ELSE N'_Total' END + '|' + CAST(cntr_value AS varchar(30))
  FROM sys.dm_os_performance_counters WHERE cntr_type IN (272696576, 272696320) AND cntr_value > 0" >"$TMPD/hand-after.out" || fail "C: the hand read after"
sqok "C: sp_PressureDetector logged" "EXEC dbo.sp_PressureDetector @log_to_table = 1, @log_database_name = N'pgvc_out', @log_schema_name = N'dbo', @log_table_name_prefix = N'pdc';"
sq "SELECT object_name + '|' + counter_name + '|' + instance_name + '|' + CAST(cntr_value AS varchar(30)) + '|' + CAST(cntr_type AS varchar(20)) FROM dbo.pdc_Perfmon" pgvc_out >"$TMPD/pd-perfmon.out" || fail "C: the logged perfmon"
sq "SELECT ISNULL(CAST(socket_count AS varchar(10)), '') + '|' + CAST(cpu_count AS varchar(10)) + '|' + CAST(scheduler_count AS varchar(10)) FROM sys.dm_os_sys_info" >"$TMPD/hand-info.out" || fail "C: the CPU details by hand"
python3 - "$PGDSN" "$SB" "$TMPD" <<'PYEND' || fail "C: see above"
import sys, subprocess
dsn, sb, d = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
strip = lambda o: o.split(':', 1)[1] if ':' in o else o
def hand(f):
    out = {}
    for l in open(f):
        p = l.strip().split('|')
        if len(p) == 4: out[(strip(p[0]), p[1], p[2])] = int(p[3])
    return out
before, after = hand(f"{d}/hand-before.out"), hand(f"{d}/hand-after.out")
pd = {}
for l in open(f"{d}/pd-perfmon.out"):
    p = l.strip().split('|')
    if len(p) == 5: pd[(strip(p[0]), p[1], p[2])] = (int(p[3]), int(p[4]))
ours = {}
for o, c, i, v, t in q(f"""SELECT k.object, k.counter, k.inst, s.value, k.cntr_type FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_series k USING (series_id)
   JOIN (SELECT scope, max(snapshot_at) AS at FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} GROUP BY scope) r ON r.at = s.snapshot_at
  WHERE s.instance_id = {sb} AND (r.scope = 'database') = (k.object IN ('Databases', 'Database Replica'))"""):
    ours[(o, c, i)] = (int(v), int(t))
bad = []
if len(pd) < 30: bad.append(f"C sp_PressureDetector logged only {len(pd)} perfmon rows")
cum = 0
late = []
for k, (v, t) in pd.items():
    if k not in ours:
        # a cumulative counter at a raw 0 is not stored; one still at 0 in the hand read right after pgvigil's read
        # (which keeps only values over 0; counters only go up) started counting after it: that, not a miss
        if t in (272696576, 272696320) and k not in after: late.append(k); continue
        bad.append(f"C {k} logged by sp_PressureDetector ({v}, type {t}) is no series pgvigil stored at its read before"); continue
    ov, ot = ours[k]
    if ot != t: bad.append(f"C {k}: type {ot} against sp_PressureDetector's {t}")
    if t in (272696576, 272696320):
        cum += 1
        if ov > v: bad.append(f"C {k}: pgvigil {ov} above sp_PressureDetector's later {v}")
        if k in before and ov < before[k]: bad.append(f"C {k}: pgvigil {ov} below the hand read before it {before[k]}")
info = q(f"SELECT coalesce(info->>'socket_count', '') || '|' || (info->>'cpu_count') || '|' || (info->>'scheduler_count') FROM pgvigil.mssql_cpu_info WHERE instance_id = {sb}")
hand = open(f"{d}/hand-info.out").read().strip()
if not info or '|'.join(info[0]) != hand: bad.append(f"C CPU details {info} against the hand read {hand}")
for b in bad: print('DIFF', b)
print(f"C: sp_PressureDetector logged {len(pd)} perfmon rows, every one a series pgvigil stored ({cum} cumulative between the hand read before and its own) but {len(late)} cumulative that started counting after pgvigil's read {late}; CPU details {hand}")
sys.exit(1 if bad else 0)
PYEND
echo "ok   C: every counter sp_PressureDetector logs is stored by pgvigil, the cumulative ones between a hand read before and sp_PressureDetector's after; the CPU details equal"

echo "== D. sessions and tempdb =="
for i in 1 2 3 4 5; do hold pgvc_h1 pgvcpu "SELECT 1;"; done
for i in 1 2 3; do hold pgvc_h2 pgvcpu2 "SELECT 1;"; done
hold pgvc_tmp pgvcpu "CREATE TABLE #held (id int, pad char(2000)); INSERT #held SELECT TOP (600) object_id, 'x' FROM sys.all_objects;"
seen 'pgvc[_]h1' 5 "D: the h1 sessions"; seen 'pgvc[_]h2' 3 "D: the h2 sessions"; seen 'pgvc[_]tmp' 1 "D: the temp table session"
sleep 3
col mssql_activity
SQ_GROUPS="SELECT x.grp + '|' + ISNULL(x.name, '') + '|' + CAST(x.n AS varchar(10)) + '|' + CAST(x.sl AS varchar(10)) FROM (
  SELECT N'program' AS grp, s.program_name AS name, COUNT(*) AS n, SUM(CASE WHEN s.status = N'sleeping' THEN 1 ELSE 0 END) AS sl FROM sys.dm_exec_sessions s
   WHERE s.session_id > 50 AND s.is_user_process = 1 AND ISNULL(s.program_name, N'') <> N'' AND s.program_name NOT LIKE N'pgvigil%' AND s.session_id <> @@SPID GROUP BY s.program_name
  UNION ALL SELECT N'host', s.host_name, COUNT(*), SUM(CASE WHEN s.status = N'sleeping' THEN 1 ELSE 0 END) FROM sys.dm_exec_sessions s
   WHERE s.session_id > 50 AND s.is_user_process = 1 AND ISNULL(s.program_name, N'') <> N'' AND s.program_name NOT LIKE N'pgvigil%' AND s.session_id <> @@SPID AND s.host_name IS NOT NULL GROUP BY s.host_name
  UNION ALL SELECT N'database', DB_NAME(s.database_id), COUNT(*), SUM(CASE WHEN s.status = N'sleeping' THEN 1 ELSE 0 END) FROM sys.dm_exec_sessions s
   WHERE s.session_id > 50 AND s.is_user_process = 1 AND ISNULL(s.program_name, N'') <> N'' AND s.program_name NOT LIKE N'pgvigil%' AND s.session_id <> @@SPID GROUP BY DB_NAME(s.database_id)) x"
sq "$SQ_GROUPS" >"$TMPD/hand-groups.out" || fail "D: the hand read of the groups"
# PerformanceMonitor 3.12.0 SessionStatsCollector.QueryText, verbatim (MIT, Erik Darling, Darling Data LLC)
sq "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT /* PerformanceMonitorLite */
    program_name =
        ISNULL(des.program_name, N''),
    connection_count =
        COUNT_BIG(*),
    running_count =
        SUM
        (
            CASE
                WHEN des.status = N'running'
                THEN 1
                ELSE 0
            END
        ),
    sleeping_count =
        SUM
        (
            CASE
                WHEN des.status = N'sleeping'
                THEN 1
                ELSE 0
            END
        ),
    dormant_count =
        SUM
        (
            CASE
                WHEN des.status = N'dormant'
                THEN 1
                ELSE 0
            END
        ),
    total_cpu_time_ms =
        SUM(des.cpu_time),
    total_reads =
        SUM(des.reads),
    total_writes =
        SUM(des.writes),
    total_logical_reads =
        SUM(des.logical_reads)
FROM sys.dm_exec_sessions AS des
WHERE des.session_id > 50
AND   des.is_user_process = 1
AND   des.program_name IS NOT NULL
AND   des.program_name <> N''
AND   des.program_name NOT LIKE N'PerformanceMonitor%'
GROUP BY
    des.program_name
ORDER BY
    COUNT_BIG(*) DESC
OPTION(RECOMPILE);" >"$TMPD/pm-sessions.out" || fail "D: PerformanceMonitor's session read"
sq "SELECT CAST(COUNT(*) AS varchar(10)) + '|' + CAST(SUM(CASE WHEN status = N'sleeping' THEN 1 ELSE 0 END) AS varchar(10)) + '|' + CAST(SUM(CASE WHEN is_user_process = 0 THEN 1 ELSE 0 END) AS varchar(10)) + '|' + (SELECT STRING_AGG(CAST(x.d AS varchar(10)), ',') FROM (SELECT DISTINCT database_id AS d FROM sys.dm_exec_sessions WHERE session_id > 50 AND session_id <> @@SPID) x) FROM sys.dm_exec_sessions WHERE session_id > 50 AND session_id <> @@SPID" >"$TMPD/hand-total.out" || fail "D: the totals by hand"
sq "SELECT CAST(u.session_id AS varchar(10)) + '|' + CAST((u.user_objects_alloc_page_count + u.internal_objects_alloc_page_count) * 8 AS varchar(20)) + '|' + CAST((u.user_objects_alloc_page_count + u.internal_objects_alloc_page_count - u.user_objects_dealloc_page_count - u.internal_objects_dealloc_page_count) * 8 AS varchar(20)) + '|' + CAST((u.user_objects_alloc_page_count - u.user_objects_dealloc_page_count) * 8 AS varchar(20))
  FROM sys.dm_db_session_space_usage u JOIN sys.dm_exec_sessions s ON s.session_id = u.session_id WHERE s.host_name = N'pgvc_tmp'" >"$TMPD/hand-tmp.out" || fail "D: the temp table by hand"
python3 - "$PGDSN" "$SB" "$TMPD" <<'PYEND' || fail "D: see above"
import sys, subprocess
dsn, sb, d = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
bad = []
at = f"(SELECT max(snapshot_at) FROM pgvigil.mssql_session_summary WHERE instance_id = {sb})"
ours = {(g, n): (int(s), int(sl)) for g, n, s, sl in q(f"SELECT grp, name, sessions, sleeping FROM pgvigil.mssql_session_group WHERE instance_id = {sb} AND snapshot_at = {at}")}
hand = {}
for l in open(f"{d}/hand-groups.out"):
    p = l.strip().split('|')
    if len(p) == 4: hand[(p[0], p[1])] = (int(p[2]), int(p[3]))
for k in ('host', 'database'):
    o = {n: v for (g, n), v in ours.items() if g == k}; h = {n: v for (g, n), v in hand.items() if g == k}
    if o != h: bad.append(f"D {k}: pgvigil {o} against the hand read {h}")
for host, want in (('pgvc_h1', 5), ('pgvc_h2', 3)):
    if ours.get(('host', host), (0, 0))[0] != want: bad.append(f"D host {host}: {ours.get(('host', host))}, want {want}")
pm = {}
for l in open(f"{d}/pm-sessions.out"):
    p = l.strip().split('|')
    if len(p) >= 5 and p[1].isdigit(): pm[p[0]] = (int(p[1]), int(p[3]))
# PerformanceMonitor's read counts its own reading session (it leaves out only 'PerformanceMonitor%'): one SQLCMD more
po = {n: v for (g, n), v in ours.items() if g == 'program'}
for n, (c, sl) in pm.items():
    if n.startswith('pgvigil'): continue
    oc = po.get(n, (0, 0))[0] + (1 if n == 'SQLCMD' else 0)
    if oc != c: bad.append(f"D application {n}: pgvigil {po.get(n)} (+1 for PerformanceMonitor's own reading session) against PerformanceMonitor's {c}")
if not pm: bad.append("D PerformanceMonitor's read returned nothing")
tot = q(f"SELECT sessions, sleeping, background, databases FROM pgvigil.mssql_session_summary WHERE instance_id = {sb} AND snapshot_at = {at}")[0]
h = open(f"{d}/hand-total.out").read().strip().split('|')
# PerformanceMonitor's totals are over the sessions over 50. The hand read ran after pgvigil's and leaves its own
# session out; pgvigil's own session (running, in master) was one of pgvigil's
hdb = set(h[3].split(',')) if len(h) > 3 and h[3] else set()
# databases by id (a background session's database can have no name, which STRING_AGG would drop); pgvigil's own is master (1)
if (int(tot[0]), int(tot[1]), int(tot[2]), int(tot[3])) != (int(h[0]) + 1, int(h[1]), int(h[2]), len(hdb | {'1'})):
    bad.append(f"D totals (sessions, sleeping, background, databases): pgvigil {tot} against the hand read {h[:3]} + pgvigil's own session and database ids {sorted(hdb | {'1'})}")
tmp = q(f"SELECT t.session_id || '|' || t.alloc_kb || '|' || t.current_kb || '|' || t.user_kb FROM pgvigil.mssql_session_tempdb t WHERE t.instance_id = {sb} AND t.snapshot_at = {at} AND t.host_name = 'pgvc_tmp'")
ht = open(f"{d}/hand-tmp.out").read().strip()
if not tmp or '|'.join(tmp[0]) != ht: bad.append(f"D the idle temp table session: pgvigil {tmp} against the hand read {ht}")
for b in bad: print('DIFF', b)
print(f"D: hosts {sorted((n, v) for (g, n), v in ours.items() if g == 'host')}; applications {po}; PerformanceMonitor's {pm}; totals {tot} / hand {h}; tempdb {ht}")
sys.exit(1 if bad else 0)
PYEND
killhost 'pgvc[_]h%'
echo "ok   D: the groups per host and database equal a hand read, per application PerformanceMonitor's own read; the totals; the idle session's tempdb equals sys.dm_db_session_space_usage"

echo "== E. CPU pressure =="
NS=$(sq "SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE'")
for i in $(seq 1 $(( NS * 3 ))); do hold pgvc_cpu pgvcpu "DECLARE @i bigint = 0, @t datetime2 = SYSDATETIME(); WHILE DATEDIFF(second, @t, SYSDATETIME()) < 100 SET @i += 1;"; done
seen 'pgvc[_]cpu' $(( NS * 3 )) "E: the CPU-bound sessions"
sleep 10
col mssql_requests mssql_cpu mssql_waiting_tasks
sqok "E: sp_PressureDetector logged under the burn" "EXEC dbo.sp_PressureDetector @log_to_table = 1, @log_database_name = N'pgvc_out', @log_schema_name = N'dbo', @log_table_name_prefix = N'pde';"
sq "SELECT TOP (1) CAST(threads_waiting_for_cpu AS varchar(10)) + '|' + ISNULL(high_runnable_percent, '') FROM dbo.pde_CPU ORDER BY collection_time DESC" pgvc_out >"$TMPD/pd-cpu.out" || fail "E: the logged thread row"
E1=$(pq "SELECT runnable_tasks || '|' || coalesce(runnable_pct::text, '') || '|' || coalesce(requests::text, '') || '|' || level FROM pgvigil.mssql_cpu_newest($SB, now() - interval '1 hour', now())")
echo "E: pgvigil under the burn: runnable tasks | runnable % | requests | level = $E1; sp_PressureDetector: $(cat "$TMPD/pd-cpu.out")"
IFS='|' read -r ERT EPCT EREQ ELVL <<<"$E1"
(( ERT > 0 )) || fail "E: no runnable task in pgvigil's read under the burn"
python3 -c "import sys; p=float(sys.argv[1] or 0); n=int(sys.argv[2] or 0); sys.exit(0 if p >= 10 and n >= 4 else 1)" "$EPCT" "$EREQ" || fail "E: runnable requests $EPCT % of $EREQ (want 10 % of 4 or more)"
IFS='|' read -r PDW PDH <"$TMPD/pd-cpu.out"
(( PDW > 0 )) && [[ "$PDH" == *"queries are waiting to get on a CPU"* ]] || fail "E: sp_PressureDetector's thread row: $PDW waiting for CPU, '$PDH'"
for _ in $(seq 1 30); do
  R=$(sq "SELECT COUNT(*) FROM (SELECT CONVERT(xml, record) AS x FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%') r
          WHERE r.x.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') >= 50")
  (( R > 0 )) && break; sleep 5
done
(( R > 0 )) || fail "E: no scheduler monitor record of 50 % or more SQL Server CPU"
col mssql_cpu
sqok "E: sp_PressureDetector logged after the burn" "EXEC dbo.sp_PressureDetector @log_to_table = 1, @log_database_name = N'pgvc_out', @log_schema_name = N'dbo', @log_table_name_prefix = N'pde2';"
sq "SELECT CONVERT(varchar(23), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), sample_time), 126) + '|' + CAST(sqlserver_cpu_utilization AS varchar(5)) FROM dbo.pde2_CPUEvents WHERE sqlserver_cpu_utilization >= 50" pgvc_out >"$TMPD/pd-events.out" || fail "E: the logged CPU events"
python3 - "$PGDSN" "$SB" "$TMPD" <<'PYEND' || fail "E: see above"
import sys, subprocess, datetime as dt
dsn, sb, d = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
ours = [(dt.datetime.fromisoformat(a.replace(' ', 'T')[:23]), int(p)) for a, p in q(f"SELECT to_char(snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS'), sql_pct FROM pgvigil.mssql_cpu_sample WHERE instance_id = {sb} AND sql_pct >= 50")]
pd = []
for l in open(f"{d}/pd-events.out"):
    p = l.strip().split('|')
    if len(p) == 2: pd.append((dt.datetime.fromisoformat(p[0][:23]), int(p[1])))
bad = []
if not pd: bad.append("E sp_PressureDetector logged no CPU event of 50 % or more")
for t, p in pd:
    if not any(abs((t - o).total_seconds()) <= 1.5 and op == p for o, op in ours): bad.append(f"E sp_PressureDetector's event {t} {p} % is not among pgvigil's records {ours}")
for b in bad: print('DIFF', b)
print(f"E: CPU events at 50 % or more: sp_PressureDetector {pd}, pgvigil {ours}")
sys.exit(1 if bad else 0)
PYEND
killhost 'pgvc[_]cpu'; stopbg
echo "ok   E: under the burn pgvigil read runnable tasks and runnable requests over 10 % of 4 or more, as sp_PressureDetector's thread row; its CPU events of 50 % or more are pgvigil's stored records"

echo "== F. a worker shortage =="
sqok "F: max worker threads 128" "EXEC sp_configure 'max worker threads', 128; RECONFIGURE;"
[[ "$(sq "SELECT max_workers_count FROM sys.dm_os_sys_info")" == 128 ]] || fail "F: max worker threads did not take"
B=$(for i in $(seq 1 90); do printf "WAITFOR DELAY '00:00:02';\nGO\n"; done)
for i in $(seq 1 200); do churn pgvc_churn "$B"; done
sleep 25
dacq() { dac "SELECT CAST(SUM(work_queue_count) AS varchar(10)) + '|' + (SELECT CAST(COUNT(*) AS varchar(10)) FROM sys.dm_os_waiting_tasks WHERE wait_type = N'THREADPOOL') FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE'"; }
D0=$(dacq) || fail "F: the DAC read before"
t0=$(date +%s); col mssql_cpu mssql_waiting_tasks mssql_requests; t1=$(date +%s)
D1=$(dacq) || fail "F: the DAC read after"
dac "EXEC dbo.sp_PressureDetector @what_to_check = 'cpu', @skip_queries = 1, @log_to_table = 1, @log_database_name = N'pgvc_out', @log_schema_name = N'dbo', @log_table_name_prefix = N'pdf';" >"$TMPD/pdf.out" 2>&1 || true
PDF=$(dac "SELECT TOP (1) CAST(requests_waiting_for_threads AS varchar(10)) + '|' + CAST(total_threads AS varchar(10)) FROM pgvc_out.dbo.pdf_CPU ORDER BY collection_time DESC" 2>&1 || true)
F1=$(pq "SELECT work_queue || '|' || max_workers || '|' || coalesce(threadpool::text, 'NULL') || '|' || level || '|' || pm_level FROM pgvigil.mssql_cpu_newest($SB, now() - interval '1 hour', now())")
echo "F: the DAC before (work queue | THREADPOOL) $D0, after $D1; pgvigil's three collections took $(( t1 - t0 )) s; pgvigil work queue | max workers | THREADPOOL | level | PerformanceMonitor = $F1; sp_PressureDetector over the DAC (requests waiting for threads | total threads) $PDF"
IFS='|' read -r FWQ FMAX FTP FLVL FPM <<<"$F1"
IFS='|' read -r DQ0 _ <<<"$D0"; IFS='|' read -r DQ1 _ <<<"$D1"
(( DQ0 > 0 && DQ1 > 0 )) || fail "F: the DAC saw no queue around pgvigil's reads ($D0 / $D1)"
(( FWQ > 0 )) && [[ "$FMAX" == 128 && "$FTP" != NULL ]] && (( FTP > 0 )) && [[ "$FLVL" == HIGH ]] || fail "F: pgvigil's read of the shortage: $F1"
IFS='|' read -r PDQ PDT <<<"$PDF"
[[ "$PDT" == 128 ]] && (( PDQ > 0 )) || fail "F: sp_PressureDetector over the DAC: $PDF"
killhost 'pgvc[_]churn'; stopbg; sleep 5
# a standing shortage: every worker held behind one lock. s177i-9's login got in with 27 tasks queued (its DAC read had
# only the total) and s177i-6's was refused with 10: why is not established (a hypothesis: a login put on a scheduler
# with a worker of its own to spare). So 250 sessions wait on the lock (about twice the workers), each attempt waits up
# to 60 s for every online scheduler to have a queue, up to three attempts are made, and each prints its scheduler
# state and a row per scheduler (id:queued/workers/active/load factor).
hold pgvc_lock pgvcpu "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1;"
sleep 3
for i in $(seq 1 250); do hold pgvc_blk pgvcpu "SELECT v FROM dbo.t WHERE id = 1;"; done
sleep 25
# online schedulers | with a queue | with a worker not active (idle or preemptive) and no queue | queued tasks | workers |
# active workers
dacs() { dac "SELECT CAST(COUNT(*) AS varchar(10)) + '|' + CAST(SUM(CASE WHEN work_queue_count > 0 THEN 1 ELSE 0 END) AS varchar(10)) + '|'
  + CAST(SUM(CASE WHEN work_queue_count = 0 AND current_workers_count > active_workers_count THEN 1 ELSE 0 END) AS varchar(10)) + '|'
  + CAST(SUM(work_queue_count) AS varchar(10)) + '|' + CAST(SUM(current_workers_count) AS varchar(10)) + '|' + CAST(SUM(active_workers_count) AS varchar(10))
  FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE'"; }
dacrows() { dac "SELECT CAST(STRING_AGG(CONCAT(scheduler_id, ':', work_queue_count, '/', current_workers_count, '/', active_workers_count, '/', load_factor), ' ')
  WITHIN GROUP (ORDER BY scheduler_id) AS varchar(2000)) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE'"; }
FAILED=0; QALLIN=0; FST=()
for att in 1 2 3; do
  QALL=0; FEND=$(( SECONDS + 60 ))
  while :; do
    DS=$(dacs) || fail "F: the DAC read of the standing shortage"
    IFS='|' read -r SCN SCQ _ <<<"$DS"
    (( SCQ == SCN )) && { QALL=1; break; }
    (( SECONDS >= FEND )) && break; sleep 2
  done
  DR=$(dacrows) || DR='(the per-scheduler read failed)'
  timeout 120 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance sqlbox -once mssql_cpu >"$TMPD/col-fail.out" 2>&1 && FLOGIN=in || FLOGIN=failed
  FWHY=$(grep -m1 'collection failed' "$TMPD/col-fail.out" || tail -1 "$TMPD/col-fail.out")
  FST+=("attempt $att: every scheduler queued=$QALL; schedulers | with a queue | a worker not active, no queue | queued | workers | active = $DS; per scheduler $DR; the collection $FLOGIN ($(cut -c1-200 <<<"$FWHY"))")
  [[ $FLOGIN == failed ]] && { FAILED=1; break; }
  (( QALL )) && QALLIN=1
  sleep 5
done
printf 'F: the standing shortage, %s\n' "${FST[@]}"
CF=$(pq "SELECT count(*) || '|' || coalesce(max(left(note, 120)), '') FROM pgvigil.mssql_connect_failures_between($SB, now() - interval '10 minutes', now())")
echo "F: connect failures logged: $CF"
killhost 'pgvc[_]%'; stopbg; sleep 5
sqok "F: max worker threads back to 0" "EXEC sp_configure 'max worker threads', 0; RECONFIGURE;"
if (( FAILED )); then
  (( ${CF%%|*} >= 1 )) && [[ "$CF" == *"|connect: "* ]] || fail "F: a failed collection left no connect failure ($CF; $(tail -2 "$TMPD/col-fail.out"))"
  FSTAND="under the standing shortage pgvigil's collection could not connect and the failure was logged ($CF)"
else
  if (( QALLIN )); then
    echo "NOT PROVEN live: the standing shortage let pgvigil's login in on all three attempts, at least one with every scheduler queued (the states above): a monitor's login is not reliably refused by a worker shortage; the CPU page's note is proven on a stored connect failure"
  else
    echo "NOT PROVEN live: the standing shortage never queued every scheduler and pgvigil's login got in on all three attempts (the states above: a set-up shortfall, not a finding about logins); the CPU page's note is proven on a stored connect failure"
  fi
  pq "SELECT pgvigil.import_connect_failure('sqlbox', 'mssql_cpu', now(), 20000, 'read tcp: i/o timeout (stored by the proof)')" >/dev/null
  CF=$(pq "SELECT count(*) || '|' || coalesce(max(left(note, 120)), '') FROM pgvigil.mssql_connect_failures_between($SB, now() - interval '10 minutes', now())")
  [[ "${CF%%|*}" == 1 && "$CF" == *"|connect: "* ]] || fail "F: the stored connect failure is not read back ($CF)"
  FSTAND="NOT PROVEN live: the standing shortage let the login in 3 times; a stored connect failure read back"
fi
echo "ok   F: pgvigil read the churning shortage itself (work queue $FWQ, THREADPOOL $FTP, max workers 128, level HIGH, PerformanceMonitor '$FPM') between DAC reads that saw a queue; sp_PressureDetector over the DAC saw $PDQ request(s) waiting for threads; $FSTAND"

echo "== G. the rules on stored rows =="
python3 - "$PGDSN" <<'PYEND' || fail "G: the levels table"
import sys, subprocess
dsn = sys.argv[1]
def q(s): return subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.strip()
# (runnable, schedulers, work queue, current, max, CPUs, queued) -> pgvigil level, PerformanceMonitor level, its recommendation
cases = [
  ((0, 4, 0, 10, 512, 4, 0), 'NORMAL', 'NORMAL', 'No CPU scheduler pressure detected'),
  ((1, 4, 0, 10, 512, 4, 0), 'ELEVATED', 'NORMAL', 'No CPU scheduler pressure detected'),
  ((4, 4, 0, 10, 512, 4, 0), 'HIGH', 'HIGH - Runnable tasks warning', 'No CPU scheduler pressure detected'),
  ((10, 64, 0, 10, 2000, 64, 0), 'NORMAL', 'NORMAL', 'No CPU scheduler pressure detected'),
  ((11, 64, 0, 10, 2000, 64, 0), 'NORMAL', 'MEDIUM - Some runnable tasks queued', 'No CPU scheduler pressure detected'),
  ((21, 64, 0, 10, 2000, 64, 0), 'ELEVATED', 'HIGH - Moderate runnable task queue', 'CPU pressure detected - check for CPU-intensive queries, consider adding CPU cores'),
  ((51, 64, 0, 10, 2000, 64, 0), 'ELEVATED', 'CRITICAL - High runnable task queue', 'CPU pressure detected - check for CPU-intensive queries, consider adding CPU cores'),
  ((15, 64, 0, 10, 2000, 64, 0), 'NORMAL', 'MEDIUM - Some runnable tasks queued', 'No CPU scheduler pressure detected'),
  ((16, 64, 0, 10, 2000, 64, 0), 'ELEVATED', 'MEDIUM - Some runnable tasks queued', 'No CPU scheduler pressure detected'),
  ((64, 64, 0, 10, 2000, 64, 0), 'HIGH', 'CRITICAL - High runnable task queue', 'CPU pressure detected - check for CPU-intensive queries, consider adding CPU cores'),
  ((0, 4, 1, 10, 512, 4, 0), 'HIGH', 'NORMAL', 'No CPU scheduler pressure detected'),
  ((0, 4, 0, 410, 512, 4, 0), 'ELEVATED', 'NORMAL', 'No CPU scheduler pressure detected'),
  ((0, 4, 0, 461, 512, 4, 0), 'ELEVATED', 'HIGH - Worker thread exhaustion', 'Worker thread exhaustion - check max worker threads setting'),
  ((0, 4, 0, 460, 512, 4, 0), 'ELEVATED', 'NORMAL', 'No CPU scheduler pressure detected'),
  ((0, 4, 0, 461, 512, 4, 0), 'ELEVATED', 'HIGH - Worker thread exhaustion', 'Worker thread exhaustion - check max worker threads setting'),
  ((0, 4, 0, 10, 512, 4, 4), 'NORMAL', 'MEDIUM - Queued requests warning', 'Requests queued for execution - CPU or worker thread pressure'),
  ((0, 4, 0, 10, 512, 4, 3), 'NORMAL', 'NORMAL', 'Requests queued for execution - CPU or worker thread pressure'),
]
# pgvigil's level on the page's rounded figures (worker use to 1 place, runnable per scheduler to 2) [review s177i-review11]
cases.append(((0, 4, 0, 563, 704, 4, 0), 'ELEVATED', 'NORMAL', 'No CPU scheduler pressure detected'))
cases.append(((199, 200, 0, 10, 5000, 200, 0), 'HIGH', 'CRITICAL - High runnable task queue', 'CPU pressure detected - check for CPU-intensive queries, consider adding CPU cores'))
# exactly 90 % of max: PerformanceMonitor's flag (>= 90 %) without its > 90 % band
cases.append(((0, 4, 0, 900, 1000, 4, 0), 'ELEVATED', 'CRITICAL - Worker thread exhaustion warning', 'Worker thread exhaustion - check max worker threads setting'))
bad = []
for args, lv, pml, pmr in cases:
    got = q("SELECT level || '|' || pm_level || '|' || pm_recommendation FROM pgvigil.mssql_sched_levels(%s)" % ', '.join(map(str, args)))
    if got != f"{lv}|{pml}|{pmr}": bad.append(f"G levels {args}: {got}, want {lv}|{pml}|{pmr}")
for b in bad: print('DIFF', b)
print(f"G: {len(cases)} cases of mssql_sched_levels")
sys.exit(1 if bad else 0)
PYEND
fnd() { pq "SELECT count(*) FROM pgvigil.mssql_cpu_findings WHERE instance_id = $SB AND check_name = '$1'"; }
for tb in mssql_cpu_sample mssql_fileio_sample mssql_job_runs; do pq "SELECT pgvigil.ensure_month_partition('$tb', now())" >/dev/null; done
pq "SELECT pgvigil.ensure_month_partition('mssql_job_runs', now() - interval '21 days')" >/dev/null
oth() { pq "DELETE FROM pgvigil.mssql_cpu_sample WHERE instance_id = $SB AND record_id >= 900000" >/dev/null
  pq "INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct) SELECT $SB, now() - make_interval(secs => g * 60), 900000 + g, 10, $1, 90 - $1 FROM generate_series(1, $2) g" >/dev/null; }
oth 50 10; O1=$(fnd 'other processes use the CPU'); oth 49 10; O2=$(fnd 'other processes use the CPU'); oth 60 9; O3=$(fnd 'other processes use the CPU')
pq "DELETE FROM pgvigil.mssql_cpu_sample WHERE instance_id = $SB AND record_id >= 900000" >/dev/null
[[ "$O1" == 1 && "$O2" == 0 && "$O3" == 0 ]] || fail "G: other processes: 50 % x10 $O1 (want 1), 49 % x10 $O2 (want 0), 60 % x9 $O3 (want 0)"
TS=$(pq "SELECT now() + interval '1 minute'")
pq "SELECT pgvigil.mssql_ensure_day_partition('mssql_requests', '$TS')" >/dev/null   # mssql_requests is partitioned by day
pq "INSERT INTO pgvigil.mssql_requests_summary (instance_id, snapshot_at, source) VALUES ($SB, '$TS', 'dmv')" >/dev/null
trq() { pq "DELETE FROM pgvigil.mssql_requests WHERE instance_id = $SB AND snapshot_at = '$TS'" >/dev/null
  pq "INSERT INTO pgvigil.mssql_requests (instance_id, snapshot_at, session_id, status, tran_start, login_name, program_name) VALUES ($SB, '$TS', 4242, '$1', '$TS'::timestamptz - interval '$2', 'proof', 'proof')" >/dev/null
  pq "SELECT coalesce(max(severity), 'none') FROM pgvigil.mssql_cpu_findings WHERE instance_id = $SB AND check_name = 'a transaction open for a long time'"; }
T1=$(trq sleeping '30 minutes'); T2=$(trq sleeping '29 minutes'); T3=$(trq sleeping '4 hours'); T4=$(trq running '4 hours'); T5=$(trq running '3 hours 59 minutes'); T6=$(trq running '30 hours')
pq "DELETE FROM pgvigil.mssql_requests WHERE instance_id = $SB AND snapshot_at = '$TS'; DELETE FROM pgvigil.mssql_requests_summary WHERE instance_id = $SB AND snapshot_at = '$TS'" >/dev/null
[[ "$T1/$T2/$T3/$T4/$T5/$T6" == "warning/none/critical/warning/none/warning" ]] || fail "G: a long transaction: idle 30 min $T1, idle 29 min $T2, idle 4 h $T3, running 4 h $T4, running 3 h 59 $T5, running 30 h $T6 (want warning/none/critical/warning/none/warning)"
wr() { pq "DELETE FROM pgvigil.mssql_fileio_sample WHERE instance_id = $SB AND database_name = 'pgvproof'" >/dev/null
  pq "INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc, reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs) VALUES ($SB, now() - interval '5 minutes', 999, 1, 'pgvproof', 'pgvproof_data', 'ROWS', 0, 0, 0, $1, $1 * 8192, $2, 60)" >/dev/null
  fnd 'slow data file writes'; }
W1=$(wr 1000 100100); W2=$(wr 1000 100000); W3=$(wr 999 999000)
pq "DELETE FROM pgvigil.mssql_fileio_sample WHERE instance_id = $SB AND database_name = 'pgvproof'" >/dev/null
[[ "$W1/$W2/$W3" == "1/0/0" ]] || fail "G: slow data file writes: 100.1 ms x1000 $W1, 100 ms x1000 $W2, 1000 ms x999 $W3 (want 1/0/0)"
echo "ok   G: the levels table; other processes 50 % x10 raises, 49 % or 9 records none; a long transaction idle 30 min warning, 29 min none, 4 h critical, running 4 h warning, 3 h 59 none, 30 h warning; slow data file writes 100.1 ms over 1,000 writes raises, 100 ms or 999 writes none"

echo "== H. the API under pgvigil serve =="
(cd web && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "H: the web build"; }
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "H: user add"
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.out" >&2; fail "H: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "H: the API login"
FISO=$(pq "SELECT to_char((min(snapshot_at) - interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM pgvigil.mssql_sched_sample WHERE instance_id = $SB")
TISO=$(pq "SELECT to_char((now() + interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
PICK=$(pq "SELECT min(series_id) FROM pgvigil.mssql_counter_series WHERE instance_id = $SB AND counter = 'Batch Requests/sec'")
for ep in cpu connections fileio; do curl -fs -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/$ep?instance=$SB&from=$FISO&to=$TISO" >"$TMPD/api-$ep.json" || fail "H: GET /api/mssql/$ep"; done
curl -fs -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/counters?instance=$SB&from=$FISO&to=$TISO&series=$PICK" >"$TMPD/api-counters.json" || fail "H: GET /api/mssql/counters"
curl -fs -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/tempdb?instance=$SB" >"$TMPD/api-tempdb.json" || fail "H: GET /api/mssql/tempdb"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/counters?instance=$SB&series=1,2,3,4,5,6,7,8,9,10,11")" == 400 ]] || fail "H: eleven series were not refused"
python3 - "$TMPD" "$PGDSN" "$SB" "$FISO" "$TISO" "$PICK" <<'PYEND' || fail "H: see above"
import sys, json, subprocess
d, dsn, sb, f, t, pick = sys.argv[1:]
def n(q): return int(subprocess.run(['psql', dsn, '-XAtq', '-c', q], check=True, capture_output=True, text=True).stdout.strip())
def cnt(j, part):
    x = j.get(part)
    if x is None: return None
    return len(x.get('rows', x) if isinstance(x, dict) else x)
w = f"{sb}, '{f}', '{t}'"
want = {'cpu': {'newest': f"SELECT count(*) FROM pgvigil.mssql_cpu_newest({w})", 'threadpool': f"SELECT count(*) FROM pgvigil.mssql_threadpool_newest({w})",
                'connectfail': f"SELECT count(*) FROM pgvigil.mssql_connect_failures_between({w})"},
        'connections': {'summary': f"SELECT count(*) FROM pgvigil.mssql_session_newest({w})", 'series': f"SELECT count(*) FROM pgvigil.mssql_session_series_between({w})",
                        'applications': f"SELECT count(*) FROM pgvigil.mssql_session_groups_newest({w}, 'program')",
                        'hosts': f"SELECT count(*) FROM pgvigil.mssql_session_groups_newest({w}, 'host')",
                        'databases': f"SELECT count(*) FROM pgvigil.mssql_session_groups_newest({w}, 'database')"},
        'counters': {'now': f"SELECT count(*) FROM pgvigil.mssql_counter_newest({w})",
                     'series': f"SELECT count(*) FROM pgvigil.mssql_counter_series_between({w}, (SELECT step_secs FROM (SELECT greatest(60, (extract(epoch FROM '{t}'::timestamptz - '{f}'::timestamptz) / 120)::int) AS step_secs) s), ARRAY[{pick}])"},
        'fileio': {'logflush': f"SELECT count(*) FROM pgvigil.mssql_log_flush_between({w})"},
        'tempdb': {'holders': f"SELECT count(*) FROM pgvigil.mssql_session_tempdb_newest({sb}, now() - interval '15 minutes', now())"}}
bad = []
for ep, parts in want.items():
    j = json.load(open(f"{d}/api-{ep}.json"))
    for p, qq in parts.items():
        if cnt(j, p) != n(qq): bad.append(f"H {ep} {p}: the API {cnt(j, p)} rows, the function {n(qq)}")
    print(f"H {ep}: " + ', '.join(f"{p} {cnt(j, p)}" for p in sorted(j)))
for b in bad: print('DIFF', b)
sys.exit(1 if bad else 0)
PYEND
echo "ok   H: every D14 part answers, the counted ones equal to their functions; eleven series refused (400)"

echo "== I. the pages in headless Chromium =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
setsid chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1100 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "I: chromium's CDP port never answered"
cat > "$TMPD/i.mjs" <<'JS'
// prints one line per check; the shell grades them
const [port, U, sb, from, to, shots, mode] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0 && !!m.querySelector('h2') && !m.querySelector('[role=status]')?.textContent?.startsWith('Reading'); })()`); if (ok) { await sleep(700); return true; } await sleep(200); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
const w = `i=${sb}&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
const pages = { cpu: `#/mssqlcpu?${w}`, connections: `#/mssqlconnections?${w}`, metrics: `#/counters?${w}`, tempdb: `#/mssqltempdb?i=${sb}`, fileio: `#/mssqlfileio?${w}`, jobs: `#/mssqljobs?${w}` };
const state = () => ev(`(() => { const m = document.querySelector('main');
  const h3 = t => [...m.querySelectorAll('h3')].find(x => x.textContent.startsWith(t));
  // a chart's legend is a table too (uPlot's .u-legend): only a grid counts
  const isGrid = x => x.tagName === 'TABLE' ? !x.classList.contains('u-legend') : [...x.querySelectorAll('table')].some(tb => !tb.classList.contains('u-legend'));
  const rowsAfter = (t) => { const h = h3(t); if (!h) return -1; let g = h.nextElementSibling; while (g && !isGrid(g) && g.tagName !== 'H3') g = g.nextElementSibling; return g && g.tagName !== 'H3' ? [...g.querySelectorAll('tbody tr')].filter(tr => !tr.closest('.u-legend') && !tr.querySelector('.empty')).length : 0; };
  const attr = (a) => { const e = m.querySelector('[' + a + ']'); return e ? e.getAttribute(a) : null; };
  return JSON.stringify({ hash: location.hash, title: m.querySelector('h2')?.textContent ?? '', errors: m.querySelectorAll('.error:not([role=status])').length,
    verdict: attr('data-verdict'), pm: attr('data-pm-level'), threadpool: attr('data-threadpool'), cpuinfo: attr('data-cpuinfo'), connectfail: attr('data-connectfail'),
    runpct: attr('data-runnable-pct'), threadRows: rowsAfter('Thread usage'), tiles: m.querySelectorAll('.tile').length,
    apps: rowsAfter('Sessions by application'), hosts: rowsAfter('Sessions by host'), dbs: rowsAfter('Sessions by database'),
    counters: m.querySelector('.mssql-counters') ? [...m.querySelectorAll('.mssql-counters tbody tr')].filter(tr => !tr.closest('.u-legend') && !tr.querySelector('.empty')).length : -1,
    checked: [...m.querySelectorAll('.mssql-counters input[type=checkbox]')].filter(c => c.checked).length,
    counterChart: !!m.querySelector('.mssql-counters .uplot'), holders: rowsAfter('Sessions holding tempdb'),
    kb: [...m.querySelectorAll('th')].filter(th => /KB per (read|write)/.test(th.textContent)).length, logflush: rowsAfter('Log bytes flushed per database'),
    p95: [...m.querySelectorAll('th')].some(th => /p95 of its good runs/.test(th.textContent)),
    jobRow: [...m.querySelectorAll('tbody tr')].map(tr => tr.textContent).filter(x => x.includes('pgvproof job')).join(' / ').slice(0, 300),
    links: [...m.querySelectorAll('a[href]')].map(a => ({ t: a.textContent.trim(), h: a.getAttribute('href') })),
    controls: [...m.querySelectorAll('input, button, select')].length }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.I_USR)}, password: ${JSON.stringify(process.env.I_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
// the early walk: TempDB and File IO before their own collections ran, in light only
if (mode === 'early') {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', 'light'); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  // a fresh document after the login, as the main walk (a hash change alone keeps the page loaded before it)
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  for (const name of ['tempdb', 'fileio']) {
    if (!await go(pages[name])) { console.log(`FAIL render ${name}-early light`); continue; }
    const s = await state(); delete s.links;
    console.log(`page ${name}-early light ${JSON.stringify(s)}`);
    await shot(`d14-${name}-early-light`);
  }
  ws.close(); process.exit(0);
}
for (const theme of ['light', 'dark']) {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  for (const [name, hash] of Object.entries(pages)) {
    if (!await go(hash)) { console.log(`FAIL render ${name} ${theme}`); continue; }
    if (name === 'metrics') await sleep(1500);
    const s = await state(); delete s.links;
    console.log(`page ${name} ${theme} ${JSON.stringify(s)}`);
    await shot(`d14-${name}-${theme}`);
  }
}
// the Metrics page: a box checked and cleared redraws the chart; the eleventh is refused by the page
await go(pages.metrics); await sleep(1500);
const pick = await ev(`(async () => { const bs = [...document.querySelectorAll('.mssql-counters input[type=checkbox]')]; const off = bs.find(b => !b.checked); if (!off) return 'none';
  off.click(); await new Promise(r => setTimeout(r, 1500)); const a = bs.filter(b => b.checked).length; off.click(); await new Promise(r => setTimeout(r, 1500));
  return a + '|' + bs.filter(b => b.checked).length + '|' + !!document.querySelector('.mssql-counters .uplot'); })()`, true);
console.log(`metrics pick ${pick}`);
// every link and every control of the CPU and Connections pages, each clicked once, with its landing
for (const name of ['cpu', 'connections']) {
  await go(pages[name]);
  const links = (await state()).links; const seen = new Set();
  for (const l of links) {
    if (seen.has(l.h)) continue; seen.add(l.h);
    if (!l.h.startsWith('#')) { console.log(`click link ${name} ${JSON.stringify(l.t)} ${l.h} -> external (not followed)`); continue; }
    const ok = await go(l.h); const r = await state();
    console.log(`click link ${name} ${JSON.stringify(l.t)} ${l.h} -> ${r.hash} title=${JSON.stringify(r.title)} errors=${r.errors} rendered=${ok} same=${r.hash.split('?')[0] === l.h.split('?')[0]}`);
    await go(pages[name]);
  }
  await go(pages[name]);
  const n = (await state()).controls;
  for (let i = 0; i < n; i++) {
    const what = await ev(`(() => { const c = [...document.querySelector('main').querySelectorAll('input, button, select')][${i}]; if (!c) return null;
      const lab = (c.closest('label')?.textContent || c.getAttribute('aria-label') || c.textContent || c.title || c.name || c.tagName).trim().slice(0, 60);
      const t = c.tagName === 'INPUT' ? c.type : c.tagName.toLowerCase();
      if (t === 'checkbox') { c.click(); c.click(); } else if (t === 'select') { c.dispatchEvent(new Event('change', { bubbles: true })); } else { c.click(); }
      return JSON.stringify({ t, lab }); })()`);
    if (!what) { console.log(`click control ${name} ${i} gone`); continue; }
    await sleep(400);
    const dlg = await ev(`(() => { const d = document.querySelector('dialog[open]'); if (d) { d.close(); return true; } return false; })()`);
    const r = await state(); const wv = JSON.parse(what);
    console.log(`click control ${name} ${i} ${wv.t} ${JSON.stringify(wv.lab)} -> ${r.hash.split('?')[0]} dialog=${dlg} errors=${r.errors}`);
    if (r.hash.split('?')[0] !== pages[name].split('?')[0]) await go(pages[name]);
  }
}
ws.close(); process.exit(0);
JS
# the early path: TempDB and File IO before mssql_tempdb (hourly) and mssql_fileio (every minute) read: D14's sections
# (the tempdb holders, the log flushes) are mssql_activity's and still show. A fresh session holding tempdb and a fresh
# mssql_activity read first (D's holder was killed in F), the early walk over its own window end, the holders counted
# right after it
hold pgvc_tmpi pgvcpu "CREATE TABLE #held (id int, pad char(2000)); INSERT #held SELECT TOP (600) object_id, 'x' FROM sys.all_objects;"
seen 'pgvc[_]tmpi' 1 "I: the session holding tempdb"
sleep 3
col mssql_activity
TISO_E=$(pq "SELECT to_char((now() + interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
early=$(I_USR="$USR" I_UPW="$UPW" node "$TMPD/i.mjs" "$CDP" "$U/" "$SB" "$FISO" "$TISO_E" "$SHOTS" early) || fail "I: the early walk stopped: $early"
EH=$(pq "SELECT count(*) FROM pgvigil.mssql_session_tempdb_newest($SB, now() - interval '15 minutes', now())")
# then the reads a running pgvigil has made by now: mssql_jobs (msdb), mssql_tempdb, two mssql_fileio reads around a
# write (the first sets the baseline)
col mssql_jobs mssql_tempdb mssql_fileio
sqok "I: a write between the file reads" "UPDATE dbo.t SET v = v + 1; CHECKPOINT;" pgvcpu
sleep 2
col mssql_fileio
# a running job with stored runs after mssql_jobs's own read, so Running now draws its p95 and % of average (SQL Agent
# is off in the container)
pq "INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, name, snapshot_at, running_since) VALUES ($SB, '00000000-0000-0000-0000-00000000d014', 'pgvproof job', now(), now() - interval '150 seconds')" >/dev/null 2>&1 || echo "I: the stored running job could not be written (the Jobs page check is skipped)"
pq "INSERT INTO pgvigil.mssql_job_runs (instance_id, history_id, job_id, step_id, run_status, duration_s, snapshot_at) SELECT $SB, 9000000 + g, '00000000-0000-0000-0000-00000000d014', 0, 1, g * 10, now() - make_interval(days => g) FROM generate_series(1, 20) g" >/dev/null || fail "I: the stored job runs"
JP=$(pq "SELECT round(avg(duration_s)) || '|' || round(percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_s)::numeric) FROM pgvigil.mssql_job_runs WHERE instance_id = $SB AND step_id = 0 AND run_status = 1" 2>/dev/null || echo '|')
TISO=$(pq "SELECT to_char((now() + interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
out=$(I_USR="$USR" I_UPW="$UPW" node "$TMPD/i.mjs" "$CDP" "$U/" "$SB" "$FISO" "$TISO" "$SHOTS") || fail "I: the Chromium walk stopped: $out"
out="$early"$'\n'"$out"
echo "$out" | grep -v '^click control'
echo "$out" | grep -q '^login 200$' || fail "I: the UI login in Chromium"
! echo "$out" | grep -q '^FAIL' || fail "I: a page did not render: $(echo "$out" | grep '^FAIL' | head -3)"
python3 - "$PGDSN" "$SB" "$FISO" "$TISO" "$JP" "$out" "$TISO_E" "$EH" <<'PYEND' || fail "I: see above"
import sys, json, subprocess
dsn, sb, f, t, jp, out, te_end, eh = sys.argv[1:]
def q(s): return subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.strip()
w = f"{sb}, '{f}', '{t}'"
lv, pm = q(f"SELECT level || '|' || pm_level FROM pgvigil.mssql_cpu_newest({w})").split('|')
want_now = int(q(f"SELECT count(*) FROM pgvigil.mssql_counter_newest({w})"))
grp = {g: int(q(f"SELECT count(*) FROM pgvigil.mssql_session_groups_newest({w}, '{g}')")) for g in ('program', 'host', 'database')}
holders = int(q(f"SELECT count(*) FROM pgvigil.mssql_session_tempdb_newest({sb}, now() - interval '15 minutes', now())"))
flushes = int(q(f"SELECT count(*) FROM pgvigil.mssql_log_flush_between({w})"))
flushes_e = int(q(f"SELECT count(*) FROM pgvigil.mssql_log_flush_between({sb}, '{f}', '{te_end}')"))
pages = {}
for l in out.splitlines():
    if l.startswith('page '):
        _, name, theme, js = l.split(' ', 3); pages[(name, theme)] = json.loads(js)
bad = []
for theme in ('light', 'dark'):
    g = lambda n: pages.get((n, theme), {})
    c = g('cpu')
    if c.get('verdict') != lv or c.get('pm') != pm or c.get('threadRows') != 1 or c.get('threadpool') is None or not c.get('cpuinfo') or c.get('cpuinfo') == '0' \
       or not c.get('connectfail') or c.get('errors') != 0: bad.append(f"I cpu {theme}: {c} (want verdict {lv}, PerformanceMonitor {pm}, a thread row, THREADPOOL, CPU details, the connect-failure note)")
    k = g('connections')
    if (k.get('apps'), k.get('hosts'), k.get('dbs')) != (grp['program'], grp['host'], grp['database']) or k.get('tiles', 0) < 11 or k.get('errors') != 0:
        bad.append(f"I connections {theme}: {k} (want {grp}, 11 tiles)")
    m = g('metrics')
    if m.get('counters') != want_now or m.get('checked', 0) < 4 or not m.get('counterChart') or m.get('errors') != 0: bad.append(f"I metrics {theme}: {m} (want {want_now} counter rows, the default series checked and charted)")
    td = g('tempdb')
    if td.get('holders') != holders or holders < 1 or td.get('errors') != 0: bad.append(f"I tempdb {theme}: {td} (want {holders} holders, at least 1)")
    fi = g('fileio')
    if fi.get('kb') != 2 or fi.get('logflush') != flushes or flushes < 1 or fi.get('errors') != 0: bad.append(f"I fileio {theme}: {fi} (want the KB per read and per write columns, {flushes} log flush rows)")
    jb = g('jobs')
    if jp != '|' and (not jb.get('p95') or 'pgvproof job' not in jb.get('jobRow', '')): bad.append(f"I jobs {theme}: {jb}")
te, fe = pages.get(('tempdb-early', 'light'), {}), pages.get(('fileio-early', 'light'), {})
if te.get('holders') != int(eh) or int(eh) < 1 or te.get('errors') != 0: bad.append(f"I tempdb before its own read: {te} (want {eh} holders, at least 1)")
if fe.get('kb') != 0 or fe.get('logflush') != flushes_e or flushes_e < 1 or fe.get('errors') != 0: bad.append(f"I fileio before its own read: {fe} (want no file grid, {flushes_e} log flush rows)")
pk = [l for l in out.splitlines() if l.startswith('metrics pick ')]
if not pk or pk[0].split(' ', 2)[2].split('|')[2] != 'true': bad.append(f"I metrics pick: {pk}")
cl = [l for l in out.splitlines() if l.startswith('click ')]
if not cl: bad.append("I nothing clicked")
for l in cl:
    if 'errors=0' not in l and 'external' not in l and ' gone' not in l: bad.append(f"I {l}")
    if l.startswith('click link') and 'external' not in l and ('rendered=false' in l or 'same=false' in l): bad.append(f"I {l}")
for b in bad: print('DIFF', b)
print(f"I: verdict {lv} / PerformanceMonitor {pm}; {want_now} counter rows; groups {grp}; holders {holders}; {len(cl)} click(s); jobs (avg | p95 stored) {jp}")
sys.exit(1 if bad else 0)
PYEND
echo "$out" | grep '^click ' > "$SHOTS/d14-click-table.txt" || true
echo "ok   I: CPU, Connections, Metrics, TempDB, File IO and Jobs in light and dark as the store has them, no error box; $(grep -c . "$SHOTS/d14-click-table.txt") click(s) in the click table; shots in $SHOTS"
echo "proof-darling-cpu: OK (the counters against sp_PressureDetector's logged perfmon and hand reads; the sessions against PerformanceMonitor's own read and hand reads; CPU pressure and a worker shortage provoked and read back; the rules on stored rows; the API and the pages; the NOT PROVEN lines above stand)"
