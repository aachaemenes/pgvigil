package demo

import (
	"fmt"
	"hash/fnv"
	"math"
	"math/rand/v2"
	"slices"
	"strings"
	"time"
)

// Row is one collected record, as the collector hands it to an import function.
type Row = map[string]any

// Batch is one import call: a collection's rows at one snapshot time.
type Batch struct {
	Collection string
	At         time.Time
	Rows       []Row
}

// stmtDef is one statement the application runs.
type stmtDef struct {
	text   string
	rate   float64 // calls per second at full load, before the instance's multiplier
	meanMS float64
	rows   float64 // rows per call
	write  bool
	report bool // reads a lot, spills to temp
}

// tables names each application's three main tables.
var tables = map[string][3]string{
	"erp":       {"items", "order_lines", "user_sessions"},
	"hr":        {"employees", "timesheets", "user_sessions"},
	"orders":    {"orders", "order_items", "carts"},
	"billing":   {"invoices", "invoice_lines", "payment_tokens"},
	"crm":       {"accounts", "activities", "user_sessions"},
	"reporting": {"fact_sales", "sales_lines", "report_cache"},
	"portal":    {"users", "page_views", "web_sessions"},
	"analytics": {"events", "event_props", "ingest_batches"},
}

// statement indexes the chain scenarios refer to
const (
	stUpdate = 2 // UPDATE t1 SET status: the convoy statement
	stInsert = 3
	stReport = 5 // the long report
	stPoint  = 0
)

func statementsFor(app string) []stmtDef {
	t := tables[app]
	r := strings.NewReplacer("{t1}", t[0], "{t2}", t[1], "{t3}", t[2])
	defs := []stmtDef{
		{text: "SELECT * FROM {t1} WHERE id = $1", rate: 120, meanMS: 0.08, rows: 1},
		{text: "SELECT {t1}.id, {t2}.status FROM {t1} JOIN {t2} ON {t2}.parent_id = {t1}.id WHERE {t1}.account_id = $1 ORDER BY {t1}.created_at DESC LIMIT $2", rate: 30, meanMS: 1.8, rows: 20},
		{text: "UPDATE {t1} SET status = $1, updated_at = now() WHERE id = $2", rate: 25, meanMS: 0.3, rows: 1, write: true},
		{text: "INSERT INTO {t2} (parent_id, line_no, amount) VALUES ($1, $2, $3)", rate: 40, meanMS: 0.15, rows: 1, write: true},
		{text: "SELECT count(*) FROM {t2} WHERE created_at > $1", rate: 0.2, meanMS: 45, rows: 1},
		{text: "SELECT date_trunc($1, created_at) AS d, sum(amount) FROM {t2} WHERE created_at BETWEEN $2 AND $3 GROUP BY 1 ORDER BY 1", rate: 0.02, meanMS: 850, rows: 30, report: true},
		{text: "DELETE FROM {t3} WHERE expires_at < now()", rate: 0.01, meanMS: 120, rows: 400, write: true},
		{text: "SELECT * FROM {t3} WHERE token = $1", rate: 80, meanMS: 0.05, rows: 1},
		{text: "UPDATE {t3} SET last_seen = now() WHERE token = $1", rate: 20, meanMS: 0.1, rows: 1, write: true},
		{text: "SELECT {t1}.*, {t3}.* FROM {t1} LEFT JOIN {t3} ON {t3}.owner_id = {t1}.owner_id WHERE {t1}.name ILIKE $1", rate: 0.5, meanMS: 220, rows: 12, report: true},
		{text: "SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = $1", rate: 0.05, meanMS: 2, rows: 300},
		{text: "WITH x AS (SELECT parent_id, sum(amount) AS s FROM {t2} GROUP BY 1) UPDATE {t1} SET total = x.s FROM x WHERE x.parent_id = {t1}.id", rate: 0.0003, meanMS: 4200, rows: 50000, write: true, report: true},
		{text: "SELECT id, payload FROM {t2} WHERE parent_id = ANY($1) FOR UPDATE SKIP LOCKED", rate: 6, meanMS: 0.9, rows: 8},
		{text: "INSERT INTO {t3} (token, owner_id, expires_at) VALUES ($1, $2, $3) ON CONFLICT (token) DO NOTHING", rate: 4, meanMS: 0.2, rows: 1, write: true},
		{text: "SELECT {t1}.id FROM {t1} WHERE {t1}.updated_at > $1 ORDER BY {t1}.updated_at LIMIT $2", rate: 1.5, meanMS: 6, rows: 500},
		{text: "VACUUM (ANALYZE) {t2}", rate: 0.00001, meanMS: 95000, rows: 0},
	}
	for i := range defs {
		defs[i].text = r.Replace(defs[i].text)
	}
	return defs
}

// ddlText is the ALTER the DDL chain queues behind a long report.
func ddlText(app string) string {
	return "ALTER TABLE " + tables[app][1] + " ADD COLUMN discount_code text"
}

// counters is one cumulative series set (a database, a statement, an IO row).
type counters map[string]float64

func (c counters) add(k string, v float64) { c[k] += v }
func (c counters) int(k string) int64      { return int64(c[k]) }

// Gen produces one instance's rows, snapshot by snapshot, oldest first.
type Gen struct {
	Spec  Spec
	idx   int
	rng   *rand.Rand
	start time.Time // the first snapshot of the history
	end   time.Time // the anchor: the last snapshot of the seed
	prev  time.Time // the previous snapshot (zero before the first)

	pmStart    time.Time
	stmts      []stmtDef
	stmtCum    []counters
	stmtPrev   time.Time
	statsReset time.Time
	resetAt    time.Time
	dbCum      []counters
	srvCum     counters
	ioCum      []counters
	runID      int64
}

// NewGen builds the generator of one instance; seed and idx make it deterministic.
func NewGen(s Spec, idx int, seed uint64, start, end time.Time) *Gen {
	g := &Gen{Spec: s, idx: idx, rng: rand.New(rand.NewPCG(seed, uint64(idx)+1)), start: start, end: end}
	g.pmStart = end.Add(-41*24*time.Hour - time.Duration(idx%24)*time.Hour).Truncate(time.Minute)
	g.statsReset = g.pmStart
	if s.StmtReset {
		g.resetAt = end.Add(-3*24*time.Hour + 2*time.Hour).Truncate(5 * time.Minute)
	}
	g.stmts = statementsFor(s.App)
	g.stmtCum = make([]counters, len(g.stmts))
	for i := range g.stmtCum {
		g.stmtCum[i] = counters{}
	}
	g.dbCum = make([]counters, len(g.dbList()))
	for i := range g.dbCum {
		g.dbCum[i] = counters{}
	}
	g.srvCum = counters{}
	g.ioCum = make([]counters, len(ioKinds))
	for i := range g.ioCum {
		g.ioCum[i] = counters{}
	}
	return g
}

// Grid is the snapshot times from end-days to end: every 5 minutes, then every minute in the last hour.
func Grid(end time.Time, days int) []time.Time {
	start := end.Add(-time.Duration(days) * 24 * time.Hour).Truncate(5 * time.Minute)
	fine := end.Add(-time.Hour)
	var out []time.Time
	for t := start; t.Before(fine); t = t.Add(5 * time.Minute) {
		out = append(out, t)
	}
	for t := fine; !t.After(end); t = t.Add(time.Minute) {
		out = append(out, t)
	}
	return out
}

