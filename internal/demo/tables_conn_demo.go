package demo

import (
	"math"
	"time"
)

// The demo's table activity and connection sources (task 127). Wiring in gen.go's batches (after add("tables", ...)):
//
//	if first || t.Minute()%5 == 0 { add("table_activity", g.tableActivityRows(t)) }
//	add("connections", g.connectionRows(t))
//
// and "table_activity", "connections" appended to Collections()' PostgreSQL list.

// tableActivityRows: the cumulative scan and row-change counters of each demo table since the demo's start, rising
// at a rate of its own with the daily load curve: the main tables take the inserts and updates, audit_log only inserts
// and a nightly delete, settings is read by sequential scans all day (a small table: the planner's right choice).
func (g *Gen) tableActivityRows(t time.Time) []Row {
	s := g.Spec
	mins := t.Sub(g.start).Minutes()
	day := 0.6 + 0.4*math.Sin(float64(t.Hour()-6)/24*2*math.Pi)
	var out []Row
	for di, db := range s.DBs {
		for ti, td := range g.tableDefs() {
			relid := 16500 + int64(di)*1000 + int64(ti)*7
			k := s.Load * (1 + 0.2*float64(hash64(s.Name+td.name)%5)) / float64(di+1)
			seq, idx, ins, upd, del := 0.4, 300.0, 40.0/float64(ti+1), 25.0/float64(ti+1), 2.0/float64(ti+1)
			switch td.name {
			case "audit_log":
				seq, idx, ins, upd, del = 0.1, 0, 120, 0, 0
				if t.Hour() >= 2 {
					del = 60 // the nightly trim: its deletes over the day so far
				}
			case "settings":
				seq, idx, ins, upd, del = 90, 0, 0, 0.01, 0
			}
			c := func(rate float64) int64 { return int64(mins * rate * k * day) }
			out = append(out, Row{"kind": "table", "dbid": dbOID(di), "relid": relid, "datname": db, "schema_name": "public",
				"table_name": td.name, "seq_scan": c(seq), "seq_tup_read": c(seq) * int64(td.base*50), "idx_scan": c(idx),
				"n_tup_ins": c(ins), "n_tup_upd": c(upd), "n_tup_del": c(del), "n_tup_hot_upd": c(upd) * 8 / 10})
		}
	}
	return out
}

// connectionRows: the instance's connection sources at one read: the application's pool (mostly idle), its batch
// jobs, a reporting tool, the DBA's psql and the monitoring login, scaled by the load and the hour.
func (g *Gen) connectionRows(t time.Time) []Row {
	s := g.Spec
	db := s.DBs[0]
	busy := 0.5 + 0.5*noise(s.Name+"conn", t.Truncate(5*time.Minute))
	pool := int(math.Round(20*s.Load)) + 2
	act := int(math.Round(float64(pool) * 0.15 * busy))
	src := []Row{
		{"application_name": s.App + "-api", "usename": "app_" + s.App, "datname": db, "client": "10.60.1.21", "total": pool, "active": act, "idle": pool - act - 1, "idle_in_txn": 1},
		{"application_name": s.App + "-api", "usename": "app_" + s.App, "datname": db, "client": "10.60.1.22", "total": pool, "active": act / 2, "idle": pool - act/2},
		{"application_name": s.App + "-batch", "usename": "batch_" + s.App, "datname": db, "client": "10.60.9.44", "total": 3, "active": 1, "idle": 2},
		{"application_name": "Metabase", "usename": "report", "datname": db, "client": "10.70.0.8", "total": 4, "idle": 4},
		{"application_name": "pgvigil", "usename": "pgvigil", "datname": "postgres", "client": "10.10.0.5", "total": 1, "active": 1},
	}
	if t.Hour() >= 9 && t.Hour() < 17 {
		src = append(src, Row{"application_name": "psql", "usename": "dba", "datname": db, "client": "10.10.3.17", "total": 1, "idle": 1})
	}
	if len(s.DBs) > 1 {
		src = append(src, Row{"application_name": s.App + "-api", "usename": "app_" + s.App, "datname": s.DBs[1], "client": "10.60.1.21",
			"total": pool / 2, "idle": pool / 2})
	}
	out := make([]Row, 0, len(src)+1)
	for _, r := range src {
		r["kind"] = "source"
		for _, k := range []string{"active", "idle", "idle_in_txn", "waiting_lock", "other"} {
			if _, ok := r[k]; !ok {
				r[k] = 0
			}
		}
		out = append(out, r)
	}
	return append(out, Row{"kind": "read"})
}
