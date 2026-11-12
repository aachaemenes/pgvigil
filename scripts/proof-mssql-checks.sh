#!/usr/bin/env bash
# Proof of the SQL Server day-one checks (task 148: migration 0090_mssql_checks.sql; internal/mssql/checks.go,
# dboptions.go, agentalerts.go; internal/web/q_mssql_checks.go): each finding is raised by a state seeded on a real
# SQL Server and cleared by its undo, the cells of the server-option and database-option grids turn yellow or red
# and back to green, and the area cells (the Summary's) follow.
#
# Needs: docker, go (the proof builds ONE binary into its temp folder; PGVIGIL_BIN names a built one instead), psql,
# curl, jq, ss, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname and no password in it
#                       (host=... user=...; PGPASSWORD or ~/.pgpass carries one).
#   MSSQL_IMAGE         the SQL Server image, default mcr.microsoft.com/mssql/server:2022-latest.
# The binary must carry the routes /api/mssql/checks and /api/mssql/checks/fleet (the lead's wiring in web.go): the
# proof stops at its first API read when it does not.
# What it makes, and removes on every exit path the shell can catch: its own SQL Server container (SQL Server Agent
# on, the zone America/Los_Angeles so a server-local time differs from UTC, a throwaway sa password made here, never
# printed), its own repository database pgvigil_p148_<n>. Inside the
# container (gone with it): three logins, three databases, one operator, ten alerts, one trace flag, one server
# option, one row in msdb.dbo.suspect_pages. A proof killed with kill -9 leaves them: the container is
# pgv-p148-mssql-<n> and the database pgvigil_p148_<n>, both named in the first lines of the output.
#
# Expected (written before the first run):
#  A. as the monitoring login (VIEW SERVER STATE, VIEW ANY DEFINITION, db_datareader in msdb): `collect -once
#     mssql_checks` exits 0 and does not say partial; mssql_server_option holds as many present rows as sa counts in
#     sys.configurations; mssql_database_option as many as sa counts in sys.databases; every area of the nine is
#     read; mssql_build is known (the catalogue has 2022) and, where sa's build is newer than the catalogue's newest
#     (4255), newer; the image's untouched options: 'cost threshold for parallelism' 5 is a warning (sp_Blitz 188),
#     'xp_cmdshell' 0 is ok. The server's clock is not UTC (GETDATE() differs from GETUTCDATE()), so F's 'within the
#     last hour' fails if a local time is stored as UTC.
#  B. a database with AUTO_CLOSE on: its auto_close cell deviates ('warn', sp_Blitz 12), the finding 'auto close'
#     names it, the dboptions area cell counts a warning, mssql_option_risks.auto_close = 1 and the fleet API's
#     risks say 1; SET AUTO_CLOSE OFF and the next read: the cell has no deviation, the finding is gone, the count 0.
#  C. PAGE_VERIFY NONE on the same database: the page_verify cell is 'crit' (sp_Blitz 14) and the area cell counts
#     a critical; back to CHECKSUM: cleared.
#  D. 'cross db ownership chaining' 1 (RECONFIGURE): the option's cell is 'warn' (dbachecks CrossDBOwnershipChaining)
#     and a finding is raised; back to 0: 'ok', the finding gone. 'cost threshold for parallelism' 50: 'ok' (green,
#     though off its default); back to 5: 'warn' again. [Changed after run 2, before run 3: the option seeded was
#     xp_cmdshell, and run 2 stopped at its sp_configure with the server's message hidden (sq sent it to /dev/null; sq
#     now prints it on a failure). The option is now one that changes on any platform; xp_cmdshell's rule is the unit
#     test's.]
#  E. trace flag 1211 on globally (DBCC TRACEON(1211, -1)): its row is on and 'warn', the finding 'trace flag on'
#     names 1211; TRACEOFF: the row is kept, not present, and the finding is gone.
#  F. master has never had a good DBCC CHECKDB on a new container (its create date is the image's, years old): the
#     finding 'last good CHECKDB' names master, critical; DBCC CHECKDB(master): its cell holds a time within the last
#     hour and the finding is gone. A database made by the proof minutes ago with no CHECKDB raises nothing (new).
#  G. a database in FULL recovery with a full backup and a 16 MB log that cannot grow, filled to 75 % or more:
#     the 'log space used' finding names it (warning, or critical at 90 % and more) with the log reuse wait
#     LOG_BACKUP; BACKUP LOG: under 75 % and the finding gone. The log resized one megabyte at a time to 220 MB:
#     its vlf_count cell deviates (200 or more: Glenn Berry Q36); the database dropped: gone from the grid and the risks.
#     [Changed after run 3: the backups went to /dev/null, which SQL Server on Linux refuses (Msg 3634, OS error 31);
#     they go to a file in the container's data folder, removed with the container. Changed after run 4: the log reuse
#     wait was not LOG_BACKUP; sys.databases sets it when a checkpoint tries to truncate the log, so the seeding ends
#     with a CHECKPOINT in the database, and a failed check prints the stored and sa's value.]
#  H. a row of event type 2 (bad checksum) put into msdb.dbo.suspect_pages for the proof's database: the finding
#     'suspect pages' names it, critical, and the corruption area cell counts it; the row deleted: cleared.
#  I. the container's Agent has no operator and no alert: the findings 'no operator' and 'no alerts for severity 19
#     to 25' and 'no alerts for corruption errors' are raised (warning each); an operator and alerts for severities
#     19-25 and errors 823-825 that notify it: all three gone; the alerts and the operator deleted: back. Read as sa
#     (an instance of its own): the fail-safe operator is readable, 'no fail-safe operator' is raised (info) on the new
#     server. Whether the monitoring login may read it is printed, not asserted. [Changed after the fold's first run,
#     which also set the operator with master.dbo.sp_MSsetalertinfo and expected it stored: on the Linux image the
#     procedure returns 0 while its registry write under the Agent's key stores nothing (xp_instance_regread of
#     AlertFailSafeOperator is NULL right after it, AlertNotificationMethod stays 0), so the set is not proven here.]
#  J. a table with a tinyint identity at 200 (78 % of 255) in the proof's database: `collect -once mssql_identity`
#     lists it 'warn' with a finding; at 240 (94 %): 'crit'; the table dropped: the column and the finding gone,
#     the scan row says scanned.
#  K. a login with the public role only: mssql_checks exits 0 and says partial; the config, traceflags, build,
#     dboptions, dbstate, checkdb and corruption areas are read; logspace and alerts are not, each with its reason.
#     [Changed after run 5, which expected corruption not read: msdb's guest user lets the public role read
#     msdb.dbo.suspect_pages (the read succeeded as that login), while sysnotifications refused it (Msg 229).]
#     mssql_identity is skipped naming VIEW ANY DEFINITION. A login with VIEW ANY DEFINITION and no right to enter
#     a user database: mssql_identity says partial and the identity area is not read, its note naming CONNECT ANY
#     DATABASE (the run would otherwise read as '0 of 0 columns', green).
#  L. the API: GET /api/mssql/checks?instance=N answers the fourteen parts; the databases part's deviations for the
#     auto-close database say 'warn' while it is seeded; the options part's cross db ownership chaining row says
#     the status the table holds; the fleet's options part holds every instance's options.
#  M. the imports refuse a PostgreSQL instance; an older payload after a newer one changes nothing.
#  The last line is "proof-mssql-checks: PASS (A-M)" and the exit code 0.
#  NOT PROVEN HERE: a build behind the catalogue on a live server (the unit test TestJudgeBuild covers the
#  judgement; one image), SQL Server 2016-2019 and 2025 (proof-mssql-versions.sh can run this proof per version),
#  Windows, Amazon RDS, Azure SQL Managed Instance, a real damaged page, a database SUSPECT or RECOVERY_PENDING, the
#  fail-safe operator set, the page in a browser.
set -euo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
for t in docker psql curl jq ss; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_p148_$SUF
CT=pgv-p148-mssql-$SUF
DB=pgvp148_$SUF; DBLOG=pgvp148log_$SUF; DBNEW=pgvp148new_$SUF
L1=pgv_chk_$SUF; L2=pgv_chkbare_$SUF; L3=pgv_chkdef_$SUF
N=proof-checks-$SUF; NB=proof-checksbare-$SUF; NV=proof-checksdef-$SUF; NS=proof-checkssa-$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw); P3=$(pw)
fail() { echo "FAIL: $*" >&2; exit 1; }
freeport() { for p in $(seq "$1" "$2"); do ss -ltn | grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_CT=; SRV_PID=
cleanup() {
  rc=$?
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  [ -n "$MADE_CT" ] && { docker rm -f -v "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2; }
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || true
  exit $rc
}
trap cleanup EXIT
echo "container $CT, repository database $REPO_DB"

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN names no binary"
  BIN=$WORK/pgvigil
  (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"
fi

echo "--- the SQL Server"
MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MPORT=$(freeport 22433 22499) || fail "no free port for the SQL Server container"
ADDR=127.0.0.1:$MPORT
MADE_CT=1
docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_AGENT_ENABLED=true -e TZ=America/Los_Angeles -p "127.0.0.1:$MPORT:1433" \
  "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run of the SQL Server container"
# sq <sql> [database]: as sa, the password through the environment by name
# sqlcmd writes a server error to stdout: on a failure the output goes to stderr, so a caller's >/dev/null hides nothing
sq() {
  local o
  o=$(docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1" 2>&1) || { printf 'sqlcmd failed: %s\n' "$o" >&2; return 1; }
  [ -z "$o" ] || printf '%s\n' "$o"
}
sqs() {
  local o
  o=$(docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -i /dev/stdin 2>&1) || { printf 'sqlcmd failed: %s\n' "$o" >&2; return 1; }
  [ -z "$o" ] || printf '%s\n' "$o"
}
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
PV=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))")
echo "  $PV"
# the Agent's own sessions: the alerts read needs msdb and the Agent's tables, not the Agent running; waited for a while
for _ in $(seq 1 30); do [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE 'SQLAgent%'")" -gt 0 ] && break; sleep 2; done

printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\nCREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\nCREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\nGO\n" "$L1" "$P1" "$L2" "$P2" "$L3" "$P3" | sqs >/dev/null
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1]; GRANT CONNECT ANY DATABASE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L3];" >/dev/null
sq "CREATE USER [$L1] FOR LOGIN [$L1]; ALTER ROLE db_datareader ADD MEMBER [$L1];" msdb >/dev/null
sq "CREATE DATABASE [$DB]; ALTER DATABASE [$DB] SET RECOVERY SIMPLE;" >/dev/null
export MS_MON="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_BARE="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_DEF="sqlserver://$L3:$P3@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_SA="sqlserver://sa:$MSSQL_SA_PASSWORD@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"

adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n' "$N"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_BARE\n' "$NB"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_DEF\n' "$NV"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_SA\n' "$NS"
} > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "${2:-$N}" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }
chk() { collect mssql_checks "${1:-$N}" >/dev/null; }

echo "--- A. the read as the monitoring login"
chk
grep -q partial "$OUT" && fail "A: the run says partial: $(cat "$OUT")"
I=$(q "select instance_id from pgvigil.instances where name = '$N'")
NCFG=$(sq "SELECT COUNT(*) FROM sys.configurations"); NDB=$(sq "SELECT COUNT(*) FROM sys.databases")
[ "$(q "select count(*) from pgvigil.mssql_server_option where instance_id = $I and is_present")" = "$NCFG" ] || fail "A: options, want $NCFG"
[ "$(q "select count(*) from pgvigil.mssql_database_option where instance_id = $I and is_present")" = "$NDB" ] || fail "A: databases, want $NDB"
[ "$(q "select count(*) from pgvigil.mssql_check_area where instance_id = $I and is_read")" = 9 ] || fail "A: areas read: $(q "select string_agg(area || '=' || is_read || coalesce(' ' || note, ''), '; ') from pgvigil.mssql_check_area where instance_id = $I")"
BUILD=$(echo "$PV" | cut -d. -f3)
WANT_NEWER=$([ "$BUILD" -gt 4255 ] && echo true || echo false)   # a boolean joined into text reads true / false
[ "$(q "select known || '|' || newer from pgvigil.mssql_build where instance_id = $I")" = "true|$WANT_NEWER" ] || fail "A: build: $(q "select * from pgvigil.mssql_build where instance_id = $I")"
opt() { q "select status || '|' || coalesce(rule, '') from pgvigil.mssql_server_option where instance_id = $I and name = '$1'"; }
[ "$(opt 'cost threshold for parallelism')" = "warn|sp_Blitz 188" ] || fail "A: cost threshold: $(opt 'cost threshold for parallelism')"
[ "$(opt xp_cmdshell)" = "ok|" ] || fail "A: xp_cmdshell: $(opt xp_cmdshell)"
OFFS=$(sq "SELECT DATEDIFF(minute, GETUTCDATE(), GETDATE())")
[ "$OFFS" != 0 ] || fail "A: the server's clock is UTC (TZ not taken): F could not catch a local time stored as UTC"
echo "  $NCFG options, $NDB databases, build $BUILD (newer than the catalogue: $WANT_NEWER), server clock UTC$OFFS min"
echo "A: OK"

