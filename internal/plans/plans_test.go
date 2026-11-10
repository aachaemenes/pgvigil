package plans

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The recorded plans in testdata are EXPLAIN (ANALYZE, FORMAT TEXT) and (FORMAT JSON) of the shapes in
// testdata/shapes.txt over testdata/seed.sql, on PostgreSQL 18.6 (two runs of one statement: the numbers differ
// between the two files, the structure does not).

// ruleFields are the node fields the 0029 rules read; numbers are compared by presence and, for the structural
// ones, by value.
var ruleFields = []string{"Node Type", "Relation Name", "CTE Name", "Index Name", "Join Type", "Parent Relationship", "Sort Space Type",
	"Workers Planned", "Workers Launched", "Plan Rows", "Actual Loops"}

var presentFields = []string{"Actual Rows", "Rows Removed by Filter", "Hash Batches", "HashAgg Batches", "Lossy Heap Blocks", "Heap Fetches", "Sort Space Used"}

func walk(n map[string]any, f func(map[string]any)) {
	f(n)
	kids, _ := n["Plans"].([]any)
	for _, k := range kids {
		if m, ok := k.(map[string]any); ok {
			walk(m, f)
		}
	}
}

func nodes(top map[string]any) []map[string]any {
	var out []map[string]any
	walk(top["Plan"].(map[string]any), func(m map[string]any) { out = append(out, m) })
	return out
}

func norm(v any) string {
	switch x := v.(type) {
	case nil:
		return "<nil>"
	case float64:
		return fmt.Sprintf("%g", x)
	case json.Number:
		return x.String()
	}
	return fmt.Sprint(v)
}

func TestTextMatchesJSON(t *testing.T) {
	files, _ := filepath.Glob("testdata/*.json")
	if len(files) < 13 {
		t.Fatalf("recorded plans: %d, want the 13 shapes", len(files))
	}
	for _, jf := range files {
		name := strings.TrimSuffix(filepath.Base(jf), ".json")
		t.Run(name, func(t *testing.T) {
			jb, _ := os.ReadFile(jf)
			tb, err := os.ReadFile(strings.TrimSuffix(jf, ".json") + ".txt")
			if err != nil {
				t.Fatal(err)
			}
			jo, err := NormalizeJSON(jb)
			if err != nil {
				t.Fatal(err)
			}
			to, err := ParseText(string(tb))
			if err != nil {
				t.Fatal(err)
			}
			jn, tn := nodes(jo), nodes(to)
			if len(jn) != len(tn) {
				t.Fatalf("nodes: json %d, text %d", len(jn), len(tn))
			}
			for i := range jn {
				for _, f := range ruleFields {
					if f == "Relation Name" && jn[i]["Node Type"] == "ModifyTable" {
						continue
					}
					if f == "Parent Relationship" && i == 0 {
						continue
					}
					if f == "Plan Rows" || f == "Actual Loops" { // present in both; values differ between the two runs only for loops of parallel nodes
						if (jn[i][f] == nil) != (tn[i][f] == nil) {
							t.Errorf("node %d %s: json %v, text %v", i, f, jn[i][f], tn[i][f])
						}
						continue
					}
					if norm(jn[i][f]) != norm(tn[i][f]) {
						t.Errorf("node %d (%v) %s: json %v, text %v", i, jn[i]["Node Type"], f, norm(jn[i][f]), norm(tn[i][f]))
					}
				}
				for _, f := range presentFields {
					if (jn[i][f] == nil) != (tn[i][f] == nil) {
						t.Errorf("node %d (%v) %s present: json %v, text %v", i, jn[i]["Node Type"], f, jn[i][f], tn[i][f])
					}
				}
			}
			if (jo["Execution Time"] == nil) != (to["Execution Time"] == nil) {
				t.Errorf("Execution Time: json %v, text %v", jo["Execution Time"], to["Execution Time"])
			}
			jt, _ := jo["Triggers"].([]any)
			tt, _ := to["Triggers"].([]any)
			if len(jt) != len(tt) {
				t.Errorf("Triggers: json %v, text %v", jt, tt)
			}
			if jt, ok := jo["JIT"].(map[string]any); ok {
				tt, _ := to["JIT"].(map[string]any)
				if tt == nil || tt["Timing"] == nil || jt["Timing"] == nil {
					t.Errorf("JIT timing: json %v, text %v", jt, tt)
				}
			}
		})
	}
}

