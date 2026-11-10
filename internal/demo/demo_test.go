package demo

import (
	"encoding/json"
	"strings"
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
	// the three SQL Server instances follow the twelve; the copies of a scale run follow those
	big := Specs("x-", 30)
	if FleetSize != 15 || big[12].Name != "x-onprem-sql01" || big[13].Name != "x-onprem-sql02" || big[14].Name != "x-azure-sql03" {
		t.Fatalf("the SQL Server instances: %d, %s %s %s", FleetSize, big[12].Name, big[13].Name, big[14].Name)
	}
	for i, s := range big {
		if (s.Engine == EngineSQLServer) != (i >= 12 && i < 15) {
			t.Fatalf("%s (index %d): engine %q", s.Name, i, s.Engine)
		}
	}
	if big[15].Name != "x-onprem-erp01-001" || big[15].SenderTo != "x-onprem-erp02-001" || big[16].ReceiverOf != "x-onprem-erp01-001" {
		t.Fatalf("copies: %s %s %s", big[15].Name, big[15].SenderTo, big[16].ReceiverOf)
	}
}

// A SQL Server instance runs its own collections and none of PostgreSQL's, and a PostgreSQL instance none of
// SQL Server's; the scenarios the walk-through opens are in the batches: the chain with its sleeping head at the
// anchor on sql01, the wait counters only ever rising, the day's Extended Events twice a minute apart with the same
// keys, the storage year before the history, and the managed instance without volumes or a slow session.
func TestMSSQLDemo(t *testing.T) {
	specs := Specs("demo-", FleetSize)
	for i, s := range specs[:12] {
		g := NewGen(s, i, 7, Grid(anchor, 7)[0], anchor)
		for _, c := range g.Collections() {
			if strings.HasPrefix(c, "mssql_") {
				t.Fatalf("%s: collection %s", s.Name, c)
			}
		}
		// the first step and the anchor's carry every collection an instance has
		for _, b := range append(g.Step(Grid(anchor, 7)[0]), g.Step(anchor)...) {
			if strings.HasPrefix(b.Collection, "mssql_") {
				t.Fatalf("%s: a SQL Server batch %s", s.Name, b.Collection)
			}
		}
	}
	for i, s := range specs[12:] {
		idx := 12 + i
		g := NewGen(s, idx, 7, Grid(anchor, 7)[0], anchor)
		for _, c := range g.Collections() {
			if !strings.HasPrefix(c, "mssql_") {
				t.Fatalf("%s: collection %s", s.Name, c)
			}
		}
		batches := run(t, s, idx, 7)
		seen := map[string]int{}
		var lastWaits map[string][3]int64
		var xeKeys []string
		var atAnchor, storageBefore, volumes, slowStates int
		for _, b := range batches {
			if !strings.HasPrefix(b.Collection, "mssql_") {
				t.Fatalf("%s: a PostgreSQL batch %s", s.Name, b.Collection)
			}
			seen[b.Collection]++
			switch b.Collection {
			case "mssql_waits":
				cur := map[string][3]int64{}
				for _, r := range b.Rows {
					if r["kind"] == "wait" {
						c := [3]int64{r["waiting_tasks"].(int64), r["wait_ms"].(int64), r["signal_ms"].(int64)}
						if c[0] < 0 || c[1] < 0 || c[2] < 0 || c[2] > c[1] {
							t.Fatalf("%s: %s at %v: tasks, wait and signal %v", s.Name, r["wait_type"], b.At, c)
						}
						cur[r["wait_type"].(string)] = c
					}
				}
				for w, v := range lastWaits {
					if c := cur[w]; c[0] < v[0] || c[1] < v[1] || c[2] < v[2] {
						t.Fatalf("%s: %s went down at %v: %v after %v", s.Name, w, b.At, c, v)
					}
				}
				lastWaits = cur
			case "mssql_requests":
				if b.At.Equal(anchor) {
					for _, r := range b.Rows {
						if r["kind"] == "blocking" && r["head_session_id"] == 71 && r["longest_wait_ms"].(int64) > 300000 {
							atAnchor++
						}
					}
				}
			case "mssql_xe":
				keys := ""
				for _, r := range b.Rows {
					if r["kind"] == "state" && r["capture"] == "slow" && r["state"] == "not installed" {
						slowStates++
					}
					if k, ok := r["event_key"].(string); ok {
						keys += k + "@" + r["event_at"].(string) + ";"
					}
				}
				xeKeys = append(xeKeys, keys)
			case "mssql_storage":
				if b.At.Before(Grid(anchor, 7)[0]) {
					storageBefore++
				}
				for _, r := range b.Rows {
					if r["kind"] == "volume" {
						volumes++
					}
				}
			}
		}
		for _, c := range []string{"mssql_instance", "mssql_requests", "mssql_waits", "mssql_xe", "mssql_storage", "mssql_versionstore"} {
			if seen[c] == 0 {
				t.Errorf("%s: no %s batch", s.Name, c)
			}
		}
		if len(xeKeys) != 2 || xeKeys[0] != xeKeys[1] || xeKeys[0] == "" {
			t.Errorf("%s: Extended Events: %d imports, the same events in both: %v", s.Name, len(xeKeys), len(xeKeys) == 2 && xeKeys[0] == xeKeys[1])
		}
		if storageBefore < 350 {
			t.Errorf("%s: %d storage reads before the history, want a year of days", s.Name, storageBefore)
		}
		sql01, sql03 := strings.HasSuffix(s.Name, "-sql01"), strings.HasSuffix(s.Name, "-sql03")
		if (atAnchor == 1) != sql01 {
			t.Errorf("%s: %d chain head(s) over five minutes at the anchor", s.Name, atAnchor)
		}
		if (seen["mssql_jobs"] > 0) != sql01 || (seen["mssql_ag"] > 0) == sql03 || (seen["mssql_backups"] > 0) == sql03 {
			t.Errorf("%s: jobs %d, ag %d, backups %d batches", s.Name, seen["mssql_jobs"], seen["mssql_ag"], seen["mssql_backups"])
		}
		if (volumes == 0) != sql03 || (slowStates == 2) != sql03 {
			t.Errorf("%s: %d volume rows, %d 'slow not installed' states", s.Name, volumes, slowStates)
		}
		// live ticks after the seed: the capture states alone on an ordinary minute (no event twice), and every
		// twenty minutes the events of the twenty minutes before, none at or before the anchor's last deadlock, so
		// the findings of the last hour hold while the demo is served; the version store does not outgrow tempdb
		live := g2(t, s, idx)
		xeBatch := func(at time.Time) (kinds map[string]int, found bool) {
			kinds = map[string]int{}
			for _, b := range live.Step(at) {
				switch b.Collection {
				case "mssql_xe":
					found = true
					for _, r := range b.Rows {
						kinds[r["kind"].(string)]++
						if v, ok := r["event_at"].(string); ok && r["kind"] == "deadlock" {
							if e, err := time.Parse(time.RFC3339Nano, v); err != nil || !e.After(anchor.Add(-20*time.Minute)) {
								t.Fatalf("%s: a live deadlock at %v", s.Name, v)
							}
						}
					}
				case "mssql_versionstore":
					for _, r := range b.Rows {
						if r["kind"] == "store" && r["store_kb"].(int64) > r["tempdb_data_kb"].(int64)/2 {
							t.Fatalf("%s: at %v the version store is %v KB of tempdb's %v", s.Name, at, r["store_kb"], r["tempdb_data_kb"])
						}
					}
				}
			}
			return kinds, found
		}
		if kinds, found := xeBatch(anchor.Add(time.Minute)); !found || kinds["state"] < 4 || len(kinds) != 1 {
			t.Errorf("%s: the tick a minute after the anchor: an Extended Events batch %v with %v", s.Name, found, kinds)
		}
		for m := 2; m < 20; m++ {
			live.Step(anchor.Add(time.Duration(m) * time.Minute))
		}
		kinds, found := xeBatch(anchor.Add(20 * time.Minute))
		sql02 := strings.HasSuffix(s.Name, "-sql02")
		if !found || kinds["state"] < 4 || (kinds["deadlock"] == 1) == sql02 || (kinds["blocked"] == 4) == sql02 || kinds["ag_event"] != 0 {
			t.Errorf("%s: the tick twenty minutes after the anchor: %v", s.Name, kinds)
		}
		for m := 21; m <= 180; m++ { // three hours of serving
			xeBatch(anchor.Add(time.Duration(m) * time.Minute))
		}
	}
}

