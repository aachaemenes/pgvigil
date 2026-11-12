#!/usr/bin/env bash
# proof-darling-sysevents.sh - task 177 D15: the System health tab in the shape of PerformanceMonitor's System Events
# and sp_HealthParser (internal/mssql/syshealth.go, readers_sysevents.go; 0120; internal/web/q_mssql_errorlog.go;
# web/src/mssql_errorlog.ts), against sp_HealthParser's own output on the same server over the same window.
#
# Needs: docker, go, psql, curl, python3, node, npm, chromium; a PostgreSQL superuser in ADMIN_DSN (keyword form,
# default 'host=127.0.0.1 port=5432 user=postgres dbname=postgres'); HEALTHPARSER_SQL naming sp_HealthParser.sql
# (DarlingData, MIT; installed on the proof's own container only). PGVIGIL_SHOTS: where the shots go.
# Everything it makes carries a random suffix and is removed on every exit: the container, the database, the server.
#
# The checks (each prints 'ok' or ends the run with FAIL):
#  A. a SQL Server 2022 container; on it, provoked: a lock wait of about 38 s (system_health keeps wait_info only past
#     30 s on a lock), max server memory lowered to 2048 MB and raised again (memory broker notifications), a data file growth, a
#     DBCC command and DDL (the default trace); then system_health's file is waited on until it holds the wait, a
#     SYSTEM and a RESOURCE result written after the provocations, and scheduler monitor and memory broker events.
#  B. pgvigil reads system_health (mssql_syshealth) and the default trace (mssql_defaulttrace): both readers 'read'.
#  C. sp_HealthParser @log_to_table = 1 over the same window (@start_date / @end_date), its log tables against
#     pgvigil's rows, row for row: SignificantWaits = /api/mssql/syshealth part=waits (the provoked LCK_M_S among them);
#     MemoryBroker = part=broker; MemoryNodeOOM = part=node_oom; SchedulerIssues = every stored SCHEDULER_MONITOR sample
#     (other = 100 - SQL - idle), and part=scheduler = those past a warning; SystemHealth = the stored SYSTEM results'
#     counters (state, spinlock backoffs, sick spinlock type, latch warnings, access violations, write access
#     violations, dump requests, non-yielding, page faults, CPU, bad pages), and part=series' counters per bucket = the
#     largest of SystemHealth's values in that bucket; the RESOURCE results' new columns (available virtual, paging
#     file, % committed in the working set, page faults, system physical memory high) = a hand read of the memory
#     report in system_health's file.
#  D. the default trace's growths, DBCC commands and DDL in the window = a hand read of fn_trace_gettable under the
#     reader's own rules (defaulttrace.go), per kind, and /api/mssql/defaulttrace's grids as many rows.
#  E. the server's own scheduler monitor samples printed (their CPU, idle and memory utilization ranges) with the
#     findings they raise; pgvigil.mssql_sysevents_findings (0120) on an instance id with no real sample: seeds at other
#     processes 50 and 49 %, memory utilization 50 and 51, raise exactly the two scheduler findings with the edge figures;
#     an Extended Events state row seeded with a truncated ring buffer raises the third; in a window of their own two
#     hours ahead (its month's partition made first), seven wait_info seeds (session 0, no statement, a BACKUP, 400 ms,
#     WAITFOR, a kept one, one whose statement the text policy hid): part=waits keeps exactly 2; five scheduler samples
#     on both sides of SQL 90 / other 50 / memory 50 and two without idle (a Linux host's): part=scheduler keeps exactly
#     4, the one without idle at SQL 95 with other blank, part=scheduler_samples counts 7; on Linux the server's own
#     samples raise no 'other processes' finding, and a seed without idle raises none on the seed-only instance;
#     the seeds removed.
#  F. go test ./internal/mssql ./internal/web ./internal/repo, golangci-lint (0 issues) at the root and in app/.
#  G. `pgvigil serve`: #/mssqlhealth and #/mssqltrace in the light and the dark theme, rendered without an error box;
#     the seven counter charts (each drawn or saying no value was reported), the grids as many rows as the API; every
#     link of both pages clicked, its landing named (a wait type lands on the Waiting tasks tab with wt=); every column
#     group check box clicked, its columns in the grid's header after; shots of both pages in both themes.
# NOT PROVEN HERE: a memory node OOM event (none is provoked: the comparison is 0 = 0 unless the server raised one; the
#  parser's fields are its unit test's); a sick spinlock, bad page, dump request or access violation with a value (the
#  charts say none was reported; their per-bucket maximum is checked on the values the server wrote); the truncated ring
#  buffer read itself (E seeds the state); the scheduler monitor on a Windows host (the container is Linux: idle is
#  dropped there, so C compares idle and other blank; the reader's Linux test is TestDropLinuxIdle's function, not its
#  wiring in RunBatches); Azure SQL Managed Instance's ring buffer path; SQL Server 2016-2019; proof-a11y
#  (its own script, run beside this one).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
: "${HEALTHPARSER_SQL:?HEALTHPARSER_SQL names sp_HealthParser.sql}"
[ -f "$HEALTHPARSER_SQL" ] || { echo "FAIL: no file $HEALTHPARSER_SQL" >&2; exit 1; }
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvs-sql-$SUF; HOSTN=pgvs$SUF; LBL=pgvigil-proof=s177h
PGDB=pgv_sysev_$SUF; MON=pgv_smon_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=; BG=()
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
# sq: T-SQL as sa (stdin, never a command line); sqok: output not wanted, a failure loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
# sq and sqr run with -I (QUOTED_IDENTIFIER ON, as proof-mssql-readers' sq): xml value() refuses to run without it (Msg 1934)
# sqr: rows longer than sqlcmd's 256 characters (-y 0, which refuses -h): each row a select of 'R~' + its text, the
# header and anything else dropped
sqr() { local o rc=0; o=$(printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -y 0 -d "$0" -i /dev/stdin' "${2:-master}") || rc=$?
  if (( rc != 0 )); then echo "$o" | grep -v '^R~' | head -20 >&2; fail "sqlcmd exit $rc on: $(echo "$1" | head -c 300)"; fi
  echo "$o" | sed -n 's/^R~//p'; }
# tcols: a comma list of column names as one T-SQL text expression, each ISNULL(CONVERT(nvarchar(256), col), ''), joined by '|'
tcols() { echo "$1" | tr ',' '\n' | sed "s/.*/ISNULL(CONVERT(nvarchar(256), &), '')/" | paste -sd'#' | sed "s/#/ + '|' + /g"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
sqfile() { docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d master -i /dev/stdin' < "$1"; }
for t in docker go psql curl python3 node npm chromium git; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== build: a copy of the tree, the web bundle rebuilt =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git --exclude=./.t177h -cf - . | tar -C "$GSRC" -xf -
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "build: the web bundle"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "build: go build"
BIN=$TMPD/pgvigil

echo "== A. a SQL Server 2022 container; a long lock wait, a memory change, a growth, DBCC and DDL provoked =="
START=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '-1 minute')
docker run -d --name "$SQL" --hostname "$HOSTN" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
ready=
for _ in $(seq 1 90); do ready=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true); [[ "$ready" == 1 ]] && break; sleep 2; done
[[ "$ready" == 1 ]] || fail "A: the SQL Server container did not come up in 180 s"
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT ALTER TRACE TO [$MON];"
sqfile "$HEALTHPARSER_SQL" >"$TMPD/hp.out" 2>&1 || { tail -5 "$TMPD/hp.out" >&2; fail "A: installing sp_HealthParser"; }
HPV=$(grep -o "@version = '[0-9.]*'" "$HEALTHPARSER_SQL" | head -1 | grep -o "[0-9.]*" || true)
sqok "A: the log database" "CREATE DATABASE pgvs_hp;"
# a small database whose data file grows (1 MB at a time) under an insert, a table made and dropped (DDL)
sqok "A: the database" "CREATE DATABASE pgvs ON (NAME = pgvs, FILENAME = '/var/opt/mssql/data/pgvs.mdf', SIZE = 8MB, FILEGROWTH = 1MB)
  LOG ON (NAME = pgvs_log, FILENAME = '/var/opt/mssql/data/pgvs.ldf', SIZE = 8MB, FILEGROWTH = 8MB);"
sqok "A: the table" "CREATE TABLE dbo.pgvs_t (id int NOT NULL PRIMARY KEY, pad char(2000) NOT NULL DEFAULT 'a');
  INSERT dbo.pgvs_t (id) SELECT TOP (6000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvs
sqok "A: DDL" "CREATE TABLE dbo.pgvs_ddl (id int); DROP TABLE dbo.pgvs_ddl;" pgvs
sqok "A: DBCC" "DBCC FREEPROCCACHE WITH NO_INFOMSGS;"
# the lock wait: the head holds an X key lock for 40 s; the waiter's shared lock waits about 38 s (LCK_M_S)
sess() { printf '%s\n' "$2" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -d pgvs -H "$0" -i /dev/stdin' "$1" >"$TMPD/s-$1.out" 2>&1 & BG+=($!); }
sess pgvs_h "BEGIN TRAN; UPDATE dbo.pgvs_t SET pad = 'h' WHERE id = 1; WAITFOR DELAY '00:00:40'; COMMIT;"
for _ in $(seq 1 30); do [[ "$(sq "SELECT COUNT(*) FROM sys.dm_tran_locks l JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id WHERE s.host_name = 'pgvs_h' AND l.resource_type = 'KEY' AND l.request_mode = 'X'")" == 1 ]] && break; sleep 1; done
sess pgvs_w "SELECT pad FROM dbo.pgvs_t WHERE id = 1;"
WSID=; for _ in $(seq 1 30); do WSID=$(sq "SELECT MIN(r.session_id) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = 'pgvs_w' AND r.wait_type = 'LCK_M_S'"); [[ "$WSID" =~ ^[0-9]+$ ]] && break; sleep 1; done
[[ "$WSID" =~ ^[0-9]+$ ]] || fail "A: the waiter never waited on LCK_M_S"
for p in "${BG[@]}"; do wait "$p" 2>/dev/null || true; done; BG=()
# max server memory down and up again, with no session in flight: the memory broker's notifications. A cut to 1024 MB
# left the server refusing logins for a while (run 1: a prelogin failure on the next statement), so the cut is to
# 2048 MB and each statement retries its connection for up to 2 minutes (a connection error only; any other fails)
sqmem() { local out; for _ in $(seq 1 24); do
    out=$(sq "$2" 2>&1) && return 0
    echo "$out" | grep -q "unable to establish connection\|prelogin\|TCP Provider" || fail "$1: $out"; sleep 5; done; fail "$1: no connection in 2 minutes: $out"; }
sqmem "A: max server memory 2048" "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', 2048; RECONFIGURE;"
sleep 20
sqmem "A: max server memory back" "EXEC sp_configure 'max server memory (MB)', 2147483647; RECONFIGURE;"
PROVOKED=$(sq "SELECT CONVERT(varchar(23), SYSUTCDATETIME(), 126)" | tail -1) || fail "A: the server's clock after the provocations: $PROVOKED"
# system_health writes to its file up to 120 s late; sp_server_diagnostics runs every 300 s
XF="sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL)"
# a filter on timestamp_utc itself goes into the function and picks whole files on SQL Server 2022 (proof-mssql-readers'
# note); on an expression of it, rows. The times are passed without a zone (style 126 takes no Z)
have() { sq "SELECT COUNT(*) FROM $XF WHERE object_name = N'$1' AND DATEADD(millisecond, 0, timestamp_utc) > CONVERT(datetime2, '${2%Z}', 126)${3:+ AND $3}" | tail -1; }
for w in $(seq 1 84); do
  NW=$(have wait_info "$START" "CAST(event_data AS nvarchar(max)) LIKE N'%LCK_M_S%'"); NSY=$(have sp_server_diagnostics_component_result "$PROVOKED")
  NSM=$(have scheduler_monitor_system_health_ring_buffer_recorded "$START"); NMB=$(have memory_broker_ring_buffer_recorded "$START")
  (( ${NW:-0} >= 1 && ${NSY:-0} >= 4 && ${NSM:-0} >= 1 && ${NMB:-0} >= 1 )) && break; sleep 5
done
(( ${NW:-0} >= 1 && ${NSY:-0} >= 4 && ${NSM:-0} >= 1 && ${NMB:-0} >= 1 )) || fail "A: system_health's file after 7 min: wait_info LCK_M_S $NW, component results after the provocations $NSY (want 4), scheduler monitor $NSM, memory broker $NMB"
CUT=$(sq "SELECT CONVERT(varchar(23), SYSUTCDATETIME(), 126)" | tail -1) || fail "A: the server's clock at the cut: $CUT"
# system_health writes an event to its file up to 120 s after its time: past the cut, both sides wait that long before
# either reads, so an event stamped before the cut is in the file for pgvigil's read and sp_HealthParser's alike
sleep 125
echo "ok   A: provoked (waiter $WSID on LCK_M_S, max server memory 2048 MB and back, a growth, DBCC, DDL); in the file after $((w * 5)) s: wait_info $NW, component results $NSY, scheduler monitor $NSM, memory broker $NMB"

echo "== B. pgvigil reads system_health and the default trace =="
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
export PGV_S_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$TMPD/s.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_S_MON
EOF
"$BIN" migrate -config "$TMPD/s.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
col() { "$BIN" collect -config "$TMPD/s.yaml" -instance sqlbox -once "$1" >"$TMPD/c-$1.out" 2>&1 || { cat "$TMPD/c-$1.out" >&2; fail "B: collect $1"; }; }
col mssql_syshealth; col mssql_syshealth; col mssql_defaulttrace
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
for r in syshealth defaulttrace; do
  [[ "$(pq "SELECT state FROM pgvigil.mssql_reader_state WHERE instance_id = $SB AND reader = '$r'")" == read ]] || fail "B: the $r reader: $(pq "SELECT state || ' ' || coalesce(note, '') FROM pgvigil.mssql_reader_state WHERE instance_id = $SB AND reader = '$r'")"
done
W0="'$START'::timestamptz"; W1="'${CUT}Z'::timestamptz"
NEV=$(pq "SELECT string_agg(component || ' ' || n, ', ' ORDER BY component) FROM (SELECT component, count(*) n FROM pgvigil.mssql_health_components WHERE instance_id = $SB AND event_at > $W0 AND event_at <= $W1 GROUP BY 1) x")
echo "ok   B: both readers read; stored in the window: $NEV"

echo "== C. sp_HealthParser's own log tables against pgvigil's rows =="
sqok "C: sp_HealthParser" "EXEC dbo.sp_HealthParser @what_to_check = 'all', @start_date = '${START}', @end_date = '${CUT}Z', @warnings_only = 0,
  @log_to_table = 1, @log_database_name = N'pgvs_hp', @log_schema_name = N'dbo', @log_retention_days = 0;"
TSRV=$(sq "SELECT DATEDIFF(MINUTE, GETUTCDATE(), SYSDATETIME())" | tail -1) || fail "C: the server's offset from UTC: $TSRV"
[[ "$TSRV" == 0 ]] || fail "C: the container's clock is not UTC (offset $TSRV min): sp_HealthParser's event_time is the server's local time"
# the rows of a log table as text, one line each, sorted (the event time to the millisecond, then the columns given)
hp() { sqr "SELECT 'R~' + REPLACE(CONVERT(varchar(23), event_time, 121), ' ', 'T') + '|' + $2 FROM dbo.HealthParser_$1 ORDER BY 1" pgvs_hp | sed 's/[[:space:]]*$//; /^$/d' | sort; }
# an API part's rows as the same text (the columns given by name, a number without its .0, a NULL as empty)
api() { local o rc=0; o=$(curl -fsS -b "$TMPD/jar" "$U/api/mssql/syshealth?instance=$SB&from=$(urlq "$START")&to=$(urlq "${CUT}Z")&part=$1" 2>&1) || rc=$?
  (( rc == 0 )) || fail "the API's part=$1: curl exit $rc: $o"; echo "$o"; }
apirows() { python3 -c '
import json, sys
t = json.load(sys.stdin)[sys.argv[1]]; cols = sys.argv[2].split(",")
from datetime import datetime
def f(v):
    if v is None: return ""
    if isinstance(v, float) and v == int(v): return str(int(v))
    if isinstance(v, str) and v[:2] == "20" and "T" in v[:11]:
        t = datetime.fromisoformat(v.replace("Z", "+00:00")); return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03d" % (t.microsecond // 1000)
    return str(v)
for r in t["rows"]:
    d = dict(zip(t["columns"], r)); print("|".join(f(d[c]) for c in cols))' "$1" "$2" | sort; }
# the pages and the API need the server; it starts here and serves C, D and G
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$TMPD/s.yaml" "$USR" >/dev/null 2>&1 || fail "C: user add"
HPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
"$BIN" serve -config "$TMPD/s.yaml" -listen "127.0.0.1:$HPORT" >"$TMPD/serve.log" 2>&1 & SRVPID=$!
U=http://127.0.0.1:$HPORT
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "C: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/jar" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "C: the API login"
cmp_rows() { # name, sp_HealthParser's lines, pgvigil's lines, the least count wanted
  if ! diff <(echo "$2") <(echo "$3") > "$TMPD/c.diff"; then echo "sp_HealthParser:"; echo "$2" | head -20; echo "pgvigil:"; echo "$3" | head -20; cat "$TMPD/c.diff" | head -20; fail "C: $1 differ"; fi
  local n; n=$(echo "$2" | sed '/^$/d' | wc -l); (( n >= $4 )) || fail "C: $1: $n row(s), want $4 or more"; echo "ok   C: $1: $n row(s), equal row for row"; }
# significant waits: the money style of sp_HealthParser's text columns (a thousands comma, no .00) read back as numbers
HW=$(hp SignificantWaits "ISNULL(wait_type, '') + '|' + REPLACE(REPLACE(ISNULL(duration_ms, ''), ',', ''), '.00', '') + '|' + REPLACE(REPLACE(ISNULL(signal_duration_ms, ''), ',', ''), '.00', '') + '|' + ISNULL(wait_resource, '') + '|' + ISNULL(CONVERT(varchar(11), session_id), '')")
PW=$(api waits | apirows waits event_at,wait_type,duration_ms,signal_duration_ms,wait_resource,session_id)
cmp_rows "significant waits (sp_HealthParser's SignificantWaits, part=waits)" "$HW" "$PW" 1
echo "$PW" | grep -q "|LCK_M_S|.*|$WSID$" || fail "C: the provoked LCK_M_S wait of session $WSID is not among the significant waits"
BC="broker_id,pool_metadata_id,delta_time,memory_ratio,new_target,overall,rate,currently_predicated,currently_allocated,previously_allocated,broker,notification"
HB=$(hp MemoryBroker "$(tcols "$BC")")
PB=$(api broker | apirows broker "event_at,$BC")
cmp_rows "memory broker (MemoryBroker, part=broker)" "$HB" "$PB" 1
OC="node_id,memory_node_id,memory_utilization_pct,total_physical_memory_kb,available_physical_memory_kb,total_page_file_kb,available_page_file_kb,total_virtual_address_space_kb,available_virtual_address_space_kb,target_kb,reserved_kb,committed_kb,shared_committed_kb,awe_kb,pages_kb,failure_type,failure_value,resources,factor_text,factor_value,last_error,pool_metadata_id,is_process_in_job,is_system_physical_memory_high,is_system_physical_memory_low,is_process_physical_memory_low,is_process_virtual_memory_low"
HO=$(hp MemoryNodeOOM "$(tcols "$OC")")
PO=$(api node_oom | apirows node_oom "event_at,$OC")
cmp_rows "memory node OOM (MemoryNodeOOM, part=node_oom)" "$HO" "$PO" 0
HS=$(hp SchedulerIssues "ISNULL(CONVERT(varchar(11), sql_cpu_utilization), '') + '|' + ISNULL(CONVERT(varchar(11), other_process_cpu), '') + '|' + ISNULL(CONVERT(varchar(11), system_idle), '') + '|' + ISNULL(CONVERT(varchar(11), memory_utilization), '') + '|' + REPLACE(REPLACE(ISNULL(page_faults, ''), ',', ''), '.00', '') + '|' + ISNULL(CONVERT(varchar(30), working_set_delta_mb), '')")
# SQL Server on Linux writes system_idle as 0 in every sample; pgvigil stores it as not read there (cpu.go's rule), so
# idle and other are compared blank after the premise is checked on sp_HealthParser's own rows
HOSTP=$(sq "SELECT CAST(host_platform AS nvarchar(256)) FROM sys.dm_os_host_info" | tail -1) || fail "C: the host platform: $HOSTP"
if [[ "$HOSTP" == Linux ]]; then
  NIDLE=$(echo "$HS" | awk -F'|' '$4 != "0"' | sed '/^$/d' | wc -l)
  (( NIDLE == 0 )) || fail "C: on Linux sp_HealthParser's system_idle is not 0 in $NIDLE sample(s): the guard's premise does not hold"
  echo "info C: Linux host: sp_HealthParser's system_idle 0 in all $(echo "$HS" | sed '/^$/d' | wc -l) sample(s), other processes $(echo "$HS" | awk -F'|' '{print $3}' | sort -n | sed -n '1p;$p' | paste -sd- -) %; pgvigil stores idle and other as not read"
  HS=$(echo "$HS" | awk -F'|' 'BEGIN { OFS = "|" } { $3 = ""; $4 = ""; print }')
fi
PS=$(pq "SELECT to_char(event_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS') || '|' || coalesce(pgvigil.mssql_health_num(detail, 'process_utilization')::text, '') || '|'
         || coalesce((100 - pgvigil.mssql_health_num(detail, 'process_utilization') - pgvigil.mssql_health_num(detail, 'system_idle'))::text, '') || '|'
         || coalesce(pgvigil.mssql_health_num(detail, 'system_idle')::text, '') || '|' || coalesce(pgvigil.mssql_health_num(detail, 'memory_utilization')::text, '') || '|'
         || coalesce(pgvigil.mssql_health_num(detail, 'page_faults')::text, '') || '|' || coalesce(to_char(round(pgvigil.mssql_health_num(detail, 'working_set_delta') / 1048576, 2), 'FM999999999990.00'), '')
         FROM pgvigil.mssql_health_components WHERE instance_id = $SB AND component = 'SCHEDULER_MONITOR' AND event_at >= $W0 AND event_at < $W1" | sort)
cmp_rows "scheduler monitor (SchedulerIssues, @warnings_only = 0; the stored samples)" "$HS" "$PS" 1
NWARN=$(echo "$HS" | awk -F'|' '$2 >= 90 || ($3 != "" && $3 >= 50) || ($5 != "" && $5 <= 50)' | sed '/^$/d' | wc -l)
NAPIS=$(api scheduler | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["scheduler"]["rows"]))')
[[ "$NAPIS" == "$NWARN" ]] || fail "C: part=scheduler holds $NAPIS sample(s), sp_HealthParser's rows past a warning $NWARN"
echo "ok   C: part=scheduler: $NAPIS sample(s) past a warning, as sp_HealthParser's rows"
SC="state,spinlockBackoffs,sickSpinlockType,latchWarnings,isAccessViolationOccurred,writeAccessViolationCount,intervalDumpRequests,nonYieldingTasksReported,pageFaults,systemCpuUtilization,sqlCpuUtilization,BadPagesDetected,BadPagesFixed"
HY=$(hp SystemHealth "$(tcols "$SC")")
PY=$(pq "SELECT to_char(event_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS') || '|' || state || '|' || $(echo "$SC" | cut -d, -f2- | tr ',' '\n' | sed "s/.*/coalesce(detail->>'&', '')/" | paste -sd'|' | sed "s/|/ || '|' || /g")
         FROM pgvigil.mssql_health_components WHERE instance_id = $SB AND component = 'SYSTEM' AND event_at >= $W0 AND event_at < $W1" | sort)
cmp_rows "SYSTEM counters (SystemHealth, the stored SYSTEM results)" "$HY" "$PY" 1
# part=series: per bucket the largest of each counter = the largest of sp_HealthParser's values in that bucket
SER=$(api series); STEP=$(python3 -c 'import sys; from datetime import datetime as d; a, b = sys.argv[1:]; f = lambda s: d.fromisoformat(s.replace("Z", "+00:00")); import math; print(max(300, math.ceil((f(b) - f(a)).total_seconds() / 120)))' "$START" "${CUT}Z")
python3 - "$STEP" <<PYEOF || fail "C: part=series' counters are not the largest of sp_HealthParser's values per bucket"
import json, sys
from datetime import datetime, timezone
step = int(sys.argv[1]); t = json.loads('''$SER''')["series"]
api = {r[0][:19]: dict(zip(t["columns"], r)) for r in t["rows"]}
# the line: time, state, spinlockBackoffs, sickSpinlockType, latchWarnings, isAccessViolationOccurred, writeAccessViolationCount,
# intervalDumpRequests, nonYieldingTasksReported, pageFaults, systemCpu, sqlCpu, BadPagesDetected, BadPagesFixed
cols = {"latch_warnings": 4, "access_violations": 5, "write_access_violations": 6, "dump_requests": 7, "non_yielding": 8, "bad_pages": 12}
want = {}
for line in """$HY""".splitlines():
    if not line: continue
    f = line.split("|"); at = datetime.fromisoformat(f[0]).replace(tzinfo=timezone.utc).timestamp()
    b = datetime.fromtimestamp(int(at // step) * step, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    for k, i in cols.items():
        if f[i] != "": want.setdefault(b, {}).setdefault(k, []).append(int(f[i]))
bad = 0
for b, ks in want.items():
    for k, vs in ks.items():
        got = api.get(b, {}).get(k)
        if got is None or int(got) != max(vs): print(f"bucket {b} {k}: api {got}, want {max(vs)}"); bad += 1
print(f"{sum(len(v) for v in want.values())} bucket counters compared"); sys.exit(1 if bad else 0)
PYEOF
echo "ok   C: part=series' counters = the largest of sp_HealthParser's per bucket ($STEP s)"
# RESOURCE: the new columns against a hand read of the memory report in system_health's file
HR=$(sqr "SELECT 'R~' + REPLACE(CONVERT(varchar(23), timestamp_utc, 121), ' ', 'T') + '|' + $(for e in 'Available Virtual Memory' 'Available Paging File' 'Percent of Committed Memory in WS' 'Page Faults' 'System physical memory high'; do
  case "$e" in Avail*) echo "ISNULL(CONVERT(varchar(30), CONVERT(decimal(20,0), ROUND(x.value('(/event/data[@name=\"data\"]/value/resource/memoryReport/entry[@description=\"$e\"]/@value)[1]', 'bigint') / 1048576.0, 0))), '')";;
  *) echo "ISNULL(CONVERT(varchar(30), x.value('(/event/data[@name=\"data\"]/value/resource/memoryReport/entry[@description=\"$e\"]/@value)[1]', 'bigint')), '')";; esac; done | paste -sd'|' | sed "s/|ISNULL/ + '|' + ISNULL/g")
  FROM (SELECT timestamp_utc, CAST(event_data AS xml) AS x FROM $XF WHERE object_name = N'sp_server_diagnostics_component_result') f
 WHERE x.value('(/event/data[@name=\"component\"]/text)[1]', 'varchar(30)') = 'RESOURCE' AND DATEADD(millisecond, 0, timestamp_utc) >= CONVERT(datetime2, '${START%Z}', 126) AND DATEADD(millisecond, 0, timestamp_utc) < CONVERT(datetime2, '$CUT', 126) ORDER BY 1" | sed 's/[[:space:]]*$//; /^$/d' | sort)
PR=$(api resource | apirows resource event_at,available_virtual_mb,available_paging_mb,pct_committed_in_ws,page_faults,system_memory_high)
cmp_rows "RESOURCE memory columns (a hand read of the memory report, part=resource)" "$HR" "$PR" 1

echo "== D. the default trace against a hand read of fn_trace_gettable =="
TP=$(sq "SELECT path FROM sys.traces WHERE is_default = 1" | tail -1) || fail "D: the default trace's path: $TP"
HD=$(sq "SELECT CASE WHEN t.EventClass IN (92, 93) THEN CASE t.EventClass WHEN 92 THEN 'data growth' ELSE 'log growth' END
                    WHEN t.EventClass IN (94, 95) THEN CASE t.EventClass WHEN 94 THEN 'data shrink' ELSE 'log shrink' END
                    WHEN t.EventClass = 116 THEN 'dbcc' ELSE 'ddl' END + ':' + CONVERT(varchar(11), COUNT(*))
  FROM sys.fn_trace_gettable(N'$TP', DEFAULT) t
 WHERE COALESCE(t.EndTime, t.StartTime) >= CONVERT(datetime, '${START%Z}', 126) AND COALESCE(t.EndTime, t.StartTime) < CONVERT(datetime, '$CUT', 126)
   AND (t.EventClass IN (92, 93, 94, 95) OR (t.EventClass = 116 AND ISNULL(t.ApplicationName, N'') NOT LIKE N'pgvigil%')
        OR (t.EventClass IN (46, 47, 164) AND t.EventSubClass = 1 AND ISNULL(t.DatabaseID, 0) <> 2 AND ISNULL(t.ObjectType, 0) NOT IN (21587, 17747)))
 GROUP BY CASE WHEN t.EventClass IN (92, 93) THEN CASE t.EventClass WHEN 92 THEN 'data growth' ELSE 'log growth' END
               WHEN t.EventClass IN (94, 95) THEN CASE t.EventClass WHEN 94 THEN 'data shrink' ELSE 'log shrink' END
               WHEN t.EventClass = 116 THEN 'dbcc' ELSE 'ddl' END ORDER BY 1" | sed '/^$/d' | paste -sd, -) || fail "D: the hand read of the default trace: $HD"
PD=$(pq "SELECT string_agg(kind || ':' || n, ',' ORDER BY kind) FROM (SELECT kind, count(*) n FROM pgvigil.mssql_trace_events WHERE instance_id = $SB AND event_at >= $W0 AND event_at < $W1 GROUP BY kind) x")
[[ "$HD" == "$PD" ]] || fail "D: the default trace per kind: hand read '$HD', pgvigil '$PD'"
for k in 'data growth' dbcc ddl; do echo "$PD" | grep -q "$k:" || fail "D: no '$k' event (provoked in A)"; done
DT=$(curl -fsS -b "$TMPD/jar" "$U/api/mssql/defaulttrace?instance=$SB&from=$(urlq "$START")&to=$(urlq "${CUT}Z")" 2>&1) || fail "D: /api/mssql/defaulttrace: $DT"
GN=$(echo "$DT" | python3 -c 'import json,sys; d = json.load(sys.stdin); print(len(d["growths"]["rows"]), len(d["dbcc"]["rows"]), len(d["ddl"]["rows"]))')
WANT=$(pq "SELECT count(*) FILTER (WHERE kind LIKE '% growth' OR kind LIKE '% shrink') || ' ' || count(*) FILTER (WHERE kind = 'dbcc') || ' ' || count(*) FILTER (WHERE kind = 'ddl') FROM pgvigil.mssql_trace_events WHERE instance_id = $SB AND event_at > '$START' AND event_at <= '${CUT}Z'")
[[ "$GN" == "$WANT" ]] || fail "D: /api/mssql/defaulttrace's grids (growths, dbcc, ddl) $GN, the store $WANT"
echo "ok   D: the default trace per kind = the hand read ($PD); the API's grids $GN rows as the store"

echo "== E. the system events' findings (0120) =="
# the server's own scheduler monitor samples first (SQL Server on Linux: is system_idle read?), and what they raise
# before any seed; the scheduler findings are then checked on an instance id that holds no real sample (the view groups
# by instance, so the server's own samples could raise them by themselves), with seeds on both sides of each threshold
LNX=$(pq "SELECT count(*) || ' sample(s); SQL ' || coalesce(min(pgvigil.mssql_health_num(detail, 'process_utilization')) || '-' || max(pgvigil.mssql_health_num(detail, 'process_utilization')), '-') || ' %, idle ' || coalesce(min(pgvigil.mssql_health_num(detail, 'system_idle')) || '-' || max(pgvigil.mssql_health_num(detail, 'system_idle')), '-') || ' %, memory utilization ' || coalesce(min(pgvigil.mssql_health_num(detail, 'memory_utilization')) || '-' || max(pgvigil.mssql_health_num(detail, 'memory_utilization')), '-') FROM pgvigil.mssql_health_components WHERE instance_id = $SB AND component = 'SCHEDULER_MONITOR'")
PRE=$(pq "SELECT string_agg(check_name, ',' ORDER BY check_name) FROM pgvigil.mssql_sysevents_findings WHERE instance_id = $SB")
echo "info E: the server's own scheduler monitor samples: $LNX; the findings they raise before any seed: ${PRE:-none}"
echo "$PRE" | grep -q 'ring buffer' && fail "E: the ring buffer finding is raised before its seed: '$PRE'"
[[ "$HOSTP" == Linux ]] && echo "$PRE" | grep -q 'other processes' && fail "E: on Linux the server's own samples raise 'other processes' (idle is not read there): '$PRE'"
# the months the seeds land in exist (the importer makes a month's partition only for the rows it stores)
EW0=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+2 hours'); EW1=$(date -u +%Y-%m-%dT%H:%M:%SZ -d '+3 hours')
for t in "$(date -u +%Y-%m-%dT%H:%M:%SZ -d '-10 minutes')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EW0" "$EW1"; do
  pq "SELECT pgvigil.mssql_event_partition('mssql_health_components', '$t'::timestamptz)" >/dev/null
done
FX=$(pq "SELECT coalesce(max(instance_id), 0) + 1000 FROM pgvigil.instances")
fseed() { pq "INSERT INTO pgvigil.mssql_health_components (instance_id, event_at, event_key, snapshot_at, component, state, detail)
              VALUES ($FX, now() - interval '$2 minutes', 'pgvs-$1', now(), 'SCHEDULER_MONITOR', 'EVENT', '$3')" >/dev/null; }
fseed f1 5 '{"process_utilization": 10, "system_idle": 40, "memory_utilization": 100}'
fseed f2 4 '{"process_utilization": 10, "system_idle": 41, "memory_utilization": 100}'
fseed f3 3 '{"process_utilization": 10, "system_idle": 85, "memory_utilization": 50}'
fseed f4 2 '{"process_utilization": 10, "system_idle": 85, "memory_utilization": 51}'
fseed f5 1 '{"process_utilization": 10, "system_idle_not_read": true, "memory_utilization": 100}'
XST=$(pq "SELECT count(*) FROM pgvigil.mssql_xe_state WHERE instance_id = $SB AND capture = 'slow'")
pq "INSERT INTO pgvigil.mssql_xe_state (instance_id, capture, snapshot_at, state, state_since, session_name, target, event_count, truncated)
    VALUES ($SB, 'slow', now(), 'running', now(), 'pgvs_ring', 'ring_buffer', 812, true)
    ON CONFLICT (instance_id, capture) DO UPDATE SET truncated = true, snapshot_at = now(), event_count = 812, session_name = 'pgvs_ring'" >/dev/null
EF=$(pq "SELECT string_agg(severity || '|' || check_name || '|' || split_part(detail, ':', 1), ',' ORDER BY check_name) FROM pgvigil.mssql_sysevents_findings WHERE instance_id = $FX")
ER=$(pq "SELECT string_agg(severity || '|' || check_name, ',') FROM pgvigil.mssql_sysevents_findings WHERE instance_id = $SB AND check_name = 'the ring buffer output was cut off'")
# the join's arm (0190): the same findings reach pgvigil.findings under the source mssql_sysevents
EA=$(pq "SELECT count(*) FROM pgvigil.findings WHERE instance_id = $FX AND source = 'mssql_sysevents'")
EB=$(pq "SELECT count(*) FROM pgvigil.findings WHERE instance_id = $SB AND source = 'mssql_sysevents' AND setting = 'the ring buffer output was cut off'")
pq "DELETE FROM pgvigil.mssql_health_components WHERE instance_id = $FX" >/dev/null
[[ "$XST" == 0 ]] && pq "DELETE FROM pgvigil.mssql_xe_state WHERE instance_id = $SB AND capture = 'slow'" >/dev/null || pq "UPDATE pgvigil.mssql_xe_state SET truncated = false WHERE instance_id = $SB AND capture = 'slow'" >/dev/null
WANTF="warning|system_health: other processes used half the CPU|1 sample(s) in the last hour with other processes at 50 % or more of the CPU (the most 50 %, SQL Server 10 % at that sample),warning|system_health: the working set was trimmed|1 sample(s) in the last hour with memory utilization at 50 or less (the least 50)"
[[ "$EF" == "$WANTF" ]] || fail "E: the scheduler findings over the seeds (other 50 / 49, memory 50 / 51, a Linux sample without idle): '$EF', want '$WANTF'"
[[ "$ER" == "warning|the ring buffer output was cut off" ]] || fail "E: the ring buffer finding '$ER'"
[[ "$EA" == 2 && "$EB" == 1 ]] || fail "E: pgvigil.findings' mssql_sysevents arm holds $EA of the 2 scheduler findings and $EB of the 1 ring buffer finding (0190)"
# the filters of part=waits (sp_HealthParser's) and part=scheduler (its warnings), on rows seeded in a window of their own
seed() { pq "INSERT INTO pgvigil.mssql_health_components (instance_id, event_at, event_key, snapshot_at, component, state, detail)
              VALUES ($SB, '$EW0'::timestamptz + interval '$2 minutes', 'pgvs-$1', now(), '$3', 'EVENT', '$4')" >/dev/null; }
W='"signal_duration_ms": 0, "is_backup": false, "has_sql_text": true'
seed w1 1 WAIT_INFO "{\"wait_type\": \"LCK_M_X\", \"duration_ms\": 900, \"session_id\": 61, $W, \"statement\": \"UPDATE dbo.t SET c = 1\"}"
seed w2 2 WAIT_INFO "{\"wait_type\": \"LCK_M_X\", \"duration_ms\": 900, \"session_id\": 0, $W}"
seed w3 3 WAIT_INFO "{\"wait_type\": \"LCK_M_X\", \"duration_ms\": 900, \"session_id\": 62, \"signal_duration_ms\": 0, \"is_backup\": false, \"has_sql_text\": false}"
seed w4 4 WAIT_INFO "{\"wait_type\": \"BACKUPIO\", \"duration_ms\": 900, \"session_id\": 63, \"signal_duration_ms\": 0, \"is_backup\": true, \"has_sql_text\": true}"
seed w5 5 WAIT_INFO "{\"wait_type\": \"LCK_M_X\", \"duration_ms\": 400, \"session_id\": 64, $W}"
seed w6 6 WAIT_INFO "{\"wait_type\": \"WAITFOR\", \"duration_ms\": 9000, \"session_id\": 65, $W}"
seed w7 7 WAIT_INFO "{\"wait_type\": \"LCK_M_S\", \"duration_ms\": 1200, \"session_id\": 66, $W}"
seed s1 8 SCHEDULER_MONITOR '{"process_utilization": 90, "system_idle": 5, "memory_utilization": 100}'
seed s2 9 SCHEDULER_MONITOR '{"process_utilization": 10, "system_idle": 40, "memory_utilization": 100}'
seed s3 10 SCHEDULER_MONITOR '{"process_utilization": 10, "system_idle": 80, "memory_utilization": 50}'
seed s4 11 SCHEDULER_MONITOR '{"process_utilization": 89, "system_idle": 11, "memory_utilization": 51}'
seed s5 12 SCHEDULER_MONITOR '{"process_utilization": 10, "system_idle": 41, "memory_utilization": 100}'
seed s6 13 SCHEDULER_MONITOR '{"process_utilization": 95, "system_idle_not_read": true, "memory_utilization": 100}'
seed s7 14 SCHEDULER_MONITOR '{"process_utilization": 10, "system_idle_not_read": true, "memory_utilization": 100}'
epart() { local o rc=0; o=$(curl -fsS -b "$TMPD/jar" "$U/api/mssql/syshealth?instance=$SB&from=$(urlq "$EW0")&to=$(urlq "$EW1")&part=$1" 2>&1) || rc=$?
  (( rc == 0 )) || fail "E: the API's part=$1 over the seeded window: curl exit $rc: $o"; echo "$o"; }
EWS=$(epart waits | apirows waits wait_type,duration_ms,session_id | paste -sd, -)
ESS=$(epart scheduler | apirows scheduler sql_cpu,other_cpu,memory_utilization | paste -sd, -)
ESN=$(epart scheduler_samples | apirows scheduler_samples samples)
pq "DELETE FROM pgvigil.mssql_health_components WHERE instance_id = $SB AND event_key LIKE 'pgvs-%'" >/dev/null
[[ "$EWS" == "LCK_M_S|1200|66,LCK_M_X|900|61" ]] || fail "E: part=waits over the seeded waits: '$EWS', want the two sp_HealthParser keeps (session 0, no statement, a BACKUP, 400 ms and WAITFOR left out; a statement hidden by the text policy kept)"
[[ "$ESS" == "10|10|50,10|50|100,90|5|100,95||100" ]] || fail "E: part=scheduler over the seeded samples: '$ESS', want the three on a warning's edge (SQL 90, other 50, memory 50; SQL 89, other 49 and memory 51 left out) and the Linux sample at SQL 95 with other blank (the one at SQL 10 left out)"
[[ "$ESN" == 7 ]] || fail "E: part=scheduler_samples over the seeded window: '$ESN', want 7"
echo "ok   E: the findings on the thresholds (other 50 raised, 49 not; memory utilization 50 raised, 51 not; a cut ring buffer); part=waits keeps 2 of 7 seeded waits ($EWS), part=scheduler 4 of 7 samples (the edges, and a Linux sample without idle kept on SQL 95 with other blank; scheduler_samples 7); the seeds removed"

echo "== F. tests and lint on the run's copy =="
(cd "$GSRC" && go test -count=1 ./internal/mssql/ ./internal/web/ ./internal/repo/ >"$TMPD/test.out" 2>&1) || { tail -30 "$TMPD/test.out" >&2; fail "F: go test"; }
(cd "$GSRC" && golangci-lint run --allow-parallel-runners ./... >"$TMPD/lint.out" 2>&1) || { tail -30 "$TMPD/lint.out" >&2; fail "F: golangci-lint at the root"; }
(cd "$GSRC/app" && golangci-lint run --allow-parallel-runners ./... >"$TMPD/lint-app.out" 2>&1) || { tail -30 "$TMPD/lint-app.out" >&2; fail "F: golangci-lint in app/"; }
echo "ok   F: go test green; golangci-lint 0 issues at the root and in app/"

echo "== G. the pages in headless Chromium, every link and control clicked =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,900 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "G: chromium's CDP port never answered"
cat > "$TMPD/g.mjs" <<'JS'
// prints one line per check; the shell grades them
const [port, U, sb, shots, from, to] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0 && !m.querySelector('.loading'); })()`); if (ok) { await sleep(600); return true; } await sleep(200); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150); await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
// rows of the grid that follows a heading whose text starts with the given words; -1 where there is none
const gridRows = (head) => ev(`(() => { const m = document.querySelector('main'); const h = [...m.querySelectorAll('h2,h3,h4')].find(x => x.textContent.startsWith(${JSON.stringify(head)}));
  let g = h?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE') g = g.nextElementSibling;
  return g ? [...g.querySelectorAll('table.grid tbody tr')].filter(tr => !tr.querySelector('.empty')).length : -1; })()`);
const state = () => ev(`(() => { const m = document.querySelector('main'); return JSON.stringify({ hash: location.hash, errors: m.querySelectorAll('.error:not([role=status])').length,
  h: (m.querySelector('h2')?.textContent ?? ''), links: [...m.querySelectorAll('a[href]')].map(a => ({ t: a.textContent.trim().slice(0, 60), h: a.getAttribute('href') })) }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.G_USR)}, password: ${JSON.stringify(process.env.G_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
const range = `&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
const pages = { health: `#/mssqlhealth?i=${sb}${range}`, trace: `#/mssqltrace?i=${sb}${range}` };
const charts = () => ev(`JSON.stringify([...document.querySelectorAll('main .chart')].map(c => { const t = c.querySelector('h3')?.textContent ?? ''; return t + '=' + (c.querySelector('canvas, svg, .u-wrap') ? 'drawn' : (c.querySelector('p.empty')?.textContent ?? '?')); }))`).then(JSON.parse);
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: U + '#/about' }); await sleep(400);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  if (!await go(pages.health)) { console.log(`FAIL render health ${theme}`); continue; }
  const s = await state();
  console.log(`page health ${theme} errors=${s.errors} waits=${await gridRows('Significant waits')} broker=${await gridRows('Memory broker')} scheduler=${await gridRows('Scheduler monitor')} oom=${await gridRows('Memory node OOM')} system=${await gridRows('SYSTEM')}`);
  for (const c of await charts()) console.log(`chart ${theme} ${c}`);
  await shot(`syshealth-${theme}`);
  if (!await go(pages.trace)) { console.log(`FAIL render trace ${theme}`); continue; }
  const t = await state();
  console.log(`page trace ${theme} errors=${t.errors}`);
  await shot(`defaulttrace-${theme}`);
}
// every link of both pages: its landing and whether the page it lands on renders without an error box
for (const [name, hash] of Object.entries(pages)) {
  await go(hash); const s = await state();
  const seen = new Set();
  for (const l of s.links) {
    if (seen.has(l.h)) continue; seen.add(l.h);
    if (!l.h.startsWith('#/')) { console.log(`click ${name} ${JSON.stringify(l.t)} -> ${l.h} (not followed: off the page)`); continue; }
    const ok = await go(l.h); const f = await state();
    console.log(`click ${name} ${JSON.stringify(l.t)} -> ${f.hash.split('?')[0]} (${f.h}) rendered=${ok} errors=${f.errors} wt=${new URLSearchParams(f.hash.split('?')[1] ?? '').get('wt') ?? '-'}`);
  }
}
// every column group check box: clicked, its first column's label in its grid's header after, then clicked back
await go(pages.health);
const boxes = await ev(`JSON.stringify([...document.querySelectorAll('main fieldset.filters')].flatMap((f, i) => [...f.querySelectorAll('label')].map((l, j) => ({ i, j, name: l.textContent.trim(), on: l.querySelector('input').checked }))))`).then(JSON.parse);
for (const b of boxes) {
  const heads = () => ev(`[...document.querySelectorAll('main fieldset.filters')[${b.i}].parentElement.querySelectorAll('thead th')].map(th => th.textContent.replace(/[\\u25be\\u25b4\\u25bc\\u25b2]/g, '').trim()).join('|')`);
  const before = await heads();
  await ev(`document.querySelectorAll('main fieldset.filters')[${b.i}].querySelectorAll('label input')[${b.j}].click(); 'ok'`); await sleep(300);
  const after = await heads();
  await ev(`document.querySelectorAll('main fieldset.filters')[${b.i}].querySelectorAll('label input')[${b.j}].click(); 'ok'`); await sleep(300);
  const back = await heads();
  const legend = await ev(`document.querySelectorAll('main fieldset.filters')[${b.i}].querySelector('legend').textContent`);
  console.log(`control ${JSON.stringify(legend)} ${JSON.stringify(b.name)} was=${b.on ? 'on' : 'off'} columns ${before.split('|').length} -> ${after.split('|').length} -> ${back.split('|').length} restored=${before === back}`);
}
ws.close(); process.exit(0);
JS
out=$(G_USR="$USR" G_UPW="$UPW" node "$TMPD/g.mjs" "$CDP" "$U/" "$SB" "$SHOTS" "$START" "${CUT}Z") || fail "G: the Chromium walk stopped: $out"
echo "$out"
echo "$out" | grep -q '^login 200$' || fail "G: the UI login in Chromium"
! echo "$out" | grep -q '^FAIL' || fail "G: a page did not render"
NWA=$(echo "$PW" | sed '/^$/d' | wc -l); NBR=$(echo "$PB" | sed '/^$/d' | wc -l)
for theme in light dark; do
  echo "$out" | grep -q "^page health $theme errors=0 waits=$NWA broker=$NBR scheduler=$NAPIS " || fail "G: the System health page ($theme): $(echo "$out" | grep "^page health $theme") (want waits $NWA, broker $NBR, scheduler $NAPIS)"
  echo "$out" | grep -q "^page trace $theme errors=0$" || fail "G: the Default trace page ($theme)"
  NCH=$(echo "$out" | grep -c "^chart $theme \(Corruption\|Contention\) events: " || true)
  [[ "$NCH" == 7 ]] || fail "G: $NCH corruption / contention chart(s) on the page ($theme), want 7"
  ! echo "$out" | grep "^chart $theme \(Corruption\|Contention\) events: " | grep -q '=?$' || fail "G: a counter chart neither drawn nor saying why ($theme)"
done
! echo "$out" | grep '^click ' | grep -v 'not followed' | grep -qv 'rendered=true errors=0' || fail "G: a link landed on a page with an error: $(echo "$out" | grep '^click ' | grep -v 'rendered=true errors=0' | head -3)"
echo "$out" | grep '^click health ' | grep -q -- "-> #/mssql_waiting (.*) rendered=true errors=0 wt=LCK_M_S" || fail "G: the LCK_M_S wait type does not land on Waiting tasks filtered to it"
NCTL=$(echo "$out" | grep -c '^control ' || true)
(( NCTL == 6 )) || fail "G: $NCTL column group check box(es), want 6 (RESOURCE 2, Memory node OOM 4)"
! echo "$out" | grep '^control ' | grep -qv 'restored=true' || fail "G: a check box did not restore its grid"
# PerformanceMonitor's defaults: Process memory and Failure on, the other groups off
DEF=$(echo "$out" | sed -n 's/^control "[^"]*" "\([^"]*\)" was=\([a-z]*\) .*/\1=\2/p' | paste -sd, -)
[[ "$DEF" == "Process memory=on,Pressure flags=off,Memory sizes=off,Pool detail=off,Failure=on,Flags=off" ]] || fail "G: the column groups' defaults: $DEF"
! echo "$out" | grep '^control ' | awk '{ for (i = 1; i <= NF; i++) if ($i == "columns") { a = $(i + 1); b = $(i + 3); if (a == b) bad = 1 } } END { exit !bad }' || fail "G: a check box did not change its grid's columns: $(echo "$out" | grep '^control ' | head -6)"
echo "ok   G: both pages in light and dark (waits $NWA, broker $NBR, scheduler $NAPIS as the API; 7 counter charts each drawn or saying why), $(echo "$out" | grep -c '^click ') link(s) and $NCTL control(s) clicked; shots $([[ -n "${PGVIGIL_SHOTS:-}" ]] && echo "in $SHOTS" || echo "not kept (PGVIGIL_SHOTS unset)")"
echo "proof-darling-sysevents: OK (sp_HealthParser ${HPV:-?}'s significant waits, memory broker, memory node OOM, scheduler monitor and system health rows equal pgvigil's over the same window; the RESOURCE columns and the default trace equal hand reads; the findings; the pages and their links and controls in Chromium)"