func TestBuild(t *testing.T) {
	jb, _ := os.ReadFile("testdata/sortspill.json")
	r := Build(Explained, time.Unix(0, 0), "", "db1", "select 1", string(jb))
	if r.Format != "json" || !r.Analyzed || r.Plan == nil || r.PlanNote != "" || !strings.HasPrefix(r.PlanKey, "explain:") {
		t.Fatalf("json build: %+v", r)
	}
	tb, _ := os.ReadFile("testdata/sortspill.txt")
	r = Build(Explained, time.Unix(0, 0), "k1", "db1", "", string(tb))
	if r.Format != "text" || !r.Analyzed || r.Plan == nil || r.PlanKey != "k1" {
		t.Fatalf("text build: %+v", r)
	}
	r = Build(Explained, time.Unix(0, 0), "", "", "", "not a plan")
	if r.Plan != nil || !strings.Contains(r.PlanNote, "no plan node") {
		t.Fatalf("garbage: %+v", r)
	}
}

func TestFromLogMessage(t *testing.T) {
	text := "duration: 1503.221 ms  plan:\n\tQuery Text: select count(*)\n\t  from t40 where v = 1\n\tAggregate  (cost=1.00..2.00 rows=1 width=8) (actual time=1.0..1.0 rows=1.00 loops=1)\n\t  ->  Seq Scan on t40  (cost=0.00..1.00 rows=2000 width=0) (actual time=0.1..0.9 rows=2000.00 loops=1)\n\t        Filter: (v = 1)\n\t        Rows Removed by Filter: 198000"
	r, ok := FromLogMessage(time.Unix(10, 0), "db1", "u1", text)
	if !ok || r.Source != AutoExplain || r.Format != "text" || r.DurationMS == nil || *r.DurationMS != 1503.221 {
		t.Fatalf("text message: ok %v %+v", ok, r)
	}
	if r.Query != "select count(*)\n  from t40 where v = 1" {
		t.Errorf("query %q", r.Query)
	}
	var top map[string]any
	_ = json.Unmarshal(r.Plan, &top)
	n := nodes(top)
	if len(n) != 2 || n[1]["Relation Name"] != "t40" || norm(n[1]["Rows Removed by Filter"]) != "198000" {
		t.Errorf("nodes %v", n)
	}
	js := "duration: 12.5 ms  plan:\n{\n  \"Query Text\": \"select 1\",\n  \"Plan\": {\"Node Type\": \"Result\", \"Plan Rows\": 1, \"Actual Rows\": 1, \"Actual Loops\": 1}\n}"
	r, ok = FromLogMessage(time.Unix(10, 0), "db1", "u1", js)
	if !ok || r.Format != "json" || r.Query != "select 1" || !r.Analyzed {
		t.Fatalf("json message: %+v", r)
	}
	if _, ok := FromLogMessage(time.Now(), "", "", "duration: 5 ms  statement: select 1"); ok {
		t.Error("a slow statement line read as a plan")
	}
}

func TestScanSQL(t *testing.T) {
	cases := []struct {
		in       string
		kw       string
		max      int
		multiple bool
		unterm   bool
	}{
		{"select * from t where id = $1 and v = $12", "SELECT", 12, false, false},
		{"  -- c\n/* x /* y */ */ WITH a AS (select 1) select * from a", "WITH", 0, false, false},
		{"select '$1', \"$2\", $$ $3 $$, $tag$ $4 $tag$ from t", "SELECT", 0, false, false},
		{"select 1; drop table t", "SELECT", 0, true, false},
		{"select 1;  ", "SELECT", 0, false, false},
		{"select 'it''s; $5'", "SELECT", 0, false, false},
		{"select E'a\\'; drop table t'", "SELECT", 0, false, false},
		{"select 'open", "SELECT", 0, false, true},
		{"update t set v = $2 where id = $1", "UPDATE", 2, false, false},
		{"select a$1 from t", "SELECT", 0, false, false},
		{"(select 1)", "(", 0, false, false},
	}
	for _, c := range cases {
		s := ScanSQL(c.in)
		if s.Keyword != c.kw || s.MaxParam != c.max || s.Multiple != c.multiple || s.Unterminated != c.unterm {
			t.Errorf("%q: %+v", c.in, s)
		}
	}
	if ok, _ := ScanSQL("vacuum t").Explainable(); ok {
		t.Error("vacuum explainable")
	}
	if ok, _ := ScanSQL("delete from t").ReadOnlyKind(); ok {
		t.Error("delete taken for EXPLAIN ANALYZE")
	}
	if ok, _ := ScanSQL("with x as (select 1) select * from x").ReadOnlyKind(); !ok {
		t.Error("a WITH query refused")
	}
}

