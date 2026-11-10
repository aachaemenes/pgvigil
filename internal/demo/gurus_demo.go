package demo

// Wait-sampling and index rows for the demo fleet (task 41: the waits and indexes collections): the shapes import_waits
// and import_indexes take.
//
// Wiring (the lead's, in gen.go):
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
