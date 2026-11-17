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

// TestAzureReadReplicaOnAStore (P25 finding L109's read-replica node, the lead 10:4x: DBA Dash's '(read-only)' leaf,
// issue #2047): on a store (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/azuredb/summary part=databases gives each
// Azure SQL Database's replica role from its newest stored minute (0145: 0 primary, 1 high-availability secondary, 2
// geo-replication forwarder, 3 named replica) and read_only for a role over 0 - so a database read through a read-only
// connection, which reports its primary's server and database names, is told apart on the Summary and in the tree.
func TestAzureReadReplicaOnAStore(t *testing.T) {
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
	tag, server := fmt.Sprintf("azrr:%d", sfx), fmt.Sprintf("srvr-%d", sfx)
	ids := map[string]int{}
	var all []int
	for _, n := range []string{"primary", "replica"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
			fmt.Sprintf("azrr-%s-%d", n, sfx), tag).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
		all = append(all, id)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = ANY ($1)`, all)
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, all); err != nil {
			t.Error(err)
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	now := time.Now().UTC().Truncate(time.Minute)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_azuredb_minute', $1)`, now.Add(-10*time.Minute))
	z := `'{0,0,0,0,0,0,0,0,0,0}'`
	for n, role := range map[string]int{"primary": 0, "replica": 1} {
		// an older minute with role 0 on both: the newest minute's role is the one read
		for i, r := range []int{0, role} {
			exec(`INSERT INTO pgvigil.mssql_azuredb_minute (instance_id, snapshot_at, samples, replica_role, dtu_buckets, cpu_buckets, data_buckets, log_buckets)
			      VALUES ($1, $2, 4, $3, `+z+`, `+z+`, `+z+`, `+z+`)`, ids[n], now.Add(time.Duration(i-5)*time.Minute), r)
		}
		exec(`INSERT INTO pgvigil.mssql_azuredb_read (instance_id, newest_minute, read_at) VALUES ($1, $2, $3)`, ids[n], now.Add(-4*time.Minute), now)
		exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $2, 'pool1', $3)`, ids[n], server, now)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	q := url.Values{"from": {now.Add(-time.Hour).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}, "tag": {tag}, "part": {"databases"}}
	rec := httptest.NewRecorder()
	s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	raw := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	if tb := raw["databases"]; tb != nil {
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			for n, id := range ids {
				if fmt.Sprint(m["instance_id"]) == fmt.Sprint(id) {
					got[n] = fmt.Sprintf("%v %v", m["replica_role"], m["read_only"])
				}
			}
		}
	}
	if got["primary"] != "0 false" || got["replica"] != "1 true" {
		t.Errorf("replica roles %v, want the primary '0 false' and the replica '1 true' (its newest minute's role)", got)
	}
}
