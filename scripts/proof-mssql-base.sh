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
#     sqlserver dsn with an inline password, also one holding '='; versions_fleet, corruption_summary and
#     slow_sources (the views that list every PostgreSQL instance) hold no row for the SQL Server instance.
#  C. a login WITHOUT VIEW SERVER STATE: the run prints "partial" naming sys.dm_os_sys_info, collection_dates says
#     partial with that note, mssql_instance.sysinfo_read is false with cpu_count NULL, and mssql_config is stored in
#     full (the part any login may read).
#  D. a name is one engine: ensure_instance of the SQL Server instance's name as 'postgres' raises "already stored as
#     engine sqlserver"; and under a race (two sessions' first call for one new name, one per engine, the first
#     holding its transaction three seconds) the second raises the same text and one row exists, engine sqlserver.
#  E. a configuration change is kept: after sa raises 'remote login timeout (s)' by one, the next collection stores
#     the new value_in_use with previous_in_use = the old one and changed_at = that collection's time; the rows whose
#     value did not change keep changed_at NULL.
#  G. a configuration value the server no longer lists: after a read that carries one value only, that row is
#     present and every other row of the instance is marked not present with its last values kept; the next full
#     read marks them all present again.
#  H. the row contract of QueryRows against the server, as the monitoring login (TestQueryRowsLive): a GUID in its
#     canonical text, a varbinary, binary and rowversion as 0x hex, a decimal and money as number text, datetime /
#     datetime2 / smalldatetime / date / time as zone-less text with the clock value unchanged, a datetimeoffset as
#     the UTC instant, the session's own sql_handle as 0x hex. NOT RUN without a go toolchain.
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
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MADE_DB=; MADE_L1=; MADE_L2=; MADE_U1=
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
cleanup() {
  rc=$?
  if [ -n "$OLD_RLT" ]; then sq "EXEC sp_configure 'remote login timeout (s)', $OLD_RLT; RECONFIGURE;" >/dev/null 2>&1 || echo "CLEANUP: 'remote login timeout (s)' was NOT put back to $OLD_RLT" >&2; fi
  # only what THIS run created: a name that existed before the run (another run's, by a suffix collision) stays
  if [ -n "$MADE_U1" ]; then sq "IF USER_ID('$L1') IS NOT NULL DROP USER [$L1];" msdb >/dev/null 2>&1 || echo "CLEANUP: msdb user $L1 not dropped" >&2; fi
  if [ -n "$MADE_L1" ]; then sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; fi
  if [ -n "$MADE_L2" ]; then sq "IF SUSER_ID('$L2') IS NOT NULL DROP LOGIN [$L2];" >/dev/null 2>&1 || echo "CLEANUP: login $L2 not dropped" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -f "$CFG" "$OUT" "$BAD"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
sq "CREATE LOGIN [$L1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF;"; MADE_L1=1
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];"
sq "CREATE LOGIN [$L2] WITH PASSWORD = '$P2', CHECK_POLICY = OFF;"; MADE_L2=1
sq "CREATE USER [$L1] FOR LOGIN [$L1];" msdb; MADE_U1=1
sq "ALTER ROLE db_datareader ADD MEMBER [$L1];" msdb
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
awk '{ print } /^    dsn: env:MSSQL_MON_DSN/ { print "    disabled: [databases]" }' "$CFG" > "$BAD"
grep -q "disabled: \[databases\]" "$BAD" || fail "B: the bad config was not built"
if "$BIN" collect -config "$BAD" -once mssql_instance >"$OUT" 2>&1; then fail "B: a PostgreSQL collection disabled on a SQL Server instance was accepted"; fi
grep -q "is a postgres collection" "$OUT" || { cat "$OUT"; fail "B: the refusal's text"; }
for inline in "sqlserver://someone:secret@localhost:1433" "sqlserver://someone:se=cret@localhost:1433"; do
  sed "s|^    dsn: env:MSSQL_MON_DSN|    dsn: $inline|" "$CFG" > "$BAD"
  if "$BIN" collect -config "$BAD" -once mssql_instance >"$OUT" 2>&1; then fail "B: an inline password was accepted: $inline"; fi
  grep -q "must come through env:NAME or file:/path" "$OUT" || { cat "$OUT"; fail "B: the inline-password refusal's text"; }
