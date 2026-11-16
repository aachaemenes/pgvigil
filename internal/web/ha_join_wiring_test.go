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

// TestReplicationTabNamesPatroniNoLeader (the wiring review's #8; the rule the lead relays as Allen's: a click lands
// where its cause shows). The Summary's Replication cell counts the overview checks 'replication' and 'patroni' and
// lands on the instance's Replication tab, which reads GET /api/replication. On a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) a Patroni cluster that two reads 70 s apart find without a leader
// (scripts/proof-patroni.sh's seeded case s1) is critical 'patroni no leader' in 0144's own view - the control - and
// the Replication tab's parts name it: a part 'patroni_checks' whose rows hold that check, beside a part 'patroni'
// (the read's line and the members the block is drawn from). Without them the cell is red and its landing page
// says 'No replication problems in the newest snapshot.'
func TestReplicationTabNamesPatroniNoLeader(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '18.0', 180000, false, '{}'::text[], 'postgres')`,
		"patwire-"+sfx).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	// a cluster of its own (scope and system identifier), so this instance is the one that judges it
	scope := "patwire" + sfx
	read := func(leader string) string {
		return `{"kind":"patroni_read","url":"u","ok":true,"cluster_ok":true,"scope":"` + scope + `","members":2,"leader":` + leader +
			`,"system_identifier":"s-` + scope + `"}`
	}
	member := func(name, role, state string) string {
		return `{"kind":"patroni","member":"` + name + `","role":"` + role + `","state":"` + state + `","api_ok":true}`
	}
	for _, r := range []struct {
		secondsAgo int
		payload    string
	}{
		{140, "[" + read(`"m1"`) + "," + member("m1", "leader", "running") + "," + member("m2", "replica", "streaming") + "]"},
		{70, "[" + read("null") + "," + member("m2", "replica", "running") + "]"},
		{0, "[" + read("null") + "," + member("m2", "replica", "running") + "]"},
	} {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_patroni($1, now() - $2::int * interval '1 second', $3::jsonb)`, id, r.secondsAgo, r.payload); err != nil {
			t.Fatal(err)
		}
	}
	var own string
	if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(severity || '|' || check_name, ',' ORDER BY check_name), '')
	                               FROM pgvigil.pg_patroni_checks WHERE instance_id = $1`, id).Scan(&own); err != nil {
		t.Fatal(err)
	}
	if own != "critical|patroni member down,critical|patroni no leader" {
		t.Fatalf("the control, 0144's own view: %q; want the two critical checks of a cluster without a leader", own)
	}
	now := time.Now()
	parts := map[string]part{}
	for _, p := range replicationParts(id, now.Add(-time.Hour), now, 60) {
		parts[p.name] = p
	}
	if _, ok := parts["patroni"]; !ok {
		t.Error("GET /api/replication reads no part 'patroni': the Replication tab cannot draw the Patroni block")
	}
	chk, ok := parts["patroni_checks"]
	if !ok {
		t.Fatal("GET /api/replication reads no part 'patroni_checks': the Summary's Replication cell is red on 'patroni no leader' and its landing page names no Patroni check")
	}
	rows, err := pool.Query(ctx, chk.sql, chk.args...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	col := -1
	for i, f := range rows.FieldDescriptions() {
		if f.Name == "check_name" {
			col = i
		}
	}
	if col < 0 {
		t.Fatal("the part 'patroni_checks' has no column check_name")
	}
	named := false
	for rows.Next() {
		v, err := rows.Values()
		if err != nil {
			t.Fatal(err)
		}
		if s, _ := v[col].(string); s == "patroni no leader" {
			named = true
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if !named {
		t.Error("the Replication tab's part 'patroni_checks' does not name 'patroni no leader' for a cluster without a leader")
	}
}

// TestSummaryMirroringCellOnAStore (hadr-s3's answer to the join's L10, its report's HA JOIN CHECK (d)): on a migrated
// repository (PGVIGIL_REPO_TEST_DSN, skipped without it) a SQL Server instance that only mirrors - one read of a
// synchronized principal whose named witness is disconnected (0143's warning 'the mirroring witness is disconnected')
// and whose mirroring endpoint is stopped (its critical 'the mirroring endpoint is not started') - counts both in the
// Summary's Mirroring cell and none in Availability Groups. The cell took only names that START with 'mirroring'
// (three of 0143's eight mirroring names); the other five - these two, 'the mirroring send / redo queue is over its
// threshold' and 'the principal of a mirrored database changed' - fell to Availability Groups, as the log shipping
// names did before W19.
func TestSummaryMirroringCellOnAStore(t *testing.T) {
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
		"mirwire-"+sfx).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_mirroring_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	payload, err := json.Marshal([]map[string]any{
		{"kind": "mirror", "database_name": "mirw_db", "role": "PRINCIPAL", "state": "SYNCHRONIZED", "safety_level": "FULL",
			"partner": "TCP://MIR-" + sfx + ":5022", "partner_instance": "MIR-" + sfx, "witness": "TCP://WIT-" + sfx + ":5022",
			"witness_state": "DISCONNECTED", "log_send_queue_kb": 0, "redo_queue_kb": 0, "role_sequence": 1},
		{"kind": "endpoint", "endpoint_name": "Mirroring", "endpoint_port": 5022, "endpoint_state": "STOPPED"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_mirroring($1, now(), $2::jsonb)`, id, string(payload)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_mirroring', now(), 'ok')`, id); err != nil {
		t.Fatal(err)
	}
	// the control: the two findings themselves, as 0143 raises them
	var own string
	if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(severity || '|' || check_name, ', ' ORDER BY severity, check_name), '') FROM pgvigil.mssql_hadr_findings
	                               WHERE instance_id = $1`, id).Scan(&own); err != nil {
		t.Fatal(err)
	}
	if own != "critical|the mirroring endpoint is not started, warning|the mirroring witness is disconnected" {
		t.Fatalf("the instance's HA findings: %q; want the critical endpoint finding and the warning witness finding", own)
	}
	rs, err := pool.Query(ctx, sqlMSSQLSummaryCells, `{}`, 3600)
	if err != nil {
		t.Fatal(err)
	}
	defer rs.Close()
	crit, warn := map[string]int{}, map[string]int{}
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
			crit[key], warn[key] = c, w
		}
	}
	if err := rs.Err(); err != nil {
		t.Fatal(err)
	}
	if crit["mirroring"] != 1 || warn["mirroring"] != 1 || crit["availability"] != 0 || warn["availability"] != 0 {
		t.Errorf("the Summary's counts (critical / warning): Mirroring %d / %d, Availability Groups %d / %d; want 1 / 1 and 0 / 0",
			crit["mirroring"], warn["mirroring"], crit["availability"], warn["availability"])
	}
}
