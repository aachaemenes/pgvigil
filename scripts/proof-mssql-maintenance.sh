#!/usr/bin/env bash
# Proof of task 410 (B17, SQL Server maintenance: Ola Hallengren's solution, its jobs, their schedules and outcomes,
# and the maintenance history in its CommandLog): migration 0161, internal/mssql/maintenance.go (the collection
# mssql_maintenance), GET /api/mssql/maintenance - against a SQL Server of the proof's own with the solution installed
# from its public repository at a fixed commit, and rows the proof writes for what a Linux container cannot show.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, curl, python3, network access to
# raw.githubusercontent.com (MaintenanceSolution.sql, MIT licence, Copyright (c) Ola Hallengren: fetched in the run,
# never kept), the wiring patch applied to the tree first, and
#   ADMIN_DSN        a superuser connection to a PostgreSQL in keyword form (default 'host=127.0.0.1 port=5432 user=postgres
#                    dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGES   the SQL Server images: the first the full run, the others the version run (default
#                    '2022-latest 2017-latest 2019-latest').
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment, never a command
# line. Only the collection a step names runs (pgvigil collect -once).
#
# Expected (written before the first run; red on the commit before 0161 at A: 'unknown collection mssql_maintenance',
# the API route 404, 0161's relations missing):
#  A. the first image's container with its Agent on and its time zone not UTC (TZ America/Los_Angeles); a monitor login
#     with VIEW SERVER STATE, db_datareader in msdb and a user in each database; migrate ok; mssql_instance,
#     mssql_jobs and mssql_maintenance each 'ok' as that login.
#  O0 no solution anywhere: ONE info row 'not installed', no warning, no finding; the API's parts answer.
#  O1 MaintenanceSolution.sql (its byte-order mark stripped) installed into a database of its own (pgvdba, not master)
#     with @CreateJobs 'Y': without VIEW DEFINITION the solution's procedures are invisible to the login, so the row
#     reads 'not read: VIEW DEFINITION', never 'not installed'; with VIEW ANY DEFINITION found in pgvdba by the scan of
#     every database the login can enter, the four procedures and dbo.CommandLog present, each version '2026-09-12
#     15:02:38' as the file's own line. A second database with dbo.CommandExecute alone -> a partial install naming
#     what is missing (warning). A database the login cannot enter is named in the 'not installed' row ('not looked
#     into: <db> (no access)') and does not hold it 'not read' (the departure C1).
#  O2 the jobs as installed on Linux (ten; no 'Output File Cleanup'): each matched by what its step calls (the
#     procedure with @BackupType and @Databases, the CommandLog clean-up's DELETE, the two msdb history procedures),
#     shown under Ola's name; ten 'no enabled schedule' warnings. Schedules added -> ok. One job disabled, one schedule
#     disabled -> warning each; one job dropped -> info 'not present', and with the job expected at the instance
#     (409's mssql_config_expect, kind 'job') -> warning, not expected -> off (the job made again by a second install,
#     no row reads its clearing). A job renamed -> still matched by its
#     step; a job of another name whose step calls dbo.IndexOptimize -> matched and judged.
#  O3 the clean-up ages from mssql_jobs.steps: @CleanupTime NULL -> 'never removed', met; 24 on 'USER_DATABASES -
#     FULL' -> info 'under 192 hours'; @MirrorCleanupTime 24 beside @CleanupTime 200 -> met (the mirror's value is not
#     the clean-up time); CommandLog Cleanup at 7 days -> info; sp_purge_jobhistory at 30 -> ok; a step the
#     parser does not know -> 'age not read', never met. Put back -> clear.
#  O4 three jobs run (the two integrity checks and the renamed IndexOptimize): their outcomes equal to msdb's history;
#     DatabaseBackup run directly into a root-owned mode 555 directory -> the CommandLog row with error 3013 read (its
#     message is NULL in CommandLog: the finding names the number and says the job's history has the message), a
#     warning naming the database and the command type; a CommandLog row with error 1205 whose role's job succeeded
#     since (a written row) -> info, no finding (1222 and 5245 follow the same rule, not written); the failure clears
#     after 24 hours (the clock moved in a written row, not waited for).
#  O5 CommandLog read forward: a second read takes only the new IDs (= the hand count past the cursor); a command still
#     running at the read (a written row with no EndTime) is read again until it closes; an open row older than 7 days
#     (written) -> 'never closed' and the cursor moves on; CommandLog truncated (MAX(ID) under the cursor) -> the
#     cursor starts again, no row lost or doubled; StartTime and EndTime stored in UTC from the server's local time
#     (the container's TZ: the stored time 7 or 8 hours after the server's own); without SELECT on dbo.CommandLog ->
#     'not read: SELECT on dbo.CommandLog'.
#  O6 purge() removes mssql_ola_commandlog rows past its days and keeps the newer (written rows).
#  P  data purity (B24b): DBCC DBINFO read by the monitor login without sysadmin in every database it can enter -
#     a database made by the server reads 'on'; a database the login has no user in reads 'not read: no access', never
#     a verdict; a database made before SQL Server 2005 whose flags are 0 (written rows) -> a warning, flags 2 -> on.
#  R  on written rows: no database's purity read -> the rule's own row not read; an application's own
#     dbo.CommandLog alone is no install; a job's age from the step its role matches; an unparsed or too large age not
#     read; a role not expected is off on every row; the instance's 'expected' over the root's 'not expected'; a job name
#     none of the solution's refused; a 1205 no successful run has passed is a warning; a failure read hours ago still a
#     finding while the reads are fresh; a CommandLog the last read did not reach not read; a restored CommandLog's rows
#     not doubled; on an instance without the solution a site's own history job is not judged.
#  Q  (written before its red run) live on the first image: Q1 an open row 8 days old
#     before a running row, 6,000 closed rows and a failure: one read takes the whole table (the failure stored), the
#     forward cursor at MAX(ID)+1 and the open cursor at the running row, nothing behind; the next read re-reads the
#     running row alone; once it ends, ok and the open cursor 0. Q2 a CommandLog whose read fails: the run partial,
#     naming it. Q3 an application's own CommandLog: no history row, no cursor, the run ok. Q4 a second read within
#     the day runs no DBCC DBINFO (the default trace), the flags kept. Q5 a password crossing the 4,000th character:
#     masked whole, then cut. Q6 a full of a database named ...Differential... and a 40-file differential (its command
#     past 4,000 characters): the API's last part says full and differential (W). Written (R): Q7 a read behind the
#     table's end: info, how far; Q8 the CHECKTABLE family and the products' backups in the last part (W); Q9 a site's
#     own history job not in the Jobs grid, the grid's rows carrying their role (W); Q10 a collector's clock ahead of
#     the repository's: no 'not read' after a good read; Q11 a 1205 of an index command while only a backup job
#     succeeded since: a warning, info once IndexOptimize's job succeeded; Q12 @BackupType before @Databases and
#     'USER_DATABASES, -BigDb': the LOG role's job. RED expected on the code before the change (2022 only):
#     Q1's five rows FAIL (the failure not reached under the 5,000 cap; one cursor at the running row, no open
#     cursor; no commandlog_behind; the next read re-reads 5,000; no open cursor row at the end), O5's two cursor
#     rows FAIL (they read the open cursor now), Q2 ('ok', the error dropped), Q3 (a 'not read' history row for
#     pgvapp), Q4 (no purity read time kept: the flags read every hour), Q5 (the token's start stored), W Q6 x2, Q7 (no row),
#     W Q8, W Q9 x2, Q10 (a 'not read' row), Q11 (info), Q12 (no row) FAIL: 20 [graded after the first red run, fold410red2: 18 - Q4's trace count and Q5 passed on the old code; Q4 reads the purity cursor now, Q5 prints the stored tail; red again before the fixes; fold410red3: 19 - Q5 passed again: the import's cut left only the key's first characters, which the row did not look for; the row now reads the stored tail's end]; every other row as on fold410green1.
#  W  GET /api/mssql/maintenance: its parts; the checks part = the function's rows; a bad from 400.
#  V  the version run (2017, 2019): A, O0, the purity read as the monitor login (a verdict, or 'not read' with the
#     error: 2017 and 2019 refuse it with 2571, and the rule's own row is then 'not read') and the database
#     without its user (not read), O1's found install, O2's first state (ten jobs, ten 'no enabled schedule').
#  NOT PROVEN here: SQL Server 2016; Windows (eleven jobs, 'Output File Cleanup' and its age: written rows); Managed
#  Instance (six jobs) and RDS (three): the expected lists on written rows; a server across a daylight saving step;
#  an availability group's secondary replica; a read cut by the run's deadline; a CommandLog truncated and refilled
#  past the old cursor between two reads.
set -uo pipefail
cd "$(dirname "$0")/.."
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
read -r -a IMAGES <<<"${PGVIGIL_IMAGES:-2022-latest 2017-latest 2019-latest}"
OLA_COMMIT=41617578643e722b790ea4d57ef80f8de38ae747
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
PGDB=pgv_mt_$SUF; MON=pgv_mon_$SUF; LOW=pgv_low_$SUF
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SA_PW=$(pw); MON_PW=$(pw); LOW_PW=$(pw); FAILS=0; NP=0; SQL=; SRV_PID=
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_AGENT_ENABLED=true\nTZ=America/Los_Angeles\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
  docker ps -aq --filter "label=pgv-mt-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
