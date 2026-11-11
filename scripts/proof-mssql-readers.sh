#!/usr/bin/env bash
# Proof of the SQL Server readers of task 149 (migration 0091_mssql_readers.sql; internal/mssql/errorlog.go,
# defaulttrace.go, syshealth.go; internal/web/q_mssql_errorlog.go) against a real SQL Server and, for the rules no
# server shows on demand (a finding's window, a late state, a clock set back), on imported rows.
#
# Needs: go (one binary is built into the temp folder; PGVIGIL_BIN names a built one instead), psql, curl, jq, ss,
# docker, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname, no password in it.
#   PGVIGIL_SKIP_PG13=1      leaves part M out (it starts and removes a postgres:13 container of its own).
#   PGVIGIL_NO_MSSQL=1       the parts that need no SQL Server only (M, G, X): the last line says so and is NOT the
#                            proof's PASS.
# The binary must carry the routes /api/mssql/errorlog, /defaulttrace and /syshealth (the lead's wiring in web.go):
# part A stops at its first read when it does not.
# The proof makes, and removes on every exit path (the end, a failed check, INT, TERM): its own SQL Server container
# (mcr.microsoft.com/mssql/server:2022-latest unless MSSQL_IMAGE names another; its clock set to America/Los_Angeles
# so the server's local time is not UTC; a throwaway sa password made here, never printed), its own repository
# database pgvigil_s149_readers_<n> and, for M, a postgres:13 container. Inside its own container it makes logins, a
# database, error-log lines, trace events and memory pressure; nothing outside it.
#
# Expected (written before the first run):
#  M. the whole migration chain applies on PostgreSQL 13: migrate exits 0, the newest schema version equals the main
#     repository's, and 0091's seven functions exist there.
#  L. the error log. Three logins on the one server, each its own instance in the repository: FULL (VIEW SERVER STATE,
#     ALTER TRACE, EXECUTE on xp_readerrorlog), CURRENT (EXECUTE on xp_readerrorlog only: it may read a log file and
#     may not list the archives) and BARE (no right at all).
#     1. The first read: FULL's state 'read' with the scope 'all archives'; CURRENT's 'read' with the scope 'current
#        log only' and a note naming sp_enumerrorlogs; BARE's 'no right', and its collection's status is ok (not error,
#        not partial). The server's offset is -480 or -420 minutes (America/Los_Angeles).
#     2. sa raises a severity 17 error WITH LOG (marker A). FULL's next read stores it exactly once: severity 17, error
#        50000, its message; logged_local equals sa's own read of the line in xp_readerrorlog to the millisecond, and
#        log_at equals that time moved by the server's offset (sa's arithmetic) to the millisecond.
#     3. A third read stores nothing more for marker A.
#     4. The instance's own string: pgvigil.mssql_errorlog_search_set gives FULL one string; sa logs a severity 10
#        line with it; sa cycles the error log, raises marker B (severity 17), cycles again (marker B now in archive
#        1, marker A in archive 2). FULL's next read stores marker B once with archive 1, the own line once marked
#        custom, and marker A is still one row (the files read again overlap the cursor).
#     5. sa raises marker C after the cycles. CURRENT's next read stores marker C once and has no row of marker B:
#        it reads the current log only, and its state says so.
#  T. the default trace. 1. FULL's first read: state 'read', the trace's oldest event set; CURRENT's and BARE's
#     'no right' naming ALTER TRACE, their collections ok. 2. sa makes a database whose files grow by 8 MB, fills it
#     until the data file has grown, creates and drops a table, empties the data and runs DBCC SHRINKFILE on the data
#     file. FULL's next read stores, for that database, as many data growths and as many log growths as sa counts in
#     the trace, and the newest data growth with event_at equal to sa's StartTime moved by the offset to the
#     millisecond; exactly one DBCC SHRINKFILE row by sa there (sub 'DBCC SHRINKFILE', its text), dated the same way;
#     one create and one drop of the table. 3. A second read stores no more of any of them. 4. The findings hold
#     'default trace: a DBCC SHRINK command ran' for FULL (info).
#  H. system_health. 1. FULL's read: state 'read', scope event_file; the stored results equal, per component, sa's
#     count of sp_server_diagnostics_component_result events up to the newest stored one; all four components there.
#     CURRENT and BARE: 'no right' naming VIEW SERVER STATE. 2. the warning. The container runs with max worker threads 128 (set and restarted before L). sa
#     waits for a QUERY_PROCESSING result, then one session holds a lock and 400 sessions wait on it (the workers run
#     out) for the whole of the next five-minute interval and 30 s more; the sessions are ended. (Measured on the box
#     in two experiments before this was written: such a starved interval gave a QUERY_PROCESSING result in WARNING,
#     35 pending tasks, the oldest waiting 289 s; a memory eater in the container never gave a RESOURCE warning.)
#     sa reads at least one QUERY_PROCESSING result not CLEAN. FULL's next read stores it exactly once, its event_at
#     equal to sa's timestamp_utc to the millisecond, its state and pending tasks equal; the findings hold
#     'system_health: a component is not clean' for QUERY_PROCESSING (warning for WARNING, critical for ERROR).
#     3. A second read stores no more of them.
#  A. the API on FULL's rows: /api/mssql/errorlog with q=marker A gives one line of severity 17; with sev=17 it is
#     there and with class=corruption it is not; the search part holds the own string; class=nope, sev=99 and a q of
#     201 characters are refused with 400. /api/mssql/defaulttrace: dbcc_summary has DBCC SHRINKFILE with 1 run by sa;
#     growth_summary has the database's data growth; ddl has the create and the drop. /api/mssql/syshealth: latest has
#     the four components; issues has the warning of H2.
#  G. the three import functions refuse a PostgreSQL instance.
#  X. without a server, on imported rows of an instance made for it:
#     1. one error-log line imported three times, its instant moved by an hour (a clock set back) and then by 30
#        hours: two rows (the first two are one). The same for a trace event: two rows. A component result imported
#        twice: one row.
#     2. the findings of the instance equal exactly this list (severity|check|object): critical|error log: errors of
#        severity 17 or higher|severity 21; critical|error log: corruption reported|corruption; warning|error log:
#        memory pressure reported|memory; warning|default trace: slow file growth|db1 (data growth);
#        warning|default trace: auto-shrink ran|db1; warning|default trace: a disruptive DBCC command ran|DBCC
#        FREEPROCCACHE; info|default trace: a DBCC SHRINK command ran|DBCC SHRINKFILE; info|default trace: the wait
#        or latch statistics were cleared|DBCC SQLPERF (CLEAR); warning|system_health: a component is not
#        clean|QUERY_PROCESSING; critical|system_health: a component is not clean|RESOURCE; critical|system_health:
#        bad pages detected|SYSTEM; critical|system_health: a sick spinlock|SYSTEM; critical|system_health: deadlocked
#        schedulers|QUERY_PROCESSING; warning|system_health: tasks waiting for a worker|QUERY_PROCESSING;
#        warning|system_health: long IO or IO latch timeouts|IO_SUBSYSTEM; critical|system_health: out of
#        memory|RESOURCE; warning|a SQL Server reader could not read its source|defaulttrace; info|a SQL Server
#        reader's source is switched off|syshealth; info|a SQL Server reader lacks its right|errorlog.
#        Not in it: a line 30 hours old, a growth of 900 ms, a FREEPROCCACHE with a plan handle, an older SYSTEM result
#        with non-yielding tasks, a state read 40 minutes ago, a figure that is no number. (Restated with the review
#        fold, before any run that had it: the out-of-memory count is the counter's growth inside the window, so the
#        rows hold a RESOURCE result 20 minutes old with 0 exceptions before the one with 1.)
#     3. mssql_errorlog_search_set: four strings with two duplicates (one by its spaces, one by its case) give 2, the
#        first spelling kept, and the cursor row holds them with offset 1;
#        51 strings, a string of 201 characters and an unknown instance are refused; an empty list gives 0 and removes
#        the row. A batch's cursor row for 'errorlog:search' does not touch it.
#     4. a reader's state: a late state row changes nothing; the same state again keeps state_since; a read without an
#        oldest event keeps the one before.
#  The last line is "proof-mssql-readers: PASS (...)" and the exit code 0 only when every part holds; anything else
#  is a FAIL line naming the check, exit 1.
#  NOT PROVEN HERE: a Windows SQL Server (backslash paths: unit-tested), SQL Server 2017 and 2019 (the version proof
#  of task 145 runs this file on them when the lead adds it), Amazon RDS (rds_read_error_log), Azure SQL Managed
#  Instance, a slow growth over 1 s, the corruption, IO and scheduler components of a real server in trouble, the
#  pages in a browser (proof-a11y).
set -euo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
for t in psql curl jq ss; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
NOMS=${PGVIGIL_NO_MSSQL:-}
if [ -z "$NOMS" ] || [ "${PGVIGIL_SKIP_PG13:-}" != 1 ]; then
  command -v docker >/dev/null || { echo "FAIL: docker is not on this machine" >&2; exit 1; }
fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_s149_readers_$SUF
CT=pgv-s149-mssql-$SUF; PG13=pgv-s149-pg13-$SUF
LF=pgv149full_$SUF; LC=pgv149cur_$SUF; LB=pgv149bare_$SUF
NF=s149-full-$SUF; NC=s149-current-$SUF; NB=s149-bare-$SUF
DB=pgv149db_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PF=$(pw); PC=$(pw); PB=$(pw)
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: got '$2', want '$3'"; }
freeport() { for p in $(seq "$1" "$2"); do ss -ltn | grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_CT=; MADE_PG13=; SRV_PID=
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# sq <sql> [database]: one batch as sa (the password through the environment by name); sqs: a batch on stdin
sq() { timeout 300 docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
sqs() { timeout 300 docker exec -i -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -C -b -I -W -h -1 -s '|' -U sa -i /dev/stdin; }
# raise <severity> <text>: RAISERROR ... WITH LOG; sqlcmd's exit code is the error's, so it is not checked here
raise() { timeout 60 docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -C -I -U sa -Q "RAISERROR(N'$2', $1, 1) WITH LOG;" >/dev/null 2>&1 || true; }
cleanup() {
  rc=$?
  [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null || true; }
  [ -n "$MADE_CT" ] && { docker rm -f "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2; }
  [ -n "$MADE_PG13" ] && { docker rm -f "$PG13" >/dev/null 2>&1 || echo "CLEANUP: container $PG13 not removed" >&2; }
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || true
  echo "cleanup: container $CT $( [ -n "$MADE_CT" ] && (docker ps -aq --filter "name=^$CT\$" | grep -q . && echo LEFT || echo removed) || echo 'not made'), repository $REPO_DB $( [ -n "$MADE_REPO" ] && echo dropped || echo 'not made')"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN names no binary"
  BIN=$WORK/pgvigil
  (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"
fi
[ -x "$BIN" ] || fail "no binary at $BIN"
echo "  the machine's load: $(cut -d' ' -f1-3 /proc/loadavg)"

echo "--- the SQL Server"
if [ -n "$NOMS" ]; then
  echo "  NOT USED (PGVIGIL_NO_MSSQL=1): the parts L, T, H and A are not run"; ADDR=none
else
  MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  MPORT=$(freeport 22433 22499) || fail "no free port for the SQL Server container"
  ADDR=127.0.0.1:$MPORT
  MADE_CT=1
  docker run -d --name "$CT" --memory "${PGVIGIL_S149_MEMORY:-4g}" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e TZ=America/Los_Angeles \
    -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run of the SQL Server container"
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
  echo "  $CT ($ADDR): $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(80))")"
  # H2 starves the workers: max worker threads at its lowest, in force after a restart
  sq "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max worker threads', 128; RECONFIGURE;" >/dev/null
  docker restart "$CT" >/dev/null || fail "the restart of $CT"
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  eq "the most workers after the restart" "$(sq "SELECT max_workers_count FROM sys.dm_os_sys_info")" 128
  OFF=$(sq "SELECT DATEDIFF(minute, GETUTCDATE(), GETDATE())")
  case $OFF in -480|-420) echo "  the server's clock is $OFF minutes from UTC" ;; *) fail "L1: the server's offset is $OFF, want -480 or -420 (TZ=America/Los_Angeles)" ;; esac
fi

adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

if [ -z "$NOMS" ]; then
  printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\nCREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\nCREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" \
    "$LF" "$PF" "$LC" "$PC" "$LB" "$PB" | sqs >/dev/null
  sq "GRANT VIEW SERVER STATE TO [$LF]; GRANT ALTER TRACE TO [$LF];
      CREATE USER [$LF] FOR LOGIN [$LF]; CREATE USER [$LC] FOR LOGIN [$LC];
      GRANT EXECUTE ON sys.xp_readerrorlog TO [$LF]; GRANT EXECUTE ON sys.xp_readerrorlog TO [$LC];" >/dev/null
fi
export MS_FULL="sqlserver://$LF:$PF@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_CUR="sqlserver://$LC:$PC@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_BARE="sqlserver://$LB:$PB@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_FULL\n' "$NF"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_CUR\n' "$NC"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_BARE\n' "$NB"
} > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate on the main repository"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT" >&2; fail "collect $1 on $2"; }; }
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
status() { q "select status from pgvigil.collection_dates where instance_id = $(iid "$1") and collection = '$2'"; }
st() { q "select $3 from pgvigil.mssql_reader_state where instance_id = $(iid "$1") and reader = '$2'"; }

