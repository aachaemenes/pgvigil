#!/usr/bin/env bash
# Proof of SQL Server audit monitoring (task 158: migration 0101_mssql_audit.sql, internal/mssql/audit.go,
# internal/web/q_mssql_audit.go, web/src/mssql_audit.ts) against a real SQL Server whose audit the proof itself
# creates and, for the rules no server shows on demand (a failed audit, a restored database's orphan specification,
# a late read), on imported rows.
#
# Needs: go (the proof builds ONE binary into its temp folder; PGVIGIL_BIN names a built one instead), psql, pg_dump,
# curl, jq, ss, docker, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname (host=... user=...).
#                            It rides psql's command line: no password in it (PGPASSWORD or ~/.pgpass carries one).
#   PGVIGIL_MSSQL_CONTAINER  an existing SQL Server sandbox container, with PGVIGIL_MSSQL_ADDR (default
#                            localhost:1433) and its sa password in MSSQL_SA_PASSWORD. NOT set: the proof starts its
#                            own SQL Server container (MSSQL_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest,
#                            MSSQL_MEMORY_LIMIT_MB 2048) with a throwaway sa password made here, and removes it.
#   PGVIGIL_SKIP_PG13=1      leaves part M out (it starts and removes a postgres:13 container of its own).
#   PGVIGIL_SHOTS            a folder: part S runs (it needs chromium and node) and saves the Audit page's screenshots
#                            there in both themes. PGVIGIL_CHROMIUM_FLAGS: more flags for Chromium.
#   PGVIGIL_NO_MSSQL=1       the parts that need no SQL Server only (the migration, G, H, Y): no container, no
#                            login; the last line says so and is NOT the proof's PASS.
# The binary must carry the route /api/mssql/audit and the instance key audit_text (the wiring in web.go, config.go
# and batch.go); part S also needs the bundle built from this tree ('npm run build' in web/).
# The proof makes, and removes on every exit path: its own repository database, on the SQL Server two server audits
# with a folder for their files, a server and a database audit specification, a database, four logins, its own
# containers. It changes no server setting.
#
# Expected (written before the first run):
#  M. the whole migration chain applies on PostgreSQL 13: migrate exits 0, the newest schema version equals the main
#     repository's, and import_mssql_audit, mssql_audit_status and mssql_audit_findings exist there.
#  A. the health, as a login with VIEW SERVER STATE, VIEW ANY DEFINITION and the right to read the audit files (VIEW
#     SERVER SECURITY AUDIT from SQL Server 2022, CONTROL SERVER before). sa has made: the audit <main> to a FILE
#     (4 MB a file, 8 rollover files, queue delay 1000 ms, on failure CONTINUE) and started it; a server
#     specification with six groups, FAILED_LOGIN_GROUP among them; a database specification that records SELECT
#     and INSERT on one table by public; a second audit <off> that is never started. The first read is not partial
#     and stores: two audits; <main> started, target file, on failure CONTINUE, queue delay 1000, 4 MB, 8 rollover
#     files, the file sa reads in sys.dm_server_audit_status, read_state 'read'; <off> stopped, read_state 'waiting'
#     with a note that it was never read; the server specification switched on with 6 actions under <main>'s GUID; the database
#     specification with 'SELECT' and 'INSERT' on dbo.<table> by public; mssql_audit_read says the list, the state
#     and the specifications were read, the events are readable by the right this version asks for, and no statement
#     text is stored. The Summary cell reads '1 of 2 started', a warning. Findings: 'an audit is defined and not
#     started' for <off> only; no 'no audit covers sign-in failures'. The audit's own start is the one event listed.
#  B. the events. After the first read sa creates a login, grants it a server permission, adds it to a server role,
#     someone signs in as it with a wrong password, sa creates a table whose DEFAULT holds a marker literal, runs
#     1,000 SELECTs and 3 INSERTs on the audited table. The next read (in batches of 200 records, so it crosses
#     many buffer edges) stores each ONCE: one CREATE of a SQL LOGIN named so by sa; one GRANT for that login; one
#     ADD MEMBER to the role for that login; one failed sign-in of that login, not succeeded, error 18456 state 8,
#     with the server's reason and the client's address; one CREATE of a TABLE of that name; and counts of exactly
#     1,000 SELECT and 3 INSERT on the audited table by sa. No row holds statement text and a dump of the whole
#     repository does not hold the marker (grep 0). A read again stores nothing new: the same 1,000.
#     The same server read as three more instances that opt in (audit_text: true): under query_text full the CREATE
#     TABLE's row holds the marker; under normalized it holds the statement without the marker; under none it holds
#     no statement and text_stored is false. None of them holds the SELECTs' text: counts only. The DDL's marker is
#     stored for the instance under full alone (on every audit record of that one CREATE TABLE).
#  D. a stopped audit. sa stops <main> (ALTER SERVER AUDIT ... STATE = OFF): the next read stores it as stopped,
#     raises 'an audit is defined and not started' for it and 'no audit covers sign-in failures', the cell reads
#     '0 of 2 started'; the ALTER of the audit is listed once (ALTER on a SERVER AUDIT named <main>, by sa) and
#     'an audit or its specification was changed' is raised. sa starts it again: the next read stores it as started
#     on a new file, both findings of <main> clear (<off> keeps its own), and the events of the new file are read
#     across the file change: the audit's second 'event enabled' is listed.
#  E. the rights. A login with VIEW SERVER STATE and VIEW ANY DEFINITION and NOT the audit right: the run is neither
#     partial nor skipped; both audits are stored with read_state 'no right' naming the right; no event and no
#     count is stored for it; the cell says 'events not read' and is not critical; collection_dates says ok. A login
#     with neither right: skipped, naming both.
#  F. the sign-in rule. Twelve more wrong passwords (13 failed sign-ins within the hour): 'failed sign-ins in the
#     last hour' is a warning naming 13 and the login; 13 rows are stored.
#  G. without a server, on imported rows: an event imported twice is one row; a count imported in two calls adds up
#     (5 + 7 = 12) and two rows of one key in one call are summed (2 + 3); an audit in state failed raises 'an
#     audit failed' (critical) and the cell is critical; a specification whose GUID no audit has raises 'an audit
#     specification has no audit on this server'; a specification switched off under a started audit raises its
#     warning; an instance with no audit raises 'no audit covers sign-in failures', one whose list was not readable
#     does not; 9 failed sign-ins raise nothing, 10 a warning, 100 a critical; an ADD MEMBER to a server role
#     raises 'a server role gained a member'; an audit missing from a later complete read goes absent, from a read
#     that could not list the audits it stays and keeps its target; an OLDER read imported late changes nothing; a
#     stopped audit raises 'an audit is defined and not started' and the cell's warning, keeps its 'since' over a
#     second read and clears both when it is started; a
#     database's specification stays while the database is skipped and goes absent when the database is gone; an
#     Application log audit is stored as 'not readable'; a PostgreSQL instance is refused.
#  H. roles: pgvigil_collector may execute import_mssql_audit and may not select mssql_audit_events; pgvigil_reader
#     may select the five tables and two views and may not execute the import.
#  Y. the API on G's imported rows: /api/mssql/audit gives the parts; category=role keeps only that category; an
#     unknown category and an unknown part are refused with 400.
#  P. the API on the server's rows: audits has <main> and <off>; specs has the two specifications, the database one
#     with 'INSERT on dbo.<table> by public'; counted has SELECT on the table with 1,000 events; by_category has 13
#     failed sign-ins; the series' failed sign-ins add up to 13 and its reads to 1,000; the skipped instance has no
#     read row and its state part says 'skipped' with the reason.
#  S. (only with PGVIGIL_SHOTS) in a headless Chromium at 1600 wide, light and dark: the Audit page shows <main>
#     'started' and <off> 'not started' in the audits grid, the database specification's actions, the failed
#     sign-in rows, the SELECT count of 1,000, and for the health-only login the words 'health only'; no row of the
#     audits grid or of the events grid is taller than 100 px (corrected after the first look: a long file path and
#     a sign-in's reason wrapped in a squeezed cell and their rows were 110 to 150 px tall; the first run's checks
#     did not see it). Screenshots audit-<view>-<theme>.png, the audits grid's right end among them.
#  NOT PROVEN HERE: an Application or Security log target on a live server (SQL Server on Linux has the file target
#  only: G stores the row), a failed audit on a live server, SQL Server 2016-2019 (CONTROL SERVER), Amazon RDS
#  (msdb.dbo.rds_fn_get_audit_file: written from AWS's page), Azure SQL Managed Instance (a URL target is named as
#  not read), Azure SQL Database (the collection is skipped), a cursor file rolled away on a live server (a unit
#  test), a record over 4,000 characters, the page's accessibility (proof-a11y).
set -euo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
for t in psql pg_dump curl jq ss; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
if [ -z "${PGVIGIL_NO_MSSQL:-}" ] || [ "${PGVIGIL_SKIP_PG13:-}" != 1 ]; then
  command -v docker >/dev/null || { echo "FAIL: docker is not on this machine" >&2; exit 1; }
