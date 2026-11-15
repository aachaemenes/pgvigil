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

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0151's provider replicas (task 390b): a resource is
// one row whoever reads it (a source and its replica both monitored read the same chain); an older read imported late
// stores its datapoints and leaves the rows; one sample per datapoint (a window read twice adds nothing; a newer
// read's value replaces an older read's: CloudWatch revises a minute's Maximum); a replica
// added to a known source, a status change, and a promotion are each one event; the cascaded marker; the findings at
// the DEFAULT tiers (provider_replica_lag warning 600 s, critical 1800 s, every datapoint of 10 minutes), 'stopped' only
// on an available replica whose reported status other than replicating has stood 5 minutes (a read at least 5 minutes
// after the one that first saw it; fold 9: a blank status is 'not reported yet'), 'lag
// missing' after 15 minutes without a datapoint on an available replica, a promotion a warning for 24 hours - each on
// every instance that reads the resource. Each row names the broken variant it catches.
func TestCloudReplicasOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	ids := map[string]int{}
	for _, n := range []string{"src", "rep"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'rds', '16.4', 160004, false, '{}'::text[], 'postgres')`,
			fmt.Sprintf("crep-%s-%d", n, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
	}
	db1, r1, r1a := fmt.Sprintf("db%d", sfx), fmt.Sprintf("db%d-r1", sfx), fmt.Sprintf("db%d-r1a", sfx)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.cloud_replica_sample WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replica_events WHERE resource_id = ANY($1)`,
			`DELETE FROM pgvigil.cloud_replica_reads WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replicas WHERE resource_id = ANY($1)`} {
			if _, err := pool.Exec(context.Background(), q, []string{db1, r1, r1a}); err != nil {
				t.Error(err)
			}
		}
		for _, id := range ids {
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id)
		}
	}()
	res := func(id, role, source string, replicas []string, status, repl string) map[string]any {
		if replicas == nil {
			replicas = []string{}
		}
		return map[string]any{"kind": "resource", "provider": "aws", "resource_id": id, "engine": "postgres", "region": "us-east-2", "role": role,
			"source_id": source, "replica_ids": replicas, "cascaded": role == "replica" && len(replicas) > 0, "status": status, "repl_status": repl, "repl_note": ""}
	}
	point := func(id string, at time.Time, v float64) map[string]any {
		return map[string]any{"kind": "point", "provider": "aws", "resource_id": id, "metric": "replica_lag", "unit": "s", "at": at.Format(time.RFC3339), "value": v}
	}
	imp := func(who string, at time.Time, self string, rows ...map[string]any) {
		t.Helper()
		rows = append([]map[string]any{{"kind": "read", "provider": "aws", "resource_id": self}}, rows...)
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_cloud_replicas($1, $2, $3::jsonb)`, ids[who], at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	n := func(q string, args ...any) int {
		t.Helper()
		var v int
		if err := pool.QueryRow(ctx, q, args...).Scan(&v); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return v
	}
	events := func(id, kind string) int {
		return n(`SELECT count(*)::int FROM pgvigil.cloud_replica_events WHERE provider = 'aws' AND resource_id = $1 AND kind = $2`, id, kind)
	}
	finding := func(who, check, object string) string {
		t.Helper()
		var sev string
		err := pool.QueryRow(ctx, `SELECT coalesce(max(severity), '') FROM pgvigil.cloud_replica_findings WHERE instance_id = $1 AND check_name = $2 AND object = $3`,
			ids[who], check, object).Scan(&sev)
		if err != nil {
			t.Fatal(err)
		}
		return sev
	}
	now := time.Now().UTC().Truncate(time.Minute)

	// the source's read: db1 and its replica r1 (status not reported yet), r1's lag 5 s each minute of 20
	var pts []map[string]any
	for m := 20; m >= 1; m-- {
		pts = append(pts, point(r1, now.Add(-time.Duration(m)*time.Minute), 5))
	}
	imp("src", now.Add(-time.Minute), db1, append([]map[string]any{res(db1, "source", "", []string{r1}, "available", ""), res(r1, "replica", db1, nil, "available", "")}, pts...)...)
	if c := n(`SELECT count(*)::int FROM pgvigil.cloud_replicas WHERE resource_id = ANY($1)`, []string{db1, r1}); c != 2 {
		t.Fatalf("%d resource rows, want 2", c)
	}
	// the replica's own read of the same chain, a minute later, the same datapoints and one more: one row each
	imp("rep", now, r1, append([]map[string]any{res(r1, "replica", db1, nil, "available", ""), res(db1, "source", "", []string{r1}, "available", "")},
		append(pts, point(r1, now, 5))...)...)
	if c := n(`SELECT count(*)::int FROM pgvigil.cloud_replica_sample WHERE resource_id = $1`, r1); c != 21 {
		t.Errorf("%d samples of r1, want 21 (one a datapoint, whoever read it)", c)
	}
	if c := n(`SELECT count(*)::int FROM pgvigil.cloud_replicas WHERE resource_id = ANY($1)`, []string{db1, r1}); c != 2 {
		t.Errorf("%d resource rows after both reads, want 2 (a resource stored once)", c)
	}
	if s := finding("src", "provider replica stopped", r1); s != "" {
		t.Errorf("a replica whose status is not reported yet: stopped %q, want none (fold 9)", s)
	}
	if s := finding("src", "provider replica lag", r1); s != "" {
		t.Errorf("a 5 s lag at the defaults: %q, want none", s)
	}
	// an older read of the source imported late: the rows stand (a status from it would be stale), its datapoint stored
	imp("src", now.Add(-10*time.Minute), db1, res(db1, "source", "", nil, "available", ""), point(r1, now.Add(-25*time.Minute), 5))
	if c := n(`SELECT cardinality(replica_ids) FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = $1`, db1); c != 1 {
		t.Errorf("an older read changed db1's replicas: %d, want 1", c)
	}
	if c := events(r1, "removed"); c != 0 {
		t.Errorf("an older read made %d 'removed' events", c)
	}
	if c := n(`SELECT count(*)::int FROM pgvigil.cloud_replica_sample WHERE resource_id = $1`, r1); c != 22 {
		t.Errorf("the older read's datapoint: %d samples, want 22", c)
	}

	// a lag over the warning tier in every datapoint of 10 minutes (a newer read's values over the same minutes):
	// warning on both readers
	pts = nil
	for m := 10; m >= 0; m-- {
		pts = append(pts, point(r1, now.Add(time.Minute-time.Duration(m)*time.Minute), 700))
	}
	imp("rep", now.Add(time.Minute), r1, append([]map[string]any{res(r1, "replica", db1, []string{r1a}, "available", "replicating"),
		res(db1, "source", "", []string{r1}, "available", ""), res(r1a, "replica", r1, nil, "available", "replicating")}, pts...)...)
	for _, who := range []string{"src", "rep"} {
		if s := finding(who, "provider replica lag", r1); s != "warning" {
			t.Errorf("700 s for 10 minutes, read by %s: %q, want warning (the default 600 s)", who, s)
		}
	}
	if c := n(`SELECT CASE WHEN cascaded THEN 1 ELSE 0 END FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = $1`, r1); c != 1 {
		t.Error("r1 replicates to r1a: not marked cascaded")
	}
	if c := events(r1, "added"); c != 1 {
		t.Errorf("r1a added to r1: %d 'added' events on r1, want 1", c)
	}

	// replication stopped (error) on an available replica: the rule is by time, not by reads - RDS itself reports
	// 'Replication has stopped.' for about 2.5 minutes after a replica's reboot (lab RP 2026-11-15), so a status that
	// has stood under 5 minutes is no finding however many reads saw it; a status that changed and came back starts
	// its 5 minutes again; a read 6 minutes after the one that first saw it: critical
	imp("rep", now.Add(2*time.Minute), r1, res(r1, "replica", db1, []string{r1a}, "available", "error"))
	if s := finding("rep", "provider replica stopped", r1); s != "" {
		t.Errorf("one read with error: %q, want none", s)
	}
	imp("rep", now.Add(3*time.Minute), r1, res(r1, "replica", db1, []string{r1a}, "available", "error"))
	if s := finding("rep", "provider replica stopped", r1); s != "" {
		t.Errorf("error in two reads 1 minute apart: %q, want none until it has stood 5 minutes (a rule by reads, not by time)", s)
	}
	imp("rep", now.Add(4*time.Minute), r1, res(r1, "replica", db1, []string{r1a}, "available", "replicating"))
	if s := finding("rep", "provider replica stopped", r1); s != "" {
		t.Errorf("replicating again: %q, want none", s)
	}
	imp("rep", now.Add(5*time.Minute), r1, res(r1, "replica", db1, []string{r1a}, "available", "error"))
	imp("rep", now.Add(9*time.Minute), r1, res(r1, "replica", db1, []string{r1a}, "available", "error"))
	if s := finding("rep", "provider replica stopped", r1); s != "" {
		t.Errorf("a second stop 4 minutes old, 7 after the first: %q, want none (the time counted from the first stop, not from this one)", s)
	}
	imp("rep", now.Add(11*time.Minute), r1, res(r1, "replica", db1, []string{r1a}, "available", "error"))
	if s := finding("rep", "provider replica stopped", r1); s != "critical" {
		t.Errorf("error in reads 6 minutes apart: %q, want critical", s)
	}
	if c := events(r1, "status"); c != 4 {
		t.Errorf("r1's replication status '' -> replicating -> error -> replicating -> error: %d 'status' events, want 4", c)
	}
	// r1a available and reported, no datapoint: none while it is new (a replica being made), a warning once it has been
	// seen 15 minutes with none (its first sighting moved back, as the clock would)
	if s := finding("rep", "provider lag missing", r1a); s != "" {
		t.Errorf("r1a seen 3 minutes ago with no datapoint yet: %q, want none", s)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.cloud_replicas SET first_seen_at = first_seen_at - interval '20 minutes', status_since = status_since - interval '20 minutes' WHERE provider = 'aws' AND resource_id = $1`, r1a); err != nil {
		t.Fatal(err)
	}
	if s := finding("rep", "provider lag missing", r1a); s != "warning" {
		t.Errorf("r1a seen 20 minutes with no lag datapoint: %q, want warning", s)
	}
	// r1 promoted: a standalone instance now, its source no longer lists it - 'promoted', a warning for 24 hours
	imp("rep", now.Add(12*time.Minute), r1, res(r1, "standalone", "", nil, "available", ""))
	imp("src", now.Add(13*time.Minute), db1, res(db1, "standalone", "", nil, "available", ""))
	if c := events(r1, "promoted"); c != 1 {
		t.Errorf("r1 promoted: %d 'promoted' events, want 1", c)
	}
	if s := finding("rep", "replica promoted or detached", r1); s != "warning" {
		t.Errorf("r1 promoted: %q, want warning", s)
	}
	if s := finding("rep", "provider replica stopped", r1); s != "" {
		t.Errorf("a promoted (standalone) instance is no stopped replica: %q", s)
	}
}
