package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestCollectionPerfScaleJ5 (the review of B6g-3 #6 (a): measure first; a box row on a store seeded
// at fleet scale by .vis/scale-seed.sql, PGVIGIL_SCALE_DSN - skipped without it): the Collection Performance report's
// read over 8 days - at the root for one collection and for every collection, then one instance and a sparse scope
// (the review of J5 (a) #6) - as the page reads it: one GET runs rows, charts
// and meta in series (web.go multi), so the read is their sum. Each statement under EXPLAIN (ANALYZE, BUFFERS, TIMING
// OFF) three times (per-node timing would add a clock read per row: the review of B6g part c #6) - the median - and once
// with TIMING ON for its top node and buffers; the session as the serve sets it (jit off, custom plans: web.go). The
// agreed rule decides on the one-collection read's sum: over 2 s, the (collection, hour) index.
func TestCollectionPerfScaleJ5(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_SCALE_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_SCALE_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["jit"] = "off"
	cfg.ConnConfig.RuntimeParams["plan_cache_mode"] = "force_custom_plan"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	to := time.Now().UTC()
	from := to.Add(-8 * 24 * time.Hour)
	plan := func(opts, sql string, args []any) (float64, map[string]any) {
		t.Helper()
		var raw []byte
		if err := pool.QueryRow(ctx, "EXPLAIN ("+opts+", FORMAT JSON)\n"+sql, args...).Scan(&raw); err != nil {
			t.Fatalf("EXPLAIN: %v", err)
		}
		var p []struct {
			Plan          map[string]any `json:"Plan"`
			ExecutionTime float64        `json:"Execution Time"`
		}
		if err := json.Unmarshal(raw, &p); err != nil || len(p) == 0 {
			t.Fatalf("the plan: %v", err)
		}
		return p[0].ExecutionTime, p[0].Plan
	}
	// the review of J5 (a) #6: beside the two reads at the root, the walk's own cost - one instance (60 rows an hour: the
	// cap at about 84 hours, 8 windows) and a sparse scope (10 instances of one collection: 1,920 rows in 8 days, under the
	// cap, so the walk goes to the range's first hour, its last window the 128-hour step clipped to that hour)
	var one int
	var ten []int32
	if err := pool.QueryRow(ctx, `SELECT min(instance_id) FROM pgvigil.instances WHERE name LIKE 'sc-i%'`).Scan(&one); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT array_agg(instance_id ORDER BY instance_id) FROM (SELECT instance_id FROM pgvigil.instances
	   WHERE name LIKE 'sc-i%' ORDER BY instance_id LIMIT 10) x`).Scan(&ten); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name  string
		inst  int
		insts []int32
		coll  string
	}{{"one collection", 0, nil, "activity"}, {"every collection", 0, nil, ""}, {"one instance", one, nil, ""},
		{"a sparse scope (10 instances, one collection)", 0, ten, "activity"}} {
		var insts any
		if c.insts != nil {
			insts = c.insts
		}
		sum := 0.0
		for _, st := range []struct {
			name string
			sql  string
			args []any
		}{
			{"rows", sqlCollPerfRows, []any{from, to, c.inst, insts, c.coll, collPerfCap}},
			{"charts", sqlCollPerfCharts, []any{from, to, c.inst, insts, c.coll}},
			{"meta", sqlCollPerfMeta, nil},
		} {
			var ms []float64
			for k := 0; k < 3; k++ {
				v, _ := plan("ANALYZE, BUFFERS, TIMING OFF", st.sql, st.args)
				ms = append(ms, v)
			}
			sort.Float64s(ms)
			sum += ms[1]
			tv, top := plan("ANALYZE, BUFFERS, TIMING ON", st.sql, st.args)
			hit, _ := top["Shared Hit Blocks"].(float64)
			read, _ := top["Shared Read Blocks"].(float64)
			t.Logf("J5 %s, %s: median %.0f ms (%.0f / %.0f / %.0f, TIMING OFF), top node %v, shared buffers %.0f (TIMING ON: %.0f ms)",
				c.name, st.name, ms[1], ms[0], ms[1], ms[2], top["Node Type"], hit+read, tv)
			// the plan's nodes of 1 s or more (TIMING ON), each with what spilled: the cause of a slow read named by the plan
			var slow []string
			slowNodes(top, 1000, &slow)
			for _, n := range slow {
				t.Logf("J5 %s, %s: node %s", c.name, st.name, n)
			}
		}
		t.Logf("J5 %s: the page's read (rows + charts + meta medians) %.0f ms", c.name, sum)
	}
}

// slowNodes: a plan's nodes whose actual total time is floor ms or more, outermost first, with their rows and what they
// spilled or sorted (the J5 rows read at the root over every collection: 124.7 s in vis-scale3, the cause unread)
func slowNodes(n map[string]any, floor float64, out *[]string) {
	// a node's time and rows are per loop: times its loops (the review of the B6g-4 fold #7 - an inner node of a nested
	// loop at 0.5 ms x 10,000 loops is 5 s)
	loops, _ := n["Actual Loops"].(float64)
	if loops < 1 {
		loops = 1
	}
	if per, _ := n["Actual Total Time"].(float64); per*loops >= floor {
		rows, _ := n["Actual Rows"].(float64)
		s := fmt.Sprintf("%v %.0f ms, %.0f rows over %.0f loop(s)", n["Node Type"], per*loops, rows*loops, loops)
		for _, k := range []string{"Relation Name", "Index Name", "Strategy", "Sort Method", "Sort Space Type", "Sort Space Used",
			"Peak Memory Usage", "Disk Usage", "HashAgg Batches", "Workers Launched", "Presorted Key"} {
			if v, ok := n[k]; ok {
				s += fmt.Sprintf("; %s %v", k, v)
			}
		}
		*out = append(*out, s)
	}
	kids, _ := n["Plans"].([]any)
	for _, k := range kids {
		if m, ok := k.(map[string]any); ok {
			slowNodes(m, floor, out)
		}
	}
}