fi
if [ -n "${PGVIGIL_SHOTS:-}" ] && [ -z "${PGVIGIL_NO_MSSQL:-}" ]; then
  for t in chromium node; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine (PGVIGIL_SHOTS asks for the page)" >&2; exit 1; }; done
fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_audit_$SUF
DB=pgvproof_audit_$SUF
AUD=pgv_audit_$SUF; AUDOFF=pgv_auditoff_$SUF; SPEC=pgv_spec_$SUF; DBSPEC=pgv_dbspec_$SUF; ADIR=/var/opt/mssql/pgvaudit_$SUF
L1=pgv_aud_$SUF; L2=pgv_audhealth_$SUF; L3=pgv_audbare_$SUF; LNEW=pgv_audnew_$SUF
N=proof-audit-$SUF; NT=proof-audit-text-$SUF; NN=proof-audit-norm-$SUF; NX=proof-audit-none-$SUF; NH=proof-audit-health-$SUF; NB=proof-audit-bare-$SUF
MARK=pvmarkddl$SUF; MARK2=pvmarksel$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw); P3=$(pw); PNEW=$(pw)
fail() { echo "FAIL: $*" >&2; exit 1; }
# the listening sockets are read once into a variable: 'ss | grep -q' under pipefail would call a taken port free
# whenever grep left before ss had finished writing
freeport() { local l p; l=$(ss -ltn); for p in $(seq "$1" "$2"); do grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " <<<"$l" || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_DB=; MADE_L=(); MADE_CT=; MADE_PG13=; MADE_AUD=; SRV_PID=; CHR_PID=
CT=${PGVIGIL_MSSQL_CONTAINER:-}; OWN=; NOMS=${PGVIGIL_NO_MSSQL:-}
PG13=pgv-audit-pg13-$SUF
# sq <sql> [database]: as sa, the password through the environment by name
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# sqs: as sa, the batch on stdin (a login's password never rides a command line)
sqs() { docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -i /dev/stdin; }
# badlogin <login>: one sign-in with a wrong password (the server answers 18456)
badlogin() { docker exec -e SQLCMDPASSWORD="wrong-$SUF" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -l 5 -U "$1" -Q "SELECT 1" >/dev/null 2>&1 || true; }
drop_audit() {
  sq "IF DB_ID('$DB') IS NOT NULL AND EXISTS (SELECT 1 FROM [$DB].sys.database_audit_specifications WHERE name = '$DBSPEC') EXEC [$DB].sys.sp_executesql N'ALTER DATABASE AUDIT SPECIFICATION [$DBSPEC] WITH (STATE = OFF); DROP DATABASE AUDIT SPECIFICATION [$DBSPEC];';
      IF EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = '$SPEC') BEGIN ALTER SERVER AUDIT SPECIFICATION [$SPEC] WITH (STATE = OFF); DROP SERVER AUDIT SPECIFICATION [$SPEC]; END;
      IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$AUD') BEGIN ALTER SERVER AUDIT [$AUD] WITH (STATE = OFF); DROP SERVER AUDIT [$AUD]; END;
      IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = '$AUDOFF') DROP SERVER AUDIT [$AUDOFF];"
}
cleanup() {
  rc=$?
  for p in "$SRV_PID" "$CHR_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -n "$CHR_PID" ] && { wait "$CHR_PID" 2>/dev/null || true; }
  if [ -n "$MADE_CT" ]; then
    docker rm -f -v "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2   # only the container this run made
  elif [ -z "$NOMS" ] && [ -n "$CT" ]; then
    # on a sandbox that stays: the audit first (a database with a specification cannot simply go), then the rest
    if [ -n "$MADE_AUD" ]; then drop_audit >/dev/null 2>&1 || echo "CLEANUP: the audits of this run were not all dropped ($AUD, $AUDOFF, $SPEC, $DBSPEC)" >&2; fi
    if [ -n "$MADE_DB" ]; then sq "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null 2>&1 || echo "CLEANUP: database $DB not dropped" >&2; fi
    for l in "${MADE_L[@]:-}"; do
      [ -n "$l" ] || continue
      sq "IF SUSER_ID('$l') IS NOT NULL DROP LOGIN [$l];" >/dev/null 2>&1 || echo "CLEANUP: login $l not dropped" >&2
    done
    docker exec "$CT" rm -rf "$ADIR" >/dev/null 2>&1 || echo "CLEANUP: the audit folder $ADIR was not removed" >&2
  fi
  [ -n "$MADE_PG13" ] && { docker rm -f -v "$PG13" >/dev/null 2>&1 || echo "CLEANUP: container $PG13 not removed" >&2; }
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || echo "CLEANUP: $WORK not removed" >&2
  if command -v docker >/dev/null 2>&1; then
    echo "cleanup: containers of this run left: $(docker ps -a --format '{{.Names}}' | grep -c -E "^(pgv-audit-mssql-$SUF|$PG13)\$" || true)"
  fi
  exit $rc
}
trap cleanup EXIT

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN names no binary"
  BIN=$WORK/pgvigil
  (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"
fi
[ -x "$BIN" ] || fail "no binary at $BIN"

echo "--- the SQL Server"
MAJOR=16
if [ -n "$NOMS" ]; then
  echo "  NOT USED (PGVIGIL_NO_MSSQL=1): the parts A, B, D, E, F, P and S are not run"
  ADDR=none
elif [ -n "$CT" ]; then
  ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
  : "${MSSQL_SA_PASSWORD:?the sa password of the sandbox PGVIGIL_MSSQL_CONTAINER names}"
  echo "  the existing sandbox $CT ($ADDR)"
else
  CT=pgv-audit-mssql-$SUF; OWN=1
  MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
  MPORT=$(freeport 21500 21560) || fail "no free port for the SQL Server container"
  ADDR=127.0.0.1:$MPORT
  MADE_CT=1   # before the run: a container made and then failing (a port taken) is still this run's to remove
  docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_MEMORY_LIMIT_MB="${MSSQL_MEMORY_LIMIT_MB:-2048}" \
    -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run of the SQL Server container"
  echo "  its own container $CT ($ADDR)"
fi
if [ -z "$NOMS" ]; then
  export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  for _ in $(seq 1 120); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
  echo "  $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(80))")"
  MAJOR=$(sq "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int)")
fi
# the right the server asks for the audit files, by Microsoft's page of sys.fn_get_audit_file
if [ "$MAJOR" -ge 16 ]; then WANT_RIGHT="VIEW SERVER SECURITY AUDIT"; else WANT_RIGHT="CONTROL SERVER"; fi

adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

mklogin() { printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$1" "$2" | sqs >/dev/null; MADE_L+=("$1"); }
if [ -z "$NOMS" ]; then
  # the logins and the database come BEFORE the audit is started: nothing of the proof's own preparation is recorded
  mklogin "$L1" "$P1"; mklogin "$L2" "$P2"; mklogin "$L3" "$P3"
  # CONNECT ANY DATABASE: the monitoring login enters each database for its audit specification (docs/sqlserver.md)
  sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1]; GRANT CONNECT ANY DATABASE TO [$L1]; GRANT $WANT_RIGHT TO [$L1];
      GRANT VIEW SERVER STATE TO [$L2]; GRANT VIEW ANY DEFINITION TO [$L2]; GRANT CONNECT ANY DATABASE TO [$L2];" >/dev/null
  sq "CREATE DATABASE [$DB];" >/dev/null; MADE_DB=1
  sq "CREATE TABLE dbo.pv_t (id int IDENTITY PRIMARY KEY, v int NOT NULL DEFAULT 0); INSERT dbo.pv_t (v) VALUES (1), (2), (3), (4), (5);" "$DB" >/dev/null
fi
export MS_MON="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_HEALTH="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_BARE="sqlserver://$L3:$P3@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n' "$N"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n    audit_text: true\n' "$NT"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n    audit_text: true\n    query_text: normalized\n' "$NN"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n    audit_text: true\n    query_text: none\n' "$NX"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_HEALTH\n' "$NH"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_BARE\n' "$NB"
} > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate on the main repository (does the binary know the key audit_text? the wiring in config.go)"
collect() { "$BIN" collect -config "$CFG" -once mssql_audit -instance "$1" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }
iid_of() { q "select instance_id from pgvigil.instances where name='$1'"; }
# nfind <instance id> <check name> [object]: how many findings of that name (and object) the instance has
nfind() { q "select count(*) from pgvigil.mssql_audit_findings where instance_id=$1 and check_name='$2' and ('${3:-}' = '' or object = '${3:-}')"; }
cell() { q "select critical || '|' || warning || '|' || coalesce(value, '') from pgvigil.mssql_audit_status where instance_id=$1"; }

if [ "${PGVIGIL_SKIP_PG13:-}" = 1 ]; then
  echo "--- M. PostgreSQL 13: NOT RUN (PGVIGIL_SKIP_PG13=1)"; M_NOTE="M NOT RUN"
