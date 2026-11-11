package web

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// sqlStorageSeries over a bucket that holds several reads: each tablespace counts once (its largest read), so two
// tablespaces read four times in an hour sum to their own sizes, not four times them. The query runs against a temp
// table of storage_sample's columns. PGVIGIL_REPO_DSN names a PostgreSQL to run against; skipped without it.
func TestStorageSeriesOneReadPerBucket(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, `CREATE TEMP TABLE storage_sample_t (instance_id int, snapshot_at timestamptz, kind text, name text, size_bytes bigint, allocated_bytes bigint)`); err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 11, 10, 10, 0, 0, 0, time.UTC)
	for i := 0; i < 4; i++ { // four 15-minute reads in one hour
		at := base.Add(time.Duration(i*15) * time.Minute)
		for _, r := range []struct {
			kind, name string
			size       int64
		}{{"tablespace", "pg_default", 300 << 30}, {"tablespace", "pg_global", 1 << 20}, {"wal", "pg_wal", 512 << 20}} {
			if _, err := conn.Exec(ctx, `INSERT INTO storage_sample_t VALUES (1, $1, $2, $3, $4, NULL)`, at, r.kind, r.name, r.size+int64(i)); err != nil {
				t.Fatal(err)
			}
		}
	}
	q := strings.Replace(sqlStorageSeries, "pgvigil.storage_sample", "pg_temp.storage_sample_t", 1)
	var n int
	var ts, wal int64
	rows, err := conn.Query(ctx, q, 1, base.Add(-time.Minute), base.Add(time.Hour), 3600)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var at time.Time
		var tsp, walp, aur *int64
		if err := rows.Scan(&at, &walp, &tsp, &aur); err != nil {
			t.Fatal(err)
		}
		n++
		ts, wal = *tsp, *walp
	}
	if rows.Err() != nil {
		t.Fatal(rows.Err())
	}
	if want := int64(300<<30) + 1<<20 + 6; n != 1 || ts != want || wal != 512<<20+3 {
		t.Fatalf("%d bucket(s), tablespaces %d (want %d), wal %d", n, ts, want, wal)
	}
}
