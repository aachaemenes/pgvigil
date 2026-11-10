// The DBADash door's demo rows (task 55): a recorded DBA Dash Summary of three SQL Server instances in one repository "dbadash-demo",
// in the shape the live proof read from a DBA Dash 4.24.1 repository (scripts/proof-dbadash.sh; the codes, keys and detail names are
// DBA Dash's own; the instance names and values are invented), one read an hour over the demo's days through pgvigil.import_dbadash.

package demo

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// three SQL Server instances in one repository "dbadash-demo", in the shape the live proof read from a DBADash 4.24.1
// repository (scripts/proof-dbadash.sh; the codes, keys and detail names are DBADash's own; the instance names and
// values are invented). One read every hour over the demo's days through pgvigil.import_dbadash, so the history and
// dbadash_changes() have rows: SQLPROD02's Drive Space goes Warning -> Critical 6 hours before the end, SQLDEV01's
// Backup FULL goes OK -> Critical 30 hours before the end.

// dbadashDemoBase is the status row every demo instance starts from (DBADash's codes: 1 Critical, 2 Warning, 3 N/A, 4 OK).
func dbadashDemoBase() map[string]int {
	return map[string]int{
		"MemoryDumpStatus": 4, "CorruptionStatus": 4, "LastGoodCheckDBStatus": 4, "AlertStatus": 4, "FullBackupStatus": 4,
		"DiffBackupStatus": 4, "LogBackupStatus": 4, "DriveStatus": 4, "JobStatus": 4, "IsAgentRunningStatus": 4,
		"LogShippingStatus": 3, "MirroringStatus": 3, "AGStatus": 4, "LogFreeSpaceStatus": 4, "FileFreeSpaceStatus": 4,
		"PctMaxSizeStatus": 3, "ElasticPoolStorageStatus": 3, "QueryStoreStatus": 4, "CustomCheckStatus": 3,
		"CollectionErrorStatus": 4, "SnapshotAgeStatus": 4, "DBMailStatus": 4, "IdentityStatus": 4, "DatabaseStateStatus": 4,
		"ServiceBrokerStatus": 3, "UptimeStatus": 4,
	}
}

// SeedDBADash writes the demo repository's hourly reads from start to end.
func SeedDBADash(ctx context.Context, pool *pgxpool.Pool, start, end time.Time) error {
	type inst struct {
		id                int
		name, version, ed string
		over              func(t time.Time) map[string]int
		details           func(t time.Time) map[string]any
	}
	ut := func(t time.Time) string { return t.UTC().Format("2006-01-02 15:04:05") }
	insts := []inst{
		{1, "SQLPROD01", "16.0.4135.4", "Enterprise Edition: Core-based Licensing (64-bit)",
			func(time.Time) map[string]int { return map[string]int{"LogShippingStatus": 4} },
			func(_ time.Time) map[string]any {
				return map[string]any{"CollectionErrorCount": 0, "SnapshotAgeMin": 1, "SnapshotAgeMax": 2, "DaysSinceLastGoodCheckDB": 3,
					"LastGoodCheckDBHealthyCount": 14, "LastGoodCheckDBWarningCount": 0, "LastGoodCheckDBCriticalCount": 0,
					"sqlserver_start_time_utc": ut(end.Add(-41 * 24 * time.Hour)), "IsAgentRunning": true, "MaxIdentityPctUsed": 38.4, "MinIdentityEstimatedDays": 2210}
			}},
		{2, "SQLPROD02", "15.0.4405.4", "Standard Edition (64-bit)",
			func(t time.Time) map[string]int {
				o := map[string]int{"DriveStatus": 2, "IdentityStatus": 2}
				if t.After(end.Add(-6 * time.Hour)) {
					o["DriveStatus"] = 1
				}
				return o
			},
			func(_ time.Time) map[string]any {
				return map[string]any{"CollectionErrorCount": 2, "SnapshotAgeMin": 1, "SnapshotAgeMax": 4, "DaysSinceLastGoodCheckDB": 6,
					"LastGoodCheckDBHealthyCount": 9, "LastGoodCheckDBWarningCount": 0, "LastGoodCheckDBCriticalCount": 0,
					"sqlserver_start_time_utc": ut(end.Add(-12 * 24 * time.Hour)), "IsAgentRunning": true, "MaxIdentityPctUsed": 81.7, "MinIdentityEstimatedDays": 44}
			}},
		{3, "SQLDEV01", "16.0.1000.6", "Developer Edition (64-bit)",
			func(t time.Time) map[string]int {
				o := map[string]int{"AGStatus": 3, "LastGoodCheckDBStatus": 1, "DBMailStatus": 3, "MemoryDumpStatus": 2}
				if t.After(end.Add(-30 * time.Hour)) {
					o["FullBackupStatus"] = 1
				}
				return o
			},
			func(_ time.Time) map[string]any {
				return map[string]any{"CollectionErrorCount": 0, "SnapshotAgeMin": 1, "SnapshotAgeMax": 3,
					"LastGoodCheckDBHealthyCount": 0, "LastGoodCheckDBWarningCount": 0, "LastGoodCheckDBCriticalCount": 37,
					"MemoryDumpCount": 2, "LastMemoryDumpUTC": ut(end.Add(-6 * 24 * time.Hour)),
					"DBMailStatusDescription":  "Database Mail XPs component is turned off in sp_configure.",
					"sqlserver_start_time_utc": ut(end.Add(-3 * 24 * time.Hour)), "IsAgentRunning": true}
			}},
	}
	for t := start.Truncate(time.Hour); !t.After(end); t = t.Add(time.Hour) {
		refreshed := t.Add(-2 * time.Minute).UTC()
		var rows []map[string]any
		for _, in := range insts {
			st := dbadashDemoBase()
			for k, v := range in.over(t) {
				st[k] = v
			}
			rows = append(rows, map[string]any{
				"instance_id": in.id, "instance": in.name, "connection_id": in.name, "display_name": in.name, "show_in_summary": true,
				"product_version": in.version, "edition": in.ed, "last_collection": t.Add(-1 * time.Minute).UTC(),
				"refreshed_at": refreshed, "statuses": st, "details": in.details(t),
			})
		}
		payload, err := json.Marshal(map[string]any{"status": "ok", "version": "4.24.1.0", "refreshed_at": refreshed, "instances": rows})
		if err != nil {
			return err
		}
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_dbadash($1, $2, $3::jsonb)`, "dbadash-demo", t, string(payload)); err != nil {
			return fmt.Errorf("dbadash demo: %w", err)
		}
	}
	_, err := pool.Exec(ctx, `SELECT pgvigil.import_dbadash_configured($1)`, []string{"dbadash-demo"})
	return err
}

// Note for the demo's serve: `pgvigil demo -serve` runs no dbadash.Run (the demo config lists no dbadash: repository), so
// the import_dbadash_configured call above keeps the demo repository in the tree; a later 'pgvigil run' with a config
// that lists none would mark it unconfigured (dbadash.Run returns at once on an empty list and calls nothing, so it
// stays).