# cell <database> <option key>: the deviation's status, or 'none'
cell() { q "select coalesce(deviations -> '$2' ->> 'status', 'none') || '|' || coalesce(deviations -> '$2' ->> 'rule', '') from pgvigil.mssql_database_option where instance_id = $I and database_name = '$1' and is_present"; }
finding() { q "select count(*) || '|' || coalesce(max(severity), '') from pgvigil.mssql_check_finding where instance_id = $I and check_name = '$1' and object = '$2'"; }
area() { q "select critical || '|' || warning from pgvigil.mssql_checks_status where instance_id = $I and key = '$1'"; }

echo "--- B. AUTO_CLOSE on and off"
sq "ALTER DATABASE [$DB] SET AUTO_CLOSE ON;" >/dev/null; chk
[ "$(cell "$DB" auto_close)" = "warn|sp_Blitz 12" ] || fail "B: the cell is $(cell "$DB" auto_close)"
[ "$(finding 'auto close' "$DB")" = "1|warning" ] || fail "B: finding $(finding 'auto close' "$DB")"
[ "$(area dboptions | cut -d'|' -f2)" -ge 1 ] || fail "B: the dboptions area cell: $(area dboptions)"
[ "$(q "select auto_close from pgvigil.mssql_option_risks where instance_id = $I")" = 1 ] || fail "B: risk count"
B_SEEDED=1
echo "  seeded: cell warn, finding, area $(area dboptions), risk 1"
echo "--- L (while B is seeded). the API"
PORT=$(freeport 18340 18380) || fail "no free port for the UI"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "$U/health" >/dev/null || { cat "$WORK/serve.log" >&2; fail "the UI did not serve"; }
for r in "mssql/checks?instance=$I" "mssql/checks/fleet"; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/$r")" = 200 ] || fail "L: /api/$r does not answer 200 (the lead's wiring in web.go)"
done
curl -fs "$U/mssql/checks?instance=$I" > "$WORK/checks.json"
[ "$(jq -r 'keys | length' "$WORK/checks.json")" = 14 ] || fail "L: parts $(jq -r 'keys | join(",")' "$WORK/checks.json")"
objs() { jq -c --arg p "$2" '.[$p] as $t | [$t.rows[] | [$t.columns, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }
[ "$(objs "$WORK/checks.json" databases | jq -r --arg d "$DB" '.[] | select(.database_name == $d) | .deviations.auto_close.status')" = warn ] || fail "L: the API's auto-close cell"
[ "$(objs "$WORK/checks.json" columns | jq -r 'length')" -ge 30 ] || fail "L: the grid's columns"
curl -fs "$U/mssql/checks/fleet" > "$WORK/fleet.json"
[ "$(objs "$WORK/fleet.json" risks | jq -r --argjson i "$I" '.[] | select(.instance_id == $i) | .auto_close')" = 1 ] || fail "L: the fleet's auto-close count"
[ "$(objs "$WORK/fleet.json" options | jq -r --argjson i "$I" '[.[] | select(.instance_id == $i)] | length')" = "$NCFG" ] || fail "L: the fleet's options"
echo "L: OK (the parts while seeded; the options part checked in D)"
sq "ALTER DATABASE [$DB] SET AUTO_CLOSE OFF;" >/dev/null; chk
[ "$(cell "$DB" auto_close)" = "none|" ] || fail "B: after the undo the cell is $(cell "$DB" auto_close)"
[ "$(finding 'auto close' "$DB")" = "0|" ] || fail "B: the finding after the undo"
[ "$(q "select auto_close from pgvigil.mssql_option_risks where instance_id = $I")" = 0 ] || fail "B: risk count after the undo"
curl -fs "$U/mssql/checks/fleet?part=risks" > "$WORK/fleet.json"
[ "$(objs "$WORK/fleet.json" risks | jq -r --argjson i "$I" '.[] | select(.instance_id == $i) | .auto_close')" = 0 ] || fail "B: the fleet's count after the undo"
[ "$(q "select options ->> 'auto_close' from pgvigil.mssql_database_option where instance_id = $I and database_name = '$DB'")" = off ] || fail "B: the value after the undo"
echo "B: OK"

echo "--- C. PAGE_VERIFY NONE and back"
sq "ALTER DATABASE [$DB] SET PAGE_VERIFY NONE;" >/dev/null; chk
[ "$(cell "$DB" page_verify)" = "crit|sp_Blitz 14" ] || fail "C: the cell is $(cell "$DB" page_verify)"
[ "$(area dboptions | cut -d'|' -f1)" -ge 1 ] || fail "C: the area cell counts no critical: $(area dboptions)"
sq "ALTER DATABASE [$DB] SET PAGE_VERIFY CHECKSUM;" >/dev/null; chk
[ "$(cell "$DB" page_verify)" = "none|" ] || fail "C: after the undo the cell is $(cell "$DB" page_verify)"
[ "$(area dboptions)" = "0|0" ] || fail "C: the area cell after the undo: $(area dboptions)"
echo "C: OK"

echo "--- D. server options"
X='cross db ownership chaining'
sq "EXEC sp_configure '$X', 1; RECONFIGURE;" >/dev/null; chk
[ "$(opt "$X")" = "warn|dbachecks CrossDBOwnershipChaining" ] || fail "D: $X on: $(opt "$X")"
[ "$(finding 'server option' "$X")" = "1|warning" ] || fail "D: the $X finding: $(finding 'server option' "$X")"
curl -fs "$U/mssql/checks?instance=$I&part=options" > "$WORK/opts.json"
[ "$(objs "$WORK/opts.json" options | jq -r --arg x "$X" '.[] | select(.name == $x) | .status')" = warn ] || fail "L: the API's $X row"
sq "EXEC sp_configure '$X', 0; RECONFIGURE; EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;" >/dev/null; chk
[ "$(opt "$X")" = "ok|" ] || fail "D: $X off: $(opt "$X")"
[ "$(finding 'server option' "$X")" = "0|" ] || fail "D: the $X finding after the undo"
[ "$(opt 'cost threshold for parallelism')" = "ok|" ] || fail "D: cost threshold 50: $(opt 'cost threshold for parallelism')"
sq "EXEC sp_configure 'cost threshold for parallelism', 5; RECONFIGURE; EXEC sp_configure 'show advanced options', 0; RECONFIGURE;" >/dev/null; chk
[ "$(opt 'cost threshold for parallelism')" = "warn|sp_Blitz 188" ] || fail "D: cost threshold back to 5: $(opt 'cost threshold for parallelism')"
echo "D: OK"

echo "--- E. trace flag 1211"
flag() { q "select is_on || '|' || status || '|' || is_present from pgvigil.mssql_trace_flag where instance_id = $I and flag = $1"; }
sq "DBCC TRACEON(1211, -1) WITH NO_INFOMSGS;" >/dev/null; chk
[ "$(flag 1211)" = "true|warn|true" ] || fail "E: flag 1211 on: $(flag 1211)"
[ "$(finding 'trace flag on' 1211)" = "1|warning" ] || fail "E: the finding"
sq "DBCC TRACEOFF(1211, -1) WITH NO_INFOMSGS;" >/dev/null; chk
[ "$(flag 1211)" = "true|warn|false" ] || fail "E: flag 1211 after TRACEOFF: $(flag 1211)"
[ "$(finding 'trace flag on' 1211)" = "0|" ] || fail "E: the finding after TRACEOFF"
echo "E: OK"

echo "--- F. last good CHECKDB"
sq "CREATE DATABASE [$DBNEW];" >/dev/null; chk
NEVER=$(sq "SELECT CASE WHEN CAST(DATABASEPROPERTYEX('master', 'LastGoodCheckDbTime') AS datetime) < '19010101' THEN 1 ELSE 0 END")
if [ "$NEVER" = 1 ]; then
  [ "$(finding 'last good CHECKDB' master)" = "1|critical" ] || fail "F: master never checked: $(finding 'last good CHECKDB' master)"
else
  echo "  master was checked already on this image: the never-checked finding is not seeded here"
fi
[ "$(finding 'last good CHECKDB' "$DBNEW")" = "0|" ] || fail "F: a new database raised a CHECKDB finding"
[ "$(q "select options ->> 'last_good_checkdb' from pgvigil.mssql_database_option where instance_id = $I and database_name = '$DBNEW'")" = never ] || fail "F: the new database's cell"
sq "DBCC CHECKDB(master) WITH NO_INFOMSGS;" >/dev/null; chk
[ "$(finding 'last good CHECKDB' master)" = "0|" ] || fail "F: the finding after DBCC CHECKDB(master)"
[ "$(q "select (options ->> 'last_good_checkdb')::timestamptz > now() - interval '1 hour' from pgvigil.mssql_database_option where instance_id = $I and database_name = 'master'")" = t ] || fail "F: master's cell is not a recent time"
echo "F: OK"

echo "--- G. log space and virtual log files"
sq "CREATE DATABASE [$DBLOG] ON (NAME = d, FILENAME = '/var/opt/mssql/data/$DBLOG.mdf', SIZE = 64MB) LOG ON (NAME = l, FILENAME = '/var/opt/mssql/data/$DBLOG.ldf', SIZE = 16MB, FILEGROWTH = 0);
    ALTER DATABASE [$DBLOG] SET RECOVERY FULL; BACKUP DATABASE [$DBLOG] TO DISK = '/var/opt/mssql/data/$DBLOG.bak' WITH INIT, NO_COMPRESSION;" >/dev/null
sq "CREATE TABLE dbo.fill (id int IDENTITY, pad char(4000) NOT NULL DEFAULT 'x');
    DECLARE @pct float = 0;
    WHILE @pct < 80
    BEGIN
      INSERT dbo.fill DEFAULT VALUES; INSERT dbo.fill DEFAULT VALUES; INSERT dbo.fill DEFAULT VALUES; INSERT dbo.fill DEFAULT VALUES;
      SELECT @pct = used_log_space_in_percent FROM sys.dm_db_log_space_usage;
    END
    CHECKPOINT;" "$DBLOG" >/dev/null
chk
LG=$(finding 'log space used' "$DBLOG")
case "$LG" in "1|warning"|"1|critical") ;; *) fail "G: the log finding: $LG ($(q "select options ->> 'log_used_pct' from pgvigil.mssql_database_option where instance_id = $I and database_name = '$DBLOG'"))";; esac
RW=$(q "select options ->> 'log_reuse_wait' from pgvigil.mssql_database_option where instance_id = $I and database_name = '$DBLOG'")
[ "$RW" = LOG_BACKUP ] || fail "G: the log reuse wait is '$RW' (sa reads '$(sq "SELECT log_reuse_wait_desc FROM sys.databases WHERE name = '$DBLOG'")')"
sq "BACKUP LOG [$DBLOG] TO DISK = '/var/opt/mssql/data/$DBLOG.trn' WITH INIT;" >/dev/null; chk
[ "$(finding 'log space used' "$DBLOG")" = "0|" ] || fail "G: the log finding after BACKUP LOG"
sq "ALTER DATABASE [$DBLOG] SET RECOVERY SIMPLE; DECLARE @n int = 17, @s nvarchar(400);
    WHILE @n <= 220 BEGIN SET @s = N'ALTER DATABASE [$DBLOG] MODIFY FILE (NAME = l, SIZE = ' + CAST(@n AS nvarchar(10)) + N'MB)'; EXEC (@s); SET @n += 1; END" >/dev/null