np() { echo "NOT PROVEN $*"; NP=$((NP + 1)); }
fail() { echo "FAIL $*"; exit 1; }
# sq: a statement as sa in the container (database $2, default master)
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${SQ_TIMEOUT:-300}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqv() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || bad "$1: $(tr '\n' ' ' <<<"$out" | head -c 300)"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
eqv() { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: got [$2] want [$3]"; fi; }
check() { local got; got=$(pq "$2" 2>&1); eqv "$1" "$got" "$3"; }
collect() { "$BIN" collect -config "${CFG:-$TMPD/m.yaml}" -once "$1" -instance "${2:-sqlbox}" > "$TMPD/collect.out" 2>&1 || { tail -5 "$TMPD/collect.out"; return 1; }; }
col() { local c; for c in "$@"; do collect "$c" || true; done; }
lastrun() { pq "SELECT d.status || coalesce(': ' || d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i ON i.instance_id = d.instance_id WHERE d.collection = '$1' AND i.name = '${2:-sqlbox}'"; }

for t in docker go psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
[[ $ADMIN_DSN == *password=* ]] && fail "ADMIN_DSN holds a password: give it through PGPASSFILE or PGPASSWORD (it would reach psql's command line)"
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
curl -fsSL "https://raw.githubusercontent.com/olahallengren/sql-server-maintenance-solution/$OLA_COMMIT/MaintenanceSolution.sql" -o "$TMPD/ms.sql" || fail "MaintenanceSolution.sql was not fetched"
OLA_VERSION=$(grep -m1 -o -- '--// Version: [0-9-]* [0-9:]*' "$TMPD/ms.sql" | sed 's#--// Version: ##')
BIN=$TMPD/pgvigil
go build -o "$BIN" ./cmd/pgvigil || fail "build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null || fail "repository database"
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"

wait_up() {
  local r=""
  for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" 2>/dev/null); [[ "$r" == 1 ]] && return 0; sleep 2; done
  return 1
}
set_dsn() {
  PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
  export PGV_MT_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
  export PGV_MT_LOW="sqlserver://$LOW:$(urlq "$LOW_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
}
start_server() {  # $1 image tag
  SQL=pgv-mt-$SUF-${1%%-*}
  docker run -d --name "$SQL" --label "pgv-mt-$SUF" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$1" >/dev/null || fail "docker run $1"
  SQLCMD=/opt/mssql-tools18/bin/sqlcmd
  for _ in $(seq 1 30); do docker exec "$SQL" test -e /opt >/dev/null 2>&1 && break; sleep 1; done
  docker exec "$SQL" test -x "$SQLCMD" || SQLCMD=/opt/mssql-tools/bin/sqlcmd
  wait_up || { docker logs --tail 15 "$SQL" 2>&1 | sed 's/^/     container: /'; fail "$1 did not come up"; }
  sq "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON];
CREATE LOGIN [$LOW] WITH PASSWORD = '$LOW_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$LOW];" >/dev/null || fail "the logins"
  sq "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON]; CREATE USER [$LOW] FOR LOGIN [$LOW]; ALTER ROLE db_datareader ADD MEMBER [$LOW];" msdb >/dev/null || fail "the msdb users"
  # the server's own user where the image has one (2017's runs as root): the backup directory its, the other root's, mode 555
  docker exec -u 0 "$SQL" bash -c 'mkdir -p /var/opt/mssql/backup /var/opt/mssql/nowrite && { ! id mssql >/dev/null 2>&1 || chown mssql /var/opt/mssql/backup; } && chown root:root /var/opt/mssql/nowrite && chmod 555 /var/opt/mssql/nowrite' || fail "the backup directories"
  set_dsn
  cat > "$TMPD/m.yaml" <<YAML
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_MT_MON
    tags: ["env:proof$SUF"]
YAML
  cat > "$TMPD/m-low.yaml" <<YAML
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox_low
    engine: sqlserver
    dsn: env:PGV_MT_LOW
YAML
}
BASE="mssql_instance mssql_jobs mssql_maintenance"

echo "== A: ${IMAGES[0]}"
start_server "${IMAGES[0]}"
ok "SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"), the solution $OLA_VERSION"
"$BIN" migrate -config "$TMPD/m.yaml" > "$TMPD/migrate.out" 2>&1 && ok "migrate" || { tail -20 "$TMPD/migrate.out"; fail "migrate"; }
for c in $BASE; do
  collect "$c" || true
  eqv "A: $c runs as the monitor login" "$(lastrun "$c")" "ok"
done
[[ $(lastrun mssql_maintenance) == ok ]] || fail "A: mssql_maintenance did not run: nothing below can be read"
IID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")

# ---- helpers of the sections below ---------------------------------------------------------------------------------
mkdb() {  # $1 name: a database with the monitor login's user
  sq "CREATE DATABASE [$1];" >/dev/null && sq "CREATE USER [$MON] FOR LOGIN [$MON];" "$1" >/dev/null
}
# st: a rule's rows as 'object status' (the rule's own row: its status); det: their details
st() { pq "SELECT coalesce(string_agg(CASE WHEN object = '' THEN status ELSE object || ' ' || status END, ', ' ORDER BY object), 'no row') FROM pgvigil.mssql_maintenance_checks_of(${3:-$IID}) WHERE check_name = '$1'${2:+ AND object = '$2'}"; }
det() { pq "SELECT coalesce(string_agg(detail, ' | ' ORDER BY object), 'no row') FROM pgvigil.mssql_maintenance_checks_of(${3:-$IID}) WHERE check_name = '$1'${2:+ AND object = '$2'}"; }
rule() { eqv "$1" "$(st "$2" "${4:-}" "${5:-}")" "$3"; }
cnt() { pq "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of(${3:-$IID}) WHERE check_name = '$1' AND status = '$2'"; }
expect_job() {  # $1 op (set|inherit) $2 key [$3 the value's JSON]
  pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"$1\",\"level\":\"instance\",\"instance_id\":$IID,\"kind\":\"job\",\"key\":\"$2\"${3:+,\"value\":$3}}'::jsonb)->>'outcome'"
}
install() {  # the solution into pgvdba, its CONFIG lines set (the byte-order mark stripped: sqlcmd reads stdin as text)
  LC_ALL=C sed -e '1s/^\xEF\xBB\xBF//' -e "s/^USE \[master\]/USE [pgvdba]/" -e "s/^DECLARE @CreateJobs nvarchar(max) *= *'[YN]'/DECLARE @CreateJobs nvarchar(max) = 'Y'/" \
      -e "s#^DECLARE @BackupDirectory nvarchar(max) *= *NULL#DECLARE @BackupDirectory nvarchar(max) = N'/var/opt/mssql/backup'#" "$TMPD/ms.sql" > "$TMPD/ms2.sql"
  docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -i /dev/stdin' < "$TMPD/ms2.sql" > "$TMPD/install.out" 2>&1
}
cl() { sq "SELECT count(*) FROM dbo.CommandLog" pgvdba; }   # the CommandLog's rows by hand
stored() { pq "SELECT count(*) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba'${1:+ AND $1}"; }
runjob() {  # $1 job name: started and waited for (its history's outcome row)
  local before; before=$(sq "SELECT count(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$1' AND h.step_id = 0")
  sq "EXEC msdb.dbo.sp_start_job @job_name = N'$1';" >/dev/null
  for _ in $(seq 1 90); do [[ $(sq "SELECT count(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$1' AND h.step_id = 0") -gt $before ]] && return 0; sleep 2; done
  return 1
}
# step: a job's first step set to a command (written in a file: no quote of it is taken by the shell)
step() {  # $1 job name, the command on stdin
  local f="$TMPD/step.sql"
  { printf "EXEC msdb.dbo.sp_update_jobstep @job_name = N'%s', @step_id = 1, @command = N'" "$1"; sed "s/'/''/g" | tr -d '\n'; printf "';\n"; } > "$f"
  sq "$(cat "$f")" >/dev/null || bad "setup: the step of $1"
}
LINUX_JOBS=10

