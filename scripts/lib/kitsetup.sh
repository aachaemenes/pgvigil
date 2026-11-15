# kitsetup.sh - the SQL Server state the community tools are run against, shared by capture-community-samples.sh and
# kitwatch.sh (sourced, never run). A tool's rows - and for some tools the shape of its answer - depend on what the
# server holds, so both scripts build the same state in the same order: a SQL Server container, the kits in master,
# the database Sales with the demo's invented names (internal/demo/mssql_*_demo.go), Query Store, the logins, pgvigil's
# read login as docs/sqlserver.md and docs/customreports.md describe it, the blocked process threshold at 5 s with the
# keeper_HumanEvents_blocking session a DBA makes with sp_HumanEvents, a workload, a deadlock, two error-log lines,
# duplicate indexes, and a blocking chain held while the tools that read running sessions run.
#
# The caller defines: fail <words>, pw <prefix> (a random password), freeport (a free TCP port), the array HOLD (the
# background pids its cleanup kills), WORK (its temp folder) and CT (the container's name), and removes the container
# in its cleanup when MADE_CT is set. MSSQL_IMAGE overrides the image. Nothing here writes outside the container but
# the fifo in WORK. The SA password stays in the environment (never on a command line, never echoed).
#
# A step that can fail sets KS_WHY (the reason, "" when it held) and returns 1 on a failure. Never call one inside
# $( ): ks_chain_hold keeps the head's fifo open on fd 7 and every step keeps its background pids in HOLD - a subshell
# would close the one and lose the other.

# ks_container: start the SQL Server 2022 container and wait for it; sets MPORT, ADDR, CID, MSV, MS_SERVER, APW, RPW
ks_container() {
  MSSQL_SA_PASSWORD=$(pw Sa); export MSSQL_SA_PASSWORD; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  APW=$(pw Ap); RPW=$(pw Rd)
  MPORT=$(freeport); ADDR=127.0.0.1:$MPORT
  MADE_CT=1
  docker run -d --name "$CT" --hostname testsql01 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_PID=Developer \
    -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run"
  CID=$(docker inspect -f '{{.Id}}' "$CT")
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server does not answer"
  MSV=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))")
  [[ $MSV == 16.* ]] || fail "the image is not SQL Server 2022 (ProductVersion $MSV)"
  MS_SERVER="SQL Server 2022 $MSV"
}

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

# the procedures each kit file must leave in master: a file cut at a GO installs a part of itself with sqlcmd's exit 0
KS_PROCS_FRK="sp_Blitz sp_BlitzCache sp_BlitzFirst sp_BlitzIndex sp_BlitzLock sp_BlitzWho"
KS_PROCS_DARLING="sp_HumanEvents sp_HumanEventsBlockViewer sp_PressureDetector sp_QuickieStore sp_HealthParser sp_LogHunter sp_IndexCleanup"
KS_PROCS_WIA="sp_WhoIsActive"

# ks_install <file> <procedures...>: the kit's file into master, then each procedure it must leave (KS_WHY)
ks_install() {
  local f=$1; shift
  KS_WHY=""
  sqf "$f" 2>"$WORK/install.err" || { KS_WHY="did not install: $(tail -c 400 "$WORK/install.err")"; return 1; }
  local miss="" p
  for p in "$@"; do
    [[ $(sq "SELECT COUNT(*) FROM sys.procedures WHERE name = N'$p' AND schema_id = 1") == 1 ]] || miss+=" $p"
  done
  [[ -z $miss ]] || { KS_WHY="installed without:$miss"; return 1; }
}

# ks_drop_kits: every procedure of the three kits out of master (kitwatch's second pass installs the newest over none)
ks_drop_kits() {
  local p
  for p in $KS_PROCS_FRK sp_BlitzBackups sp_BlitzQueryStore sp_ineachdb sp_BlitzAnalysis $KS_PROCS_DARLING sp_PerfCheck $KS_PROCS_WIA; do
    sq "IF OBJECT_ID(N'dbo.$p', N'P') IS NOT NULL DROP PROCEDURE dbo.$p;" >/dev/null
  done
  sq "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'keeper_HumanEvents_blocking') DROP EVENT SESSION keeper_HumanEvents_blocking ON SERVER;" >/dev/null
}

# ks_definition <procedure>: its definition (VIEW DEFINITION's read: nothing is executed), for the version lines,
# the decline texts and the sibling names. Not through sq: sqlcmd returns at most -y characters of an nvarchar(max)
# (256 by default) and sq's -W cannot be combined with -y, so -y 0 (the whole value) here and no -W.
ks_definition() {
  docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -h -1 -y 0 \
    -U sa -d master -Q "SET NOCOUNT ON; SELECT OBJECT_DEFINITION(OBJECT_ID(N'dbo.$1'));" 2>/dev/null || true
}

