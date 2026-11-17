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

// TestExecStatsStepsOnAStore (review part 5's findings 1, 2, 3 and 5 on the Execution Stats strip): on a migrated
// repository (PGVIGIL_REPO_TEST_DSN, skipped without it), over a 30-minute range:
//   - the strip's steps are never finer than the collections' five minutes (procStep, as the Procedures page's chart):
//     a procedures read at :05:30 and a functions read at :09:50 fall in ONE step, so the lines share their points;
//   - every top object has a row on every step its kind's reads cover, 0 where it did not run (never a gap);
//   - each kind is divided by its OWN reads' seconds in the step (a functions read of 200 s beside a procedures read
//     of 300 s: the function's figure over 200);
//   - one label per object, from its database's newest name and its own newest schema and name (a read that gave up
//     on a lock stores NULL names; a database renamed in the range), and the rows carry database_id and object_id;
//   - db=<name> takes the database whose newest name it is, by its id: the samples stored under its old name or
//     with no name count;
//   - top= outside 1-50 or not a number is refused.
func TestExecStatsStepsOnAStore(t *testing.T) {
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
		fmt.Sprintf("execsteps-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = $1`,
			`DELETE FROM pgvigil.mssql_func_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_func_read WHERE instance_id = $1`,
			`DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
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
	base := time.Now().UTC().Truncate(time.Hour).Add(-2 * time.Hour)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read", "mssql_func_sample", "mssql_func_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, base)
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, base.Add(30*time.Minute))
	}
	m := func(mins, secs int) time.Time {
		return base.Add(time.Duration(mins)*time.Minute + time.Duration(secs)*time.Second)
	}
	// the procedures' reads at :05:30, :10:30, :15:30 (300 s each); the functions' at :09:50 (200 s), :14:50, :19:50 (300 s)
	for _, at := range []time.Time{m(5, 30), m(10, 30), m(15, 30)} {
		exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 300, 2)`, id, at)
	}
	exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 200, 1, 0)`, id, m(9, 50))
	for _, at := range []time.Time{m(14, 50), m(19, 50)} {
		exec(`INSERT INTO pgvigil.mssql_func_read (instance_id, snapshot_at, interval_secs, functions, triggers) VALUES ($1, $2, 300, 1, 0)`, id, at)
	}
	proc := func(at time.Time, db, obj int, dbName, schema, name any, durMS int) {
		t.Helper()
		exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
		        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
		      VALUES ($1, $2, $3, $4, $5, $6, $7, 'SQL_STORED_PROCEDURE', 1, 0, $8, 0, 0, 0, 300)`, id, at, db, obj, dbName, schema, name, durMS*1000)
	}
	// usp_a (sales, 5:101): 3000 ms in the :05 step under the database's old name, nothing at :10, 1500 ms at :15 from
	// a read that stored no names; usp_b (5:102): 600 ms at :15 under the new name; usp_h (hr, 6:401): 300 ms at :05
	proc(m(5, 30), 5, 101, "sales_old", "dbo", "usp_a", 3000)
	proc(m(15, 30), 5, 101, nil, nil, nil, 1500)
	proc(m(15, 30), 5, 102, "sales", "dbo", "usp_b", 600)
	proc(m(5, 30), 6, 401, "hr", "dbo", "usp_h", 300)
	// fn_f (5:201): 1000 ms in the functions' 200-second read of the :05 step, 600 ms at :10, nothing at :15
	for _, f := range []struct {
		at time.Time
		ms int
	}{{m(9, 50), 1000}, {m(14, 50), 600}} {
		exec(`INSERT INTO pgvigil.mssql_func_sample (instance_id, snapshot_at, kind, database_id, object_id, database_name, schema_name, object_name, type_desc,
		        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
		      VALUES ($1, $2, 'function', 5, 201, 'sales', 'dbo', 'fn_f', 'SQL_SCALAR_FUNCTION', 1, 0, $3, 0, 0, 0, 300)`, id, f.at, f.ms*1000)
	}

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) (int, string) {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {base.Format(time.RFC3339)}, "to": {base.Add(30 * time.Minute).Format(time.RFC3339)}, "part": {"execstats"}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.Performance(rec, httptest.NewRequest(http.MethodGet, "/api/performance?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			return rec.Code, ""
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []string
		if tb := raw["execstats"]; tb != nil {
			for _, r := range tb.Rows {
				row := map[string]any{}
				for i, c := range tb.Columns {
					row[c] = r[i]
				}
				at, _ := time.Parse(time.RFC3339, fmt.Sprint(row["snapshot_at"]))
				out = append(out, fmt.Sprintf("%02d %v:%v %v=%v", int(at.Sub(base).Minutes()), row["database_id"], row["object_id"], row["object"], row["per_sec"]))
			}
		}
		return 200, fmt.Sprint(out)
	}
	sales := []string{
		"05 5:201 sales.dbo.fn_f=5", "05 5:101 sales.dbo.usp_a=10", "05 5:102 sales.dbo.usp_b=0",
		"10 5:201 sales.dbo.fn_f=2", "10 5:101 sales.dbo.usp_a=0", "10 5:102 sales.dbo.usp_b=0",
		"15 5:201 sales.dbo.fn_f=0", "15 5:101 sales.dbo.usp_a=5", "15 5:102 sales.dbo.usp_b=2",
	}
	every := []string{
		"05 6:401 hr.dbo.usp_h=1", sales[0], sales[1], sales[2],
		"10 6:401 hr.dbo.usp_h=0", sales[3], sales[4], sales[5],
		"15 6:401 hr.dbo.usp_h=0", sales[6], sales[7], sales[8],
	}
	if code, got := call(url.Values{"measure": {"duration"}, "top": {"5"}}); code != 200 || got != fmt.Sprint(every) {
		t.Errorf("every database, top 5:\n got %d %s\nwant %v\n(five-minute steps; 0 where an object did not run; each kind over its own reads' seconds; one label per object)", code, got, every)
	}
	if code, got := call(url.Values{"measure": {"duration"}, "top": {"5"}, "db": {"sales"}}); code != 200 || got != fmt.Sprint(sales) {
		t.Errorf("db=sales:\n got %d %s\nwant %v\n(the database by its newest name: its old-name and no-name samples count)", code, got, sales)
	}
	top2 := []string{sales[0], sales[1], sales[3], sales[4], sales[6], sales[7]}
	if code, got := call(url.Values{"measure": {"duration"}, "top": {"2"}}); code != 200 || got != fmt.Sprint(top2) {
		t.Errorf("top 2:\n got %d %s\nwant %v\n(usp_a 4500 ms and fn_f 1600 ms over the range)", code, got, top2)
	}
	for _, bad := range []string{"0", "51", "abc"} {
		if code, _ := call(url.Values{"top": {bad}}); code != http.StatusBadRequest {
			t.Errorf("top=%s: %d, want 400", bad, code)
		}
	}
}
