package collect

import (
	"os"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/logparse"
)

// The log readers' auto_explain events become import_plans rows: one per plan event, in the shape import_plans
// takes, with the duration and the query text from the plan; under none no plan is kept; other kinds and other
// collections give nothing.
func TestPlanRowsFromLog(t *testing.T) {
	plan, err := os.ReadFile("../plans/testdata/sortspill.txt")
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 11, 9, 23, 0, 0, 0, time.UTC)
	rows := []Row{
		{"kind": "event", "kind_of": string(logparse.Plan), "at": at, "duration_ms": 1802.114, "datname": "orders", "usename": "app", "statement": string(plan)},
		{"kind": "event", "kind_of": "slow", "at": at, "duration_ms": 950.0, "datname": "orders", "usename": "app", "statement": "SELECT 1"},
		{"kind": "cursor", "source": "x", "read_to": at},
	}
	out := planRowsFromLog("serverlog", rows, "full")
	if len(out) != 1 {
		t.Fatalf("want one plan row, got %d: %v", len(out), out)
	}
	r := out[0]
	if r["source"] != "auto_explain" {
		t.Errorf("source = %v, want auto_explain", r["source"])
	}
	if r["datname"] != "orders" || r["usename"] != "app" {
		t.Errorf("database / user not carried: %v %v", r["datname"], r["usename"])
	}
	if d, ok := r["duration_ms"].(float64); !ok || d != 1802.114 {
		t.Errorf("duration_ms = %#v, want 1802.114", r["duration_ms"])
	}
	if s, _ := r["plan_text"].(string); s == "" {
		t.Errorf("no plan text in the row: %v", r)
	}
	// a duration at or over 1,000,000 ms must print in plain decimal: the auto_explain pattern reads "1000000.5 ms", not "1e+06"
	big := []Row{{"kind": "event", "kind_of": string(logparse.Plan), "at": at, "duration_ms": 1000000.5, "datname": "orders", "usename": "app", "statement": string(plan)}}
	if out := planRowsFromLog("serverlog", big, "full"); len(out) != 1 {
		t.Fatalf("a 1,000,000.5 ms plan must give one row, got %d", len(out))
	} else if d, _ := out[0]["duration_ms"].(float64); d != 1000000.5 {
		t.Errorf("duration_ms = %#v, want 1000000.5", out[0]["duration_ms"])
	}
	if out := planRowsFromLog("logs", rows, "none"); len(out) != 0 {
		t.Errorf("none must keep no plan, got %d", len(out))
	}
	if out := planRowsFromLog("activity", rows, "full"); out != nil {
		t.Errorf("another collection must give nothing, got %v", out)
	}
	if out := planRowsFromLog("serverlog", rows[1:], "full"); out != nil {
		t.Errorf("a batch without plan events must give nothing, got %v", out)
	}
}
