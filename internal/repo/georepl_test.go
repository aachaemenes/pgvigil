package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0151's geo-replication rows (task 390a):
// a read with no link stores the read alone; a link added, a role change, a partner change on the same link and a
// state change are each one event with the read before; a re-run of one read adds nothing; an older read imported
// late stores its sample and leaves the state; a link gone is 'removed' and its state row goes; the findings: the
// data loss held 5 minutes, SUSPENDED in two reads, a role change (critical, an hour) and a removed link (24 hours).
func TestGeoReplOnAStore(t *testing.T) {
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
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("geo-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_georepl_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	read := func(server string, links int) map[string]any {
		return map[string]any{"kind": "read", "server_read": server, "database_name": "db1", "links": links}
	}
	link := func(role int, partner string, state int, lag int, unsent float64) map[string]any {
		desc := map[int]string{0: "PRIMARY", 1: "SECONDARY"}[role]
		sd := map[int]string{1: "SEEDING", 2: "CATCH_UP", 4: "SUSPENDED"}[state]
		return map[string]any{"kind": "link", "link_guid": "8d3c0000-0000-0000-0000-000000000001", "partner_server": partner,
			"partner_database": "db1", "role": role, "role_desc": desc, "replication_state": state, "replication_state_desc": sd,
			"replication_lag_sec": lag, "unsent_s": unsent, "ack_age_s": 2, "last_replication": "2026-11-14T10:00:01Z",
			"last_commit": "2026-11-14T10:00:03Z", "secondary_allow_connections": 2, "secondary_allow_connections_desc": "ALL"}
	}
	imp := func(at time.Time, rows ...map[string]any) {
		t.Helper()
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_georepl($1, $2, $3::jsonb)`, id, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	count := func(q string, args ...any) int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, q, append([]any{id}, args...)...).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	events := func(kind string) int {
		return count(`SELECT count(*)::int FROM pgvigil.mssql_georepl_events WHERE instance_id = $1 AND kind = $2`, kind)
	}
	finding := func(check string) string {
		t.Helper()
		var sev string
		err := pool.QueryRow(ctx, `SELECT severity FROM pgvigil.mssql_georepl_findings WHERE instance_id = $1 AND check_name = $2`, id, check).Scan(&sev)
		if err != nil {
			return ""
		}
		return sev
	}

	now := time.Now().UTC().Truncate(time.Second)
	t0 := now.Add(-7 * time.Minute)
	imp(t0, read("pgv-a", 0))
	if n := count(`SELECT count(*)::int FROM pgvigil.mssql_georepl_read WHERE instance_id = $1 AND links = 0 AND server_read = 'pgv-a'`); n != 1 {
		t.Fatalf("a read with no link: read rows %d, want 1", n)
	}
	// the link appears, then holds a 120 s unsent window for six reads (over the 1-minute default, under 5)
	for i := 1; i <= 6; i++ {
		imp(t0.Add(time.Duration(i)*time.Minute), read("pgv-a", 1), link(0, "pgv-b", 2, 3, 120))
	}
	if events("added") != 1 || count(`SELECT count(*)::int FROM pgvigil.mssql_georepl_state WHERE instance_id = $1`) != 1 {
		t.Fatalf("link added: events %d", events("added"))
	}
	if got := finding("geo-replication data loss"); got != "warning" {
		t.Errorf("120 s held 5 minutes: finding %q, want warning", got)
	}
	// a re-run of the newest read adds nothing; an older read imported late keeps the state
	imp(t0.Add(6*time.Minute), read("pgv-a", 1), link(0, "pgv-b", 2, 3, 120))
	imp(t0.Add(150*time.Second), read("pgv-a", 1), link(1, "pgv-c", 4, 0, 0))
	if events("role") != 0 || events("partner") != 0 || events("state") != 0 {
		t.Fatalf("a re-run or a late older read made events: role %d partner %d state %d", events("role"), events("partner"), events("state"))
	}
	if n := count(`SELECT count(*)::int FROM pgvigil.mssql_georepl_sample WHERE instance_id = $1 AND snapshot_at = $2`, t0.Add(150*time.Second)); n != 1 {
		t.Errorf("the late read's sample: %d, want 1", n)
	}
	// a failover through the listener: the partner changes on the same link, the role stays
	imp(now, read("pgv-b", 1), link(0, "pgv-a", 2, 1, 0))
	if events("partner") != 1 || events("role") != 0 {
		t.Fatalf("partner change: partner %d role %d", events("partner"), events("role"))
	}
	if finding("geo-replication partner changed") != "critical" {
		t.Error("a partner change is not a critical finding for the hour")
	}
	// a failover seen by the database itself: the role changes; then SUSPENDED in two reads
	imp(now.Add(time.Second), read("pgv-b", 1), link(1, "pgv-a", 4, 0, 0))
	imp(now.Add(2*time.Second), read("pgv-b", 1), link(1, "pgv-a", 4, 0, 0))
	if events("role") != 1 || events("state") != 1 {
		t.Fatalf("role and state: role %d state %d", events("role"), events("state"))
	}
	if finding("geo-replication role changed") != "critical" || finding("geo-replication suspended") != "critical" {
		t.Errorf("role changed %q, suspended %q, want both critical", finding("geo-replication role changed"), finding("geo-replication suspended"))
	}
	// the link removed
	imp(now.Add(3*time.Second), read("pgv-b", 0))
	if events("removed") != 1 || count(`SELECT count(*)::int FROM pgvigil.mssql_georepl_state WHERE instance_id = $1`) != 0 {
		t.Fatalf("removed: events %d", events("removed"))
	}
	if finding("geo-replication link removed") != "warning" {
		t.Error("a removed link is not a warning")
	}
}

// 0151's failover groups (task 390a G2): one row a server and group whoever reads it; a role change (the group's
// primary moved), a policy change and a group gone are each one event; an older read of the server (another of its
// databases, imported late) changes nothing; an Activity Log operation is stored once - one row per operation (its
// correlationId) however many of its events (Started, Accepted, Succeeded) and reads carry it, at its first event's
// time, with its newest status; a role change that flips the partners' roles is no 'partner' event; a moved primary
// is critical; the instance that read the server removed, the server's events stay.
func TestFailoverGroupsOnAStore(t *testing.T) {
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
	ids := make([]int, 2)
	for i := range ids {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("fg-%d-%d", i, time.Now().UnixNano()%1000000000)).Scan(&ids[i]); err != nil {
			t.Fatal(err)
		}
	}
	key := fmt.Sprintf("s/g/pgv-%d", time.Now().UnixNano()%1000000000)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_failover_groups WHERE server_key = $1`, key)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_failover_group_events WHERE server_key = $1`, key)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_failover_group_reads WHERE server_key = $1`, key)
		for _, id := range ids {
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id)
		}
	}()
	group := func(role, policy string) map[string]any {
		partnerRole := "Secondary"
		if role == "Secondary" {
			partnerRole = "Primary" // a failover flips both ends
		}
		return map[string]any{"kind": "group", "group_name": "fg1", "role": role, "replication_state": "CATCH_UP", "secondary_type": "Geo",
			"rw_policy": policy, "grace_minutes": 60, "ro_policy": "Disabled", "ro_target": "",
			"partners": `[{"server":"pgv-b","location":"East US","role":"` + partnerRole + `"}]`, "databases": `["db1"]`}
	}
	imp := func(id int, at time.Time, rows ...map[string]any) {
		t.Helper()
		rows = append([]map[string]any{{"kind": "read", "server_key": key, "cloud": ""}}, rows...)
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_failover_groups($1, $2, $3::jsonb)`, id, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	events := func(kind string) int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.mssql_failover_group_events WHERE server_key = $1 AND kind = $2`, key, kind).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	now := time.Now().UTC().Truncate(time.Second)
	imp(ids[0], now.Add(-10*time.Minute), group("Primary", "Manual"))
	imp(ids[1], now.Add(-5*time.Minute), group("Primary", "Automatic"))
	if events("policy") != 1 {
		t.Fatalf("policy change read through another database: %d events", events("policy"))
	}
	imp(ids[0], now.Add(-7*time.Minute), group("Secondary", "Manual")) // an older read of the server, imported late
	if events("role") != 0 {
		t.Fatal("a late older read made a role event")
	}
	opEvent := func(id, status string, at time.Time) map[string]any {
		return map[string]any{"kind": "operation", "event_id": id, "correlation_id": "c1", "at": at.Format(time.RFC3339), "operation": "failover",
			"status": status, "group_name": "fg1"}
	}
	started, accepted, succeeded := now.Add(-3*time.Minute), now.Add(-2*time.Minute), now.Add(-time.Minute)
	// the first read sees the operation Started; the next sees its three events (the log's window is two hours)
	imp(ids[0], now, group("Secondary", "Automatic"), opEvent("e1", "Started", started))
	imp(ids[0], now.Add(time.Second), group("Secondary", "Automatic"), opEvent("e1", "Started", started), opEvent("e2", "Accepted", accepted),
		opEvent("e3", "Succeeded", succeeded))
	if events("role") != 1 || events("operation") != 1 {
		t.Fatalf("role %d operation %d, want 1 and 1 (one operation, however many of its events)", events("role"), events("operation"))
	}
	var opAt time.Time
	var opStatus string
	if err := pool.QueryRow(ctx, `SELECT at, old_value FROM pgvigil.mssql_failover_group_events WHERE server_key = $1 AND kind = 'operation'`, key).Scan(&opAt, &opStatus); err != nil ||
		!opAt.Equal(started) || opStatus != "Succeeded" {
		t.Errorf("the operation row: at %v status %q (%v), want its first event's time %v and its newest status Succeeded", opAt, opStatus, err, started)
	}
	if n := events("partner"); n != 0 {
		t.Errorf("a failover (both ends' roles flipped) made %d 'partner' events, want 0: the role event says it", n)
	}
	var sev string
	if err := pool.QueryRow(ctx, `SELECT severity FROM pgvigil.mssql_georepl_findings WHERE instance_id = $1 AND check_name = 'failover group primary moved'`, ids[0]).Scan(&sev); err != nil || sev != "critical" {
		t.Errorf("failover group primary moved: %q %v, want critical", sev, err)
	}
	imp(ids[0], now.Add(2*time.Second))
	if events("removed") != 1 {
		t.Fatalf("a group gone: %d removed events", events("removed"))
	}
	// the instance whose reads saw the server's events removed: the server's history stays
	var before, after int
	_ = pool.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.mssql_failover_group_events WHERE server_key = $1`, key).Scan(&before)
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.instances WHERE instance_id = $1`, ids[0]); err != nil {
		t.Fatal(err)
	}
	_ = pool.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.mssql_failover_group_events WHERE server_key = $1`, key).Scan(&after)
	if before == 0 || after != before {
		t.Errorf("the reading instance removed: the server's events %d -> %d, want them kept", before, after)
	}
}