// g2 is a generator stepped through the seed's grid, ready for a live tick.
func g2(t *testing.T, s Spec, idx int) *Gen {
	t.Helper()
	grid := Grid(anchor, 7)
	g := NewGen(s, idx, 7, grid[0], anchor)
	for _, at := range grid {
		g.Step(at)
	}
	return g
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

// the chains of the anchor outlast the seed: the catch-up ticks of the minutes after the anchor (and the first
// page of a serve) still carry every waiter, and the pause begins at the twelfth minute
func TestChainsOutlastSeed(t *testing.T) {
	specs := Specs("demo-", 12)
	grid := Grid(anchor, 1)
	want := map[string]int{"demo-onprem-erp01": 3, "demo-rds-orders01": 6, "demo-onprem-hr01": 2}
	for i, s := range specs {
		w, ok := want[s.Name]
		if !ok {
			continue
		}
		g := NewGen(s, i, 1, grid[0], anchor)
		for _, at := range grid {
			g.Step(at)
		}
		for m := 1; m <= 12; m++ {
			waiters := 0
			for _, b := range g.Step(anchor.Add(time.Duration(m) * time.Minute)) {
				if b.Collection != "activity" {
					continue
				}
				for _, r := range b.Rows {
					if r["kind"] == "session" && r["wait_event_type"] == "Lock" {
						waiters++
					}
				}
			}
			if m < 12 && waiters != w {
				t.Fatalf("%s: %d lock waiter(s) at +%d min, want %d", s.Name, waiters, m, w)
			}
			if m == 12 && waiters != 0 {
				t.Fatalf("%s: %d lock waiter(s) at +12 min, want the pause", s.Name, waiters)
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

// tableChecks applies the rules of pgvigil.table_checks (0016_tables.sql) to one 'table' row.
func tableChecks(r Row) []string {
	pages := r["relpages"].(int64)
	if hp := r["heap_bytes"].(int64) / 8192; hp > pages {
		pages = hp
	}
	big := pages >= 1000
	live, dead := float64(r["n_live_tup"].(int64)), float64(r["n_dead_tup"].(int64))
	var out []string
	if r["last_vacuum"] == nil && big {
		out = append(out, "never vacuumed")
	}
	if r["last_analyze"] == nil && big {
		out = append(out, "never analyzed")
	}
	if r["last_analyze"] != nil && live > 0 && float64(r["n_mod_since_analyze"].(int64)) > 0.2*live && big {
		out = append(out, "statistics stale")
	}
	if r["bloat_pct"].(float64) > 20 && r["bloat_bytes"].(int64) >= 104857600 {
		out = append(out, "bloat")
	}
	if xid, mx := r["xid_age"].(int64), r["mxid_age"].(int64); xid >= 1000000000 || mx >= 1000000000 {
		out = append(out, "xid age")
	}
	if live+dead > 1000 && dead > 0.2*(live+dead) {
		out = append(out, "dead rows")
	}
	if r["autovacuum_off"].(bool) {
		out = append(out, "autovacuum off")
	}
	return out
}

// TestTableScenarios checks every hourly tables read of the 7 days: no table ever trips a check other than
// its scenario's, a scenario table trips its own check at the anchor, nothing is vacuumed or analyzed after
// the snapshot, and the skip scenario sends table_skipped on some reads but never on the first.
func TestTableScenarios(t *testing.T) {
	want := map[string]string{"bloat": "bloat", "dead": "dead rows", "avoff": "autovacuum off", "novac": "never vacuumed"}
	for i, s := range Specs("demo-", 12) {
		problem := tables[s.App][1]
		var reads, skipped int
		var last []Row
		for _, b := range run(t, s, i, 7) {
			if b.Collection != "tables" {
				continue
			}
			reads++
			last = b.Rows
			for _, r := range b.Rows {
				switch r["kind"] {
				case "table_skipped":
					if reads == 1 {
						t.Errorf("%s: table_skipped on the first read", s.Name)
					}
					skipped++
				case "table":
					for _, k := range []string{"last_vacuum", "last_analyze", "last_autovacuum", "last_autoanalyze"} {
						if at, ok := r[k].(time.Time); ok && at.After(b.At) {
							t.Errorf("%s %s: %s %v after the snapshot %v", s.Name, r["table_name"], k, at, b.At)
						}
					}
					for _, c := range tableChecks(r) {
						if c != want[s.Tables] || r["table_name"] != problem {
							t.Errorf("%s at %v: %s trips %q", s.Name, b.At, r["table_name"], c)
						}
					}
				}
			}
		}
		if s.Tables == "skip" && skipped == 0 {
			t.Errorf("%s: no table_skipped row in %d reads", s.Name, reads)
		}
		if w, ok := want[s.Tables]; ok {
			var got []string
			for _, r := range last {
				if r["kind"] == "table" {
					for _, c := range tableChecks(r) {
						got = append(got, c+":"+r["table_name"].(string))
					}
				}
			}
			if len(got) != 1 || got[0] != w+":"+problem {
				t.Errorf("%s (%s): checks at the anchor %v, want %s on %s", s.Name, s.Tables, got, w, problem)
			}
		}
	}
}

// TestDMSDrain checks the CDC task at the anchor against pgvigil.dms_drain's reading: the apply outruns the
// read (an ETA), latency is falling against 10-30 minutes earlier (speed over 1x) but still over the 300 s
// threshold, and the spill is on and smaller than at its peak 45 minutes before.
func TestDMSDrain(t *testing.T) {
	for i, s := range Specs("demo-", 12) {
		if !s.DMS {
			continue
		}
		task := map[time.Time]Row{}
		for _, b := range run(t, s, i, 7) {
			if b.Collection == "dms" {
				for _, r := range b.Rows {
					if r["kind"] == "task" && r["task_id"] == "erp-to-aurora-cdc" {
						task[b.At] = r
					}
				}
			}
		}
		now, then, peak := task[anchor], task[anchor.Add(-20*time.Minute)], task[anchor.Add(-45*time.Minute)]
		if now == nil || then == nil || peak == nil {
			t.Fatalf("%s: CDC task rows missing at the anchor, -20 min or -45 min", s.Name)
		}
		if now["rows_out_s"].(float64) <= now["rows_in_s"].(float64) {
			t.Errorf("%s: no ETA at the anchor: out %v <= in %v", s.Name, now["rows_out_s"], now["rows_in_s"])
		}
		if l, l0 := now["latency_target_s"].(float64), then["latency_target_s"].(float64); l >= l0 || l <= 300 {
			t.Errorf("%s: latency at the anchor %v (20 min before %v): want falling and over 300", s.Name, l, l0)
		}
		if d, d0 := now["disk_target"].(float64), peak["disk_target"].(float64); d <= 0 || d >= d0 {
			t.Errorf("%s: spill at the anchor %v (peak %v): want on and draining", s.Name, d, d0)
		}
	}
}