echo "== O0: no solution anywhere"
mkdb pgvp1
sq "CREATE DATABASE pgvnouser;" >/dev/null   # the monitor login has no user here
sq "GRANT VIEW ANY DEFINITION TO [$MON];" >/dev/null   # it may look into every database it can enter
col mssql_confcheck mssql_maintenance
rule "O0 no solution: one info row, never a warning" "maintenance solution installed" info
eqv "O0 ... 'not installed', the databases it cannot enter named, no finding" "$(det 'maintenance solution installed') / $(pq "SELECT count(*) FROM pgvigil.mssql_maintenance_findings WHERE instance_id = $IID")" "not installed: no database read holds the solution (another maintenance tool may be in use); not looked into: model (no access), pgvnouser (no access) / 0"
check "O0 no job row while the solution is nowhere" "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name LIKE 'maintenance job%'" 0
# B24b: data purity in every database the login can enter; one it cannot is 'not read', never a verdict
rule "P a database the monitor login has no user in: data purity not read, not a verdict" "data purity checks" "pgvnouser not read" pgvnouser
eqv "P ... saying why" "$(det 'data purity checks' pgvnouser)" "not read: no access (the login cannot enter the database)"
check "P pgvp1, made by this server: purity read by the monitor login (no sysadmin) and on" "SELECT purity_read || ' ' || purity_on || ' ' || (create_version >= 611) FROM pgvigil.mssql_maint_database WHERE instance_id = $IID AND database_name = 'pgvp1'" "true true true"
check "P ... the rule's own row: on where read" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'data purity checks' AND object = ''" ok

echo "== O1: the solution installed into a database of its own"
mkdb pgvdba
sq "REVOKE VIEW ANY DEFINITION FROM [$MON];" >/dev/null
install; eqv "O1 MaintenanceSolution.sql installed (@CreateJobs Y, a backup directory)" "$?" 0
sq "GRANT SELECT ON dbo.CommandLog TO [$MON];" pgvdba >/dev/null || bad "O1 setup: SELECT on dbo.CommandLog for the monitor login"
col mssql_maintenance
rule "O1 without VIEW DEFINITION its procedures are invisible to the login: not read, never 'not installed'" "maintenance solution installed" "not read"
check "O1 ... the row says which right" "SELECT detail LIKE '%VIEW DEFINITION%' FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance solution installed'" t
check "O1 ... pgvdba's own row: not looked into, saying which right (its CommandLog visible by the SELECT grant)" "SELECT install_read || ' ' || (note LIKE '%VIEW DEFINITION%') FROM pgvigil.mssql_maint_database WHERE instance_id = $IID AND database_name = 'pgvdba'" "false true"
sq "GRANT VIEW ANY DEFINITION TO [$MON];" >/dev/null
col mssql_maintenance
rule "O1 with VIEW ANY DEFINITION: found in pgvdba" "maintenance solution installed" "pgvdba ok"
check "O1 ... the four procedures and dbo.CommandLog, each version the file's own" "SELECT array_to_string(objects, ',') || ' ' || (SELECT string_agg(DISTINCT v, ',') FROM jsonb_each_text(versions) t(k, v)) FROM pgvigil.mssql_maint_database WHERE instance_id = $IID AND database_name = 'pgvdba'" "CommandExecute,CommandLog,DatabaseBackup,DatabaseIntegrityCheck,IndexOptimize $OLA_VERSION"
mkdb pgvpart
sqv "O1 setup: a database with dbo.CommandExecute alone" "EXEC (N'CREATE PROCEDURE dbo.CommandExecute AS SELECT 1;');" pgvpart
col mssql_maintenance
rule "O1 a part of the solution: a warning naming what is missing" "maintenance solution installed" "pgvdba ok, pgvpart warning"
eqv "O1 ... its words" "$(det 'maintenance solution installed' pgvpart)" "a part of the solution: missing CommandLog, DatabaseBackup, DatabaseIntegrityCheck, IndexOptimize"
sqv "O1 setup: the part dropped" "DROP PROCEDURE dbo.CommandExecute;" pgvpart

echo "== O2: the jobs as installed on Linux"
col mssql_jobs mssql_maintenance
check "O2 ten jobs on Linux, each matched by what its step calls and shown under Ola's name" "SELECT count(DISTINCT split_part(object, ': ', 1)) FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance job enabled'" "$LINUX_JOBS"
check "O2 ... no 'Output File Cleanup' on Linux" "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE object LIKE 'Output File Cleanup%'" 0
eqv "O2 ten 'no enabled schedule' warnings, every job enabled" "$(cnt 'maintenance job scheduled' warning) $(cnt 'maintenance job enabled' ok)" "$LINUX_JOBS $LINUX_JOBS"
sqv "O2 setup: a daily schedule for every job" "DECLARE @n sysname; DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM msdb.dbo.sysjobs;
OPEN c; FETCH NEXT FROM c INTO @n; WHILE @@FETCH_STATUS = 0 BEGIN
  EXEC msdb.dbo.sp_add_jobschedule @job_name = @n, @name = N'pgv daily', @freq_type = 4, @freq_interval = 1, @active_start_date = 20991231, @active_start_time = 10000;
  FETCH NEXT FROM c INTO @n; END; CLOSE c; DEALLOCATE c;"
col mssql_jobs mssql_maintenance
eqv "O2 scheduled: every job ok" "$(cnt 'maintenance job scheduled' ok) $(cnt 'maintenance job scheduled' warning)" "$LINUX_JOBS 0"
sqv "O2 setup: IndexOptimize disabled, the schedules of the integrity checks disabled" "EXEC msdb.dbo.sp_update_job @job_name = N'IndexOptimize - USER_DATABASES', @enabled = 0;
UPDATE s SET enabled = 0 FROM msdb.dbo.sysschedules s JOIN msdb.dbo.sysjobschedules js ON js.schedule_id = s.schedule_id JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id WHERE j.name LIKE N'DatabaseIntegrityCheck%';"
col mssql_jobs mssql_maintenance
rule "O2 a job disabled: a warning" "maintenance job enabled" "IndexOptimize - USER_DATABASES: IndexOptimize - USER_DATABASES warning" "IndexOptimize - USER_DATABASES: IndexOptimize - USER_DATABASES"
eqv "O2 ... the jobs whose schedule is disabled: a warning each" "$(cnt 'maintenance job scheduled' warning)" 2
sqv "O2 setup: back (enabled, every schedule on)" "EXEC msdb.dbo.sp_update_job @job_name = N'IndexOptimize - USER_DATABASES', @enabled = 1; UPDATE msdb.dbo.sysschedules SET enabled = 1 WHERE name = N'pgv daily';"
col mssql_jobs mssql_maintenance
eqv "O2 put back: clear" "$(cnt 'maintenance job scheduled' warning) $(cnt 'maintenance job enabled' warning)" "0 0"
sqv "O2 setup: sp_purge_jobhistory dropped" "EXEC msdb.dbo.sp_delete_job @job_name = N'sp_purge_jobhistory';"
col mssql_jobs mssql_maintenance
rule "O2 a job the solution makes, dropped: info 'not present'" "maintenance job" "sp_purge_jobhistory info" sp_purge_jobhistory
eqv "O2 setup: it expected at the instance (kind job)" "$(expect_job set expected '["sp_purge_jobhistory"]')" done
rule "O2 ... expected: a warning" "maintenance job" "sp_purge_jobhistory warning" sp_purge_jobhistory
eqv "O2 setup: not expected instead" "$(expect_job inherit expected) $(expect_job set not_expected '["sp_purge_jobhistory"]')" "done done"
rule "O2 ... not expected: off" "maintenance job" "sp_purge_jobhistory off" sp_purge_jobhistory
eqv "O2 setup: the expectation taken away" "$(expect_job inherit not_expected)" done
install; eqv "O2 setup: the job made again (the solution installed again)" "$?" 0
sqv "O2 setup: IndexOptimize renamed, another job calling dbo.IndexOptimize" "EXEC msdb.dbo.sp_update_job @job_name = N'IndexOptimize - USER_DATABASES', @new_name = N'pgv nightly index';
EXEC msdb.dbo.sp_add_job @job_name = N'pgv extra index', @owner_login_name = N'sa';
EXEC msdb.dbo.sp_add_jobstep @job_name = N'pgv extra index', @step_name = N'one', @subsystem = N'TSQL', @database_name = N'pgvdba', @command = N'EXECUTE [dbo].[IndexOptimize] @Databases = N''pgvp1''';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'pgv extra index';"
col mssql_jobs mssql_maintenance
check "O2 a job renamed is still matched by its step, and a job of another name calling dbo.IndexOptimize is matched and judged" "SELECT string_agg(object, ', ' ORDER BY object) FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance job enabled' AND object LIKE 'IndexOptimize%'" "IndexOptimize - USER_DATABASES: pgv extra index, IndexOptimize - USER_DATABASES: pgv nightly index"
check "O2 ... and the role is not 'not present'" "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance job' AND object = 'IndexOptimize - USER_DATABASES'" 0