// noise is a value in [0,1) fixed by its key and a time: two instances (a sender and its receiver)
// read the same lag at the same snapshot without sharing a random stream.
func noise(key string, t time.Time) float64 {
	h := fnv.New64a()
	_, _ = fmt.Fprintf(h, "%s|%d", key, t.Unix())
	return float64(h.Sum64()>>11) / float64(1<<53)
}

func hash64(s string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(s))
	return int64(h.Sum64() & 0x7fffffffffffffff)
}

// curve is the load at t: a daily bell around 15:00 UTC on weekdays, flatter at the weekend.
func curve(t time.Time) float64 {
	h := float64(t.Hour()) + float64(t.Minute())/60
	v := 0.25
	if h > 6 && h < 22 {
		v += 0.75 * math.Sin(math.Pi*(h-6)/16)
	}
	if wd := t.Weekday(); wd == time.Saturday || wd == time.Sunday {
		v *= 0.55
	}
	return v
}

// window reports whether t falls in a scenario's window: daily at hourUTC for dur, and the
// current one that ends at the anchor (so the latest snapshot shows it). ws is the window's start.
// Past the anchor (the live trickle of 'demo -serve') the current window repeats every dur + 10
// minutes, so a demo left running shows fresh chains with sane ages instead of one that never ends.
func (g *Gen) window(t time.Time, hourUTC int, dur time.Duration) (bool, time.Time) {
	cur := g.end.Add(-dur + 2*time.Minute)
	if !t.Before(cur) {
		period := dur + 10*time.Minute
		ws := cur.Add(t.Sub(cur) / period * period)
		return t.Before(ws.Add(dur)), ws
	}
	day := time.Date(t.Year(), t.Month(), t.Day(), hourUTC, 0, 0, 0, time.UTC)
	if !t.Before(day) && t.Before(day.Add(dur)) {
		return true, day
	}
	return false, time.Time{}
}

func (g *Gen) dbList() []string {
	return append(append([]string{}, g.Spec.DBs...), "postgres")
}

func dbOID(i int) int64 {
	if i < 0 {
		return 5
	}
	return 16384 + int64(i)*17
}

// Step returns the import batches of the snapshot at t (t after the previous step).
func (g *Gen) Step(t time.Time) []Batch {
	first := g.prev.IsZero()
	prev := g.prev
	if first {
		prev = t.Add(-5 * time.Minute)
	}
	var out []Batch
	add := func(c string, rows []Row) {
		if len(rows) > 0 {
			out = append(out, Batch{Collection: c, At: t, Rows: rows})
		}
	}
	if first || (t.Minute() == 0 && t.Hour()%6 == 0) || t.Equal(g.end) {
		add("instance", g.instanceRows(t))
	}
	if first || t.Minute() == 0 {
		add("databases", g.databaseRows(t))
	}
	add("activity", g.activityRows(t))
	add("dbstats", g.dbstatsRows(t, prev))
	if !g.Spec.StmtBroken && (first || t.Minute()%5 == 0) {
		add("statements", g.statementRows(t))
	}
	add("replication", g.replicationRows(t))
	if g.Spec.Cron {
		add("jobs", g.jobRows(t, prev))
	}
	if g.Spec.Logs {
		add("logs", g.logRows(t, prev))
	}
	if g.Spec.DMS {
		add("dms", g.dmsRows(t))
	}
	if first || t.Minute() == 0 {
		add("tables", g.tableRows(t, first))
	}
	g.prev = t
	return out
}

// Collections names what this instance's collector runs (for the collection log).
func (g *Gen) Collections() []string {
	c := []string{"instance", "databases", "activity", "dbstats", "statements", "replication"}
	if g.Spec.Cron {
		c = append(c, "jobs")
	}
	if g.Spec.Logs {
		c = append(c, "logs")
	}
	if g.Spec.DMS {
		c = append(c, "dms")
	}
	return append(c, "tables")
}

// ---------------------------------------------------------------- instance

func (g *Gen) settings(t time.Time) []Row {
	s := g.Spec
	vals := map[string]string{
		"checkpoint_timeout": "900", "effective_cache_size": "3145728", "log_min_duration_statement": "-1",
		"maintenance_work_mem": "1048576", "max_connections": fmt.Sprint(s.MaxConn), "max_wal_size": "8192",
		"random_page_cost": "1.1", "shared_buffers": "1048576", "track_io_timing": "on", "wal_level": "replica", "work_mem": "4096",
		"shared_preload_libraries": "pg_stat_statements",
	}
	if s.Cron {
		vals["shared_preload_libraries"] = "pg_stat_statements,pg_cron"
	}
	if s.StmtBroken {
		vals["shared_preload_libraries"] = ""
	}
	if s.DMS || s.SlotStale {
		vals["wal_level"] = "logical"
	}
	if s.Platform == "rds" || s.Platform == "aurora" {
		vals["log_min_duration_statement"] = "5000"
	}
	if s.SettingEdit != "" {
		name, rest, _ := strings.Cut(s.SettingEdit, "=")
		oldV, newV, _ := strings.Cut(rest, ">")
		vals[name] = oldV
		if !t.Before(g.end.Add(-3*24*time.Hour + time.Duration(g.idx)*time.Hour)) {
			vals[name] = newV
		}
	}
	names := make([]string, 0, len(vals))
	for k := range vals {
		names = append(names, k)
	}
	slices.Sort(names)
	out := make([]Row, 0, len(names))
	for _, n := range names {
		out = append(out, Row{"name": n, "value": vals[n]})
	}
	return out
}

func (g *Gen) instanceRows(t time.Time) []Row {
	s := g.Spec
	ext := []Row{{"name": "plpgsql", "version": "1.0"}}
	if !s.StmtBroken {
		ext = append(ext, Row{"name": "pg_stat_statements", "version": "1.10"})
	}
	if s.Cron {
		ext = append(ext, Row{"name": "pg_cron", "version": "1.6"})
	}
	return []Row{{
		"server_version": s.Version, "server_version_num": s.VersionNum, "is_replica": s.Replica,
		"postmaster_start": g.pmStart, "server_now": t, "time_zone": "UTC", "connected_database": "postgres",
		"connected_user": "pgvigil_monitor", "server_addr": s.Addr, "server_port": 5432, "data_checksums": "on",
		"shared_buffers": "8GB", "max_connections": s.MaxConn, "work_mem": "4MB", "wal_level": "replica",
		"track_io_timing": "on", "log_min_duration_statement": "-1", "database_count": len(g.dbList()),
		"platform": s.Platform, "has_pg_stat_statements": !s.StmtBroken, "has_pg_cron": s.Cron, "has_pgagent": false,
		"has_wait_sampling": false, "has_log_fdw": false, "extensions": ext, "non_default_settings": g.settings(t),
	}}
}

// ---------------------------------------------------------------- databases

