package demo

// Wait-sampling and index rows for the demo fleet (task 41: the waits and indexes collections): the shapes import_waits
// and import_indexes take.
//
// Wired in gen.go at the join:
//   Step:        after add("activity", ...):           if g.waitDoor() { add("waits", g.waitRows(t)) }
//                inside `if first || t.Minute() == 0 {` next to extensions, versions and roles:  add("indexes", g.indexRows(t))
//   Collections: before the final return:              if g.waitDoor() { c = append(c, "waits") }
//                append "indexes" to the final list: ..., "extensions", "versions", "roles", "indexes")
// seed.go: no skip line (the waits collection logs its own skip where waitDoor is false: the collector's reason).

import (
	"fmt"
	"math"
	"time"
)

// waitDoor: pg_wait_sampling is installed on the on-prem primaries (the self-managed servers where the DBA can preload
// it); everywhere else the Waits tab reads the activity samples, as on a real fleet without the extension.
func (g *Gen) waitDoor() bool { return g.Spec.Platform == "onprem" && !g.Spec.Replica }

// waitRows is the per-minute read of pg_wait_sampling_profile, summed over pids: a cumulative count per (event type,
// event, queryid) since the server started. Each key grows at its own rate times a daily wave whose integral keeps the
// count monotonic (rate x (m + 0.6 x (m - P/2pi x sin(2pi m / P))), m minutes since the history's start, P one day),
// so the imported differences follow the load curve. The statements' waits: the UPDATE convoy waits on Lock:transactionid,
// the reports on IO:DataFileRead and BufferFile, the point reads mostly on CPU (no event); the background processes'
// Activity waits carry no queryid.
func (g *Gen) waitRows(t time.Time) []Row {
	s := g.Spec
	m := t.Sub(g.start).Minutes() + float64(g.idx)*13
	const p = 24 * 60.0
	cum := func(rate float64) int64 {
		return int64(rate * (m + 0.6*(m-p/(2*math.Pi)*math.Sin(2*math.Pi*m/p))))
	}
	qid := func(i int) int64 { return hash64(s.Name + "|" + g.stmts[i].text) }
	type key struct {
		typ, event string
		q          int // statement index, -1 = none
		rate       float64
	}
	keys := []key{
		{"", "", 0, 900}, {"", "", 1, 260}, {"", "", 7, 420}, // CPU: no wait event
		{"IO", "DataFileRead", 1, 140}, {"IO", "DataFileRead", 5, 380}, {"IO", "BufferFile", 5, 90},
		{"Lock", "transactionid", stUpdate, 60}, {"LWLock", "BufferMapping", 1, 25}, {"LWLock", "WALWrite", 3, 30},
		{"IO", "WalSync", 3, 75}, {"Client", "ClientRead", 2, 50}, {"Timeout", "VacuumDelay", -1, 40},
		{"Activity", "CheckpointerMain", -1, 6000}, {"Activity", "BgwriterMain", -1, 6000}, {"Activity", "WalWriterMain", -1, 6000},
		{"Activity", "AutovacuumMain", -1, 6000}, {"Activity", "LogicalLauncherMain", -1, 6000},
	}
	out := make([]Row, 0, len(keys)+1)
	for _, k := range keys {
		r := Row{"kind": "profile", "count": cum(k.rate * (0.8 + 0.4*noise(s.Name+k.event, g.start)))}
		if k.typ != "" {
			r["event_type"], r["event"] = k.typ, k.event
		} else {
			r["event_type"], r["event"] = nil, nil
		}
		if k.q >= 0 {
			r["queryid"] = qid(k.q)
		} else {
			r["queryid"] = int64(0)
		}
		out = append(out, r)
	}
	return append(out, Row{"kind": "period", "ms": 10.0})
}