chk
VLF=$(q "select options ->> 'vlf_count' from pgvigil.mssql_database_option where instance_id = $I and database_name = '$DBLOG'")
[ "$(cell "$DBLOG" vlf_count | cut -d'|' -f1)" = warn ] || fail "G: the VLF cell ($VLF virtual log files): $(cell "$DBLOG" vlf_count)"
[ "$(q "select vlf_high from pgvigil.mssql_option_risks where instance_id = $I")" = 1 ] || fail "G: the VLF risk count"
sq "DROP DATABASE [$DBLOG];" >/dev/null; chk
[ "$(q "select count(*) from pgvigil.mssql_database_option where instance_id = $I and database_name = '$DBLOG' and is_present")" = 0 ] || fail "G: the dropped database is still present"
[ "$(q "select vlf_high from pgvigil.mssql_option_risks where instance_id = $I")" = 0 ] || fail "G: the VLF risk count after the drop"
echo "G: OK ($VLF virtual log files)"

echo "--- H. a suspect page"
sq "INSERT msdb.dbo.suspect_pages (database_id, file_id, page_id, event_type, error_count, last_update_date) VALUES (DB_ID('$DB'), 1, 153, 2, 1, GETDATE());" >/dev/null; chk
[ "$(finding 'suspect pages' "$DB")" = "1|critical" ] || fail "H: $(finding 'suspect pages' "$DB")"
[ "$(area corruption | cut -d'|' -f1)" = 1 ] || fail "H: the corruption area cell: $(area corruption)"
sq "DELETE msdb.dbo.suspect_pages WHERE database_id = DB_ID('$DB');" >/dev/null; chk
[ "$(finding 'suspect pages' "$DB")" = "0|" ] || fail "H: after the delete"
[ "$(area corruption)" = "0|0" ] || fail "H: the corruption area cell after the delete"
echo "H: OK"

