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

// TestCollectionPerfScaleJ5 (the review of B6g-3 #6, the lead's 13:3x (a): measure first; a box row on a store seeded
// at fleet scale by .vis/scale-seed.sql, PGVIGIL_SCALE_DSN - skipped without it): the Collection Performance report's
// read at the root over 8 days - one collection, and every collection - as the page reads it: one GET runs rows, charts
// and meta in series (web.go multi), so the read is their sum. Each statement under EXPLAIN (ANALYZE, BUFFERS, TIMING
// OFF) three times (per-node timing would add a clock read per row: the review of B6g part c #6) - the median - and once
// with TIMING ON for its top node and buffers; the session as the serve sets it (jit off, custom plans: web.go). The
// lead's rule decides on the one-collection read's sum: over 2 s, the (collection, hour) index.
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
	for _, c := range []struct{ name, coll string }{{"one collection", "activity"}, {"every collection", ""}} {
		sum := 0.0
		for _, st := range []struct {
			name string
			sql  string
			args []any
		}{
			{"rows", sqlCollPerfRows, []any{from, to, 0, nil, c.coll, collPerfCap}},
			{"charts", sqlCollPerfCharts, []any{from, to, 0, nil, c.coll}},
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

// slowNodes: a plan's nodes whose actual total time is min ms or more, outermost first, with their rows and what they
// spilled or sorted (the J5 rows read at the root over every collection: 124.7 s in vis-scale3, the cause unread)
func slowNodes(n map[string]any, min float64, out *[]string) {
	// a node's time and rows are per loop: times its loops (the review of the B6g-4 fold #7 - an inner node of a nested
	// loop at 0.5 ms x 10,000 loops is 5 s)
	loops, _ := n["Actual Loops"].(float64)
	if loops < 1 {
		loops = 1
	}
	if per, _ := n["Actual Total Time"].(float64); per*loops >= min {
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
			slowNodes(m, min, out)
		}
	}
}