func (g *Gen) databaseRows(t time.Time) []Row {
	days := t.Sub(g.start).Hours() / 24
	var out []Row
	for i, d := range g.Spec.DBs {
		size := (60e9*g.Spec.Load/float64(i+1) + 4e9) * (1 + 0.004*days)
		out = append(out, Row{"dbid": dbOID(i), "datname": d, "owner": "app_" + g.Spec.App, "encoding": "UTF8",
			"lc_collate": "en_US.UTF-8", "lc_ctype": "en_US.UTF-8", "is_template": false, "allow_conn": true, "conn_limit": -1,
			"tablespace": "pg_default", "xid_age": int64(40e6 + math.Mod(days*9e6*g.Spec.Load, 160e6)), "mxid_age": int64(1e5 + days*2e4),
			"can_connect": true, "size_bytes": int64(size)})
	}
	for _, x := range []struct {
		name     string
		oid      int64
		template bool
		allow    bool
	}{{"postgres", 5, false, true}, {"template0", 4, true, false}, {"template1", 1, true, true}} {
		out = append(out, Row{"dbid": x.oid, "datname": x.name, "owner": "postgres", "encoding": "UTF8", "lc_collate": "en_US.UTF-8",
			"lc_ctype": "en_US.UTF-8", "is_template": x.template, "allow_conn": x.allow, "conn_limit": -1, "tablespace": "pg_default",
			"xid_age": int64(40e6 + math.Mod(days*9e6*g.Spec.Load, 160e6)), "mxid_age": int64(1e5), "can_connect": x.allow,
			"size_bytes": int64(7.6e6)})
	}
	return out
}

// ---------------------------------------------------------------- activity

func (g *Gen) session(pid int, st stmtDef, state string, qStart time.Time) Row {
	s := g.Spec
	return Row{"kind": "session", "pid": pid, "backend_start": qStart.Add(-time.Duration(1+pid%70) * time.Hour),
		"datname": s.DBs[0], "usename": "app_" + s.App, "application_name": s.App + "-api", "client": fmt.Sprintf("10.60.%d.%d", pid%7, 10+pid%200),
		"state": state, "wait_event_type": nil, "wait_event": nil, "xact_start": qStart.Add(-40 * time.Millisecond),
		"query_start": qStart, "state_change": qStart, "xid_assigned": st.write, "backend_xmin_age": 2 + pid%40,
		"blocking_pids": nil, "leader_pid": nil, "query_id": hash64(s.Name + "|" + st.text), "query_hash": hash64(st.text),
		"query": st.text, "backend_type": "client backend", "is_blocker": false}
}

func (g *Gen) activityRows(t time.Time) []Row {
	s := g.Spec
	c := curve(t)
	nActive := int(math.Round(s.Load * (1 + 5*c) * (0.7 + 0.6*g.rng.Float64())))
	used := map[int]bool{}
	pid := func(key string) int {
		p := 2000 + int(uint64(hash64(key))%60000)
		for used[p] {
			p++
		}
		used[p] = true
		return p
	}
	var rows []Row
	waitingLock, clientWait, idleTxn := 0, 0, 0
	longestActive, longestIdle := 0.0, 0.0
	xminAge := 120 + g.rng.IntN(4000)

	// weighted pick: a statement's share of time
	total := 0.0
	for _, st := range g.stmts {
		total += st.rate * st.meanMS
	}
	for i := 0; i < nActive; i++ {
		x := g.rng.Float64() * total
		k := 0
		for j, st := range g.stmts {
			x -= st.rate * st.meanMS
			if x <= 0 {
				k = j
				break
			}
		}
		st := g.stmts[k]
		dur := time.Duration(st.meanMS*(0.2+3*g.rng.Float64())*float64(time.Millisecond)) + time.Duration(g.rng.IntN(50))*time.Millisecond
		r := g.session(pid(fmt.Sprintf("%s|%d|%d", s.Name, t.Unix(), i)), st, "active", t.Add(-dur))
		switch w := g.rng.Float64(); {
		case w < 0.15:
			r["wait_event_type"], r["wait_event"] = "IO", "DataFileRead"
		case w < 0.25:
			r["wait_event_type"], r["wait_event"] = "Client", "ClientRead"
			clientWait++
		case w < 0.30:
			r["wait_event_type"], r["wait_event"] = "LWLock", "WALWrite"
		}
		longestActive = math.Max(longestActive, dur.Seconds())
		rows = append(rows, r)
	}
	if g.rng.Float64() < 0.06 { // a short idle-in-transaction now and then
		st := g.stmts[stUpdate]
		r := g.session(pid(fmt.Sprintf("%s|%d|idle", s.Name, t.Unix())), st, "idle in transaction", t.Add(-time.Duration(2+g.rng.IntN(18))*time.Second))
		r["xact_start"] = t.Add(-25 * time.Second)
		rows = append(rows, r)
		idleTxn++
		longestIdle = math.Max(longestIdle, t.Sub(r["state_change"].(time.Time)).Seconds())
	}

	// the scenarios: a head and its waiters, stable pids for the whole window
	// a session appears once its statement has started; a waiter only while what it waits on is there
	chain := func(head Row, waiters []Row) {
		if head["query_start"].(time.Time).After(t) {
			return
		}
		present := map[int]bool{head["pid"].(int): true}
		blockers := map[int]bool{}
		kept := []Row{head}
		for _, w := range waiters {
			b := w["blocking_pids"].([]int)[0]
			if w["query_start"].(time.Time).After(t) || !present[b] {
				continue
			}
			present[w["pid"].(int)] = true
			blockers[b] = true
			kept = append(kept, w)
			waitingLock++
			longestActive = math.Max(longestActive, t.Sub(w["query_start"].(time.Time)).Seconds())
		}
		for _, r := range kept {
			r["is_blocker"] = blockers[r["pid"].(int)]
			rows = append(rows, r)
		}
	}
	if s.ChainActive {
		if in, ws := g.window(t, 10, 20*time.Minute); in {
			key := fmt.Sprintf("%s|chainA|%d", s.Name, ws.Unix())
			st := g.stmts[stUpdate]
			h := g.session(pid(key+"|h"), st, "active", ws.Add(time.Second))
			h["xact_start"] = ws
			h["xid_assigned"] = true
			hp := h["pid"].(int)
			w1 := g.session(pid(key+"|w1"), st, "active", ws.Add(40*time.Second))
			w1["wait_event_type"], w1["wait_event"], w1["blocking_pids"], w1["is_blocker"] = "Lock", "transactionid", []int{hp}, true
			w2 := g.session(pid(key+"|w2"), st, "active", ws.Add(95*time.Second))
			w2["wait_event_type"], w2["wait_event"], w2["blocking_pids"] = "Lock", "tuple", []int{w1["pid"].(int)}
			w3 := g.session(pid(key+"|w3"), st, "active", ws.Add(130*time.Second))
			w3["wait_event_type"], w3["wait_event"], w3["blocking_pids"] = "Lock", "transactionid", []int{hp}
			longestActive = math.Max(longestActive, t.Sub(ws).Seconds())
			chain(h, []Row{w1, w2, w3})
		}
	}
	if s.ChainDDL {
		if in, ws := g.window(t, 14, 25*time.Minute); in {
			key := fmt.Sprintf("%s|chainB|%d", s.Name, ws.Unix())
			h := g.session(pid(key+"|h"), g.stmts[stReport], "active", ws)
			h["wait_event_type"], h["wait_event"] = "IO", "DataFileRead"
			hp := h["pid"].(int)
			ddl := stmtDef{text: ddlText(s.App), write: true}
			alter := g.session(pid(key+"|ddl"), ddl, "active", ws.Add(3*time.Minute))
			alter["usename"], alter["application_name"] = "deploy_bot", "flyway"
			alter["wait_event_type"], alter["wait_event"], alter["blocking_pids"], alter["is_blocker"] = "Lock", "relation", []int{hp}, true
			ap := alter["pid"].(int)
			var ws2 []Row
			ws2 = append(ws2, alter)
			for i, k := range []int{stPoint, stInsert, stPoint, stInsert, stPoint} {
				w := g.session(pid(fmt.Sprintf("%s|q%d", key, i)), g.stmts[k], "active", ws.Add(3*time.Minute+time.Duration(5+i*20)*time.Second))
				w["wait_event_type"], w["wait_event"], w["blocking_pids"] = "Lock", "relation", []int{ap}
				ws2 = append(ws2, w)
			}
			longestActive = math.Max(longestActive, t.Sub(ws).Seconds())
			chain(h, ws2)
		}
	}
	if s.IdleHead {
		if in, ws := g.window(t, 13, 30*time.Minute); in {
			key := fmt.Sprintf("%s|idle|%d", s.Name, ws.Unix())
			st := g.stmts[stUpdate]
			h := g.session(pid(key+"|h"), st, "idle in transaction", ws.Add(time.Second))
			h["xact_start"], h["state_change"], h["xid_assigned"], h["backend_xmin_age"] = ws, ws.Add(2*time.Second), true, nil
			h["application_name"], h["client"] = "hr-batch", "10.60.9.44"
			hp := h["pid"].(int)
			w1 := g.session(pid(key+"|w1"), st, "active", ws.Add(4*time.Minute))
			w1["wait_event_type"], w1["wait_event"], w1["blocking_pids"] = "Lock", "transactionid", []int{hp}
			w2 := g.session(pid(key+"|w2"), st, "active", ws.Add(9*time.Minute))
			w2["wait_event_type"], w2["wait_event"], w2["blocking_pids"] = "Lock", "transactionid", []int{hp}
			idleTxn++
			longestIdle = math.Max(longestIdle, t.Sub(ws.Add(2*time.Second)).Seconds())
			xminAge += int(t.Sub(ws).Seconds() * 40)
			chain(h, []Row{w1, w2})
		}
	}
	active := 0
	for _, r := range rows {
		if r["state"] == "active" {
			active++
		}
	}
	idle := int(float64(s.MaxConn) * 0.08 * (0.5 + c))
	rows = append(rows, Row{"kind": "summary", "total": active + idle + idleTxn, "active": active, "idle": idle,
		"idle_in_txn": idleTxn, "idle_in_txn_aborted": 0, "waiting_lock": waitingLock, "active_client_wait": clientWait,
		"longest_active_secs": int(longestActive), "longest_idle_txn_secs": int(longestIdle), "oldest_xmin_age": xminAge,
		"max_connections": s.MaxConn})
	return rows
}