echo "--- I. Agent alerts and operators"
agent3() { echo "$(finding 'no operator' 'SQL Server Agent')/$(finding 'no alerts for severity 19 to 25' 'SQL Server Agent')/$(finding 'no alerts for corruption errors' 'SQL Server Agent')"; }
[ "$(agent3)" = "1|warning/1|warning/1|warning" ] || fail "I: a new server: $(agent3)"
echo "  the monitoring login reads the fail-safe operator: $(q "select failsafe_read from pgvigil.mssql_agent_alerting where instance_id = $I")"
chk "$NS"
IS=$(q "select instance_id from pgvigil.instances where name = '$NS'")
fsafe() { q "select a.failsafe_read || '|' || coalesce(a.failsafe_operator, '') || '|' || (select count(*) || coalesce(max(':' || f.severity), '') from pgvigil.mssql_check_finding f where f.instance_id = $IS and f.check_name = 'no fail-safe operator') from pgvigil.mssql_agent_alerting a where a.instance_id = $IS"; }
[ "$(fsafe)" = "true||1:info" ] || fail "I: as sa on a new server: $(fsafe) (read|operator|finding:severity)"
{
  echo "EXEC msdb.dbo.sp_add_operator @name = N'pgvp_dba', @enabled = 1, @email_address = N'dba@example.invalid';"
  for s in 19 20 21 22 23 24 25; do echo "EXEC msdb.dbo.sp_add_alert @name = N'pgvp sev $s', @severity = $s, @include_event_description_in = 1; EXEC msdb.dbo.sp_add_notification @alert_name = N'pgvp sev $s', @operator_name = N'pgvp_dba', @notification_method = 1;"; done
  for e in 823 824 825; do echo "EXEC msdb.dbo.sp_add_alert @name = N'pgvp err $e', @message_id = $e, @include_event_description_in = 1; EXEC msdb.dbo.sp_add_notification @alert_name = N'pgvp err $e', @operator_name = N'pgvp_dba', @notification_method = 1;"; done
  echo "GO"
} | sqs >/dev/null
chk
[ "$(agent3)" = "0|/0|/0|" ] || fail "I: set up: $(agent3)"
[ "$(q "select count(*) from pgvigil.mssql_agent_alert where instance_id = $I and enabled and notifies = 1")" = 10 ] || fail "I: the ten alerts"
[ "$(q "select count(*) from pgvigil.mssql_agent_operator where instance_id = $I and has_email")" = 1 ] || fail "I: the operator"
{
  for s in 19 20 21 22 23 24 25; do echo "EXEC msdb.dbo.sp_delete_alert @name = N'pgvp sev $s';"; done
  for e in 823 824 825; do echo "EXEC msdb.dbo.sp_delete_alert @name = N'pgvp err $e';"; done
  echo "EXEC msdb.dbo.sp_delete_operator @name = N'pgvp_dba';"; echo "GO"
} | sqs >/dev/null
chk
[ "$(agent3)" = "1|warning/1|warning/1|warning" ] || fail "I: after the undo: $(agent3)"
echo "I: OK"