// indexRows is the hourly indexes read: a db row per database, and per instance one scenario. Every primary: a
// redundant index on its first table's (account_id) beside the (account_id, created_at) one, and an unused 24 MB index
// on (legacy_ref) since the history's start (the counters run since the server's start, 40 days before the anchor, so
// its counters qualify; it becomes a finding once pgvigil has seen it unused for 7 days, so a demo of under 7 days
// shows the row without the finding); idx%3 == 0 an invalid index left by a failed CREATE INDEX CONCURRENTLY two days before the anchor (on a
// standby too: it has the primary's catalog);
// idx%4 == 1 a duplicate (status) pair; a standby shows its unused indexes without a finding (its counters see only its
// own reads).
func (g *Gen) indexRows(t time.Time) []Row {
	s := g.Spec
	t1, t2 := tables[s.App][0], tables[s.App][1]
	since := g.end.Add(-40 * 24 * time.Hour)
	out := []Row{}
	for di, db := range g.dbList() {
		dbid := dbOID(di)
		if db == "postgres" {
			dbid = 5
		}
		n, bytes := 3, int64(48)<<20
		if di == 0 {
			n, bytes = 24, int64(2300)<<20
		}
		out = append(out, Row{"kind": "db", "dbid": dbid, "datname": db, "indexes": n, "index_bytes": bytes,
			"stats_since": since, "is_replica": s.Replica})
	}
	db, dbid := s.DBs[0], dbOID(0)
	ix := func(oid int64, problem, table, name, def string, size, tsize int64, scans any, cov, covDef string, fk bool) Row {
		r := Row{"kind": "index", "dbid": dbid, "datname": db, "indexrelid": oid, "problem": problem, "schema_name": "public",
			"table_name": table, "index_name": name, "access_method": "btree", "index_bytes": size, "table_bytes": tsize,
			"idx_scan": scans, "index_def": def, "drop_sql": fmt.Sprintf("DROP INDEX CONCURRENTLY public.%s;", name),
			"undo_sql": regexpConcurrently(def) + ";"}
		if cov != "" {
			r["covered_by"], r["covered_by_def"], r["supports_fk"] = cov, covDef, fk
		}
		return r
	}
	big := int64(9800) << 20
	acc := fmt.Sprintf("CREATE INDEX %s_account_id_idx ON public.%s USING btree (account_id)", t1, t1)
	accCr := fmt.Sprintf("CREATE INDEX %s_account_created_idx ON public.%s USING btree (account_id, created_at DESC)", t1, t1)
	out = append(out,
		ix(24001, "redundant", t1, t1+"_account_id_idx", acc, 410<<20, big, int64(1200), t1+"_account_created_idx", accCr, false),
		ix(24002, "unused", t1, t1+"_legacy_ref_idx", fmt.Sprintf("CREATE INDEX %s_legacy_ref_idx ON public.%s USING btree (legacy_ref)", t1, t1),
			24<<20, big, int64(0), "", "", false))
	if g.idx%3 == 0 && !t.Before(g.end.Add(-48*time.Hour)) { // a standby has the primary's catalog: the same invalid index
		out = append(out, ix(24003, "invalid", t2, t2+"_parent_amount_idx",
			fmt.Sprintf("CREATE INDEX %s_parent_amount_idx ON public.%s USING btree (parent_id, amount)", t2, t2), 6<<20, int64(5200)<<20, nil, "", "", false))
	}
	if g.idx%4 == 1 {
		st := fmt.Sprintf("CREATE INDEX %s_status_idx ON public.%s USING btree (status)", t1, t1)
		out = append(out, ix(24004, "duplicate", t1, t1+"_status_idx1",
			fmt.Sprintf("CREATE INDEX %s_status_idx1 ON public.%s USING btree (status)", t1, t1), 180<<20, big, int64(3), t1+"_status_idx", st, false))
	}
	return append(out, g.inventoryRows(t)...)
}