echo "== O3: the clean-up ages"
FULL='DatabaseBackup - USER_DATABASES - FULL: DatabaseBackup - USER_DATABASES - FULL'
rule "O3 @CleanupTime NULL: never removed, met" "maintenance clean-up age" "$FULL ok" "$FULL"
eqv "O3 ... its words" "$(det 'maintenance clean-up age' "$FULL")" "the backup files are never removed by the job"
FULLCMD=$(sq "SELECT command FROM msdb.dbo.sysjobsteps s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = N'DatabaseBackup - USER_DATABASES - FULL' AND s.step_id = 1")
CLCMD=$(sq "SELECT command FROM msdb.dbo.sysjobsteps s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = N'CommandLog Cleanup' AND s.step_id = 1")
BHCMD=$(sq "SELECT command FROM msdb.dbo.sysjobsteps s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = N'sp_delete_backuphistory' AND s.step_id = 1")
step 'DatabaseBackup - USER_DATABASES - FULL' <<'CMD'
EXECUTE [dbo].[DatabaseBackup] @Databases = 'USER_DATABASES', @Directory = N'/var/opt/mssql/backup', @BackupType = 'FULL', @CleanupTime = 24, @LogToTable = 'Y'
CMD
step 'CommandLog Cleanup' <<'CMD'
DELETE FROM [dbo].[CommandLog] WHERE StartTime < DATEADD(dd,-7,GETDATE())
CMD
step 'sp_delete_backuphistory' <<'CMD'
SELECT 1
CMD
col mssql_jobs mssql_maintenance
eqv "O3 @CleanupTime 24: info under 192 hours; CommandLog Cleanup at 7 days: info; a step whose age is unknown: not read" "$(st 'maintenance clean-up age' "$FULL" | sed 's/.*FULL //') / $(st 'maintenance clean-up age' 'CommandLog Cleanup: CommandLog Cleanup' | sed 's/.*Cleanup //') / $(st 'maintenance clean-up age' 'sp_delete_backuphistory: sp_delete_backuphistory' | sed 's/.*backuphistory //')" "info / info / not read"
check "O3 ... no finding for an age (info)" "SELECT count(*) FROM pgvigil.mssql_maintenance_findings WHERE instance_id = $IID AND check_name = 'maintenance clean-up age'" 0
step 'DatabaseBackup - USER_DATABASES - FULL' <<'CMD'
EXECUTE [dbo].[DatabaseBackup] @Databases = 'USER_DATABASES', @Directory = N'/var/opt/mssql/backup', @BackupType = 'FULL', @MirrorCleanupTime = 24, @CleanupTime = 200, @LogToTable = 'Y'
CMD
col mssql_jobs mssql_maintenance
rule "O3 @MirrorCleanupTime 24 beside @CleanupTime 200: met (the mirror's value is not the clean-up time)" "maintenance clean-up age" "$FULL ok" "$FULL"
rule "O3 the history clean-up at 30 days: ok" "maintenance clean-up age" "sp_purge_jobhistory: sp_purge_jobhistory ok" "sp_purge_jobhistory: sp_purge_jobhistory"
step 'DatabaseBackup - USER_DATABASES - FULL' <<<"$FULLCMD"
step 'CommandLog Cleanup' <<<"$CLCMD"
step 'sp_delete_backuphistory' <<<"$BHCMD"
col mssql_jobs mssql_maintenance
eqv "O3 put back: clear" "$(cnt 'maintenance clean-up age' info) $(cnt 'maintenance clean-up age' 'not read')" "0 0"

echo "== O4: the jobs run, a backup that fails"
for j in 'DatabaseIntegrityCheck - SYSTEM_DATABASES' 'DatabaseIntegrityCheck - USER_DATABASES' 'pgv nightly index'; do runjob "$j" || bad "O4 the job $j did not end"; done
col mssql_jobs mssql_maintenance
check "O4 the jobs run: their outcomes as msdb's history has them" "SELECT string_agg(name || '=' || last_outcome, ', ' ORDER BY name) FROM pgvigil.mssql_jobs WHERE instance_id = $IID AND name IN ('DatabaseIntegrityCheck - SYSTEM_DATABASES', 'DatabaseIntegrityCheck - USER_DATABASES', 'pgv nightly index')" "$(sq "SELECT STRING_AGG(j.name + '=' + CAST(h.run_status AS varchar(2)), ', ') WITHIN GROUP (ORDER BY j.name) FROM msdb.dbo.sysjobs j CROSS APPLY (SELECT TOP (1) run_status FROM msdb.dbo.sysjobhistory x WHERE x.job_id = j.job_id AND x.step_id = 0 ORDER BY x.instance_id DESC) h WHERE j.name IN (N'DatabaseIntegrityCheck - SYSTEM_DATABASES', N'DatabaseIntegrityCheck - USER_DATABASES', N'pgv nightly index')")"
check "O4 the CommandLog read: as many rows as the table holds" "SELECT count(*) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba'" "$(cl)"
sq "EXEC dbo.DatabaseBackup @Databases = N'pgvp1', @Directory = N'/var/opt/mssql/nowrite', @BackupType = 'FULL', @LogToTable = 'Y';" pgvdba >/dev/null 2>&1
col mssql_maintenance
check "O4 a backup into a directory the server may not write: the CommandLog row's error 3013, a warning naming the database and the command" "SELECT status || ' ' || (object LIKE 'pgvdba: pgvp1 BACKUP_DATABASE #%') FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance command failed' AND value = '3013'" "warning true"
check "O4 ... its message is not in CommandLog: the row says where it is" "SELECT detail LIKE '%the message is not in CommandLog (see the job''s history)%' FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance command failed' AND value = '3013'" t
eqv "O4 ... a finding" "$(pq "SELECT count(*) FROM pgvigil.mssql_maintenance_findings WHERE instance_id = $IID AND check_name = 'maintenance command failed'")" 1
pq "INSERT INTO pgvigil.mssql_ola_commandlog (instance_id, database_name, epoch, id, db, command_type, start_at, end_at, error_number, status, snapshot_at) VALUES ($IID, 'pgvdba', 99, 1, 'pgvp1', 'ALTER_INDEX', now() - interval '1 hour', now() - interval '1 hour', 1205, 'failed', now())" >/dev/null
check "O4 a deadlock victim (1205, a written row) while no job of the solution failed since: info, no finding" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance command failed' AND value = '1205'" info
pq "UPDATE pgvigil.mssql_ola_commandlog SET start_at = now() - interval '25 hours' WHERE instance_id = $IID AND error_number = 3013" >/dev/null
check "O4 the failure 25 hours old (the clock moved in a written row): cleared" "SELECT count(*) FROM pgvigil.mssql_maintenance_findings WHERE instance_id = $IID AND check_name = 'maintenance command failed'" 0
pq "DELETE FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND epoch = 99" >/dev/null