else
  echo "--- M. the migration chain on PostgreSQL 13"
  PG13PW=$(pw); export PG13PW
  P13=$(freeport 25500 25560) || fail "M: no free port for the PostgreSQL 13 container"
  MADE_PG13=1
  POSTGRES_PASSWORD="$PG13PW" docker run -d --name "$PG13" -e POSTGRES_PASSWORD -p "127.0.0.1:$P13:5432" postgres:13 >/dev/null || fail "M: docker run postgres:13"
  p13() { PGPASSWORD="$PG13PW" psql "host=127.0.0.1 port=$P13 user=postgres dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
  for _ in $(seq 1 60); do p13 "select 1" >/dev/null 2>&1 && break; sleep 1; done
  sleep 2; p13 "select 1" >/dev/null || fail "M: PostgreSQL 13 does not answer"   # the image restarts once after its init
  p13 "create database pgvigil_audit_pg13_$SUF" >/dev/null
  export PG13_DSN="host=127.0.0.1 port=$P13 user=postgres password=$PG13PW dbname=pgvigil_audit_pg13_$SUF"
  sed 's/env:PGVIGIL_REPO_DSN/env:PG13_DSN/' "$CFG" > "$WORK/pg13.yaml"
  "$BIN" migrate -config "$WORK/pg13.yaml" > "$WORK/pg13.out" 2>&1 || { tail -20 "$WORK/pg13.out" >&2; fail "M: migrate on PostgreSQL 13"; }
  V13=$(p13 "select current_setting('server_version_num')::int / 10000 || '|' || (select max(version) from pgvigil.schema_version)" "pgvigil_audit_pg13_$SUF")
  VMAIN=$(q "select max(version) from pgvigil.schema_version")
  [ "$V13" = "13|$VMAIN" ] || fail "M: PostgreSQL 13 says '$V13', want '13|$VMAIN'"
  F13=$(p13 "select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname = 'import_mssql_audit') || '|' || (select count(*) from pg_views where schemaname = 'pgvigil' and viewname in ('mssql_audit_status', 'mssql_audit_findings'))" "pgvigil_audit_pg13_$SUF")
  [ "$F13" = "1|2" ] || fail "M: 0101's function and views on PostgreSQL 13: '$F13', want '1|2'"
  docker rm -f -v "$PG13" >/dev/null 2>&1 && MADE_PG13=
  echo "M: OK (schema version $VMAIN on PostgreSQL 13)"; M_NOTE="M"
fi

if [ -z "$NOMS" ]; then
echo "--- A. the health"
docker exec "$CT" mkdir -p "$ADIR" || fail "A: the audit folder $ADIR"
MADE_AUD=1
sq "CREATE SERVER AUDIT [$AUD] TO FILE (FILEPATH = '$ADIR', MAXSIZE = 4 MB, MAX_ROLLOVER_FILES = 8) WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
    CREATE SERVER AUDIT [$AUDOFF] TO FILE (FILEPATH = '$ADIR', MAXSIZE = 2 MB, MAX_ROLLOVER_FILES = 2) WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
    CREATE SERVER AUDIT SPECIFICATION [$SPEC] FOR SERVER AUDIT [$AUD] ADD (FAILED_LOGIN_GROUP), ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
      ADD (SERVER_PERMISSION_CHANGE_GROUP), ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP), ADD (AUDIT_CHANGE_GROUP), ADD (SCHEMA_OBJECT_CHANGE_GROUP) WITH (STATE = ON);" >/dev/null
sq "CREATE DATABASE AUDIT SPECIFICATION [$DBSPEC] FOR SERVER AUDIT [$AUD] ADD (SELECT, INSERT ON dbo.pv_t BY public) WITH (STATE = ON);" "$DB" >/dev/null
sq "ALTER SERVER AUDIT [$AUD] WITH (STATE = ON);" >/dev/null
sleep 2
IFS='|' read -r SA_FILE SA_GUID <<<"$(sq "SELECT s.audit_file_path, CAST(a.audit_guid AS varchar(36)) FROM sys.dm_server_audit_status s JOIN sys.server_audits a ON a.audit_id = s.audit_id WHERE a.name = '$AUD'")"
[ -n "$SA_FILE" ] && [ -n "$SA_GUID" ] || fail "A: sa's own read of the audit came back empty"
echo "  sa reads: $AUD started, file $SA_FILE"
collect "$N"
if grep -q "partial\|skipped" "$OUT"; then fail "A: the run says partial or skipped"; fi
iid=$(iid_of "$N")
arow() { q "select state || '|' || coalesce(target, '') || '|' || coalesce(on_failure, '') || '|' || coalesce(queue_delay_ms::text, '') || '|' || coalesce(max_file_size_mb::text, '') || '|' || coalesce(max_rollover_files::text, '') || '|' || coalesce(current_file, '') || '|' || coalesce(read_state, '') from pgvigil.mssql_audit where instance_id=$1 and name='$2' and is_present"; }
[ "$(q "select count(*) from pgvigil.mssql_audit where instance_id=$iid and is_present")" = 2 ] || fail "A: audits stored (want 2): $(q "select string_agg(name || ':' || state, ', ') from pgvigil.mssql_audit where instance_id=$iid")"
[ "$(arow "$iid" "$AUD")" = "started|file|CONTINUE|1000|4|8|$SA_FILE|read" ] || fail "A: $AUD is '$(arow "$iid" "$AUD")', want 'started|file|CONTINUE|1000|4|8|$SA_FILE|read'"
[ "$(q "select state || '|' || target || '|' || read_state || '|' || (read_note like '%never read%') from pgvigil.mssql_audit where instance_id=$iid and name='$AUDOFF'")" = "stopped|file|waiting|true" ] \
  || fail "A: $AUDOFF is '$(q "select state, target, read_state, read_note from pgvigil.mssql_audit where instance_id=$iid and name='$AUDOFF'")'"
[ "$(q "select is_enabled || '|' || cardinality(action_names) || '|' || ('FAILED_LOGIN_GROUP' = any (action_names)) || '|' || (upper(audit_guid) = upper('$SA_GUID')) from pgvigil.mssql_audit_spec where instance_id=$iid and scope='server' and name='$SPEC' and is_present")" = "true|6|true|true" ] \
  || fail "A: the server specification: $(q "select is_enabled, action_names, audit_guid from pgvigil.mssql_audit_spec where instance_id=$iid and scope='server'")"
[ "$(q "select is_enabled || '|' || database_name || '|' || (select string_agg((e->>'action') || ' on ' || (e->>'object') || ' by ' || (e->>'principal'), ', ' order by e->>'action') from jsonb_array_elements(actions) e) from pgvigil.mssql_audit_spec where instance_id=$iid and scope='database' and name='$DBSPEC' and is_present")" = "true|$DB|INSERT on dbo.pv_t by public, SELECT on dbo.pv_t by public" ] \
  || fail "A: the database specification: $(q "select is_enabled, database_name, actions from pgvigil.mssql_audit_spec where instance_id=$iid and scope='database'")"
[ "$(q "select defs_read || '|' || state_read || '|' || specs_read || '|' || events_readable || '|' || events_right || '|' || text_stored from pgvigil.mssql_audit_read where instance_id=$iid")" = "true|true|true|true|$WANT_RIGHT|false" ] \
  || fail "A: mssql_audit_read: $(q "select defs_read, state_read, specs_read, events_readable, events_right, text_stored from pgvigil.mssql_audit_read where instance_id=$iid")"
[ "$(cell "$iid")" = "0|1|1 of 2 started" ] || fail "A: the cell is '$(cell "$iid")', want '0|1|1 of 2 started'"
[ "$(nfind "$iid" 'an audit is defined and not started' "$AUDOFF")|$(nfind "$iid" 'an audit is defined and not started')|$(nfind "$iid" 'no audit covers sign-in failures')" = "1|1|0" ] \
  || fail "A: the findings: $(q "select string_agg(check_name || ' [' || object || ']', '; ') from pgvigil.mssql_audit_findings where instance_id=$iid")"
[ "$(q "select count(*) || '|' || coalesce(max(category), '') || '|' || coalesce(max(action_id), '') || '|' || coalesce(max(reason), '') from pgvigil.mssql_audit_events where instance_id=$iid")" = "1|audit|AUSC|event enabled" ] \
  || fail "A: the events after the first read (want the audit's own start alone): $(q "select string_agg(category || ':' || action_id || ':' || coalesce(object_name, '') || ':' || coalesce(reason, ''), '; ') from pgvigil.mssql_audit_events where instance_id=$iid")"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='mssql_audit'")" = ok ] || fail "A: collection_dates"
echo "A: OK ($AUD started on $(basename "$SA_FILE"), $AUDOFF not started, 2 specifications, the cell '1 of 2 started')"

