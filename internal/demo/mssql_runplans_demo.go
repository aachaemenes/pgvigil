package demo

import (
	"embed"
	"regexp"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// The plans the demo keeps of its SQL Server instances' running queries (mssql_running_plans, task 406: a
// running query's plan on Running queries). The demo turns the collection on for its SQL Server instances, as an admin's
// schedules: line would (cmd/pgvigil/demo.go: RunningPlanInstances), and each snapshot sends what the collector sends
// (internal/mssql/plancache.go runningPlansCollector): the policy row, then one 'running' row per request of the
// mssql_requests snapshot whose plan meets DBA Dash 4.25.0's plan threshold (CPU 1,000 ms, a grant of 6,400 pages,
// 2 requests on the plan, or 10 s running), with its figures; its plan travels the first time the instance sends it and
// then once an hour (runningPlanEvery), through the same credential mask (collect.MaskXML, MaskPlanXML's own).
//
// The plans are DEMO DATA, said so where they are shown: each was captured by scripts/capture-demo-running-plans.sh on
// a scratch SQL Server container that ran the demo's own statement over tables of the demo's names (runplans/README.md);
// the demo's hashes are its own, so the plan's StmtSimple QueryHash and QueryPlanHash are set to the request's, and the
// stored row's plan_note says it is demo data (the page's status line reads it).

//go:embed runplans/*.sqlplan
var runPlanFS embed.FS

// runPlanNote is the stored plan_note of a demo plan: the running plan reply adds it to its words.
const runPlanNote = "demo data: a plan captured on a test server for this statement's text, not read from this instance"

// runPlanFiles: the captured plan of each running statement of the demo, by the statement's sql_handle.
var runPlanFiles = map[string]string{
	mssqlHandleReport:  "runplans/report.sqlplan",
	mssqlHandleLookup:  "runplans/lookup.sqlplan",
	mssqlHandleVictim1: "runplans/victim1.sqlplan",
	mssqlHandleVictim2: "runplans/victim2.sqlplan",
}

// DBA Dash 4.25.0's PlanCollectionThreshold.DefaultThreshold, as internal/mssql/plancache.go reads it.
const (
	runPlanCPUms      = 1000
	runPlanGrantPages = 6400
	runPlanCount      = 2
	runPlanRunningMs  = 10000
	runPlanEvery      = time.Hour
)

var (
	runPlanQueryHash = regexp.MustCompile(`QueryHash="0x[0-9A-Fa-f]+"`)
	runPlanPlanHash  = regexp.MustCompile(`QueryPlanHash="0x[0-9A-Fa-f]+"`)
)

// runPlanFileNote is the comment the seed writes just inside a demo plan's ShowPlanXML root, so a downloaded .sqlplan
// says what it is wherever it is opened (SSMS and the plan readers skip a comment).
const runPlanFileNote = "<!-- demo data: pgvigil's demo shows this plan, captured on a test server for this statement's text; it was not read from any instance -->"

// runPlanCompat is the demo databases' compatibility level (the demo's Query Store rows carry 160 too), sent with each
// running row as the collector sends the database's.
const runPlanCompat = 160

// runPlanXML is the captured plan of a statement with the demo request's hashes and the demo-data comment, or "" when
// the demo has none.
func runPlanXML(sqlHandle, queryHash, planHash string) string {
	f, ok := runPlanFiles[sqlHandle]
	if !ok {
		return ""
	}
	b, err := runPlanFS.ReadFile(f)
	if err != nil {
		return ""
	}
	x := runPlanQueryHash.ReplaceAllString(string(b), `QueryHash="`+queryHash+`"`)
	x = runPlanPlanHash.ReplaceAllString(x, `QueryPlanHash="`+planHash+`"`)
	root := strings.Index(x, "<ShowPlanXML")
	end := strings.Index(x[max(root, 0):], ">")
	if root < 0 || end < 0 {
		return ""
	}
	at := root + end + 1
	return x[:at] + runPlanFileNote + x[at:]
}

// RunningPlanInstances names the fleet's SQL Server instances: the demo turns mssql_running_plans on for each.
func (f *Fleet) RunningPlanInstances() []string {
	var out []string
	for _, g := range f.gens {
		if g.Spec.Engine == EngineSQLServer {
			out = append(out, g.Spec.Name)
		}
	}
	return out
}

// mssqlRunningPlansRows is the mssql_running_plans payload at t for the snapshot's request rows (reqs, the
// mssql_requests payload of the same t).
func (g *Gen) mssqlRunningPlansRows(t time.Time, reqs []Row) []Row {
	out := []Row{{"kind": "plan_policy", "kind_of": "plan", "statement": "kept"}}
	if g.runPlanSent == nil {
		g.runPlanSent = map[string]time.Time{}
	}
	type group struct {
		first                      Row
		requests                   int
		cpu, grantPages, longestMs int64
	}
	var keys []string
	var stats []Row // the plan_stats rows of the plans this snapshot sends (the collector sends them in the same payload)
	groups := map[string]*group{}
	for _, r := range reqs {
		qh, _ := r["stmt_query_hash"].(string)
		ph, _ := r["stmt_plan_hash"].(string)
		handle, _ := r["plan_handle"].(string)
		if r["kind"] != "request" || qh == "" || ph == "" || strings.Trim(strings.TrimPrefix(ph, "0x"), "0") == "" || handle == "" {
			continue
		}
		k := strings.Join([]string{handle, ph, toStr(r["stmt_start"]), toStr(r["stmt_end"])}, "|")
		gr := groups[k]
		if gr == nil {
			gr = &group{first: r}
			groups[k] = gr
			keys = append(keys, k)
		}
		gr.requests++
		gr.cpu += toInt64(r["cpu_ms"])
		gr.grantPages += toInt64(r["granted_memory_kb"]) / 8
		gr.longestMs = max(gr.longestMs, toInt64(r["elapsed_ms"]))
	}
	for _, k := range keys {
		gr := groups[k]
		var reasons []string
		if gr.cpu >= runPlanCPUms {
			reasons = append(reasons, "cpu")
		}
		if gr.grantPages >= runPlanGrantPages {
			reasons = append(reasons, "grant")
		}
		if gr.requests >= runPlanCount {
			reasons = append(reasons, "count")
		}
		if gr.longestMs >= runPlanRunningMs {
			reasons = append(reasons, "duration")
		}
		if len(reasons) == 0 {
			continue
		}
		q := gr.first
		row := Row{"kind": "running", "query_hash_hex": q["stmt_query_hash"], "plan_hash_hex": q["stmt_plan_hash"], "stmt_start": q["stmt_start"],
			"stmt_end": q["stmt_end"], "plan_handle": q["plan_handle"], "database_name": q["database_name"], "requests": gr.requests,
			"cpu_ms": gr.cpu, "grant_kb": gr.grantPages * 8, "longest_ms": gr.longestMs, "reasons": strings.Join(reasons, ","),
			"compatibility_level": runPlanCompat}
		if sent, ok := g.runPlanSent[k]; !ok || t.Sub(sent) >= runPlanEvery {
			sqlHandle, _ := q["sql_handle"].(string)
			if x := runPlanXML(sqlHandle, toStr(q["stmt_query_hash"]), toStr(q["stmt_plan_hash"])); x != "" {
				row["kind_of"], row["statement"], row["plan_bytes"], row["plan_state"], row["plan_note"] = "plan", collect.MaskXML(x), len(x), "read", runPlanNote
				g.runPlanSent[k] = t
				// the statistics the plan was compiled with, as the collector sends them beside a plan it read
				// (internal/mssql statsRows; the Statistics used button reads them)
				for _, st := range mssql.PlanStatsUsed(x) {
					stats = append(stats, Row{"kind": "plan_stats", "stmt": st.Stmt, "stat_database": st.Database, "stat_schema": st.Schema,
						"stat_table": st.Table, "stat_name": st.Statistics, "modification_count": st.ModCount, "sampling_pct": st.SamplingPct,
						"last_update": st.LastUpdate, "query_hash_hex": q["stmt_query_hash"], "plan_hash_hex": q["stmt_plan_hash"],
						"stmt_start": q["stmt_start"], "stmt_end": q["stmt_end"], "database_name": q["database_name"]})
				}
			} else {
				// no captured plan for the statement: said as the collector says it, asked again at the next snapshot
				row["plan_state"] = "no plan"
			}
		}
		out = append(out, row)
	}
	return append(out, stats...)
}

func toStr(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case int:
		return itoa64(int64(x))
	case int64:
		return itoa64(x)
	}
	return ""
}

func toInt64(v any) int64 {
	switch x := v.(type) {
	case int:
		return int64(x)
	case int64:
		return x
	case float64:
		return int64(x)
	}
	return 0
}