echo "== O5: the CommandLog read forward"
O5B=$(cl)
runjob 'DatabaseIntegrityCheck - SYSTEM_DATABASES' || bad "O5 the job did not end"
col mssql_maintenance
eqv "O5 a second read takes only the new IDs: the rows of the newest read's snapshot = the IDs added" "$(stored "snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba')")" "$(( $(cl) - O5B ))"
eqv "O5 ... every row stored" "$(stored)" "$(cl)"
check "O5 ... the cursor one past the table's last ID" "SELECT last_seq FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance:pgvdba'" "$(( $(sq "SELECT MAX(ID) FROM dbo.CommandLog" pgvdba) + 1 ))"
sqv "O5 setup: a command still running (a row with no EndTime), and one opened 8 days ago" "INSERT dbo.CommandLog (DatabaseName, CommandType, Command, StartTime) VALUES (N'pgvp1', N'ALTER_INDEX', N'ALTER INDEX x ON t REBUILD', SYSDATETIME());
INSERT dbo.CommandLog (DatabaseName, CommandType, Command, StartTime) VALUES (N'pgvp1', N'UPDATE_STATISTICS', N'UPDATE STATISTICS t', DATEADD(day, -8, SYSDATETIME()));" pgvdba
RUNID=$(sq "SELECT MIN(ID) FROM dbo.CommandLog WHERE EndTime IS NULL AND StartTime > DATEADD(day, -1, SYSDATETIME())" pgvdba)
col mssql_maintenance
check "O5 the running command: read, and the open cursor at it" "SELECT (SELECT status FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND id = $RUNID) || ' ' || coalesce((SELECT last_seq::text FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance_open:pgvdba'), 'no open cursor')" "running $RUNID"
check "O5 the one opened 8 days ago: never closed, the cursor not held by it" "SELECT string_agg(status, ',') FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND command_type = 'UPDATE_STATISTICS' AND end_at IS NULL" "never closed"
sqv "O5 setup: the running command ends" "UPDATE dbo.CommandLog SET EndTime = SYSDATETIME(), ErrorNumber = 0 WHERE ID = $RUNID;" pgvdba
col mssql_maintenance
check "O5 ... read again once it ends: ok, the forward cursor one past the table's end, no row open" "SELECT (SELECT status FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND id = $RUNID) || ' ' || (SELECT last_seq FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance:pgvdba') || ' ' || coalesce((SELECT last_seq::text FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance_open:pgvdba'), 'no open cursor')" "ok $(( $(sq "SELECT MAX(ID) FROM dbo.CommandLog" pgvdba) + 1 )) 0"
OFF=$(sq "SELECT DATEPART(TZOFFSET, SYSDATETIMEOFFSET())")
LOCAL=$(sq "SELECT CONVERT(varchar(19), StartTime, 126) FROM dbo.CommandLog WHERE ID = $RUNID" pgvdba)
eqv "O5 the server's clock is not UTC (the container's TZ)" "$([[ $OFF =~ ^-?[0-9]+$ && $OFF != 0 ]] && echo 'not UTC' || echo "offset [$OFF]")" "not UTC"
check "O5 ... the stored start is the server's own time moved to UTC" "SELECT to_char(start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') = to_char('$LOCAL'::timestamp - make_interval(mins => $OFF), 'YYYY-MM-DD HH24:MI:SS') FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND id = $RUNID" t
S2=$(stored)
sqv "O5 setup: the CommandLog truncated" "TRUNCATE TABLE dbo.CommandLog;" pgvdba
runjob 'DatabaseIntegrityCheck - SYSTEM_DATABASES' || bad "O5 the job did not end"
col mssql_maintenance
eqv "O5 truncated: the cursor starts again, the rows read before kept, the new ones read (a new epoch)" "$(stored 'epoch = 0') $(stored 'epoch = 1')" "$S2 $(cl)"
sq "GRANT VIEW ANY DEFINITION TO [$LOW];" >/dev/null; sq "CREATE USER [$LOW] FOR LOGIN [$LOW];" pgvdba >/dev/null
CFG=$TMPD/m-low.yaml collect mssql_maintenance sqlbox_low || true
LID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox_low'")
rule "O5 a login that sees CommandLog without SELECT on it: the history not read" "maintenance history read" "pgvdba not read" "" "$LID"
eqv "O5 ... saying which right" "$(det 'maintenance history read' '' "$LID")" "not read: SELECT on dbo.CommandLog"

echo "== Q: live: the CommandLog read"
# Q1 (P2-1, P2-2, P4-1, P4-7): an open row 8 days old BEFORE a running row, then 6,000 closed rows and a failure.
# One read takes the whole table; the forward cursor goes past its end, the open cursor stays at the running row (the
# 8-day row before it never holds it); the next read re-reads the running row alone.
sqv "Q1 setup: an open row 8 days old, a running row, 6,000 closed rows, a failure" "INSERT dbo.CommandLog (DatabaseName, CommandType, Command, StartTime) VALUES (N'pgvp1', N'UPDATE_STATISTICS', N'UPDATE STATISTICS q1old', DATEADD(day, -8, SYSDATETIME()));
INSERT dbo.CommandLog (DatabaseName, CommandType, Command, StartTime) VALUES (N'pgvp1', N'ALTER_INDEX', N'ALTER INDEX q1 ON t REBUILD', SYSDATETIME());
INSERT dbo.CommandLog (DatabaseName, CommandType, Command, StartTime, EndTime, ErrorNumber) SELECT TOP (6000) N'pgvp1', N'BACKUP_LOG', N'BACKUP LOG [pgvp1] TO DISK = N''/q1''', SYSDATETIME(), SYSDATETIME(), 0 FROM sys.all_objects a CROSS JOIN sys.all_objects b;
INSERT dbo.CommandLog (DatabaseName, CommandType, Command, StartTime, EndTime, ErrorNumber, ErrorMessage) VALUES (N'pgvp1', N'BACKUP_LOG', N'BACKUP LOG [pgvp1] TO DISK = N''/q1f''', SYSDATETIME(), SYSDATETIME(), 50000, N'q1 failure');" pgvdba
Q1RUN=$(sq "SELECT ID FROM dbo.CommandLog WHERE Command = N'ALTER INDEX q1 ON t REBUILD'" pgvdba)
Q1MAX=$(sq "SELECT MAX(ID) FROM dbo.CommandLog" pgvdba)
col mssql_maintenance
check "Q1 one read takes the whole table: the failure after 6,000 rows stored" "SELECT count(*) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND error_number = 50000" 1
check "Q1 ... the forward cursor one past the table's end, the open cursor at the running row (the 8-day row before it never holds it)" "SELECT (SELECT last_seq FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance:pgvdba') || ' ' || coalesce((SELECT last_seq::text FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance_open:pgvdba'), 'no open cursor')" "$((Q1MAX + 1)) $Q1RUN"
check "Q1 ... nothing behind the table's end" "SELECT coalesce(commandlog_behind::text, 'null') FROM pgvigil.mssql_maint_database WHERE instance_id = $IID AND database_name = 'pgvdba'" 0
col mssql_maintenance
check "Q1 the next read re-reads the running row alone (the rows of the newest read's snapshot)" "SELECT count(*) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba')" 1
sqv "Q1 setup: the running row ends" "UPDATE dbo.CommandLog SET EndTime = SYSDATETIME(), ErrorNumber = 0 WHERE ID = $Q1RUN;" pgvdba
col mssql_maintenance
check "Q1 ... once it ends: ok, no row open" "SELECT (SELECT status FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND id = $Q1RUN ORDER BY epoch DESC LIMIT 1) || ' ' || coalesce((SELECT last_seq::text FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance_open:pgvdba'), 'no open cursor')" "ok 0"
# Q2 (P2-4): a CommandLog read that fails (a column renamed): the run partial, saying where - never 'ok' with nothing said
sqv "Q2 setup: a column of pgvdba's CommandLog renamed (its read fails)" "EXEC sp_rename N'dbo.CommandLog.ErrorMessage', N'ErrorText', N'COLUMN';" pgvdba
col mssql_maintenance
Q2=$(lastrun mssql_maintenance)
eqv "Q2 a CommandLog read that fails: the run partial, naming the CommandLog and the error" "$([[ $Q2 == partial:*'dbo.CommandLog in pgvdba'*'Invalid column name'* ]] && echo said || echo "[${Q2:0:160}]")" said
sqv "Q2 setup: the column back" "EXEC sp_rename N'dbo.CommandLog.ErrorText', N'ErrorMessage', N'COLUMN';" pgvdba
# Q3 (P2-5): an application's own dbo.CommandLog (other columns), none of the procedures: never read as the solution's
mkdb pgvapp
sqv "Q3 setup: an application's own dbo.CommandLog" "CREATE TABLE dbo.CommandLog (ID int IDENTITY PRIMARY KEY, Msg nvarchar(100)); INSERT dbo.CommandLog (Msg) VALUES (N'app row');" pgvapp
col mssql_maintenance
eqv "Q3 an application's own CommandLog is not read as the solution's: no history row, no cursor, the run ok" "$(pq "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'maintenance history read' AND object = 'pgvapp'") $(pq "SELECT count(*) FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source IN ('mssql_maintenance:pgvapp', 'mssql_maintenance_open:pgvapp')") $(lastrun mssql_maintenance | cut -c1-7)" "0 0 ok"
sq "DROP DATABASE pgvapp;" >/dev/null
# Q4 (P2-6): data purity read once a day - a second read within the day leaves pgvp1's purity read time (its cursor)
# as it was and runs no DBCC DBINFO; the day's flags kept. The default trace's DBCC DBINFO events over the read are
# printed, not graded (the first red run saw none on the code that reads every hour: not recorded, or not flushed yet)
TRC=$(sq "SELECT path FROM sys.traces WHERE is_default = 1")
dbinfo() { [[ -n "$TRC" ]] && sq "SELECT COUNT(*) FROM sys.fn_trace_gettable(N'$TRC', DEFAULT) WHERE EventClass = 116 AND CAST(TextData AS nvarchar(max)) LIKE N'%DBINFO%'" || echo 0; }
pat() { pq "SELECT coalesce((SELECT last_event_at::text FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_maintenance_purity:pgvp1'), 'no purity cursor')"; }
Q4B=$(pat); Q4TB=$(dbinfo); col mssql_maintenance; Q4A=$(pat); Q4TA=$(dbinfo)
eqv "Q4 data purity read once a day: a second read within the day leaves pgvp1's purity read time as it was" "$([[ $Q4B != no* && $Q4A == "$Q4B" ]] && echo kept || echo "[$Q4B] [$Q4A]")" kept
echo "     Q4 the default trace's DBCC DBINFO events over that read: $((Q4TA - Q4TB)) (not graded)"
check "Q4 ... the day's flags kept on the row" "SELECT purity_read || ' ' || purity_on FROM pgvigil.mssql_maint_database WHERE instance_id = $IID AND database_name = 'pgvp1'" "true true"
# Q5 (P2-7): a command whose PASSWORD literal crosses the 4,000th character: masked whole, then cut
sqv "Q5 setup: a command whose password crosses the 4,000th character" "INSERT dbo.CommandLog (DatabaseName, CommandType, Command, StartTime, EndTime, ErrorNumber) VALUES (N'pgvp1', N'BACKUP_DATABASE', REPLICATE(CAST(N'x' AS nvarchar(max)), 3975) + N', PASSWORD = N''Q5cut$SUF''', SYSDATETIME(), SYSDATETIME(), 0);" pgvdba
col mssql_maintenance
Q5T=$(pq "SELECT right(command, 40) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND database_name = 'pgvdba' AND command LIKE 'xxxxxxxxxx%' ORDER BY snapshot_at DESC LIMIT 1")
# (on the code before the fix the import's own cut takes the end of an unmasked tail: '<masked>'Q5c' - the key's
# first characters stored, probe q5): the stored text ends with the masked literal itself
eqv "Q5 the command masked before it is cut: the stored text ends with the masked literal (the tail printed when not)" "$([[ $Q5T == *"PASSWORD = '<masked>'" ]] && echo masked || echo "[$Q5T]")" masked
# Q6 (P3-1): a full backup of a database whose name holds 'Differential', a full and a 40-file differential of pgvp1
# (its command past 4,000 characters): read through the API's last part in W
mkdb pgvDifferentialPricing
sqv "Q6 setup: the backups" "EXEC dbo.DatabaseBackup @Databases = N'pgvDifferentialPricing', @Directory = N'/var/opt/mssql/backup', @BackupType = 'FULL', @LogToTable = 'Y';
EXEC dbo.DatabaseBackup @Databases = N'pgvp1', @Directory = N'/var/opt/mssql/backup', @BackupType = 'FULL', @LogToTable = 'Y';
EXEC dbo.DatabaseBackup @Databases = N'pgvp1', @Directory = N'/var/opt/mssql/backup', @BackupType = 'DIFF', @NumberOfFiles = 40, @LogToTable = 'Y';" pgvdba
eqv "Q6 setup: the differential's command is longer than 4,000 characters" "$(sq "SELECT CASE WHEN MAX(LEN(Command)) > 4000 THEN 'long' ELSE 'short ' + CAST(MAX(LEN(Command)) AS varchar(10)) END FROM dbo.CommandLog WHERE DatabaseName = N'pgvp1' AND CommandType = N'BACKUP_DATABASE' AND Command LIKE N'%, DIFFERENTIAL%'" pgvdba)" long
col mssql_maintenance

