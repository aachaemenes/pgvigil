package demo

import (
	"strings"
	"testing"
	"time"
)

// TestCustomIdleQuiet: the idle_in_transaction custom check stays ok on every primary but aurora-crm01 (whose climb
// is the scenario) at every 5-minute mark of the week before an anchor and the half hour after it, whatever the
// anchor's time of day: proof-demo's overview lists custom@ only for crm01's climb and erp01's triggers. The 13:20 UTC
// anchor of 2026-11-11 put demo-rds-orders01 at 5 by its load and the noise alone.
func TestCustomIdleQuiet(t *testing.T) {
	anchors := []time.Time{anchor, time.Date(2026, 11, 11, 13, 20, 0, 0, time.UTC), time.Date(2026, 11, 13, 15, 0, 0, 0, time.UTC)}
	for i, s := range Specs("demo-", 12) {
		if s.Engine == EngineSQLServer || s.Replica || strings.HasSuffix(s.Name, "aurora-crm01") {
			continue
		}
		for _, end := range anchors {
			g := NewGen(s, i, 1, end.Add(-7*24*time.Hour), end)
			for at := end.Add(-7 * 24 * time.Hour).Truncate(5 * time.Minute); !at.After(end.Add(30 * time.Minute)); at = at.Add(5 * time.Minute) {
				for _, r := range g.customDemoRows(at, false) {
					if r["kind"] == "result" && r["check_name"] == "idle_in_transaction" && r["status"] != "ok" {
						t.Fatalf("%s at %s: idle_in_transaction %v (%v)", s.Name, at.Format(time.RFC3339), r["status"], r["value"])
					}
				}
			}
		}
	}
}