echo "--- B. the events, each once"
mklogin "$LNEW" "$PNEW"
sq "GRANT VIEW ANY DATABASE TO [$LNEW]; ALTER SERVER ROLE [processadmin] ADD MEMBER [$LNEW];" >/dev/null
badlogin "$LNEW"
sq "CREATE TABLE dbo.pv_made (id int NOT NULL, note varchar(40) NOT NULL DEFAULT '$MARK');" "$DB" >/dev/null
sq "DECLARE @i int = 0, @c int; WHILE @i < 1000 BEGIN SELECT @c = COUNT(*) FROM dbo.pv_t WHERE v <> -1 OR '$MARK2' = 'x'; SET @i += 1; END;
    INSERT dbo.pv_t (v) VALUES (11); INSERT dbo.pv_t (v) VALUES (12); INSERT dbo.pv_t (v) VALUES (13);" "$DB" >/dev/null
sleep 3   # the audit's queue delay is one second
SA_SEL=$(sq "SELECT COUNT(*) FROM sys.fn_get_audit_file('$ADIR/$AUD*.sqlaudit', default, default) WHERE action_id = 'SL' AND object_name = 'pv_t'")
echo "  sa reads $SA_SEL SELECT record(s) on pv_t in the audit file"
PGVIGIL_MSSQL_AUDIT_BATCH=200 collect "$N"
if grep -q "partial\|skipped" "$OUT"; then fail "B: the run says partial or skipped"; fi
ev() { q "select count(*) from pgvigil.mssql_audit_events e where e.instance_id=$iid and $1"; }
[ "$(ev "category='ddl' and action='CREATE' and class_name='SQL LOGIN' and object_name='$LNEW' and login_name='sa' and succeeded")" = 1 ] || fail "B: the CREATE LOGIN (want once): $(q "select string_agg(action || '/' || coalesce(class_name, '') || '/' || coalesce(object_name, ''), '; ') from pgvigil.mssql_audit_events where instance_id=$iid and category='ddl'")"
[ "$(ev "category='permission' and action='GRANT' and target_login='$LNEW' and login_name='sa'")" = 1 ] || fail "B: the GRANT (want once): $(q "select string_agg(action || '/' || coalesce(target_login, ''), '; ') from pgvigil.mssql_audit_events where instance_id=$iid and category='permission'")"
[ "$(ev "category='role' and action='ADD MEMBER' and object_name='processadmin' and target_login='$LNEW'")" = 1 ] || fail "B: the role membership (want once)"
[ "$(ev "category='failed sign-in' and login_name='$LNEW' and not succeeded and error_number=18456 and error_state=8 and reason like 'Login failed for user%' and client_ip is not null")" = 1 ] \
  || fail "B: the failed sign-in (want once): $(q "select string_agg(coalesce(login_name, '') || '/' || coalesce(error_number::text, '') || '/' || coalesce(error_state::text, '') || '/' || coalesce(client_ip, '') || '/' || coalesce(reason, ''), '; ') from pgvigil.mssql_audit_events where instance_id=$iid and category='failed sign-in'")"
[ "$(ev "category='ddl' and action='CREATE' and class_name='TABLE' and object_name='pv_made' and database_name='$DB'")" = 1 ] || fail "B: the CREATE TABLE (want once): $(q "select string_agg(action || '/' || coalesce(class_name, '') || '/' || coalesce(object_name, ''), '; ') from pgvigil.mssql_audit_events where instance_id=$iid and category='ddl'")"
cnt() { q "select coalesce(sum(n), 0) from pgvigil.mssql_audit_counts where instance_id=$1 and action_id='$2' and object_name='pv_t' and database_name='$DB' and login_name='sa' and succeeded"; }
[ "$(cnt "$iid" SL)|$(cnt "$iid" IN)" = "1000|3" ] || fail "B: the counts on pv_t: SELECT $(cnt "$iid" SL), INSERT $(cnt "$iid" IN); want 1000 and 3 (sa's own read of the file: $SA_SEL SELECT)"
[ "$(q "select count(*) from pgvigil.mssql_audit_counts where instance_id=$iid and category not in ('read', 'write')")" = 0 ] || fail "B: counts of another category: $(q "select string_agg(category || ':' || action_id || ':' || n, '; ') from pgvigil.mssql_audit_counts where instance_id=$iid and category not in ('read', 'write')")"
[ "$(q "select count(*) from pgvigil.mssql_audit_events where instance_id=$iid and statement is not null")" = 0 ] || fail "B: statement text is stored without the opt-in"
# nothing of the statement text anywhere in the repository: one marker is in the CREATE TABLE's DEFAULT, the other in every SELECT
pg_dump "$PGVIGIL_REPO_DSN" --data-only > "$WORK/dump1.sql" 2>"$WORK/dump1.err" || { cat "$WORK/dump1.err" >&2; fail "B: pg_dump of the repository"; }
[ "$(grep -c "pgvigil.mssql_audit_events" "$WORK/dump1.sql" || true)" -ge 1 ] || fail "B: the dump does not hold the audit tables"
MARKS=$(grep -c -e "$MARK" -e "$MARK2" "$WORK/dump1.sql" || true)
[ "$MARKS" = 0 ] || fail "B: the repository holds a statement marker on $MARKS line(s) without the opt-in"
BEFORE=$(q "select count(*) from pgvigil.mssql_audit_events where instance_id=$iid")
collect "$N" >/dev/null
[ "$(cnt "$iid" SL)|$(cnt "$iid" IN)|$(q "select count(*) from pgvigil.mssql_audit_events where instance_id=$iid")" = "1000|3|$BEFORE" ] || fail "B: a read again changed the store: SELECT $(cnt "$iid" SL), INSERT $(cnt "$iid" IN), events $(q "select count(*) from pgvigil.mssql_audit_events where instance_id=$iid") (was $BEFORE)"
echo "  listed once each: CREATE LOGIN, GRANT, ADD MEMBER, the failed sign-in, CREATE TABLE; counted 1000 SELECT and 3 INSERT; marker in the repository: 0"
# the opt-in, under each query_text policy (each instance's first read starts at the same file)
collect "$NT" >/dev/null; collect "$NN" >/dev/null; collect "$NX" >/dev/null
stmt() { q "select coalesce(max(statement), '') from pgvigil.mssql_audit_events where instance_id=$(iid_of "$1") and category='ddl' and class_name='TABLE' and object_name='pv_made'"; }
ST_FULL=$(stmt "$NT"); ST_NORM=$(stmt "$NN"); ST_NONE=$(stmt "$NX")
case "$ST_FULL" in *"CREATE TABLE dbo.pv_made"*"$MARK"*) ;; *) fail "B: opted in under full, the CREATE TABLE's statement is '$ST_FULL'" ;; esac
case "$ST_NORM" in *"$MARK"*) fail "B: opted in under normalized, the statement still holds the literal: '$ST_NORM'" ;; *"CREATE TABLE dbo.pv_made"*"DEFAULT ?"*) ;; *) fail "B: opted in under normalized, the statement is '$ST_NORM'" ;; esac
[ -z "$ST_NONE" ] || fail "B: opted in under none, a statement is stored: '$ST_NONE'"
[ "$(q "select string_agg(i.name || '=' || r.text_stored, ',' order by i.name) from pgvigil.mssql_audit_read r join pgvigil.instances i using (instance_id) where i.name in ('$NT', '$NN', '$NX')")" = "$NX=false,$NN=true,$NT=true" ] \
  || fail "B: text_stored: $(q "select string_agg(i.name || '=' || r.text_stored, ',' order by i.name) from pgvigil.mssql_audit_read r join pgvigil.instances i using (instance_id)")"
[ "$(cnt "$(iid_of "$NT")" SL)" = 1000 ] || fail "B: the opted-in instance counts $(cnt "$(iid_of "$NT")" SL) SELECT, want 1000"
# the SELECTs' own text (their marker) is in no store, opted in or not; the DDL's marker now is, once (the full instance)
pg_dump "$PGVIGIL_REPO_DSN" --data-only > "$WORK/dump2.sql" 2>"$WORK/dump2.err" || { cat "$WORK/dump2.err" >&2; fail "B: the second pg_dump"; }
[ "$(grep -c "$MARK2" "$WORK/dump2.sql" || true)" = 0 ] || fail "B: after the opt-in the dump holds the SELECTs' marker on $(grep -c "$MARK2" "$WORK/dump2.sql" || true) line(s)"
# (one CREATE TABLE is several audit records - the table, its schema, its default - so the DDL's marker is on more than one row)
[ "$(grep -c "$MARK" "$WORK/dump2.sql" || true)" -ge 1 ] && [ "$(q "select count(*) from pgvigil.mssql_audit_events e join pgvigil.instances i using (instance_id) where e.statement like '%$MARK%' and i.name <> '$NT'")" = 0 ] \
  || fail "B: the DDL's marker must be stored for the instance under full alone: $(q "select string_agg(i.name || ':' || e.action_id || '/' || coalesce(e.class_type, ''), '; ') from pgvigil.mssql_audit_events e join pgvigil.instances i using (instance_id) where e.statement like '%$MARK%'")"
