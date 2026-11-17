package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAzureDBPagesOnAStore (B2a): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) the Azure tab's
// and the Azure Summary's reads of one Azure SQL Database - its tier, the window's row (averages weighed by samples, the
// largest sample, DBA Dash's unused DTUs, the histograms summed), its minutes newest first, the gap in the window, its
// PRIMARY data files against their max size with the '% Max Size' status - and the Summary's Disk cell n/a on Azure SQL
// Database while a SQL Server's with the same storage read says ok. [the review's fold, part c L5:] a DTU database whose
// tier is not read gives its DTU limit from its minutes and its files read 4 hours ago at 92 % say 'stale'; a vCore
// database without a tier row gives its vCores from its minutes and an unlimited data file says 'no max size'; the
// fleet sorts by unused DTUs, most first (DBA Dash's), and carries all four histograms with their 70 %+ shares.
func TestAzureDBPagesOnAStore(t *testing.T) {
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
	ids := map[string]int{}
	for _, c := range []struct{ key, platform string }{{"azuresqldb", "azuresqldb"}, {"sqlserver", "sqlserver"}, {"nogov", "azuresqldb"}, {"vcore", "azuresqldb"}} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("azpages-%s-%d", c.key, sfx), c.platform).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[c.key] = id
	}
	az, ss, nogov, vcore := ids["azuresqldb"], ids["sqlserver"], ids["nogov"], ids["vcore"]
	defer func() {
		for _, c := range []struct {
			q    string
			args []any
		}{
			{`DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id IN ($1, $2, $3)`, []any{az, nogov, vcore}},
			{`DELETE FROM pgvigil.instances WHERE instance_id IN ($1, $2, $3, $4)`, []any{az, ss, nogov, vcore}},
		} {
			if _, err := pool.Exec(context.Background(), c.q, c.args...); err != nil {
				t.Error(err)
			}
		}
	}()
	impAt := func(id int, at time.Time, fn string, rows ...map[string]any) {
		t.Helper()
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, fmt.Sprintf(`SELECT pgvigil.import_%s($1, $2, $3::jsonb)`, fn), id, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	imp := func(id int, fn string, rows ...map[string]any) { t.Helper(); impAt(id, time.Now(), fn, rows...) }
	base := time.Now().UTC().Truncate(time.Minute).Add(-30 * time.Minute)
	minute := func(m, samples int, cpu, cpuMax, dtu, dtuMax, dtus float64, cpuB, dtuB []int) map[string]any {
		return map[string]any{"kind": "minute", "minute": base.Add(time.Duration(m) * time.Minute).Format(time.RFC3339), "samples": samples,
			"avg_cpu_percent": cpu, "max_cpu_percent": cpuMax, "avg_data_io_percent": 1.0, "max_data_io_percent": 2.0,
			"avg_log_write_percent": 0.5, "max_log_write_percent": 1.0, "dtu_limit": 5.0, "avg_dtu_percent": dtu, "max_dtu_percent": dtuMax,
			"avg_dtu": dtus, "max_dtu": dtuMax / 20, "dtu_buckets": dtuB, "cpu_buckets": cpuB,
			"data_buckets": []int{samples, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "log_buckets": []int{samples, 0, 0, 0, 0, 0, 0, 0, 0, 0}}
	}
	imp(az, "mssql_azuredb_resources",
		minute(0, 4, 10, 30, 10, 30, 0.5, []int{2, 1, 0, 1, 0, 0, 0, 0, 0, 0}, []int{2, 1, 0, 1, 0, 0, 0, 0, 0, 0}),
		minute(1, 2, 40, 95, 40, 95, 2, []int{0, 0, 0, 0, 1, 0, 0, 0, 0, 1}, []int{0, 0, 0, 0, 1, 0, 0, 0, 0, 1}),
		map[string]any{"kind": "gap", "gap_from": base.Add(-20 * time.Minute).Format(time.RFC3339), "gap_to": base.Add(-5 * time.Minute).Format(time.RFC3339), "oldest_end": nil})
	imp(az, "mssql_azuredb_governance", map[string]any{"kind": "governance", "edition": "Basic", "service_objective": "Basic", "max_size_bytes": 2147483648.0,
		"pool": nil, "pool_from": nil, "pool_note": nil, "gov": map[string]any{"slo_name": "Basic", "dtu_limit": 5, "cpu_limit": nil, "max_sessions": 30000,
			"primary_group_max_workers": 30, "primary_max_log_rate": 2621440, "user_data_directory_space_usage_mb": 40}})
	file := func(id int, typ string, fg any, size, used, limit int64) map[string]any {
		return map[string]any{"kind": "file", "database_id": 5, "database_name": "appdb", "database_state": "ONLINE", "file_id": id, "file_name": fmt.Sprint(id),
			"type_desc": typ, "filegroup": fg, "physical_name": "x", "state_desc": "ONLINE", "size_bytes": size << 20, "used_bytes": used << 20, "used_read": 1,
			"used_note": nil, "max_size_bytes": limit << 20, "growth_bytes": 64 << 20, "growth_pct": 0, "volume": nil}
	}
	// the database without a tier row: DTU minutes (limit 10, largest 1 DTU: 9 unused), its files read 4 hours ago at 92 %
	nm := minute(0, 4, 5, 10, 5, 10, 0.5, []int{4, 0, 0, 0, 0, 0, 0, 0, 0, 0}, []int{4, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	nm["dtu_limit"], nm["max_dtu"] = 10.0, 1.0
	imp(nogov, "mssql_azuredb_resources", nm)
	impAt(nogov, time.Now().Add(-4*time.Hour), "mssql_storage", file(1, "ROWS", "PRIMARY", 1884, 100, 2048))
	// the vCore database without a tier row: 2 vCores in its minutes, no DTU; an unlimited data file
	vm := minute(0, 4, 50, 80, 0, 0, 0, []int{0, 0, 0, 0, 0, 4, 0, 0, 0, 0}, []int{0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	vm["dtu_limit"], vm["cpu_limit"], vm["avg_dtu_percent"], vm["max_dtu_percent"], vm["avg_dtu"], vm["max_dtu"] = nil, 2.0, nil, nil, nil, nil
	imp(vcore, "mssql_azuredb_resources", vm)
	unl := file(1, "ROWS", "PRIMARY", 500, 100, 0)
	unl["max_size_bytes"] = nil
	imp(vcore, "mssql_storage", unl)
	for _, id := range []int{az, ss} {
		imp(id, "mssql_storage", file(1, "ROWS", "PRIMARY", 1700, 600, 2048), file(2, "LOG", nil, 100, 10, 1024))
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_storage', now(), 'ok')
		   ON CONFLICT (instance_id, collection) DO UPDATE SET snapshot_at = now(), status = 'ok'`, id); err != nil {
			t.Fatal(err)
		}
	}
	from, to := base.Add(-time.Hour), base.Add(time.Hour)
	text := func(q string, args ...any) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(row_to_json(q)::text, ' '), '') FROM (`+q+`) q`, args...).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	check := func(what, got, want string) {
		t.Helper()
		if got != want {
			t.Errorf("%s:\n got %s\nwant %s", what, got, want)
		}
	}
	check("tier", text(`SELECT service_objective, dtu_limit, max_size_mb, usage_mb, max_sessions, max_workers, max_log_rate_mb_s FROM (`+sqlAzureDBTier+`) t`, az),
		`{"service_objective":"Basic","dtu_limit":5,"max_size_mb":2048,"usage_mb":40,"max_sessions":"30000","max_workers":"30","max_log_rate_mb_s":2.50}`)
	// weighed: CPU (10 x 4 + 40 x 2) / 6 = 20; DTUs (0.5 x 4 + 2 x 2) / 6 = 1; unused at the max = 5 - 4.75
	check("window", text(`SELECT samples, minutes, avg_cpu_percent, max_cpu_percent, avg_dtu_percent, max_dtu_percent, avg_dtu, max_dtu, unused_dtu, cpu_hist, dtu_hist, data_hist FROM (`+sqlAzureDBSummary+`) s`, az, from, to),
		`{"samples":6,"minutes":2,"avg_cpu_percent":20.00,"max_cpu_percent":95.00,"avg_dtu_percent":20.00,"max_dtu_percent":95.00,"avg_dtu":1.00,"max_dtu":4.7500,"unused_dtu":0.2500,"cpu_hist":[2,1,0,1,1,0,0,0,0,1],"dtu_hist":[2,1,0,1,1,0,0,0,0,1],"data_hist":[6,0,0,0,0,0,0,0,0,0]}`)
	check("minutes newest first", text(`SELECT samples, avg_cpu_percent FROM (`+sqlAzureDBMinutes+`) m`, az, from, to),
		`{"samples":2,"avg_cpu_percent":40.0000} {"samples":4,"avg_cpu_percent":10.0000}`)
	check("gaps", text(`SELECT minutes FROM (`+sqlAzureDBGaps+`) g`, az, from, to), `{"minutes":15}`)
	check("an empty window", text(`SELECT samples, cpu_hist FROM (`+sqlAzureDBSummary+`) s`, az, to, to.Add(time.Hour)), `{"samples":null,"cpu_hist":[0,0,0,0,0,0,0,0,0,0]}`)
	// the fleet: the Azure SQL Database only, its files 1700 of 2048 MB allocated (83.0 %: a warning), 600 used (29.3 %)
	check("fleet", text(`SELECT instance_id, service_objective, samples, avg_cpu_percent, gaps, gap_minutes, allocated_mb, used_mb, max_size_mb, allocated_pct, used_pct, pctmax_status, cpu_hist, dtu_hist, dtu_hot_pct FROM (`+sqlAzureDBFleet+`) f WHERE instance_id IN ($7, $8)`,
		from, to, "sqlserver", nil, nil, nil, az, ss),
		fmt.Sprintf(`{"instance_id":%d,"service_objective":"Basic","samples":6,"avg_cpu_percent":20.00,"gaps":1,"gap_minutes":15,"allocated_mb":1700,"used_mb":600,"max_size_mb":2048,"allocated_pct":83.0,"used_pct":29.3,"pctmax_status":"warning","cpu_hist":[2,1,0,1,1,0,0,0,0,1],"dtu_hist":[2,1,0,1,1,0,0,0,0,1],"dtu_hot_pct":16.7}`, az))
	// the order (most unused DTUs first, none last) and the two databases without a tier row
	check("fleet order and the untiered", text(`SELECT instance_id, tier_read, dtu_limit, cpu_limit, unused_dtu, pctmax_status FROM (`+sqlAzureDBFleet+`) f WHERE instance_id IN ($7, $8, $9)`,
		from, to, "sqlserver", nil, nil, nil, az, nogov, vcore),
		fmt.Sprintf(`{"instance_id":%d,"tier_read":false,"dtu_limit":10,"cpu_limit":null,"unused_dtu":9.0000,"pctmax_status":"stale"} `+
			`{"instance_id":%d,"tier_read":true,"dtu_limit":5,"cpu_limit":null,"unused_dtu":0.2500,"pctmax_status":"warning"} `+
			`{"instance_id":%d,"tier_read":false,"dtu_limit":null,"cpu_limit":2.00,"unused_dtu":null,"pctmax_status":"no max size"}`, nogov, az, vcore))
	// the Summary's Disk cell
	rs, err := pool.Query(ctx, sqlMSSQLSummaryCells, `{}`, 3600)
	if err != nil {
		t.Fatal(err)
	}
	defer rs.Close()
	disk := map[int]string{}
	for rs.Next() {
		vals, err := rs.Values()
		if err != nil {
			t.Fatal(err)
		}
		id, _ := vals[0].(int32)
		if vals[1] == "disk" && (int(id) == az || int(id) == ss) {
			disk[int(id)] = fmt.Sprint(vals[2])
		}
	}
	if disk[az] != "n/a" || disk[ss] != "ok" {
		t.Errorf("the Disk cell: Azure SQL Database %q (want n/a: no volumes there), SQL Server %q (want ok)", disk[az], disk[ss])
	}
}