# ks_sales: the database, its tables and rows, Query Store, the logins orders_app and stock_job, pgvigil_read
ks_sales() {
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
  local l
  for l in orders_app stock_job; do
    sq "CREATE LOGIN $l WITH PASSWORD = '$APW', CHECK_POLICY = OFF;" >/dev/null
    sq "CREATE USER $l FOR LOGIN $l; ALTER ROLE db_datareader ADD MEMBER $l; ALTER ROLE db_datawriter ADD MEMBER $l; GRANT EXECUTE TO $l;" Sales >/dev/null
  done
  sq "CREATE LOGIN pgvigil_read WITH PASSWORD = '$RPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE TO pgvigil_read;" >/dev/null
  sq "CREATE USER pgvigil_read FOR LOGIN pgvigil_read; GRANT EXECUTE ON sys.xp_readerrorlog TO pgvigil_read;" >/dev/null
  sq "CREATE USER pgvigil_read FOR LOGIN pgvigil_read; ALTER ROLE db_datareader ADD MEMBER pgvigil_read;" msdb >/dev/null
  sq "CREATE USER pgvigil_read FOR LOGIN pgvigil_read; ALTER ROLE db_datareader ADD MEMBER pgvigil_read;" Sales >/dev/null
}

# ks_grant_kits: EXECUTE on every non-shipped procedure in master to pgvigil_read (after each install)
ks_grant_kits() {
  sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'GRANT EXECUTE ON dbo.' + QUOTENAME(name) + N' TO pgvigil_read; ' FROM sys.procedures WHERE is_ms_shipped = 0 AND schema_id = 1; EXEC (@s);" >/dev/null
}

# ks_keeper: the blocked process threshold at 5 s, deadlocks into the error log (trace flag 1222), and the session the
# block viewer reads, made as the page's advice says (sp_HumanEvents @event_type = 'blocking', @keep_alive = 1): the
# reason it is not running in KS_WHY
ks_keeper() {
  KS_WHY=""
  sq "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'blocked process threshold (s)', 5; RECONFIGURE; DBCC TRACEON (1222, -1) WITH NO_INFOMSGS;" >/dev/null
  local o
  o=$(sq "EXEC dbo.sp_HumanEvents @event_type = N'blocking', @keep_alive = 1;" 2>&1) || true
  [[ $(sq "SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name = N'keeper_HumanEvents_blocking'") == 1 ]] \
    || { KS_WHY="the page's advice call (sp_HumanEvents @event_type = 'blocking', @keep_alive = 1) made no running keeper_HumanEvents_blocking session: $(printf '%s' "$o" | tail -c 300)"; return 1; }
}

