#!/usr/bin/env bash
# Proof of the SQL Server custom checks (ST6: internal/mssql/custom.go mssql_custom, internal/mssqlread, migration
# 0262, the custom: keys engine / procedure / database in internal/collect/custom.go): the DBA's own T-SQL and
# procedures run as the documented read login on a real SQL Server, each on a connection of its own in a transaction
# rolled back, behind ONE fence (the login's rights), into the PostgreSQL custom checks' store.
#
# Needs: docker, go (the proof builds ONE binary into its temp folder with the WIRING patch applied by the caller;
# PGVIGIL_BIN names a built one instead), psql, curl, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname and no password in it.
#   MSSQL_IMAGE         the SQL Server image, default mcr.microsoft.com/mssql/server:2022-latest (2017, 2019, 2022:
#                       the box driver runs the proof once per version).
# The tree must carry the WIRING patch (scripts/proof-st6-wiring.patch: the frame's InstanceCollector in mssql.go):
# the proof stops at its first collection when it does not.
# What it makes, and removes on every exit path the shell can catch: its own SQL Server container (a throwaway sa
# password made here, never printed), its own repository database pgvigil_st6_<n>; inside the container (gone with
# it): eight logins, two databases, one table, two procedures, one trace (closed by the proof). A proof killed with
# kill -9 leaves them: the container is pgv-st6-mssql-<n> and the database pgvigil_st6_<n>, both named first.
#
# Expected (written before the first run):
#  V  the documented read login (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE, ALTER TRACE, msdb
#     db_datareader, EXECUTE on xp_readerrorlog - docs/sqlserver.md): `collect -once mssql_custom` is ok; the value
#     check v_dbs (SELECT COUNT(*) AS value FROM sys.databases, warning 0) holds sa's count and is a warning; the check
#     v_appdb with database: pgvp_app reads that database (DB_NAME() there: value 1 by its CASE); the rows check
#     r_dbs holds row_count = sa's count and its rows kept (each row a database name).
#  P  procedure p_secret (pgvp_util.dbo.pgv_check_secret, owned by dbo, reading dbo.secret that the login may NOT
#     SELECT; the login has EXECUTE on the procedure only): its one row kept (ownership chaining); p_missing names a
#     procedure that does not exist: its error says so with Msg 2812 and the grant; p_nogrant (a procedure the login
#     may not EXECUTE): its error names Msg 229 and the grant.
#  F  the fence, one instance per login, each with the check v_dbs only (bulkadmin where the server takes it: SQL
#     Server on Linux before 2022 refuses the role, Msg 16202 - then the bare ADMINISTER BULK OPERATIONS, or the row is
#     NOT RUN on that version, said; added after run 1): the collection's row in collection_dates
#     is an error naming the right, and NO custom_results row, for a sysadmin ('role sysadmin'), CONTROL SERVER,
#     ALTER ANY CONNECTION, IMPERSONATE on sa ('IMPERSONATE on login sa'), bulkadmin ('ADMINISTER BULK OPERATIONS'),
#     and the documented login with db_datawriter in pgvp_app ('in database pgvp_app DELETE, INSERT, UPDATE'). The documented login
#     itself is V (it passes).
#  C  a connection per check: c1_set sets CONTEXT_INFO, a SESSION_CONTEXT key and a Session applock; c2_read, run
#     after it on the same instance in the same run, reads none of them (value 0).
#  S  c1_set also SETs LOCK_TIMEOUT 5 and USEs pgvp_app: c2_read reads the frame's 2000 and master (value 0).
#  W  w_insert (an INSERT into pgvp_app.dbo.target, which the login may not write): error, the server's own
#     permission message; w_commit (COMMIT, then a SELECT): error 'the check ended the transaction it ran in';
#     w_trace (sp_trace_create): error 'made trace <id> (<path>)', and the trace is THERE afterwards (pgvigil left it;
#     the proof closes it as sa); w_slow (WAITFOR 35 s): error 'did not finish within 30 s'.
#  X  x_rows (101 rows): row_count 101, 100 kept, note 'the first 100 of 101 rows kept'; x_cols (51 columns): note
#     'the first 50 of 51 columns kept'; x_cell (a 2,000-character text): its kept cell exactly 1,000 characters (cut,
#     no words added); x_dec (decimal 12.50) value 12.5; x_money (money 7.25) 7.25; x_bit (bit 1) 1;
#     x_text (a text value column): error 'nvarchar column is not a number'; x_sets (two result sets): note 'the
#     first of 2 result sets read'.
#  E  the PostgreSQL check pg_only (no engine) has no custom_checks row on any SQL Server instance.
#  R  the store: custom_report() lists the SQL Server checks with engine sqlserver; custom_findings holds v_dbs's
#     warning and the W checks' errors with the SQL Server words ('a T-SQL batch or procedure that runs as the read
#     login, in a transaction rolled back'); GET /api/custom?instance=<id> on a serve -no-login answers the checks and
#     instance engine sqlserver.
#  L  internal/web TestST6FencesLive (go test, the live variables set): a custom report runs as the documented login,
#     is refused naming ALTER ANY CONNECTION for the login with it and refused for a sysadmin; community tools let
#     the ALTER ANY CONNECTION login in and refuse the sysadmin (the lead's 12:5x: they keep openMS's check alone).
#  NOT PROVEN here: SQL Server on Windows (Linux containers), Azure SQL Database / Managed Instance / Amazon RDS (the
#     rights reads differ there), a write through an existing linked server whose mapping holds remote rights (named in
#     docs/custom.md, not stopped), the check left in another principal's context (unreachable: the fence refuses
#     every IMPERSONATE), the Custom tab drawn in a browser (the walks on the demo).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL, keyword form, no dbname}"
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_st6_$SUF
CT=pgv-st6-mssql-$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
freeport() { local l p; l=$(ss -ltn); for p in $(seq "$1" "$2"); do grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " <<<"$l" || { echo "$p"; return; }; done; return 1; }
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
grep -q 'InstanceCollector' "$ROOT/internal/mssql/mssql.go" || fail "the tree lacks the WIRING patch (git apply scripts/proof-st6-wiring.patch)"

echo "--- the SQL Server"
MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MPORT=$(freeport 22500 22599) || fail "no free port for the SQL Server container"
ADDR=127.0.0.1:$MPORT
MADE_CT=1
docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MPORT:1433" \
  "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run of the SQL Server container"
docker exec "$CT" sh -c 'test -x /opt/mssql-tools18/bin/sqlcmd || { mkdir -p /opt/mssql-tools18/bin && ln -s /opt/mssql-tools/bin/sqlcmd /opt/mssql-tools18/bin/sqlcmd; }' \
  || fail "the sqlcmd link in $CT"
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

# the logins: the documented read login, and one per fence row
declare -A PWS
LOGINS="mon sa ctl conn imp bulk dw"
for k in $LOGINS; do PWS[$k]=$(pw); done
{
  for k in $LOGINS; do printf "CREATE LOGIN [pgv_%s_%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$k" "$SUF" "${PWS[$k]}"; done
  printf "GO\n"
  # every login but sa's starts as the documented read login
  for k in mon ctl conn imp bulk dw; do
    printf "GRANT VIEW SERVER STATE TO [pgv_%s_%s]; GRANT VIEW ANY DEFINITION TO [pgv_%s_%s]; GRANT CONNECT ANY DATABASE TO [pgv_%s_%s]; GRANT ALTER TRACE TO [pgv_%s_%s];\n" "$k" "$SUF" "$k" "$SUF" "$k" "$SUF" "$k" "$SUF"
    printf "USE msdb; CREATE USER [pgv_%s_%s] FOR LOGIN [pgv_%s_%s]; ALTER ROLE db_datareader ADD MEMBER [pgv_%s_%s];\nUSE master; CREATE USER [pgv_%s_%s] FOR LOGIN [pgv_%s_%s]; GRANT EXECUTE ON master.sys.xp_readerrorlog TO [pgv_%s_%s];\nGO\n" "$k" "$SUF" "$k" "$SUF" "$k" "$SUF" "$k" "$SUF" "$k" "$SUF" "$k" "$SUF"
  done
  printf "ALTER SERVER ROLE sysadmin ADD MEMBER [pgv_sa_%s];\nGRANT CONTROL SERVER TO [pgv_ctl_%s];\nGRANT ALTER ANY CONNECTION TO [pgv_conn_%s];\nGRANT IMPERSONATE ON LOGIN::[sa] TO [pgv_imp_%s];\nGO\n" "$SUF" "$SUF" "$SUF" "$SUF"
  # the databases: an application database with a table no login may write, and a utility database with the procedures
  cat <<SQL
CREATE DATABASE pgvp_app;
CREATE DATABASE pgvp_util;
GO
USE pgvp_app;
CREATE TABLE dbo.target (id int);
CREATE USER [pgv_dw_$SUF] FOR LOGIN [pgv_dw_$SUF];
ALTER ROLE db_datawriter ADD MEMBER [pgv_dw_$SUF];
GO
USE pgvp_util;
CREATE TABLE dbo.secret (k nvarchar(40));
INSERT dbo.secret VALUES (N'only-through-the-procedure');
GO
CREATE PROCEDURE dbo.pgv_check_secret AS SELECT k FROM dbo.secret;
GO
CREATE PROCEDURE dbo.pgv_check_nogrant AS SELECT 1 AS value;
GO
CREATE USER [pgv_mon_$SUF] FOR LOGIN [pgv_mon_$SUF];
GRANT EXECUTE ON dbo.pgv_check_secret TO [pgv_mon_$SUF];
GO
SQL
} | sqs >/dev/null
# bulkadmin on its own: SQL Server on Linux before 2022 refuses the role (Msg 16202, run 1 on 2019 / 2017); then the bare
# right; a server that refuses both leaves the bulk row NOT RUN on that version, said
BULK_OK=1
if ! sq "ALTER SERVER ROLE bulkadmin ADD MEMBER [pgv_bulk_$SUF];" >/dev/null 2>"$WORK/bulk.err"; then
  if ! sq "GRANT ADMINISTER BULK OPERATIONS TO [pgv_bulk_$SUF];" >/dev/null 2>>"$WORK/bulk.err"; then
    BULK_OK=; echo "NOT RUN F bulk on $PV: the server refuses bulkadmin and ADMINISTER BULK OPERATIONS ($(grep -o 'Msg [0-9]*' "$WORK/bulk.err" | sort -u | tr '\n' ' '))"
  fi
fi
dsn() { echo "sqlserver://pgv_$1_$SUF:${PWS[$1]}@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"; }
for k in $LOGINS; do export "MS_$(tr '[:lower:]' '[:upper:]' <<<"$k")=$(dsn "$k")"; done

echo "--- the repository"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO_DB" >/dev/null; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
LONG=$(head -c 2000 /dev/zero | tr '\0' 'x')
COLS51=$(for i in $(seq 1 51); do printf '%s%s AS c%s' "$([ "$i" -gt 1 ] && echo ', ')" "$i" "$i"; done)
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - {name: st6-mon-$SUF, engine: sqlserver, dsn: env:MS_MON, tags: [st6:mon]}
  - {name: st6-sa-$SUF, engine: sqlserver, dsn: env:MS_SA, tags: [st6:fence]}
  - {name: st6-ctl-$SUF, engine: sqlserver, dsn: env:MS_CTL, tags: [st6:fence]}
  - {name: st6-conn-$SUF, engine: sqlserver, dsn: env:MS_CONN, tags: [st6:fence]}
  - {name: st6-imp-$SUF, engine: sqlserver, dsn: env:MS_IMP, tags: [st6:fence]}
  - {name: st6-bulk-$SUF, engine: sqlserver, dsn: env:MS_BULK, tags: [st6:fence]}
  - {name: st6-dw-$SUF, engine: sqlserver, dsn: env:MS_DW, tags: [st6:fence]}
custom:
  - {name: pg_only, sql: SELECT 1 AS value}
  - {name: v_dbs, engine: sqlserver, sql: "SELECT COUNT(*) AS value FROM sys.databases", warning: 0, tags: [st6:mon, st6:fence]}
  - {name: v_appdb, engine: sqlserver, database: pgvp_app, sql: "SELECT CASE WHEN DB_NAME() = N'pgvp_app' THEN 1 ELSE 0 END AS value", tags: [st6:mon]}
  - {name: r_dbs, engine: sqlserver, rule: rows, sql: "SELECT name FROM sys.databases ORDER BY name", tags: [st6:mon]}
  - {name: p_secret, procedure: pgvp_util.dbo.pgv_check_secret, rule: rows, tags: [st6:mon]}
  - {name: p_missing, procedure: pgvp_util.dbo.pgv_no_such_check, tags: [st6:mon]}
  - {name: p_nogrant, procedure: pgvp_util.dbo.pgv_check_nogrant, tags: [st6:mon]}
  - {name: c1_set, engine: sqlserver, tags: [st6:mon], sql: "SET CONTEXT_INFO 0x01; EXEC sys.sp_set_session_context N'pgv', N'set'; DECLARE @r int; EXEC @r = sp_getapplock @Resource = N'pgv_st6', @LockMode = 'Exclusive', @LockOwner = 'Session'; SET LOCK_TIMEOUT 5; USE pgvp_app; SELECT @r AS value"}
  - {name: c2_read, engine: sqlserver, tags: [st6:mon], sql: "SELECT CASE WHEN CONTEXT_INFO() IS NULL AND SESSION_CONTEXT(N'pgv') IS NULL AND APPLOCK_MODE('public', N'pgv_st6', 'Session') = 'NoLock' AND @@LOCK_TIMEOUT = 2000 AND DB_NAME() = N'master' THEN 0 ELSE 1 END AS value"}
  - {name: w_insert, engine: sqlserver, tags: [st6:mon], sql: "INSERT INTO pgvp_app.dbo.target VALUES (1); SELECT 1 AS value"}
  - {name: w_commit, engine: sqlserver, tags: [st6:mon], sql: "COMMIT; SELECT 1 AS value"}
  - {name: w_trace, engine: sqlserver, tags: [st6:mon], sql: "DECLARE @id int; EXEC sp_trace_create @id OUTPUT, 0, N'/tmp/pgv_st6_$SUF'; SELECT @id AS value"}
  - {name: w_slow, engine: sqlserver, tags: [st6:mon], sql: "WAITFOR DELAY '00:00:35'; SELECT 1 AS value"}
  - {name: x_rows, engine: sqlserver, rule: rows, tags: [st6:mon], sql: "SELECT TOP (101) o.object_id FROM sys.all_objects o ORDER BY o.object_id"}
  - {name: x_cols, engine: sqlserver, rule: rows, tags: [st6:mon], sql: "SELECT $COLS51"}
  - {name: x_cell, engine: sqlserver, rule: rows, tags: [st6:mon], sql: "SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 2000) AS long_text"}
  - {name: x_dec, engine: sqlserver, tags: [st6:mon], sql: "SELECT CAST(12.50 AS decimal(9,2)) AS value"}
  - {name: x_money, engine: sqlserver, tags: [st6:mon], sql: "SELECT CAST(7.25 AS money) AS value"}
  - {name: x_bit, engine: sqlserver, tags: [st6:mon], sql: "SELECT CAST(1 AS bit) AS value"}
  - {name: x_text, engine: sqlserver, tags: [st6:mon], sql: "SELECT N'abc' AS value"}
  - {name: x_sets, engine: sqlserver, tags: [st6:mon], sql: "SELECT 1 AS value; SELECT 2 AS other"}
EOF
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
[[ $(q "select count(*) from pgvigil.schema_version where version = '0262_mssql_custom.sql'") == 1 ]] || fail "0262 is not applied"

# ccheck <instance> <check> <column>: the latest result's column (text)
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
res() { q "select coalesce(($3)::text, '-') from pgvigil.custom_results r join pgvigil.instances i using (instance_id) where i.name = '$1' and r.check_name = '$2' order by r.snapshot_at desc limit 1"; }
collect() { "$BIN" collect -config "$CFG" -once mssql_custom -instance "$1" > "$OUT" 2>&1 || true; }

echo "--- V P C S W X E: the documented read login (one run: the WAITFOR check makes it about 40 s)"
MON=st6-mon-$SUF
collect "$MON"
[[ $(q "select status from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = '$MON' and d.collection = 'mssql_custom'") == ok ]] \
  || fail "V: the collection on $MON: $(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = '$MON' and d.collection = 'mssql_custom'"); $(tail -3 "$OUT")"