done
[ "$(q "select count(*) from pgvigil.versions_fleet where instance_id=$iid")|$(q "select count(*) from pgvigil.corruption_summary where instance_id=$iid")|$(q "select count(*) from pgvigil.slow_sources where instance_id=$iid")" = "0|0|0" ] \
  || fail "B: the SQL Server instance is listed by a PostgreSQL fleet view (versions_fleet | corruption_summary | slow_sources)"
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
# the race: two sessions' FIRST call for one new name, one per engine. The first holds its insert open; the second
# has read "no such name" by then and waits on the unique index. After the commit exactly one row exists, under
# the first engine, and the second call raised instead of returning the other engine's instance_id.
NR=proof-race-$SUF
( psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "begin" -c "select pgvigil.ensure_instance('$NR', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')" -c "select pg_sleep(3)" -c "commit" >/dev/null ) &
RACE=$!
sleep 1
if q "select pgvigil.ensure_instance('$NR', 'onprem', 'x', 170000, false, '{}', 'postgres')" >"$OUT" 2>&1; then wait $RACE; cat "$OUT"; fail "D: the second engine's first call returned an instance id"; fi
wait $RACE || fail "D: the first session of the race failed"
grep -q "already stored as engine sqlserver" "$OUT" || { cat "$OUT"; fail "D: the race's refusal text"; }
[ "$(q "select count(*) || '|' || min(engine) from pgvigil.instances where name='$NR'")" = "1|sqlserver" ] || fail "D: the race left $(q "select count(*), min(engine) from pgvigil.instances where name='$NR'")"
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

echo "--- G. a value the server no longer lists is marked, not kept as current"
[ "$(q "select count(*) from pgvigil.mssql_config where instance_id=$iid and not is_present")" = 0 ] || fail "G: a row marked gone before anything went"
q "select pgvigil.import_mssql_instance($iid, now(), '[{\"kind\":\"server\",\"product_version\":\"$PV\"},{\"kind\":\"config\",\"name\":\"max server memory (MB)\",\"value\":$MAXMEM,\"value_in_use\":$MAXMEM}]'::jsonb)" >/dev/null
[ "$(q "select count(*) filter (where is_present) || '|' || count(*) filter (where not is_present) from pgvigil.mssql_config where instance_id=$iid")" = "1|$((NCFG - 1))" ] \
  || fail "G: after a one-value read: $(q "select count(*) filter (where is_present), count(*) filter (where not is_present) from pgvigil.mssql_config where instance_id=$iid")"
"$BIN" collect -config "$CFG" -once mssql_instance -instance "$N1" >/dev/null || fail "G: collect"
[ "$(q "select count(*) from pgvigil.mssql_config where instance_id=$iid and is_present")" = "$NCFG" ] || fail "G: the full read did not bring every row back"
echo "G: OK"

echo "--- H. the row contract against the server, as the monitoring login"
if command -v go >/dev/null 2>&1 && [ -f go.mod ]; then
  PGVIGIL_MSSQL_TEST_DSN="$MSSQL_MON_DSN" go test ./internal/mssql -run 'TestQueryRowsLive' -count=1 -v 2>&1 | tee "$OUT" | grep -E '^(--- |ok|FAIL|PASS)' || true
  grep -q -- "--- PASS: TestQueryRowsLive" "$OUT" || { cat "$OUT"; fail "H: the live contract test"; }
  echo "H: OK"
else
  echo "H: NOT RUN (no go toolchain or not at the repository root)"
fi

echo "F: NOT PROVEN (no collection of the base reads a user table; the session settings are asserted by TestSessionSetup)"
echo "proof-mssql-base: PASS (A-E, G, H)"