# ks_workload: the workload alone (200 passes or the reason), then a deadlock beside it, two error-log lines, Query
# Store flushed; waits for the deadlock in system_health. The reason a state was not reached in KS_WHY
ks_workload() {
  local wl
  KS_WHY=""
  wl=$(docker exec -e SQLCMDPASSWORD="$APW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -h -1 -W -U orders_app -d Sales -Q "SET NOCOUNT ON;
    DECLARE @i int = 0; WHILE @i < 200 BEGIN
      EXEC dbo.usp_SearchOrders @text = N'1', @top = 100;
      SELECT c.region, COUNT(*) AS orders, SUM(o.total) AS total FROM dbo.Orders o JOIN dbo.Customer c ON c.customer_id = o.customer_id WHERE o.ordered >= DATEADD(day, -30, sysutcdatetime()) GROUP BY c.region;
      SELECT TOP (50) ol.order_id, SUM(ol.amount) AS amount FROM dbo.OrderLine ol WHERE ol.stock_id = 1 + @i % 500 GROUP BY ol.order_id ORDER BY 2 DESC;
      UPDATE dbo.Orders SET status = 'shipped' WHERE order_id = 1 + (@i * 7) % 50000;
      INSERT dbo.AuditLog (logged, what) VALUES (sysutcdatetime(), N'order changed');
      SET @i += 1;
    END;
    SELECT CONCAT('workload passes ', @i);" 2>&1 | tail -3) || { KS_WHY="the workload: $wl"; return 1; }
  grep -q '^workload passes 200$' <<<"$wl" || { KS_WHY="the workload did not make its 200 passes: $(printf '%s' "$wl" | tail -3)"; return 1; }
  sqbg orders_app Sales "BEGIN TRAN; UPDATE dbo.Stock SET qty = qty - 1 WHERE stock_id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.OrderLine SET qty = qty WHERE line_id = 1; COMMIT;"
  sqbg stock_job Sales "BEGIN TRAN; UPDATE dbo.OrderLine SET qty = qty WHERE line_id = 1; WAITFOR DELAY '00:00:03'; UPDATE dbo.Stock SET qty = qty + 1 WHERE stock_id = 1; COMMIT;"
  sq "RAISERROR (N'Sales: the nightly stock job failed: 3 orders were not shipped', 16, 1) WITH LOG; RAISERROR (N'Sales: a backup of Sales_archive has not run for 8 days', 10, 1) WITH LOG;" >/dev/null 2>&1 || true
  sq "EXEC sys.sp_query_store_flush_db;" Sales >/dev/null
  local dl='SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'"'"'system_health*.xel'"'"', NULL, NULL, NULL) WHERE object_name = N'"'"'xml_deadlock_report'"'"''
  for _ in $(seq 1 90); do [[ $(sq "$dl") -ge 1 ]] && break; sleep 2; done
  [[ $(sq "$dl") -ge 1 ]] || { KS_WHY="system_health holds no deadlock after 180 s"; return 1; }
}

# ks_chain_hold: a sleeping head with an open transaction and two sessions waiting on it, held until ks_chain_release;
# waits 20 s for the blocked process reports (5, 10, 15, 20 s) into the keeper session. The reason in KS_WHY
ks_chain_hold() {
  KS_WHY=""
  rm -f "$WORK/head.in"; mkfifo "$WORK/head.in"
  docker exec -i -e SQLCMDPASSWORD="$APW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -I -U stock_job -d Sales < "$WORK/head.in" >/dev/null 2>&1 & HOLD+=($!)
  exec 7>"$WORK/head.in"
  printf 'BEGIN TRAN; UPDATE dbo.Stock SET qty = qty WHERE stock_id = 2;\nGO\n' >&7
  sleep 2
  sqbg orders_app Sales "UPDATE dbo.Stock SET qty = qty - 1 WHERE stock_id = 2;"
  sqbg orders_app Sales "SELECT qty FROM dbo.Stock WITH (UPDLOCK) WHERE stock_id = 2;"
  for _ in $(seq 1 30); do [[ $(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id > 0") -ge 2 ]] && break; sleep 1; done
  [[ $(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id > 0") -ge 2 ]] || { KS_WHY="the chain did not form"; return 1; }
  sleep 20
}

ks_chain_release() {
  exec 7>&-
  sq "DECLARE @k nvarchar(max) = N''; SELECT @k += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; ' FROM sys.dm_exec_sessions WHERE login_name IN (N'orders_app', N'stock_job'); EXEC (@k);" >/dev/null 2>&1 || true
}

# ks_mark <run.json> <tool> <mark> <nokit>: the run's line and whether it holds its subject. MARK: words the rows must
# hold (the state's own subject: a run without them read a server where the state was not reached); NOKIT: no kit's
# own statement among the rows. Exit 0 = done with rows of its subject; 1 = not done; 2 = done but the state missing.
ks_mark() {
  MARK=$3 NOKIT=$4 python3 - "$1" "$2" <<'PY'
import json, os, re, sys
r = json.load(open(sys.argv[1]))['runs'][0]
rows = sum(len(s['rows']) for s in r['sets'])
text = json.dumps(r['sets'])
mark, nokit = os.environ['MARK'], os.environ['NOKIT']
miss = [m for m in mark.split('|') if m and m not in text]
kit = re.findall(r'#BlitzResults|#Recompile|#partdb|#BlitzWho|WhoIsActive|@VersionCheckMode|#ErrorLog|#deadlock_data', text) if nokit else []
print(f"capt {sys.argv[2]}: {r['outcome']}, {len(r['sets'])} sets, {rows} rows" + (f"; holds '{mark}'" if mark and not miss else '')
      + (f"; MISSING {miss}" if miss else '') + (f"; KIT CODE {sorted(set(kit))}" if kit else '') + ((': ' + r.get('error', '')[:200]) if r['outcome'] != 'done' else ''))
if r['outcome'] != 'done':
    sys.exit(1)
sys.exit(0 if rows > 0 and not miss and not kit else 2)
PY
}

# KS_SQL_RUNS: the 13 SQL Server tools in the capture's order and state, with each tool's MARK, NOKIT and parameters
# (tool~phase~mark~nokit~params json; '~' because a MARK holds '|'): phase 'before' runs before any kit has run in Sales (plan cache, Query Store),
# 'chain' while the chain is held, 'after' once it is released
KS_SQL_RUNS=(
  'sp_BlitzCache~before~usp_SearchOrders~1~{"@DatabaseName":"Sales"}'
  'sp_QuickieStore~before~Orders~1~{"@database_name":"Sales"}'
  'sp_WhoIsActive~chain~LCK_M_|stock_job~1~{"@find_block_leaders":"1"}'
  'sp_BlitzWho~chain~stock_job~1~{}'
  'sp_HumanEventsBlockViewer~chain~Stock~1~{}'
  'sp_PressureDetector~chain~~1~{}'
  'sp_BlitzFirst~chain~~1~{}'
  'sp_Blitz~after~Sales~~{"@CheckServerInfo":"1"}'
  'sp_BlitzIndex~after~Unindexed Foreign Keys~~{"@DatabaseName":"Sales","@Mode":"4"}'
  'sp_BlitzLock~after~dbo.Stock|orders_app~1~{}'
  'sp_HealthParser~after~deadlock~1~{}'
  'sp_LogHunter~after~was killed by~~{}'
  'sp_IndexCleanup~after~IX_Orders_customer_2~~{"@database_name":"Sales"}'
)