NDB=$(sq "SELECT COUNT(*) FROM sys.databases")
[[ $(res "$MON" v_dbs "status || ' ' || value") == "warning $NDB" ]] || fail "V: v_dbs $(res "$MON" v_dbs "status || ' ' || coalesce(value::text, '') || ' ' || coalesce(error, '')") (sa counts $NDB)"
[[ $(res "$MON" v_appdb "status || ' ' || value") == "ok 1" ]] || fail "V: v_appdb (database: pgvp_app) $(res "$MON" v_appdb "status || ' ' || coalesce(value::text, '') || ' ' || coalesce(error, '')")"
[[ $(res "$MON" r_dbs "row_count") == "$NDB" && $(res "$MON" r_dbs "jsonb_array_length(rows)") == "$NDB" && $(res "$MON" r_dbs "rows_kept") == true ]] || fail "V: r_dbs $(res "$MON" r_dbs "row_count || ' ' || coalesce(error, '')")"
ok "V: as the documented read login: v_dbs = sa's $NDB databases (a warning over 0), v_appdb ran in pgvp_app, r_dbs counted $NDB rows and kept them"
[[ $(res "$MON" p_secret "row_count || ' ' || (rows->0->>0)") == "1 only-through-the-procedure" ]] || fail "P: p_secret $(res "$MON" p_secret "coalesce(error, '') || ' ' || coalesce(rows::text, '')")"
[[ $(res "$MON" p_missing "status") == error && $(res "$MON" p_missing "error") == *"Msg 2812"*"GRANT EXECUTE"* ]] || fail "P: p_missing $(res "$MON" p_missing "status || ' ' || coalesce(error, '')")"
[[ $(res "$MON" p_nogrant "status") == error && $(res "$MON" p_nogrant "error") == *"Msg 229"*"GRANT EXECUTE"* ]] || fail "P: p_nogrant $(res "$MON" p_nogrant "status || ' ' || coalesce(error, '')")"
SELFAIL=$(docker exec -e SQLCMDPASSWORD="${PWS[mon]}" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -U "pgv_mon_$SUF" -d pgvp_util -Q "SELECT k FROM dbo.secret" 2>&1 || true)
[[ $SELFAIL == *"denied"* ]] || fail "P: the login read dbo.secret directly: $SELFAIL"
ok "P: p_secret read dbo.secret through its procedure (the login may not SELECT it: '$(grep -o 'The SELECT permission was denied[^.]*' <<<"$SELFAIL" | head -1)'); a missing procedure and one without EXECUTE answer in words"
[[ $(res "$MON" c1_set "status") == ok && $(res "$MON" c2_read "status || ' ' || value") == "ok 0" ]] || fail "C/S: c1_set $(res "$MON" c1_set "status || ' ' || coalesce(error, '')"), c2_read $(res "$MON" c2_read "status || ' ' || coalesce(value::text, '') || ' ' || coalesce(error, '')")"
ok "C S: after a check that set CONTEXT_INFO, SESSION_CONTEXT, a session applock, LOCK_TIMEOUT 5 and USE pgvp_app, the next check read none of it (its own connection: 2000 and master)"
[[ $(res "$MON" w_insert "status") == error && $(res "$MON" w_insert "error") == *"INSERT permission was denied"* ]] || fail "W: w_insert $(res "$MON" w_insert "status || ' ' || coalesce(error, '')")"
[[ $(sq "SELECT COUNT(*) FROM dbo.target" pgvp_app) == 0 ]] || fail "W: pgvp_app.dbo.target holds a row"
[[ $(res "$MON" w_commit "status") == error && $(res "$MON" w_commit "error") == *"ended the transaction it ran in"* ]] || fail "W: w_commit $(res "$MON" w_commit "status || ' ' || coalesce(error, '')")"
TR=$(res "$MON" w_trace "error")
[[ $(res "$MON" w_trace "status") == error && $TR == *"made trace "*"pgv_st6_$SUF"* && $TR == *"pgvigil leaves it as it is"* ]] || fail "W: w_trace $(res "$MON" w_trace "status || ' ' || coalesce(error, '')")"
TID=$(sq "SELECT id FROM sys.traces WHERE path LIKE N'%pgv_st6_$SUF%'")
[[ -n $TID ]] || fail "W: the trace w_trace made is not there (pgvigil must leave it)"
sq "EXEC sp_trace_setstatus $TID, 0; EXEC sp_trace_setstatus $TID, 2;" >/dev/null
[[ $(res "$MON" w_slow "status") == error && $(res "$MON" w_slow "error") == *"did not finish within 30 s"* ]] || fail "W: w_slow $(res "$MON" w_slow "status || ' ' || coalesce(error, '')")"
ok "W: an INSERT the login may not make, a COMMIT inside the check, a trace (trace $TID left in place, closed here as sa) and a 35 s wait are each the check's error in words; pgvp_app.dbo.target holds no row"
[[ $(res "$MON" x_rows "row_count || ' ' || jsonb_array_length(rows) || ' ' || note") == "101 100 the first 100 of 101 rows kept" ]] || fail "X: x_rows $(res "$MON" x_rows "row_count || ' ' || coalesce(note, '') || ' ' || coalesce(error, '')")"
[[ $(res "$MON" x_cols "jsonb_array_length(columns)") == 50 && $(res "$MON" x_cols "note") == *"the first 50 of 51 columns kept"* ]] || fail "X: x_cols $(res "$MON" x_cols "coalesce(note, '') || ' ' || coalesce(error, '')")"
CL=$(res "$MON" x_cell "length(rows->0->>0)")
[[ $CL =~ ^[0-9]+$ ]] && (( CL == 1000 )) || fail "X: x_cell's kept cell is $CL characters"
[[ $(res "$MON" x_dec "value") == 12.5 && $(res "$MON" x_money "value") == 7.25 && $(res "$MON" x_bit "value") == 1 ]] || fail "X: the number types: decimal $(res "$MON" x_dec "value"), money $(res "$MON" x_money "value"), bit $(res "$MON" x_bit "value")"
[[ $(res "$MON" x_text "error") == *"nvarchar column is not a number"* ]] || fail "X: x_text $(res "$MON" x_text "status || ' ' || coalesce(error, '')")"
[[ $(res "$MON" x_sets "note") == *"the first of 2 result sets read"* && $(res "$MON" x_sets "value") == 1 ]] || fail "X: x_sets $(res "$MON" x_sets "coalesce(note, '') || ' ' || coalesce(error, '')")"
ok "X: 101 rows -> 100 kept, 51 columns -> 50, a 2,000-character cell kept at $CL, decimal 12.5, money 7.25, bit 1, a text value column refused in words, a second result set noted"
[[ $(q "select count(*) from pgvigil.custom_checks c join pgvigil.instances i using (instance_id) where i.engine = 'sqlserver' and c.check_name = 'pg_only'") == 0 ]] || fail "E: the PostgreSQL check pg_only is listed on a SQL Server instance"
ok "E: the PostgreSQL check pg_only is on no SQL Server instance"