// ---------------------------------------------------------------- dbstats

var ioKinds = []struct{ backend, object, context string }{
	{"client backend", "relation", "normal"},
	{"client backend", "temp relation", "normal"},
	{"autovacuum worker", "relation", "vacuum"},
	{"checkpointer", "relation", "normal"},
	{"background writer", "relation", "normal"},
}

// deadlockTimes are the moments the deadlock scenario fires: twice a day before the last 24 h, and
// three in the last 24 h (the overview's 24 h check reads 3).
func (g *Gen) deadlockTimes(from, to time.Time) []time.Time {
	if !g.Spec.Deadlocks {
		return nil
	}
	var out []time.Time
	for _, d := range []time.Duration{5*time.Hour + 13*time.Minute, 2*time.Hour + 41*time.Minute, 47 * time.Minute} {
		if x := g.end.Add(-d); x.After(from) && !x.After(to) {
			out = append(out, x)
		}
	}
	for day := g.start.Truncate(24 * time.Hour); day.Before(g.end.Add(-24 * time.Hour)); day = day.Add(24 * time.Hour) {
		for _, x := range []time.Time{day.Add(11*time.Hour + 17*time.Minute), day.Add(16*time.Hour + 43*time.Minute)} {
			if x.After(from) && !x.After(to) && x.Before(g.end.Add(-24*time.Hour)) {
				out = append(out, x)
			}
		}
	}
	return out
}

func (g *Gen) dbstatsRows(t, prev time.Time) []Row {
	s := g.Spec
	dt := t.Sub(prev).Seconds()
	c := curve(t)
	load := s.Load * (0.15 + c)
	if s.Replica {
		load *= 0.3
	}
	var out []Row
	for i, name := range g.dbList() {
		share := 1.0
		switch {
		case name == "postgres":
			share = 0.01
		case i > 0:
			share = 0.15
		}
		k := g.dbCum[i]
		commits := 150 * load * share * dt * (0.9 + 0.2*g.rng.Float64())
		k.add("xact_commit", commits)
		k.add("xact_rollback", commits*0.004)
		k.add("blks_hit", commits*60)
		k.add("blks_read", commits*0.6*(1+c))
		k.add("tup_returned", commits*400)
		k.add("tup_fetched", commits*35)
		if !s.Replica {
			k.add("tup_inserted", commits*1.6)
			k.add("tup_updated", commits*1.1)
			k.add("tup_deleted", commits*0.2)
		}
		if s.Replica {
			k.add("conflicts", chance(g.rng.Float64(), 0.02*dt/300))
		}
		if g.rng.Float64() < 0.3*c*dt/300 {
			k.add("temp_files", 1)
			k.add("temp_bytes", 64e6*g.rng.Float64())
		}
		if i == 0 {
			k.add("deadlocks", float64(len(g.deadlockTimes(prev, t))))
		}
		k.add("blk_read_time", commits*0.6*0.08)
		k.add("blk_write_time", commits*0.01)
		k.add("session_time", dt*1000*float64(s.MaxConn)*0.08*share)
		k.add("active_time", dt*1000*s.Load*(1+5*c)*share)
		k.add("idle_in_transaction_time", dt*20*share)
		k.add("sessions", dt*0.5*share*(1+c))
		k.add("sessions_abandoned", chance(g.rng.Float64(), 0.01*dt/300))
		oid := dbOID(i)
		if name == "postgres" {
			oid = 5
		}
		out = append(out, Row{"kind": "db", "dbid": oid, "datname": name, "stats_reset": nil, "postmaster_start": g.pmStart,
			"numbackends": int(float64(s.MaxConn) * 0.08 * (0.5 + c) * share),
			"xact_commit": k.int("xact_commit"), "xact_rollback": k.int("xact_rollback"), "blks_read": k.int("blks_read"),
			"blks_hit": k.int("blks_hit"), "tup_returned": k.int("tup_returned"), "tup_fetched": k.int("tup_fetched"),
			"tup_inserted": k.int("tup_inserted"), "tup_updated": k.int("tup_updated"), "tup_deleted": k.int("tup_deleted"),
			"conflicts": k.int("conflicts"), "temp_files": k.int("temp_files"), "temp_bytes": k.int("temp_bytes"),
			"deadlocks": k.int("deadlocks"), "checksum_failures": 0, "checksum_last_failure": nil,
			"blk_read_time": k["blk_read_time"], "blk_write_time": k["blk_write_time"], "session_time": k["session_time"],
			"active_time": k["active_time"], "idle_in_transaction_time": k["idle_in_transaction_time"],
			"sessions": k.int("sessions"), "sessions_abandoned": k.int("sessions_abandoned"), "sessions_fatal": 0, "sessions_killed": 0})
	}
	v := g.srvCum
	commits := 150 * load * dt
	v.add("checkpoints_timed", dt/900)
	if c > 0.85 && g.rng.Float64() < 0.08*dt/300 {
		v.add("checkpoints_req", 1)
	}
	v.add("checkpoint_write_time", dt*40*load)
	v.add("checkpoint_sync_time", dt*2*load)
	v.add("buffers_checkpoint", commits*0.8)
	v.add("buffers_clean", commits*0.3)
	v.add("maxwritten_clean", chance(g.rng.Float64(), 0.05*dt/300))
	v.add("buffers_backend", commits*0.05)
	v.add("buffers_alloc", commits*0.7)
	v.add("wal_records", commits*7)
	v.add("wal_fpi", commits*0.4)
	v.add("wal_bytes", commits*2100)
	v.add("wal_write", commits*0.9)
	v.add("wal_sync", commits*0.85)
	v.add("wal_write_time", commits*0.002)
	v.add("wal_sync_time", commits*0.05)
	out = append(out, Row{"kind": "server", "bgwriter_stats_reset": g.pmStart, "checkpointer_stats_reset": g.pmStart,
		"checkpoints_timed": v.int("checkpoints_timed"), "checkpoints_req": v.int("checkpoints_req"),
		"checkpoint_write_time": v["checkpoint_write_time"], "checkpoint_sync_time": v["checkpoint_sync_time"],
		"buffers_checkpoint": v.int("buffers_checkpoint"), "buffers_clean": v.int("buffers_clean"),
		"maxwritten_clean": v.int("maxwritten_clean"), "buffers_backend": v.int("buffers_backend"), "buffers_backend_fsync": 0,
		"buffers_alloc": v.int("buffers_alloc"), "wal_records": v.int("wal_records"), "wal_fpi": v.int("wal_fpi"),
		"wal_bytes": v.int("wal_bytes"), "wal_buffers_full": 0, "wal_write": v.int("wal_write"), "wal_sync": v.int("wal_sync"),
		"wal_write_time": v["wal_write_time"], "wal_sync_time": v["wal_sync_time"]})
	if s.VersionNum >= 160000 {
		for i, k := range ioKinds {
			v := g.ioCum[i]
			f := []float64{1, 0.05, 0.2, 0.3, 0.1}[i]
			v.add("reads", commits*0.6*f)
			v.add("read_time", commits*0.6*f*0.08)
			v.add("writes", commits*0.3*f)
			v.add("write_time", commits*0.3*f*0.02)
			v.add("extends", commits*0.05*f)
			v.add("hits", commits*60*f)
			v.add("evictions", commits*0.4*f)
			v.add("fsyncs", dt/900*f)
			out = append(out, Row{"kind": "io", "backend_type": k.backend, "object": k.object, "context": k.context,
				"stats_reset": g.pmStart, "reads": v.int("reads"), "read_time": v["read_time"], "writes": v.int("writes"),
				"write_time": v["write_time"], "writebacks": 0, "writeback_time": 0.0, "extends": v.int("extends"), "extend_time": 0.0,
				"op_bytes": 8192, "hits": v.int("hits"), "evictions": v.int("evictions"), "reuses": 0, "fsyncs": v.int("fsyncs"),
				"fsync_time": v["fsyncs"] * 3})
		}
	}
	return out
}

