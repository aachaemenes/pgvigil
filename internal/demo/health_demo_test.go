package demo

import (
	"os"
	"regexp"
	"strings"
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
	rows := healthRows(gens, ids, time.Date(2026, 11, 14, 9, 50, 0, 0, time.UTC), time.Date(2026, 11, 14, 10, 29, 0, 0, time.UTC), nil)
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

// TestDemoHealthKnownMinutes (the review of B6.2, part a #2): a minute the fleet did not log (a failed or a dropped
// tick) is not counted - the hourly rows count only the minutes known holds
func TestDemoHealthKnownMinutes(t *testing.T) {
	end := time.Date(2026, 11, 14, 10, 30, 0, 0, time.UTC)
	g := NewGen(Specs("demo-", 1)[0], 0, 1, end.Add(-2*time.Hour), end)
	from, to := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC), time.Date(2026, 11, 14, 10, 9, 0, 0, time.UTC)
	gap := time.Date(2026, 11, 14, 10, 4, 0, 0, time.UTC)
	all := healthRows([]*Gen{g}, []int{1}, from, to, nil)
	some := healthRows([]*Gen{g}, []int{1}, from, to, func(_ int, m time.Time) bool { return !m.Equal(gap) })
	runs := func(rs []demoHealth) (n int) {
		for _, r := range rs {
			n += r.Runs + r.Skipped
		}
		return n
	}
	if len(all) == 0 || runs(all)-runs(some) != len(g.Collections()) {
		t.Fatalf("one unknown minute: %d runs counted against %d with every minute, want %d fewer (one per collection)", runs(some), runs(all), len(g.Collections()))
	}
}

// TestDemoHealthKnownPerInstance (the review B6f3 #10): a minute is known per instance - a tick that failed on one
// instance leaves the minutes of the others that logged it counted (their collection_log rows exist), and only the
// failed instance's minute uncounted
func TestDemoHealthKnownPerInstance(t *testing.T) {
	end := time.Date(2026, 11, 14, 10, 30, 0, 0, time.UTC)
	sp := Specs("demo-", 2)
	g0, g1 := NewGen(sp[0], 0, 2, end.Add(-2*time.Hour), end), NewGen(sp[1], 1, 2, end.Add(-2*time.Hour), end)
	from, to := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC), time.Date(2026, 11, 14, 10, 9, 0, 0, time.UTC)
	gap := time.Date(2026, 11, 14, 10, 4, 0, 0, time.UTC)
	all := healthRows([]*Gen{g0, g1}, []int{1, 2}, from, to, nil)
	some := healthRows([]*Gen{g0, g1}, []int{1, 2}, from, to, func(i int, m time.Time) bool { return !(i == 0 && m.Equal(gap)) })
	runs := func(rs []demoHealth, id int) (n int) {
		for _, r := range rs {
			if r.InstanceID == id {
				n += r.Runs + r.Skipped
			}
		}
		return n
	}
	if d := runs(all, 1) - runs(some, 1); d != len(g0.Collections()) {
		t.Errorf("instance 1: %d fewer runs, want %d (one per collection at the unknown minute)", d, len(g0.Collections()))
	}
	if d := runs(all, 2) - runs(some, 2); d != 0 || runs(all, 2) == 0 {
		t.Errorf("instance 2: %d fewer runs of %d, want 0 fewer (it logged the minute)", d, runs(all, 2))
	}
}

// TestDemoLogCollectionsOneStatement (the review B6f5 #2): a tick's collections of one instance and minute are logged
// in ONE statement (the logHistoryErrors form), so a sibling's cancel leaves that minute logged whole or not at all -
// never logged in part and unmarked (an error counted on the list and not in Failed)
func TestDemoLogCollectionsOneStatement(t *testing.T) {
	b, err := os.ReadFile("seed.go")
	if err != nil {
		t.Fatal(err)
	}
	body := regexp.MustCompile(`(?s)func \(m \*importer\) logCollections\(.*?\n}\n`).Find(b)
	if body == nil {
		t.Fatal("no logCollections in seed.go")
	}
	if n := strings.Count(string(body), ".Exec("); n != 1 {
		t.Errorf("logCollections runs %d statements, want 1", n)
	}
	if !strings.Contains(string(body), "unnest(") {
		t.Error("logCollections does not log the minute's collections in one statement over unnest(...)")
	}
	if regexp.MustCompile(`(?s)for [^\n]*\{[^}]*\.Exec\(`).Match(body) {
		t.Error("logCollections runs its statement inside the loop over the collections")
	}
}
