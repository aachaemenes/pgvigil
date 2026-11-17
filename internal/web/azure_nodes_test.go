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
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAzureSummaryByServerAndPoolOnAStore (P25 task 7: DBA Dash's logical server and elastic pool nodes): on a migrated
// repository (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/azuredb/summary takes server= (one logical server) and
// pool= (one elastic pool of that server) and cuts every part to the Azure SQL Databases there - the databases grid,
// the Elastic Pool grid, the Service Objectives changes and the Resource Governance grid; the databases part names each
// database's logical server (the pool's member row, else the instance's own server name, else its governance row's).
func TestAzureSummaryByServerAndPoolOnAStore(t *testing.T) {
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
	tag := fmt.Sprintf("aznode:%d", sfx)
	srvA, srvB := fmt.Sprintf("srva-%d", sfx), fmt.Sprintf("srvb-%d", sfx)
	ids := map[string]int{}
	var all []int
	for _, n := range []string{"a", "b", "c", "d"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
			fmt.Sprintf("aznode-%s-%d", n, sfx), tag).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
		all = append(all, id)
	}
	defer func() {
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
	at := time.Now().UTC().Truncate(time.Minute).Add(-30 * time.Minute)
	// a and b: pool1 of server A (the pool's member rows); c: server A alone, named by its governance row; d: server B,
	// named by the instance's own server name; c changed tier once
	exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $3, 'pool1', $4), ($2, $3, 'pool1', $4)`, ids["a"], ids["b"], srvA, at)
	exec(`INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, server_name) VALUES ($1, $2, $3)`, ids["d"], at, srvB)
	for _, n := range []string{"a", "b"} {
		exec(`INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, pool, gov)
		      VALUES ($1, now(), $2, 'Standard', 'ElasticPool', 'pool1', jsonb_build_object('server_name', $3::text))`, ids[n], at, srvA)
	}
	exec(`INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, dtu_limit, gov)
	      VALUES ($1, now(), $2, 'Standard', 'S3', 100, jsonb_build_object('server_name', $3::text))`, ids["c"], at, srvA)
	exec(`INSERT INTO pgvigil.mssql_azuredb_governance_history (instance_id, valid_from, valid_to, edition, service_objective, dtu_limit, gov)
	      VALUES ($1, $2, $3, 'Standard', 'S1', 20, '{}'), ($1, $3, 'infinity', 'Standard', 'S3', 100, '{}')`, ids["c"], at.Add(-2*time.Hour), at)
	exec(`INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, dtu_limit, gov)
	      VALUES ($1, now(), $2, 'Basic', 'Basic', 5, '{}')`, ids["d"], at)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(server, poolName string) map[string][]map[string]any {
		t.Helper()
		q := url.Values{"from": {at.Add(-10 * time.Minute).Format(time.RFC3339)}, "to": {at.Add(10 * time.Minute).Format(time.RFC3339)}, "tag": {tag}}
		if server != "" {
			q.Set("server", server)
		}
		if poolName != "" {
			q.Set("pool", poolName)
		}
		rec := httptest.NewRecorder()
		s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		out := map[string][]map[string]any{}
		for name, tb := range raw {
			if tb == nil {
				continue
			}
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out[name] = append(out[name], m)
			}
		}
		return out
	}
	// names: the letters of the rows' instances (aznode-<letter>-<sfx>), sorted
	names := func(rows []map[string]any) string {
		var l []string
		for _, r := range rows {
			l = append(l, strings.Split(fmt.Sprint(r["instance"]), "-")[1])
		}
		sort.Strings(l)
		return strings.Join(l, ",")
	}
	whole := call("", "")
	if got := names(whole["databases"]); got != "a,b,c,d" {
		t.Errorf("the tag: databases %s, want a,b,c,d", got)
	}
	servers := map[string]string{}
	for _, r := range whole["databases"] {
		servers[strings.Split(fmt.Sprint(r["instance"]), "-")[1]] = fmt.Sprint(r["server"])
	}
	if fmt.Sprint(servers["a"], " ", servers["b"], " ", servers["c"], " ", servers["d"]) != strings.Join([]string{srvA, srvA, srvA, srvB}, " ") {
		t.Errorf("the databases' logical servers %v, want a, b and c on %s (the pool's members, the governance row) and d on %s (the server name)", servers, srvA, srvB)
	}
	a := call(srvA, "")
	if got := names(a["databases"]); got != "a,b,c" {
		t.Errorf("server=%s: databases %s, want a,b,c (d is on %s)", srvA, got, srvB)
	}
	if got := names(a["governance"]); got != "a,b,c" {
		t.Errorf("server=%s: governance rows %s, want a,b,c", srvA, got)
	}
	if got := names(a["slo_history"]); got != "c" {
		t.Errorf("server=%s: Service Objectives changes %s, want c's one", srvA, got)
	}
	if len(a["pools"]) != 1 || fmt.Sprint(a["pools"][0]["pool"], " ", a["pools"][0]["databases"]) != "pool1 2" {
		t.Errorf("server=%s: pools %v, want pool1 with 2 databases", srvA, a["pools"])
	}
	// a server's name is matched as SQL Server matches it (no case)
	if got := names(call(strings.ToUpper(srvB), "")["databases"]); got != "d" {
		t.Errorf("server=%s: databases %s, want d", strings.ToUpper(srvB), got)
	}
	if b := call(srvB, ""); len(b["pools"]) != 0 || len(b["slo_history"]) != 0 {
		t.Errorf("server=%s: pools %v, changes %v, want none (d is in no pool and never changed tier)", srvB, b["pools"], b["slo_history"])
	}
	p := call(srvA, "pool1")
	if got := names(p["databases"]); got != "a,b" {
		t.Errorf("server=%s&pool=pool1: databases %s, want a,b (c is in no pool)", srvA, got)
	}
	if got := names(p["governance"]); got != "a,b" {
		t.Errorf("server=%s&pool=pool1: governance rows %s, want a,b", srvA, got)
	}
	if len(p["slo_history"]) != 0 {
		t.Errorf("server=%s&pool=pool1: changes %v, want none (c's change is not the pool's)", srvA, p["slo_history"])
	}
	if got := names(call(srvB, "pool1")["databases"]); got != "" {
		t.Errorf("server=%s&pool=pool1: databases %s, want none (pool1 is %s's)", srvB, got, srvA)
	}
	// a pool without its server names no pool: refused, as an empty server is
	rec := httptest.NewRecorder()
	s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?pool=pool1&tag="+url.QueryEscape(tag), nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("pool= without server=: %d %s, want 400 (a pool's name is its server's)", rec.Code, rec.Body.String())
	}
}