echo "--- J. identity columns"
idc() { q "select status || '|' || pct_used from pgvigil.mssql_identity_column where instance_id = $I and database_name = '$DB' and table_name = 'pv_tiny'"; }
sq "CREATE TABLE dbo.pv_tiny (id tinyint IDENTITY(1, 1) NOT NULL, v int NULL); INSERT dbo.pv_tiny (v) SELECT TOP (200) 1 FROM sys.all_columns;" "$DB" >/dev/null
collect mssql_identity >/dev/null
[ "$(idc)" = "warn|78.43" ] || fail "J: at 200: $(idc)"
[ "$(finding 'identity column near its limit' "$DB.dbo.pv_tiny.id")" = "1|warning" ] || fail "J: the finding at 200"
sq "INSERT dbo.pv_tiny (v) SELECT TOP (40) 1 FROM sys.all_columns;" "$DB" >/dev/null
collect mssql_identity >/dev/null
[ "$(idc)" = "crit|94.12" ] || fail "J: at 240: $(idc)"
sq "DROP TABLE dbo.pv_tiny;" "$DB" >/dev/null
collect mssql_identity >/dev/null
[ "$(idc)" = "" ] || fail "J: the column after the drop: $(idc)"
[ "$(finding 'identity column near its limit' "$DB.dbo.pv_tiny.id")" = "0|" ] || fail "J: the finding after the drop"
[ "$(q "select scanned from pgvigil.mssql_identity_scan where instance_id = $I and database_name = '$DB'")" = t ] || fail "J: the scan row"
echo "J: OK"

