package demo

import "time"

// The baseline compare's two regression shapes (task 57) and the session SETs (task 58).

type regressDef struct {
	text                  string
	before, after         float64    // calls a day: before, and in the last 24 hours before the anchor
	meanBefore, meanAfter float64    // ms
	ppcBefore             float64    // pages (shared blocks hit + read) a call before
	ppcAfter              [2]float64 // after: a range, drawn per step
}

var regressDefs = []regressDef{
	{text: "SELECT o.id, o.status FROM orders o WHERE o.customer_id = $1 AND o.status = ANY($2)",
		before: 34000, after: 2400000, meanBefore: 0.4, meanAfter: 0.4, ppcBefore: 6, ppcAfter: [2]float64{6, 6}},
	{text: "SELECT i.sku, sum(i.qty) FROM order_items i JOIN orders o ON o.id = i.order_id WHERE o.created_at > $1 GROUP BY i.sku",
		before: 221, after: 2632, meanBefore: 3, meanAfter: 2400, ppcBefore: 120, ppcAfter: [2]float64{1300000, 1600000}},
}

func (g *Gen) regressOn() bool { return g.is("rds-orders01") }

// regressRows: the two shapes' cumulative pg_stat_statements rows at t; dt is statementRows' step in seconds.
func (g *Gen) regressRows(t time.Time, dt float64) []Row {
	if !g.regressOn() {
		return nil
	}
	if g.regCum == nil {
		g.regCum = make([]counters, len(regressDefs))
		for i := range g.regCum {
			g.regCum[i] = counters{}
		}
	}
	after := t.After(g.end.Add(-24 * time.Hour))
	var out []Row
	for i, d := range regressDefs {
		k := g.regCum[i]
		perDay, mean, ppc := d.before, d.meanBefore, d.ppcBefore
		if after {
			perDay, mean = d.after, d.meanAfter
			ppc = d.ppcAfter[0] + (d.ppcAfter[1]-d.ppcAfter[0])*g.rng.Float64()
		}
		calls := perDay / 86400 * dt
		k.add("calls", calls)
		if k["calls"] < 1 {
			continue
		}
		k.add("total_exec_ms", calls*mean)
		k.add("rows", calls*5)
		k.add("shared_blks_hit", calls*ppc*0.9)
		k.add("shared_blks_read", calls*ppc*0.1)
		out = append(out, Row{"kind": "stmt", "dbid": dbOID(0), "datname": g.Spec.DBs[0], "userid": int64(16500), "usename": "app_" + g.Spec.App,
			"queryid": hash64(g.Spec.Name + "|regress|" + d.text), "toplevel": true, "calls": k.int("calls"), "total_exec_ms": k["total_exec_ms"],
			"rows": k.int("rows"), "shared_blks_hit": k.int("shared_blks_hit"), "shared_blks_read": k.int("shared_blks_read"),
			// every counter, the zero ones too: import_statements reads a missing counter as NULL, and a NULL compare
			// makes the row's reset flag NULL (the import then fails on statements_delta.reset NOT NULL)
			"shared_blks_dirtied": k.int("shared_blks_dirtied"), "shared_blks_written": k.int("shared_blks_written"),
			"temp_blks_read": k.int("temp_blks_read"), "temp_blks_written": k.int("temp_blks_written"),
			"blk_read_ms": k["blk_read_ms"], "blk_write_ms": k["blk_write_ms"], "temp_read_ms": k["temp_read_ms"],
			"temp_write_ms": k["temp_write_ms"], "wal_bytes": k.int("wal_bytes"), "query": d.text})
	}
	return out
}

// sessionSetRows: the hourly session_sets read (internal/collect/sessionsets.go's rows).
func (g *Gen) sessionSetRows(t time.Time) []Row {
	if g.Spec.StmtBroken {
		return []Row{{"kind": "state", "status": "not available",
			"reason": "pg_stat_statements is not loaded (shared_preload_libraries): its settings are not defined", "track_utility": nil}}
	}
	out := []Row{{"kind": "state", "status": "ok", "reason": nil, "track_utility": "on"}}
	hidden := g.Spec.VersionNum >= 170000
	type def struct {
		setting, value string
		planner        bool
		perHour        float64
		since          time.Time
	}
	defs := []def{
		{"application_name", g.Spec.App + "-api", false, 40 * g.Spec.Load, g.start},
		{"search_path", g.Spec.App + ", public", false, 40 * g.Spec.Load, g.start},
	}
	if g.regressOn() {
		defs = append(defs, def{"enable_hashjoin", "off", true, 3, g.end.Add(-24 * time.Hour)})
	}
	for _, d := range defs {
		calls := int64(d.perHour * t.Sub(d.since).Hours())
		if calls < 1 {
			continue
		}
		text, value := "SET "+d.setting+" = '"+d.value+"'", any(d.value)
		if hidden {
			text, value = "SET "+d.setting+" = $1", nil
		}
		out = append(out, Row{"kind": "set", "dbid": dbOID(0), "datname": g.Spec.DBs[0], "userid": int64(16500), "rolname": "app_" + g.Spec.App,
			"queryid": hash64(g.Spec.Name + "|set|" + d.setting), "toplevel": true, "command": "SET", "setting": d.setting,
			"value": value, "value_hidden": hidden, "planner": d.planner, "calls": calls, "query": text})
	}
	return out
}
