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

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0151's hours (task 390b task 7, in B2a-N2's 0167
// shape): cloud_replica_hour per provider resource, metric and UTC hour (points, total, min, max) from
// cloud_replica_sample, and mssql_georepl_hour per instance, link and hour (the lag's and the unsent window's reads,
// totals, minima, maxima) from mssql_georepl_sample, each filled by a statement trigger that RECOMPUTES the touched
// hours. Each hour equals its samples (computed here apart); a newer read's revised value (the samples' UPDATE path)
// and a late datapoint in an old hour recompute it; a dirty range over a corrupted hour is rebuilt by heal_one (the
// failure path itself, 'rollup failed' and its heal by the next import, is 0167's code shape, not repeated here); hours
// are UTC under a +05:30 session; each window function's rows summed equal the samples of the window (inside
// one hour, across its edges, over two days, and over a dirty range). Each row names the broken variant it catches.
func TestCloudReplicaHoursOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	// every import under a +05:30 session (a trigger truncating hours in the session's zone passes when only the last
	// SELECT runs in it)
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["timezone"] = "Asia/Kolkata"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sfx := time.Now().UnixNano() % 1000000000
	var id, ms int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'rds', '16.4', 160004, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("crh-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("crh-ms-%d", sfx)).Scan(&ms); err != nil {
		t.Fatal(err)
	}
	src, rep := fmt.Sprintf("hsrc%d", sfx), fmt.Sprintf("hrep%d", sfx)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.cloud_replica_sample WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replica_hour WHERE resource_id = ANY($1)`,
			`DELETE FROM pgvigil.cloud_replica_hour_dirty WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replicas WHERE resource_id = ANY($1)`} {
			if _, err := pool.Exec(context.Background(), q, []string{src, rep}); err != nil {
				t.Error(err)
			}
		}
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_georepl_sample WHERE instance_id = $1`, ms)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_georepl_hour WHERE instance_id = $1`, ms)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`, []int{id, ms})
	}()
	// a fixed past day, whole hours (the test's own month made by the trigger when purge has not)
	h0 := time.Now().UTC().Truncate(time.Hour).Add(-48 * time.Hour)
	imp := func(at time.Time, pts map[time.Time]float64) {
		t.Helper()
		rows := []map[string]any{{"kind": "read", "provider": "aws", "resource_id": rep},
			{"kind": "resource", "provider": "aws", "resource_id": rep, "role": "replica", "source_id": src, "replica_ids": []string{}, "status": "available"}}
		for ts, v := range pts {
			rows = append(rows, map[string]any{"kind": "point", "provider": "aws", "resource_id": rep, "metric": "replica_lag", "unit": "s",
				"at": ts.Format(time.RFC3339), "value": v})
		}
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_cloud_replicas($1, $2, $3::jsonb)`, id, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	// 30 hours of a datapoint a minute, imported 20 minutes at a time, each read a minute after its last point
	for m := 0; m < 30*60; m += 20 {
		pts := map[time.Time]float64{}
		for k := m; k < m+20; k++ {
			pts[h0.Add(time.Duration(k)*time.Minute)] = float64((k*37)%101) + 0.25
		}
		imp(h0.Add(time.Duration(m+20)*time.Minute), pts)
	}
	// an hour row against its samples, computed apart
	hourOK := func(hour time.Time, why string) {
		t.Helper()
		var bad int
		err := pool.QueryRow(ctx, `
		  WITH s AS (SELECT count(*)::int AS n, sum(value) AS total, min(value) AS lo, max(value) AS hi FROM pgvigil.cloud_replica_sample
		              WHERE provider = 'aws' AND resource_id = $1 AND metric = 'replica_lag' AND snapshot_at >= $2 AND snapshot_at < $2 + interval '1 hour')
		  SELECT count(*)::int FROM s LEFT JOIN pgvigil.cloud_replica_hour h ON h.provider = 'aws' AND h.resource_id = $1 AND h.metric = 'replica_lag' AND h.snapshot_at = $2
		   WHERE h.points IS DISTINCT FROM s.n OR abs(h.total - s.total) > 1e-6 OR h.min_value IS DISTINCT FROM s.lo OR h.max_value IS DISTINCT FROM s.hi`,
			rep, hour).Scan(&bad)
		if err != nil {
			t.Fatal(err)
		}
		if bad != 0 {
			t.Errorf("the hour %s differs from its samples: %s", hour.Format(time.RFC3339), why)
		}
	}
	for _, k := range []int{0, 1, 13, 29} {
		hourOK(h0.Add(time.Duration(k)*time.Hour), "a trigger that adds instead of recomputing, or keys hours in the session's zone")
	}
	// a newer read revises a datapoint (CloudWatch's Maximum moves): the UPDATE path recomputes its hour
	imp(h0.Add(3*time.Hour), map[time.Time]float64{h0.Add(2*time.Hour + 5*time.Minute): 999})
	hourOK(h0.Add(2*time.Hour), "a revised value (ON CONFLICT DO UPDATE) left out: an INSERT-only trigger")
	// a late datapoint in an old hour (a gap filled), the import's own read time later than all
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.cloud_replica_sample WHERE resource_id = $1 AND snapshot_at = $2`, rep, h0.Add(4*time.Hour+7*time.Minute)); err != nil {
		t.Fatal(err)
	}
	imp(h0.Add(40*time.Hour), map[time.Time]float64{h0.Add(4*time.Hour + 7*time.Minute): 55})
	hourOK(h0.Add(4*time.Hour), "a late datapoint in an old hour: a trigger that skips old hours")
	// a dirty range over a corrupted hour: heal_one rebuilds it (a heal that adds doubles it, one that does nothing keeps 0)
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.cloud_replica_hour SET points = 0, total = 0 WHERE resource_id = $1 AND snapshot_at = $2`, rep, h0.Add(6*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.cloud_replica_hour_dirty (provider, resource_id, from_at, to_at, why, instance_id) VALUES ('aws', $1, $2, $3, 'the test', $4)`,
		rep, h0.Add(6*time.Hour), h0.Add(7*time.Hour), id); err != nil {
		t.Fatal(err)
	}
	// the window over the dirty range reads its samples, not the corrupted hour
	winOK := func(from, to time.Time, why string) {
		t.Helper()
		var bad int
		err := pool.QueryRow(ctx, `
		  WITH w AS (SELECT sum(points)::int AS n, sum(total) AS total, min(min_value) AS lo, max(max_value) AS hi FROM pgvigil.cloud_replica_window('aws', ARRAY[$1], $2, $3) WHERE metric = 'replica_lag'),
		       s AS (SELECT count(*)::int AS n, sum(value) AS total, min(value) AS lo, max(value) AS hi FROM pgvigil.cloud_replica_sample
		              WHERE provider = 'aws' AND resource_id = $1 AND metric = 'replica_lag' AND snapshot_at >= $2 AND snapshot_at < $3)
		  SELECT count(*)::int FROM w, s WHERE w.n IS DISTINCT FROM s.n OR abs(w.total - s.total) > 1e-6 OR w.lo IS DISTINCT FROM s.lo OR w.hi IS DISTINCT FROM s.hi`,
			rep, from, to).Scan(&bad)
		if err != nil {
			t.Fatal(err)
		}
		if bad != 0 {
			t.Errorf("the window %s to %s differs from its samples: %s", from.Format(time.RFC3339), to.Format(time.RFC3339), why)
		}
	}
	winOK(h0.Add(5*time.Hour+30*time.Minute), h0.Add(8*time.Hour+10*time.Minute), "a dirty range read from its corrupted hour, or an edge lost or counted twice")
	if _, err := pool.Exec(ctx, `SELECT pgvigil.cloud_replica_hour_heal_one('aws', $1)`, rep); err != nil {
		t.Fatal(err)
	}
	hourOK(h0.Add(6*time.Hour), "a dirty range not rebuilt by heal_one")
	winOK(h0.Add(10*time.Minute), h0.Add(10*time.Minute+40*time.Second), "a window inside one hour")
	winOK(h0.Add(-2*time.Hour), h0.Add(31*time.Hour), "a window over the whole series")
	winOK(h0.Add(9*time.Hour+59*time.Minute), h0.Add(21*time.Hour+1*time.Minute), "the edges of a long window")
	// hours are UTC under a +05:30 session
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `SET TimeZone = 'Asia/Kolkata'`); err != nil {
		t.Fatal(err)
	}
	var odd int
	if err := conn.QueryRow(ctx, `SELECT count(*)::int FROM pgvigil.cloud_replica_hour WHERE resource_id = $1 AND extract(minute FROM snapshot_at AT TIME ZONE 'UTC') <> 0`, rep).Scan(&odd); err != nil {
		t.Fatal(err)
	}
	_, _ = conn.Exec(ctx, `RESET TimeZone`)
	conn.Release()
	if odd != 0 {
		t.Errorf("%d hour rows not on a UTC hour", odd)
	}

	// mssql_georepl_hour from 0151 part G's samples: two hours of reads a minute apart, on one link
	link := fmt.Sprintf("00000000-0000-0000-0000-%012d", sfx)
	for k := 0; k < 120; k++ {
		at := h0.Add(time.Duration(k) * time.Minute)
		p, _ := json.Marshal([]map[string]any{{"kind": "read", "server_read": "s1", "database_name": "d1", "links": 1},
			{"kind": "link", "link_guid": link, "partner_server": "s2", "partner_database": "d1", "role": 0, "role_desc": "PRIMARY",
				"replication_state": 2, "replication_state_desc": "CATCH_UP", "replication_lag_sec": k % 7, "unsent_s": float64(k%11) + 0.5}})
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_georepl($1, $2, $3::jsonb)`, ms, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	var bad int
	if err := pool.QueryRow(ctx, `
	  WITH s AS (SELECT date_trunc('hour', snapshot_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS h, count(*)::int AS n, sum(replication_lag_sec) AS lt,
	                    max(replication_lag_sec) AS lmax, sum(unsent_s) AS ut, max(unsent_s) AS umax
	               FROM pgvigil.mssql_georepl_sample WHERE instance_id = $1 GROUP BY 1)
	  SELECT count(*)::int FROM s LEFT JOIN pgvigil.mssql_georepl_hour g ON g.instance_id = $1 AND g.link_guid = $2 AND g.snapshot_at = s.h
	   WHERE g.reads IS DISTINCT FROM s.n OR g.lag_total IS DISTINCT FROM s.lt OR g.lag_max IS DISTINCT FROM s.lmax
	      OR g.unsent_total IS DISTINCT FROM s.ut OR g.unsent_max IS DISTINCT FROM s.umax`, ms, link).Scan(&bad); err != nil {
		t.Fatal(err)
	}
	if bad != 0 {
		t.Errorf("%d georepl hours differ from their samples", bad)
	}
	if err := pool.QueryRow(ctx, `
	  WITH w AS (SELECT sum(reads)::int AS n, sum(lag_total) AS lt, max(unsent_max) AS umax FROM pgvigil.mssql_georepl_window(ARRAY[$1::int], $2, $3)),
	       s AS (SELECT count(*)::int AS n, sum(replication_lag_sec) AS lt, max(unsent_s) AS umax FROM pgvigil.mssql_georepl_sample
	              WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3)
	  SELECT count(*)::int FROM w, s WHERE w.n IS DISTINCT FROM s.n OR w.lt IS DISTINCT FROM s.lt OR w.umax IS DISTINCT FROM s.umax`,
		ms, h0.Add(17*time.Minute), h0.Add(101*time.Minute)).Scan(&bad); err != nil {
		t.Fatal(err)
	}
	if bad != 0 {
		t.Error("the georepl window across an hour's edges differs from its samples")
	}
}
