#!/usr/bin/env bash
# Captures the plans the demo shows on Running queries (internal/demo/runplans/*.sqlplan): the demo's own running
# statements (internal/demo/mssql_demo.go: mssqlReport, mssqlLookup, mssqlVictim1, mssqlVictim2), run on a SQL Server
# container against tables of the demo's names, each plan read from the plan cache as the mssql_running_plans collector
# reads it (sys.dm_exec_text_query_plan at the statement's offsets). Nothing of a real server: a scratch container,
# made and removed by this run. Needs docker and base64.
#   MSSQL_IMAGE        the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_CAPTURE_OUT a folder to write <name>.sqlplan into; unset = each plan printed base64 between
#                      'BEGIN PLAN <name>' and 'END PLAN' (a lab run's folder is removed after the run)
set -euo pipefail
IMG=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n'); SQL=pgvdrp-sql-$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
umask 077
TMPD=$(mktemp -d)
SA_PW=$(printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')")
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() { docker rm -f -v "$SQL" >/dev/null 2>&1 || true; rm -rf "$TMPD"; }
trap cleanup EXIT
docker run -d --name "$SQL" --label pgvigil-proof=demo-running-plans --memory 6g --env-file "$TMPD/sa.env" "$IMG" >/dev/null
SQLCMD=
for _ in $(seq 1 60); do
  for c in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do docker exec "$SQL" test -x "$c" 2>/dev/null && SQLCMD=$c && break 2; done
  sleep 1
done
[[ -n "$SQLCMD" ]] || fail "no sqlcmd in the image"
TRUST=; [[ "$SQLCMD" == *tools18* ]] && TRUST=-C
# sq: T-SQL as sa from stdin into the database $2; sqx: the same with -y 0 (a long value whole; sqlcmd refuses -h
# beside it, so its output keeps the column's header and dash lines: the reader keeps the plan's own line)
sq() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -h -1 -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqx() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -y 0 -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
sq "SELECT 1" >/dev/null || fail "the server never answered"
VER=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(32))" | tr -d '[:space:]')
echo "SQL Server $VER"

# the demo's tables: Sales (Customers, Orders, OrderLines) and Ledger (LedgerEntry), with rows enough for the report to
# compile a parallel plan as the demo's request shows it (DOP 8)
sq "CREATE DATABASE Sales; CREATE DATABASE Ledger;" >/dev/null
sq "
CREATE TABLE dbo.Customers (CustomerId int NOT NULL PRIMARY KEY, Region nvarchar(40) NOT NULL);
CREATE TABLE dbo.Orders (OrderId int NOT NULL PRIMARY KEY, CustomerId int NOT NULL, Status varchar(12) NOT NULL, ShippedAt datetime2 NULL);
CREATE INDEX ix_Orders_CustomerId ON dbo.Orders (CustomerId);
CREATE TABLE dbo.OrderLines (OrderLineId int IDENTITY PRIMARY KEY, OrderId int NOT NULL, Amount decimal(12,2) NOT NULL);
WITH n AS (SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT dbo.Customers SELECT i, CONCAT(N'Region ', i % 12) FROM n;
WITH n AS (SELECT TOP (400000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT dbo.Orders SELECT i, 1 + i % 20000, 'OPEN', NULL FROM n;
WITH n AS (SELECT TOP (2000000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN (VALUES (1),(2)) c(x))
INSERT dbo.OrderLines (OrderId, Amount) SELECT 1 + i % 400000, (i % 997) / 10.0 FROM n;
" Sales >/dev/null
sq "
CREATE TABLE dbo.LedgerEntry (EntryId bigint IDENTITY PRIMARY KEY, AccountId int NOT NULL, PostedAt datetime2 NOT NULL, Amount decimal(14,2) NOT NULL);
CREATE INDEX ix_LedgerEntry_Account ON dbo.LedgerEntry (AccountId, PostedAt);
WITH n AS (SELECT TOP (500000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT dbo.LedgerEntry (AccountId, PostedAt, Amount) SELECT 1 + i % 5000, DATEADD(minute, -i, '2026-11-01'), (i % 991) / 10.0 FROM n;
" Ledger >/dev/null
echo "the demo's tables loaded"

# each statement exactly as the demo's request runs it (the parameterized ones through sp_executesql, as an application
# sends them), then its plan from the cache at the statement's offsets
run() { # $1 name, $2 database, $3 the batch that runs the statement, $4 a fragment of its text that the read finds it by
  sq "$3" "$2" >/dev/null
  sqx "SELECT TOP (1) tqp.query_plan
  FROM sys.dm_exec_query_stats qs
 CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
 CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle, qs.statement_start_offset, qs.statement_end_offset) tqp
 WHERE st.text LIKE N'%$4%' AND st.text NOT LIKE N'%dm_exec_query_stats%'
 ORDER BY qs.last_execution_time DESC" "$2" | tr -d '\r' > "$TMPD/$1.raw" || fail "$1: the plan read failed ($(head -c 300 "$TMPD/$1.raw"))"
  grep '^<ShowPlanXML' "$TMPD/$1.raw" | sed -e 's/[[:space:]]*$//' > "$TMPD/$1.sqlplan" || fail "$1: no plan read ($(head -c 300 "$TMPD/$1.raw"))"
  echo "$1: $(wc -c < "$TMPD/$1.sqlplan") bytes, $(grep -o 'PhysicalOp="[^"]*"' "$TMPD/$1.sqlplan" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
  if [[ -n "${PGVIGIL_CAPTURE_OUT:-}" ]]; then cp "$TMPD/$1.sqlplan" "$PGVIGIL_CAPTURE_OUT/$1.sqlplan"
  else echo "BEGIN PLAN $1"; base64 -w 76 < "$TMPD/$1.sqlplan"; echo "END PLAN"; fi
}
run report Sales "SELECT c.Region, SUM(l.Amount) FROM dbo.OrderLines l JOIN dbo.Orders o ON o.OrderId = l.OrderId JOIN dbo.Customers c ON c.CustomerId = o.CustomerId GROUP BY c.Region" "GROUP BY c.Region"
run victim1 Sales "EXEC sp_executesql N'UPDATE dbo.Orders SET ShippedAt = SYSUTCDATETIME() WHERE OrderId = @p0', N'@p0 int', @p0 = 4411" "SET ShippedAt = SYSUTCDATETIME() WHERE OrderId = @p0"
run victim2 Sales "EXEC sp_executesql N'SELECT o.OrderId, o.Status FROM dbo.Orders o WHERE o.CustomerId = @p0 ORDER BY o.OrderId', N'@p0 int', @p0 = 4411" "WHERE o.CustomerId = @p0 ORDER BY o.OrderId"
run lookup Ledger "EXEC sp_executesql N'SELECT TOP (50) EntryId, PostedAt, Amount FROM dbo.LedgerEntry WHERE AccountId = @p0 ORDER BY PostedAt DESC', N'@p0 int', @p0 = 1207" "FROM dbo.LedgerEntry WHERE AccountId = @p0 ORDER BY PostedAt DESC"
echo "CAPTURED on SQL Server $VER"