echo "--- F: the fence, one login at a time"
for pair in "sa|role sysadmin" "ctl|CONTROL SERVER" "conn|ALTER ANY CONNECTION" "imp|IMPERSONATE on login sa" "bulk|ADMINISTER BULK OPERATIONS" "dw|in database pgvp_app DELETE, INSERT, UPDATE"; do
  k=${pair%%|*}; want=${pair#*|}; inst=st6-$k-$SUF
  [[ $k == bulk && -z $BULK_OK ]] && continue
  collect "$inst"
  st=$(q "select status || '|' || coalesce(note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = '$inst' and d.collection = 'mssql_custom'")
  [[ ${st%%|*} == error && $st == *"custom checks refused on this instance"*"$want"* ]] || fail "F: $k: $st; $(tail -2 "$OUT")"
  [[ $(q "select count(*) from pgvigil.custom_results r join pgvigil.instances i using (instance_id) where i.name = '$inst'") == 0 ]] || fail "F: $k: a check ran"
done
ok "F: refused by name, no check run: a sysadmin, CONTROL SERVER, ALTER ANY CONNECTION, IMPERSONATE on sa, bulkadmin, and db_datawriter in pgvp_app"

echo "--- R: the store and the page's read"
[[ $(q "select count(*) from pgvigil.custom_report() where engine = 'sqlserver' and instance = '$MON'") -ge 20 ]] || fail "R: custom_report(): $(q "select count(*) from pgvigil.custom_report() where engine = 'sqlserver'") SQL Server rows"
MID=$(iid "$MON")
[[ $(q "select count(*) from pgvigil.custom_findings where instance_id = $MID and setting = 'custom check v_dbs' and severity = 'warning'") == 1 ]] || fail "R: v_dbs's finding"
[[ $(q "select count(*) from pgvigil.custom_findings where instance_id = $MID and value = '(error)' and suggested = 'a T-SQL batch or procedure that runs as the read login, in a transaction rolled back'") -ge 4 ]] \
  || fail "R: the error findings: $(q "select string_agg(setting || ': ' || suggested, ' | ') from pgvigil.custom_findings where instance_id = $MID and value = '(error)'")"
PORT=$(freeport 23500 23599) || fail "no free port for serve"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.5; done
curl -sf -o "$WORK/api.json" "http://127.0.0.1:$PORT/api/custom?instance=$MID&w=1h" || fail "R: GET /api/custom: $(tail -2 "$WORK/serve.log")"
python3 - "$WORK/api.json" <<'PY' || fail "R: the API's answer"
import json, sys
d = json.load(open(sys.argv[1]))
def rows(t):
    if not t: return []
    return [dict(zip(t['columns'], r)) for r in t['rows']] if isinstance(t, dict) and 'columns' in t else t
eng = rows(d.get('instance'))
names = {r['check_name'] for r in rows(d.get('checks'))}
assert eng and eng[0].get('engine') == 'sqlserver', eng
assert {'v_dbs', 'p_secret', 'w_trace', 'x_rows'} <= names, sorted(names)
print('  the API: instance engine sqlserver,', len(names), 'checks')
PY
ok "R: custom_report() lists the SQL Server checks with engine sqlserver; custom_findings holds v_dbs's warning and the errors in the SQL Server words; GET /api/custom answers the checks and the engine"

echo "--- L: the two fences of the DBA's own SQL (go test, live)"
if command -v go >/dev/null; then
  ( cd "$ROOT" && PGVIGIL_ST6_MON_DSN=$MS_MON PGVIGIL_ST6_EXTRA_DSN=$MS_CONN PGVIGIL_ST6_SA_DSN=$MS_SA go test ./internal/web/ -run 'TestST6FencesLive' -count=1 -v 2>&1 | grep -E '^(=== RUN|--- |ok|FAIL|PASS)|fence_live_test' ) > "$WORK/l.out" || true
  cat "$WORK/l.out"
  grep -q -- '--- PASS: TestST6FencesLive' "$WORK/l.out" || fail "L: TestST6FencesLive did not pass"
  ok "L: custom reports refuse ALTER ANY CONNECTION and a sysadmin and run as the documented login; community tools let ALTER ANY CONNECTION in and refuse a sysadmin"
else
  echo "NOT RUN L: go is not on this machine"
fi
echo "PROOF OK: SQL Server custom checks ($PV)"
