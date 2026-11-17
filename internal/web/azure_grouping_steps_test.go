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
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAzureDateGroupingStepsOnAStore (control audit row A1): DBA Dash's Date Grouping offers 1min, 2min, 5min, 10min,
// 15min, 30min, 1hr, 2hrs, 4hrs, 6hrs, 12hrs, 1 Day, 2 Days, 7 Days and 14 Days on the Azure DB and Pool charts
// (DBADashGUI/DateHelper.cs DateGroups), each bucket measured from 1900-01-01 (dbo.DateGroupingMins), a step of 60
// minutes and over read from its hourly table (AzureDBElasticPoolResourceStats_Get's @Use60MIN). pgvigil's
// /api/mssql/azuredb and /api/mssql/pool serve part=grouped&step=<minutes> for the steps past minute / hour / day: under
// 60 from the minutes, 60 and over from the hour split (mssql_azuredb_window), every average weighed by its samples,
// the maximum the largest, minutes counted (partial: fewer than the step holds); no step = no rows; any other step = 400.
func TestAzureDateGroupingStepsOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("azsteps-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	server := fmt.Sprintf("srvg-%d", sfx)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, server)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`, id)
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	// day 1: 01:00 (4 samples, CPU 10), 01:01 (4, 30), 01:05 (2, 50); day 2: 01:00 (2, 70); each maximum CPU + 5
	d1 := time.Date(2026, 10, 10, 1, 0, 0, 0, time.UTC)
	d2 := d1.Add(24 * time.Hour)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_azuredb_minute', $1)`, d1)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_pool_minute', $1)`, d1)
	z := `'{0,0,0,0,0,0,0,0,0,0}'`
	type min struct {
		at      time.Time
		samples int
		cpu     float64
	}
	mins := []min{{d1, 4, 10}, {d1.Add(time.Minute), 4, 30}, {d1.Add(5 * time.Minute), 2, 50}, {d2, 2, 70}}
	for _, m := range mins {
		exec(`INSERT INTO pgvigil.mssql_azuredb_minute (instance_id, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, dtu_buckets, cpu_buckets, data_buckets, log_buckets)
		      VALUES ($1, $2, $3, $4::numeric, $4::numeric + 5, `+z+`, `+z+`, `+z+`, `+z+`)`, id, m.at, m.samples, m.cpu)
	}
	exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $2, 'pool1', $3)`, id, server, d1)
	for _, m := range mins[:3] {
		exec(`INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_edtu_percent, max_worker_percent,
		        used_storage_percent, instance_id, name_from) VALUES ($1, 'pool1', $2, $3, $4::numeric, $4::numeric + 5, $4::numeric, 10, 40, $5, 'tag')`, server, m.at, m.samples, m.cpu, id)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(h func(http.ResponseWriter, *http.Request), path, step string, wantCode int) []map[string]any {
		t.Helper()
		q := url.Values{"instance": {fmt.Sprint(id)}, "from": {d1.Add(-time.Hour).Format(time.RFC3339)}, "to": {d2.Add(time.Hour).Format(time.RFC3339)}, "part": {"grouped"}}
		if step != "" {
			q.Set("step", step)
		}
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path+"?"+q.Encode(), nil))
		if rec.Code != wantCode {
			t.Fatalf("%s part=grouped step=%q: %d %s (want %d)", path, step, rec.Code, rec.Body.String(), wantCode)
		}
		if wantCode != http.StatusOK {
			return nil
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw["grouped"]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out = append(out, m)
			}
		}
		return out
	}
	num := func(v any) float64 {
		switch x := v.(type) {
		case float64:
			return x
		case string:
			var f float64
			_, _ = fmt.Sscan(x, &f)
			return f
		}
		return -1
	}
	at := func(v any) time.Time {
		ts, _ := time.Parse(time.RFC3339Nano, fmt.Sprint(v))
		return ts.UTC()
	}
	// a bucket's start as DBA Dash's dbo.DateGroupingMins computes it: whole steps from 1900-01-01
	base := time.Date(1900, 1, 1, 0, 0, 0, 0, time.UTC)
	bucket := func(ts time.Time, step int) time.Time {
		d := time.Duration(step) * time.Minute
		return base.Add(ts.Sub(base) / d * d)
	}
	type want struct {
		start   time.Time
		minutes int
		avg     float64
		max     float64
		partial bool
	}
	check := func(what string, got []map[string]any, wants []want) {
		t.Helper()
		if len(got) != len(wants) {
			t.Errorf("%s: %d bucket(s), want %d: %v", what, len(got), len(wants), got)
			return
		}
		for i, w := range wants {
			g := got[i]
			if !at(g["snapshot_at"]).Equal(w.start) || int(num(g["minutes"])) != w.minutes || num(g["avg_cpu_percent"]) != w.avg ||
				num(g["max_cpu_percent"]) != w.max || g["partial"] != w.partial {
				t.Errorf("%s bucket %d: got %v, want start %s minutes %d CPU avg %.2f max %.2f partial %v", what, i, g, w.start.Format(time.RFC3339), w.minutes, w.avg, w.max, w.partial)
			}
		}
	}
	// the database: 5 minutes (newest first) - day 2's 01:00, day 1's 01:05, day 1's 01:00 (10 and 30 by 4 samples each = 20)
	check("azuredb step 5", call(s.MSSQLAzureDB, "/api/mssql/azuredb", "5", http.StatusOK), []want{
		{bucket(d2, 5), 1, 70, 75, true}, {bucket(d1.Add(5*time.Minute), 5), 1, 50, 55, true}, {bucket(d1, 5), 2, 20, 35, true}})
	// 2 hours, through the hour split: day 1's three minutes in one bucket ((40 + 120 + 100) / 10 = 26)
	check("azuredb step 120", call(s.MSSQLAzureDB, "/api/mssql/azuredb", "120", http.StatusOK), []want{
		{bucket(d2, 120), 1, 70, 75, true}, {bucket(d1, 120), 3, 26, 55, true}})
	// 2, 7 and 14 days: the buckets as DBA Dash's 1900-01-01 base puts them (day 1 and day 2 apart or together)
	for _, st := range []int{2880, 10080, 20160} {
		var wants []want
		if bucket(d1, st).Equal(bucket(d2, st)) {
			wants = []want{{bucket(d1, st), 4, (40 + 120 + 100 + 140) / 12.0, 75, true}}
		} else {
			wants = []want{{bucket(d2, st), 1, 70, 75, true}, {bucket(d1, st), 3, 26, 55, true}}
		}
		for i := range wants {
			wants[i].avg = float64(int(wants[i].avg*100+0.5)) / 100
		}
		check(fmt.Sprintf("azuredb step %d", st), call(s.MSSQLAzureDB, "/api/mssql/azuredb", fmt.Sprint(st), http.StatusOK), wants)
	}
	if got := call(s.MSSQLAzureDB, "/api/mssql/azuredb", "", http.StatusOK); len(got) != 0 {
		t.Errorf("azuredb part=grouped without a step: %d row(s), want none", len(got))
	}
	call(s.MSSQLAzureDB, "/api/mssql/azuredb", "7", http.StatusBadRequest)
	// the pool: 5 minutes - 01:05 (60), 01:00 (20 and 40 by 4 samples each = 30)
	pg := call(s.MSSQLPool, "/api/mssql/pool", "5", http.StatusOK)
	if len(pg) != 2 || !at(pg[0]["snapshot_at"]).Equal(bucket(d1.Add(5*time.Minute), 5)) || num(pg[0]["avg_cpu_percent"]) != 50 ||
		!at(pg[1]["snapshot_at"]).Equal(bucket(d1, 5)) || num(pg[1]["avg_cpu_percent"]) != 20 || int(num(pg[1]["minutes"])) != 2 {
		t.Errorf("pool step 5: %v, want 01:05 CPU 50 then 01:00 CPU 20 over 2 minutes", pg)
	}
	call(s.MSSQLPool, "/api/mssql/pool", "45", http.StatusBadRequest)
}