// ---------------------------------------------------------------- statements

func (g *Gen) statementRows(t time.Time) []Row {
	s := g.Spec
	from := g.stmtPrev
	if from.IsZero() {
		from = t.Add(-5 * time.Minute)
	}
	if !g.resetAt.IsZero() && g.resetAt.After(from) && !g.resetAt.After(t) {
		for i := range g.stmtCum {
			g.stmtCum[i] = counters{}
		}
		g.statsReset = g.resetAt
		from = g.resetAt
	}
	dt := t.Sub(from).Seconds()
	c := curve(t)
	chainA, _ := g.window(t, 10, 20*time.Minute)
	idle, _ := g.window(t, 13, 30*time.Minute)
	var out []Row
	for i, st := range g.stmts {
		k := g.stmtCum[i]
		calls := st.rate * s.Load * (0.15 + c) * dt * (0.85 + 0.3*g.rng.Float64())
		if s.Replica && st.write {
			calls = 0
		}
		mean := st.meanMS * (0.7 + 0.6*g.rng.Float64())
		if i == stUpdate && ((s.ChainActive && chainA) || (s.IdleHead && idle)) {
			mean *= 400 // lock waits count in the execution time
		}
		k.add("calls", calls)
		if k["calls"] < 1 {
			continue // not seen yet since the reset: pg_stat_statements has no row
		}
		k.add("total_exec_ms", calls*mean)
		k.add("rows", calls*st.rows)
		k.add("shared_blks_hit", calls*(4+st.rows*3))
		rd := 0.02
		if st.report {
			rd = 40
		}
		k.add("shared_blks_read", calls*rd*(1+c))
		k.add("blk_read_ms", calls*rd*0.08)
		if st.write {
			k.add("shared_blks_dirtied", calls*1.2)
			k.add("shared_blks_written", calls*0.1)
			k.add("wal_bytes", calls*st.rows*180)
		}
		if st.report {
			k.add("temp_blks_read", calls*800)
			k.add("temp_blks_written", calls*800)
			k.add("temp_read_ms", calls*3)
			k.add("temp_write_ms", calls*5)
		}
		db := s.DBs[0]
		dbid := dbOID(0)
		if strings.HasPrefix(st.text, "SELECT n.nspname") {
			db, dbid = "postgres", 5
		}
		out = append(out, Row{"kind": "stmt", "dbid": dbid, "datname": db, "userid": int64(16500), "usename": "app_" + s.App,
			"queryid": hash64(s.Name + "|" + st.text), "toplevel": true, "calls": k.int("calls"), "total_exec_ms": k["total_exec_ms"],
			"rows": k.int("rows"), "shared_blks_hit": k.int("shared_blks_hit"), "shared_blks_read": k.int("shared_blks_read"),
			"shared_blks_dirtied": k.int("shared_blks_dirtied"), "shared_blks_written": k.int("shared_blks_written"),
			"temp_blks_read": k.int("temp_blks_read"), "temp_blks_written": k.int("temp_blks_written"),
			"blk_read_ms": k["blk_read_ms"], "blk_write_ms": k["blk_write_ms"], "temp_read_ms": k["temp_read_ms"],
			"temp_write_ms": k["temp_write_ms"], "wal_bytes": k.int("wal_bytes"), "query": st.text})
	}
	out = append(out, Row{"kind": "info", "dealloc": 0, "stats_reset": g.statsReset})
	g.stmtPrev = t
	return out
}

// ---------------------------------------------------------------- replication

// lagSecs is the replica's replay lag at t: under a second, then climbing for the last 90 minutes
// before the anchor, then level.
func (g *Gen) lagSecs(key string, t time.Time) float64 {
	v := 0.1 + 0.8*noise(key, t)
	if ramp := t.Sub(g.end.Add(-90 * time.Minute)).Seconds(); ramp > 0 {
		v += math.Min(ramp, 90*60) * 0.08 // holds at the anchor's ~432 s while 'demo -serve' runs on
	}
	return v
}

