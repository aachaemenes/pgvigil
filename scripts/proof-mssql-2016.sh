#!/usr/bin/env bash
# Proof that the SQL Server proofs hold on SQL Server 2016 (major 13). SQL Server 2016 has no Linux image, so the
# server is ONE Windows server reached over the network (scripts/lab/azure-mssql2016-vm.sh makes one in an Azure
# lab), not a pair of containers as in scripts/proof-mssql-versions.sh. The ten proofs of that script and the
# summary proof run against it unchanged: they reach their server's sa side through `docker exec <container>
# /opt/mssql-tools18/bin/sqlcmd -S localhost ...`, and this script puts a `docker` of its own first on their PATH
# that sends exactly those calls, for one pseudo container name, to a sqlcmd in a tools container on this machine
# with -S pointed at the server over the network (TLS, the server's certificate trusted as the proofs' own -C
# says). Every other docker call (a postgres:13 container of a proof, an inspect, a removal) is the real docker's.
# The statements are the proofs' own, byte for byte; only the transport changes. Two calls have no network form and
# are translated: a file a proof copies into the container (`docker cp`, then sqlcmd -i) goes into the tools
# container; the deletion of a proof's own event files under the Linux log folder (`rm -f
# /var/opt/mssql/log/<name>`) deletes <name> in the server's own log folder through xp_cmdshell, switched on for
# that one call where it is off and put back in the same batch. Any other call into the pseudo container that has
# no network form fails the proof that made it, naming the call.
#
# Needs: docker (the tools image is pulled when missing), psql, curl, jq, python3, ss, timeout, od, flock, a go
# toolchain at the repository root (ONE binary is built and handed to every proof as PGVIGIL_BIN; PGVIGIL_BIN names
# a built one instead; go is needed all the same: three proofs build or test with it), and
#   PGVIGIL_ADMIN_DSN          a superuser connection to a PostgreSQL in KEYWORD form, no dbname and no password in it
#   the server: PGVIGIL_MSSQL2016_ADDR (host:port; default the line in .lab/pgv16.addr) and the file holding its sa
#   password, PGVIGIL_MSSQL2016_SA_FILE (default .lab/pgv16-sa.pw, mode 600; the password is read from it, never
#   printed, and reaches sqlcmd and the collector through the environment by name)
# Settings (a relative path is taken from the repository root):
#   PGVIGIL_2016_PROOFS        default "base services running xe hadr storage perf reads querystore actions"
#   PGVIGIL_2016_GROUP_PROOFS  the proofs that need an availability group of two replicas: "hadr" (the default) or
#                              empty; no other name is accepted. On a server where Always On is not enabled (SQL
#                              Server 2016 can enable it only on a Windows cluster's node; this server is one node
#                              and no cluster) such a proof is NOT RUN and recorded 'NOT PROVEN: one node' with that
#                              reason; where Always On is enabled it runs, and its failure is a FAIL like any other.
#                              Its statements are still compiled by the server in part T.
#   PGVIGIL_2016_TIMEOUT       seconds one proof may take, default 2400; a proof over it is ended and FAILS
#   PGVIGIL_2016_WHOISACTIVE   a local copy of sp_WhoIsActive.sql: installed in master (dropped at the end when this
#                              run installed it), and the running-queries proof then runs its part B
#   PGVIGIL_2016_TOOLS_IMAGE   the image whose sqlcmd talks to the server, default
#                              mcr.microsoft.com/mssql/server:2022-latest (only its /opt/mssql-tools18/bin/sqlcmd runs:
#                              the container is started with `sleep`, no SQL Server in it)
#   PGVIGIL_2016_OUT           the folder of the logs and of summary.md; default a temp folder, kept and named
# Refused, as in proof-mssql-versions.sh: PGVIGIL_NO_MSSQL and a GODEBUG that names x509negativeserial.
#
# What it makes, and removes at the end (on every exit path the shell can catch): the tools container (label of this
# run) and the docker shim under a temp folder; on PGVIGIL_ADMIN_DSN the repository database pgvigil_v16proof_<n>;
# on the server, as a server in use has them: the Agent job 'pgvv seed' with sixty history rows dated yesterday
# (deleted at the end with its history) and 'Database Mail XPs' switched on and Database Mail started (put back to
# the value read before the run). What the proofs make is theirs to remove (each header says what).
#
# Expected (written before the first run):
#  P. the server answers sa within 4 minutes; ProductVersion's major is 13; Edition names Developer; SQL Server Agent
#     has its sessions open; IsHadrEnabled is 0 (one node, no Windows cluster: recorded, it decides the group proofs).
#  C. `collect -once mssql_instance` as sa over an encrypted connection (encrypt=true, TrustServerCertificate=true)
#     exits 0 and the repository holds the server as engine sqlserver, platform sqlserver, server_version_num =
#     major * 10000 + minor of sa's ProductVersion (130000). The control, as in proof-mssql-versions.sh check C: the
#     same read with GODEBUG=x509negativeserial=0 for that one call either passes or fails with exactly 'x509:
#     negative serial number'; which, is recorded in the summary's row "certificate serial negative" (a record,
#     never a verdict: the server draws the number). Any other failure of the control fails C.
#  H. after the seed, msdb.dbo.sysjobhistory holds 60 rows or more and 'Database Mail XPs' is 1 in use.
#  K. every SQL Server collection of the collector (21: ag backups cpu fileio indexlocks instance jobs logshipping
#     memory mirroring procstats properties querystore replication requests services storage tempdb versionstore
#     waits xe), `collect -once <it>` as sa: exits 0, and no line it prints is an ERROR, carries the server's words
#     for a statement 2016 does not have ('Invalid column name', 'Invalid object name', 'is not a recognized built-in
#     function name', 'Incorrect syntax') or any server error ('mssql: <message> (<number>)': as sa, every server
#     error is a finding); its row in collection_dates is ok, or skipped / partial with a note that is none of those
#     (never error, never missing). Only the first collector error of a run reaches its note: the output is read too. A collection that fails K is the finding: its output names the statement.
#  T. the live tests of internal/mssql against the server as sa (`go test ./internal/mssql -run 'Live$'` with
#     PGVIGIL_MSSQL_TEST_DSN): TestQueryRowsLive, TestRunningLive, TestHADRStatementsLive (every availability group,
#     mirroring, log shipping, replication, job and backup statement compiled by the server under SET NOEXEC ON, and
#     run where the server has the feature: the group statements are compiled, not run, without Always On),
#     TestAgentDateTimeLive, TestBackupSinkLive and TestBackupUTCLive pass; TestRequestsManySessionsLive skips (no
#     session count asked). The go test exit code is the verdict.
#  R. every proof of the list exits 0 (PASS), except a group proof on a server without Always On: not run, 'NOT
#     PROVEN: one node'. A proof that fails is the finding (its log names the statement and the column); never rerun
#     into green here. Expected FAIL on the tree of the first run (rel-145 at 0ce7ca8), each a proof's OWN statement,
#     not the collector's: actions (spids() reads STRING_AGG, 2017+), perf (part A reads sys.dm_os_host_info, 2017+),
#     reads (part A's hand reads of sys.dm_os_host_info), xe (parts I and K read the slow session's event files by the
#     Linux path /var/opt/mssql/log/ in their own T-SQL). Each stays FAIL until the proof is changed; the changes are
#     proposed apart, never made by this script.
#     [The first run, graded: those four failed as written, and querystore failed too, which the list above did not
#      name: its setup turns on WAIT_STATS_CAPTURE_MODE, a Query Store option of SQL Server 2017 ("Incorrect syntax
#      near 'WAIT_STATS_CAPTURE_MODE'"), and it reads the 2017 wait statistics in its own comparisons.]
#  S. proof-mssql-summary.sh (no SQL Server) exits 0, once.
#  The last line is "proof-mssql-2016: PASS (<build>; <n> proofs, <m> not proven on one node, 21 collections,
#  summary once; logs in <folder>)" and the exit code 0 only when P, C, H, K, T, R and S hold; else the failed cells
#  are listed, the last line says FAIL with their count and the exit code is 1. What a passed proof itself prints
#  as SKIPPED, NOT RUN or NOT PROVEN stays so: those lines are listed under the matrix and kept in left-out.txt.
#  NOT PROVEN HERE: an availability group on SQL Server 2016 (a Windows cluster's group), a second server for the
#  proofs that compare two (they run against one), an edition other than Developer, SQL Server 2016 before SP3.
set -euo pipefail
set +x   # a trace would print the passwords
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
for t in docker psql curl jq python3 ss timeout od flock; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
command -v go >/dev/null || { echo "FAIL: go is not on this machine (the proofs build and test with it, whatever PGVIGIL_BIN names)" >&2; exit 1; }
[ -z "${PGVIGIL_NO_MSSQL:-}" ] || { echo "FAIL: PGVIGIL_NO_MSSQL is set: proof-mssql-reads.sh would leave out every SQL Server part and still exit 0; unset it" >&2; exit 1; }
case ${GODEBUG:-} in *x509negativeserial*) echo "FAIL: GODEBUG carries x509negativeserial: check C must read the build's own setting; unset it" >&2; exit 1 ;; esac
read -r -a PROOFS <<<"${PGVIGIL_2016_PROOFS:-base services running xe hadr storage perf reads querystore actions}"
read -r -a GROUP_PROOFS <<<"${PGVIGIL_2016_GROUP_PROOFS-hadr}"
for g in "${GROUP_PROOFS[@]}"; do [ "$g" = hadr ] || { echo "FAIL: PGVIGIL_2016_GROUP_PROOFS may name only hadr: $g" >&2; exit 1; }; done
PTIMEOUT=${PGVIGIL_2016_TIMEOUT:-2400}
[[ $PTIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: PGVIGIL_2016_TIMEOUT is a whole number above 0" >&2; exit 1; }
for name in "${PROOFS[@]}"; do [ -f "scripts/proof-mssql-$name.sh" ] || { echo "FAIL: no scripts/proof-mssql-$name.sh" >&2; exit 1; }; done
TOOLS_IMAGE=${PGVIGIL_2016_TOOLS_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
ADDR=${PGVIGIL_MSSQL2016_ADDR:-}
if [ -z "$ADDR" ] && [ -r .lab/pgv16.addr ]; then ADDR=$(head -1 .lab/pgv16.addr); fi
[[ $ADDR =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || { echo "FAIL: PGVIGIL_MSSQL2016_ADDR is host:port (or .lab/pgv16.addr holds it): '$ADDR'" >&2; exit 1; }
SAFILE=${PGVIGIL_MSSQL2016_SA_FILE:-.lab/pgv16-sa.pw}
[ -r "$SAFILE" ] && [ -s "$SAFILE" ] || { echo "FAIL: no readable sa password file at $SAFILE" >&2; exit 1; }
[ "$(stat -c %a "$SAFILE")" = 600 ] || { echo "FAIL: $SAFILE is mode $(stat -c %a "$SAFILE"), want 600" >&2; exit 1; }
# one run at a time against one server (the seed job and the settings it puts back are the server's, not the run's)
exec 7>"${TMPDIR:-/tmp}/pgvigil-v16-${ADDR//[:.]/_}.lock"
flock -n 7 || { echo "FAIL: another proof-mssql-2016 run holds the server at $ADDR" >&2; exit 1; }
MSSQL_SA_PASSWORD=$(head -1 "$SAFILE"); export MSSQL_SA_PASSWORD
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
WHOISACTIVE=${PGVIGIL_2016_WHOISACTIVE:-}
if [ -n "$WHOISACTIVE" ]; then
  [ -r "$WHOISACTIVE" ] && grep -qi 'sp_WhoIsActive' "$WHOISACTIVE" || { echo "FAIL: PGVIGIL_2016_WHOISACTIVE names no readable sp_WhoIsActive script: $WHOISACTIVE" >&2; exit 1; }
fi

SUF=$RANDOM; RUN_LABEL="pgvigil.v16.run=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CT=pgv16sql-$SUF; TOOLS=pgv16tools-$SUF; INST=pgv16-$SUF
REPO_DB=pgvigil_v16proof_$SUF; MADE_REPO=; MADE_TOOLS=; MADE_SEED=; MADE_WIA=; DBMAIL_OLD=; ADV_OLD=; MAILSTATE_OLD=
OUT=${PGVIGIL_2016_OUT:-$(mktemp -d)}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
rm -f "$OUT/stop" "$OUT/summary.md" "$OUT/results.txt" "$OUT"/*.left-out.txt "$OUT/proof.pid"; : > "$OUT/results.txt"; mkdir -p "$OUT/sweep"
REAL_DOCKER=$(command -v docker)
SQLHOST="tcp:${ADDR%:*},${ADDR##*:}"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# sqa <sql>: one statement as sa over the network; sqin: a batch on stdin. Five minutes at most per call.
sqa() { timeout 300 "$REAL_DOCKER" exec -e SQLCMDPASSWORD "$TOOLS" "$SQLCMD" -S "$SQLHOST" -U sa -C -b -I -W -h -1 -s '|' -d master -Q "SET NOCOUNT ON; $1"; }
sqin() { timeout 300 "$REAL_DOCKER" exec -i -e SQLCMDPASSWORD "$TOOLS" "$SQLCMD" -S "$SQLHOST" -U sa -C -b -I -W -h -1 -d master -i /dev/stdin; }
mask() { local text; text=$(cat); text=${text//"$MSSQL_SA_PASSWORD"/<hidden>}; [ -z "$text" ] || printf '%s\n' "$text"; }

cleanup() {
  rc=$?
  trap - EXIT INT TERM
  set +e
  : > "$OUT/stop"
  if [ -f "$OUT/proof.pid" ]; then kill -TERM "$(cat "$OUT/proof.pid")" 2>/dev/null; for _ in $(seq 1 150); do [ -z "$(jobs -rp)" ] && break; sleep 1; done; fi
  if [ -n "$MADE_TOOLS" ]; then
    if [ -n "$MADE_SEED" ]; then
      sqa "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'pgvv seed') EXEC msdb.dbo.sp_delete_job @job_name = N'pgvv seed', @delete_history = 1;" >/dev/null 2>&1 \
        || echo "CLEANUP: the job 'pgvv seed' was not deleted on the server" >&2
    fi
    if [ "$DBMAIL_OLD" = 0 ]; then
      sqa "EXEC msdb.dbo.sysmail_stop_sp; EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'Database Mail XPs', 0; RECONFIGURE; IF $ADV_OLD = 0 BEGIN EXEC sp_configure 'show advanced options', 0; RECONFIGURE; END;" >/dev/null 2>&1 \
        || echo "CLEANUP: 'Database Mail XPs' was not put back to 0 on the server" >&2
    elif [ "$DBMAIL_OLD" = 1 ] && [ "$MAILSTATE_OLD" = STOPPED ]; then
      sqa "EXEC msdb.dbo.sysmail_stop_sp;" >/dev/null 2>&1 || echo "CLEANUP: Database Mail was not stopped again on the server" >&2
    fi
    if [ -n "$MADE_WIA" ]; then sqa "IF OBJECT_ID('master.dbo.sp_WhoIsActive', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_WhoIsActive;" >/dev/null 2>&1 || echo "CLEANUP: sp_WhoIsActive was not dropped" >&2; fi
  fi
  ids=$("$REAL_DOCKER" ps -aq --filter "label=$RUN_LABEL")
  if [ -n "$ids" ]; then "$REAL_DOCKER" rm -f $ids >/dev/null 2>&1 || echo "CLEANUP: a container of this run was not removed (label $RUN_LABEL)" >&2; fi
  if [ -n "$MADE_REPO" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  BIN=$WORK/pgvigil
  CGO_ENABLED=0 go build -trimpath -o "$BIN" ./cmd/pgvigil || { echo "FAIL: the build" >&2; exit 1; }
fi
[ -x "$BIN" ] || { echo "FAIL: no binary at $BIN" >&2; exit 1; }
case $BIN in /*) ;; *) BIN=$PWD/$BIN ;; esac

# the tools container: sqlcmd only, as root (a proof copies a file in that only its owner reads, then sqlcmd opens it)
"$REAL_DOCKER" image inspect "$TOOLS_IMAGE" >/dev/null 2>&1 || "$REAL_DOCKER" pull -q "$TOOLS_IMAGE" >/dev/null || { echo "FAIL: the image $TOOLS_IMAGE could not be pulled" >&2; exit 1; }
"$REAL_DOCKER" run -d --name "$TOOLS" --label "$RUN_LABEL" --user root --entrypoint sleep "$TOOLS_IMAGE" infinity >/dev/null || { echo "FAIL: the tools container" >&2; exit 1; }
MADE_TOOLS=1

result() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '|\n' '/ ' | cut -c1-400)" >> "$OUT/results.txt"
  echo "  SQL Server 2016 $1: $2 ($3 s)"
}
echo "proof-mssql-2016: the server at $ADDR x ${PROOFS[*]}; logs in $OUT; this run's label $RUN_LABEL"

# P
t0=$SECONDS; WHY=
# 48 tries, each with a 5 s login timeout and a 0 to 2 s pause: about four minutes at most
for _ in $(seq 1 48); do timeout 30 "$REAL_DOCKER" exec -e SQLCMDPASSWORD "$TOOLS" "$SQLCMD" -S "$SQLHOST" -U sa -C -b -l 5 -Q "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
if ! sqa "SELECT 1" > "$OUT/p-first.txt" 2>&1; then
  WHY="P: the server never answered sa at $ADDR: $(mask < "$OUT/p-first.txt" | head -3 | tr '\n' ' ')"
else
  for _ in $(seq 1 30); do [ "$(sqa "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%'" 2>/dev/null)" -gt 0 ] 2>/dev/null && break; sleep 2; done
  P=$(sqa "SELECT CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), 4) AS varchar(4)) + '|' + CAST(SERVERPROPERTY('Edition') AS varchar(80)) + '|' + CASE WHEN EXISTS (SELECT 1 FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%') THEN '1' ELSE '0' END + '|' + CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS varchar(4)) + '|' + @@SERVERNAME") || WHY="P: sa's read of the server"
  if [ -z "$WHY" ]; then
    IFS='|' read -r P_MAJOR P_EDITION P_AGENT P_HADR P_NAME <<<"$P"
    [ "$P_MAJOR" = 13 ] || WHY="P: the major is $P_MAJOR (want 13)"
    case $P_EDITION in *Developer*) ;; *) WHY="${WHY:+$WHY; }P: the edition is $P_EDITION (want Developer)" ;; esac
    [ "$P_AGENT" = 1 ] || WHY="${WHY:+$WHY; }P: SQL Server Agent has no session open"
  fi
fi
if [ -n "$WHY" ]; then result setup FAIL $((SECONDS - t0)) "$WHY"; echo "FAIL: $WHY" >&2; exit 1; fi
sqa "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + '|' + CAST(SERVERPROPERTY('ProductLevel') AS varchar(40)) + '|' + ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS varchar(40)), '') + '|' + CAST(SERVERPROPERTY('Edition') AS varchar(80))" > "$OUT/build.txt"
sqa "SELECT REPLACE(REPLACE(@@VERSION, CHAR(13), ' '), CHAR(10), ' ')" > "$OUT/os.txt" 2>/dev/null || true
LOGDIR=$(sqa "SELECT LEFT(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(400)), LEN(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(400))) - CHARINDEX(N'\\', REVERSE(CAST(SERVERPROPERTY('ErrorLogFileName') AS nvarchar(400)))) + 1)")
[[ $LOGDIR =~ ^[A-Za-z]:\\ ]] || { result setup FAIL $((SECONDS - t0)) "P: the server's log folder reads '$LOGDIR' (want a Windows path)"; exit 1; }
echo "  the server: $(cat "$OUT/build.txt"); @@SERVERNAME $P_NAME; Always On enabled: $P_HADR; log folder $LOGDIR"

# C
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" >/dev/null || { echo "FAIL: the repository database $REPO_DB" >&2; exit 1; }
MADE_REPO=1
export PGV16_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
export PGV16_DSN="sqlserver://sa:$MSSQL_SA_PASSWORD@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
CFG=$WORK/v16.yaml
printf 'repository:\n  dsn: env:PGV16_REPO_DSN\ninstances:\n  - name: %s\n    engine: sqlserver\n    dsn: env:PGV16_DSN\n' "$INST" > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || { echo "FAIL: migrate of the repository database $REPO_DB" >&2; exit 1; }
rq() { psql "$PGV16_REPO_DSN" -XAtq -c "$1"; }
num=$(sqa "SELECT CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), 4) AS int) * 10000 + CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), 3) AS int)")
if ! out=$("$BIN" collect -config "$CFG" -once mssql_instance -instance "$INST" 2>&1); then
  printf '%s\n' "$out" | mask > "$OUT/c.log"
  WHY="C: the collector could not read the server: $( { printf '%s\n' "$out" | grep -m1 -o 'err=.*' || printf '%s\n' "$out" | tail -1; } | mask)"
else
  got=$(rq "select engine || '|' || platform || '|' || server_version_num from pgvigil.instances where name = '$INST'")
  [ "$got" = "sqlserver|sqlserver|$num" ] || WHY="C: the repository holds the server as $got (want sqlserver|sqlserver|$num)"
fi
if [ -z "$WHY" ]; then
  if out=$(GODEBUG=x509negativeserial=0 "$BIN" collect -config "$CFG" -once mssql_instance -instance "$INST" 2>&1); then echo no > "$OUT/negative-serial.txt"
  elif printf '%s\n' "$out" | grep -q 'x509: negative serial number'; then echo yes > "$OUT/negative-serial.txt"
  else WHY="C: the control read failed for another reason: $( { printf '%s\n' "$out" | grep -m1 -o 'err=.*' || printf '%s\n' "$out" | tail -1; } | mask)"; fi
fi
if [ -n "$WHY" ]; then result setup FAIL $((SECONDS - t0)) "$WHY"; echo "FAIL: $WHY" >&2; exit 1; fi
echo "  C: the collector reads the server over TLS as $num; certificate serial negative: $(cat "$OUT/negative-serial.txt")"

# H: a server in use (Database Mail on and started, sixty rows of job history from yesterday)
ADV_OLD=$(sqa "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'show advanced options'") || { result setup FAIL $((SECONDS - t0)) "H: sa's read of 'show advanced options'"; exit 1; }
DBMAIL_OLD=$(sqa "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Database Mail XPs'") || { result setup FAIL $((SECONDS - t0)) "H: sa's read of 'Database Mail XPs'"; exit 1; }
if [ "$DBMAIL_OLD" = 1 ]; then MAILSTATE_OLD=$(sqa "EXEC msdb.dbo.sysmail_help_status_sp;" 2>/dev/null | tr -d ' \r' | tail -1 || true); fi
MADE_SEED=1
{ printf 'DECLARE @adv_old int = %s;\n' "$ADV_OLD"; cat <<'SQL'
SET NOCOUNT ON;
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;
IF @adv_old = 0 BEGIN EXEC sp_configure 'show advanced options', 0; RECONFIGURE; END;
EXEC msdb.dbo.sysmail_start_sp;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'pgvv seed') EXEC msdb.dbo.sp_delete_job @job_name = N'pgvv seed', @delete_history = 1;
EXEC msdb.dbo.sp_add_job @job_name = N'pgvv seed', @enabled = 1, @owner_login_name = N'sa';
EXEC msdb.dbo.sp_add_jobstep @job_name = N'pgvv seed', @step_id = 1, @step_name = N'one', @subsystem = N'TSQL', @command = N'SELECT 1;';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'pgvv seed';
DECLARE @job uniqueidentifier = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'pgvv seed'),
        @day int = CAST(CONVERT(char(8), DATEADD(day, -1, GETDATE()), 112) AS int), @run int = 0;
WHILE @run < 30
BEGIN
  INSERT msdb.dbo.sysjobhistory (job_id, step_id, step_name, sql_message_id, sql_severity, message, run_status, run_date, run_time, run_duration,
                                 operator_id_emailed, operator_id_netsent, operator_id_paged, retries_attempted, server)
  VALUES (@job, 1, N'one', 0, 0, N'Executed as user: sa. The step succeeded.', 1, @day, 10000 + @run * 100, 0, 0, 0, 0, 0, @@SERVERNAME),
         (@job, 0, N'(Job outcome)', 0, 0, N'The job succeeded.  The Job was invoked by User sa.  The last step to run was step 1 (one).', 1, @day, 10000 + @run * 100, 0, 0, 0, 0, 0, @@SERVERNAME);
  SET @run += 1;
END
SQL
} | sqin 2>&1 | mask > "$OUT/h.log" || { result setup FAIL $((SECONDS - t0)) "H: Database Mail or the seeded job history (h.log)"; exit 1; }
got=$(sqa "SELECT CAST((SELECT COUNT(*) FROM msdb.dbo.sysjobhistory) AS varchar(12)) + '|' + CAST((SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Database Mail XPs') AS varchar(4))")
[ "${got%%|*}" -ge 60 ] 2>/dev/null && [ "${got##*|}" = 1 ] || { result setup FAIL $((SECONDS - t0)) "H: job history rows|Database Mail XPs = $got (want 60 or more|1)"; exit 1; }
if [ -n "$WHOISACTIVE" ]; then
  if [ "$(sqa "SELECT CASE WHEN OBJECT_ID('master.dbo.sp_WhoIsActive', 'P') IS NULL THEN 0 ELSE 1 END")" = 0 ]; then
    MADE_WIA=1
    sqin < "$WHOISACTIVE" 2>&1 | mask >> "$OUT/h.log" || { result setup FAIL $((SECONDS - t0)) "H: sp_WhoIsActive did not install"; exit 1; }
  fi
  [ "$(sqa "SELECT CASE WHEN OBJECT_ID('master.dbo.sp_WhoIsActive', 'P') IS NULL THEN 0 ELSE 1 END")" = 1 ] || { result setup FAIL $((SECONDS - t0)) "H: sp_WhoIsActive is not in master"; exit 1; }
fi
result setup PASS $((SECONDS - t0)) "$(cat "$OUT/build.txt")"

# K: every collection once, as sa
COLLECTIONS="ag backups cpu fileio indexlocks instance jobs logshipping memory mirroring procstats properties querystore replication requests services storage tempdb versionstore waits xe"
echo "--- K. every SQL Server collection once, as sa"
for c in $COLLECTIONS; do
  t1=$SECONDS; crc=0
  "$BIN" collect -config "$CFG" -once "mssql_$c" -instance "$INST" > "$OUT/sweep/$c.raw" 2>&1 || crc=$?
  mask < "$OUT/sweep/$c.raw" > "$OUT/sweep/$c.log"; rm -f "$OUT/sweep/$c.raw"
  state=$(rq "select cd.status || ': ' || coalesce(left(cd.note, 300), '') from pgvigil.collection_dates cd join pgvigil.instances i using (instance_id) where i.name = '$INST' and cd.collection = 'mssql_$c'" 2>/dev/null || true)
  bad=$(grep -m1 -iE 'level=ERROR|Invalid column name|Invalid object name|is not a recognized built-in function name|Incorrect syntax|mssql: .*\([0-9]+\)' "$OUT/sweep/$c.log" || true)
  if [ $crc = 0 ] && [ -z "$bad" ] && [[ $state =~ ^(ok|skipped|partial): ]] && ! printf '%s' "$state" | grep -qiE 'Invalid column name|Invalid object name|is not a recognized built-in function name|Incorrect syntax|mssql: .*\([0-9]+\)'; then
    result "collect mssql_$c" PASS $((SECONDS - t1)) "${state:-no state row}"
  else
    result "collect mssql_$c" FAIL $((SECONDS - t1)) "exit $crc: ${bad:-$state}"
  fi
done

# T: the live tests of the package, as sa
echo "--- T. the live tests of internal/mssql, as sa"
t1=$SECONDS; trc=0
PGVIGIL_MSSQL_TEST_DSN="$PGV16_DSN" go test ./internal/mssql -run 'Live$' -count=1 -v > "$OUT/live.raw" 2>&1 || trc=$?
mask < "$OUT/live.raw" > "$OUT/live.log"; rm -f "$OUT/live.raw"
missing=
for tn in TestQueryRowsLive TestRunningLive TestHADRStatementsLive TestAgentDateTimeLive TestBackupSinkLive TestBackupUTCLive; do
  grep -qE "^--- PASS: $tn " "$OUT/live.log" || missing="$missing $tn"
done
if [ $trc = 0 ] && [ -n "$missing" ]; then trc=99; fi
if [ $trc = 0 ]; then
  result "live tests" PASS $((SECONDS - t1)) "$(grep -cE '^--- PASS' "$OUT/live.log") passed, $(grep -cE '^--- SKIP' "$OUT/live.log") skipped"
else
  result "live tests" FAIL $((SECONDS - t1)) "exit $trc${missing:+ (not passed:$missing)}: $(grep -m3 -E '^--- FAIL|does not compile|_test.go:[0-9]+:' "$OUT/live.log" | tr '\n' ' ')"
fi

# the docker the proofs see: calls into the pseudo container $CT go to the server; everything else is docker's own
mkdir -p "$WORK/shim"
cat > "$WORK/shim/docker" <<'SHIM'
#!/usr/bin/env bash
# docker as the SQL Server 2016 proof's proofs see it (written by scripts/proof-mssql-2016.sh)
real=$PGV16_REAL_DOCKER
nonet() { echo "proof-mssql-2016: no network form for this call into $PGV16_CT: $*" >&2; exit 1; }
case ${1:-} in
exec)
  shift; opts=()
  while [ $# -gt 0 ]; do
    case $1 in
      -e|--env|-u|--user|-w|--workdir) opts+=("$1" "$2"); shift 2 ;;
      --) shift; break ;;
      -*) opts+=("$1"); shift ;;
      *) break ;;
    esac
  done
  ct=$1; shift
  [ "$ct" = "$PGV16_CT" ] || exec "$real" exec "${opts[@]}" "$ct" "$@"
  case $1 in
    */sqlcmd)
      args=(); prev=
      for a in "${@:2}"; do
        if [ "$prev" = -S ] && [ "$a" = localhost ]; then a=$PGV16_SQLHOST; fi
        args+=("$a"); prev=$a
      done
      exec "$real" exec "${opts[@]}" "$PGV16_TOOLS" "$PGV16_SQLCMD" "${args[@]}" ;;
    bash|sh)
      [ "${2:-}" = -c ] || nonet "$@"
      script=$3
      if [[ $script =~ ^rm\ -f\ /var/opt/mssql/log/([A-Za-z0-9_.*]+)$ ]]; then
        # a proof's own event files: deleted in the server's log folder, xp_cmdshell on for this one call where it is off
        file=${BASH_REMATCH[1]}
        exec "$real" exec -i -e SQLCMDPASSWORD "$PGV16_TOOLS" "$PGV16_SQLCMD" -S "$PGV16_SQLHOST" -U sa -C -b -h -1 -d master -i /dev/stdin >&2 <<SQL
SET NOCOUNT ON;
DECLARE @adv int = (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'show advanced options'),
        @xp int = (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'xp_cmdshell'), @rc int, @err nvarchar(2048);
IF @xp = 0 BEGIN EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'xp_cmdshell', 1; RECONFIGURE; END;
BEGIN TRY
  EXEC @rc = master.dbo.xp_cmdshell N'del /q "${PGV16_LOGDIR}${file}" 2>nul & if exist "${PGV16_LOGDIR}${file}" (exit /b 1) else (exit /b 0)', no_output;
END TRY
BEGIN CATCH SET @err = ERROR_MESSAGE(); END CATCH;
IF @xp = 0 BEGIN EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE; IF @adv = 0 BEGIN EXEC sp_configure 'show advanced options', 0; RECONFIGURE; END; END;
IF @err IS NOT NULL RAISERROR(N'the delete through xp_cmdshell: %s', 16, 1, @err);
IF @rc IS NULL OR @rc <> 0 RAISERROR(N'the delete through xp_cmdshell returned %d', 16, 1, @rc);
SQL
      fi
      case $script in */var/opt/mssql/*|*/backups/*) nonet "$@" ;; esac
      exec "$real" exec "${opts[@]}" "$PGV16_TOOLS" "$1" -c "${script//-S localhost/-S $PGV16_SQLHOST}" "${@:4}" ;;
    rm)
      for a in "${@:2}"; do case $a in /tmp/*|-f) ;; *) nonet "$@" ;; esac; done
      exec "$real" exec "${opts[@]}" "$PGV16_TOOLS" "$@" ;;
    *) nonet "$@" ;;
  esac ;;
cp)
  shift; opts=(); while [ $# -gt 0 ] && [[ $1 == -* ]]; do opts+=("$1"); shift; done
  src=$1; dst=$2
  case $dst in "$PGV16_CT":/tmp/*) exec "$real" cp "${opts[@]}" "$src" "$PGV16_TOOLS:${dst#*:}" ;; "$PGV16_CT":*) nonet cp "$@" ;; esac
  exec "$real" cp "${opts[@]}" "$src" "$dst" ;;
inspect|logs|rm|stop|start|restart|kill)
  for a in "$@"; do [ "$a" = "$PGV16_CT" ] && nonet "$@"; done
  exec "$real" "$@" ;;
*) exec "$real" "$@" ;;
esac
SHIM
chmod 755 "$WORK/shim/docker"
export PGV16_REAL_DOCKER="$REAL_DOCKER" PGV16_CT="$CT" PGV16_TOOLS="$TOOLS" PGV16_SQLHOST="$SQLHOST" PGV16_SQLCMD="$SQLCMD" PGV16_LOGDIR="$LOGDIR"

# R: each proof against the one server
is_group() { local g; for g in "${GROUP_PROOFS[@]}"; do [ "$g" = "$1" ] && return 0; done; return 1; }
for name in "${PROOFS[@]}"; do
  [ -e "$OUT/stop" ] && break
  if is_group "$name" && [ "$P_HADR" = 0 ]; then
    result "$name" "NOT PROVEN: one node" 0 "not run: IsHadrEnabled 0 (one node, no Windows cluster), the proof needs two replicas of one group; its statements are compiled in part T"
    continue
  fi
  log=$OUT/$name.log; t1=$SECONDS; prc=0
  PATH="$WORK/shim:$PATH" PGVIGIL_BIN="$BIN" PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=postgres" PGVIGIL_ADMIN_DSN="$PGVIGIL_ADMIN_DSN" \
    PGVIGIL_MSSQL_AG=pgv16_no_group PGVIGIL_MSSQL_CONTAINER="$CT" PGVIGIL_MSSQL_ADDR="$ADDR" \
    PGVIGIL_MSSQL_CONTAINER2="$CT-none" PGVIGIL_MSSQL_ADDR2="127.0.0.1:9" PGVIGIL_MSSQL_CONTAINERS="$CT" PGVIGIL_MSSQL_ADDRS="$ADDR" \
    timeout -k 120 "$PTIMEOUT" bash "scripts/proof-mssql-$name.sh" > "$log" 2>&1 &
  echo $! > "$OUT/proof.pid"
  wait $! || prc=$?
  rm -f "$OUT/proof.pid"
  if [ $prc = 0 ]; then
    result "$name" PASS $((SECONDS - t1)) "$(grep -v '^[[:space:]]*$' "$log" | tail -1)"
    grep -E 'SKIPPED|NOT RUN|NOT PROVEN|not proven|not run' "$log" | cut -c1-300 > "$OUT/$name.left-out.txt" || true
  else
    note=$(grep -m1 -E '^FAIL|proof-mssql-2016: no network form' "$log" || true)
    [ -n "$note" ] || note=$(grep -m1 -E 'level=ERROR|^Msg [0-9]+, Level 1[1-9]' -A1 "$log" | tr '\n' ' ' || true)
    [ -n "$note" ] || note=$(grep -v '^[[:space:]]*$' "$log" | tail -1 || true)
    if [ $prc = 124 ] || [ $prc = 137 ]; then note="over $PTIMEOUT s, ended; $note"; fi
    result "$name" FAIL $((SECONDS - t1)) "exit $prc: $note"
  fi
done

echo "--- S. proof-mssql-summary.sh (no SQL Server), once"
SUMMARY=PASS
PGVIGIL_BIN="$BIN" timeout -k 120 "$PTIMEOUT" bash scripts/proof-mssql-summary.sh > "$OUT/summary.log" 2>&1 || SUMMARY=FAIL
echo "S: $SUMMARY ($(grep -v '^[[:space:]]*$' "$OUT/summary.log" | tail -1))"

cell() { awk -F'|' -v step="$1" '$1 == step { print $2; found = 1 } END { if (!found) print "NOT RUN" }' "$OUT/results.txt"; }
{
  printf '| part | SQL Server 2016 |\n| --- | --- |\n'
  printf '| build | %s |\n' "$(tr '|' ' ' < "$OUT/build.txt")"
  printf '| host | %s |\n' "$(cut -c1-200 "$OUT/os.txt" 2>/dev/null || echo -)"
  printf '| certificate serial negative | %s |\n' "$(cat "$OUT/negative-serial.txt" 2>/dev/null || echo -)"
  for step in setup $(for c in $COLLECTIONS; do printf 'collect_mssql_%s ' "$c"; done) live_tests "${PROOFS[@]}"; do
    s=${step/collect_mssql_/collect mssql_}; s=${s/live_tests/live tests}
    printf '| %s | %s |\n' "$s" "$(cell "$s")"
  done
  printf '| summary | %s |\n' "$SUMMARY"
} > "$OUT/summary.md"
cat "$OUT/summary.md"
echo "--- what the passed proofs themselves left out or name as not proven (a PASS is a proof's exit code)"
for name in "${PROOFS[@]}"; do
  [ -s "$OUT/$name.left-out.txt" ] || continue
  while IFS= read -r line; do echo "  SQL Server 2016, $name: $line"; done < "$OUT/$name.left-out.txt"
done | tee "$OUT/left-out.txt"
BAD=0; NP=0
while IFS='|' read -r step verdict secs note; do
  case $verdict in
    PASS) ;;
    "NOT PROVEN: one node") NP=$((NP + 1)); echo "NOT PROVEN (one node): $step: $note" ;;
    *) BAD=$((BAD + 1)); echo "FAILED CELL: $step: $verdict ($secs s): $note" ;;
  esac
done < "$OUT/results.txt"
for name in "${PROOFS[@]}"; do [ "$(cell "$name")" = "NOT RUN" ] && { BAD=$((BAD + 1)); echo "FAILED CELL: $name: NOT RUN"; }; done
[ "$SUMMARY" = PASS ] || BAD=$((BAD + 1))
if [ $BAD -gt 0 ]; then
  echo "proof-mssql-2016: FAIL ($BAD failed or not run; $NP not proven on one node; logs in $OUT)"
  exit 1
fi
echo "proof-mssql-2016: PASS ($(cut -d'|' -f1,4 "$OUT/build.txt" | tr '|' ' '); $((${#PROOFS[@]} - NP)) proofs, $NP not proven on one node, $(wc -w <<<"$COLLECTIONS") collections, summary once; logs in $OUT)"
