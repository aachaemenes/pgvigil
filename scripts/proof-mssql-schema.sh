#!/usr/bin/env bash
# Proof of A26, SQL Server schema history (migration 0267; internal/mssql/schema.go; internal/web/q_schema.go; the
# collection mssql_schema) against a real SQL Server 2022 and a repository of its own.
#
# Needs: go (one binary is built into the temp folder, with scripts/a26-wiring.patch applied for the build and taken
# back; PGVIGIL_BIN names a built, wired one instead), psql, curl, jq, ss, docker.
# Makes, and removes on every exit path: a SQL Server container (MSSQL_IMAGE, default 2022-latest; a throwaway sa
# password never printed) with its logins and databases, and a postgres:18 repository container. Nothing outside them.
#
# Expected (written before the first run; the report's 'A26 core run EXPECTED' line):
#  R0. reads, printed: the default trace's ObjectType names (sys.trace_subclass_values, column 28) and whether
#      sp_rename raises an Object:Altered (164) in the default trace.
#  P1. an instance without mssql_schema: the collection 'skipped', 'off on this instance', no schema row of it.
#  P2. the first read is the baseline: shop's kinds (schema, table, column, constraint, trigger, view, procedure,
#      function, synonym, sequence, type; its first plain index is P3's) stored, no change; mssql_schema_dbs 'read'.
#  P7a. a database where the login is denied VIEW DEFINITION: 'not readable', no object, no change.
#  P8. a database of 10,001 tables: 'partial', not snapshotted; P8b: not tried again on the next pass (its partial_at
#      unchanged: the build review's S-2).
#  P3. after DDL and a default-trace read, ONE pass (no daily read due): CREATE TABLE -> added, who sa; ALTER TABLE
#      ADD COLUMN -> the column added; CREATE INDEX -> added; DROP TABLE -> dropped (one row); ALTER VIEW -> changed;
#      ALTER FUNCTION f_two -> changed with the body's before / after TEXT (query_text full); ALTER PROCEDURE p_key,
#      whose body names a password -> changed, its after its 'body sha256:' line and "body text not kept", never its
#      text or the password (the B+C review's B2); on an instance with query_text none the procedure's change shows
#      two 'body sha256:' lines; quiet (no DDL) kept present ('seen').
#  P4. a rolled-back ALTER TABLE: no change on the next pass.
#  P5. sp_rename: found (by the trace or a forced daily read), as R0 says.
#  P7b. a login without ALTER TRACE: the reader 'no right', no trace-driven read; on a26-full, DDL the reader stored and
#      then a reader row 20 minutes stale: not trusted, so no 'ddl' read (shop's read_at unchanged); in A the API's
#      trace part says trusted false for a26-notrace (the build review's S-6).
#  B1. a database dropped and another created on the same id: no 'dropped' row, the new one a baseline.
#  P6. a restore over shop: diffed, not a baseline (the table made after the backup 'dropped').
#  S10. a dropped database: its objects marked not present.
#  S9. a 2,000-procedure database's whole re-read: the collect's run time (the catalog read and the import, so the
#      import's own time is within it) and the repository's WAL printed against the lead's bound (15 s of 30 s;
#      100 MB), over = a note, never a FAIL.
#  A.  the API: /api/schema on the SQL Server instance has the trace, mssql_dbs and who parts; part=change gives
#      f_two's whole before / after text, and p_key's without its text or its password.
#  P11. /api/diff in databases mode (a = b, db_a shop, db_b reborn): a schema part comparing the two (Part C); in
#      snapshots mode (at_a before P3's DDL, db_a shop): mode 'snapshots', dbo.Gone in the schema part; the schema
#      findings' warning 'schema: an object dropped' for shop (the B+C review's S4).
#  The first line is 'containers: <SQL Server> <repository>' (a job that kills this script removes exactly those).
#  The last line is 'proof-mssql-schema: PASS (...)' and exit 0 only when every row holds.
#  NOT PROVEN HERE: a torn read (unit-tested), the 160 MB fall-back (unit-tested), 3,000 databases' baseline, the
#  Schema tab in a browser (proof-a11y at the join), SQL Server 2016 / 2019, Azure SQL Database.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d /tmp/pgv-a26-XXXXXX)
N=$RANDOM; CT=a26ms_$N; RC=a26repo_$N; CFG=$WORK/pgvigil.yaml; OUT=$WORK/out
echo "containers: $CT $RC"
MADE_CT=; MADE_RC=; SRV_PID=; UNWIRE=0
fail() { echo "FAIL $*"; exit 1; }
ok() { echo "ok   $*"; }
eq() { [ "$2" = "$3" ] || fail "$1: got '$2', want '$3'"; }
pw() { head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20; echo 'a1!'; }
freeport() { local used; used=$(ss -Hltn); for p in $(seq "$1" "$2"); do grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " <<<"$used" || { echo "$p"; return; }; done; return 1; }
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
sq() { timeout 600 docker exec -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
cleanup() {
  rc=$?
  [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null || true; }
  [ -n "$MADE_CT" ] && { docker rm -f -v "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2; }
  [ -n "$MADE_RC" ] && { docker rm -f -v "$RC" >/dev/null 2>&1 || echo "CLEANUP: container $RC not removed" >&2; }
  [ "$UNWIRE" = 1 ] && { (cd "$ROOT" && git apply -R scripts/a26-wiring.patch) || echo "CLEANUP: the wiring patch was not taken back" >&2; }
  rm -rf "$WORK" || true
  echo "cleanup: containers $CT $RC $(docker ps -aq --filter "name=^($CT|$RC)\$" | grep -q . && echo LEFT || echo removed)"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  if ! grep -q 'MSSQLSchema \*MSSQLSchema' "$ROOT/internal/config/config.go"; then
    (cd "$ROOT" && git apply scripts/a26-wiring.patch) || fail "scripts/a26-wiring.patch does not apply"; UNWIRE=1; echo "  wiring: a26-wiring.patch applied for the build"
  fi
  BIN=$WORK/pgvigil; (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"
  [ "$UNWIRE" = 1 ] && { (cd "$ROOT" && git apply -R scripts/a26-wiring.patch) || fail "the wiring patch was not taken back"; UNWIRE=0; }
fi
echo "  the machine's load: $(cut -d' ' -f1-3 /proc/loadavg)"

echo "--- the repository (postgres:18, its own container)"
RPW=$(pw); RP=$(freeport 27432 27499) || fail "no free port for the repository"
MADE_RC=1; docker run -d --name "$RC" -e POSTGRES_PASSWORD="$RPW" -p "127.0.0.1:$RP:5432" postgres:18 -c max_connections=200 >/dev/null || fail "docker run postgres:18"
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$RP user=postgres password=$RPW dbname=postgres"
for _ in $(seq 1 60); do psql "$PGVIGIL_REPO_DSN" -XAtqc "select 1" >/dev/null 2>&1 && break; sleep 1; done
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- the SQL Server"
MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MPORT=$(freeport 22433 22499) || fail "no free port for the SQL Server"
MADE_CT=1; docker run -d --name "$CT" --memory 4g -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run of the SQL Server"
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server does not answer"
echo "  $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))")"
PF=$(pw); PT=$(pw)
sq "CREATE LOGIN a26full WITH PASSWORD = '$PF', CHECK_POLICY = OFF; CREATE LOGIN a26notrace WITH PASSWORD = '$PT', CHECK_POLICY = OFF;
    GRANT VIEW ANY DEFINITION, CONNECT ANY DATABASE, VIEW SERVER STATE, ALTER TRACE TO a26full;
    GRANT VIEW ANY DEFINITION, CONNECT ANY DATABASE, VIEW SERVER STATE TO a26notrace;" >/dev/null || fail "the logins"
sq "CREATE USER a26full FOR LOGIN a26full; CREATE USER a26notrace FOR LOGIN a26notrace;
    GRANT SELECT ON dbo.restorehistory TO a26full; GRANT SELECT ON dbo.restorehistory TO a26notrace;" msdb >/dev/null || fail "msdb's users"
for d in shop quiet locked gone1 big mid; do sq "CREATE DATABASE [$d]" >/dev/null || fail "create $d"; done
sq "CREATE USER a26full FOR LOGIN a26full; DENY VIEW DEFINITION TO a26full;" locked >/dev/null || fail "the DENY in locked"
sq "CREATE TABLE dbo.t (a int);" locked >/dev/null; sq "CREATE TABLE dbo.g (a int);" gone1 >/dev/null
sq "CREATE TABLE dbo.q (a int);" quiet >/dev/null
sq "DECLARE @i int = 0; WHILE @i < 10001 BEGIN EXEC (N'CREATE TABLE dbo.t' + CAST(@i AS nvarchar(10)) + N' (a int)'); SET @i += 1; END" big >/dev/null || fail "big's 10,001 tables"
sq "DECLARE @i int = 0, @b nvarchar(max) = REPLICATE(CAST(N'-- filler line for the size of a real procedure body ' AS nvarchar(max)), 150);
    WHILE @i < 2000 BEGIN EXEC (N'CREATE PROCEDURE dbo.p' + CAST(@i AS nvarchar(10)) + N' AS BEGIN ' + @b + NCHAR(10) + N'SELECT 1; END'); SET @i += 1; END" mid >/dev/null || fail "mid's 2,000 procedures"
cat > "$WORK/shop.sql" <<'SQL'
CREATE SCHEMA app;
GO
CREATE TYPE dbo.code FROM nvarchar(10) NOT NULL;
CREATE SEQUENCE dbo.seq AS int START WITH 1 INCREMENT BY 1;
CREATE TABLE dbo.Customers (id int NOT NULL CONSTRAINT pk_customers PRIMARY KEY, name nvarchar(50) NULL);
CREATE TABLE dbo.Orders (id int IDENTITY(1,1) NOT NULL CONSTRAINT pk_orders PRIMARY KEY, d date NOT NULL CONSTRAINT df_orders_d DEFAULT (getdate()),
  customer int NULL CONSTRAINT fk_orders_customer REFERENCES dbo.Customers (id), qty int NULL CONSTRAINT ck_orders_qty CHECK (qty > 0));
CREATE TABLE dbo.Gone (a int);
CREATE TABLE app.Orders (a int);
GO
CREATE VIEW dbo.v_orders AS SELECT id, d FROM dbo.Orders;
GO
CREATE PROCEDURE dbo.p_key AS BEGIN OPEN SYMMETRIC KEY k DECRYPTION BY PASSWORD = 'S3cretOne'; SELECT 1 AS one; END
GO
CREATE FUNCTION dbo.f_two() RETURNS int AS BEGIN RETURN 2; END
GO
CREATE TRIGGER dbo.trg_orders ON dbo.Orders AFTER INSERT AS BEGIN SET NOCOUNT ON; END
GO
CREATE SYNONYM dbo.syn_orders FOR dbo.Orders;
GO
SQL
docker exec -i -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -C -b -I -U sa -d shop -i /dev/stdin < "$WORK/shop.sql" >/dev/null || fail "shop's objects"

ms() { echo "sqlserver://$1:$2@127.0.0.1:$MPORT?database=master&encrypt=true&TrustServerCertificate=true"; }
export MS_FULL; MS_FULL=$(ms a26full "$PF"); export MS_NT; MS_NT=$(ms a26notrace "$PT")
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: a26-full\n    engine: sqlserver\n    dsn: env:MS_FULL\n    mssql_schema:\n      databases: ["*", "-mid"]\n'
  printf '  - name: a26-hash\n    engine: sqlserver\n    dsn: env:MS_FULL\n    query_text: none\n    mssql_schema:\n      databases: ["shop"]\n'
  printf '  - name: a26-notrace\n    engine: sqlserver\n    dsn: env:MS_NT\n    mssql_schema:\n      databases: ["shop"]\n'
  printf '  - name: a26-off\n    engine: sqlserver\n    dsn: env:MS_FULL\n'
  printf '  - name: a26-mid\n    engine: sqlserver\n    dsn: env:MS_FULL\n    mssql_schema:\n      databases: ["mid"]\n'
} > "$CFG"
"$BIN" migrate -config "$CFG" > "$OUT" 2>&1 || { tail -5 "$OUT"; fail "migrate"; }
eq "the newest migration" "$(q "select max(version) from pgvigil.schema_version")" "0267_mssql_schema.sql"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { tail -5 "$OUT" >&2; fail "collect $1 on $2"; }; }
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
dbid() { sq "SELECT database_id FROM sys.databases WHERE name = N'$1'"; }
status() { q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id = $(iid "$1") and collection = '$2'"; }
mstate() { q "select state from pgvigil.mssql_schema_dbs where instance_id = $(iid "$1") and database_id = $(dbid "$2")"; }
changes() { q "select coalesce(string_agg(change || ' ' || kind || ' ' || identity, ', ' order by change, kind, identity), '') from pgvigil.schema_changes where instance_id = $(iid "$1") and dbid = $(dbid "$2") and snapshot_at = (select max(snapshot_at) from pgvigil.schema_changes where instance_id = $(iid "$1") and dbid = $(dbid "$2"))"; }
nchanges() { q "select count(*) from pgvigil.schema_changes where instance_id = $(iid "$1") and dbid = $(dbid "$2")"; }
pass() { collect mssql_defaulttrace "$1"; collect mssql_schema "$1"; }

echo "--- R0. reads"
echo "  the default trace's ObjectType names: $(sq "SELECT STRING_AGG(subclass_name, ',') WITHIN GROUP (ORDER BY subclass_name) FROM (SELECT DISTINCT subclass_name FROM sys.trace_subclass_values WHERE trace_column_id = 28) x" | cut -c1-600)"

echo "--- P1. no key: off"
collect mssql_schema a26-off
case "$(status a26-off mssql_schema)" in "skipped off on this instance"*) ;; *) fail "P1: a26-off's mssql_schema is '$(status a26-off mssql_schema)'" ;; esac
eq "P1: schema rows of a26-off" "$(q "select count(*) from pgvigil.schema_databases where instance_id = $(iid a26-off)")" 0
ok "P1 off: skipped, nothing read"

echo "--- P2 / P7a / P8. the baseline"
pass a26-full; pass a26-hash; pass a26-notrace
eq "P2: shop's state" "$(mstate a26-full shop)" read
eq "P2: changes at the baseline" "$(nchanges a26-full shop)" 0
KINDS=$(q "select string_agg(distinct kind, ',' order by kind) from pgvigil.schema_objects where instance_id = $(iid a26-full) and dbid = $(dbid shop) and is_present")
eq "P2: shop's kinds" "$KINDS" "column,constraint,function,procedure,schema,sequence,synonym,table,trigger,type,view"
[ -n "$(q "select read_at from pgvigil.mssql_schema_dbs where instance_id = $(iid a26-full) and database_id = $(dbid shop)")" ] || fail "P2: no read_at"
eq "P7a: locked's state" "$(mstate a26-full locked)" "not readable"
eq "P7a: locked's objects" "$(q "select count(*) from pgvigil.schema_objects where instance_id = $(iid a26-full) and dbid = $(dbid locked)")" 0
eq "P8: big's state" "$(mstate a26-full big)" partial
eq "P8: big's objects" "$(q "select count(*) from pgvigil.schema_objects where instance_id = $(iid a26-full) and dbid = $(dbid big)")" 0
[ -z "$(q "select 1 from pgvigil.mssql_schema_dbs where instance_id = $(iid a26-full) and database_id = $(dbid mid)")" ] || fail "P2: mid read though '-mid' leaves it out"
PA8=$(q "select partial_at from pgvigil.mssql_schema_dbs where instance_id = $(iid a26-full) and database_id = $(dbid big)")
[ -n "$PA8" ] || fail "P8: big's partial_at is empty"
ok "P2 baseline: 11 kinds in shop (its first plain index comes in P3), no change; P7a locked not readable; P8 big partial; -mid left out"
sleep 1; TP2=$(date -u +%FT%TZ); sleep 1

echo "--- P3. DDL, one pass"
sq "CREATE TABLE dbo.NewT (a int); ALTER TABLE dbo.Orders ADD note nvarchar(20) NULL; CREATE INDEX ix_orders_d ON dbo.Orders (d); DROP TABLE dbo.Gone;" shop >/dev/null || fail "P3's DDL"
sq "EXEC (N'ALTER VIEW dbo.v_orders AS SELECT id, d, note FROM dbo.Orders'); EXEC (N'ALTER PROCEDURE dbo.p_key AS BEGIN OPEN SYMMETRIC KEY k DECRYPTION BY PASSWORD = ''S3cretTwo''; SELECT 2 AS two; END'); EXEC (N'ALTER FUNCTION dbo.f_two() RETURNS int AS BEGIN RETURN 3; END');" shop >/dev/null || fail "P3's ALTERs"
pass a26-full; pass a26-hash
eq "P3: the changes" "$(changes a26-full shop)" "added column dbo.Orders.note, added index ix_orders_d on dbo.Orders, added table dbo.NewT, changed function dbo.f_two, changed procedure dbo.p_key, changed view dbo.v_orders, dropped table dbo.Gone"
WHO=$(q "select coalesce(who_login, '<none>') || ' ' || who_n from pgvigil.mssql_schema_changes_window($(iid a26-full), now() - interval '1 hour', now(), $(dbid shop)) where identity = 'dbo.NewT'")
eq "P3: who created dbo.NewT" "$WHO" "sa 1"
AFTER=$(q "select after from pgvigil.schema_changes where instance_id = $(iid a26-full) and dbid = $(dbid shop) and identity = 'dbo.p_key' and attribute = 'definition' order by snapshot_at desc limit 1")
grep -qF "body text not kept: it names a password or a secret" <<<"$AFTER" && grep -qF "body sha256:" <<<"$AFTER" \
  || fail "P3: the procedure naming a password is not its sha line and the words: $(head -c 200 <<<"$AFTER")"
grep -qF "S3cretTwo" <<<"$AFTER" && fail "P3: the password is in the stored text"
grep -qF "SELECT 2 AS two" <<<"$AFTER" && fail "P3: the text of a body naming a password is stored"
FAFTER=$(q "select after from pgvigil.schema_changes where instance_id = $(iid a26-full) and dbid = $(dbid shop) and identity = 'dbo.f_two' and attribute = 'definition' order by snapshot_at desc limit 1")
grep -qF "RETURN 3" <<<"$FAFTER" || fail "P3: f_two's after is not its text under full: $(head -c 200 <<<"$FAFTER")"
HAFTER=$(q "select after from pgvigil.schema_changes where instance_id = $(iid a26-hash) and dbid = $(dbid shop) and identity = 'dbo.p_key' order by snapshot_at desc limit 1")
grep -q "body sha256:" <<<"$HAFTER" && ! grep -q "SELECT 2" <<<"$HAFTER" || fail "P3: under query_text none the procedure's after is not its sha line: $(head -c 200 <<<"$HAFTER")"
eq "P3: quiet kept present" "$(q "select is_present from pgvigil.schema_databases where instance_id = $(iid a26-full) and dbid = $(dbid quiet)")" t
eq "P8b: big's partial_at after P3's pass" "$(q "select partial_at from pgvigil.mssql_schema_dbs where instance_id = $(iid a26-full) and database_id = $(dbid big)")" "$PA8"
eq "P8b: big's state after P3's pass" "$(mstate a26-full big)" partial
ok "P3 one pass: 7 changes, the who sa, f_two's text under full, p_key (a password) as its sha line and the words, its sha under none, quiet kept; P8b big not tried again"

echo "--- P4. a rolled-back ALTER"
N4=$(nchanges a26-full shop)
sq "BEGIN TRAN; ALTER TABLE dbo.Customers ADD x int NULL; ROLLBACK;" shop >/dev/null || fail "P4's rolled-back ALTER"
pass a26-full
eq "P4: changes after a rollback" "$(nchanges a26-full shop)" "$N4"
ok "P4 rollback: nothing"

echo "--- P5. sp_rename"
sq "EXEC sp_rename N'dbo.NewT', N'NewT2';" shop >/dev/null || fail "P5's sp_rename"
collect mssql_defaulttrace a26-full
R164=$(q "select count(*) from pgvigil.mssql_trace_events where instance_id = $(iid a26-full) and kind = 'ddl' and database_name = 'shop' and object_name in ('NewT', 'NewT2') and sub = 'alter'")
echo "  the default trace's alter rows on NewT / NewT2 after sp_rename: $R164"
collect mssql_schema a26-full
if [ "$(changes a26-full shop)" != "added table dbo.NewT2, dropped table dbo.NewT" ]; then
  q "update pgvigil.mssql_schema_dbs set read_at = read_at - interval '2 days' where instance_id = $(iid a26-full) and database_id = $(dbid shop)" >/dev/null
  collect mssql_schema a26-full; HOW="the daily read (forced)"
else HOW="the trace"; fi
eq "P5: sp_rename found" "$(changes a26-full shop)" "added table dbo.NewT2, dropped table dbo.NewT"
ok "P5 sp_rename: found by $HOW"

echo "--- P7b. no ALTER TRACE"
N7=$(nchanges a26-notrace shop)
collect mssql_defaulttrace a26-notrace; collect mssql_schema a26-notrace
eq "P7b: the reader's state" "$(q "select state from pgvigil.mssql_reader_state where instance_id = $(iid a26-notrace) and reader = 'defaulttrace'")" "no right"
eq "P7b: no trace-driven read" "$(nchanges a26-notrace shop)" "$N7"
RA=$(q "select read_at from pgvigil.mssql_schema_dbs where instance_id = $(iid a26-full) and database_id = $(dbid shop)")
sq "CREATE TABLE dbo.P7bT (a int);" shop >/dev/null || fail "P7b's DDL"
collect mssql_defaulttrace a26-full
eq "P7b: the reader stored the DDL" "$(q "select count(*) > 0 from pgvigil.mssql_trace_events where instance_id = $(iid a26-full) and kind = 'ddl' and database_name = 'shop' and object_name = 'P7bT'")" t
q "update pgvigil.mssql_reader_state set snapshot_at = snapshot_at - interval '20 minutes' where instance_id = $(iid a26-full) and reader = 'defaulttrace'" >/dev/null
q "delete from pgvigil.mssql_schema_trace_gaps where instance_id = $(iid a26-full)" >/dev/null
collect mssql_schema a26-full
eq "P7b: shop's read_at after a pass on a stale reader" "$(q "select read_at from pgvigil.mssql_schema_dbs where instance_id = $(iid a26-full) and database_id = $(dbid shop)")" "$RA"
ok "P7b no ALTER TRACE: the reader 'no right', no trace-driven read; a stale reader's stored DDL not trusted (no read)"

echo "--- B1. another database on a reused id"
OLD=$(dbid gone1); pass a26-full
sq "DROP DATABASE gone1; CREATE DATABASE reborn;" >/dev/null || fail "B1's drop and create"
NEW=$(dbid reborn); sq "CREATE TABLE dbo.r (a int);" reborn >/dev/null
pass a26-full
if [ "$OLD" = "$NEW" ]; then
  eq "B1: dropped rows on the reused id" "$(q "select count(*) from pgvigil.schema_changes where instance_id = $(iid a26-full) and dbid = $NEW and change = 'dropped'")" 0
  eq "B1: reborn's object" "$(q "select string_agg(identity, ',') from pgvigil.schema_objects where instance_id = $(iid a26-full) and dbid = $NEW and is_present and kind = 'table'")" "dbo.r"
  ok "B1 reused id $NEW: a new baseline, no false drop"; B1W=B1
else echo "NOT PROVEN B1: the server gave reborn id $NEW, not gone1's $OLD"; B1W="B1 NOT PROVEN"; fi

echo "--- P6. a restore over shop"
sq "BACKUP DATABASE shop TO DISK = N'/var/opt/mssql/data/shop_a26.bak' WITH INIT;" >/dev/null || fail "P6's backup"
sq "CREATE TABLE dbo.AfterBackup (a int);" shop >/dev/null
pass a26-full
eq "P6: the table after the backup" "$(changes a26-full shop)" "added table dbo.AfterBackup"
sq "RESTORE DATABASE shop FROM DISK = N'/var/opt/mssql/data/shop_a26.bak' WITH REPLACE;" >/dev/null || fail "P6's restore"
pass a26-full
eq "P6: after the restore" "$(changes a26-full shop)" "dropped table dbo.AfterBackup"
ok "P6 restore: diffed (the table made after the backup dropped), not a baseline"

echo "--- S10. a dropped database"
sq "DROP DATABASE quiet;" >/dev/null; QID=$(q "select dbid from pgvigil.schema_databases where instance_id = $(iid a26-full) and datname = 'quiet'")
pass a26-full
eq "S10: quiet's objects present" "$(q "select count(*) from pgvigil.schema_objects where instance_id = $(iid a26-full) and dbid = $QID and is_present")" 0
ok "S10: a dropped database's objects marked gone"

echo "--- S9. a 2,000-procedure database's whole re-read"
collect mssql_defaulttrace a26-mid; collect mssql_schema a26-mid
sq "EXEC (N'ALTER PROCEDURE dbo.p7 AS BEGIN SELECT 7; END');" mid >/dev/null
collect mssql_defaulttrace a26-mid
W0=$(q "select pg_current_wal_lsn()"); T0=$(date +%s.%N)
collect mssql_schema a26-mid
T1=$(date +%s.%N); WAL=$(q "select pg_wal_lsn_diff(pg_current_wal_lsn(), '$W0')::bigint / 1048576")
SECS=$(python3 -c "print(round($T1 - $T0, 1))")
eq "S9: the re-read found the procedure" "$(changes a26-mid mid)" "changed procedure dbo.p7"
NOTE=""; python3 -c "import sys; sys.exit(0 if $SECS <= 15 else 1)" || NOTE=" - OVER 15 s: the lead's upsert WHERE"; [ "$WAL" -le 100 ] || NOTE="$NOTE - OVER 100 MB of WAL: the lead's upsert WHERE"
ok "S9 mid (2,000 procedures): the whole re-read in ${SECS} s (the import within it), ${WAL} MB of the repository's WAL$NOTE"

echo "--- A. the API"
PORT=$(freeport 18690 18720) || fail "A: no free port"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
API="http://127.0.0.1:$PORT/api/schema?instance=$(iid a26-full)&from=$(date -u -d '-3 hours' +%FT%TZ)&to=$(date -u -d '+5 minutes' +%FT%TZ)"
curl -fs "$API" > "$WORK/a.json" || fail "A: GET /api/schema: $(tail -3 "$WORK/serve.log")"
jq -e '.trace and .mssql_dbs and .changes' "$WORK/a.json" >/dev/null || fail "A: the SQL Server parts are missing: $(head -c 300 "$WORK/a.json")"
CH=$(q "select to_char(snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') from pgvigil.schema_changes where instance_id = $(iid a26-full) and identity = 'dbo.p_key' and attribute = 'definition' order by snapshot_at desc limit 1")
curl -fs "http://127.0.0.1:$PORT/api/schema?instance=$(iid a26-full)&db=$(dbid shop)&kind=procedure&identity=dbo.p_key&attribute=definition&change_at=$CH&part=change" > "$WORK/c.json" || fail "A: part=change"
grep -qF "body text not kept" "$WORK/c.json" && ! grep -qF "S3cretTwo" "$WORK/c.json" && ! grep -qF "SELECT 2 AS two" "$WORK/c.json" \
  || fail "A: p_key's part=change holds its text or its password: $(head -c 300 "$WORK/c.json")"
CHF=$(q "select to_char(snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') from pgvigil.schema_changes where instance_id = $(iid a26-full) and identity = 'dbo.f_two' and attribute = 'definition' order by snapshot_at desc limit 1")
curl -fs "http://127.0.0.1:$PORT/api/schema?instance=$(iid a26-full)&db=$(dbid shop)&kind=function&identity=dbo.f_two&attribute=definition&change_at=$CHF&part=change" > "$WORK/f.json" || fail "A: part=change of f_two"
grep -qF "RETURN 2" "$WORK/f.json" && grep -qF "RETURN 3" "$WORK/f.json" || fail "A: f_two's part=change is not its whole before / after text: $(head -c 300 "$WORK/f.json")"
curl -fs "http://127.0.0.1:$PORT/api/schema?instance=$(iid a26-notrace)&from=$(date -u -d '-3 hours' +%FT%TZ)&to=$(date -u -d '+5 minutes' +%FT%TZ)" > "$WORK/nt.json" || fail "A: GET /api/schema for a26-notrace"
eq "A: a26-notrace's trace trusted" "$(jq -r '(.trace.columns | index("trusted")) as $i | .trace.rows[0][$i]' "$WORK/nt.json")" false
ok "A API: the trace, mssql_dbs and changes parts; part=change gives f_two's whole text, p_key's without its text or password; a26-notrace's trace not trusted"

echo "--- P11. the Diff page's schema compare on SQL Server (Part C)"
curl -fs "http://127.0.0.1:$PORT/api/diff?a=$(iid a26-full)&b=$(iid a26-full)&db_a=shop&db_b=reborn" > "$WORK/d.json" || fail "P11: GET /api/diff: $(tail -3 "$WORK/serve.log")"
jq -e '.schema' "$WORK/d.json" >/dev/null || fail "P11: no schema part on SQL Server: $(head -c 300 "$WORK/d.json")"
grep -qF '"dbo.r"' "$WORK/d.json" && grep -qF '"dbo.Orders"' "$WORK/d.json" || fail "P11: the two databases' objects are not compared: $(head -c 300 "$WORK/d.json")"
curl -fs "http://127.0.0.1:$PORT/api/diff?a=$(iid a26-full)&b=$(iid a26-full)&at_a=$TP2&db_a=shop" > "$WORK/t.json" || fail "P11: GET /api/diff at two times: $(tail -3 "$WORK/serve.log")"
eq "P11: the two-dates mode" "$(jq -r '(.meta.columns | index("mode")) as $i | .meta.rows[0][$i]' "$WORK/t.json")" snapshots
grep -qF '"dbo.Gone"' "$WORK/t.json" || fail "P11: dbo.Gone (dropped after $TP2) is not in the two-dates compare: $(head -c 300 "$WORK/t.json")"
eq "P11: the schema findings' drop warning for shop" "$(q "select count(*) from pgvigil.schema_findings where instance_id = $(iid a26-full) and setting = 'schema: an object dropped' and value = 'shop'")" 1
ok "P11 the Diff page: shop and reborn compared by their schema objects on SQL Server; shop at two times (dbo.Gone); the drop warning in the findings"

echo "NOT PROVEN: a torn read and the 160 MB fall-back (unit-tested), 3,000 databases' baseline, the Schema tab in a browser (proof-a11y at the join), SQL Server 2016 / 2019, Azure SQL Database"
echo "proof-mssql-schema: PASS (R0, P1, P2, P7a, P8, P8b, P3, P4, P5, P7b, $B1W, P6, S10, S9, A, P11)"
