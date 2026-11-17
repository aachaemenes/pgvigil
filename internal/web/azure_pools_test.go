package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAzureSummaryPoolsOnAStore (P25 task 8: DBA Dash's Azure Summary, its separate Elastic Pool grid): on a migrated
// repository (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/azuredb/summary part=pools lists each elastic pool of
// the scope's Azure SQL Databases once - its logical server and name, how many of its databases pgvigil reads, and
// over the window its CPU / data IO / log write / eDTU averages and maxima, its workers' and sessions' maxima and
// its storage share as last read; a pool none of whose databases is in the scope is not listed.
func TestAzureSummaryPoolsOnAStore(t *testing.T) {
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
	tag := fmt.Sprintf("azpool:%d", sfx)
	var ids []int
	for _, n := range []string{"a", "b"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
			fmt.Sprintf("azpool-%s-%d", n, sfx), tag).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	server := fmt.Sprintf("srv-%d", sfx)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`} {
			if _, err := pool.Exec(context.Background(), q, server); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, ids); err != nil {
			t.Error(err)
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	at := time.Now().UTC().Truncate(time.Minute).Add(-30 * time.Minute)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_pool_minute', $1)`, at)
	exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $3, 'pool1', $4), ($2, $3, 'pool1', $4)`, ids[0], ids[1], server, at)
	exec(`INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_data_io_percent,
	        avg_log_write_percent, max_worker_percent, max_session_percent, avg_edtu_percent, used_storage_percent, allocated_storage_percent,
	        instance_id, name_from)
	      VALUES ($1, 'pool1', $2, 4, 20, 50, 10, 5, 30, 12, 25, 40, 55, $4, 'tag'),
	             ($1, 'pool1', $3, 2, 40, 90, 20, 15, 60, 24, 45, 41, 56, $4, 'tag')`, server, at, at.Add(time.Minute), ids[0])

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(tagQ string) []map[string]any {
		t.Helper()
		q := url.Values{"from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "part": {"pools"}}
		if tagQ != "" {
			q.Set("tag", tagQ)
		}
		rec := httptest.NewRecorder()
		s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw["pools"]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				if m["server"] == server {
					out = append(out, m)
				}
			}
		}
		return out
	}
	got := call(tag)
	if len(got) != 1 {
		t.Fatalf("tag %s: pools %v, want pool1 once", tag, got)
	}
	p := got[0]
	// the second minute carries 2 samples to the first's 4: an average weighs each minute by its samples (review t11-2 SHOULD 4)
	if fmt.Sprint(p["pool"], " ", p["databases"], " ", p["avg_cpu_percent"], " ", p["max_cpu_percent"], " ", p["avg_edtu_percent"], " ", p["max_worker_percent"], " ",
		p["used_storage_percent"], " ", p["max_data_io_percent"], " ", p["max_log_write_percent"]) != "pool1 2 26.67 90 31.67 60 41 20 15" {
		t.Errorf("pool1: %v, want 2 databases, CPU avg 26.67 (20x4 + 40x2 over 6 samples) max 90, eDTU avg 31.67, workers max 60, storage used 41 (the last minute's), data IO max 20, log write max 15", p)
	}
	if other := call("azpool:none"); len(other) != 0 {
		t.Errorf("another tag: %v, want no pool", other)
	}
}