// TestDumpRows is the proof's door into the parser (scripts/proof-plans.sh): with PLANS_DUMP_IN set it reads that
// file, either auto_explain log messages separated by a line holding only "--8<--" (PLANS_DUMP_KIND=log) or one
// plan per file (PLANS_DUMP_KIND=text|json, the plan text as EXPLAIN printed it), and writes the import_plans
// payload to PLANS_DUMP_OUT. Without the variables it is skipped.
func TestDumpRows(t *testing.T) {
	in, out := os.Getenv("PLANS_DUMP_IN"), os.Getenv("PLANS_DUMP_OUT")
	if in == "" || out == "" {
		t.Skip("PLANS_DUMP_IN / PLANS_DUMP_OUT not set")
	}
	b, err := os.ReadFile(in)
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now()
	var rows []Row
	switch os.Getenv("PLANS_DUMP_KIND") {
	case "log":
		for _, msg := range strings.Split(string(b), "\n--8<--\n") {
			if strings.TrimSpace(msg) == "" {
				continue
			}
			r, ok := FromLogMessage(at, os.Getenv("PLANS_DUMP_DB"), os.Getenv("PLANS_DUMP_USER"), strings.TrimSpace(msg))
			if !ok {
				t.Fatalf("not an auto_explain message: %.80q", msg)
			}
			rows = append(rows, r)
		}
	default:
		rows = append(rows, Build(Source(os.Getenv("PLANS_DUMP_SOURCE")), at, os.Getenv("PLANS_DUMP_KEY"), os.Getenv("PLANS_DUMP_DB"), os.Getenv("PLANS_DUMP_QUERY"), string(b)))
	}
	for _, r := range rows {
		if r.Plan == nil {
			t.Fatalf("a plan did not parse: %s", r.PlanNote)
		}
	}
	p, _ := json.Marshal(rows)
	if err := os.WriteFile(out, p, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestMask(t *testing.T) {
	up := func(s string) string { return "#" + strings.ToUpper(s) + "#" }
	tb, _ := os.ReadFile("testdata/filter.txt")
	r := Build(Explained, time.Unix(0, 0), "", "", "select * from t40 where v = 1", string(tb))
	if !Mask(&r, "normalized", up) {
		t.Fatal("normalized dropped the row")
	}
	if !strings.Contains(r.PlanText, "Filter: #(V = 1)#") || !strings.Contains(r.PlanText, "(cost=") || r.Query != "#SELECT * FROM T40 WHERE V = 1#" {
		t.Errorf("text masked:\n%s\n%s", r.PlanText, r.Query)
	}
	if strings.Contains(string(r.Plan), `"(v = 1)"`) || !strings.Contains(string(r.Plan), `"#(V = 1)#"`) {
		t.Errorf("json form not masked: %s", r.Plan)
	}
	jb, _ := os.ReadFile("testdata/filter.json")
	r = Build(Explained, time.Unix(0, 0), "", "", "", string(jb))
	Mask(&r, "normalized", up)
	if strings.Contains(r.PlanText, `"(v = 1)"`) {
		t.Errorf("json text not masked: %s", r.PlanText)
	}
	if Mask(&r, "none", up) {
		t.Error("none kept the row")
	}
	r2 := Build(Explained, time.Unix(0, 0), "", "", "q", string(tb))
	before := r2.PlanText
	if !Mask(&r2, "full", up) || r2.PlanText != before {
		t.Error("full changed the row")
	}
}
