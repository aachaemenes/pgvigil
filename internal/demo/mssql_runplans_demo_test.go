package demo

import (
	"encoding/xml"
	"strings"
	"testing"
	"time"
)

// TestRunningPlansDemo: each demo SQL Server instance sends mssql_running_plans with every mssql_requests snapshot: the
// policy row first, a 'running' row for each request whose plan meets the threshold (the same hashes and offsets), its
// plan the first time and then at most once an hour, a ShowPlanXML document carrying the request's hashes and the
// demo-data note; sql01's report and sql03's lookup are kept within the seed's days; the collection is in the log list.
func TestRunningPlansDemo(t *testing.T) {
	specs := Specs("demo-", FleetSize)
	for i, s := range specs[12:] {
		idx := 12 + i
		g := NewGen(s, idx, 7, Grid(anchor, 7)[0], anchor)
		listed := false
		for _, c := range g.Collections() {
			listed = listed || c == "mssql_running_plans"
		}
		if !listed {
			t.Errorf("%s: mssql_running_plans is not in the collection list", s.Name)
		}
		reqs := map[string][]Row{}
		var plans []Batch
		for _, b := range run(t, s, idx, 7) {
			switch b.Collection {
			case "mssql_requests":
				reqs[b.At.String()] = b.Rows
			case "mssql_running_plans":
				plans = append(plans, b)
			}
		}
		if len(plans) != len(reqs) {
			t.Fatalf("%s: %d running-plan batches for %d request snapshots", s.Name, len(plans), len(reqs))
		}
		lastPlan := map[string]time.Time{}
		kept := map[string]bool{}
		for _, b := range plans {
			if len(b.Rows) == 0 || b.Rows[0]["kind"] != "plan_policy" || b.Rows[0]["statement"] != "kept" {
				t.Fatalf("%s at %v: the first row is not the policy row: %v", s.Name, b.At, b.Rows)
			}
			byKey := map[string]Row{}
			for _, r := range b.Rows[1:] {
				byKey[toStr(r["query_hash_hex"])+toStr(r["plan_hash_hex"])] = r
			}
			for _, q := range reqs[b.At.String()] {
				if q["kind"] != "request" || q["plan_handle"] == nil {
					continue
				}
				meets := toInt64(q["cpu_ms"]) >= runPlanCPUms || toInt64(q["granted_memory_kb"])/8 >= runPlanGrantPages || toInt64(q["elapsed_ms"]) >= runPlanRunningMs
				r, has := byKey[toStr(q["stmt_query_hash"])+toStr(q["stmt_plan_hash"])]
				if meets != has {
					t.Fatalf("%s at %v: session %v meets the threshold %v, has a running row %v", s.Name, b.At, q["session_id"], meets, has)
				}
				if !has {
					continue
				}
				if r["stmt_start"] != q["stmt_start"] || r["stmt_end"] != q["stmt_end"] || r["database_name"] != q["database_name"] || r["reasons"] == "" {
					t.Fatalf("%s at %v: the running row %v for the request %v", s.Name, b.At, r, q)
				}
				k := toStr(r["query_hash_hex"]) + toStr(r["plan_hash_hex"])
				kept[toStr(q["sql_handle"])] = true
				x, _ := r["statement"].(string)
				if x == "" {
					continue
				}
				if r["kind_of"] != "plan" || r["plan_state"] != "read" || !strings.HasPrefix(toStr(r["plan_note"]), "demo data") {
					t.Fatalf("%s at %v: a plan row without its state or note: %v", s.Name, b.At, r)
				}
				var doc struct {
					XMLName xml.Name
					Stmts   []struct {
						QueryHash     string `xml:"QueryHash,attr"`
						QueryPlanHash string `xml:"QueryPlanHash,attr"`
					} `xml:"BatchSequence>Batch>Statements>StmtSimple"`
				}
				if err := xml.Unmarshal([]byte(x), &doc); err != nil || doc.XMLName.Local != "ShowPlanXML" || len(doc.Stmts) != 1 {
					t.Fatalf("%s at %v: the plan is not a one-statement ShowPlanXML document (%v)", s.Name, b.At, err)
				}
				if doc.Stmts[0].QueryHash != q["stmt_query_hash"] || doc.Stmts[0].QueryPlanHash != q["stmt_plan_hash"] {
					t.Fatalf("%s at %v: the plan's hashes %v for the request's %v / %v", s.Name, b.At, doc.Stmts[0], q["stmt_query_hash"], q["stmt_plan_hash"])
				}
				if prev, ok := lastPlan[k]; ok && b.At.Sub(prev) < runPlanEvery {
					t.Fatalf("%s at %v: a plan sent again %v after the last", s.Name, b.At, b.At.Sub(prev))
				}
				lastPlan[k] = b.At
			}
		}
		switch {
		case strings.HasSuffix(s.Name, "-sql01") && !kept[mssqlHandleReport]:
			t.Errorf("%s: the report's plan never kept", s.Name)
		case strings.HasSuffix(s.Name, "-sql03") && !kept[mssqlHandleLookup]:
			t.Errorf("%s: the lookup's plan never kept", s.Name)
		}
	}
	for h := range runPlanFiles {
		if runPlanXML(h, "0x1", "0x2") == "" {
			t.Errorf("no captured plan for the statement of %s", h)
		}
	}
}
