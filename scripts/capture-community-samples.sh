#!/usr/bin/env bash
# capture-community-samples.sh - the demo's stored samples of the community tools (internal/demo/community/samples).
#
# Builds two test servers for the capture and nothing else - a SQL Server 2022 container and a PostgreSQL cluster of its
# own (initdb on a free port; never a shared cluster: another job's databases, paths and statements would be stored) -
# loaded with the demo's own invented names (SQL Server: the database Sales with dbo.Customer, Orders, OrderLine, Stock
# and AuditLog, the logins orders_app and stock_job, as internal/demo/mssql_*_demo.go name them; PostgreSQL: the
# database erp with schema_demo.go's tables items, order_lines and user_sessions and the function order_total, the
# roles app_erp, app_readonly and erp_deploy), and makes on them what each tool reads: a workload, Query Store on, a
# deadlock, a blocking chain with a sleeping head held while the tools that read running sessions run, the blocked
# process threshold at 5 s with the keeper_HumanEvents_blocking session a DBA makes with sp_HumanEvents, the error
# log's lines, duplicate, unused and invalid indexes, a sequence at 80 % of its range, settings changed, an idle in
# transaction holder and a prepared transaction. Then pgvigil serve (the UI login on) runs every tool once through
# POST /api/community/run with the parameters written below - the page's own run path, its answer kept as it came -
# and the procedures' forms through POST /api/community/params; the pack command (internal/demo/community/pack)
# scrubs and stores them, and the package's tests check them with this machine's own names denied.
#
# Box only (docker, a PostgreSQL install with initdb, go, psql, curl, python3, ss). Nothing here is part of a proof.
#   PGVIGIL_ADMIN_DSN      a superuser of a PostgreSQL server for the throwaway repository database (keyword form)
#   PGVIGIL_COMMUNITY_DIR  the kits: frk-install-all.sql, darlingdata.sql, sp_WhoIsActive.sql (installed in master)
#   PGVIGIL_BIN            the pgvigil binary (default: built from this tree)
#   PGVIGIL_SAMPLE_RAW     a folder to keep the raw answers in (default: removed with the temp folder)
#   PGVIGIL_SAMPLE_DENY    more words no sample may hold, comma-separated (this machine's host name and cloud project
#                          are added here by themselves)
# Expected: one line 'capt <tool>: done, <sets> sets, <rows> rows' per tool (23), the pack's line per file and its
# total under 1 MB, the package's tests ok, and the last line 'capture: 23 samples, <bytes> bytes, deny 0'; exit 0.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
: "${PGVIGIL_ADMIN_DSN:?PGVIGIL_ADMIN_DSN (a superuser, keyword form) is required}"
: "${PGVIGIL_COMMUNITY_DIR:?PGVIGIL_COMMUNITY_DIR (the kits) is required}"
CDIR=$(realpath "$PGVIGIL_COMMUNITY_DIR")
N=$RANDOM$RANDOM
WORK=$(mktemp -d)
RAW=${PGVIGIL_SAMPLE_RAW:-$WORK/raw}; mkdir -p "$RAW"; RAW=$(realpath "$RAW")
# the raw answers and meta.json hold this machine's own names: never inside the repository unless git ignores them
case "$RAW/" in "$ROOT"/*) git -C "$ROOT" check-ignore -q "$RAW" 2>/dev/null || { echo "FAIL: PGVIGIL_SAMPLE_RAW is inside the repository and not ignored: keep the raw answers outside it" >&2; exit 1; };; esac
REPO=capt_repo_$N; CT=capt-mssql-$N
PGD=$WORK/pgdata; SOCK=$WORK/sock; mkdir -p "$SOCK"
SRV=""; MADE_CT=""; PGUP=""; HOLD=()
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  for p in "${HOLD[@]}" "$SRV"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [[ -n "$MADE_CT" ]] && docker rm -f -v "$CT" >/dev/null 2>&1 || true
  [[ -n "$PGUP" ]] && "$PGCTL" -D "$PGD" -m immediate stop >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in docker psql curl python3 ss go; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for f in frk-install-all.sql darlingdata.sql sp_WhoIsActive.sql; do [[ -r "$CDIR/$f" ]] || fail "$CDIR/$f is missing"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 12000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}
pw() { echo "$1$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!a1"; }

# ---- the kits' versions, from their own source (the sample line says them) ----------------------------------------
grep -q "SELECT @Version = '8.34', @VersionDate = '20260702'" "$CDIR/frk-install-all.sql" || fail "the First Responder Kit is not 8.34 (2026-07-02): the table below names it"
grep -q 'Who Is Active? v2200.20260409' "$CDIR/sp_WhoIsActive.sql" || fail "sp_WhoIsActive is not v2200.20260409"
darling_version() {   # a DarlingData procedure's @version from its own ALTER PROCEDURE block
  awk -v p="dbo.$1" '$0 ~ "CREATE PROCEDURE " p " AS" {on=1} on && /@version = '\''/ {gsub(/[^0-9.]/, "", $3); print $3; exit}' "$CDIR/darlingdata.sql"
}
declare -A DV
for p in sp_PressureDetector sp_QuickieStore sp_HumanEventsBlockViewer sp_HealthParser sp_LogHunter sp_IndexCleanup; do
  DV[$p]=$(darling_version "$p"); [[ -n ${DV[$p]} ]] || fail "no @version for $p in darlingdata.sql"
done
grep -q "@version_date = '20261101'" "$CDIR/darlingdata.sql" || fail "DarlingData is not the 2026-11-01 release"

# ---- the binary ---------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$(realpath "$PGVIGIL_BIN"); else
  BIN=$WORK/pgvigil; CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil || fail "go build"
fi

# ---- SQL Server 2022 ----------------------------------------------------------------------------------------------
echo "--- SQL Server: the container (host name testsql01)"
MSSQL_SA_PASSWORD=$(pw Sa); export MSSQL_SA_PASSWORD; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
APW=$(pw Ap); RPW=$(pw Rd)
MPORT=$(freeport); ADDR=127.0.0.1:$MPORT
MADE_CT=1
docker run -d --name "$CT" --hostname testsql01 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_PID=Developer \
  -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run"
CID=$(docker inspect -f '{{.Id}}' "$CT")
sq() {   # sq <sql> [database] [login] [password]
  local o
  o=$(docker exec -e SQLCMDPASSWORD="${4:-$MSSQL_SA_PASSWORD}" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' \
      -U "${3:-sa}" -d "${2:-master}" -Q "SET NOCOUNT ON; $1" 2>&1) || { printf 'sqlcmd failed: %s\n' "$o" >&2; return 1; }
  [ -z "$o" ] || printf '%s\n' "$o"
}
sqf() {   # a script file as sa in master
  local o
  o=$(docker exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -d master -i /dev/stdin < "$1" 2>&1) \
    || { printf 'sqlcmd failed on %s: %s\n' "$1" "$(printf '%s' "$o" | tail -5)" >&2; return 1; }
}
sqbg() {   # sqbg <login> <database> <sql>: a session in the background (its pid kept), output dropped
  docker exec -e SQLCMDPASSWORD="$APW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -I -U "$1" -d "$2" -Q "SET NOCOUNT ON; $3" >/dev/null 2>&1 &
  HOLD+=($!)
}
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server does not answer"
MSV=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))")
[[ $MSV == 16.* ]] || fail "the image is not SQL Server 2022 (ProductVersion $MSV)"
MS_SERVER="SQL Server 2022 $MSV"
echo "ok   $MS_SERVER"
for f in frk-install-all.sql darlingdata.sql sp_WhoIsActive.sql; do sqf "$CDIR/$f" || fail "$f did not install"; done
echo "ok   the kits installed in master"

sq "CREATE DATABASE Sales;
    ALTER DATABASE Sales SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1, DATA_FLUSH_INTERVAL_SECONDS = 60);" >/dev/null
sq "CREATE TABLE dbo.Customer (customer_id int IDENTITY PRIMARY KEY, name nvarchar(100) NOT NULL, region varchar(20) NOT NULL, created datetime2 NOT NULL DEFAULT sysutcdatetime());
    CREATE TABLE dbo.Orders (order_id int IDENTITY PRIMARY KEY, customer_id int NOT NULL REFERENCES dbo.Customer, ordered datetime2 NOT NULL, total decimal(12,2) NOT NULL, status varchar(20) NOT NULL);
    CREATE TABLE dbo.Stock (stock_id int IDENTITY PRIMARY KEY, sku varchar(20) NOT NULL, qty int NOT NULL);
    CREATE TABLE dbo.OrderLine (line_id int IDENTITY PRIMARY KEY, order_id int NOT NULL REFERENCES dbo.Orders, stock_id int NOT NULL REFERENCES dbo.Stock, qty int NOT NULL, amount decimal(12,2) NOT NULL);
    CREATE TABLE dbo.AuditLog (log_id bigint IDENTITY PRIMARY KEY, logged datetime2 NOT NULL, what nvarchar(200) NOT NULL);
    WITH n AS (SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT dbo.Customer (name, region) SELECT CONCAT(N'Customer ', i), CHOOSE(1 + i % 4, 'west', 'east', 'north', 'south') FROM n;
    INSERT dbo.Stock (sku, qty) SELECT TOP (500) CONCAT('SKU-', ROW_NUMBER() OVER (ORDER BY (SELECT NULL))), 100 FROM sys.all_objects a CROSS JOIN sys.all_objects b;
    WITH n AS (SELECT TOP (50000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT dbo.Orders (customer_id, ordered, total, status) SELECT 1 + ABS(CHECKSUM(NEWID())) % 2000, DATEADD(minute, -(ABS(CHECKSUM(NEWID())) % 100000), sysutcdatetime()), ABS(CHECKSUM(NEWID())) % 100000 / 100.0, CHOOSE(1 + i % 3, 'open', 'shipped', 'closed') FROM n;
    INSERT dbo.OrderLine (order_id, stock_id, qty, amount) SELECT TOP (150000) 1 + ABS(CHECKSUM(NEWID())) % 50000, 1 + ABS(CHECKSUM(NEWID())) % 500, 1 + ABS(CHECKSUM(NEWID())) % 5, ABS(CHECKSUM(NEWID())) % 10000 / 100.0 FROM sys.all_objects a CROSS JOIN sys.all_objects b;
    INSERT dbo.AuditLog (logged, what) SELECT TOP (20000) DATEADD(minute, -(ABS(CHECKSUM(NEWID())) % 200000), sysutcdatetime()), N'order changed' FROM sys.all_objects a CROSS JOIN sys.all_objects b;
    CREATE INDEX IX_Orders_customer ON dbo.Orders (customer_id);
    CREATE INDEX IX_Orders_customer_2 ON dbo.Orders (customer_id);
    CREATE INDEX IX_Orders_customer_ordered ON dbo.Orders (customer_id, ordered);
    CREATE INDEX IX_AuditLog_what ON dbo.AuditLog (what);" Sales >/dev/null
sq "EXEC (N'CREATE PROCEDURE dbo.usp_SearchOrders @text nvarchar(50), @top int AS
      SELECT TOP (@top) o.order_id, c.name, o.total FROM dbo.Orders o JOIN dbo.Customer c ON c.customer_id = o.customer_id
       WHERE c.name LIKE N''%'' + @text + N''%'' ORDER BY o.ordered DESC');" Sales >/dev/null
for l in orders_app stock_job; do
  sq "CREATE LOGIN $l WITH PASSWORD = '$APW', CHECK_POLICY = OFF;" >/dev/null
  sq "CREATE USER $l FOR LOGIN $l; ALTER ROLE db_datareader ADD MEMBER $l; ALTER ROLE db_datawriter ADD MEMBER $l; GRANT EXECUTE TO $l;" Sales >/dev/null
done
# pgvigil's read login as docs/sqlserver.md and docs/customreports.md describe it: the server's read rights, a user in
# master with EXECUTE on the kits and on xp_readerrorlog, msdb's reader, a reader in Sales
sq "CREATE LOGIN pgvigil_read WITH PASSWORD = '$RPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE TO pgvigil_read;" >/dev/null
sq "CREATE USER pgvigil_read FOR LOGIN pgvigil_read; GRANT EXECUTE ON sys.xp_readerrorlog TO pgvigil_read;
    DECLARE @s nvarchar(max) = N''; SELECT @s += N'GRANT EXECUTE ON dbo.' + QUOTENAME(name) + N' TO pgvigil_read; ' FROM sys.procedures WHERE is_ms_shipped = 0 AND schema_id = 1; EXEC (@s);" >/dev/null
sq "CREATE USER pgvigil_read FOR LOGIN pgvigil_read; ALTER ROLE db_datareader ADD MEMBER pgvigil_read;" msdb >/dev/null
sq "CREATE USER pgvigil_read FOR LOGIN pgvigil_read; ALTER ROLE db_datareader ADD MEMBER pgvigil_read;" Sales >/dev/null
# the blocked process report at 5 s and the session a DBA's script makes (sp_HumanEvents' keeper session); deadlocks into
# the error log too (trace flag 1222), as many servers run
sq "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'blocked process threshold (s)', 5; RECONFIGURE; DBCC TRACEON (1222, -1) WITH NO_INFOMSGS;" >/dev/null
sq "EXEC dbo.sp_HumanEvents @event_type = N'blocking', @keep_alive = 1;" >/dev/null 2>&1 || true
[[ $(sq "SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name = N'keeper_HumanEvents_blocking'") == 1 ]] || fail "sp_HumanEvents made no running keeper_HumanEvents_blocking session"
echo "ok   Sales, the logins, Query Store, the threshold 5 s, keeper_HumanEvents_blocking running"

echo "--- SQL Server: a deadlock, the workload, the error log"
# the workload first, alone (with -b, and its last line the passes it made: all 200 or the capture stops), then the
# deadlock: run beside it, the workload's own scan queued behind the deadlock's row and it was the victim
WL=$(docker exec -e SQLCMDPASSWORD="$APW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -h -1 -W -U orders_app -d Sales -Q "SET NOCOUNT ON;
  DECLARE @i int = 0; WHILE @i < 200 BEGIN
    EXEC dbo.usp_SearchOrders @text = N'1', @top = 100;
    SELECT c.region, COUNT(*) AS orders, SUM(o.total) AS total FROM dbo.Orders o JOIN dbo.Customer c ON c.customer_id = o.customer_id WHERE o.ordered >= DATEADD(day, -30, sysutcdatetime()) GROUP BY c.region;
    SELECT TOP (50) ol.order_id, SUM(ol.amount) AS amount FROM dbo.OrderLine ol WHERE ol.stock_id = 1 + @i % 500 GROUP BY ol.order_id ORDER BY 2 DESC;
    UPDATE dbo.Orders SET status = 'shipped' WHERE order_id = 1 + (@i * 7) % 50000;
    INSERT dbo.AuditLog (logged, what) VALUES (sysutcdatetime(), N'order changed');
    SET @i += 1;
  END;
  SELECT CONCAT('workload passes ', @i);" 2>&1 | tail -3) || fail "the workload: $WL"
grep -q '^workload passes 200$' <<<"$WL" || fail "the workload did not make its 200 passes: $(printf '%s' "$WL" | tail -3)"
sqbg orders_app Sales "BEGIN TRAN; UPDATE dbo.Stock SET qty = qty - 1 WHERE stock_id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.OrderLine SET qty = qty WHERE line_id = 1; COMMIT;"
sqbg stock_job Sales "BEGIN TRAN; UPDATE dbo.OrderLine SET qty = qty WHERE line_id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.Stock SET qty = qty + 1 WHERE stock_id = 1; COMMIT;"
sq "RAISERROR (N'Sales: the nightly stock job failed: 3 orders were not shipped', 16, 1) WITH LOG; RAISERROR (N'Sales: a backup of Sales_archive has not run for 8 days', 10, 1) WITH LOG;" >/dev/null 2>&1 || true
sq "EXEC sys.sp_query_store_flush_db;" Sales >/dev/null
for _ in $(seq 1 90); do
  [[ $(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) WHERE object_name = N'xml_deadlock_report'") -ge 1 ]] && break; sleep 2
done
[[ $(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL) WHERE object_name = N'xml_deadlock_report'") -ge 1 ]] || fail "system_health holds no deadlock after 180 s"
echo "ok   a deadlock in system_health, the workload ran, Query Store flushed"

# ---- PostgreSQL: a cluster of its own ------------------------------------------------------------------------------
echo "--- PostgreSQL: a cluster of its own"
INITDB=$(command -v initdb || ls /usr/lib/postgresql/*/bin/initdb 2>/dev/null | sort -V | tail -1)
[[ -x "$INITDB" ]] || fail "initdb is not on this machine"
PGCTL=$(dirname "$INITDB")/pg_ctl; PP=$(freeport)
"$INITDB" -D "$PGD" -U postgres --auth-local=trust --auth-host=scram-sha-256 >"$WORK/initdb.log" 2>&1 || fail "initdb: $(tail -3 "$WORK/initdb.log")"
"$PGCTL" -D "$PGD" -o "-p $PP -k $SOCK -c listen_addresses=localhost -c shared_preload_libraries=pg_stat_statements -c max_prepared_transactions=5 -c work_mem=16MB -c random_page_cost=1.1 -c log_min_duration_statement=1000 -c track_io_timing=on -c shared_buffers=64MB" \
  -l "$WORK/pg.log" -w start >/dev/null || fail "the cluster did not start: $(tail -3 "$WORK/pg.log")"
