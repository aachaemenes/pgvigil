package collect

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Set 2's task 4 (L46, migration 0363): the five-minute table read carries pg_statio_user_tables' six block counters
// beside its scan and row counters. A box row (PGVIGIL_REPO_TEST_DSN, a login that may create a table): a table made
// here, filled and scanned, is read by tableActivitySQL with its heap blocks counted; the six keys are on every row.
func TestTableActivityReadsTheBlocks(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close(context.Background()) }()
	name := fmt.Sprintf("pgv_ta_blocks_%d", time.Now().UnixNano()%1_000_000_000)
	if _, err := c.Exec(ctx, `CREATE TABLE public.`+name+` (i int)`); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = c.Exec(context.Background(), `DROP TABLE IF EXISTS public.`+name) }()
	if _, err := c.Exec(ctx, `INSERT INTO public.`+name+` SELECT generate_series(1, 5000)`); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(ctx, `SELECT count(*) FROM public.`+name); err != nil {
		t.Fatal(err)
	}
	keys := []string{"heap_blks_read", "heap_blks_hit", "idx_blks_read", "idx_blks_hit", "toast_blks_read", "toast_blks_hit"}
	var got Row
	for i := 0; i < 20 && got == nil; i++ { // the statistics reach the views within a second of the transaction's end
		time.Sleep(300 * time.Millisecond)
		rows, err := c.Query(ctx, fmt.Sprintf(tableActivitySQL, tableActivityPerDB))
		if err != nil {
			t.Fatal(err)
		}
		all, err := rowsToMaps(rows)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range all {
			for _, k := range keys {
				if _, ok := r[k]; !ok {
					t.Fatalf("a table_activity row has no %s: %v", k, r)
				}
			}
			if r["table_name"] == name {
				if h, _ := r["heap_blks_read"].(int64); h > 0 {
					got = r
				} else if h2, _ := r["heap_blks_hit"].(int64); h2 > 0 {
					got = r
				}
			}
		}
	}
	if got == nil {
		t.Fatalf("%s: no row with its heap blocks counted in 6 s", name)
	}
}
