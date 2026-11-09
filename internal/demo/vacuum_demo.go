package demo

import (
	"math"
	"time"
)

// ---------------------------------------------------------------- vacuum

// vacuumSkipNote is the collection log's note on a standby, in the collector's words (vacuumApplies).
const vacuumSkipNote = "a standby does not vacuum: its primary's read covers it"

// vacuumRows is the minute vacuum read: the summary, an autovacuum of the second main table of the first
// database in the first 20 minutes of every third hour (a 6 h anti-wraparound one on the Tables "avoff"
// scenario's instance is not modelled: its table has autovacuum off), and on the instance whose Tables
// scenario is "dead" a manual VACUUM waiting on a lock from minute 30 to 35 of every hour.
func (g *Gen) vacuumRows(t time.Time) []Row {
	s := g.Spec
	t2 := tables[s.App][1]
	workers := 0
	var out []Row
	if len(s.DBs) > 0 && t.Hour()%3 == 0 && t.Minute() < 20 {
		start := t.Truncate(time.Hour).Add(time.Duration(hash64(s.Name)%3) * time.Minute)
		if !t.Before(start) {
			el := int(t.Sub(start).Seconds())
			total := int64(2400e6 * math.Max(0.25, s.Load) / 8192)
			out = append(out, Row{"kind": "vacuum", "pid": 40000 + g.idx, "dbid": dbOID(0), "datname": s.DBs[0], "relid": 16507,
				"table_name": "public." + t2, "backend_type": "autovacuum worker", "is_auto": true, "is_wraparound": false,
				"phase": "scanning heap", "heap_blks_total": total, "heap_blks_scanned": min(total, total*int64(el)/1200),
				"heap_blks_vacuumed": total * int64(el) / 2400, "index_vacuum_count": 0, "dead_tuples": int64(el) * 900,
				"xact_start": start, "query_start": start, "elapsed_secs": el, "wait_event_type": "Timeout", "wait_event": "VacuumDelay",
				"query": "autovacuum: VACUUM public." + t2})
			workers++
		}
	}
	if s.Tables == "dead" && len(s.DBs) > 0 && t.Minute() >= 30 && t.Minute() < 36 {
		start := t.Truncate(time.Hour).Add(30 * time.Minute)
		out = append(out, Row{"kind": "vacuum", "pid": 41000 + g.idx, "dbid": dbOID(0), "datname": s.DBs[0], "relid": 16507,
			"table_name": "public." + t2, "backend_type": "client backend", "is_auto": false, "is_wraparound": false,
			"query_start": start, "xact_start": start, "elapsed_secs": int(t.Sub(start).Seconds()), "wait_event_type": "Lock",
			"wait_event": "relation", "blocking_pids": []int{42000 + g.idx}, "query": "VACUUM (VERBOSE) public." + t2})
	}
	out = append(out, Row{"kind": "summary", "autovacuum": "on", "track_counts": "on", "max_workers": 3, "workers_running": workers})
	return out
}

// vacuumTablesRows is the hourly vacuum_tables read: the settings, a wraparound row per database (older on
// the "avoff" scenario's instance: 230 M of 200 M, past the freeze max age, a warning), and per database the tables near or over a
// threshold from the same model as tableRows (the "dead" scenario's table is over its threshold all the time,
// so its check appears 6 hours into the data).
func (g *Gen) vacuumTablesRows(t time.Time) []Row {
	s := g.Spec
	out := []Row{{"kind": "settings", "autovacuum": "on", "track_counts": "on", "max_workers": 3, "naptime_secs": 60,
		"vacuum_threshold": 50.0, "vacuum_scale_factor": 0.2, "vacuum_max_threshold": 100000000.0, "insert_threshold": 1000.0,
		"insert_scale_factor": 0.2, "analyze_threshold": 50.0, "analyze_scale_factor": 0.1, "freeze_max_age": 200000000,
		"mxid_freeze_max_age": 400000000, "failsafe_age": 1600000000, "cost_limit": 200, "cost_delay_ms": 2.0, "log_min_duration_ms": 600000}}
	for di, db := range g.dbList() {
		age := 30e6 + hash64(s.Name+db+t.Truncate(24*time.Hour).String())%60e6
		if s.Tables == "avoff" && di == 0 {
			age = 230e6
		}
		id := dbOID(di)
		if db == "postgres" { // the databases collection gives postgres OID 5 (dbOID(-1))
			id = dbOID(-1)
		}
		out = append(out, Row{"kind": "wrap", "dbid": id, "datname": db, "allow_conn": true, "xid_age": age, "mxid_age": 1200})
	}
	out = append(out, Row{"kind": "wrap", "dbid": int64(1), "datname": "template1", "allow_conn": true, "xid_age": int64(20e6), "mxid_age": 0},
		Row{"kind": "wrap", "dbid": int64(4), "datname": "template0", "allow_conn": false, "xid_age": int64(20e6), "mxid_age": 0})
	for di, db := range s.DBs {
		var overVac, offN int64
		var rows []Row
		for ti, td := range g.tableDefs() {
			problem := ti == 1 && di == 0
			live := float64(int64(td.base*1e6*math.Max(0.25, s.Load)) / 8192 * 60)
			dead := live / 40
			thr := 50 + 0.2*live
			avOn := true
			if problem && s.Tables == "dead" {
				dead = live * 3 / 7
			}
			if problem && s.Tables == "avoff" {
				avOn, dead = false, live/8
				offN++
			}
			over := avOn && dead > thr
			if over {
				overVac++
			}
			if !over && avOn && dead < 0.5*thr {
				continue
			}
			rows = append(rows, Row{"kind": "table", "dbid": dbOID(di), "relid": 16500 + int64(di)*1000 + int64(ti)*7, "datname": db,
				"schema_name": "public", "table_name": td.name, "relkind": "r", "reltuples": live, "n_live_tup": int64(live),
				"n_dead_tup": int64(dead), "n_ins_since_vacuum": int64(live / 200), "n_mod_since_analyze": int64(live / 50),
				"vac_threshold": thr, "ins_threshold": 1000 + 0.2*live, "anl_threshold": 50 + 0.1*live, "autovacuum_enabled": avOn,
				"has_own_settings": !avOn, "over_vacuum": over, "over_insert": false, "over_analyze": false,
				"last_vacuum": t.Add(-30 * time.Hour), "last_autovacuum": t.Add(-30 * time.Hour), "last_analyze": t.Add(-3 * time.Hour),
				"last_autoanalyze": t.Add(-3 * time.Hour), "autovacuum_count": 40, "autoanalyze_count": 60,
				"xid_age": int64(40e6), "mxid_age": int64(1000), "freeze_max_age": int64(200000000)})
		}
		out = append(out, Row{"kind": "db", "dbid": dbOID(di), "datname": db, "user_tables": int64(len(g.tableDefs())),
			"over_vacuum": overVac, "over_insert": 0, "over_analyze": 0, "autovacuum_off": offN, "never_vacuumed": 0})
		out = append(out, rows...)
	}
	return out
}
