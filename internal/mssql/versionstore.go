package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// versionStoreCollector is mssql_versionstore: the tempdb version store (its size from the counter and from
// tempdb's files, the cumulative generation and cleanup counters the repository turns into rates), THE HOLDER -
// the oldest active transaction that generates or may read row versions, with its session and last statement -
// the store per database, and the persistent version store of accelerated database recovery.
//
// Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; the per-database part from
// 2016 SP2 (13.0.5026), the persistent version store from 2019 (15). Not on Azure SQL Database: tempdb is not the
// login's to read there.
type versionStoreCollector struct{}

func init() { Register(versionStoreCollector{}) }

func (versionStoreCollector) Name() string                   { return Prefix + "versionstore" }
func (versionStoreCollector) DefaultInterval() time.Duration { return time.Minute }

func (versionStoreCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not yet on Azure SQL Database (tempdb's version store is not readable there)"
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE: the version store's DMVs and counters are not readable"
	}
	return true, ""
}

// storeSQL: SQL Server 2016 SP1+. The two rate counters are cumulative (cntr_type 272696576): the value is the KB
// generated or cleaned since the server started, and a rate is the delta between two reads.
const storeSQL = `SELECT 'store' AS kind,
  (SELECT CAST(SUM(CAST(version_store_reserved_page_count AS bigint)) * 8 AS bigint) FROM tempdb.sys.dm_db_file_space_usage) AS reserved_kb,
  (SELECT CAST(SUM(CAST(total_page_count AS bigint)) * 8 AS bigint) FROM tempdb.sys.dm_db_file_space_usage) AS tempdb_data_kb,
  (SELECT MAX(cntr_value) FROM sys.dm_os_performance_counters WHERE object_name LIKE '%:Transactions%' AND counter_name = 'Version Store Size (KB)') AS store_kb,
  (SELECT MAX(cntr_value) FROM sys.dm_os_performance_counters WHERE object_name LIKE '%:Transactions%' AND counter_name = 'Version Generation rate (KB/s)') AS generation_raw_kb,
  (SELECT MAX(cntr_value) FROM sys.dm_os_performance_counters WHERE object_name LIKE '%:Transactions%' AND counter_name = 'Version Cleanup rate (KB/s)') AS cleanup_raw_kb,
  (SELECT COUNT(*) FROM sys.dm_tran_active_snapshot_database_transactions WHERE session_id <> @@SPID) AS snapshot_tx_count`

// holderSQL: SQL Server 2016 SP1+. The oldest active transaction that generates or may read row versions (the
// lowest transaction sequence number: the one version cleanup cannot pass), its session and its last statement
// from the input buffer. database_name is the SESSION's current database, which is where the transaction runs
// unless the session changed database since. The begin time is the server's local clock in the DMV: moved to UTC
// by the server's offset at the read.
const holderSQL = `SELECT TOP (1) 'holder' AS kind, st.session_id, s.login_name, s.host_name, s.program_name,
  DB_NAME(s.database_id) AS database_name, CAST(st.is_snapshot AS int) AS is_snapshot,
  CAST(st.elapsed_time_seconds AS bigint) AS elapsed_s,
  CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), tx.transaction_begin_time), 126) + 'Z' AS started_at_utc,
  ib.event_info AS statement
FROM sys.dm_tran_active_snapshot_database_transactions st
LEFT JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
LEFT JOIN sys.dm_tran_active_transactions tx ON tx.transaction_id = st.transaction_id
OUTER APPLY sys.dm_exec_input_buffer(st.session_id, NULL) ib
WHERE st.session_id <> @@SPID
ORDER BY st.transaction_sequence_num ASC`

// storeDBSQL: SQL Server 2016 SP2 (13.0.5026) and later.
const storeDBSQL = `SELECT 'db' AS kind, DB_NAME(database_id) AS database_name, CAST(reserved_space_kb AS bigint) AS reserved_kb
FROM sys.dm_tran_version_store_space_usage
WHERE reserved_page_count > 0 AND DB_NAME(database_id) IS NOT NULL`

// pvsSQL: SQL Server 2019 (15) and later. A database is listed when accelerated database recovery is on for it or
// its persistent version store holds anything.
const pvsSQL = `SELECT 'pvs' AS kind, d.name AS database_name, CAST(d.is_accelerated_database_recovery_on AS int) AS adr_on,
  CAST(p.persistent_version_store_size_kb AS bigint) AS pvs_kb,
  CAST(p.online_index_version_store_size_kb AS bigint) AS online_index_kb,
  CAST(p.current_aborted_transaction_count AS bigint) AS aborted_tx_count,
  CAST(p.oldest_active_transaction_id AS bigint) AS oldest_active_tx_id,
  CAST(p.oldest_aborted_transaction_id AS bigint) AS oldest_aborted_tx_id,
  se.session_id AS oldest_tx_session_id,
  CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), tx.transaction_begin_time), 126) + 'Z' AS oldest_tx_started_at_utc
FROM sys.dm_tran_persistent_version_store_stats p
JOIN sys.databases d ON d.database_id = p.database_id
LEFT JOIN sys.dm_tran_active_transactions tx ON tx.transaction_id = p.oldest_active_transaction_id AND p.oldest_active_transaction_id > 0
LEFT JOIN sys.dm_tran_session_transactions se ON se.transaction_id = tx.transaction_id
WHERE d.is_accelerated_database_recovery_on = 1 OR p.persistent_version_store_size_kb > 0 OR p.current_aborted_transaction_count > 0`

// hasStoreByDatabase: sys.dm_tran_version_store_space_usage arrived in SQL Server 2016 SP2 (13.0.5026). Azure SQL
// Managed Instance has it whatever its product version says (it reports 12.0).
func hasStoreByDatabase(info Info) bool {
	return info.Kind == KindAzureMI || info.Major > 13 || (info.Major == 13 && info.Build >= 5026)
}

// hasPVS: sys.dm_tran_persistent_version_store_stats arrived with accelerated database recovery in SQL Server 2019;
// Managed Instance has it (accelerated database recovery is always on there).
func hasPVS(info Info) bool { return info.Kind == KindAzureMI || info.Major >= 15 }

func (versionStoreCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, storeSQL)
	if err != nil {
		return nil, err
	}
	part := func(source, query string, marker collect.Row) {
		got, err := QueryRows(ctx, conn, query)
		if err != nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
			return
		}
		rows = append(rows, got...)
		if marker != nil {
			// the read succeeded: the marker tells the import to replace the state even when no database is listed
			rows = append(rows, marker)
		}
	}
	part("sys.dm_tran_active_snapshot_database_transactions", holderSQL, nil)
	if hasStoreByDatabase(info) {
		part("sys.dm_tran_version_store_space_usage", storeDBSQL, collect.Row{"kind": "db", "database_name": nil})
	}
	if hasPVS(info) {
		part("sys.dm_tran_persistent_version_store_stats", pvsSQL, collect.Row{"kind": "pvs", "database_name": nil})
	}
	return rows, nil
}
