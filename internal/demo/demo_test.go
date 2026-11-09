package demo

import (
	"encoding/json"
	"testing"
	"time"
)

var anchor = time.Date(2026, 11, 9, 15, 44, 0, 0, time.UTC)

// run generates one instance's whole history and returns its batches.
func run(t *testing.T, s Spec, idx int, seed uint64) []Batch {
	t.Helper()
	grid := Grid(anchor, 7)
	g := NewGen(s, idx, seed, grid[0], anchor)
	var out []Batch
	for _, at := range grid {
		out = append(out, g.Step(at)...)
	}
	return out
}

func TestGrid(t *testing.T) {
	g := Grid(anchor, 7)
	// 7 days at 5 minutes up to the last hour (2,016 - 12 = 2,004) plus one: the anchor 15:44 is off
	// the 5-minute mark, so the start truncates down to 15:40 (one point more); then 61 one-minute points
	if len(g) != 2066 || !g[len(g)-1].Equal(anchor) {
		t.Fatalf("grid: %d points, last %v", len(g), g[len(g)-1])
	}
	for i := 1; i < len(g); i++ {
		if !g[i].After(g[i-1]) {
			t.Fatalf("grid not increasing at %d", i)
		}
	}
}

func TestDeterministic(t *testing.T) {
	specs := Specs("demo-", 12)
	for i, s := range specs {
		a, _ := json.Marshal(run(t, s, i, 7))
		b, _ := json.Marshal(run(t, s, i, 7))
		if string(a) != string(b) {
			t.Fatalf("%s: two runs with seed 7 differ", s.Name)
		}
	}
	a, _ := json.Marshal(run(t, specs[0], 0, 7))
	b, _ := json.Marshal(run(t, specs[0], 0, 8))
	if string(a) == string(b) {
		t.Fatal("seeds 7 and 8 gave the same data")
	}
}

func TestFleet(t *testing.T) {
	specs := Specs("demo-", 12)
	plat := map[string]int{}
	for _, s := range specs {
		plat[s.Platform]++
		if s.Tags[0] != "demo" {
			t.Fatalf("%s: first tag %q", s.Name, s.Tags[0])
		}
	}
	if plat["onprem"] != 3 || plat["rds"] != 2 || plat["aurora"] != 3 || plat["azure"] != 2 || plat["cloudsql"] != 2 {
		t.Fatalf("platforms: %v", plat)
	}
	big := Specs("x-", 30)
	if big[12].Name != "x-onprem-erp01-001" || big[12].SenderTo != "x-onprem-erp02-001" || big[13].ReceiverOf != "x-onprem-erp01-001" {
		t.Fatalf("copies: %s %s %s", big[12].Name, big[12].SenderTo, big[13].ReceiverOf)
	}
}

// the latest snapshot carries both chains and the idle head, with the head holding and not waiting
func TestScenarios(t *testing.T) {
	specs := Specs("demo-", 12)
	last := func(bs []Batch, c string) Batch {
		var b Batch
		for _, x := range bs {
			if x.Collection == c {
				b = x
			}
		}
		return b
	}
	want := map[string]struct {
		waiters int
		head    string
	}{"demo-onprem-erp01": {3, "active"}, "demo-rds-orders01": {6, "active"}, "demo-onprem-hr01": {2, "idle in transaction"}}
	for i, s := range specs {
		bs := run(t, s, i, 1)
		act := last(bs, "activity")
		if !act.At.Equal(anchor) {
			t.Fatalf("%s: last activity at %v", s.Name, act.At)
		}
		waiters, heads := 0, map[string]int{}
		pids := map[int]Row{}
		for _, r := range act.Rows {
			if r["kind"] == "session" {
				pids[r["pid"].(int)] = r
			}
		}
		for _, r := range act.Rows {
			if r["wait_event_type"] == "Lock" {
				waiters++
				for _, b := range r["blocking_pids"].([]int) {
					if _, ok := pids[b]; !ok {
						t.Fatalf("%s: waiter %v names pid %d, absent from the snapshot", s.Name, r["pid"], b)
					}
				}
			}
			if r["is_blocker"] == true && r["wait_event_type"] != "Lock" {
				heads[r["state"].(string)]++
			}
		}
		w, ok := want[s.Name]
		if waiters != w.waiters || (ok && heads[w.head] != 1) || (!ok && len(heads) != 0) {
			t.Fatalf("%s: %d waiter(s), heads %v; want %d and one %q head", s.Name, waiters, heads, w.waiters, w.head)
		}
		var resets int
		for _, b := range bs {
			if b.Collection == "statements" {
				for _, r := range b.Rows {
					if r["kind"] == "info" && r["stats_reset"].(time.Time).After(anchor.Add(-4*24*time.Hour)) {
						resets++
						break
					}
				}
			}
		}
		if (resets > 0) != s.StmtReset {
			t.Fatalf("%s: statements after a reset in %d batch(es), StmtReset %v", s.Name, resets, s.StmtReset)
		}
	}
}

// a cumulative counter never falls within one stats epoch (the import's reset detection would
// read a fall as a reset)
func TestCountersRise(t *testing.T) {
	for i, s := range Specs("demo-", 12) {
		prev := map[string]int64{}
		for _, b := range run(t, s, i, 1) {
			if b.Collection != "dbstats" {
				continue
			}
			for _, r := range b.Rows {
				if r["kind"] != "db" {
					continue
				}
				k := r["datname"].(string)
				v := r["xact_commit"].(int64)
				if v < prev[k] {
					t.Fatalf("%s %s: xact_commit fell %d -> %d at %v", s.Name, k, prev[k], v, b.At)
				}
				prev[k] = v
			}
		}
	}
}

// 'demo -serve' ticks past the anchor for hours: the ramps hold, the chains rotate, ages stay sane
func TestLiveBounded(t *testing.T) {
	specs := Specs("demo-", 12)
	grid := Grid(anchor, 1)
	for i, s := range specs {
		if !s.ChainActive && s.SenderTo == "" && !s.DMS && !s.IdleHead {
			continue
		}
		g := NewGen(s, i, 1, grid[0], anchor)
		for _, at := range grid {
			g.Step(at)
		}
		chainSeen := 0
		for m := 1; m <= 6*60; m++ {
			at := anchor.Add(time.Duration(m) * time.Minute)
			for _, b := range g.Step(at) {
				for _, r := range b.Rows {
					if v, ok := r["replay_lag_secs"].(float64); ok && v > 450 {
						t.Fatalf("%s: replay lag %.0f s at +%d min", s.Name, v, m)
					}
					if v, ok := r["latency_target_s"].(float64); ok && v > 1100 {
						t.Fatalf("%s: DMS latency %.0f s at +%d min", s.Name, v, m)
					}
					if r["kind"] == "session" && r["wait_event_type"] == "Lock" {
						chainSeen++
						if age := at.Sub(r["query_start"].(time.Time)); age > 30*time.Minute {
							t.Fatalf("%s: a waiter %s old at +%d min", s.Name, age, m)
						}
					}
				}
			}
		}
		if (s.ChainActive || s.IdleHead) && chainSeen == 0 {
			t.Fatalf("%s: no chain in six live hours", s.Name)
		}
	}
}