echo "B: OK (the opt-in: full holds the marker, normalized 'DEFAULT ?', none nothing; a counted SELECT's text nowhere)"

echo "--- D. a stopped audit raises its finding, a started one clears it"
sq "ALTER SERVER AUDIT [$AUD] WITH (STATE = OFF);" >/dev/null
sleep 2
collect "$N" >/dev/null
[ "$(q "select state from pgvigil.mssql_audit where instance_id=$iid and name='$AUD'")" = stopped ] || fail "D: $AUD is '$(q "select state from pgvigil.mssql_audit where instance_id=$iid and name='$AUD'")' after STATE = OFF"
[ "$(nfind "$iid" 'an audit is defined and not started' "$AUD")|$(nfind "$iid" 'no audit covers sign-in failures')|$(nfind "$iid" 'an audit or its specification was changed')" = "1|1|1" ] \
  || fail "D: the findings while stopped: $(q "select string_agg(check_name || ' [' || object || ']', '; ') from pgvigil.mssql_audit_findings where instance_id=$iid")"
[ "$(cell "$iid")" = "0|1|0 of 2 started" ] || fail "D: the cell while stopped is '$(cell "$iid")'"
[ "$(ev "category='audit' and action='ALTER' and class_name='SERVER AUDIT' and object_name='$AUD' and login_name='sa'")" = 1 ] \
  || fail "D: the ALTER of the audit (want once): $(q "select string_agg(action_id || '/' || coalesce(class_name, '') || '/' || coalesce(object_name, '') || '/' || coalesce(reason, ''), '; ') from pgvigil.mssql_audit_events where instance_id=$iid and category='audit'")"
[ "$(ev "category='audit' and action_id='AUSC' and reason='event disabled'")" -ge 1 ] || fail "D: the audit's own stop record is not listed"
sq "ALTER SERVER AUDIT [$AUD] WITH (STATE = ON);" >/dev/null
sleep 3
SA_FILE2=$(sq "SELECT audit_file_path FROM sys.dm_server_audit_status WHERE name = '$AUD'")
[ -n "$SA_FILE2" ] && [ "$SA_FILE2" != "$SA_FILE" ] || fail "D: after the restart sa reads the file '$SA_FILE2' (was '$SA_FILE'): no new file"
collect "$N" >/dev/null
[ "$(q "select state || '|' || current_file from pgvigil.mssql_audit where instance_id=$iid and name='$AUD'")" = "started|$SA_FILE2" ] || fail "D: after STATE = ON: $(q "select state, current_file from pgvigil.mssql_audit where instance_id=$iid and name='$AUD'")"
[ "$(nfind "$iid" 'an audit is defined and not started' "$AUD")|$(nfind "$iid" 'an audit is defined and not started' "$AUDOFF")|$(nfind "$iid" 'no audit covers sign-in failures')" = "0|1|0" ] \
  || fail "D: the findings after the start: $(q "select string_agg(check_name || ' [' || object || ']', '; ') from pgvigil.mssql_audit_findings where instance_id=$iid")"
[ "$(cell "$iid")" = "0|1|1 of 2 started" ] || fail "D: the cell after the start is '$(cell "$iid")'"
[ "$(ev "category='audit' and action_id='AUSC' and reason='event enabled'")" = 2 ] || fail "D: the second start is not read across the file change: $(q "select string_agg(to_char(event_at, 'HH24:MI:SS') || ' ' || coalesce(reason, ''), '; ' order by event_at) from pgvigil.mssql_audit_events where instance_id=$iid and action_id='AUSC'")"
echo "D: OK (stopped: its finding, 'no audit covers sign-in failures' and '0 of 2 started'; the ALTER listed once; started again on $(basename "$SA_FILE2"): cleared)"

echo "--- E. the rights"
collect "$NH"
if grep -q "partial\|skipped" "$OUT"; then fail "E: a login without the audit right must be neither partial nor skipped"; fi
hid=$(iid_of "$NH")
[ "$(q "select count(*) || '|' || count(*) filter (where read_state = 'no right' and read_note like '%$WANT_RIGHT%') || '|' || count(*) filter (where state = 'started') from pgvigil.mssql_audit where instance_id=$hid and is_present")" = "2|2|1" ] \
  || fail "E: the health-only login's audits: $(q "select string_agg(name || ':' || state || ':' || coalesce(read_state, '') || ':' || coalesce(read_note, ''), '; ') from pgvigil.mssql_audit where instance_id=$hid")"
[ "$(q "select events_readable || '|' || defs_read || '|' || state_read from pgvigil.mssql_audit_read where instance_id=$hid")" = "false|true|true" ] || fail "E: mssql_audit_read of the health-only login"
[ "$(q "select (select count(*) from pgvigil.mssql_audit_events where instance_id=$hid) || '|' || (select count(*) from pgvigil.mssql_audit_counts where instance_id=$hid) || '|' || (select count(*) from pgvigil.mssql_audit_spec where instance_id=$hid and is_present)")" = "0|0|2" ] \
  || fail "E: the health-only login stored events or counts, or not the two specifications"
[ "$(cell "$hid")" = "0|1|1 of 2 started, events not read" ] || fail "E: the health-only cell is '$(cell "$hid")'"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$hid and collection='mssql_audit'")" = ok ] || fail "E: collection_dates of the health-only login: $(q "select status, note from pgvigil.collection_dates where instance_id=$hid and collection='mssql_audit'")"
collect "$NB"
grep -q "skipped: the login has neither VIEW ANY DEFINITION" "$OUT" || fail "E: a login with neither right is not skipped with the rights named"
echo "E: OK (without $WANT_RIGHT: the health of 2 audits, 'no right' on both, no event, status ok; with neither right: skipped)"

echo "--- F. the sign-in rule"
for _ in $(seq 1 12); do badlogin "$LNEW"; done
sleep 3
collect "$N" >/dev/null
[ "$(ev "category='failed sign-in' and login_name='$LNEW'")" = 13 ] || fail "F: failed sign-ins stored: $(ev "category='failed sign-in'") (want 13)"
[ "$(q "select severity || '|' || (detail like '13 failed sign-in(s)%') || '|' || (object like '$LNEW (13)') from pgvigil.mssql_audit_findings where instance_id=$iid and check_name='failed sign-ins in the last hour'")" = "warning|true|true" ] \
  || fail "F: the finding: $(q "select severity, object, detail from pgvigil.mssql_audit_findings where instance_id=$iid and check_name='failed sign-ins in the last hour'")"
[ "$(nfind "$iid" 'a server role gained a member' processadmin)|$(nfind "$iid" 'security changes in the last hour')" = "1|1" ] || fail "F: the role and security findings: $(q "select string_agg(check_name || ' [' || object || ']', '; ') from pgvigil.mssql_audit_findings where instance_id=$iid")"
echo "F: OK (13 failed sign-ins: a warning naming $LNEW (13))"
else
  A_NOTE="A, B, D, E, F NOT RUN"
fi

