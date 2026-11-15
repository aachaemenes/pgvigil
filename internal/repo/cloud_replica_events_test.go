package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), P3 (task 390b task 14): the provider's own failover
// events (RDS DescribeEvents, Cloud SQL FAILOVER operations) handed to 404's instance_events (0155) - the provider's
// word wins: a 0155 'restart' of the instance within 10 minutes of a failover phase becomes 'failover' (its starts kept,
// the source the provider's with its words); a failover the reads missed is written as one at its completion; the same
// read twice writes nothing more; a 0155 restart arriving after the provider's own row replaces that row (one failover).
// All in one transaction rolled back, over 0155's instance_events or, on a base without 0155, a stand-in of its shape.
func TestCloudFailoverEventsOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if _, err := tx.Exec(ctx, `DO $$ BEGIN
	  IF to_regclass('pgvigil.instance_events') IS NULL THEN
	    CREATE TABLE pgvigil.instance_events (instance_id int NOT NULL, at timestamptz NOT NULL, kind text NOT NULL, old_value text,
	      new_value text, source text NOT NULL, seen_at timestamptz NOT NULL, prev_at timestamptz, PRIMARY KEY (instance_id, kind, at));
	  END IF; END $$`); err != nil {
		t.Fatal(err)
	}
	sfx := time.Now().UnixNano() % 1000000000
	var id int
	if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'rds', '16.4', 160004, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("cfo-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	self := fmt.Sprintf("db%d", sfx)
	now := time.Now().UTC().Truncate(time.Minute)
	fo := func(at time.Time, phase, msg string) map[string]any {
		return map[string]any{"kind": "failover", "provider": "aws", "resource_id": self, "at": at.Format(time.RFC3339), "phase": phase,
			"message": msg, "source": "rds events"}
	}
	imp := func(at time.Time, rows ...map[string]any) {
		t.Helper()
		rows = append([]map[string]any{{"kind": "read", "provider": "aws", "resource_id": self},
			{"kind": "resource", "provider": "aws", "resource_id": self, "role": "standalone", "replica_ids": []string{}, "status": "available"}}, rows...)
		p, _ := json.Marshal(rows)
		if _, err := tx.Exec(ctx, `SELECT pgvigil.import_cloud_replicas($1, $2, $3::jsonb)`, id, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	restart := func(at time.Time) {
		t.Helper()
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
		  VALUES ($1, $2, 'restart', '10.0.0.1 2026-11-01 00:00', $3, 'instance_state', $2, $2 - interval '5 minutes')`, id, at, "10.0.0.2 "+at.Format(time.RFC3339)); err != nil {
			t.Fatal(err)
		}
	}
	count := func(kind string) int {
		t.Helper()
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.instance_events WHERE instance_id = $1 AND kind = $2`, id, kind).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	// a Multi-AZ failover the instance's read saw as a restart: the provider's word wins
	restart(now.Add(-29 * time.Minute))
	a := []map[string]any{fo(now.Add(-30*time.Minute), "started", "Multi-AZ instance failover started."),
		fo(now.Add(-28*time.Minute), "completed", "Multi-AZ instance failover completed.")}
	imp(now, a...)
	if r, f := count("restart"), count("failover"); r != 0 || f != 1 {
		t.Fatalf("a restart inside the provider's failover: %d restart, %d failover, want 0 and 1", r, f)
	}
	var src, newValue string
	if err := tx.QueryRow(ctx, `SELECT source, new_value FROM pgvigil.instance_events WHERE instance_id = $1 AND kind = 'failover'`, id).Scan(&src, &newValue); err != nil {
		t.Fatal(err)
	}
	if src != "rds events: Multi-AZ instance failover completed." || newValue == "" {
		t.Errorf("the converted row: source %q new %q, want the provider's source and words, the read's starts kept", src, newValue)
	}
	// a failover no read saw (the instance's reads both on the new node, or none between): written at its completion
	b := []map[string]any{fo(now.Add(-100*time.Minute), "started", "Multi-AZ instance failover started."),
		fo(now.Add(-98*time.Minute), "completed", "Multi-AZ instance failover completed.")}
	imp(now.Add(time.Minute), append(a, b...)...)
	imp(now.Add(2*time.Minute), append(a, b...)...) // the same window read again
	if f := count("failover"); f != 2 {
		t.Errorf("a missed failover and a second read: %d failover rows, want 2", f)
	}
	var at time.Time
	if err := tx.QueryRow(ctx, `SELECT at FROM pgvigil.instance_events WHERE instance_id = $1 AND kind = 'failover' AND old_value IS NULL`, id).Scan(&at); err != nil {
		t.Fatal(err)
	}
	if !at.Equal(now.Add(-98 * time.Minute)) {
		t.Errorf("the missed failover at %s, want its completion %s", at, now.Add(-98*time.Minute))
	}
	// the read's restart of that failover arrives late: it becomes the failover, the provider's own row goes
	restart(now.Add(-99 * time.Minute))
	imp(now.Add(3*time.Minute), append(a, b...)...)
	if r, f := count("restart"), count("failover"); r != 0 || f != 2 {
		t.Errorf("a late restart inside the missed failover: %d restart, %d failover, want 0 and 2", r, f)
	}
	// a restart far from any failover stays a restart
	restart(now.Add(-60 * time.Minute))
	imp(now.Add(4*time.Minute), append(a, b...)...)
	if r := count("restart"); r != 1 {
		t.Errorf("a restart 30 minutes from any failover phase: %d restart rows, want 1", r)
	}
}
