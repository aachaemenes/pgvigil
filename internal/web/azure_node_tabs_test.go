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
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAzureNodeTabsAreWired (P25 (i), the lead's 11:26 GO; DBA Dash's logical server and elastic pool node tabs, map
// rows 31-36 and 53-59): the node pages draw a tab strip in DBA Dash's order (ntab=, the first tab when none), each tab
// the fleet page cut to the node's database ids; the other slices' pages take that cut through one optional parameter
// each, carried by scripts/NODETABS-wiring.patch (applied before this row runs); the router keeps ntab= on a range
// change. The check reads the source.
func TestAzureNodeTabsAreWired(t *testing.T) {
	read := func(file string) string {
		t.Helper()
		b, err := os.ReadFile("../../" + file)
		if err != nil {
			t.Fatalf("%s: %v", file, err)
		}
		return string(b)
	}
	nodes := read("web/src/azure_nodes.ts")
	for _, w := range []string{
		// DBA Dash's order (Main.cs L1887 / L1894): the server's tabs, then the pool's
		`['perfsummary', 'Performance Summary'], ['azuresummary', 'Azure Summary'], ['alerts', 'Alerts'], ['slowqueries', 'Slow Queries'], ['objexec', 'Object Execution'], ['running', 'Running Queries']`,
		`['pool', 'Pool'], ['perfsummary', 'Performance Summary'], ['azuresummary', 'Azure Summary'], ['slowqueries', 'Slow Queries'], ['objexec', 'Object Execution'], ['running', 'Running Queries'], ['dbspace', 'DB Space']`,
		"hashParam('ntab')", "aria-current",
		// each tab's call carries the cut, on the context without the tag (the ids already hold the tag folder's cut)
		"const nctx: Ctx = { ...ctx, tag: undefined }",
		"slowFleetView(nctx, keep)", "runningFleet(nctx, keep)", "alertsView(nctx, keep)", "dbSpaceView(nctx, ids)", "perfSummaryView(nctx, ids)",
		"objectExecutionSection(nctx, undefined, ids)",
	} {
		if !strings.Contains(nodes, w) {
			t.Errorf("web/src/azure_nodes.ts has no %s", w)
		}
	}
	// the other slices' pages, each one optional parameter (their default call unchanged)
	for file, sig := range map[string]string{
		"web/src/running_fleet.ts": "export async function runningFleet(ctx: Ctx, keep?: (r: Row) => boolean)",
		"web/src/alerts.ts":        "export async function alertsView(ctx: Ctx, keep?: (r: Row) => boolean)",
		"web/src/drives.ts":        "export async function dbSpaceView(ctx: Ctx, ids?: number[])",
		"web/src/perfsummary.ts":   "export async function perfSummaryView(ctx: Ctx, ids?: number[])",
		"web/src/mssql_objexec.ts": "export function objectExecutionSection(ctx: Ctx, dbName?: string, ids?: number[])",
	} {
		if !strings.Contains(read(file), sig) {
			t.Errorf("%s has no %s", file, sig)
		}
	}
	// the Performance Summary's ids= is a variant of its statements; sqlPerfScope and the default calls stay as they are
	if !strings.Contains(read("internal/web/q_perfsummary.go"), "i.instance_id = ANY ($5::int[])") {
		t.Error("internal/web/q_perfsummary.go: no statement cut to ids= ($5)")
	}
	// the patch carries exactly the other slices' files, one diff each
	patch := read("scripts/NODETABS-wiring.patch")
	var files []string
	for _, m := range regexp.MustCompile(`(?m)^diff --git a/(\S+) `).FindAllStringSubmatch(patch, -1) {
		files = append(files, m[1])
	}
	if got := strings.Join(files, " "); got != "internal/web/q_perfsummary.go web/src/alerts.ts web/src/drives.ts web/src/perfsummary.ts web/src/running_fleet.ts" {
		t.Errorf("scripts/NODETABS-wiring.patch's files: %q, want the five other slices' files", got)
	}
	if !strings.Contains(read("web/src/router.ts"), "for (const k of ['server', 'pool', 'ntab'])") {
		t.Error("web/src/router.ts: a range change on a node page keeps no ntab=")
	}
}

// TestNodeTabReadsOnAStore (P25 (i)): on a store (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/perfsummary takes
// ids= (the node's databases: only those rows; without it the fleet's, as before), and /api/mssql/procs part=objects
// takes instances= in place of instance= - one list over the node's databases, each row with its instance (DBA Dash's
// server and pool Object Execution, the lead's Q2 (a)).
func TestNodeTabReadsOnAStore(t *testing.T) {
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
	var all []int
	for _, n := range []string{"a", "b", "c"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("aznt-%s-%d", n, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
		all = append(all, id)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = ANY ($1)`, `DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = ANY ($1)`,
			`DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`} {
			if _, err := pool.Exec(context.Background(), q, all); err != nil {
				t.Error(err)
			}
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	at := time.Now().UTC().Truncate(time.Minute).Add(-20 * time.Minute)
	for _, tb := range []string{"mssql_proc_sample", "mssql_proc_read"} {
		exec(`SELECT pgvigil.ensure_month_partition($1, $2)`, tb, at)
	}
	// a and b each ran a procedure (b's the longer); c ran one too, outside the node
	for _, x := range []struct {
		n, proc string
		dur     int
	}{{"a", "usp_a", 50000}, {"b", "usp_b", 90000}, {"c", "usp_c", 70000}} {
		exec(`INSERT INTO pgvigil.mssql_proc_read (instance_id, snapshot_at, interval_secs, procs) VALUES ($1, $2, 60, 1)`, ids[x.n], at)
		exec(`INSERT INTO pgvigil.mssql_proc_sample (instance_id, snapshot_at, database_id, object_id, database_name, schema_name, object_name, type_desc,
		        executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes, interval_secs)
		      VALUES ($1, $2, 5, 101, 'sales', 'dbo', $3, 'SQL_STORED_PROCEDURE', 10, 1000, $4, 100, 0, 0, 60)`, ids[x.n], at, x.proc, x.dur)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	get := func(h func(http.ResponseWriter, *http.Request), path string, q url.Values, part string) []map[string]any {
		t.Helper()
		q.Set("from", at.Add(-10*time.Minute).Format(time.RFC3339))
		q.Set("to", at.Add(10*time.Minute).Format(time.RFC3339))
		q.Set("part", part)
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path+"?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s %s: %d %s", path, q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[part]; tb != nil {
			for _, r := range tb.Rows {
				x := map[string]any{}
				for i, c := range tb.Columns {
					x[c] = r[i]
				}
				out = append(out, x)
			}
		}
		return out
	}
	mine := func(rows []map[string]any) string {
		var got []string
		for _, r := range rows {
			for n, id := range ids {
				if fmt.Sprint(r["instance_id"]) == fmt.Sprint(id) {
					got = append(got, n)
				}
			}
		}
		return strings.Join(got, "")
	}
	node := fmt.Sprintf("%d,%d", ids["a"], ids["b"])
	if got := mine(get(s.PerfSummary, "/api/perfsummary", url.Values{"ids": {node}}, "mssql")); got != "ab" {
		t.Errorf("perfsummary ids=a,b: this test's instances %q, want ab (c is outside the node)", got)
	}
	if got := mine(get(s.PerfSummary, "/api/perfsummary", url.Values{}, "mssql")); got != "abc" {
		t.Errorf("perfsummary without ids: this test's instances %q, want abc (the fleet, as before)", got)
	}
	objs := get(s.MSSQLProcs, "/api/mssql/procs", url.Values{"instances": {node}}, "objects")
	var got []string
	for _, r := range objs {
		got = append(got, fmt.Sprint(r["instance"], " ", r["object_name"]))
	}
	want := fmt.Sprintf("aznt-b-%d usp_b | aznt-a-%d usp_a", sfx, sfx)
	if g := strings.Join(got, " | "); g != want {
		t.Errorf("objects over the node: %q, want %q (one list, the longest first, each with its instance; c's left out)", g, want)
	}
}
