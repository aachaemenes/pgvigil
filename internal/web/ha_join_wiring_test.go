package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestOverviewHasThePatroniChecks: Patroni's checks (0144's pg_patroni_checks: no leader, a member down, paused, a
// pending restart, the DCS not reached, the REST API not answering) are an overview check of their own, 'patroni' -
// what the Summary's Replication column and /api/overview read. 0144 leaves this line to the join.
func TestOverviewHasThePatroniChecks(t *testing.T) {
	for _, c := range overviewChecks {
		if c.name == "patroni" {
			return
		}
	}
	t.Error("no overview check is named 'patroni': a Patroni cluster without a leader shows on no Summary cell")
}

// TestSummaryLogShippingCellOnAStore (hadr-s3's wiring line W19): on a migrated repository (PGVIGIL_REPO_TEST_DSN,
// skipped without it) a SQL Server instance that only ships logs - a secondary whose restore job is disabled, the
// critical 'a log shipping job is disabled' of 0143 - counts that finding in the Summary's Log Shipping cell and none
// in Availability Groups. The cell took only names that START with 'log shipping' (0066's one finding); 0143's names
// ('a log shipping job is disabled', 'log restores are behind', 'a log-shipped database is in SIMPLE recovery' ...)
// fell to Availability Groups.
func TestSummaryLogShippingCellOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sfx := fmt.Sprint(time.Now().UnixNano() % 1000000000)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		"lswire-"+sfx).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_logrestore_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	now := time.Now().UTC().Truncate(time.Second)
	z := func(m int) string { return now.Add(-time.Duration(m) * time.Minute).Format("2006-01-02T15:04:05Z") }
	pri, sec, db := "PRI-"+sfx, "SEC-"+sfx, "lsw_restoreoff"
	job := func(role string, enabled int) map[string]any {
		return map[string]any{"kind": "lsconfig", "role": "secondary", "database_name": db, "primary_server": pri, "primary_database": db,
			"restore_mode": 0, "job_role": role, "job_id": role + "-" + db, "job_name": "LS" + role + "_PRI_" + db, "job_exists": 1,
			"job_enabled": enabled, "enabled_schedules": 1, "interval_min": 15.0}
	}
	// the rows of TestLogShipExtrasOnAStore's database lsx_s_restoreoff: msdb's monitor row, the restore history, the two jobs
	payload, err := json.Marshal([]map[string]any{
		{"kind": "secondary", "secondary_server": sec, "database_name": db, "primary_server": pri, "primary_database": db,
			"threshold_minutes": 45, "alert_enabled": 1, "last_copied_file": db + ".trn", "last_copied_utc": z(3),
			"last_restored_file": db + ".trn", "last_restored_utc": z(2), "last_restored_latency_min": 2},
		{"kind": "restore", "database_name": db, "database_state": "RESTORING", "is_in_standby": 0, "recovery_model": "FULL",
			"created_utc": now.Add(-30 * 24 * time.Hour).Format("2006-01-02T15:04:05Z"), "is_mirrored": 0, "in_availability_group": 0,
			"last_log_restore_utc": z(2), "last_log_backup_start_utc": z(4), "source_server": pri, "source_database": db,
			"last_file": db + ".trn", "last_restore_utc": z(2), "last_restore_type": "L"},
		job("copy", 1), job("restore", 0),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_logshipping($1, $2, $3::jsonb)`, id, now, string(payload)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_logshipping', now(), 'ok')`, id); err != nil {
		t.Fatal(err)
	}
	// the control: the finding itself, as 0143 raises it
	var crit string
	if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(check_name, ', ' ORDER BY check_name), '') FROM pgvigil.mssql_hadr_findings
	                               WHERE instance_id = $1 AND severity = 'critical'`, id).Scan(&crit); err != nil {
		t.Fatal(err)
	}
	if crit != "a log shipping job is disabled" {
		t.Fatalf("the instance's critical HA findings: %q; want the one 'a log shipping job is disabled'", crit)
	}
	rs, err := pool.Query(ctx, sqlMSSQLSummaryCells, `{}`, 3600)
	if err != nil {
		t.Fatal(err)
	}
	defer rs.Close()
	got := map[string]int{}
	for rs.Next() {
		var iid, c, w int
		var key, state string
		var sampled bool
		var value, errText *string
		var detail []string
		var readAt, since *time.Time
		if err := rs.Scan(&iid, &key, &state, &sampled, &c, &w, &value, &detail, &readAt, &errText, &since); err != nil {
			t.Fatal(err)
		}
		if iid == id {
			got[key] = c
		}
	}
	if err := rs.Err(); err != nil {
		t.Fatal(err)
	}
	if got["logship"] != 1 || got["availability"] != 0 {
		t.Errorf("the Summary's critical counts: Log Shipping %d, Availability Groups %d; want 1 and 0", got["logship"], got["availability"])
	}
}
