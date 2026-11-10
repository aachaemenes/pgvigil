#!/usr/bin/env bash
# Proof of the SQL Server base (migration 0063, internal/mssql, internal/engines): an instance can be a SQL Server,
# its own collection runs on it as a least-privilege login and nothing of the other engine does.
#
# Needs: docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox) reachable from this
# machine on PGVIGIL_MSSQL_ADDR (default localhost:1433), its sa password in MSSQL_SA_PASSWORD, psql, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# The proof makes its own repository database, two SQL Server logins (random suffix, random passwords) and a user for
# one of them in msdb, and drops them at the end; part E changes one server configuration value ('remote login
# timeout (s)', by one second) and puts the old value back, on every exit path.
#
# Expected (written before the first run):
#  A. as the login with VIEW SERVER STATE, VIEW ANY DEFINITION and db_datareader in msdb: `collect -once
#     mssql_instance` prints a row count of 2 + the number of rows sa counts in sys.configurations and no "partial";
#     pgvigil.instances holds the instance with engine sqlserver, platform sqlserver, server_version_num = major *
#     10000 + minor of sa's ProductVersion; mssql_instance holds sa's ProductVersion, Edition and ServerName,
#     sysinfo_read true, cpu_count = sa's, started_at within 90 seconds of sa's start time in UTC; mssql_config holds
#     as many rows as sa counts, 'max server memory (MB)' with sa's value_in_use; collection_dates says ok.
#  B. the other engine stays out, both ways: `collect -once databases` on the SQL Server instance prints "skipped: a
#     postgres collection" and stores no collection_dates row for it; `collect -once mssql_instance` on a PostgreSQL
#     instance of the same file prints "skipped: a sqlserver collection" and creates no mssql_instance row for it; a
#     config whose SQL Server instance disables a PostgreSQL collection is refused before any connection; so is a
#     sqlserver dsn with an inline password.
#  C. a login WITHOUT VIEW SERVER STATE: the run prints "partial" naming sys.dm_os_sys_info, collection_dates says
#     partial with that note, mssql_instance.sysinfo_read is false with cpu_count NULL, and mssql_config is stored in
#     full (the part any login may read).
#  D. a name is one engine: ensure_instance of the SQL Server instance's name as 'postgres' raises "already stored as
#     engine sqlserver".
#  E. a configuration change is kept: after sa raises 'remote login timeout (s)' by one, the next collection stores
#     the new value_in_use with previous_in_use = the old one and changed_at = that collection's time; the rows whose
#     value did not change keep changed_at NULL.
#  F. NOT PROVEN HERE: that a collector session never waits behind a writer (the base has no collection that reads a
#     user table); the session settings are asserted by text in a unit test (TestSessionSetup).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_mssqlproof_$SUF
L1=pgv_mon_$SUF; L2=pgv_bare_$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw)
CFG=$(mktemp); OUT=$(mktemp); BAD=$(mktemp); OLD_RLT=
fail() { echo "FAIL: $*" >&2; exit 1; }
sq() { docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
cleanup() {
  rc=$?
  if [ -n "$OLD_RLT" ]; then sq "EXEC sp_configure 'remote login timeout (s)', $OLD_RLT; RECONFIGURE;" >/dev/null 2>&1 || echo "CLEANUP: 'remote login timeout (s)' was NOT put back to $OLD_RLT" >&2; fi
  sq "IF USER_ID('$L1') IS NOT NULL DROP USER [$L1];" msdb >/dev/null 2>&1 || echo "CLEANUP: msdb user $L1 not dropped" >&2
  for l in "$L1" "$L2"; do
    sq "IF SUSER_ID('$l') IS NOT NULL DROP LOGIN [$l];" >/dev/null 2>&1 || echo "CLEANUP: login $l not dropped" >&2
  done
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2
  rm -f "$CFG" "$OUT" "$BAD"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
sq "CREATE LOGIN [$L1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];
    CREATE LOGIN [$L2] WITH PASSWORD = '$P2', CHECK_POLICY = OFF;"
sq "CREATE USER [$L1] FOR LOGIN [$L1]; ALTER ROLE db_datareader ADD MEMBER [$L1];" msdb
export MSSQL_MON_DSN="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_BARE_DSN="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export PG_MON_DSN="$ADMIN_DSN"
N1=proof-mssql-$SUF; N2=proof-mssql-bare-$SUF; NP=proof-pg-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N1
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
  - name: $N2
    engine: sqlserver
    dsn: env:MSSQL_BARE_DSN
  - name: $NP
    dsn: env:PG_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null

echo "--- A. mssql_instance as the least-privilege login"
IFS='|' read -r PV ED SN NCFG MAXMEM CPU START <<<"$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)), (SELECT COUNT(*) FROM sys.configurations), (SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'max server memory (MB)'), (SELECT cpu_count FROM sys.dm_os_sys_info), (SELECT CONVERT(varchar(19), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), sqlserver_start_time), 126) FROM sys.dm_os_sys_info)")"
echo "  sa reads: $PV | $ED | $SN | $NCFG configuration rows | max memory $MAXMEM | $CPU cpus | started $START UTC"
[ -n "$PV" ] && [ "$NCFG" -gt 50 ] || fail "A: sa's own read came back empty"
"$BIN" collect -config "$CFG" -once mssql_instance -instance "$N1" | tee "$OUT"
grep -q "^$N1 mssql_instance: $((NCFG + 2)) row(s)" "$OUT" || fail "A: the run's row count (want $((NCFG + 2)))"
if grep -q "partial" "$OUT"; then fail "A: the run says partial"; fi
iid=$(q "select instance_id from pgvigil.instances where name='$N1'")
maj=${PV%%.*}; rest=${PV#*.}; min=${rest%%.*}
[ "$(q "select engine || '|' || platform || '|' || server_version_num from pgvigil.instances where instance_id=$iid")" = "sqlserver|sqlserver|$((maj * 10000 + 10#$min))" ] \
  || fail "A: the instance row: $(q "select engine, platform, server_version_num from pgvigil.instances where instance_id=$iid")"
[ "$(q "select product_version || '|' || edition || '|' || server_name || '|' || sysinfo_read || '|' || cpu_count from pgvigil.mssql_instance where instance_id=$iid")" \
  = "$PV|$ED|$SN|true|$CPU" ] || fail "A: mssql_instance: $(q "select product_version, edition, server_name, sysinfo_read, cpu_count from pgvigil.mssql_instance where instance_id=$iid")"
[ "$(q "select abs(extract(epoch from started_at - '${START}Z'::timestamptz)) < 90 from pgvigil.mssql_instance where instance_id=$iid")" = t ] || fail "A: started_at"
[ "$(q "select count(*) from pgvigil.mssql_config where instance_id=$iid")" = "$NCFG" ] || fail "A: configuration row count"
[ "$(q "select value_in_use from pgvigil.mssql_config where instance_id=$iid and name='max server memory (MB)'")" = "$MAXMEM" ] || fail "A: max server memory"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='mssql_instance'")" = ok ] || fail "A: collection_dates"
echo "A: OK"

echo "--- B. the other engine stays out"
"$BIN" collect -config "$CFG" -once databases -instance "$N1" | tee "$OUT"
grep -q "skipped: a postgres collection" "$OUT" || fail "B: a PostgreSQL collection on the SQL Server instance was not skipped"
[ "$(q "select count(*) from pgvigil.collection_dates where instance_id=$iid and collection='databases'")" = 0 ] || fail "B: a databases row for the SQL Server instance"
"$BIN" collect -config "$CFG" -once mssql_instance -instance "$NP" | tee "$OUT"
grep -q "skipped: a sqlserver collection" "$OUT" || fail "B: a SQL Server collection on the PostgreSQL instance was not skipped"
[ "$(q "select count(*) from pgvigil.mssql_instance m join pgvigil.instances i using (instance_id) where i.name='$NP'")" = 0 ] || fail "B: an mssql_instance row for the PostgreSQL instance"
sed "s/^    dsn: env:MSSQL_MON_DSN/    dsn: env:MSSQL_MON_DSN\n    disabled: [databases]/" "$CFG" > "$BAD"
if "$BIN" collect -config "$BAD" -once mssql_instance >"$OUT" 2>&1; then fail "B: a PostgreSQL collection disabled on a SQL Server instance was accepted"; fi
grep -q "is a postgres collection" "$OUT" || { cat "$OUT"; fail "B: the refusal's text"; }
sed "s|^    dsn: env:MSSQL_MON_DSN|    dsn: sqlserver://someone:secret@localhost:1433|" "$CFG" > "$BAD"
if "$BIN" collect -config "$BAD" -once mssql_instance >"$OUT" 2>&1; then fail "B: an inline password was accepted"; fi
grep -q "must come through env:NAME or file:/path" "$OUT" || { cat "$OUT"; fail "B: the inline-password refusal's text"; }
echo "B: OK"

echo "--- C. a login without VIEW SERVER STATE"
"$BIN" collect -config "$CFG" -once mssql_instance -instance "$N2" | tee "$OUT"
grep -q "partial: sys.dm_os_sys_info" "$OUT" || fail "C: the run does not say partial"
bid=$(q "select instance_id from pgvigil.instances where name='$N2'")
[ "$(q "select status || '|' || (note like 'sys.dm_os_sys_info:%VIEW SERVER STATE%') from pgvigil.collection_dates where instance_id=$bid and collection='mssql_instance'")" = "partial|true" ] \
  || fail "C: collection_dates: $(q "select status, note from pgvigil.collection_dates where instance_id=$bid")"
[ "$(q "select sysinfo_read || '|' || (cpu_count is null) || '|' || product_version from pgvigil.mssql_instance where instance_id=$bid")" = "false|true|$PV" ] || fail "C: mssql_instance"
[ "$(q "select count(*) from pgvigil.mssql_config where instance_id=$bid")" = "$NCFG" ] || fail "C: configuration row count"
echo "C: OK"

echo "--- D. a name is one engine"
if q "select pgvigil.ensure_instance('$N1', 'onprem', 'x', 170000, false, '{}')" >"$OUT" 2>&1; then fail "D: the name was accepted as postgres"; fi
grep -q "already stored as engine sqlserver" "$OUT" || { cat "$OUT"; fail "D: the refusal's text"; }
echo "D: OK"

echo "--- E. a configuration change is kept"
OLD_RLT=$(sq "SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'remote login timeout (s)'")
[ "$(q "select count(*) from pgvigil.mssql_config where instance_id=$iid and changed_at is not null")" = 0 ] || fail "E: a change before any change"
sq "EXEC sp_configure 'remote login timeout (s)', $((OLD_RLT + 1)); RECONFIGURE;" >/dev/null
"$BIN" collect -config "$CFG" -once mssql_instance -instance "$N1" >/dev/null || fail "E: collect"
[ "$(q "select value_in_use || '|' || previous_in_use || '|' || (changed_at = snapshot_at) from pgvigil.mssql_config where instance_id=$iid and name='remote login timeout (s)'")" \
  = "$((OLD_RLT + 1))|$OLD_RLT|true" ] || fail "E: the changed row: $(q "select value_in_use, previous_in_use, changed_at, snapshot_at from pgvigil.mssql_config where instance_id=$iid and name='remote login timeout (s)'")"
[ "$(q "select count(*) from pgvigil.mssql_config where instance_id=$iid and changed_at is not null")" = 1 ] || fail "E: more than one row marked changed"
sq "EXEC sp_configure 'remote login timeout (s)', $OLD_RLT; RECONFIGURE;" >/dev/null
[ "$(sq "SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'remote login timeout (s)'")" = "$OLD_RLT" ] || fail "E: the value was not put back"
OLD_RLT=
echo "E: OK"

echo "F: NOT PROVEN (no collection of the base reads a user table; the session settings are asserted by TestSessionSetup)"
echo "proof-mssql-base: PASS (A-E)"