echo "== O6: purge"
pq "INSERT INTO pgvigil.mssql_ola_commandlog (instance_id, database_name, epoch, id, command_type, start_at, status, snapshot_at) VALUES ($IID, 'pgvdba', 98, 1, 'BACKUP_LOG', now() - interval '400 days', 'ok', now()), ($IID, 'pgvdba', 98, 2, 'BACKUP_LOG', now() - interval '2 days', 'ok', now())" >/dev/null
pq "SELECT pgvigil.purge(30)" >/dev/null || bad "O6 purge() failed"
check "O6 purge() removes the CommandLog rows past the retention and keeps the newer" "SELECT string_agg(id::text, ',' ORDER BY id) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND epoch = 98" 2
pq "DELETE FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $IID AND epoch = 98" >/dev/null

echo "== P: data purity on written rows"
OLDI=$(pq "SELECT pgvigil.ensure_instance('old$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "SELECT pgvigil.import_mssql_maintenance($OLDI, now(), '[{\"kind\":\"part\",\"part\":\"install\",\"read\":1},{\"kind\":\"database\",\"database_name\":\"old80\",\"install_read\":1,\"objects\":[],\"purity_read\":1,\"create_version\":539,\"dbcc_flags\":0,\"purity_on\":0},{\"kind\":\"database\",\"database_name\":\"old80b\",\"install_read\":1,\"objects\":[],\"purity_read\":1,\"create_version\":539,\"dbcc_flags\":2,\"purity_on\":1}]'::jsonb)" >/dev/null || bad "P the written rows"
rule "P a database made before SQL Server 2005 whose flags are 0: a warning; flags 2: on (no row)" "data purity checks" "old80 warning" "" "$OLDI"
np "P a database made before SQL Server 2005, live: no such database can be made by SQL Server 2017 or later (written rows)"

echo "== R: on written rows of instances of the proof's own"
# a written instance with the solution installed (all five objects), its jobs written into mssql_jobs
RI=$(pq "SELECT pgvigil.ensure_instance('rv$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
rimp() { pq "SELECT pgvigil.import_mssql_maintenance($RI, clock_timestamp(), '$1'::jsonb)" >/dev/null || bad "R the written maintenance rows"; }
rjob() {  # $1 job id $2 name $3 enabled $4 enabled schedules $5 last outcome $6 last run (an SQL time); the steps' JSON on stdin
  local steps; steps=$(sed "s/'/''/g")   # a quote of the JSON doubled for the SQL literal (a shell argument would lose it)
  pq "INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, description, enabled_schedules, last_outcome, last_run_at, steps)
      VALUES ($RI, '$1', now(), '$2', $3, NULL, $4, $5, $6, '$steps'::jsonb)
      ON CONFLICT (instance_id, job_id) DO UPDATE SET name = EXCLUDED.name, enabled = EXCLUDED.enabled, enabled_schedules = EXCLUDED.enabled_schedules,
        last_outcome = EXCLUDED.last_outcome, last_run_at = EXCLUDED.last_run_at, steps = EXCLUDED.steps" >/dev/null || bad "R the written job $2"; }
pq "INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($RI, 'mssql_jobs', now(), 'ok') ON CONFLICT DO NOTHING" >/dev/null || bad "R the written jobs' read"
ALLOBJ='"objects":["CommandExecute","CommandLog","DatabaseBackup","DatabaseIntegrityCheck","IndexOptimize"]'
# S1: no database's purity flag read (2017 / 2019 refuse DBINFO everywhere): the rule's own row is not read, never ok
rimp "[{\"kind\":\"part\",\"part\":\"install\",\"read\":1},{\"kind\":\"database\",\"database_name\":\"dba\",\"install_read\":1,$ALLOBJ,\"purity_read\":0,\"purity_note\":\"not read: 2571\"},{\"kind\":\"database\",\"database_name\":\"app\",\"install_read\":1,\"objects\":[\"CommandLog\"],\"purity_read\":0,\"purity_note\":\"not read: 2571\"}]"
check "R S1 no database's purity flag read: the rule's own row not read, never ok" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'data purity checks' AND object = ''" "not read"
# S11: a database with an application's own dbo.CommandLog and none of the procedures is no install
check "R S11 a dbo.CommandLog alone (an application's own) is no part of the solution" "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance solution installed' AND object = 'app'" 0
# S6: a job with a SYSTEM_DATABASES FULL step (@CleanupTime NULL) and a USER_DATABASES FULL step (24): the user role reads 24
rjob j1 'pgv two backups' true 1 1 "now() - interval '1 hour'" <<'JSON'
[{"step_id":1,"command":"EXECUTE [dbo].[DatabaseBackup] @Databases = 'SYSTEM_DATABASES', @BackupType = 'FULL', @CleanupTime = NULL"},{"step_id":2,"command":"EXECUTE [dbo].[DatabaseBackup] @Databases = 'USER_DATABASES', @BackupType = 'FULL', @CleanupTime = 24"}]
JSON
check "R S6 the age is read from the step the role matches: USER_DATABASES FULL at 24 hours is info" "SELECT status || ' ' || value FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance clean-up age' AND object = 'DatabaseBackup - USER_DATABASES - FULL: pgv two backups'" "info 24 hours"
# S7 / S12: an @CleanupTime the parser cannot read, a number too large: age not read, never met, never an error
check "R S7 @CleanupTime as text or a variable: not read (NULL), never 'never removed'" "SELECT coalesce(pgvigil.mssql_ola_age('EXECUTE dbo.DatabaseBackup @CleanupTime = ''24''', 'hours')::text, 'null') || ' ' || coalesce(pgvigil.mssql_ola_age('EXECUTE dbo.DatabaseBackup @CleanupTime = @h', 'hours')::text, 'null')" "null null"
check "R S12 a number past an int: not read (NULL), never an error" "SELECT coalesce(pgvigil.mssql_ola_age('EXECUTE dbo.DatabaseBackup @CleanupTime = 99999999999', 'hours')::text, 'null') || ' ' || coalesce(pgvigil.mssql_ola_age('DELETE FROM [dbo].[CommandLog] WHERE StartTime < DATEADD(dd,-10000000000,GETDATE())', 'days')::text, 'null')" "null null"
# S4: a role set 'not expected' while its job exists: every row of it off
rjob j2 'DatabaseBackup - USER_DATABASES - DIFF' false 0 1 'now()' <<'JSON'
[{"step_id":1,"command":"EXECUTE [dbo].[DatabaseBackup] @Databases = 'USER_DATABASES', @BackupType = 'DIFF'"}]
JSON
eqv "R S4 setup: DIFF not expected at the instance" "$(pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$RI,\"kind\":\"job\",\"key\":\"not_expected\",\"value\":[\"DatabaseBackup - USER_DATABASES - DIFF\"]}'::jsonb)->>'outcome'")" done
check "R S4 a job not expected: its enabled, scheduled and age rows all off (no finding)" "SELECT string_agg(DISTINCT status, ',') FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE object LIKE 'DatabaseBackup - USER_DATABASES - DIFF:%'" off
# S8: root says not expected, the instance says expected: the instance wins (a missing role is a warning)
pq "DELETE FROM pgvigil.mssql_jobs WHERE instance_id = $RI AND job_id = 'j2'" >/dev/null
eqv "R S8 setup: the instance's not expected ended, expected at the instance, not expected at the root" "$(pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"inherit\",\"level\":\"instance\",\"instance_id\":$RI,\"kind\":\"job\",\"key\":\"not_expected\"}'::jsonb)->>'outcome'") $(pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$RI,\"kind\":\"job\",\"key\":\"expected\",\"value\":[\"DatabaseBackup - USER_DATABASES - DIFF\"]}'::jsonb)->>'outcome'") $(pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"set\",\"level\":\"root\",\"kind\":\"job\",\"key\":\"not_expected\",\"value\":[\"DatabaseBackup - USER_DATABASES - DIFF\"]}'::jsonb)->>'outcome'")" "done done done"
check "R S8 the instance's 'expected' wins over the root's 'not expected': the missing DIFF is a warning" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance job' AND object = 'DatabaseBackup - USER_DATABASES - DIFF'" warning
eqv "R S8 setup: both taken away" "$(pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"inherit\",\"level\":\"root\",\"kind\":\"job\",\"key\":\"not_expected\"}'::jsonb)->>'outcome'") $(pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"inherit\",\"level\":\"instance\",\"instance_id\":$RI,\"kind\":\"job\",\"key\":\"expected\"}'::jsonb)->>'outcome'")" "done done"
# S9: a job name that is none of the solution's is refused (it would be stored and never judged)
eqv "R S9 an expected job name that is none of the solution's: refused" "$(pq "SELECT pgvigil.import_mssql_config_expect(now(), '{\"ui_user\":\"proof\",\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$RI,\"kind\":\"job\",\"key\":\"expected\",\"value\":[\"Nightly backup\"]}'::jsonb)->>'outcome'")" refused
# S3: a deadlock victim after the last successful run of the solution's jobs: a warning, not info
pq "INSERT INTO pgvigil.mssql_ola_commandlog (instance_id, database_name, epoch, id, db, command_type, start_at, end_at, error_number, status, snapshot_at) VALUES ($RI, 'dba', 0, 1, 'app', 'ALTER_INDEX', now() - interval '1 minute', now() - interval '1 minute', 1205, 'failed', now())" >/dev/null
check "R S3 a 1205 no job of the solution has run past since: a warning" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance command failed' AND value = '1205'" warning
# S2: a failure read four hours ago, the install part read now: still a finding within its 24 hours
pq "UPDATE pgvigil.mssql_ola_commandlog SET error_number = 3013, snapshot_at = now() - interval '4 hours' WHERE instance_id = $RI AND id = 1" >/dev/null
rimp "[{\"kind\":\"part\",\"part\":\"install\",\"read\":1},{\"kind\":\"database\",\"database_name\":\"dba\",\"install_read\":1,$ALLOBJ,\"purity_read\":1,\"create_version\":957,\"dbcc_flags\":2,\"purity_on\":1}]"
check "R S2 a failure read four hours ago is still a finding while the reads are fresh" "SELECT count(*) FROM pgvigil.mssql_maintenance_findings WHERE instance_id = $RI AND check_name = 'maintenance command failed'" 1
# S10: a CommandLog whose cursor the last read did not advance: the history not read
check "R S10 a CommandLog the last read did not reach (no cursor at that read): the history not read" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance history read' AND object = 'dba'" "not read"
# Q7 (P2-2): a CommandLog read that ended behind the table's end (the run's deadline or its cap): info, how far behind
rimp '[{"kind":"commandlog_read","database_name":"dba","behind":2500},{"kind":"cursor","source":"mssql_maintenance:dba","last_seq":10}]'
check "R Q7 a CommandLog read behind its end: info, saying how far" "SELECT status || ' ' || (detail LIKE '%2500 rows behind%') FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance history read' AND object = 'dba'" "info true"
# Q8 (P3-5): the integrity family (CHECKTABLE) and a product's backups (LiteSpeed's full, Red Gate's log): in the last
# part (read in W)
rimp '[{"kind":"commandlog","database_name":"dba","id":"5","db":"big","command_type":"DBCC_CHECKTABLE","start_utc":"2026-11-15T01:00:00Z","end_utc":"2026-11-15T01:10:00Z","error_number":0,"status":"ok"},{"kind":"commandlog","database_name":"dba","id":"6","db":"big","command_type":"xp_backup_database","backup_kind":"full","start_utc":"2026-11-15T02:00:00Z","end_utc":"2026-11-15T02:10:00Z","error_number":0,"status":"ok"},{"kind":"commandlog","database_name":"dba","id":"7","db":"big","command_type":"sqlbackup","backup_kind":"log","start_utc":"2026-11-15T03:00:00Z","end_utc":"2026-11-15T03:01:00Z","error_number":0,"status":"ok"}]'
# Q11 (P3-6): a deadlock victim of an index command while only a backup job succeeded since: a warning; info once a
# job of its own role (IndexOptimize) succeeded since
pq "INSERT INTO pgvigil.mssql_ola_commandlog (instance_id, database_name, epoch, id, db, command_type, start_at, end_at, error_number, status, snapshot_at) VALUES ($RI, 'dba', 0, 8, 'q11', 'ALTER_INDEX', now() - interval '2 hours', now() - interval '2 hours', 1205, 'failed', now())" >/dev/null
check "R Q11 a 1205 of an index command, only a backup job succeeded since: a warning" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance command failed' AND object LIKE '%q11%'" warning
rjob j3 'IndexOptimize - USER_DATABASES' true 1 1 'now()' <<'JSON'
[{"step_id":1,"command":"EXECUTE [dbo].[IndexOptimize] @Databases = 'USER_DATABASES', @LogToTable = 'Y'"}]
JSON
check "R Q11 ... once the IndexOptimize job succeeded since: info" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance command failed' AND object LIKE '%q11%'" info
# Q12 (P4-2): a site's job with @BackupType before @Databases and a database list with an exclusion: matched by its role
rjob j4 'site log backups' true 1 1 'now()' <<'JSON'
[{"step_id":1,"command":"EXECUTE dbo.DatabaseBackup @BackupType = 'LOG', @Directory = N'/b', @Databases = 'USER_DATABASES, -BigDb'"}]
JSON
check "R Q12 @BackupType before @Databases, 'USER_DATABASES, -BigDb': the LOG role's job" "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($RI) WHERE check_name = 'maintenance job enabled' AND object = 'DatabaseBackup - USER_DATABASES - LOG: site log backups'" 1
# S14: a restored CommandLog (its IDs under the cursor) read again as a new epoch: the rows already stored are not doubled
rimp '[{"kind":"reset","database_name":"dba"},{"kind":"commandlog","database_name":"dba","id":"1","db":"app","command_type":"ALTER_INDEX","start_utc":"'"$(pq "SELECT to_char((start_at AT TIME ZONE 'UTC'), 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $RI AND id = 1")"'","end_utc":"2026-01-01T00:00:00Z","error_number":1205,"status":"failed"}]'
check "R S14 a row read again after a restore (same ID and start): not doubled" "SELECT count(*) FROM pgvigil.mssql_ola_commandlog WHERE instance_id = $RI AND id = 1" 1
# S5: on an instance without the solution a site's own job calling sp_purge_jobhistory is not judged as the solution's
RN=$(pq "SELECT pgvigil.ensure_instance('rn$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "SELECT pgvigil.import_mssql_maintenance($RN, now(), '[{\"kind\":\"part\",\"part\":\"install\",\"read\":1},{\"kind\":\"database\",\"database_name\":\"master\",\"install_read\":1,\"objects\":[]}]'::jsonb)" >/dev/null
pq "INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, enabled_schedules, steps) VALUES ($RN, 'p1', now(), 'Purge history', false, 0, '[{\"step_id\":1,\"command\":\"EXEC msdb.dbo.sp_purge_jobhistory @oldest_date = ''2026-01-01''\"}]'::jsonb)" >/dev/null
check "R S5 no solution: a site's own job calling sp_purge_jobhistory is not judged (no warning)" "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($RN) WHERE status = 'warning'" 0
# Q10 (P4-9): a collector whose clock runs ahead of the repository's (a run's snapshot five minutes ahead): a good read
# of the CommandLog leaves no 'not read' (the cursor carries the run's own time)
RC=$(pq "SELECT pgvigil.ensure_instance('rc$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
QT=$(pq "SELECT (now() + interval '5 minutes')::text")
pq "SELECT pgvigil.import_mssql_maintenance($RC, '$QT'::timestamptz, '[{\"kind\":\"part\",\"part\":\"install\",\"read\":1},{\"kind\":\"database\",\"database_name\":\"dba\",\"install_read\":1,$ALLOBJ}]'::jsonb)" >/dev/null || bad "R Q10 the written part"
pq "SELECT pgvigil.import_mssql_maintenance($RC, '$QT'::timestamptz, '[{\"kind\":\"cursor\",\"source\":\"mssql_maintenance:dba\",\"last_seq\":1}]'::jsonb)" >/dev/null || bad "R Q10 the written cursor"
check "R Q10 a collector's clock ahead of the repository's: no 'not read' after a good read" "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($RC) WHERE check_name = 'maintenance history read' AND status = 'not read'" 0

echo "== W: the API"
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.out" 2>&1 & SRV_PID=$!
for _ in $(seq 1 30); do curl -fs "$U/api/instances" >/dev/null 2>&1 && break; sleep 1; done
parts() { curl -s "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(sorted(d.keys())) if isinstance(d, dict) else "not an object")' 2>&1 | head -c 200; }
eqv "W GET /api/mssql/maintenance: its parts" "$(parts "$U/api/mssql/maintenance?instance=$IID")" "checks,commandlog,databases,jobs,last,parts,runs"
eqv "W ... the checks = the function's rows" "$(curl -s "$U/api/mssql/maintenance?instance=$IID&part=checks" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["checks"]["rows"]))' 2>&1 | head -c 80)" "$(pq "SELECT count(*) FROM pgvigil.mssql_maintenance_checks_of($IID)")"
eqv "W ... a bad from: 400" "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/mssql/maintenance?instance=$IID&from=yesterday")" 400
# the last part's row of one database: each kind set or null, and whether the full is older than the differential
apil() {  # $1 instance $2 database
  curl -s "$U/api/mssql/maintenance?instance=$1&part=last" | python3 -c '
import json, sys
t = json.load(sys.stdin)["last"]; c = t["columns"]
r = next((x for x in (dict(zip(c, v)) for v in t["rows"]) if x.get("database_name") == sys.argv[1]), None)
if r is None:
    print("no row"); sys.exit()
out = " ".join(k + ":" + ("null" if r.get("last_" + k) is None else "set") for k in ("full", "diff", "log", "integrity"))
if r.get("last_full") and r.get("last_diff"):
    out += " full-before-diff:" + str(r["last_full"] < r["last_diff"]).lower()
print(out)' "$2" 2>&1 | head -c 200; }
eqv "W Q6 a full backup of a database whose name holds 'Differential': a full, not a differential" "$(apil "$IID" pgvDifferentialPricing)" "full:set diff:null log:null integrity:null"
eqv "W Q6 a 40-file differential (its command past 4,000 characters): a differential, after the full; the integrity check counted" "$(apil "$IID" pgvp1)" "full:set diff:set log:set integrity:set full-before-diff:true"
eqv "W Q8 the CHECKTABLE family and the products' backups (LiteSpeed's full, Red Gate's log)" "$(apil "$RI" big)" "full:set diff:null log:set integrity:set"
eqv "W Q9 an instance without the solution: its own sp_purge_jobhistory job not in the Jobs grid" "$(curl -s "$U/api/mssql/maintenance?instance=$RN&part=jobs" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["jobs"]["rows"]))' 2>&1 | head -c 80)" 0
eqv "W Q9 ... the grid's jobs are 0161's matcher's: each row carries its role" "$(curl -s "$U/api/mssql/maintenance?instance=$IID&part=jobs" | python3 -c 'import json,sys; t=json.load(sys.stdin)["jobs"]; print("role" in t["columns"] and len(t["rows"]) > 0)' 2>&1 | head -c 80)" True
kill "$SRV_PID" 2>/dev/null; SRV_PID=
pq "DELETE FROM pgvigil.instances WHERE instance_id IN ($RI, $RN, $RC)" >/dev/null

# ---- V: the version run --------------------------------------------------------------------------------------------
for img in "${IMAGES[@]:1}"; do
  echo "== V: $img"
  docker rm -f -v "$SQL" >/dev/null 2>&1
  pq "DELETE FROM pgvigil.instances WHERE name IN ('sqlbox', 'sqlbox_low')" >/dev/null
  start_server "$img"
  ok "SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")"
  for c in $BASE mssql_confcheck; do
    collect "$c" || true
    eqv "$img A: $c runs as the monitor login" "$(lastrun "$c")" "ok"
  done
  IID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
  sq "GRANT VIEW ANY DEFINITION TO [$MON];" >/dev/null; col mssql_maintenance
  rule "$img O0 no solution: info, not installed" "maintenance solution installed" info
  mkdb pgvp1; sq "CREATE DATABASE pgvnouser;" >/dev/null
  col mssql_maintenance
  # the version's outcome for the docs (works, or refused with its error): a verdict, or 'not read' with the error - never silent
  check "$img P DBCC DBINFO as the monitor login (no sysadmin): a verdict, or 'not read' with the error" "SELECT coalesce((SELECT (purity_read AND purity_on IS NOT NULL) OR (NOT purity_read AND purity_note LIKE 'not read: %') FROM pgvigil.mssql_maint_database WHERE instance_id = $IID AND database_name = 'pgvp1'), false)" t
  echo "     $img DBCC DBINFO as the monitor login: $(pq "SELECT CASE WHEN purity_read THEN 'works (purity ' || CASE WHEN purity_on THEN 'on' ELSE 'off' END || ', create version ' || create_version || ')' ELSE coalesce(purity_note, 'no note') END FROM pgvigil.mssql_maint_database WHERE instance_id = $IID AND database_name = 'pgvp1'" | cut -c1-300)"
  rule "$img P a database without the monitor login's user: not read" "data purity checks" "pgvnouser not read" pgvnouser
  # (the rule helper drops its object filter for an empty object: the own row is read by its object '' here)
  [[ $img == 2022* ]] || check "$img P every database refuses DBCC DBINFO (2571): the rule's own row not read, never ok" "SELECT status FROM pgvigil.mssql_maintenance_checks_of($IID) WHERE check_name = 'data purity checks' AND object = ''" "not read"
  mkdb pgvdba
  install; eqv "$img O1 installed" "$?" 0
  col mssql_jobs mssql_maintenance
  rule "$img O1 found in pgvdba" "maintenance solution installed" "pgvdba ok"
  eqv "$img O2 ten jobs, ten 'no enabled schedule' warnings" "$(cnt 'maintenance job enabled' ok) $(cnt 'maintenance job scheduled' warning)" "$LINUX_JOBS $LINUX_JOBS"
done
np "SQL Server 2016: Windows-only (no Linux image), rides task 164's Windows host"
np "Windows (eleven jobs, 'Output File Cleanup' and its age), Managed Instance (six) and RDS (three): the expected lists on written rows"
np "a server across a daylight saving step (the stored time moves by the offset in force at the read)"
np "an availability group's secondary replica ('not read: a secondary replica'): no availability group on the box"
np "a CommandLog read cut by the run's deadline (its 'behind' row is proven on written rows, Q7)"
np "a CommandLog truncated and refilled past the old cursor between two reads (a known limit, in the docs)"

echo "PROOF $( [[ $FAILS == 0 ]] && echo OK || echo FAILED ): mssql maintenance ($FAILS failed, $NP not proven)"
exit $FAILS