echo "--- G. the rules on imported rows"
synth() { q "select pgvigil.ensure_instance('proof-audit-synth-$SUF-$1', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')"; }
# imp <instance id> <snapshot expr> <payload json>
imp() { q "select pgvigil.import_mssql_audit($1, $2, \$j\$$3\$j\$::jsonb)" >/dev/null; }
rd() { echo "{\"kind\":\"read\",\"defs_read\":${1:-true},\"state_read\":true,\"specs_read\":${1:-true},\"db_specs_right\":true,\"events_right\":\"VIEW SERVER SECURITY AUDIT\",\"events_readable\":true,\"text_stored\":false,\"databases_listed\":${2:-true},\"databases_read\":${3:-[]},\"databases_skipped\":${4:-[]}}"; }
au() { echo "{\"kind\":\"audit\",\"audit_id\":65536,\"name\":\"$1\",\"audit_guid\":\"$2\",\"state\":\"$3\",\"target\":${4:-\"file\"},\"type\":\"FL\",\"is_enabled\":true,\"status\":${5:-null},\"on_failure\":\"SHUTDOWN SERVER INSTANCE\",\"read_state\":\"${6:-read}\"}"; }
sp() { echo "{\"kind\":\"spec\",\"scope\":\"$1\",\"database_name\":${2},\"name\":\"$3\",\"audit_guid\":\"$4\",\"is_enabled\":$5,\"actions\":[{\"action\":\"$6\",\"class\":\"SERVER\",\"is_group\":true}]}"; }
evj() { echo "{\"kind\":\"audit_event\",\"event_at\":\"$1\",\"event_key\":\"$2\",\"audit_name\":\"a1\",\"category\":\"$3\",\"action_id\":\"$4\",\"action\":\"$5\",\"class_type\":\"$6\",\"succeeded\":${7:-true},\"login_name\":\"${8:-sa}\",\"target_login\":\"${9:-}\",\"object_name\":\"${10:-}\"}"; }
nowz() { q "select to_char((now() - interval '$1') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"; }
s=$(synth once)
HZ=$(nowz '5 minutes')   # one time for every row of this part: two reads of the clock could fall in two hours
E1=$(evj "$HZ" k1 role APRL "ADD MEMBER" SG true sa app_login sysadmin)
imp "$s" "now()" "[$E1,{\"kind\":\"audit_count\",\"hour_at\":\"$HZ\",\"audit_name\":\"a1\",\"category\":\"read\",\"action_id\":\"SL\",\"login_name\":\"u\",\"database_name\":\"d\",\"object_name\":\"t\",\"succeeded\":true,\"n\":5}]"
imp "$s" "now() + interval '1 second'" "[$E1,{\"kind\":\"audit_count\",\"hour_at\":\"$HZ\",\"audit_name\":\"a1\",\"category\":\"read\",\"action_id\":\"SL\",\"login_name\":\"u\",\"database_name\":\"d\",\"object_name\":\"t\",\"succeeded\":true,\"n\":7}]"
[ "$(q "select (select count(*) from pgvigil.mssql_audit_events where instance_id=$s) || '|' || (select sum(n) || ':' || count(*) from pgvigil.mssql_audit_counts where instance_id=$s)")" = "1|12:1" ] || fail "G: an event twice / a count in two calls: $(q "select (select count(*) from pgvigil.mssql_audit_events where instance_id=$s), (select sum(n) from pgvigil.mssql_audit_counts where instance_id=$s)")"
H2="{\"kind\":\"audit_count\",\"hour_at\":\"$HZ\",\"audit_name\":\"a1\",\"category\":\"write\",\"action_id\":\"IN\",\"login_name\":\"u\",\"database_name\":\"d\",\"object_name\":\"t\",\"succeeded\":true,\"n\":"
imp "$s" "now() + interval '2 seconds'" "[${H2}2},${H2}3}]"
[ "$(q "select sum(n) || ':' || count(*) from pgvigil.mssql_audit_counts where instance_id=$s and action_id='IN'")" = "5:1" ] || fail "G: two rows of one key in one call"
[ "$(q "select count(*) from pgvigil.mssql_audit_read where instance_id=$s")" = 0 ] || fail "G: a batch without a read row wrote the health"
[ "$(nfind "$s" 'a server role gained a member' sysadmin)" = 1 ] || fail "G: 'a server role gained a member'"
# the health rules
s=$(synth health); G1=AAAAAAAA-0000-0000-0000-000000000001; G2=AAAAAAAA-0000-0000-0000-000000000002
imp "$s" "now()" "[$(rd),$(au a_ok $G1 started),$(au a_bad $G2 failed '"file"' '"RUNTIME_FAIL"'),$(au a_log AAAAAAAA-0000-0000-0000-000000000003 started '"application log"' '"STARTED"' 'not readable'),$(sp server null s_on $G1 true AUDIT_CHANGE_GROUP),$(sp server null s_off $G1 false FAILED_LOGIN_GROUP),$(sp database '"restored"' s_orphan BBBBBBBB-0000-0000-0000-00000000000B true DATABASE_ROLE_MEMBER_CHANGE_GROUP)]"
[ "$(nfind "$s" 'an audit failed' a_bad)|$(nfind "$s" 'an audit specification is switched off' s_off)|$(nfind "$s" 'an audit specification has no audit on this server' 'restored: s_orphan')|$(nfind "$s" 'no audit covers sign-in failures')" = "1|1|1|1" ] \
  || fail "G: the health findings: $(q "select string_agg(severity || ' ' || check_name || ' [' || object || ']', '; ') from pgvigil.mssql_audit_findings where instance_id=$s")"