echo "--- K. a login with the public role only"
collect mssql_checks "$NB" >/dev/null || fail "K: the run failed"
grep -q partial "$OUT" || fail "K: the run does not say partial: $(cat "$OUT")"
IB=$(q "select instance_id from pgvigil.instances where name = '$NB'")
[ "$(q "select string_agg(area || '=' || is_read, ',' order by area) from pgvigil.mssql_check_area where instance_id = $IB")" = "alerts=false,build=true,checkdb=true,config=true,corruption=true,dboptions=true,dbstate=true,logspace=false,traceflags=true" ] \
  || fail "K: areas $(q "select string_agg(area || '=' || is_read || ' ' || coalesce(note, ''), '; ' order by area) from pgvigil.mssql_check_area where instance_id = $IB")"
[ "$(q "select count(*) from pgvigil.mssql_check_area where instance_id = $IB and not is_read and note is not null")" = 2 ] || fail "K: a reason missing"
collect mssql_identity "$NB" >/dev/null
grep -q "VIEW ANY DEFINITION" "$OUT" || fail "K: mssql_identity not skipped with the right named: $(cat "$OUT")"
collect mssql_identity "$NV" >/dev/null || fail "K: mssql_identity as the login that may enter no database failed"
grep -q partial "$OUT" || fail "K: that run does not say partial: $(cat "$OUT")"
IV=$(q "select instance_id from pgvigil.instances where name = '$NV'")
[ "$(q "select is_read || '|' || (note like '%CONNECT ANY DATABASE%') from pgvigil.mssql_check_area where instance_id = $IV and area = 'identity'")" = "false|true" ] \
  || fail "K: the identity area: $(q "select is_read || ' ' || coalesce(note, '') from pgvigil.mssql_check_area where instance_id = $IV and area = 'identity'")"
echo "K: OK"

echo "--- M. the imports' refusals"
NOW=$(q "select count(*) from pgvigil.mssql_check_finding where instance_id = $I")
q "select pgvigil.import_mssql_checks($I, now() - interval '1 day', '[{\"kind\":\"area\",\"area\":\"dboptions\",\"read\":1},{\"kind\":\"finding\",\"area\":\"dboptions\",\"check_name\":\"late\",\"object\":\"x\",\"severity\":\"warning\",\"rule\":\"r\"}]')" >/dev/null
[ "$(q "select count(*) from pgvigil.mssql_check_finding where instance_id = $I")" = "$NOW" ] || fail "M: an older payload changed the findings"
PGI=$(q "select pgvigil.ensure_instance('proof-checks-pg-$SUF', 'onprem', '17.0', 170000, false, '{}')")
for f in import_mssql_checks import_mssql_identity; do
  if q "select pgvigil.$f($PGI, now(), '[]')" > "$OUT" 2>&1; then fail "M: $f accepted a PostgreSQL instance"; fi
  grep -q "not a SQL Server instance" "$OUT" || fail "M: $f's refusal: $(cat "$OUT")"
done
echo "M: OK"
echo "proof-mssql-checks: PASS (A-M)"