// TestAzureDateGroupingMenuIsDBADashs (control audit row A1): the charts' toolbar offers DBA Dash's Date Grouping list in
// its order and labels (DateHelper.cs DateGroups) after pgvigil's Auto, and says beside it why DBA Dash's None (the
// 15-second rows) is not offered (the lead's 11-17 13:19: a named difference).
func TestAzureDateGroupingMenuIsDBADashs(t *testing.T) {
	b, err := os.ReadFile("../../web/src/azure_charts.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	m := regexp.MustCompile(`(?s)const groupings: \[[^\]]*\]\[\] = \[(.*?)\];`).FindStringSubmatch(src)
	if m == nil {
		t.Fatal("azure_charts.ts: no groupings list")
	}
	labels := regexp.MustCompile(`\['[^']*', '([^']*)'\]`).FindAllStringSubmatch(m[1], -1)
	var got []string
	for _, l := range labels {
		got = append(got, l[1])
	}
	want := []string{"Auto", "1min", "2min", "5min", "10min", "15min", "30min", "1hr", "2hrs", "4hrs", "6hrs", "12hrs", "1 Day", "2 Days", "7 Days", "14 Days"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("azure_charts.ts groupings: %q, want %q", got, want)
	}
	if !strings.Contains(src, "None (its 15-second rows) is not offered") {
		t.Error("azure_charts.ts: the toolbar does not say why DBA Dash's None is not offered")
	}
}
