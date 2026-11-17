package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestDBSnapshotsByDatabaseOnAStore (P25 row 2b, DBA Dash's database Snapshot Summary): on a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/mssql/checks?instance=N&db=<name>&part=snapshots lists the present
// snapshots whose source is that database (another database's snapshots and a dropped one left out).
func TestDBSnapshotsByDatabaseOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("dbsnap-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	for _, c := range []struct {
		at time.Time
		p  string
	}{
		{time.Now().UTC().Add(-2 * time.Hour), `[{"kind": "db_snapshot", "snapshot_name": "sales_old", "source_database": "sales", "size_on_disk_bytes": 1},
		       {"kind": "db_snapshot", "snapshot_name": "sales_snap", "source_database": "sales", "size_on_disk_bytes": 2}]`},
		{time.Now().UTC().Add(-time.Hour), `[{"kind": "db_snapshot", "snapshot_name": "sales_snap", "source_database": "sales", "size_on_disk_bytes": 4096},
		       {"kind": "db_snapshot", "snapshot_name": "hr_snap", "source_database": "hr", "size_on_disk_bytes": 8192}]`},
	} {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_db_snapshots($1, $2, $3::jsonb)`, id, c.at, c.p); err != nil {
			t.Fatal(err)
		}
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	rec := httptest.NewRecorder()
	s.MSSQLChecks(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/checks?instance="+fmt.Sprint(id)+"&part=snapshots&db=sales", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	raw := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	var got []string
	if tb := raw["snapshots"]; tb != nil {
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			got = append(got, fmt.Sprint(m["snapshot_name"], "=", m["size_on_disk_bytes"]))
		}
	}
	if fmt.Sprint(got) != "[sales_snap=4096]" {
		t.Errorf("db=sales snapshots %v, want [sales_snap=4096] (hr's and the dropped sales_old left out)", got)
	}
}
