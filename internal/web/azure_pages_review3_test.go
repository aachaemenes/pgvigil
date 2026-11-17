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
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAzurePagesReview3 (the review t11-3 of the Azure pages: BLOCKER 1, SHOULD 2, SHOULD 3, NIT 4, NIT 6, NIT 7;
// P25 tasks 7, 8 and 10). The check reads the source:
//   - the Azure Summary's tier cell jumps to the Service Objectives changes below WITHOUT a '#azure-slo' link: the app
//     routes on the hash, so that link opened the fleet Summary with the tag and the range dropped;
//   - the pool page reads its pool through a member that holds the pool's own read (pool_read), not the first member;
//   - Columns per chart never forces N charts into a narrow page: the tracks keep a floor and wrap (auto-fill), and the
//     gap is the house token;
//   - the empty node page's words have no space before their colon;
//   - the pool grid's minutes column sorts as a number;
//   - a failed pool read leaves the pool page's Summary standing (its own error box).
func TestAzurePagesReview3(t *testing.T) {
	read := func(file string) string {
		t.Helper()
		b, err := os.ReadFile("../../web/src/" + file)
		if err != nil {
			t.Fatalf("web/src/%s: %v", file, err)
		}
		return string(b)
	}
	az := read("azuredb.ts")
	if strings.Contains(az, "href: '#azure-slo'") {
		t.Error("azuredb.ts: the tier cell is a link to '#azure-slo' (the app routes on the hash: the click leaves the page)")
	}
	for _, w := range []string{"getElementById('azure-slo')", "scrollIntoView("} {
		if !strings.Contains(az, w) {
			t.Errorf("azuredb.ts: the tier cell's jump has no %s (the Service Objectives changes below, on this page)", w)
		}
	}
	if !strings.Contains(az, "x.pool_read") {
		t.Error("azuredb.ts: the pool page's member is not chosen by pool_read (a member with the pool's own read first)")
	}
	if strings.Contains(az, "${at}: this page") {
		t.Error("azuredb.ts: the empty node page's words keep the space before their colon ('... the logical server S : this page')")
	}
	ch := read("azure_charts.ts")
	if strings.Contains(ch, "repeat(${columns}, minmax(0, 1fr))") {
		t.Error("azure_charts.ts layout forces the chosen number of charts a row at every width (a phone gets charts under 200 px)")
	}
	for _, w := range []string{"auto-fill", "320px", "var(--sp-4)"} {
		if !strings.Contains(ch, w) {
			t.Errorf("azure_charts.ts layout has no %s (tracks that keep a floor and wrap, the house gap)", w)
		}
	}
	pl := read("pools.ts")
	if !strings.Contains(pl, "{ key: 'minutes', label: 'minutes', num: true") {
		t.Error("pools.ts: the pool grid's minutes column is not a number column (it sorts '12' before '9')")
	}
	if !strings.Contains(read("azure_nodes.ts"), "mssqlPoolView({ ...ctx, instance: member }).catch(") {
		t.Error("azure_nodes.ts: a failed pool read replaces the whole pool page (no .catch on mssqlPoolView)")
	}
}

// TestAzurePoolReadMemberOnAStore (the review t11-3 SHOULD 2): on a store (PGVIGIL_REPO_TEST_DSN, skipped without
// it) /api/azuredb/summary part=databases says for each database whether its pool comes from its own pool member row
// (pool_read: the database's pool read stored it, so the Elastic pool page read through it has the pool's minutes) or
// only from its governance row (false: 'No pool read for this database' there) - the pool page picks a true one.
func TestAzurePoolReadMemberOnAStore(t *testing.T) {
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
	server := fmt.Sprintf("srvr-%d", sfx)
	ids := map[string]int{}
	var all []int
	for _, n := range []string{"gov", "mem"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("azrd-%s-%d", n, sfx)).Scan(&id); err != nil {
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
	now := time.Now().UTC().Truncate(time.Minute)
	// gov: in the pool by its governance row alone (its pool read stored no member row); mem: by its member row
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, pool, gov)
	      VALUES ($1, $2, $2, 'Basic', 'ElasticPool', 'poolr', jsonb_build_object('server_name', $3::text))`, ids["gov"], now.Add(-5*time.Minute), server); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $2, 'poolr', $3)`,
		ids["mem"], server, now); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	q := url.Values{"server": {server}, "pool": {"poolr"}, "part": {"databases"},
		"from": {now.Add(-time.Hour).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}}
	rec := httptest.NewRecorder()
	s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/api/azuredb/summary %s: %d %s", q.Encode(), rec.Code, rec.Body.String())
	}
	raw := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	if tb := raw["databases"]; tb != nil {
		at := -1
		idAt := -1
		for i, c := range tb.Columns {
			switch c {
			case "pool_read":
				at = i
			case "instance_id":
				idAt = i
			}
		}
		if at < 0 || idAt < 0 {
			t.Fatalf("part=databases has no pool_read column (columns %v)", tb.Columns)
		}
		for _, r := range tb.Rows {
			for n, id := range ids {
				if fmt.Sprint(r[idAt]) == fmt.Sprint(id) {
					got[n] = fmt.Sprint(r[at])
				}
			}
		}
	}
	if got["gov"] != "false" || got["mem"] != "true" {
		t.Errorf("pool_read %v, want gov false (its pool from its governance row alone) and mem true (its own member row)", got)
	}
}
