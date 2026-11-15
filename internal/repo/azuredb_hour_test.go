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

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0167's hours of mssql_azuredb_minute (task
// B2a-N2): each hour's totals, counts, maxima and buckets equal its minutes' (uneven samples); a re-import counts
// nothing again; a late minute recomputes its hour only; an adding trigger would double a dirty range over built
// hours, this one does not; two imports of one instance at once (one held open) leave the hour exact; a failure (no
// partition can be made) keeps the minutes, writes 'rollup failed' and the next import heals; hours are UTC under a
// +05:30 session; purge drops months older than 730 days and keeps the rest. Each row names the broken variant it
// catches.
func TestAzureDBHoursOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("azh-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_azuredb_hour WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`,
			`DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	minute := func(at time.Time, samples int, cpu float64) map[string]any {
		b := make([]int, 10)
		b[int(cpu)/10%10] = samples
		return map[string]any{"kind": "minute", "minute": at.Format(time.RFC3339), "samples": samples, "avg_cpu_percent": cpu, "max_cpu_percent": cpu + 1,
			"avg_data_io_percent": 1.5, "max_data_io_percent": 2, "avg_log_write_percent": 0.5, "max_log_write_percent": 1,
			"avg_memory_usage_percent": 10, "max_memory_usage_percent": 11, "avg_xtp_storage_percent": 0, "max_xtp_storage_percent": 0,
			"max_worker_percent": 3, "max_session_percent": 4, "avg_instance_cpu_percent": 5, "max_instance_cpu_percent": 6,
			"avg_instance_memory_percent": 20, "max_instance_memory_percent": 21, "dtu_limit": 5, "cpu_limit": nil, "replica_role": 0,
			"avg_dtu_percent": cpu, "max_dtu_percent": cpu + 1, "avg_dtu": cpu / 20, "max_dtu": (cpu + 1) / 20,
			"dtu_buckets": b, "cpu_buckets": b, "data_buckets": []int{samples, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "log_buckets": []int{samples, 0, 0, 0, 0, 0, 0, 0, 0, 0}}
	}
	imp := func(rows ...map[string]any) {
		t.Helper()
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	// the hour's figures against its minutes', recomputed here from the minutes
	check := func(what string, hour time.Time) {
		t.Helper()
		var bad string
		if err := pool.QueryRow(ctx, `
WITH m AS (SELECT count(*) AS minutes, sum(samples) AS samples, sum(avg_cpu_percent * samples) AS cpu_total,
                  sum(samples) FILTER (WHERE avg_cpu_percent IS NOT NULL) AS cpu_counted, max(max_cpu_percent) AS max_cpu,
                  coalesce(sum(cpu_buckets[1]), 0) + 10 * coalesce(sum(cpu_buckets[5]), 0) AS b
             FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $2 + interval '1 hour')
SELECT CASE WHEN h.instance_id IS NULL THEN 'no hour row'
            WHEN (h.minutes, h.samples, h.cpu_total, h.cpu_counted, h.max_cpu_percent, h.cpu_buckets[1] + 10 * h.cpu_buckets[5])
                 IS DISTINCT FROM (m.minutes::int, m.samples::int, m.cpu_total, m.cpu_counted::int, m.max_cpu, m.b::int)
            THEN format('hour %s/%s/%s/%s/%s vs minutes %s/%s/%s/%s/%s', h.minutes, h.samples, h.cpu_total, h.cpu_counted, h.max_cpu_percent,
                        m.minutes, m.samples, m.cpu_total, m.cpu_counted, m.max_cpu)
            ELSE '' END
  FROM m LEFT JOIN pgvigil.mssql_azuredb_hour h ON h.instance_id = $1 AND h.snapshot_at = $2`, id, hour).Scan(&bad); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
		if bad != "" {
			t.Errorf("%s: %s", what, bad)
		}
	}
	h0 := time.Now().UTC().Truncate(time.Hour).Add(-30 * time.Hour)
	// 30 hours of minutes, imported 10 at a time (one statement each), 3 or 4 samples a minute
	for m := 0; m < 30*60; m += 10 {
		rows := []map[string]any{}
		for k := 0; k < 10; k++ {
			rows = append(rows, minute(h0.Add(time.Duration(m+k)*time.Minute), 3+(m+k)%2, float64((m+k)%100)))
		}
		imp(rows...)
	}
	check("a built hour (an hour summed wrong or a second trigger call adding)", h0.Add(5*time.Hour))
	// a re-import of stored minutes counts nothing again (a trigger that added on DO NOTHING rows)
	imp(minute(h0.Add(5*time.Hour+3*time.Minute), 4, 3), minute(h0.Add(5*time.Hour+4*time.Minute), 3, 4))
	check("after a re-import", h0.Add(5*time.Hour))
	// a late minute in an old hour recomputes that hour only (a trigger that skips old hours)
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at = $2`, id, h0.Add(7*time.Hour+30*time.Minute)); err != nil {
		t.Fatal(err)
	}
	imp(minute(h0.Add(7*time.Hour+30*time.Minute), 4, 55))
	check("a late minute's hour", h0.Add(7*time.Hour))
	// a dirty range over hours already built, healed: each hour equals its minutes, not twice them (an adding trigger)
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_hour_dirty (instance_id, from_at, to_at, why) VALUES ($1, $2, $3, 'test')
	  ON CONFLICT (instance_id) DO UPDATE SET from_at = EXCLUDED.from_at, to_at = EXCLUDED.to_at`, id, h0.Add(2*time.Hour), h0.Add(4*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_heal_one($1)`, id); err != nil {
		t.Fatal(err)
	}
	check("a healed dirty hour", h0.Add(3*time.Hour))
	// two imports of one instance at once, the first held open in its transaction (a missing lock loses a minute)
	h2 := h0.Add(10 * time.Hour)
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at IN ($2, $3)`, id, h2.Add(50*time.Minute), h2.Add(51*time.Minute)); err != nil {
		t.Fatal(err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	p1, _ := json.Marshal([]map[string]any{minute(h2.Add(50*time.Minute), 4, 77)})
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(p1)); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		p2, _ := json.Marshal([]map[string]any{minute(h2.Add(51*time.Minute), 3, 78)})
		_, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(p2))
		done <- err
	}()
	waited := false
	for i := 0; i < 50 && !waited; i++ {
		time.Sleep(100 * time.Millisecond)
		_ = pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND wait_event = 'advisory')`).Scan(&waited)
	}
	if !waited {
		t.Error("the second import never waited on the instance's lock")
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	check("two imports at once", h2)
	// a failure: a plain table named as a future month's partition (it cannot be attached), the minutes kept, the
	// 'rollup failed' row, then the next import heals once the table is gone (a failure that failed the import)
	future := time.Now().UTC().AddDate(0, 3, 0)
	part := "mssql_azuredb_hour_" + future.Format("200601")
	if _, err := pool.Exec(ctx, `CREATE TABLE pgvigil.`+part+` (x int)`); err != nil {
		t.Fatal(err)
	}
	fm := time.Date(future.Year(), future.Month(), 2, 0, 0, 0, 0, time.UTC)
	imp(minute(fm, 4, 40))
	var minutes, failed int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at = $2`, id, fm).Scan(&minutes)
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collection_log WHERE instance_id = $1 AND collection = 'mssql_azuredb_hour' AND status = 'error'`, id).Scan(&failed)
	if minutes != 1 || failed != 1 {
		t.Errorf("a failed rollup: minutes kept %d, 'rollup failed' rows %d (want 1 and 1)", minutes, failed)
	}
	if _, err := pool.Exec(ctx, `DROP TABLE pgvigil.`+part); err != nil {
		t.Fatal(err)
	}
	imp(minute(fm.Add(time.Minute), 3, 41))
	check("healed after the failure", fm)
	// UTC hours under a +05:30 session (a date_trunc in the session's zone keys hours at :30)
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `SET TimeZone = 'Asia/Kolkata'`); err != nil {
		t.Fatal(err)
	}
	pk, _ := json.Marshal([]map[string]any{minute(h0.Add(12*time.Hour+40*time.Minute), 4, 12)})
	if _, err := conn.Exec(ctx, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at = $2`, id, h0.Add(12*time.Hour+40*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(pk)); err != nil {
		t.Fatal(err)
	}
	var odd int
	_ = conn.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_azuredb_hour WHERE instance_id = $1 AND extract(minute FROM snapshot_at AT TIME ZONE 'UTC') <> 0`, id).Scan(&odd)
	conn.Release()
	if odd != 0 {
		t.Errorf("%d hour rows not on a UTC hour under Asia/Kolkata", odd)
	}
	check("an hour imported under +05:30", h0.Add(12*time.Hour))
	// purge's hours: a month older than 730 days dropped, the rest kept
	old := time.Now().UTC().AddDate(-3, 0, 0)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_partition($1)`, old); err != nil {
		t.Fatal(err)
	}
	var dropped []string
	if err := pool.QueryRow(ctx, `SELECT pgvigil.mssql_azuredb_hour_purge()`).Scan(&dropped); err != nil {
		t.Fatal(err)
	}
	if len(dropped) != 1 || dropped[0] != "mssql_azuredb_hour_"+old.Format("200601") {
		t.Errorf("purge dropped %v, want the one month over 730 days old", dropped)
	}
	check("a hour kept by purge", h0.Add(5*time.Hour))
}