func (g *Gen) replicationRows(t time.Time) []Row {
	s := g.Spec
	var out []Row
	if s.SenderTo != "" {
		lag := g.lagSecs(s.Name, t)
		lagBytes := int64(lag * 150 * s.Load * 2100 * (0.2 + curve(t)))
		out = append(out,
			Row{"kind": "sender", "pid": 900 + g.idx, "usename": "replicator", "application_name": s.SenderTo, "client_addr": "10.20.1.12",
				"state": "streaming", "sync_state": "async", "replay_lag_bytes": lagBytes, "replay_lag_secs": lag,
				"write_lag_secs": lag * 0.02, "flush_lag_secs": lag * 0.03},
			Row{"kind": "slot", "slot_name": strings.ReplaceAll(s.SenderTo, "-", "_") + "_slot", "plugin": nil, "slot_type": "physical",
				"datname": nil, "temporary": false, "active": true, "active_pid": 900 + g.idx, "retained_bytes": lagBytes, "wal_status": "reserved"})
	}
	if s.ReceiverOf != "" {
		out = append(out, Row{"kind": "receiver", "pid": 700 + g.idx, "status": "streaming", "sender_host": "10.20.1.11", "sender_port": 5432,
			"slot_name": strings.ReplaceAll(s.Name, "-", "_") + "_slot", "replay_delay_secs": g.lagSecs(s.ReceiverOf, t)})
	}
	if s.SlotStale {
		frac := t.Sub(g.start).Hours() / (7 * 24)
		out = append(out,
			Row{"kind": "slot", "slot_name": "legacy_cdc_slot", "plugin": "pgoutput", "slot_type": "logical", "datname": s.DBs[0],
				"temporary": false, "active": false, "active_pid": nil, "retained_bytes": int64((2 + 17*frac) * (1 << 30)), "wal_status": "extended"},
			Row{"kind": "publication", "pubname": "billing_pub", "puballtables": false, "pubinsert": true, "pubupdate": true,
				"pubdelete": true, "pubtruncate": false})
	}
	if s.AuroraRead != "" {
		out = append(out,
			Row{"kind": "aurora_replica", "server_id": s.Name, "session_id": "MASTER_SESSION_ID", "replica_lag_in_msec": nil},
			Row{"kind": "aurora_replica", "server_id": s.AuroraRead, "session_id": fmt.Sprintf("%08x-reader", hash64(s.AuroraRead)&0xffffffff),
				"replica_lag_in_msec": 8 + 30*noise(s.AuroraRead, t)})
	}
	if s.DMS {
		out = append(out, Row{"kind": "slot", "slot_name": "dms_erp_slot", "plugin": "test_decoding", "slot_type": "logical",
			"datname": s.DBs[0], "temporary": false, "active": true, "active_pid": 1200 + g.idx,
			"retained_bytes": int64(g.dmsLatency(t) * 4e5), "wal_status": "reserved"})
	}
	return out
}

// ---------------------------------------------------------------- jobs (pg_cron)

type cronJob struct {
	id       int64
	name     string
	schedule string
	command  string
	every    time.Duration // the schedule as a period
	offset   time.Duration // from the period's start
	dur      time.Duration
}

func (g *Gen) cronJobs() []cronJob {
	if g.Spec.App == "billing" {
		return []cronJob{
			{1, "partition-maintenance", "0 1 * * *", "CALL partman.run_maintenance_proc()", 24 * time.Hour, time.Hour, 40 * time.Second},
			{2, "purge-tokens", "*/30 * * * *", "DELETE FROM payment_tokens WHERE expires_at < now()", 30 * time.Minute, 0, 3 * time.Second},
		}
	}
	return []cronJob{
		{1, "purge-sessions", "*/15 * * * *", "DELETE FROM user_sessions WHERE expires_at < now()", 15 * time.Minute, 0, 2 * time.Second},
		{2, "refresh-sales-mv", "5 * * * *", "REFRESH MATERIALIZED VIEW CONCURRENTLY sales_by_day", time.Hour, 5 * time.Minute, 95 * time.Second},
		{3, "vacuum-analyze-nightly", "0 3 * * *", "VACUUM (ANALYZE) activities", 24 * time.Hour, 3 * time.Hour, 21 * time.Minute},
	}
}

func (g *Gen) jobRows(t, prev time.Time) []Row {
	s := g.Spec
	var out []Row
	for _, j := range g.cronJobs() {
		last := t.Truncate(j.every).Add(j.offset)
		if last.After(t) {
			last = last.Add(-j.every)
		}
		out = append(out, Row{"kind": "job", "scheduler": "pg_cron", "job_id": j.id, "job_name": j.name, "schedule": j.schedule,
			"command": j.command, "datname": s.DBs[0], "run_as": "postgres", "active": true, "nodename": "localhost", "nodeport": 5432,
			"next_run": last.Add(j.every), "last_run": last})
		// runs that ended in (prev, t]: a run is stored once it has finished
		for st := prev.Add(-j.dur).Truncate(j.every).Add(j.offset); !st.After(t); st = st.Add(j.every) {
			failed := s.CronFail && j.id == 2 && ((!st.Before(g.end.Add(-7*time.Hour)) && st.Before(g.end.Add(-5*time.Hour))) ||
				(!st.Before(g.end.Add(-74*time.Hour)) && st.Before(g.end.Add(-73*time.Hour))))
			d := j.dur
			if failed {
				d = 2 * time.Second
			}
			en := st.Add(d)
			if !en.After(prev) || en.After(t) || st.Before(g.start) {
				continue
			}
			g.runID++
			status, msg := "succeeded", "1 row"
			if j.id == 1 || strings.HasPrefix(j.command, "DELETE") {
				msg = fmt.Sprintf("DELETE %d", 10+int(noise(s.Name, st)*900))
			}
			if strings.HasPrefix(j.command, "REFRESH") {
				msg = "REFRESH MATERIALIZED VIEW"
			}
			if strings.HasPrefix(j.command, "VACUUM") {
				msg = "VACUUM"
			}
			if strings.HasPrefix(j.command, "CALL") {
				msg = "CALL"
			}
			if failed {
				status, msg = "failed", `ERROR:  could not obtain lock on materialized view "sales_by_day"`
			}
			out = append(out, Row{"kind": "run", "scheduler": "pg_cron", "job_id": j.id, "run_id": g.runID,
				"job_pid": 3000 + int(noise(s.Name+"pid", st)*50000), "datname": s.DBs[0], "run_as": "postgres", "command": j.command,
				"status": status, "return_message": msg, "start_time": st, "end_time": en, "duration_secs": d.Seconds()})
		}
	}
	return out
}

// ---------------------------------------------------------------- logs (CloudWatch)

func (g *Gen) logSource() string {
	kind := "instance"
	if g.Spec.Platform == "aurora" {
		kind = "cluster"
	}
	return "cloudwatch:/aws/rds/" + kind + "/" + g.Spec.Name + "/postgresql"
}

