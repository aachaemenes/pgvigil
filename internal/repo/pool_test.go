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

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0128's elastic pool rows (CLOUDSQL C4):
//   - two databases of one pool send the same minutes: one row a minute, the first reader's (its figures, read_by);
//     each database's pool is recorded;
//   - the storage status, DBA Dash's strict '>': 79 and 80 OK, 90 Warning, 91 Critical at the default 0.8 / 0.9; a
//     pool's own row with NULL thresholds N/A, with warning 0.8 and a NULL critical Warning at 91 and OK at 79 (DBA
//     Dash's view: N/A only for a NULL warning); a newest minute over 5 minutes old N/A (pgvigil's own); a member not
//     read for over 10 minutes no status at all.
func TestPoolOnAStore(t *testing.T) {
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
	server, poolName := fmt.Sprintf("srv-%d", sfx), "pool1"
	var a, b int
	for i, id := range []*int{&a, &b} {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("pooldb%d-%d", i, sfx)).Scan(id); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, `DELETE FROM pgvigil.mssql_pool_thresholds WHERE server = $1`} {
			if _, err := pool.Exec(context.Background(), q, server); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id IN ($1, $2)`, a, b); err != nil {
			t.Error(err)
		}
	}()
	base := time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)
	send := func(id int, cpu float64, alloc float64, minutes ...int) {
		t.Helper()
		var rows []map[string]any
		for _, m := range minutes {
			rows = append(rows, map[string]any{"server": server, "pool": poolName, "name_from": "tag", "samples": 4,
				"minute": base.Add(time.Duration(m) * time.Minute).Format(time.RFC3339), "avg_cpu_percent": cpu, "max_cpu_percent": cpu,
				"allocated_storage_percent": alloc, "storage_limit_mb": 5120.0, "avg_edtu_percent": nil})
		}
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_pool($1, now(), $2::jsonb)`, id, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	send(a, 10, 50, 0, 1)
	send(b, 99, 50, 0, 1, 2) // the same two minutes and one more
	var n, readByA int
	var cpu0 float64
	if err := pool.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE instance_id = $2), max(avg_cpu_percent) FILTER (WHERE snapshot_at = $3)::float8
	                                FROM pgvigil.mssql_pool_minute WHERE server = $1`, server, a, base).Scan(&n, &readByA, &cpu0); err != nil {
		t.Fatal(err)
	}
	if n != 3 || readByA != 2 || cpu0 != 10 {
		t.Fatalf("stored %d minutes (%d read by the first database, 12:00's CPU %v); want 3, 2 and 10 (the first reader's)", n, readByA, cpu0)
	}
	var members int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_pool_member WHERE instance_id IN ($1, $2) AND server = $3 AND pool = $4`, a, b, server, poolName).Scan(&members); err != nil || members != 2 {
		t.Fatalf("pool members %d, %v; want 2", members, err)
	}
	status := func(at time.Time) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, `SELECT status FROM pgvigil.mssql_pool_storage_status($1, $2)`, a, at).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	for i, c := range []struct {
		alloc float64
		want  string
	}{{79, "OK"}, {80, "OK"}, {90, "Warning"}, {91, "Critical"}} {
		m := 10 + i
		send(a, 1, c.alloc, m)
		if got := status(base.Add(time.Duration(m+1) * time.Minute)); got != c.want {
			t.Errorf("allocated %v%%: %s, want %s", c.alloc, got, c.want)
		}
	}
	if got := status(base.Add(30 * time.Minute)); got != "N/A" {
		t.Errorf("a newest minute 17 minutes old: %s, want N/A", got)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_pool_thresholds (server, pool, warning, critical) VALUES ($1, $2, NULL, NULL)`, server, poolName); err != nil {
		t.Fatal(err)
	}
	if got := status(base.Add(14 * time.Minute)); got != "N/A" {
		t.Errorf("the pool's own NULL thresholds at 91%%: %s, want N/A", got)
	}
	// DBA Dash's view: N/A only for a NULL warning threshold; a NULL critical one compares as false
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.mssql_pool_thresholds SET warning = 0.8 WHERE server = $1 AND pool = $2`, server, poolName); err != nil {
		t.Fatal(err)
	}
	if got := status(base.Add(14 * time.Minute)); got != "Warning" {
		t.Errorf("warning 0.8, critical NULL at 91%%: %s, want Warning (DBA Dash's view)", got)
	}
	send(a, 1, 79, 15)
	if got := status(base.Add(16 * time.Minute)); got != "OK" {
		t.Errorf("warning 0.8, critical NULL at 79%%: %s, want OK (DBA Dash's view)", got)
	}
	// a database not read in a pool for over 10 minutes (it left the pool) shows no pool status
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.mssql_pool_member SET seen_at = $2 WHERE instance_id = $1`, a, base); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_pool_storage_status($1, $2)`, a, base.Add(16*time.Minute)).Scan(&left); err != nil || left != 0 {
		t.Errorf("a member last read 16 minutes before: %d status rows, %v; want none", left, err)
	}
}
