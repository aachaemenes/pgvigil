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
// two reads at the root over 8 days - one collection, and every collection - each statement (rows, charts) under
// EXPLAIN (ANALYZE, BUFFERS) three times: the median, the plan's top node, its shared buffers. The decision (the
// lead's): a one-collection read over 2 s adds the (collection, hour) index; under it, no index, these numbers the
// evidence.
func TestCollectionPerfScaleJ5(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_SCALE_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_SCALE_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	to := time.Now().UTC()
	from := to.Add(-8 * 24 * time.Hour)
	for _, c := range []struct{ name, coll string }{{"one collection", "activity"}, {"every collection", ""}} {
		for _, st := range []struct {
			name string
			sql  string
			args []any
		}{
			{"rows", sqlCollPerfRows, []any{from, to, 0, nil, c.coll, collPerfCap}},
			{"charts", sqlCollPerfCharts, []any{from, to, 0, nil, c.coll}},
		} {
			var ms []float64
			var top string
			var bufs int64
			for k := 0; k < 3; k++ {
				var plan []byte
				if err := pool.QueryRow(ctx, "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)\n"+st.sql, st.args...).Scan(&plan); err != nil {
					t.Fatalf("%s, %s: %v", c.name, st.name, err)
				}
				var p []struct {
					Plan          map[string]any `json:"Plan"`
					ExecutionTime float64        `json:"Execution Time"`
				}
				if err := json.Unmarshal(plan, &p); err != nil || len(p) == 0 {
					t.Fatalf("%s, %s: the plan: %v", c.name, st.name, err)
				}
				ms = append(ms, p[0].ExecutionTime)
				top = fmt.Sprint(p[0].Plan["Node Type"])
				hit, _ := p[0].Plan["Shared Hit Blocks"].(float64)
				read, _ := p[0].Plan["Shared Read Blocks"].(float64)
				bufs = int64(hit + read)
			}
			sort.Float64s(ms)
			fmt.Printf("J5 %s, %s: median %.0f ms (%.0f / %.0f / %.0f), top node %s, shared buffers %d\n", c.name, st.name, ms[1], ms[0], ms[1], ms[2], top, bufs)
		}
	}
}