[ "$(q "select severity from pgvigil.mssql_audit_findings where instance_id=$s and check_name='an audit failed'")" = critical ] || fail "G: 'an audit failed' is not critical"
[ "$(cell "$s")" = "1|0|2 of 3 started" ] || fail "G: the cell with a failed audit is '$(cell "$s")', want '1|0|2 of 3 started'"
[ "$(q "select read_state || '|' || target from pgvigil.mssql_audit where instance_id=$s and name='a_log'")" = "not readable|application log" ] || fail "G: the Application log audit's row"
# FAILED_LOGIN_GROUP switched on under the started audit: the info finding goes
imp "$s" "now() + interval '1 second'" "[$(rd),$(au a_ok $G1 started),$(sp server null s_off $G1 true FAILED_LOGIN_GROUP)]"
[ "$(nfind "$s" 'no audit covers sign-in failures')|$(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.mssql_audit where instance_id=$s")" = "0|a_bad=false,a_log=false,a_ok=true" ] \
  || fail "G: after the second read: covers $(nfind "$s" 'no audit covers sign-in failures'), audits $(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.mssql_audit where instance_id=$s")"
[ "$(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.mssql_audit_spec where instance_id=$s")" = "s_off=true,s_on=false,s_orphan=false" ] || fail "G: the specifications after the second read: $(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.mssql_audit_spec where instance_id=$s")"
# a read that could not list the audits keeps what is stored: an audit it does not name stays (it may be a stopped
# one, which the state view alone never lists), and one it names keeps its target and GUID; an older read changes nothing
imp "$s" "now() + interval '2 seconds'" "[$(rd false false)]"
[ "$(q "select is_present || '|' || target from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")" = "true|file" ] || fail "G: a read without the list marked an audit absent: $(q "select is_present, target from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")"
imp "$s" "now() + interval '3 seconds'" "[$(rd false false),{\"kind\":\"audit\",\"audit_id\":65536,\"name\":\"a_ok\",\"state\":\"started\",\"status\":\"STARTED\",\"read_state\":\"not read\"}]"
[ "$(q "select is_present || '|' || target || '|' || audit_guid from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")|$(nfind "$s" 'no audit covers sign-in failures')" = "true|file|$G1|0" ] || fail "G: a read without the list changed the stored audit: $(q "select is_present, target, audit_guid from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")"
imp "$s" "now() - interval '1 hour'" "[$(rd),$(au a_ok $G1 stopped)]"
[ "$(q "select state from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")" = started ] || fail "G: an older read imported late changed the state"
# a stopped audit raises its finding and the cell's warning; started again, both clear and 'since' moves
imp "$s" "now() + interval '4 seconds'" "[$(rd),$(au a_ok $G1 stopped)]"
[ "$(nfind "$s" 'an audit is defined and not started' a_ok)|$(cell "$s")" = "1|0|1|0 of 1 started" ] || fail "G: a stopped audit: $(nfind "$s" 'an audit is defined and not started' a_ok) finding(s), cell '$(cell "$s")'"
SINCE=$(q "select state_since from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")
imp "$s" "now() + interval '5 seconds'" "[$(rd),$(au a_ok $G1 stopped)]"
[ "$(q "select state_since from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")" = "$SINCE" ] || fail "G: 'since' moved while the state did not"
imp "$s" "now() + interval '6 seconds'" "[$(rd),$(au a_ok $G1 started)]"
[ "$(nfind "$s" 'an audit is defined and not started')|$(cell "$s")|$(q "select state_since > '$SINCE' from pgvigil.mssql_audit where instance_id=$s and name='a_ok'")" = "0|0|0|1 started|t" ] || fail "G: a started audit: $(nfind "$s" 'an audit is defined and not started') finding(s), cell '$(cell "$s")'"
# a database's specification: kept while the database is skipped, absent when the database is gone
s=$(synth dbs)
imp "$s" "now()" "[$(rd true true '["d1","d2"]'),$(au a1 $G1 started),$(sp database '"d1"' sp1 $G1 true SELECT),$(sp database '"d2"' sp2 $G1 true SELECT)]"
imp "$s" "now() + interval '1 second'" "[$(rd true true '["d1"]' '["d2"]'),$(au a1 $G1 started),$(sp database '"d1"' sp1 $G1 true SELECT)]"
[ "$(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.mssql_audit_spec where instance_id=$s")" = "sp1=true,sp2=true" ] || fail "G: a skipped database lost its specification"
imp "$s" "now() + interval '2 seconds'" "[$(rd true true '["d1"]'),$(au a1 $G1 started),$(sp database '"d1"' sp1 $G1 true SELECT)]"
[ "$(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.mssql_audit_spec where instance_id=$s")" = "sp1=true,sp2=false" ] || fail "G: a database that is gone kept its specification"
imp "$s" "now() + interval '3 seconds'" "[$(rd true false),$(au a1 $G1 started)]"
[ "$(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.mssql_audit_spec where instance_id=$s")" = "sp1=true,sp2=false" ] || fail "G: a read that could not list the databases changed the specifications"
# no audit at all, and a list that was not readable
s=$(synth none); imp "$s" "now()" "[$(rd)]"
[ "$(nfind "$s" 'no audit covers sign-in failures')|$(cell "$s")" = "1|0|0|none" ] || fail "G: an instance without an audit: $(nfind "$s" 'no audit covers sign-in failures') finding(s), cell '$(cell "$s")'"
s=$(synth nolist); imp "$s" "now()" "[$(rd false false)]"
[ "$(nfind "$s" 'no audit covers sign-in failures')|$(cell "$s")" = "0|0|0|not listed" ] || fail "G: an instance whose list was not readable: $(nfind "$s" 'no audit covers sign-in failures') finding(s), cell '$(cell "$s")'"
# the sign-in rule's lines: 9 nothing, 10 a warning, 100 a critical
s=$(synth signin)
signins() { q "select pgvigil.import_mssql_audit($s, now(), (select jsonb_agg(jsonb_build_object('kind', 'audit_event', 'event_at', to_char((now() - interval '10 minutes') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), 'event_key', 'f' || g, 'category', 'failed sign-in', 'action_id', 'LGIF', 'succeeded', false, 'login_name', 'ghost')) from generate_series($1, $2) g))" >/dev/null; }
signins 1 9; [ "$(nfind "$s" 'failed sign-ins in the last hour')" = 0 ] || fail "G: 9 failed sign-ins raised the finding"
signins 10 10; [ "$(q "select severity from pgvigil.mssql_audit_findings where instance_id=$s and check_name='failed sign-ins in the last hour'")" = warning ] || fail "G: 10 failed sign-ins: not a warning"
signins 11 100; [ "$(q "select severity || '|' || object from pgvigil.mssql_audit_findings where instance_id=$s and check_name='failed sign-ins in the last hour'")" = "critical|ghost (100)" ] || fail "G: 100 failed sign-ins: not critical"
pgi=$(q "select pgvigil.ensure_instance('proof-audit-pg-$SUF', 'onprem', '17.0', 170000, false, '{}')")
if q "select pgvigil.import_mssql_audit($pgi, now(), '[]'::jsonb)" >"$OUT" 2>&1; then fail "G: a PostgreSQL instance was accepted"; fi
grep -q "not a SQL Server instance" "$OUT" || fail "G: the PostgreSQL refusal's text: $(cat "$OUT")"
echo "G: OK"

echo "--- H. roles"
[ "$(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_mssql_audit(int, timestamptz, jsonb)', 'execute') || '|' || has_function_privilege('pgvigil_reader', 'pgvigil.import_mssql_audit(int, timestamptz, jsonb)', 'execute') || '|' || has_table_privilege('pgvigil_collector', 'pgvigil.mssql_audit_events', 'select') || '|' || (select bool_and(has_table_privilege('pgvigil_reader', 'pgvigil.' || t, 'select')) from unnest(array['mssql_audit_read', 'mssql_audit', 'mssql_audit_spec', 'mssql_audit_events', 'mssql_audit_counts', 'mssql_audit_status', 'mssql_audit_findings']) t)")" = "true|false|false|true" ] \
  || fail "H: the rights (collector execute | reader execute | collector select | reader select all seven)"
echo "H: OK"

echo "--- the API"
PORT=$(freeport 18340 18380) || fail "no free port for the UI"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "$U/health" >/dev/null || { cat "$WORK/serve.log" >&2; fail "the UI did not serve"; }
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/audit?instance=1")" != 404 ] || fail "the binary has no route /api/mssql/audit (the wiring in web.go)"
win() { echo "from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"; }
objs() { jq -c --arg p "$2" '.[$p] as $t | [$t.rows[] | [$t.columns, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }

echo "--- Y. the API on imported rows"
s=$(q "select instance_id from pgvigil.instances where name='proof-audit-synth-$SUF-once'")
curl -fs "$U/mssql/audit?instance=$s&$(win)" > "$WORK/y.json" || fail "Y: /api/mssql/audit"
[ "$(jq -r 'keys | sort | join(",")' "$WORK/y.json")" = "audits,by_category,counted,counted_by_category,events,findings,read,series,specs,state,status" ] || fail "Y: the parts: $(jq -r 'keys | join(",")' "$WORK/y.json")"
[ "$(objs "$WORK/y.json" events | jq -r 'map(.category + ":" + .action + ":" + .object_name) | join(",")')" = "role:ADD MEMBER:sysadmin" ] || fail "Y: the events: $(objs "$WORK/y.json" events)"
[ "$(objs "$WORK/y.json" counted | jq -r 'map(.action_id + ":" + (.events | tostring)) | sort | join(",")')" = "IN:5,SL:12" ] || fail "Y: the counted: $(objs "$WORK/y.json" counted)"
[ "$(curl -fs "$U/mssql/audit?instance=$s&$(win)&category=role&part=events" | jq '.events.rows | length')|$(curl -fs "$U/mssql/audit?instance=$s&$(win)&category=ddl&part=events" | jq '.events.rows | length')" = "1|0" ] || fail "Y: the category filter"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/audit?instance=$s&category=nonsense")|$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/audit?instance=$s&part=nonsense")" = "400|400" ] || fail "Y: an unknown category or part is not refused with 400"
echo "Y: OK"

if [ -z "$NOMS" ]; then
echo "--- P. the API on the server's rows"
curl -fs "$U/mssql/audit?instance=$iid&$(win)" > "$WORK/p.json" || fail "P: /api/mssql/audit"
[ "$(objs "$WORK/p.json" audits | jq -r 'map(.name + ":" + .state) | sort | join(",")')" = "$AUD:started,$AUDOFF:stopped" ] || fail "P: audits: $(objs "$WORK/p.json" audits | jq -c 'map([.name, .state])')"
[ "$(objs "$WORK/p.json" specs | jq -r --arg d "$DBSPEC" 'map(select(.name == $d))[0] | .scope + "|" + .actions')" = "database|INSERT on dbo.pv_t by public, SELECT on dbo.pv_t by public" ] || fail "P: the database specification: $(objs "$WORK/p.json" specs)"
[ "$(objs "$WORK/p.json" specs | jq 'length')" = 2 ] || fail "P: specifications (want 2)"
[ "$(objs "$WORK/p.json" counted | jq -r 'map(select(.action_id == "SL" and .object_name == "pv_t"))[0].events')" = 1000 ] || fail "P: the counted SELECTs: $(objs "$WORK/p.json" counted)"
[ "$(objs "$WORK/p.json" by_category | jq -r 'map(select(.category == "failed sign-in"))[0].events')" = 13 ] || fail "P: by_category: $(objs "$WORK/p.json" by_category)"
[ "$(objs "$WORK/p.json" series | jq -r '(map(.failed_signins) | add | tostring) + "|" + (map(.reads) | add | tostring) + "|" + (map(.writes) | add | tostring)')" = "13|1000|3" ] || fail "P: the series' sums: $(objs "$WORK/p.json" series)"
[ "$(curl -fs "$U/mssql/audit?instance=$iid&$(win)&category=failed%20sign-in&part=events" | jq '.events.rows | length')" = 13 ] || fail "P: the failed sign-ins through the category filter"
[ "$(curl -fs "$U/mssql/audit?instance=$hid&part=read" | jq -r '.read as $t | $t.rows[0][($t.columns | index("events_readable"))]')" = false ] || fail "P: the health-only instance's read part"
# a skipped instance (the login with neither right) has no read row; its collection's last run says why
bid=$(iid_of "$NB")
[ "$(curl -fs "$U/mssql/audit?instance=$bid" | jq -r '(.read.rows | length | tostring) + "|" + (.state as $t | $t.rows[0][($t.columns | index("status"))]) + "|" + ((.state as $t | $t.rows[0][($t.columns | index("note"))]) | test("neither VIEW ANY DEFINITION") | tostring)')" = "0|skipped|true" ] || fail "P: the skipped instance's state part: $(curl -fs "$U/mssql/audit?instance=$bid&part=state")"
echo "P: OK"

if [ -n "${PGVIGIL_SHOTS:-}" ]; then
  echo "--- S. the Audit page in a headless Chromium, both themes, 1600 wide"
  # the bundle is saved first and searched as a file: under pipefail 'curl | grep -q' fails whenever grep finds its
  # match and leaves before curl has written the whole body (the second run failed here on a served, correct bundle)
  curl -fs "http://127.0.0.1:$PORT/app.js" -o "$WORK/app.js" || fail "S: the UI serves no app.js"
  grep -q 'Audit specifications' "$WORK/app.js" || fail "S: the served bundle has no Audit page: run 'npm run build' in web/ before the proof (the binary embeds internal/web/dist)"
  mkdir -p "$PGVIGIL_SHOTS"
  CDP=$(freeport 19270 19300) || fail "S: no free port for Chromium"
  # shellcheck disable=SC2086  # PGVIGIL_CHROMIUM_FLAGS is a list of flags (--no-sandbox where Chromium runs as root)
  chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu ${PGVIGIL_CHROMIUM_FLAGS:-} about:blank > "$WORK/chrome.log" 2>&1 & CHR_PID=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || { tail -5 "$WORK/chrome.log" >&2; fail "S: Chromium's CDP port never answered"; }
  cat > "$WORK/ui.mjs" <<'JS'
const a = JSON.parse(process.argv[2]);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${a.cdp}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 15000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await ev(expr)) return true; await sleep(150); } return false; };
let fails = 0;
const check = (cond, what) => { console.log((cond ? '  ok   ' : '  FAIL ') + what); if (!cond) fails++; };
// a grid is found by the name of one of its columns and a cell by its column's name and its row's key: never by position
const fns = `
  const gridOf = name => [...document.querySelectorAll('main table')].find(t => [...t.querySelectorAll('thead th')].some(h => h.textContent.trim() === name));
  const heads = t => [...t.querySelectorAll('thead th')].map(h => h.textContent.trim());
  const rowsOf = t => t ? [...t.querySelectorAll('tbody tr')] : [];
  const cell = (t, tr, col) => tr ? tr.cells[heads(t).indexOf(col)] : undefined;
  const rowWith = (t, col, text) => rowsOf(t).find(tr => cell(t, tr, col)?.textContent.trim() === text);
  const text = (t, tr, col) => cell(t, tr, col)?.textContent.trim() ?? null;
`;
const pv = body => ev(`(() => { ${fns} ${body} })()`);
const go = async (hash, col) => {
  await ev(`document.querySelector('main')?.replaceChildren(); 'ok'`);
  await cmd('Page.navigate', { url: a.u + '/' + hash }); await sleep(400);
  return until(`(() => { ${fns} return !!gridOf(${JSON.stringify(col)}); })()`);
};
const shot = async (name, theme) => {
  const d = await cmd('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${a.shots}/audit-${name}-${theme}.png`, Buffer.from(d.result.data, 'base64'));
};
const num = v => Number(String(v ?? '').replace(/[^0-9]/g, '') || NaN);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1400, deviceScaleFactor: 1, mobile: false });
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: a.u + '/#/summary' }); await until(`!!document.querySelector('main table')`);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); sessionStorage.clear(); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  const T = `[${theme}] `;

  check(await go(`#/mssqlaudit?i=${a.iid}&w=6h`, 'on failure'), T + 'the Audit page rendered');
  const au = await pv(`const t = gridOf('on failure'); const m = rowWith(t, 'audit', ${JSON.stringify(a.aud)}), o = rowWith(t, 'audit', ${JSON.stringify(a.off)});
    return { n: rowsOf(t).length, main: m ? [text(t, m, 'state'), text(t, m, 'target'), text(t, m, 'on failure')].join('|') : null, delay: m ? text(t, m, 'queue delay (ms)') : null,
             off: o ? text(t, o, 'state') : null, events: m ? text(t, m, 'its events') : null };`);
  check(au.n === 2 && au.main === 'started|file|continue' && num(au.delay) === 1000 && au.off === 'not started' && /^read /.test(au.events ?? ''), T + `the audits grid: ${JSON.stringify(au)}`);
  const tall = col => pv(`const t = gridOf(${JSON.stringify(col)}); return Math.max(0, ...rowsOf(t).map(r => r.getBoundingClientRect().height));`);
  const auTall = await tall('on failure');
  check(auTall > 0 && auTall <= 100, T + `the audits grid's tallest row is ${Math.round(auTall)} px (at most 100)`);
  const sp = await pv(`const t = gridOf('what it records'); const r = rowWith(t, 'specification', ${JSON.stringify(a.dbspec)}); return r ? text(t, r, 'what it records') + '|' + text(t, r, 'scope') : null;`);
  check(sp === `INSERT on dbo.pv_t by public, SELECT on dbo.pv_t by public|database ${a.db}`, T + `the database specification: ${sp}`);
  await shot('health', theme);
  // the file columns stand at the right end of a wide grid: a second picture with the grid scrolled to them
  await pv(`const t = gridOf('on failure'); t.scrollIntoView({ block: 'center' }); const w = t.closest('.grid-wrap'); if (w) w.scrollLeft = w.scrollWidth; return 'ok';`);
  await sleep(200); await shot('health-right', theme);
  const evs = await pv(`const t = gridOf('for login / user'); const rs = rowsOf(t); return { n: rs.length, failed: rs.filter(r => text(t, r, 'category') === 'failed sign-ins' && text(t, r, 'login') === ${JSON.stringify(a.lnew)}).length,
    reason: (rs.map(r => text(t, r, 'reason')).find(x => /18456/.test(x ?? '')) ?? '') };`);
  check(evs.failed === 13 && /^Password did not match/.test(evs.reason) && /error 18456, state 8/.test(evs.reason), T + `the listed events: ${evs.n} rows, ${evs.failed} failed sign-ins of the login, reason '${evs.reason.slice(0, 110)}'`);
  const evTall = await tall('for login / user');
  check(evTall > 0 && evTall <= 100, T + `the events grid's tallest row is ${Math.round(evTall)} px (at most 100)`);
  const ct = await pv(`const t = gridOf('hours with events'); const r = rowsOf(t).find(r => text(t, r, 'action') === 'SELECT' && text(t, r, 'object') === 'dbo.pv_t'); return r ? { events: text(t, r, 'events'), login: text(t, r, 'login') } : null;`);
  check(ct && num(ct.events) === 1000 && ct.login === 'sa', T + `the counted SELECTs on dbo.pv_t: ${JSON.stringify(ct)}`);
  await pv(`gridOf('for login / user').scrollIntoView({ block: 'start' }); return 'ok';`); await sleep(200); await shot('events', theme);
  await pv(`gridOf('hours with events').scrollIntoView({ block: 'start' }); return 'ok';`); await sleep(200); await shot('counted', theme);
  // the category filter narrows the listed events and keeps the choice
  await pv(`const s = document.querySelector('main select[aria-label="Category of the listed events"]'); s.value = 'audit'; s.dispatchEvent(new Event('change')); return 'ok';`);
  const narrowed = await until(`(() => { ${fns} const t = gridOf('for login / user'); const rs = rowsOf(t); return rs.length > 0 && rs.every(r => text(t, r, 'category') === 'audit changes'); })()`);
  check(narrowed, T + 'the category filter shows the audit changes alone');
  await pv(`const s = document.querySelector('main select[aria-label="Category of the listed events"]'); s.value = ''; s.dispatchEvent(new Event('change')); return 'ok';`);

  check(await go(`#/mssqlaudit?i=${a.hid}&w=6h`, 'on failure'), T + 'the health-only login\'s Audit page rendered');
  const h = await pv(`const t = gridOf('on failure'); const m = rowWith(t, 'audit', ${JSON.stringify(a.aud)}); return { events: m ? text(t, m, 'its events') : null, note: [...document.querySelectorAll('main p.meta')].map(p => p.textContent).join(' ') };`);
  check(/^health only/.test(h.events ?? '') && h.events.includes(a.right) && /their events are not/.test(h.note) && /not a failure of the collection/.test(h.note), T + `health only: '${(h.events ?? '').slice(0, 110)}'`);
  await shot('health-only', theme);
}
ws.close();
process.exit(fails ? 1 : 0);
JS
  ARGS=$(jq -nc --arg cdp "$CDP" --arg u "http://127.0.0.1:$PORT" --arg shots "$PGVIGIL_SHOTS" --arg db "$DB" --argjson iid "$iid" --argjson hid "$hid" \
    --arg aud "$AUD" --arg off "$AUDOFF" --arg dbspec "$DBSPEC" --arg lnew "$LNEW" --arg right "$WANT_RIGHT" \
    '{cdp: $cdp, u: $u, shots: $shots, db: $db, iid: $iid, hid: $hid, aud: $aud, off: $off, dbspec: $dbspec, lnew: $lnew, right: $right}')
  node "$WORK/ui.mjs" "$ARGS" || fail "S: the page"
  kill "$CHR_PID" 2>/dev/null || true; wait "$CHR_PID" 2>/dev/null || true; CHR_PID=
  echo "S: OK (ten screenshots in $PGVIGIL_SHOTS: audit-<view>-<theme>.png)"; S_NOTE=", S"
else
  echo "--- S. the page in a browser: NOT RUN (PGVIGIL_SHOTS names no folder)"; S_NOTE=""
fi
fi

echo "NOT PROVEN HERE: an Application or Security log target and a failed audit on a live server, SQL Server 2016-2019 (CONTROL SERVER), Amazon RDS, Azure SQL Managed Instance, a cursor file rolled away on a live server, a record over 4,000 characters, the page's accessibility (proof-a11y)"
if [ -n "$NOMS" ]; then
  echo "proof-mssql-audit: the server-less parts only ($M_NOTE, G, H, Y) - NOT the proof's PASS"
else
  echo "proof-mssql-audit: PASS ($M_NOTE, A, B, D, E, F, G, H, Y, P${S_NOTE:-}; SQL Server $MAJOR $([ -n "$OWN" ] && echo "in its own container" || echo "sandbox $CT"))"
fi