// inventoryRows is the inventory part of the hourly indexes read (0056): every index of every application database,
// three per main table (the primary key and two secondary ones) and one per small table, with the scans growing per
// hour of the history; the problem indexes of indexRows ride in it too with the same facts, so the inventory's
// problems column and the index page agree. relid is tableRows' (16500 + di*1000 + ti*7); the index oids are
// 25000 + di*100 + ti*10 + k, the problem indexes keep 24001-24004.
func (g *Gen) inventoryRows(t time.Time) []Row {
	s := g.Spec
	hours := math.Max(0, t.Sub(g.start).Hours())
	load := math.Max(0.25, s.Load)
	t1, t2 := tables[s.App][0], tables[s.App][1]
	out := []Row{}
	inv := func(dbid int64, db string, oid, relid int64, table, name, am, cols string, unique, primary, valid, partition bool, size int64, scans, fetch float64) Row {
		def := fmt.Sprintf("CREATE %sINDEX %s ON public.%s USING %s %s", map[bool]string{true: "UNIQUE ", false: ""}[unique], name, table, am, cols)
		return Row{"kind": "inv", "dbid": dbid, "datname": db, "indexrelid": oid, "relid": relid, "schema_name": "public",
			"table_name": table, "index_name": name, "access_method": am, "is_unique": unique, "is_primary": primary,
			"is_valid": valid, "is_partition": partition, "columns": cols, "index_def": def, "index_bytes": size,
			"idx_scan": int64(scans), "idx_tup_read": int64(fetch * 1.2), "idx_tup_fetch": int64(fetch)}
	}
	for di, db := range s.DBs {
		dbid := dbOID(di)
		for ti, td := range g.tableDefs() {
			relid := 16500 + int64(di)*1000 + int64(ti)*7
			base := int64(td.base * 1e6 * load)
			oid := 25000 + int64(di)*100 + int64(ti)*10
			rate := float64(900-ti*150) * load // scans an hour on the primary key
			out = append(out, inv(dbid, db, oid, relid, td.name, td.name+"_pkey", "btree", "(id)", true, true, true, false, base/4, rate*hours, rate*hours*1.5))
			if ti >= 3 {
				continue // the small tables: the primary key alone
			}
			out = append(out,
				inv(dbid, db, oid+1, relid, td.name, td.name+"_created_at_idx", "btree", "(created_at DESC)", false, false, true, false, base/6, rate*hours/20, rate*hours*4),
				inv(dbid, db, oid+2, relid, td.name, td.name+"_status_idx", "btree", "(status)", false, false, true, false, base/9, rate*hours/70, rate*hours*30))
		}
	}
	// the problem indexes of indexRows, the same facts (database 0, tables t1 and t2)
	dbid, db := dbOID(0), s.DBs[0]
	r1, r2 := int64(16500), int64(16507)
	out = append(out,
		inv(dbid, db, 24001, r1, t1, t1+"_account_id_idx", "btree", "(account_id)", false, false, true, false, 410<<20, 1200, 48000),
		inv(dbid, db, 24002, r1, t1, t1+"_legacy_ref_idx", "btree", "(legacy_ref)", false, false, true, false, 24<<20, 0, 0),
		inv(dbid, db, 24005, r1, t1, t1+"_account_created_idx", "btree", "(account_id, created_at DESC)", false, false, true, false, 520<<20, 31000*load*hours/168, 2.4e6*load*hours/168))
	if g.idx%3 == 0 && !t.Before(g.end.Add(-48*time.Hour)) {
		out = append(out, inv(dbid, db, 24003, r2, t2, t2+"_parent_amount_idx", "btree", "(parent_id, amount)", false, false, false, false, 6<<20, 0, 0))
	}
	if g.idx%4 == 1 {
		out = append(out, inv(dbid, db, 24004, r1, t1, t1+"_status_idx1", "btree", "(status)", false, false, true, false, 180<<20, 3, 90))
	}
	return out
}

// regexpConcurrently is the collector's undo line: CREATE [UNIQUE] INDEX -> CREATE [UNIQUE] INDEX CONCURRENTLY.
func regexpConcurrently(def string) string {
	for _, p := range []string{"CREATE UNIQUE INDEX", "CREATE INDEX"} {
		if len(def) >= len(p) && def[:len(p)] == p {
			return p + " CONCURRENTLY" + def[len(p):]
		}
	}
	return def
}