func (g *Gen) logRows(t, prev time.Time) []Row {
	s := g.Spec
	src := g.logSource()
	var out []Row
	ev := func(kind string, at time.Time, pid int, user, stmt, detail string, ms any) {
		out = append(out, Row{"kind": "event", "kind_of": kind, "at": at, "pid": pid, "client": fmt.Sprintf("10.60.%d.%d", pid%7, 10+pid%200),
			"usename": user, "datname": s.DBs[0], "duration_ms": ms, "statement": stmt, "detail": detail, "source": src,
			"event_key": fmt.Sprintf("%016x", hash64(fmt.Sprintf("%s|%s|%d|%d", s.Name, kind, at.UnixNano(), pid)))})
	}
	dt := t.Sub(prev).Hours()
	n := int(math.Floor(3*s.Load*(0.2+curve(t))*dt + g.rng.Float64()))
	for i := 0; i < n; i++ {
		st := g.stmts[[]int{stReport, 9, 4, 11}[g.rng.IntN(4)]]
		at := prev.Add(time.Duration(g.rng.Float64() * float64(t.Sub(prev))))
		ev("slow", at, 2000+g.rng.IntN(60000), "app_"+s.App, st.text, "", 5000+g.rng.Float64()*25000)
	}
	for _, at := range g.deadlockTimes(prev, t) {
		p1, p2 := 2000+int(noise(s.Name+"d1", at)*60000), 2000+int(noise(s.Name+"d2", at)*60000)
		ev("deadlock", at, p1, "app_"+s.App, g.stmts[stUpdate].text,
			fmt.Sprintf("Process %d waits for ShareLock on transaction %d; blocked by process %d. Process %d waits for ShareLock on transaction %d; blocked by process %d.",
				p1, 88000000+p1, p2, p2, 88000000+p2, p1), nil)
	}
	if s.ChainDDL {
		if in, ws := g.window(t, 14, 25*time.Minute); in {
			if at := ws.Add(3*time.Minute + time.Second); at.After(prev) && !at.After(t) {
				ev("lock_wait", at, 2000+int(uint64(hash64(fmt.Sprintf("%s|chainB|%d|ddl", s.Name, ws.Unix())))%60000), "deploy_bot", ddlText(s.App),
					"process still waiting for AccessExclusiveLock on relation 16702 of database 16384 after 1000.081 ms", 1000.081)
			}
		}
	}
	for _, hm := range [][2]int{{7, 12}, {19, 40}} {
		at := time.Date(t.Year(), t.Month(), t.Day(), hm[0], hm[1], 0, 0, time.UTC)
		if at.After(prev) && !at.After(t) {
			ev("auth_fail", at, 2000+int(noise(s.Name, at)*60000), "report_ro", "", `password authentication failed for user "report_ro"`, nil)
		}
	}
	out = append(out, Row{"kind": "cursor", "source": src, "read_to": t})
	return out
}

// ---------------------------------------------------------------- tables

// tableDefs is each application database's table list: the application's three main tables, then two
// small ones. base is the heap size in MB at load 1; the problem table of a Tables scenario is picked by name.
func (g *Gen) tableDefs() []struct {
	name string
	base float64
} {
	t := tables[g.Spec.App]
	return []struct {
		name string
		base float64
	}{{t[0], 900}, {t[1], 2400}, {t[2], 300}, {"audit_log", 160}, {"settings", 0.2}}
}

// tableRows is the hourly tables read: a 'db' row per application database and a 'table' row per table.
// Healthy tables are vacuumed and analyzed within hours, dead rows under 5 %, bloat under 10 %. The Tables
// scenario puts one table in the state its check looks for (the scenario's problem table is the second
// main table, the biggest):
//
//	bloat - 35 % of the pages not needed for the live rows (over 100 MB)   -> table bloat
//	dead  - 30 % of the rows dead                                            -> table dead rows
//	avoff - autovacuum_enabled = false                                       -> table autovacuum off
//	novac - loaded by DMS, analyzed, never vacuumed, nothing all-visible     -> table never vacuumed
//	skip  - the biggest table is skipped for a lock on odd hours after the first read (its row is kept)
func (g *Gen) tableRows(t time.Time, first bool) []Row {
	s := g.Spec
	var out []Row
	week := math.Max(0, t.Sub(g.start).Hours()/(24*7))
	for di, db := range s.DBs {
		dbid := dbOID(di)
		var bigPages, bigVisible, big, neverVac int64
		for ti, td := range g.tableDefs() {
			relid := 16500 + int64(di)*1000 + int64(ti)*7
			problem := ti == 1 && di == 0
			if problem && s.Tables == "skip" && !first && t.Hour()%2 == 1 {
				out = append(out, Row{"kind": "table_skipped", "dbid": dbid, "relid": relid})
				continue
			}
			heap := int64(td.base * 1e6 * math.Max(0.25, s.Load) * (1 + 0.04*week))
			pages := heap / 8192
			live := int64(float64(pages) * 60)
			dead := live / 40
			bloatPct := 4 + 4*noise(s.Name+td.name+"bloat", t.Truncate(24*time.Hour))
			vacAgo := time.Duration(2+hash64(s.Name+td.name)%9) * time.Hour
			lastVac := t.Add(-vacAgo).Truncate(time.Minute)
			lastAn := lastVac.Add(10 * time.Minute)
			visible := pages * 92 / 100
			avOff := false
			insSinceVac := live / 200
			if problem {
				switch s.Tables {
				case "bloat":
					bloatPct = 35
				case "dead":
					dead = live * 3 / 7 // 30 % of live + dead
				case "avoff":
					avOff = true
					lastVac = g.pmStart.Add(36 * time.Hour)
					dead = live / 8
				case "novac":
					visible, insSinceVac = 0, live
					lastAn = minDur(t, g.end.Add(-6*24*time.Hour+4*time.Hour).Truncate(time.Hour))
				}
			}
			bloatBytes := int64(float64(heap) * bloatPct / 100)
			row := Row{"kind": "table", "dbid": dbid, "relid": relid, "datname": db, "schema_name": "public", "table_name": td.name,
				"relkind": "r", "heap_bytes": heap, "toast_bytes": heap / 50, "index_bytes": heap * 2 / 5,
				"total_bytes": heap + heap/50 + heap*2/5, "relpages": pages, "reltuples": float64(live), "relallvisible": visible,
				"n_live_tup": live, "n_dead_tup": dead, "n_mod_since_analyze": live / 50, "n_ins_since_vacuum": insSinceVac,
				"last_vacuum": lastVac, "last_autovacuum": lastVac, "last_analyze": lastAn, "last_autoanalyze": lastAn,
				"vacuums": 40 + hash64(td.name)%50, "analyzes": 60 + hash64(td.name)%50, "seq_scan": 12 + hash64(s.Name+td.name)%400,
				"idx_scan": int64(1e5 * s.Load * (1 + week)), "autovacuum_off": avOff, "xid_age": 40e6 + hash64(s.Name+td.name)%90e6,
				"mxid_age": 1000 + hash64(td.name)%5000, "stats_readable": true, "stats_columns": 6 + ti,
				"est_pages": pages - bloatBytes/8192, "bloat_bytes": bloatBytes, "bloat_pct": math.Round(bloatPct*10) / 10}
			if s.Tables == "novac" && problem {
				row["last_vacuum"], row["last_autovacuum"], row["vacuums"] = nil, nil, 0
				row["schema_name"] = "erp"
				neverVac++
			}
			if pages >= 1000 {
				big++
				bigPages += pages
				bigVisible += visible
			}
			out = append(out, row)
		}
		bigNever := int64(0)
		if s.Tables == "novac" && di == 0 {
			bigNever = neverVac
		}
		out = append(out, Row{"kind": "db", "dbid": dbid, "datname": db, "stats_reset": nil, "user_tables": int64(len(g.tableDefs())),
			"never_vacuumed": neverVac, "never_analyzed": 0, "big_tables": big, "big_never_vacuumed": bigNever,
			"big_under_half_visible": bigNever, "big_pages": bigPages, "big_visible_pages": bigVisible})
	}
	return out
}

// ---------------------------------------------------------------- dms

// dmsLatency is the CDC latency at t: seconds, then climbing past the 300 s threshold for the last 3 h.
func (g *Gen) dmsLatency(t time.Time) float64 {
	v := 2 + 6*noise(g.Spec.Name+"lat", t)
	if ramp := t.Sub(g.end.Add(-3 * time.Hour)).Seconds(); ramp > 0 {
		v += math.Min(ramp, 3*3600) * 0.1 // holds at the anchor's ~1,080 s while 'demo -serve' runs on
	}
	return v
}

