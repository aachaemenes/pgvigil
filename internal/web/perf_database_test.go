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
	"sort"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPerformanceByDatabaseOnAStore (P25, F101): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it)
// a SQL Server instance's Performance read given db=<name> is the database's own: IO from that database's files only
// (and with filegroup=<name> only that file group's data files), the blocking chains whose head ran in that database,
// and the database's file groups for the IO chart's filter. Without db= the IO is every file's, as before. CPU,
// sessions and waits stay the instance's (the store keeps no per-database row of them; DBA Dash's database page draws
// the instance's CPU too).
func TestPerformanceByDatabaseOnAStore(t *testing.T) {
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
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("perfdb-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{
			`DELETE FROM pgvigil.mssql_fileio_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_fileio_read WHERE instance_id = $1`,
			`DELETE FROM pgvigil.mssql_blocking WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`,
		} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	at := time.Now().UTC().Truncate(time.Hour).Add(-30 * time.Minute)
	for _, tb := range []string{"mssql_fileio_sample", "mssql_fileio_read", "mssql_blocking"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	// two databases: sales (id 5) with a PRIMARY and an FG2 data file and its log; hr (id 6) with one PRIMARY file
	exec(`INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, file_name, type_desc, filegroup, snapshot_at, first_seen)
	      VALUES ($1, 5, 1, 'sales', 'sales', 'ROWS', 'PRIMARY', $2, $2), ($1, 5, 3, 'sales', 'sales_fg2', 'ROWS', 'FG2', $2, $2),
	             ($1, 5, 2, 'sales', 'sales_log', 'LOG', NULL, $2, $2), ($1, 6, 1, 'hr', 'hr', 'ROWS', 'PRIMARY', $2, $2)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_fileio_read (instance_id, snapshot_at, interval_secs, files) VALUES ($1, $2, 60, 4)`, id, at)
	// read latency: sales PRIMARY 10 ms, sales FG2 30 ms, hr 90 ms; the log only writes
	exec(`INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc,
	        reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
	      VALUES ($1, $2, 5, 1, 'sales', 'sales', 'ROWS', 100, 6291456, 1000, 0, 0, 0, 60),
	             ($1, $2, 5, 3, 'sales', 'sales_fg2', 'ROWS', 100, 6291456, 3000, 0, 0, 0, 60),
	             ($1, $2, 5, 2, 'sales', 'sales_log', 'LOG', 0, 0, 0, 50, 3145728, 500, 60),
	             ($1, $2, 6, 1, 'hr', 'hr', 'ROWS', 100, 6291456, 9000, 0, 0, 0, 60)`, id, at)
	exec(`INSERT INTO pgvigil.mssql_blocking (instance_id, snapshot_at, head_session_id, victims, in_snapshot, head_database, longest_wait_ms)
	      VALUES ($1, $2, 51, 3, true, 'sales', 4000), ($1, $2, 52, 5, true, 'hr', 9000)`, id, at)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	from, to := at.Add(-10*time.Minute), at.Add(10*time.Minute)
	call := func(extra url.Values) map[string][]map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {from.Format(time.RFC3339)}, "to": {to.Format(time.RFC3339)}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.Performance(rec, httptest.NewRequest(http.MethodGet, "/api/performance?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		out := map[string][]map[string]any{}
		for name, tb := range raw {
			if tb == nil {
				continue
			}
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out[name] = append(out[name], m)
			}
		}
		return out
	}
	readMS := func(parts map[string][]map[string]any) float64 {
		t.Helper()
		var got []float64
		for _, r := range parts["io"] {
			if v, ok := r["read_ms"].(float64); ok {
				got = append(got, v)
			}
		}
		if len(got) != 1 {
			t.Fatalf("io: want one step with a read latency, got %v", parts["io"])
		}
		return got[0]
	}

	// the instance: every file (13000 ms over 300 reads)
	if got := readMS(call(nil)); got != 43.33 {
		t.Errorf("the instance's IO read latency %v ms, want 43.33 (every file)", got)
	}
	sales := call(url.Values{"db": {"sales"}})
	if got := readMS(sales); got != 20 {
		t.Errorf("db=sales: IO read latency %v ms, want 20 (sales' two data files, not hr's)", got)
	}
	if got := readMS(call(url.Values{"db": {"sales"}, "filegroup": {"FG2"}})); got != 30 {
		t.Errorf("db=sales&filegroup=FG2: IO read latency %v ms, want 30 (the FG2 file alone)", got)
	}
	var groups []string
	for _, r := range sales["filegroups"] {
		groups = append(groups, fmt.Sprint(r["filegroup"]))
	}
	sort.Strings(groups)
	if fmt.Sprint(groups) != "[FG2 PRIMARY]" {
		t.Errorf("db=sales: file groups %v, want [FG2 PRIMARY] (the log has none; hr's are not sales')", groups)
	}
	var victims []float64
	for _, r := range sales["blocking"] {
		if v, ok := r["victims"].(float64); ok {
			victims = append(victims, v)
		}
	}
	if fmt.Sprint(victims) != "[3]" {
		t.Errorf("db=sales: blocking victims %v, want [3] (the chain whose head ran in sales; hr's 5 left out)", victims)
	}
	for _, r := range call(url.Values{"db": {"nosuch"}})["io"] {
		if v, ok := r["read_ms"].(float64); ok {
			t.Errorf("db=nosuch: IO read latency %v ms, want none (no file of that database)", v)
		}
	}
}
