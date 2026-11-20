package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The findings view's rules, as rows on a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it); each row names
// the broken variant it catches. At the default tiers (warning 600 s, critical 1800 s, every datapoint of 10 minutes):
// the lowest datapoint decides (not max or avg), minutes are compared as seconds (x60), the datapoints must span the
// 10 minutes, a critical row, a stale resource row fires nothing; a critical-only threshold fires; 'lag missing'
// counts from 'available', not from first sight; a blank replication status keeps the reported one; a replica removed
// twice in 24 hours is one finding row; a reader whose own read is stale (its door switched off) gets no finding of a
// resource another instance keeps fresh; 'stopped' counts its 5 minutes from when the replica is available again,
// not from a read taken while it was rebooting.
func TestCloudReplicaFindingsFoldB(t *testing.T) {
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
	for _, n := range []string{"a", "b", "c", "d"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'rds', '16.4', 160004, false, '{}'::text[], 'postgres')`,
			fmt.Sprintf("cfb-%s-%d", n, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
	}
	rid := func(n string) string { return fmt.Sprintf("fb%d-%s", sfx, n) }
	var all []string
	for _, n := range []string{"src", "min", "x60", "crit", "warn", "span", "stale", "new", "old", "status", "dup", "srcb", "critonly", "srcc", "rc", "boot", "boot2"} {
		all = append(all, rid(n))
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.cloud_replica_sample WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replica_events WHERE resource_id = ANY($1)`,
			`DELETE FROM pgvigil.cloud_replica_reads WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replicas WHERE resource_id = ANY($1)`} {
			if _, err := pool.Exec(context.Background(), q, all); err != nil {
				t.Error(err)
			}
		}
		for _, id := range ids {
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.pg_thresholds WHERE instance_id = $1`, id)
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id)
		}
	}()
	res := func(n, role, source string, replicas []string, status, repl string) map[string]any {
		if replicas == nil {
			replicas = []string{}
		}
		src := ""
		if source != "" {
			src = rid(source)
		}
		return map[string]any{"kind": "resource", "provider": "aws", "resource_id": rid(n), "engine": "postgres", "region": "us-east-2", "role": role,
			"source_id": src, "replica_ids": replicas, "status": status, "repl_status": repl, "repl_note": ""}
	}
	now := time.Now().UTC().Truncate(time.Minute)
	// pts: a datapoint a minute over the 10 minutes to now (11 points), or the last 5 minutes only
	pts := func(n string, v float64, span int, low float64) []map[string]any {
		var out []map[string]any
		for m := span; m >= 0; m-- {
			x := v
			if m == 3 && low > 0 {
				x = low
			}
			out = append(out, map[string]any{"kind": "point", "provider": "aws", "resource_id": rid(n), "metric": "replica_lag", "unit": "s",
				"at": now.Add(-time.Duration(m) * time.Minute).Format(time.RFC3339), "value": x})
		}
		return out
	}
	imp := func(who string, at time.Time, self string, rows ...map[string]any) {
		t.Helper()
		rows = append([]map[string]any{{"kind": "read", "provider": "aws", "resource_id": rid(self)}}, rows...)
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_cloud_replicas($1, $2, $3::jsonb)`, ids[who], at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	rows := func(who, check, n string) []string {
		t.Helper()
		r, err := pool.Query(ctx, `SELECT severity FROM pgvigil.cloud_replica_findings WHERE instance_id = $1 AND check_name = $2 AND object = $3`,
			ids[who], check, rid(n))
		if err != nil {
			t.Fatal(err)
		}
		out, err := pgx.CollectRows(r, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	one := func(who, check, n, want, what string) {
		t.Helper()
		got := rows(who, check, n)
		switch {
		case want == "" && len(got) != 0:
			t.Errorf("%s: %v, want no row", what, got)
		case want != "" && (len(got) != 1 || got[0] != want):
			t.Errorf("%s: %v, want one %s row", what, got, want)
		}
	}
	reps := func(n ...string) []string {
		var out []string
		for _, x := range n {
			out = append(out, rid(x))
		}
		return out
	}
	// instance a reads src; its replicas over six reads
	listed := []string{"min", "x60", "crit", "warn", "span", "stale", "new", "old", "status", "boot", "boot2"}
	srcRow := func(dup bool) map[string]any {
		l := listed
		if dup {
			l = append(append([]string{}, listed...), "dup")
		}
		return res("src", "source", "", reps(l...), "available", "")
	}
	imp("a", now.Add(-30*time.Minute), "src", srcRow(true), res("new", "replica", "src", nil, "creating", ""), res("old", "replica", "src", nil, "available", ""),
		res("dup", "replica", "src", nil, "available", ""), res("boot2", "replica", "src", nil, "rebooting", "error"))
	imp("a", now.Add(-20*time.Minute), "src", srcRow(true), res("stale", "replica", "src", nil, "available", ""), res("new", "replica", "src", nil, "creating", ""),
		res("old", "replica", "src", nil, "available", ""), res("dup", "replica", "src", nil, "available", ""),
		res("boot", "replica", "src", nil, "rebooting", "error"), res("boot2", "replica", "src", nil, "available", "error"))
	// 'status' reports error 8 minutes before the last read: 'stopped' needs the status to have stood 5 minutes
	imp("a", now.Add(-8*time.Minute), "src", srcRow(false), res("status", "replica", "src", nil, "available", "error"))
	imp("a", now.Add(-2*time.Minute), "src", srcRow(true), res("dup", "replica", "src", nil, "available", ""), res("boot", "replica", "src", nil, "available", "error"))
	imp("a", now.Add(-time.Minute), "src", srcRow(false))
	last := []map[string]any{srcRow(false), res("min", "replica", "src", nil, "available", ""), res("x60", "replica", "src", nil, "available", ""),
		res("crit", "replica", "src", nil, "available", ""), res("warn", "replica", "src", nil, "available", ""), res("span", "replica", "src", nil, "available", ""),
		res("new", "replica", "src", nil, "available", ""), res("old", "replica", "src", nil, "available", ""), res("status", "replica", "src", nil, "available", ""),
		res("boot", "replica", "src", nil, "available", "error"), res("boot2", "replica", "src", nil, "available", "error")}
	last = append(last, pts("min", 700, 10, 500)...)
	last = append(last, pts("x60", 500, 10, 0)...)
	last = append(last, pts("crit", 1900, 10, 0)...)
	last = append(last, pts("warn", 700, 10, 0)...)
	last = append(last, pts("span", 700, 5, 0)...)
	last = append(last, pts("stale", 700, 10, 0)...)
	imp("a", now, "src", last...)

	one("a", "provider replica lag", "warn", "warning", "700 s in every datapoint (the sanity row)")
	one("a", "provider replica lag", "min", "", "700 s with one datapoint at 500 s (max or avg in place of min)")
	one("a", "provider replica lag", "x60", "", "500 s against a 10-minute tier (minutes compared as seconds)")
	one("a", "provider replica lag", "crit", "critical", "1900 s against a 30-minute critical tier")
	one("a", "provider replica lag", "span", "", "datapoints over 5 of the 10 minutes (no span check)")
	one("a", "provider replica lag", "stale", "", "a resource row 20 minutes old with fresh datapoints (a stale row firing)")
	one("a", "provider lag missing", "new", "", "a replica seen 30 minutes ago while creating, available since this read (first sight, not 'available')")
	one("a", "provider lag missing", "old", "warning", "a replica available for 30 minutes with no datapoint (the sanity row)")
	one("a", "provider replica stopped", "status", "critical", "replication 'error' 8 minutes ago, then a read that reports none (a blank wiping a reported status or its time)")
	one("a", "provider replica stopped", "boot", "", "error seen 20 minutes ago while rebooting, available 2 minutes (the 5 minutes counted from a rebooting read)")
	one("a", "provider replica stopped", "boot2", "critical", "error seen 30 minutes ago while rebooting, available with error for 20 (the sanity row)")
	var st string
	if err := pool.QueryRow(ctx, `SELECT repl_status FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = $1`, rid("status")).Scan(&st); err != nil {
		t.Fatal(err)
	}
	if st != "error" {
		t.Errorf("the replication status after a blank read: %q, want 'error' kept", st)
	}
	if got := rows("a", "replica promoted or detached", "dup"); len(got) != 1 {
		t.Errorf("a replica removed twice in 24 hours: %d finding rows, want 1 (one row per instance, check and object)", len(got))
	}

	// instance b: warn null, critical 30 minutes at its own level
	var out string
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_pg_threshold(now(), $1::jsonb)::text`,
		fmt.Sprintf(`{"op": "set", "key": "provider_replica_lag", "level": "instance", "instance_id": %d, "warn": null, "crit": 30, "ui_user": "test"}`, ids["b"])).Scan(&out); err != nil {
		t.Fatal(err)
	}
	imp("b", now, "srcb", append([]map[string]any{res("srcb", "source", "", reps("critonly"), "available", ""), res("critonly", "replica", "srcb", nil, "available", "")},
		pts("critonly", 1900, 10, 0)...)...)
	one("b", "provider replica lag", "critonly", "critical", "a critical-only threshold (warn null) and 1900 s ("+out+")")

	// instance c read srcc 20 minutes ago and stopped (its door off); instance d reads rc, fresh, lagging
	imp("c", now.Add(-20*time.Minute), "srcc", res("srcc", "source", "", reps("rc"), "available", ""), res("rc", "replica", "srcc", nil, "available", ""))
	imp("d", now, "rc", append([]map[string]any{res("rc", "replica", "srcc", nil, "available", "")}, pts("rc", 700, 10, 0)...)...)
	one("d", "provider replica lag", "rc", "warning", "the instance whose fresh read covers rc (the sanity row)")
	one("c", "provider replica lag", "rc", "", "an instance whose own read is 20 minutes old (its door switched off)")
}

// A provider failover's cover, over 0155's instance_events or a stand-in of its shape, in one transaction rolled
// back: one shared test decides whether a read's event covers a provider failover -
// the event inside [the newest start within 30 minutes (else the completion - 15 minutes) - 10 minutes, the completion
// + 10 minutes], or the completion inside the event's read window (prev_at, seen_at] - in the conversion, the provider
// row's delete and its insert. Each row names the broken variant it catches.
func TestCloudFailoverCoverFoldB(t *testing.T) {
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
	now := time.Now().UTC().Truncate(time.Minute)
	cases := []struct {
		what   string
		phases [][2]any // offset from c in minutes, phase
		events func(id int, c time.Time) error
		want   string // the one failover row's source prefix; "" = no failover row at all
		rows   int    // instance_events rows of kind failover
	}{
		{"an RDS SQL Server Multi-AZ failover the hourly instance read dated 40 minutes late (outside [c-15, c+10], c inside its read window)",
			[][2]any{{-2, "started"}, {0, "completed"}},
			func(id int, c time.Time) error {
				_, err := tx.Exec(ctx, `INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
				  VALUES ($1, $2, 'failover', 'node a', 'node b', 'mssql_instance', $2, $3)`, id, c.Add(40*time.Minute), c.Add(-20*time.Minute))
				return err
			}, "rds events: Multi-AZ instance failover completed.", 1},
		{"a failover started 18 minutes before its completion, the read's restart 2 minutes after the start (outside the completion's [c-15, c+10])",
			[][2]any{{-18, "started"}, {0, "completed"}},
			func(id int, c time.Time) error {
				_, err := tx.Exec(ctx, `INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
				  VALUES ($1, $2, 'restart', '10.0.0.1 x', '10.0.0.2 y', 'instance_state', $2, $2::timestamptz - interval '5 minutes')`, id, c.Add(-16*time.Minute))
				return err
			}, "rds events: Multi-AZ instance failover completed.", 1},
		{"no start event, the read's restart 14 minutes before the completion (the gap between the conversion's 10 and the delete's 15 minutes)",
			[][2]any{{0, "completed"}},
			func(id int, c time.Time) error {
				_, err := tx.Exec(ctx, `INSERT INTO pgvigil.instance_events (instance_id, at, kind, old_value, new_value, source, seen_at, prev_at)
				  VALUES ($1, $2, 'restart', '10.0.0.1 x', '10.0.0.2 y', 'instance_state', $2, $2::timestamptz - interval '5 minutes')`, id, c.Add(-14*time.Minute))
				return err
			}, "rds events: Multi-AZ instance failover completed.", 1},
		{"both completion messages (RDS-EVENT-0015 and 0049) 3 minutes apart, no read event (a second completion counted as a second failover)",
			[][2]any{{-3, "started"}, {0, "completed"}, {3, "completed2"}},
			func(int, time.Time) error { return nil }, "rds events", 1},
		{"a failover 3 days old at the instance's first read (the first read of events stored before 0155: a 1-day look-back)",
			[][2]any{{-2, "started"}, {0, "completed"}},
			func(int, time.Time) error { return nil }, "rds events", 1},
	}
	for i, k := range cases {
		var id int
		if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'rds', '16.4', 160004, false, '{}'::text[], 'postgres')`,
			fmt.Sprintf("cfc-%d-%d", i, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		self := fmt.Sprintf("cfc%d-%d", i, sfx)
		c := now.Add(-2 * time.Hour)
		if i == 4 {
			c = now.Add(-72 * time.Hour)
		}
		if err := k.events(id, c); err != nil {
			t.Fatal(err)
		}
		rows := []map[string]any{{"kind": "read", "provider": "aws", "resource_id": self},
			{"kind": "resource", "provider": "aws", "resource_id": self, "role": "standalone", "replica_ids": []string{}, "status": "available"}}
		for _, p := range k.phases {
			phase, msg := p[1].(string), "Multi-AZ instance failover started."
			switch phase {
			case "completed":
				msg = "Multi-AZ instance failover completed."
			case "completed2":
				phase, msg = "completed", "Multi-AZ failover to standby complete - DNS may take several minutes to switch over."
			}
			rows = append(rows, map[string]any{"kind": "failover", "provider": "aws", "resource_id": self, "phase": phase, "message": msg, "source": "rds events",
				"at": c.Add(time.Duration(p[0].(int)) * time.Minute).Format(time.RFC3339)})
		}
		b, _ := json.Marshal(rows)
		for _, at := range []time.Time{now, now.Add(time.Minute)} { // the same window read twice
			if _, err := tx.Exec(ctx, `SELECT pgvigil.import_cloud_replicas($1, $2, $3::jsonb)`, id, at, string(b)); err != nil {
				t.Fatalf("%s: %v", k.what, err)
			}
		}
		var n, restarts int
		var src string
		if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE kind = 'failover')::int, count(*) FILTER (WHERE kind = 'restart')::int,
		    coalesce(max(source) FILTER (WHERE kind = 'failover'), '') FROM pgvigil.instance_events WHERE instance_id = $1`, id).Scan(&n, &restarts, &src); err != nil {
			t.Fatal(err)
		}
		if n != k.rows || restarts != 0 || src != k.want {
			t.Errorf("%s: %d failover, %d restart rows, source %q; want %d, 0 and %q", k.what, n, restarts, src, k.rows, k.want)
		}
	}
}