func (g *Gen) dmsRows(t time.Time) []Row {
	s := g.Spec
	arn := func(kind, id string) string {
		return fmt.Sprintf("arn:aws:dms:us-east-1:123456789012:%s:DEMO%X", kind, hash64(s.Name+id)&0xffffffffff)
	}
	ri := arn("rep", "ri")
	c := curve(t)
	out := []Row{{"kind": "ri", "ri_arn": ri, "ri_id": s.Name + "-ri", "status": "available", "class": "dms.r6i.large",
		"engine_version": "3.5.4", "allocated_gb": 200, "multi_az": false, "public": false, "az": "us-east-1a", "created": g.pmStart,
		"free_until": nil, "pending": nil, "cpu_pct": 12 + 35*c + 5*noise(s.Name+"cpu", t), "freeable_bytes": int64(5.5e9 - 1.5e9*c),
		"free_storage_bytes": int64(150e9), "swap_bytes": 0}}

	cdcStart := g.end.Add(-6 * 24 * time.Hour).Truncate(time.Hour)
	flFinish := cdcStart.Add(3 * time.Hour)
	errFrom := g.end.Add(-2 * 24 * time.Hour)
	tasks := []struct {
		id, typ      string
		start, flEnd time.Time
		tables       []string
		stopped      bool
	}{
		{"erp-to-aurora-cdc", "full-load-and-cdc", cdcStart, flFinish,
			[]string{"items", "order_lines", "customers", "suppliers", "gl_postings", "attachments", "price_lists", "warehouses", "shipments", "invoices", "payments", "audit_trail"}, false},
		{"erp-history-archive", "full-load", g.end.Add(-5 * 24 * time.Hour).Truncate(time.Hour), g.end.Add(-5*24*time.Hour + 2*time.Hour).Truncate(time.Hour),
			[]string{"order_lines_2019", "order_lines_2020", "order_lines_2021"}, true},
	}
	for _, tk := range tasks {
		if t.Before(tk.start) {
			continue
		}
		ta := arn("task", tk.id)
		row := Row{"kind": "task", "task_arn": ta, "task_id": tk.id, "ri_arn": ri, "migration_type": tk.typ,
			"created": tk.start.Add(-time.Hour), "started": tk.start, "fresh_start": tk.start, "start_date": tk.start,
			"full_load_start": tk.start, "source_endpoint_arn": arn("endpoint", "src"), "target_endpoint_arn": arn("endpoint", "tgt"),
			"latency_warn_secs": 300, "tables_partial": false, "tables_queued": 0}
		loaded := len(tk.tables)
		progress := 100
		if t.Before(tk.flEnd) {
			frac := t.Sub(tk.start).Seconds() / tk.flEnd.Sub(tk.start).Seconds()
			progress = int(frac * 100)
			loaded = int(frac * float64(len(tk.tables)))
			row["status"], row["tables_loading"] = "running", 1
		} else {
			row["full_load_finish"] = tk.flEnd
			row["tables_loading"] = 0
			if tk.stopped {
				row["status"], row["stop_reason"], row["stop_date"] = "stopped", "Stop Reason FULL_LOAD_ONLY_FINISHED", tk.flEnd
			} else {
				row["status"] = "running"
			}
		}
		row["progress_pct"], row["tables_loaded"] = progress, loaded
		row["elapsed_ms"] = int64(minDur(t, tk.flEnd).Sub(tk.start) / time.Millisecond)
		errored := 0
		if !tk.stopped && !t.Before(errFrom) {
			errored = 2
		}
		row["tables_errored"] = errored
		if !tk.stopped {
			lat := g.dmsLatency(t)
			row["latency_source_s"], row["latency_target_s"] = lat*0.35, lat
			row["incoming_changes"] = 400 * s.Load * (0.2 + c) * (1 + lat/60)
			row["latency_at"] = t
			// the drain readout: the apply keeps ahead of the read, except in the ramp's first two hours and a
			// quarter (falling behind, changes spilled to disk on the target); from 45 minutes before the
			// anchor it outruns the read again, so the ETA shows while the spill drains
			in := 50 * s.Load * (0.2 + c)
			out := in * 1.15
			spill := 0.0
			if ramp := g.end.Add(-3 * time.Hour); !t.Before(ramp) {
				spill = row["incoming_changes"].(float64) * 0.3
				if t.Before(g.end.Add(-45 * time.Minute)) {
					out = in * 0.7
				} else {
					out = in * 1.6
				}
			}
			row["rows_in_s"], row["rows_out_s"], row["disk_source"], row["disk_target"] = in, out, 0.0, spill
			row["cdc_start_position"] = fmt.Sprintf("%X/%08X", 0x2A, hash64(tk.id)&0xffffffff)
			row["recovery_checkpoint"] = fmt.Sprintf("checkpoint:V1#%d#%X/%08X#0#0#*#0#%d", 4100+t.Unix()%900, 0x2B, t.Unix()&0xffffff, t.Unix()/60)
		}
		out = append(out, row)
		for i, tb := range tk.tables {
			if i >= loaded && progress < 100 {
				break
			}
			hours := math.Max(0, t.Sub(tk.flEnd).Hours())
			ins := int64(hours * 3600 * 0.4 * float64(12-i) * s.Load)
			st := Row{"kind": "table", "task_arn": ta, "schema_name": "erp", "table_name": tb, "table_state": "Table completed",
				"inserts": ins, "updates": ins / 2, "deletes": ins / 20, "ddls": 0, "applied_inserts": ins, "applied_updates": ins / 2,
				"applied_deletes": ins / 20, "applied_ddls": 0, "full_load_rows": int64(250000 * (12 - i%12)), "full_load_error_rows": 0,
				"full_load_cond_failed_rows": 0, "full_load_reloaded": false, "full_load_start": tk.start,
				"full_load_end": tk.flEnd.Add(-time.Duration(len(tk.tables)-i) * 5 * time.Minute), "last_update": t,
				"validation_state": "Validated", "validation_pending": 0, "validation_failed": 0, "validation_suspended": 0, "validation_detail": nil}
			if tk.stopped {
				st["inserts"], st["updates"], st["deletes"], st["applied_inserts"], st["applied_updates"], st["applied_deletes"] = 0, 0, 0, 0, 0, 0
				st["last_update"] = tk.flEnd
			}
			if errored > 0 && (tb == "gl_postings" || tb == "attachments") {
				st["table_state"] = "Table error"
				st["validation_state"] = "Error"
				if tb == "attachments" {
					st["full_load_error_rows"] = 14
					st["validation_detail"] = "LOB column body exceeds the task's max LOB size (32 KB): rows truncated"
				}
			}
			if !tk.stopped && tb == "price_lists" && !t.Before(g.end.Add(-24*time.Hour)) {
				st["validation_state"], st["validation_failed"] = "Mismatched records", 37
				st["validation_detail"] = "37 record(s) differ between source and target"
			}
			out = append(out, st)
		}
	}
	return out
}

// chance is 1 with probability p (a draw u in [0,1)), else 0: an event whose odds scale with the step,
// so the one-minute steps of the last hour do not fire it five times as often as the 5-minute ones.
func chance(u, p float64) float64 {
	if u < p {
		return 1
	}
	return 0
}

func minDur(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}