if [ "${PGVIGIL_SKIP_PG13:-}" = 1 ]; then
  echo "--- M. PostgreSQL 13: NOT RUN (PGVIGIL_SKIP_PG13=1)"; M_NOTE="M NOT RUN"
else
  echo "--- M. the migration chain on PostgreSQL 13"
  PG13PW=$(pw); export PG13PW
  P13=$(freeport 26432 26499) || fail "M: no free port for the PostgreSQL 13 container"
  MADE_PG13=1
  POSTGRES_PASSWORD="$PG13PW" docker run -d --name "$PG13" -e POSTGRES_PASSWORD -p "127.0.0.1:$P13:5432" postgres:13 >/dev/null || fail "M: docker run postgres:13"
  p13() { PGPASSWORD="$PG13PW" psql "host=127.0.0.1 port=$P13 user=postgres dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
  for _ in $(seq 1 60); do p13 "select 1" >/dev/null 2>&1 && break; sleep 1; done
  sleep 2; p13 "select 1" >/dev/null || fail "M: PostgreSQL 13 does not answer"
  p13 "create database pgvigil_s149_pg13" >/dev/null
  export PG13_DSN="host=127.0.0.1 port=$P13 user=postgres password=$PG13PW dbname=pgvigil_s149_pg13"
  sed 's/env:PGVIGIL_REPO_DSN/env:PG13_DSN/' "$CFG" > "$WORK/pg13.yaml"
  "$BIN" migrate -config "$WORK/pg13.yaml" > "$WORK/pg13.out" 2>&1 || { tail -20 "$WORK/pg13.out" >&2; fail "M: migrate on PostgreSQL 13"; }
  V13=$(p13 "select current_setting('server_version_num')::int / 10000 || '|' || (select max(version) from pgvigil.schema_version)" pgvigil_s149_pg13)
  eq "M: PostgreSQL major|schema version" "$V13" "13|$(q "select max(version) from pgvigil.schema_version")"
  F13=$(p13 "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname in ('import_mssql_readers', 'import_mssql_errorlog', 'import_mssql_defaulttrace', 'import_mssql_syshealth', 'mssql_errorlog_search_set', 'mssql_health_num', 'mssql_event_partition')" pgvigil_s149_pg13)
  eq "M: 0091's functions on PostgreSQL 13" "$F13" 7
  docker rm -f "$PG13" >/dev/null 2>&1 && MADE_PG13=
  echo "M: OK"; M_NOTE="M"
fi

if [ -z "$NOMS" ]; then
echo "--- L. the error log"
collect mssql_errorlog "$NF"; collect mssql_errorlog "$NC"; collect mssql_errorlog "$NB"
eq "L1: FULL's state|scope" "$(st "$NF" errorlog "state || '|' || coalesce(scope, '')")" "read|all archives"
eq "L1: CURRENT's state|scope" "$(st "$NC" errorlog "state || '|' || coalesce(scope, '')")" "read|current log only"
st "$NC" errorlog note | grep -q sp_enumerrorlogs || fail "L1: CURRENT's note does not name sp_enumerrorlogs: $(st "$NC" errorlog note)"
eq "L1: BARE's state" "$(st "$NB" errorlog state)" "no right"
eq "L1: BARE's collection status" "$(status "$NB" mssql_errorlog)" ok
echo "L1: OK (FULL all archives, CURRENT current log only, BARE no right and ok)"

MA="pgv149 marker A $SUF"; MB="pgv149 marker B $SUF"; MC="pgv149 marker C $SUF"; OWN="pgv149own$SUF"
raise 17 "$MA"; sleep 1
collect mssql_errorlog "$NF"
IF=$(iid "$NF")
# sa's own read of a marker's line: its local time and that time moved to UTC by the server's offset
hand() { printf "SET NOCOUNT ON; CREATE TABLE #l (d datetime, p nvarchar(100), t nvarchar(max));\nINSERT #l EXEC master.dbo.xp_readerrorlog %s, 1, N'%s';\nSELECT CONVERT(varchar(23), d, 121) + '|' + CONVERT(varchar(23), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), d), 121) + '|' + CAST(COUNT(*) OVER () AS varchar(5)) FROM #l WHERE t LIKE N'%%%s%%';\n" "$1" "$2" "$2" | sqs; }
stored() { q "select to_char(logged_local, 'YYYY-MM-DD HH24:MI:SS.MS') || '|' || to_char(log_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '|' || coalesce(severity::text, '') || '|' || coalesce(error_number::text, '') || '|' || count(*) over () || '|' || coalesce(archive::text, '') || '|' || custom from pgvigil.mssql_errorlog where instance_id = $1 and message like '%$2%'"; }
HA=$(hand 0 "$MA")
SA=$(stored "$IF" "$MA")
eq "L2: marker A (local|utc|severity|error|rows)" "$(echo "$SA" | cut -d'|' -f1-5)" "$(echo "$HA" | cut -d'|' -f1-2)|17|50000|1"
echo "L2: OK (marker A once, local $(echo "$HA" | cut -d'|' -f1), stored $(echo "$SA" | cut -d'|' -f2) UTC)"
collect mssql_errorlog "$NF"
eq "L3: marker A after another read" "$(stored "$IF" "$MA" | cut -d'|' -f5)" 1
echo "L3: OK"

eq "L4: the own string set" "$(q "select pgvigil.mssql_errorlog_search_set('$NF', array['$OWN'], false)")" 1
raise 10 "$OWN line"
sq "EXEC sp_cycle_errorlog;" >/dev/null; sleep 1
raise 17 "$MB"; sleep 1
sq "EXEC sp_cycle_errorlog;" >/dev/null; sleep 1
HB=$(hand 1 "$MB")
[ "$(echo "$HB" | cut -d'|' -f3)" = 1 ] || fail "L4: sa does not find marker B once in archive 1: $HB"
collect mssql_errorlog "$NF"
SB=$(stored "$IF" "$MB")
eq "L4: marker B (local|utc|severity|error|rows|archive)" "$(echo "$SB" | cut -d'|' -f1-6)" "$(echo "$HB" | cut -d'|' -f1-2)|17|50000|1|1"
eq "L4: the own line (rows|custom)" "$(stored "$IF" "$OWN line" | cut -d'|' -f5,7)" "1|true"
eq "L4: marker A after the archives were read" "$(stored "$IF" "$MA" | cut -d'|' -f5)" 1
echo "L4: OK (marker B once from archive 1, the own line marked, marker A still one row)"
raise 17 "$MC"; sleep 1
collect mssql_errorlog "$NC"
IC=$(iid "$NC")
eq "L5: CURRENT's marker C rows" "$(stored "$IC" "$MC" | cut -d'|' -f5)" 1
eq "L5: CURRENT's marker B rows" "$(q "select count(*) from pgvigil.mssql_errorlog where instance_id = $IC and message like '%$MB%'")" 0
eq "L5: CURRENT's scope" "$(st "$NC" errorlog scope)" "current log only"
echo "L5: OK (CURRENT reads the current log only and says so)"

echo "--- T. the default trace"
collect mssql_defaulttrace "$NF"; collect mssql_defaulttrace "$NC"; collect mssql_defaulttrace "$NB"
eq "T1: FULL's state" "$(st "$NF" defaulttrace "state || '|' || (oldest_at is not null)")" "read|true"
for n in "$NC" "$NB"; do
  eq "T1: $n's state" "$(st "$n" defaulttrace state)" "no right"
  st "$n" defaulttrace note | grep -q "ALTER TRACE" || fail "T1: $n's note does not name ALTER TRACE"
  eq "T1: $n's collection status" "$(status "$n" mssql_defaulttrace)" ok
done
sq "CREATE DATABASE [$DB] ON (NAME = pgv149_data, FILENAME = '/var/opt/mssql/data/$DB.mdf', SIZE = 8MB, FILEGROWTH = 8MB)
    LOG ON (NAME = pgv149_log, FILENAME = '/var/opt/mssql/data/$DB.ldf', SIZE = 8MB, FILEGROWTH = 8MB);
    ALTER DATABASE [$DB] SET RECOVERY SIMPLE;" >/dev/null
sq "CREATE TABLE dbo.pv_fill (id int IDENTITY PRIMARY KEY, pad char(4000) NOT NULL DEFAULT 'x');
    INSERT dbo.pv_fill (pad) SELECT TOP (6000) 'x' FROM sys.all_columns a CROSS JOIN sys.all_columns b;
    CREATE TABLE dbo.pv_ddl (i int); DROP TABLE dbo.pv_ddl;
    TRUNCATE TABLE dbo.pv_fill;" "$DB" >/dev/null
sq "DBCC SHRINKFILE (pgv149_data, 8) WITH NO_INFOMSGS;" "$DB" >/dev/null
sleep 1
TB="DECLARE @p nvarchar(260) = (SELECT path FROM sys.traces WHERE is_default = 1); DECLARE @b nvarchar(260) = LEFT(@p, LEN(@p) - CHARINDEX(N'/', REVERSE(@p))) + N'/log.trc';"
HG=$(sq "$TB SELECT CAST(SUM(CASE WHEN EventClass = 92 THEN 1 ELSE 0 END) AS varchar(10)) + '|' + CAST(SUM(CASE WHEN EventClass = 93 THEN 1 ELSE 0 END) AS varchar(10)) FROM sys.fn_trace_gettable(@b, DEFAULT) WHERE DatabaseName = N'$DB' AND EventClass IN (92, 93)")
HGT=$(sq "$TB SELECT TOP (1) CONVERT(varchar(23), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), StartTime), 121) FROM sys.fn_trace_gettable(@b, DEFAULT) WHERE DatabaseName = N'$DB' AND EventClass = 92 ORDER BY StartTime DESC, EventSequence DESC")
HS=$(sq "$TB SELECT CONVERT(varchar(23), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), StartTime), 121) + '|' + CAST(COUNT(*) OVER () AS varchar(5)) FROM sys.fn_trace_gettable(@b, DEFAULT) WHERE DatabaseName = N'$DB' AND EventClass = 116 AND CAST(TextData AS nvarchar(4000)) LIKE N'%SHRINKFILE%'")
[ "$(echo "$HG" | cut -d'|' -f1)" -ge 1 ] 2>/dev/null || fail "T2: sa counts no data growth of $DB in the trace: $HG"
[ "$(echo "$HS" | cut -d'|' -f2)" = 1 ] || fail "T2: sa does not find one DBCC SHRINKFILE in the trace: $HS"
collect mssql_defaulttrace "$NF"
tq() { q "select $1 from pgvigil.mssql_trace_events where instance_id = $IF and $2"; }
eq "T2: data|log growths of $DB" "$(tq "count(*) filter (where kind = 'data growth') || '|' || count(*) filter (where kind = 'log growth')" "database_name = '$DB'")" "$HG"
eq "T2: the newest data growth's time (UTC)" "$(tq "to_char(max(event_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS')" "database_name = '$DB' and kind = 'data growth'")" "$HGT"
eq "T2: DBCC SHRINKFILE (time|rows|login|text)" "$(tq "to_char(max(event_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '|' || count(*) || '|' || max(login_name) || '|' || (max(statement) like '%SHRINKFILE%')" "database_name = '$DB' and kind = 'dbcc' and sub = 'DBCC SHRINKFILE'")" "$(echo "$HS" | cut -d'|' -f1)|1|sa|true"
eq "T2: create|drop of pv_ddl" "$(tq "count(*) filter (where sub = 'create') || '|' || count(*) filter (where sub = 'drop')" "object_name = 'pv_ddl' and kind = 'ddl'")" "1|1"
echo "T2: OK (growths $HG, the shrink at $(echo "$HS" | cut -d'|' -f1) UTC, the table's create and drop)"
BEFORE=$(tq "count(*)" "database_name = '$DB'")
collect mssql_defaulttrace "$NF"
eq "T3: the database's events after another read" "$(tq "count(*)" "database_name = '$DB'")" "$BEFORE"
eq "T4: the shrink finding" "$(q "select severity || '|' || object from pgvigil.mssql_readers_findings where instance_id = $IF and check_name = 'default trace: a DBCC SHRINK command ran'")" "info|DBCC SHRINKFILE"
echo "T3, T4: OK"

echo "--- H. system_health"
collect mssql_syshealth "$NF"; collect mssql_syshealth "$NC"; collect mssql_syshealth "$NB"
eq "H1: FULL's state|scope" "$(st "$NF" syshealth "state || '|' || coalesce(scope, '')")" "read|event_file"
for n in "$NC" "$NB"; do
  eq "H1: $n's state" "$(st "$n" syshealth state)" "no right"
  st "$n" syshealth note | grep -q "VIEW SERVER STATE" || fail "H1: $n's note does not name VIEW SERVER STATE"
done
# sa's count per component up to the newest stored result
hcount() {
  local upto; upto=$(q "select to_char(max(event_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') from pgvigil.mssql_health_components where instance_id = $IF")
  sq "SELECT x.c + ':' + CAST(COUNT(*) AS varchar(10)) FROM (SELECT CAST(event_data AS xml) AS e, timestamp_utc FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) WHERE object_name = N'sp_server_diagnostics_component_result') f CROSS APPLY (SELECT f.e.value('(/event/data[@name=\"component\"]/text)[1]', 'varchar(30)') AS c) x WHERE f.timestamp_utc <= CONVERT(datetime2, '$upto', 121) GROUP BY x.c ORDER BY x.c" | paste -sd, -
}
mine() { q "select string_agg(component || ':' || n, ',' order by component) from (select component, count(*) n from pgvigil.mssql_health_components where instance_id = $IF group by component) x"; }
H1=$(hcount)
eq "H1: the results per component" "$(mine)" "$H1"
[ "$(echo "$H1" | tr ',' '\n' | wc -l)" = 4 ] || fail "H1: not four components: $H1"
echo "H1: OK ($H1)"
# H2: a starved interval of the workers
QPNEWEST="SELECT CONVERT(varchar(23), MAX(timestamp_utc), 121) FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) WHERE object_name = N'sp_server_diagnostics_component_result' AND CAST(event_data AS nvarchar(max)) LIKE N'%QUERY_PROCESSING%'"
T0=$(sq "$QPNEWEST")
for _ in $(seq 1 40); do T1=$(sq "$QPNEWEST"); [ "$T1" != "$T0" ] && break; sleep 10; done
[ "$T1" != "$T0" ] || fail "H2: no new QUERY_PROCESSING result within 400 s (the newest $T0)"
NEXT=$(( $(date -u -d "$T1" +%s) + 300 ))
sq "CREATE TABLE dbo.pv_hold (id int PRIMARY KEY, v int NOT NULL); INSERT dbo.pv_hold VALUES (1, 0);" "$DB" >/dev/null
docker exec -d -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -C -U sa -d "$DB" -Q "BEGIN TRAN; UPDATE dbo.pv_hold SET v = 1 WHERE id = 1; WAITFOR DELAY '00:09:00'; ROLLBACK;"
sleep 2
docker exec -d -e SQLCMDPASSWORD "$CT" bash -c "for i in \$(seq 1 400); do $SQLCMD -S localhost -C -U sa -d $DB -l 600 -t 700 -Q 'SELECT v FROM dbo.pv_hold WHERE id = 1' >/dev/null 2>&1 & done; wait"
echo "  H2: 400 sessions wait on one lock from $(date -u +%T) UTC to the result due at $(date -u -d "@$NEXT" +%T) and 30 s more"
while [ "$(date -u +%s)" -lt $((NEXT + 30)) ]; do sleep 10; done
docker exec "$CT" bash -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null | grep -q "^/opt/mssql-tools18/bin/sqlcmd" && kill ${p#/proc/}; done' >/dev/null 2>&1 || true
for _ in $(seq 1 36); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 5; done
sq "SELECT 1" >/dev/null 2>&1 || fail "H2: the SQL Server does not answer 3 minutes after the sessions were ended"
HQ=$(sq "SELECT TOP (1) CONVERT(varchar(23), timestamp_utc, 121) + '|' + x.s + '|' + ISNULL(x.p, '') FROM (SELECT timestamp_utc, CAST(event_data AS xml) AS e FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) WHERE object_name = N'sp_server_diagnostics_component_result') f CROSS APPLY (SELECT f.e.value('(/event/data[@name=\"component\"]/text)[1]', 'varchar(30)') AS c, f.e.value('(/event/data[@name=\"state\"]/text)[1]', 'varchar(20)') AS s, f.e.value('(/event/data[@name=\"data\"]/value/queryProcessing/@pendingTasks)[1]', 'varchar(20)') AS p) x WHERE x.c = 'QUERY_PROCESSING' AND x.s <> 'CLEAN' ORDER BY f.timestamp_utc DESC")
[ -n "$HQ" ] || fail "H2: sa reads no QUERY_PROCESSING result that is not CLEAN after the starved interval"
collect mssql_syshealth "$NF"
eq "H2: the result (time|state|pending|rows)" "$(q "select to_char(event_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS') || '|' || state || '|' || coalesce(detail->>'pendingTasks', '') || '|' || count(*) over () from pgvigil.mssql_health_components where instance_id = $IF and component = 'QUERY_PROCESSING' and event_at = '$(echo "$HQ" | cut -d'|' -f1)+00'")" "$HQ|1"
WANTSEV=warning; [ "$(echo "$HQ" | cut -d'|' -f2)" = ERROR ] && WANTSEV=critical
eq "H2: the finding" "$(q "select severity from pgvigil.mssql_readers_findings where instance_id = $IF and check_name = 'system_health: a component is not clean' and object = 'QUERY_PROCESSING'")" "$WANTSEV"
echo "H2: OK (QUERY_PROCESSING $(echo "$HQ" | cut -d'|' -f2) at $(echo "$HQ" | cut -d'|' -f1) UTC, $(echo "$HQ" | cut -d'|' -f3) pending tasks; findings: $(q "select string_agg(check_name, '; ') from pgvigil.mssql_readers_findings where instance_id = $IF and check_name like 'system_health%'"))"
N2=$(mine); collect mssql_syshealth "$NF"
eq "H3: the results after another read" "$(mine | sed 's/:[0-9]*//g')" "$(echo "$N2" | sed 's/:[0-9]*//g')"
eq "H3: the results equal sa's count again" "$(mine)" "$(hcount)"
echo "H3: OK"

echo "--- A. the API"
PORT=$(freeport 18340 18380) || fail "no free port for the UI"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "$U/health" >/dev/null || { cat "$WORK/serve.log" >&2; fail "the UI did not serve"; }
for r in errorlog defaulttrace syshealth; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/$r?instance=$IF")" != 404 ] || fail "the binary has no route /api/mssql/$r (the lead's wiring in web.go)"
done
W="from=$(date -u -d '-2 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"
enc() { jq -rn --arg s "$1" '$s|@uri'; }
api() { curl -fs "$U/mssql/$1?instance=$IF&$W&$2"; }
n_rows() { jq -r ".$1.rows | length"; }
eq "A: errorlog q=marker A" "$(api errorlog "part=lines&q=$(enc "$MA")" | jq -r '.lines | [.columns, .rows[0]] | transpose | map({(.[0]): .[1]}) | add | .severity')" 17
eq "A: errorlog q=marker A rows" "$(api errorlog "part=lines&q=$(enc "$MA")" | n_rows lines)" 1
eq "A: errorlog sev=17 holds it" "$(api errorlog "part=lines&sev=17&q=$(enc "$MA")" | n_rows lines)" 1
eq "A: errorlog class=corruption does not" "$(api errorlog "part=lines&class=corruption&q=$(enc "$MA")" | n_rows lines)" 0
api errorlog "part=search" | jq -r '.search.rows[0][0]' | grep -q "$OWN" || fail "A: the search part does not hold the own string"
for bad in "class=nope" "sev=99" "q=$(head -c 201 /dev/zero | tr '\0' 'x')"; do
  eq "A: errorlog $bad" "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/errorlog?instance=$IF&$W&$bad")" 400
done
eq "A: dbcc_summary SHRINKFILE runs|logins" "$(api defaulttrace part=dbcc_summary | jq -r '.dbcc_summary | .columns as $c | .rows[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add | select(.command == "DBCC SHRINKFILE") | "\(.runs)|\(.logins)"')" "1|sa"
api defaulttrace part=growth_summary | jq -r '.growth_summary.rows[] | @json' | grep -q "\"$DB\",\"data growth\"" || fail "A: growth_summary has no data growth of $DB"
eq "A: ddl rows of pv_ddl" "$(api defaulttrace part=ddl | jq -r '[.ddl.rows[] | select(.[3] == "pv_ddl")] | length')" 2
eq "A: syshealth latest components" "$(api syshealth part=latest | jq -r '[.latest.rows[][0]] | sort | join(",")')" "IO_SUBSYSTEM,QUERY_PROCESSING,RESOURCE,SYSTEM"
eq "A: syshealth issues hold the QUERY_PROCESSING result" "$(api syshealth part=issues | jq -r '[.issues.rows[] | select(.[1] == "QUERY_PROCESSING")] | length > 0')" true
echo "A: OK"
kill "$SRV_PID" 2>/dev/null || true; SRV_PID=
fi

echo "--- G. the import functions refuse a PostgreSQL instance"
PGI=$(q "select pgvigil.ensure_instance('s149-pg-$SUF', 'postgres', 'x', 160000, false, '{}'::text[])")
for f in import_mssql_errorlog import_mssql_defaulttrace import_mssql_syshealth; do
  if q "select pgvigil.$f($PGI, now(), '[]'::jsonb)" >/dev/null 2>&1; then fail "G: $f took a PostgreSQL instance"; fi
done
echo "G: OK"

echo "--- X. imported rows"
XI=$(q "select pgvigil.ensure_instance('s149-x-$SUF', 'sqlserver', 'x', 160000, false, '{}'::text[], 'sqlserver')")
imp() { q "select pgvigil.import_mssql_readers($XI, now(), '$1'::jsonb)" >/dev/null; }
# 1. the same line or event under three instants; a component twice
L='{"kind":"line","line_key":"k1-0","logged_local":"2026-11-01T12:00:00","message":"x","severity":17,"log_at":'
imp "[$L\"2026-11-01T20:00:00Z\"}]"; imp "[$L\"2026-11-01T19:00:00Z\"}]"; imp "[$L\"2026-11-03T02:00:00Z\"}]"
eq "X1: the line's rows" "$(q "select count(*) from pgvigil.mssql_errorlog where instance_id = $XI and line_key = 'k1-0'")" 2
E='{"kind":"trace","trace_kind":"ddl","event_class":46,"event_key":"t1","logged_local":"2026-11-01T12:00:00","event_at":'
imp "[$E\"2026-11-01T20:00:00Z\"}]"; imp "[$E\"2026-11-01T19:00:00Z\"}]"; imp "[$E\"2026-11-03T02:00:00Z\"}]"
eq "X1: the trace event's rows" "$(q "select count(*) from pgvigil.mssql_trace_events where instance_id = $XI and event_key = 't1'")" 2
C='[{"kind":"component","event_at":"2026-11-01T20:00:00Z","event_key":"c1","component":"SYSTEM","state":"CLEAN","detail":{}}]'
imp "$C"; imp "$C"
eq "X1: the component's rows" "$(q "select count(*) from pgvigil.mssql_health_components where instance_id = $XI and event_key = 'c1'")" 1
echo "X1: OK"
# 2. the findings: rows of the last hour (and the ones the windows leave out)
ago() { date -u -d "-$1" +%FT%TZ; }
line() { printf '{"kind":"line","line_key":"%s","logged_local":"2026-11-01T00:00:00","log_at":"%s","severity":%s,"error_number":50000,"class":"%s","message":"%s"}' "$1" "$(ago "$2")" "$3" "$4" "$5"; }
tr_() { printf '{"kind":"trace","event_key":"%s","logged_local":"2026-11-01T00:00:00","event_at":"%s","event_class":%s,"trace_kind":"%s","sub":%s,"database_name":"%s","duration_us":%s,"pages":1024,"login_name":"sa"}' "$1" "$(ago "$2")" "$3" "$4" "$5" "$6" "$7"; }
comp() { printf '{"kind":"component","event_key":"%s","event_at":"%s","component":"%s","state":"%s","detail":%s}' "$1" "$(ago "$2")" "$3" "$4" "$5"; }
stt() { printf '{"kind":"state","reader":"%s","state":"%s","note":"%s"}' "$1" "$2" "$3"; }
imp "[$(line s17 '1 hour' 17 general 'sev 17'),$(line s21 '50 minutes' 21 general 'sev 21'),$(line cor '1 hour' 0 corruption 'page damaged'),$(line mem '1 hour' 0 memory 'paged out'),$(line old '30 hours' 24 corruption 'old')]"
imp "[$(tr_ g1 '1 hour' 92 'data growth' null db1 1500000),$(tr_ g2 '1 hour' 92 'data growth' null db2 900000),$(tr_ s1 '1 hour' 94 'data shrink' null db1 0),$(tr_ d1 '1 hour' 116 dbcc '"DBCC FREEPROCCACHE"' db1 0),$(tr_ d2 '1 hour' 116 dbcc '"DBCC FREEPROCCACHE (plan handle)"' db1 0),$(tr_ d3 '1 hour' 116 dbcc '"DBCC SHRINKFILE"' db1 0),$(tr_ d4 '1 hour' 116 dbcc '"DBCC SQLPERF (CLEAR)"' master 0)]"
imp "[$(comp r0 '20 minutes' RESOURCE CLEAN '{"outOfMemoryExceptions":0}'),$(comp q1 '10 minutes' QUERY_PROCESSING WARNING '{"pendingTasks":12,"oldestPendingTaskWaitingTime":3000,"hasDeadlockedSchedulersOccurred":1}'),$(comp r1 '10 minutes' RESOURCE ERROR '{"outOfMemoryExceptions":1,"lastNotification":"RESOURCE_MEMPHYSICAL_LOW"}'),$(comp y1 '20 minutes' SYSTEM CLEAN '{"nonYieldingTasksReported":5}'),$(comp y2 '10 minutes' SYSTEM CLEAN '{"BadPagesDetected":2,"sickSpinlockType":"LOCK_HASH","latchWarnings":"x"}'),$(comp i1 '10 minutes' IO_SUBSYSTEM CLEAN '{"intervalLongIos":3,"ioLatchTimeouts":0}')]"
q "select pgvigil.import_mssql_readers($XI, now() - interval '40 minutes', '[$(stt errorlog failed 'old failure')]'::jsonb)" >/dev/null
imp "[$(stt errorlog 'no right' 'no EXECUTE'),$(stt defaulttrace failed 'the read failed'),$(stt syshealth off 'stopped')]"
WANT='critical|error log: corruption reported|corruption
critical|error log: errors of severity 17 or higher|severity 21
critical|system_health: a component is not clean|RESOURCE
critical|system_health: a sick spinlock|SYSTEM
critical|system_health: bad pages detected|SYSTEM
critical|system_health: deadlocked schedulers|QUERY_PROCESSING
critical|system_health: out of memory|RESOURCE
info|a SQL Server reader lacks its right|errorlog
info|a SQL Server reader'"'"'s source is switched off|syshealth
info|default trace: a DBCC SHRINK command ran|DBCC SHRINKFILE
info|default trace: the wait or latch statistics were cleared|DBCC SQLPERF (CLEAR)
warning|a SQL Server reader could not read its source|defaulttrace
warning|default trace: a disruptive DBCC command ran|DBCC FREEPROCCACHE
warning|default trace: auto-shrink ran|db1
warning|default trace: slow file growth|db1 (data growth)
warning|error log: memory pressure reported|memory
warning|system_health: a component is not clean|QUERY_PROCESSING
warning|system_health: long IO or IO latch timeouts|IO_SUBSYSTEM
warning|system_health: tasks waiting for a worker|QUERY_PROCESSING'
GOT=$(q "select severity || '|' || check_name || '|' || object from pgvigil.mssql_readers_findings where instance_id = $XI order by 1")
[ "$GOT" = "$WANT" ] || { diff <(echo "$WANT") <(echo "$GOT") >&2 || true; fail "X2: the findings differ (< want, > got)"; }
echo "X2: OK (19 findings, none from the rows the windows leave out)"
# 3. the instance's own search strings
XN="s149-x-$SUF"
eq "X3: four strings with two duplicates" "$(q "select pgvigil.mssql_errorlog_search_set('$XN', array['a', 'b', ' a ', 'A'], true)")" 2
eq "X3: the cursor row" "$(q "select file_name || '|' || file_offset from pgvigil.mssql_cursor where instance_id = $XI and source = 'errorlog:search'")" '["a", "b"]|1'
for bad in "array(select 's' || g from generate_series(1, 51) g)" "array[repeat('x', 201)]"; do
  if q "select pgvigil.mssql_errorlog_search_set('$XN', $bad, false)" >/dev/null 2>&1; then fail "X3: $bad was taken"; fi
done
if q "select pgvigil.mssql_errorlog_search_set('no-such-$SUF', array['a'], false)" >/dev/null 2>&1; then fail "X3: an unknown instance was taken"; fi
imp '[{"kind":"cursor","source":"errorlog:search","file_name":"[]","file_offset":0}]'
eq "X3: a batch's cursor row did not touch the strings" "$(q "select file_name from pgvigil.mssql_cursor where instance_id = $XI and source = 'errorlog:search'")" '["a", "b"]'
eq "X3: an empty list" "$(q "select pgvigil.mssql_errorlog_search_set('$XN', '{}'::text[], false)")" 0
eq "X3: the row is gone" "$(q "select count(*) from pgvigil.mssql_cursor where instance_id = $XI and source = 'errorlog:search'")" 0
echo "X3: OK"
# 4. the reader's state
q "select pgvigil.import_mssql_readers($XI, now() - interval '5 minutes', '[{\"kind\":\"state\",\"reader\":\"syshealth\",\"state\":\"read\"}]'::jsonb)" >/dev/null
eq "X4: a late state row" "$(q "select state from pgvigil.mssql_reader_state where instance_id = $XI and reader = 'syshealth'")" off
q "select pgvigil.import_mssql_readers($XI, now() + interval '1 minute', '[{\"kind\":\"state\",\"reader\":\"defaulttrace\",\"state\":\"read\",\"oldest_at\":\"2026-11-01T00:00:00Z\"}]'::jsonb)" >/dev/null
SINCE=$(q "select state_since from pgvigil.mssql_reader_state where instance_id = $XI and reader = 'defaulttrace'")
q "select pgvigil.import_mssql_readers($XI, now() + interval '2 minutes', '[{\"kind\":\"state\",\"reader\":\"defaulttrace\",\"state\":\"read\"}]'::jsonb)" >/dev/null
eq "X4: the same state keeps its since, a read without the oldest event keeps it" \
  "$(q "select (state_since = '$SINCE') || '|' || to_char(oldest_at at time zone 'UTC', 'YYYY-MM-DD')  from pgvigil.mssql_reader_state where instance_id = $XI and reader = 'defaulttrace'")" "true|2026-11-01"
echo "X4: OK"

if [ -n "$NOMS" ]; then
  echo "proof-mssql-readers: server-less parts passed ($M_NOTE, G, X); L, T, H and A NOT RUN (PGVIGIL_NO_MSSQL=1) - this is not the proof's PASS"
else
  echo "proof-mssql-readers: PASS ($M_NOTE, L, T, H, A, G, X; $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))") in its own container, the server's clock $OFF minutes from UTC; the load at the end $(cut -d' ' -f1 /proc/loadavg))"
fi