PGUP=1
SU="host=$SOCK port=$PP user=postgres"
pq() { psql "$SU dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
PGV=$(pq "show server_version"); PG_SERVER="PostgreSQL ${PGV%% *}"
echo "ok   $PG_SERVER"
PPW=$(pw Pg)
pq "create role app_erp login; create role app_readonly; create role erp_deploy login; create role pgvigil_read login password '$PPW' in role pg_monitor" >/dev/null
pq "create database erp owner app_erp" >/dev/null
psql "$SU dbname=erp" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
create extension pg_stat_statements;
set role app_erp;
create table items (id bigint generated always as identity primary key, created_at timestamptz not null default now(), sku text not null, name text not null, price numeric(12,2) not null);
create table order_lines (id bigint generated always as identity primary key, created_at timestamptz not null default now(), item_id bigint not null references items, amount numeric(14,2) not null default 0, status text not null default 'open');
create table user_sessions (id bigint generated always as identity primary key, created_at timestamptz not null default now(), user_name text not null, last_seen timestamptz) with (autovacuum_enabled = false);
create function order_total(bigint) returns numeric language sql stable as $$ select sum(amount) from order_lines where id = $1 $$;
insert into items (sku, name, price) select 'SKU-' || g, 'item ' || g, (g % 500) + 0.99 from generate_series(1, 5000) g;
insert into order_lines (item_id, amount, status, created_at) select 1 + g % 5000, (g % 10000) / 100.0, (array['open', 'shipped', 'closed'])[1 + g % 3], now() - (g || ' minutes')::interval from generate_series(1, 200000) g;
insert into user_sessions (user_name, last_seen) select 'user' || (g % 300), now() - (g || ' seconds')::interval from generate_series(1, 50000) g;
create index items_sku_idx on items (sku);
create index items_sku_idx1 on items (sku);
create index order_lines_item_idx on order_lines (item_id);
create index user_sessions_last_seen_idx on user_sessions (last_seen);
create sequence invoice_no_seq as integer;
select setval('invoice_no_seq', 1717986918);
delete from user_sessions where id % 5 = 0;
grant select on all tables in schema public to app_readonly;
grant select, update on items, order_lines to erp_deploy;
grant select on sequence invoice_no_seq to pgvigil_read;
reset role;
analyze items;
analyze order_lines;
alter database erp set statement_timeout = '30s';
alter system set shared_buffers = '128MB';
select pg_reload_conf();
SQL
# a unique index built concurrently over duplicates fails and is left invalid (the 'Invalid indexes' read)
psql "$SU dbname=erp" -XAtq -c "create unique index concurrently order_lines_status_key on order_lines (status)" >/dev/null 2>&1 || true
[[ $(pq "select count(*) from pg_index where not indisvalid" erp) == 1 ]] || fail "no invalid index was left"
# the workload (pg_stat_statements' statements), over the unix socket as the application
{
  for i in $(seq 1 40); do
    echo "select i.sku, sum(ol.amount) from order_lines ol join items i on i.id = ol.item_id where ol.status = 'open' group by i.sku order by 2 desc limit 20;"
    echo "select order_total(g) from generate_series($i, $((i + 200))) g;"
    for j in $(seq 1 10); do echo "update user_sessions set last_seen = now() where id = $((i * 10 + j));"; echo "select * from items where sku = 'SKU-$((i * j))';"; done
  done
} > "$WORK/workload.sql"
pq "select pg_stat_statements_reset()" erp >/dev/null   # Top statements: the workload's, not the load's
PGAPPNAME=erp-api psql "host=$SOCK port=$PP user=app_erp dbname=erp" -XAtq -f "$WORK/workload.sql" >/dev/null || fail "the PostgreSQL workload"
echo "ok   erp loaded (5,000 items, 200,000 order lines), the workload ran, an invalid index, a sequence at 80 %"

# ---- serve over the two test servers ---------------------------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null
export CAPT_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
export CAPT_MS_R="sqlserver://pgvigil_read:$RPW@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export CAPT_PG_R="host=localhost port=$PP dbname=erp user=pgvigil_read password=$PPW"
cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:CAPT_REPO_DSN
instances:
  - name: testsql01
    engine: sqlserver
    dsn: env:CAPT_MS_R
  - name: testpg01
    dsn: env:CAPT_PG_R
EOF
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" >"$WORK/migrate.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/migrate.log")"
"$BIN" collect -config "$CFG" -once activity >"$WORK/collect.log" 2>&1 || true
"$BIN" collect -config "$CFG" -once mssql_instance >>"$WORK/collect.log" 2>&1 || true
q() { psql "$CAPT_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
MSID=$(q "select instance_id from pgvigil.instances where name = 'testsql01'"); PGID=$(q "select instance_id from pgvigil.instances where name = 'testpg01'")
[[ -n $MSID && -n $PGID ]] || fail "the two instances are not registered: $(tail -5 "$WORK/collect.log")"
UIPW=$(pw Ui)
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" capture >/dev/null 2>&1 || fail "user add"
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >"$WORK/serve.log" 2>&1 & SRV=$!
for n in $(seq 1 60); do curl -sf -o /dev/null "$U/" && break; kill -0 "$SRV" 2>/dev/null || fail "serve died: $(tail -3 "$WORK/serve.log")"; [[ $n == 60 ]] && fail "serve did not answer"; sleep 0.5; done
JAR=$WORK/jar
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"capture\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
[[ -n $(awk '$6 == "pgvigil_session" {print $7}' "$JAR") ]] || fail "no session cookie"
post() { curl -s --max-time 90 -o "$2" -w '%{http_code}' -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$1" "$U/api/$3"; }
curl -s -b "$JAR" -o "$WORK/ms-tools.json" "$U/api/community?instance=$MSID"
curl -s -b "$JAR" -o "$WORK/pg-tools.json" "$U/api/community?instance=$PGID&database=erp"
python3 - "$WORK/ms-tools.json" "$WORK/pg-tools.json" <<'PY' || fail "a tool is not ready on the test servers"
import json, sys
for f in sys.argv[1:]:
    d = json.load(open(f))
    off = [f"{t['id']} ({t['state']}: {'; '.join(n['what'] for n in t['needs'] if n['hard'])})" for t in d['tools'] if not t['on'] and t['kind'] != 'script']
    if off or not d['enabled']:
        print('not ready:', d.get('reason', ''), off); sys.exit(1)
print('ok   every tool ready on both test servers')
PY

# capt <tool> <instance> <database> <params json>: the form, then the run; its answer kept. MARK (when set): words the
# rows must hold - the rig's own subject, so a sample shows what it was built for, never rows that are there either way;
# NOKIT (when set): no kit's own statement may be among the rows (a plan cache or Query Store read)
TOOLS_META=()
capt() {
  local tool=$1 inst=$2 db=$3 params=$4 code
  if [[ $inst == "$MSID" ]]; then
    code=$(post "{\"instance_id\":$inst,\"tool\":\"$tool\",\"database\":\"\"}" "$RAW/$tool.params.json" community/params)
    [[ $code == 200 ]] || fail "$tool: the form answered $code: $(head -c 300 "$RAW/$tool.params.json")"
  fi
  code=$(post "{\"instance_id\":$inst,\"tool\":\"$tool\",\"database\":\"$db\",\"params\":$params,\"timeout_secs\":60}" "$RAW/$tool.run.json" community/run)
  [[ $code == 200 ]] || fail "$tool: the run answered $code: $(head -c 300 "$RAW/$tool.run.json")"
  MARK=${MARK:-} NOKIT=${NOKIT:-} python3 - "$RAW/$tool.run.json" "$tool" <<'PY' || fail "$tool: the run did not end done with rows of its subject"
import json, os, re, sys
r = json.load(open(sys.argv[1]))['runs'][0]
rows = sum(len(s['rows']) for s in r['sets'])
text = json.dumps(r['sets'])
mark, nokit = os.environ['MARK'], os.environ['NOKIT']
miss = [m for m in mark.split('|') if m and m not in text]
kit = re.findall(r'#BlitzResults|#Recompile|#partdb|#BlitzWho|WhoIsActive|@VersionCheckMode|#ErrorLog|#deadlock_data', text) if nokit else []
print(f"capt {sys.argv[2]}: {r['outcome']}, {len(r['sets'])} sets, {rows} rows" + (f"; holds '{mark}'" if mark and not miss else '')
      + (f"; MISSING {miss}" if miss else '') + (f"; KIT CODE {sorted(set(kit))}" if kit else '') + ((': ' + r.get('error', '')[:200]) if r['outcome'] != 'done' else ''))
sys.exit(0 if r['outcome'] == 'done' and rows > 0 and not miss and not kit else 1)
PY
}

FRK='"kit":"First Responder Kit","version":"8.34","version_date":"2026-07-02","help":true'
dar() { echo "\"kit\":\"DarlingData\",\"version\":\"${DV[$1]}\",\"version_date\":\"2026-11-01\",\"help\":true"; }
WIA='"kit":"sp_WhoIsActive","version":"v2200.20260409","version_date":"2026-04-09","help":false'
ms() {   # ms <tool> <database> <params json> <kit fields> (MARK / NOKIT from the caller's environment)
  capt "$1" "$MSID" "$2" "$3"
  TOOLS_META+=("{\"tool\":\"$1\",\"engine\":\"sqlserver\",\"database\":\"${2:-master}\",\"params\":$3,$4}")
}
echo "--- SQL Server: the plan cache and Query Store of Sales, before any kit ran there (their rows are statements)"
MARK='usp_SearchOrders' NOKIT=1 ms sp_BlitzCache "" '{"@DatabaseName":"Sales"}' "$FRK"
MARK='Orders' NOKIT=1 ms sp_QuickieStore "" '{"@database_name":"Sales"}' "$(dar sp_QuickieStore)"
echo "--- SQL Server: the chain held (a sleeping head with an open transaction, two sessions waiting on it)"
mkfifo "$WORK/head.in"
docker exec -i -e SQLCMDPASSWORD="$APW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -I -U stock_job -d Sales < "$WORK/head.in" >/dev/null 2>&1 & HOLD+=($!)
exec 7>"$WORK/head.in"
printf 'BEGIN TRAN; UPDATE dbo.Stock SET qty = qty WHERE stock_id = 2;\nGO\n' >&7
sleep 2
sqbg orders_app Sales "UPDATE dbo.Stock SET qty = qty - 1 WHERE stock_id = 2;"
sqbg orders_app Sales "SELECT qty FROM dbo.Stock WITH (UPDLOCK) WHERE stock_id = 2;"
for _ in $(seq 1 30); do [[ $(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id > 0") -ge 2 ]] && break; sleep 1; done
[[ $(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id > 0") -ge 2 ]] || fail "the chain did not form"
sleep 20   # blocked process reports at 5, 10, 15 and 20 s into the keeper session
echo "ok   the chain is held"
MARK='LCK_M_|stock_job' NOKIT=1 ms sp_WhoIsActive "" '{"@find_block_leaders":"1"}' "$WIA"
MARK='stock_job' NOKIT=1 ms sp_BlitzWho "" '{}' "$FRK"
MARK='Stock' NOKIT=1 ms sp_HumanEventsBlockViewer "" '{}' "$(dar sp_HumanEventsBlockViewer)"
NOKIT=1 ms sp_PressureDetector "" '{}' "$(dar sp_PressureDetector)"
NOKIT=1 ms sp_BlitzFirst "" '{}' "$FRK"
exec 7>&-
sq "DECLARE @k nvarchar(max) = N''; SELECT @k += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; ' FROM sys.dm_exec_sessions WHERE login_name IN (N'orders_app', N'stock_job'); EXEC (@k);" >/dev/null 2>&1 || true
echo "ok   the chain released"
MARK='Sales' ms sp_Blitz "" '{"@CheckServerInfo":"1"}' "$FRK"
MARK='Unindexed Foreign Keys' ms sp_BlitzIndex "" '{"@DatabaseName":"Sales","@Mode":"4"}' "$FRK"
MARK='dbo.Stock|orders_app' NOKIT=1 ms sp_BlitzLock "" '{}' "$FRK"
MARK='deadlock' NOKIT=1 ms sp_HealthParser "" '{}' "$(dar sp_HealthParser)"
MARK='was killed by' ms sp_LogHunter "" '{}' "$(dar sp_LogHunter)"
MARK='IX_Orders_customer_2' ms sp_IndexCleanup "" '{"@database_name":"Sales"}' "$(dar sp_IndexCleanup)"

echo "--- PostgreSQL: an idle in transaction head, two sessions waiting on it, a prepared transaction"
mkfifo "$WORK/pghead.in"
PGAPPNAME=erp-api psql "host=$SOCK port=$PP user=app_erp dbname=erp" -XAtq < "$WORK/pghead.in" >/dev/null 2>&1 & HOLD+=($!)
exec 8>"$WORK/pghead.in"
printf "begin isolation level repeatable read;\nselect count(*) from items;\nupdate order_lines set status = 'held' where id = 1;\n" >&8
sleep 1
PGAPPNAME=erp-batch psql "host=$SOCK port=$PP user=erp_deploy dbname=erp" -XAtq -c "update order_lines set amount = amount + 1 where id = 1" >/dev/null 2>&1 & HOLD+=($!)
PGAPPNAME=erp-api psql "host=$SOCK port=$PP user=app_erp dbname=erp" -XAtq -c "update order_lines set status = 'open' where id = 1" >/dev/null 2>&1 & HOLD+=($!)
printf "begin;\nupdate items set price = price where id = 7;\nprepare transaction 'erp_batch_42';\n" | PGAPPNAME=erp-batch psql "host=$SOCK port=$PP user=erp_deploy dbname=erp" -XAtq -v ON_ERROR_STOP=1 >/dev/null || fail "the prepared transaction"
for _ in $(seq 1 30); do [[ $(pq "select count(*) from pg_stat_activity where wait_event_type = 'Lock'") -ge 2 ]] && break; sleep 1; done
[[ $(pq "select count(*) from pg_stat_activity where wait_event_type = 'Lock'") -ge 2 ]] || fail "the PostgreSQL chain did not form"
sleep 3
pg() {   # pg <tool> <params json>
  capt "$1" "$PGID" erp "$2"
  TOOLS_META+=("{\"tool\":\"$1\",\"engine\":\"postgres\",\"database\":\"erp\",\"params\":$2,\"kit\":\"pgvigil\",\"version\":\"own read\",\"version_date\":\"\",\"help\":false}")
}
MARK='idle in transaction' pg pg_running '{}'
MARK='head' pg pg_blocking '{}'
MARK='erp_batch_42' pg pg_xmin_horizon '{}'
MARK='order_lines|user_sessions' pg pg_top_statements '{}'
MARK='order_lines' pg pg_table_sizes '{}'
MARK='user_sessions_last_seen_idx' pg pg_unused_indexes '{}'
MARK='items_sku_idx1' pg pg_duplicate_indexes '{}'
MARK='order_lines_status_key' pg pg_invalid_indexes '{}'
MARK='max_prepared_transactions' pg pg_settings_changed '{}'
MARK='invoice_no_seq' pg pg_sequences '{}'
exec 8>&-
pq "rollback prepared 'erp_batch_42'" >/dev/null 2>&1 || true

# ---- meta, the pack, the tests ---------------------------------------------------------------------------------------
HOST=$(hostname); HOSTF=$(hostname -f 2>/dev/null || hostname)
PROJECT=$(curl -s --max-time 3 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id 2>/dev/null || true)
# on GCE the full host name carries the project (<host>.<zone>.c.<project>.internal): its name, or the capture stops
if [[ -z $PROJECT && $HOSTF == *.c.*.internal ]]; then PROJECT=${HOSTF#*.c.}; PROJECT=${PROJECT%.internal}; fi
[[ -n $PROJECT || $HOSTF != *.internal ]] || fail "this machine's cloud project could not be read: its name would not be denied"
DENY_ALL="$HOST,$HOSTF,${CID:0:12},$REPO${PROJECT:+,$PROJECT}${PGVIGIL_SAMPLE_DENY:+,$PGVIGIL_SAMPLE_DENY}"
TOOLS_JSON=$(IFS=,; echo "[${TOOLS_META[*]}]")
export M_MS="$MS_SERVER" M_PG="$PG_SERVER" M_TOOLS="$TOOLS_JSON" M_DENY="$DENY_ALL" M_PGD="$PGD" M_SOCK="$SOCK" M_WORK="$WORK" M_CID="$CID" M_CT="$CT" M_HOSTF="$HOSTF" M_HOST="$HOST" M_REPO="$REPO" M_ROOT="$ROOT"
python3 - "$RAW/meta.json" <<'PY'
import json, sys, datetime, os
e = os.environ
m = {
  "captured_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
  "servers": {"sqlserver": e['M_MS'], "postgres": e['M_PG']},
  "tools": json.loads(e['M_TOOLS']),
  "replace": [[e['M_PGD'], "/var/lib/postgresql/data"], [e['M_SOCK'], "/var/run/postgresql"], [e['M_WORK'], "/tmp/capture"],
              [e['M_CID'], "testsql01"], [e['M_CID'][:12], "testsql01"], [e['M_CT'], "testsql01"], [e['M_HOSTF'], "pgvigil-host"], [e['M_HOST'], "pgvigil-host"],
              [e['M_REPO'], "pgvigil"], [e['M_ROOT'], "/opt/pgvigil"]],
  "deny": [w for w in e['M_DENY'].split(",") if w.strip()],
}
json.dump(m, open(sys.argv[1], "w"), indent=1)
print(f"ok   meta: {len(m['tools'])} tools, {len(m['replace'])} replacements, {len(m['deny'])} denied words")
PY
go run ./internal/demo/community/pack -raw "$RAW" | tee "$WORK/pack.log" || fail "the pack"
PGVIGIL_SAMPLE_DENY="$DENY_ALL" go test -count=1 -v -run 'TestStoredSamples|TestDeny' ./internal/demo/community/ 2>&1 | tail -6
[[ ${PIPESTATUS[0]} == 0 ]] || fail "the package's tests"
n=$(ls internal/demo/community/samples/*.json.gz | wc -l); bytes=$(cat internal/demo/community/samples/*.json.gz | wc -c)
[[ $n == 23 ]] || fail "$n samples, 23 expected"
echo "capture: $n samples, $bytes bytes, deny 0"
