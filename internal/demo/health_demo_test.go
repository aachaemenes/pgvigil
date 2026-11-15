package demo

import (
	"testing"
	"time"
)

// TestDemoHealthRows: the demo's hourly collection health (B6.2) follows the runs it logs, minute by minute: one run
// a collection a minute from the first logged minute; a StmtBroken instance's statements failing every run; onprem-hr01's
// activity partial 2 minutes in 10 (a warning by rate on the page); a replica's vacuum skipped (not a known run, no
// duration); the minutes split at the hour
func TestDemoHealthRows(t *testing.T) {
	end := time.Date(2026, 11, 14, 10, 30, 0, 0, time.UTC)
	specs := Specs("demo-", 20)
	var gens []*Gen
	var ids []int
	for i, s := range specs {
		gens = append(gens, NewGen(s, i, 1, end.Add(-2*time.Hour), end))
		ids = append(ids, 100+i)
	}
	rows := healthRows(gens, ids, time.Date(2026, 11, 14, 9, 50, 0, 0, time.UTC), time.Date(2026, 11, 14, 10, 29, 0, 0, time.UTC))
	find := func(suffix, coll string, hour int) *demoHealth {
		for i, g := range gens {
			if !g.is(suffix) {
				continue
			}
			for k := range rows {
				if rows[k].InstanceID == ids[i] && rows[k].Collection == coll && rows[k].Hour.Hour() == hour {
					return &rows[k]
				}
			}
		}
		return nil
	}
	hr := find("onprem-hr01", "activity", 10)
	if hr == nil || hr.Runs != 30 || hr.Partial != 6 || hr.Ok != 24 || hr.Error != 0 || hr.DurSum <= 0 || hr.DurMax > 440 || hr.LastPartial == nil {
		t.Fatalf("onprem-hr01 activity 10:00 = %+v, want 30 runs, 6 partial, 24 ok, a duration", hr)
	}
	if h9 := find("onprem-hr01", "activity", 9); h9 == nil || h9.Runs != 10 || h9.Partial != 2 {
		t.Fatalf("onprem-hr01 activity 09:00 = %+v, want 10 runs (09:50-09:59), 2 partial (09:50, 09:51)", h9)
	}
	var broken *demoHealth
	for _, g := range gens {
		if g.Spec.StmtBroken {
			broken = find(g.Spec.Name[len("demo-"):], "statements", 10)
			break
		}
	}
	if broken == nil || broken.Error != 30 || broken.Ok != 0 || broken.LastError == nil {
		t.Fatalf("a StmtBroken instance's statements 10:00 = %+v, want 30 errors", broken)
	}
	if v := find("onprem-erp02", "vacuum", 10); v != nil && (v.Skipped != 30 || v.Runs != 0 || v.DurSum != 0) {
		t.Fatalf("onprem-erp02 (a replica) vacuum 10:00 = %+v, want 30 skipped, no run, no duration", v)
	}
}
