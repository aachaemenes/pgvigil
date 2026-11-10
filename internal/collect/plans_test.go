package collect

import (
	"strings"
	"testing"
	"time"
)

// TestPlansQueryShapes: the read follows the installed version's column names, and an unknown shape is a skip.
func TestPlansQueryShapes(t *testing.T) {
	base := map[string]bool{"userid": true, "dbid": true, "planid": true, "plan": true, "calls": true}
	with := func(extra ...string) map[string]bool {
		m := map[string]bool{}
		for k := range base {
			m[k] = true
		}
		for _, e := range extra {
			m[e] = true
		}
		return m
	}
	q, err := plansQuery(with("queryid", "queryid_stat_statements", "total_time"), `"public"`)
	if err != nil || !strings.Contains(q, "coalesce(p.queryid_stat_statements, 0)") || !strings.Contains(q, "p.total_time::float8") {
		t.Fatalf("older shape: %v\n%s", err, q)
	}
	q, err = plansQuery(with("queryid", "total_exec_time"), `"ext"`)
	if err != nil || !strings.Contains(q, "coalesce(p.queryid, 0)") || !strings.Contains(q, `"ext".pg_store_plans`) || !strings.Contains(q, "ORDER BY p.total_exec_time DESC") {
		t.Fatalf("newer shape: %v\n%s", err, q)
	}
	if _, err := plansQuery(with("queryid"), `"public"`); err == nil || !strings.Contains(err.Error(), "skipped") {
		t.Fatalf("no total column: %v", err)
	}
}

// TestPlansRow uses a constructed pg_store_plans answer (plans-constructed: no pg_store_plans build on the proof
// machine): a text plan in pg_store_plans' default format, without actual numbers.
func TestPlansRow(t *testing.T) {
	plan := "Hash Join  (cost=10.00..200.00 rows=1000 width=8)\n  Hash Cond: (a.id = b.id)\n  ->  Seq Scan on a  (cost=0.00..100.00 rows=1000 width=4)\n  ->  Hash  (cost=5.00..5.00 rows=100 width=4)\n        ->  Seq Scan on b  (cost=0.00..5.00 rows=100 width=4)"
	r := plansRow(time.Unix(100, 0), 16384, 10, 42, 7, plan, 12, 3456.5, "app", "app_user")
	if r.PlanKey != "psp:16384:10:42:7" || r.Source != "pg_store_plans" || r.Format != "text" || r.Analyzed || r.Plan == nil {
		t.Fatalf("row: %+v", r)
	}
	if r.QueryID == nil || *r.QueryID != 42 || *r.PlanID != 7 || *r.Calls != 12 || *r.TotalMS != 3456.5 || r.Datname != "app" || r.Usename != "app_user" {
		t.Fatalf("fields: %+v", r)
	}
	if r0 := plansRow(time.Unix(100, 0), 1, 1, 0, 7, plan, 1, 1, "", ""); r0.QueryID != nil {
		t.Fatalf("queryid 0 kept: %v", *r0.QueryID)
	}
	m := r.Map()
	if m["plan_key"] != "psp:16384:10:42:7" || m["plan"] == nil {
		t.Fatalf("map: %v", m)
	}
}
