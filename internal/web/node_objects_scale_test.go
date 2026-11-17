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
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestNodeObjectsAtScale (review t11-7 item 2, owed since its fold: the cost of sqlMSSQLNodeObjects, the three-kind
// statement run once per database through a lateral join): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it, and skipped under -short), a node of nodeObjectsMax (500) databases, each with 4 procedures read every
// 5 minutes for 24 hours (576,000 samples), gives part=objects over the 24 hours - the 2,000-row cut, the longest total
// duration first - and logs its time; it fails only past 60 s (a scale guard, not a timing row: the box's load moves
// it, as p11c-2's ratio row showed), and with a search past 15 s.
func TestNodeObjectsAtScale(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	if testing.Short() {
		t.Skip("a scale row: not under -short")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sfx := time.Now().UnixNano() % 1000000000
	var ids []int
	for n := 0; n < nodeObjectsMax; n++ {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("nodescale-%d-%d", n, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = ANY ($1)`, `DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = ANY ($1)`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`} {
			if _, err := pool.Exec(context.Background(), q, ids); err != nil {
				t.Error(err)
			}
		}
	}()
	to := time.Now().UTC().Truncate(5 * time.Minute)
	from := to.Add(-24 * time.Hour)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read"} {
		for _, at := range []time.Time{from, to} {
			if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at); err != nil {
				t.Fatal(err)
			}
		}
	}
	seed := time.Now()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs)
	        SELECT i, g, 300, 4 FROM unnest($1::int[]) i, generate_series($2::timestamptz + interval '5 minutes', $3::timestamptz, interval '5 minutes') g`, ids, from, to); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
	        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
	        SELECT i, g, 5, 100 + p, 'ledger', 'dbo', 'usp_' || p, 'SQL_STORED_PROCEDURE', 10, 1000 * p, 2000 * p + i, 10, 0, 0, 300
	          FROM unnest($1::int[]) i, generate_series($2::timestamptz + interval '5 minutes', $3::timestamptz, interval '5 minutes') g, generate_series(1, 4) p`,
		ids, from, to); err != nil {
		t.Fatal(err)
	}
	t.Logf("seeded %d databases x 288 reads x 4 procedures in %v", len(ids), time.Since(seed).Round(time.Millisecond))
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	var list []string
	for _, id := range ids {
		list = append(list, fmt.Sprint(id))
	}
	call := func(extra url.Values, limit time.Duration) {
		t.Helper()
		q := url.Values{"instances": {strings.Join(list, ",")}, "from": {from.Format(time.RFC3339)}, "to": {to.Format(time.RFC3339)}, "part": {"objects"}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		began := time.Now()
		s.MSSQLProcs(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/procs?"+q.Encode(), nil))
		took := time.Since(began)
		if rec.Code != http.StatusOK {
			t.Fatalf("%v: %d %s", extra, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		rows := 0
		if tb := raw["objects"]; tb != nil {
			rows = len(tb.Rows)
		}
		t.Logf("the node's Object Execution over 24 hours %v: %d rows in %v (%d bytes)", extra, rows, took.Round(time.Millisecond), rec.Body.Len())
		if took > limit {
			t.Errorf("%v took %v, over the %v scale guard", extra, took, limit)
		}
	}
	call(url.Values{}, 60*time.Second)
	call(url.Values{"search": {"usp_3"}}, 15*time.Second)
}
