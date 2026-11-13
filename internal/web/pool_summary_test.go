package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPoolSummaryCellOnAStore (CLOUDSQL C4's wiring 2): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it) the SQL Server Summary's Elastic Pool Storage cell is DBA Dash's status of the database's pool's newest
// minute - OK at 1.3 %, a warning over 80 %, critical over 90 % (the default thresholds) - and n/a for a server where
// mssql_pool is skipped and for one where it never ran.
func TestPoolSummaryCellOnAStore(t *testing.T) {
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
	server := fmt.Sprintf("srv-%d", sfx)
	ids := make([]int, 3) // in the pool; mssql_pool skipped; mssql_pool never ran
	for i := range ids {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("poolsum%d-%d", i, sfx)).Scan(&ids[i]); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, server); err != nil {
			t.Error(err)
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, ids); err != nil {
			t.Error(err)
		}
	}()
	for i, status := range []string{"ok", "skipped"} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_pool', now(), $2)`, ids[i], status); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC().Truncate(time.Minute)
	type row struct {
		state, value   string
		sampled        bool
		critical, warn int
		detail         []string
	}
	read := func() map[int]row {
		t.Helper()
		rs, err := pool.Query(ctx, sqlMSSQLSummaryCells, `{}`, 3600)
		if err != nil {
			t.Fatal(err)
		}
		defer rs.Close()
		out := map[int]row{}
		for rs.Next() {
			var id, crit, warn int
			var key, state string
			var sampled bool
			var value, errText *string
			var detail []string
			var readAt, since *time.Time
			if err := rs.Scan(&id, &key, &state, &sampled, &crit, &warn, &value, &detail, &readAt, &errText, &since); err != nil {
				t.Fatal(err)
			}
			if key == "elasticpool" {
				v := ""
				if value != nil {
					v = *value
				}
				out[id] = row{state, v, sampled, crit, warn, detail}
			}
		}
		if err := rs.Err(); err != nil {
			t.Fatal(err)
		}
		return out
	}
	send := func(minutesAgo int, alloc float64) {
		t.Helper()
		p, _ := json.Marshal([]map[string]any{{"server": server, "pool": "p1", "name_from": "service objectives", "samples": 4,
			"minute": now.Add(-time.Duration(minutesAgo) * time.Minute).Format(time.RFC3339), "avg_cpu_percent": 1.0, "max_cpu_percent": 1.0,
			"allocated_storage_percent": alloc, "storage_limit_mb": 5000.0, "avg_edtu_percent": nil}})
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_pool($1, now(), $2::jsonb)`, ids[0], string(p)); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		minutesAgo     int
		alloc          float64
		value          string
		critical, warn int
	}{{3, 1.28, "1.3 %", 0, 0}, {2, 85, "85 %", 0, 1}, {1, 95, "95 %", 1, 0}} {
		send(c.minutesAgo, c.alloc)
		got := read()
		in := got[ids[0]]
		if in.state != "ok" || !in.sampled || in.value != c.value || in.critical != c.critical || in.warn != c.warn ||
			len(in.detail) != 1 || !strings.HasPrefix(in.detail[0], "pool p1 on "+server+": ") || !strings.Contains(in.detail[0], "(warning over 80 %, critical over 90 %)") {
			t.Fatalf("the pooled database at %v %%: %+v; want ok, sampled, %q, critical %d, warning %d, one detail line naming the pool and the thresholds",
				c.alloc, in, c.value, c.critical, c.warn)
		}
		for _, other := range ids[1:] {
			if o := got[other]; o.state != "n/a" || o.sampled || o.critical+o.warn != 0 {
				t.Fatalf("a server in no pool (instance %d): %+v; want n/a", other, o)
			}
		}
	}
}
