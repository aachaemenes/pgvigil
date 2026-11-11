package demo

import (
	"math"
	"time"
)

// The demo's mssql_cpu, mssql_memory, mssql_fileio and mssql_tempdb payloads (0074), each a function of t alone
// like mssqlWaitsRows: the cumulative counters grow with the load minutes since the server started, so the imports'
// differences carry the day's curve.
//
//	-sql01  16 CPUs, busy in the afternoon (SQL Server near 70 % at the peak), queries waiting for memory grants a
//	        few minutes in every seven, tempdb with 4 data files (Microsoft's starting point on 16 CPUs is 8: the
//	        finding), the sales log on a slow volume in the afternoon.
//	-sql02  the quiet secondary: tempdb with 8 even files.
//	-sql03  the managed instance, 8 CPUs: tempdb's 2 data files of different sizes (the finding).

// mssqlLoadMin is the load minutes since the server started at t (mssqlWaitsRows' rule).
func (g *Gen) mssqlLoadMin(t time.Time) float64 {
	var m float64
	h := g.mssqlStart().Truncate(time.Hour)
	for ; h.Add(time.Hour).Before(t); h = h.Add(time.Hour) {
		m += 60 * (0.4 + 0.6*curve(h))
	}
	m += t.Sub(h).Minutes() * (0.4 + 0.6*curve(h))
	return m * g.Spec.Load
}

func (g *Gen) mssqlCPUs() int {
	if g.is("-sql03") {
		return 8
	}
	return 16
}

func (g *Gen) mssqlPerfState(t time.Time) Row {
	return Row{"kind": "state", "server_utc": t, "server_start": g.mssqlStart()}
}

// mssqlCPUDemoRows: the ring buffer's records of the ten minutes up to t (the import stores each once), the
// schedulers and the throughput counters.
func (g *Gen) mssqlCPUDemoRows(t time.Time) []Row {
	name := g.Spec.Name
	busy := 0.55 // sql01's share of the machine at the peak of the curve
	switch {
	case g.is("-sql02"):
		busy = 0.12
	case g.is("-sql03"):
		busy = 0.35
	}
	start := g.mssqlStart()
	out := []Row{g.mssqlPerfState(t)}
	for m := t.Truncate(time.Minute).Add(-9 * time.Minute); !m.After(t); m = m.Add(time.Minute) {
		if m.Before(start) {
			continue
		}
		sqlPct := math.Round(100 * busy * (0.25 + 0.75*curve(m)) * (0.85 + 0.3*noise(name+"cpu", m)))
		other := math.Round(3 + 6*noise(name+"cpuo", m))
		if sqlPct+other > 100 {
			sqlPct = 100 - other
		}
		out = append(out, Row{"kind": "cpu", "record_id": int64(m.Sub(start).Minutes()) + 1, "sample_at": m.UTC().Format(time.RFC3339),
			"sql_pct": int64(sqlPct), "idle_pct": int64(100 - sqlPct - other), "other_pct": int64(other)})
	}
	cpus := g.mssqlCPUs()
	runnable := int64(math.Round(float64(cpus) * busy * curve(t) * 0.6 * noise(name+"rq", t)))
	out = append(out, Row{"kind": "sched", "schedulers": cpus, "cpu_count": cpus, "runnable_tasks": runnable, "work_queue": 0,
		"pending_io": int64(2 * noise(name+"pio", t)), "current_workers": 60 + int64(40*curve(t)*busy*2), "active_workers": 20 + int64(30*curve(t)*busy*2),
		"max_workers": 512 + 16*(cpus-4)})
	lm := g.mssqlLoadMin(t)
	counter := func(c string, perLoadMin float64) Row {
		return Row{"kind": "counter", "counter": c, "value": int64(lm * perLoadMin)}
	}
	return append(out, counter("Batch Requests/sec", 60*900*busy), counter("SQL Compilations/sec", 60*70*busy),
		counter("SQL Re-Compilations/sec", 60*6*busy), counter("Transactions/sec", 60*1400*busy))
}

// mssqlMemoryDemoRows: the machine and the server's memory, the clerks and the grants at t.
func (g *Gen) mssqlMemoryDemoRows(t time.Time) []Row {
	name := g.Spec.Name
	physKB, targetKB := int64(128<<20), int64(110000*1024)
	if g.is("-sql03") {
		physKB, targetKB = 40<<20, 32<<20
	}
	c := curve(t)
	planKB := targetKB / 20
	stolenKB := targetKB/10 + int64(float64(targetKB/20)*c)
	bpKB := targetKB - stolenKB - planKB
	ple := int64(4000 + 20000*(1-c)*(0.8+0.4*noise(name+"ple", t)))
	waiting, granted := int64(0), int64(2+10*c)
	maxGrant := int64(200<<10) + int64(float64(1<<20)*c)
	if g.is("-sql01") && t.Minute()%7 < 2 && c > 0.5 {
		waiting, maxGrant = 3, 6<<20 // a report's sort asks for 6 GB; three queries wait behind it
	}
	if g.is("-sql02") {
		granted, maxGrant = 1, 64<<10
	}
	out := []Row{
		{"kind": "memory", "physical_kb": physKB, "available_kb": physKB - targetKB - 6<<20 + int64(float64(1<<20)*noise(name+"av", t)),
			"system_state": "Available physical memory is high", "process_kb": targetKB + 1<<20, "process_low": 0,
			"committed_kb": targetKB, "committed_target_kb": targetKB, "memory_model": "LOCK_PAGES"},
		{"kind": "counter", "counter": "Target Server Memory (KB)", "value": targetKB},
		{"kind": "counter", "counter": "Total Server Memory (KB)", "value": targetKB},
		{"kind": "counter", "counter": "Stolen Server Memory (KB)", "value": stolenKB},
		{"kind": "counter", "counter": "Database Cache Memory (KB)", "value": bpKB},
		{"kind": "counter", "counter": "Memory Grants Pending", "value": waiting},
		{"kind": "counter", "counter": "Memory Grants Outstanding", "value": granted},
		{"kind": "counter", "counter": "Page life expectancy", "value": ple},
		{"kind": "grants", "sem_granted": granted, "sem_waiting": waiting, "sem_granted_kb": maxGrant + granted*(64<<10),
			"sem_target_kb": targetKB / 4, "grants": granted + waiting, "grants_waiting": waiting, "max_grant_kb": maxGrant,
			"sum_grant_kb": maxGrant + granted*(64<<10), "max_requested_kb": maxGrant},
	}
	clerks := []struct {
		t     string
		share float64
	}{
		{"MEMORYCLERK_SQLBUFFERPOOL", 0}, {"CACHESTORE_SQLCP", 0.6}, {"CACHESTORE_OBJCP", 0.3}, {"CACHESTORE_PHDR", 0.1},
		{"MEMORYCLERK_SQLQERESERVATIONS", -1}, {"MEMORYCLERK_SOSNODE", 0.01}, {"MEMORYCLERK_SQLSTORENG", 0.006},
		{"USERSTORE_TOKENPERM", 0.004}, {"MEMORYCLERK_SQLGENERAL", 0.003}, {"OBJECTSTORE_LOCK_MANAGER", 0.002},
		{"MEMORYCLERK_XE", 0.001}, {"CACHESTORE_SYSTEMROWSET", 0.001},
	}
	var total int64
	for _, k := range clerks {
		var kb int64
		switch {
		case k.share == 0:
			kb = bpKB
		case k.share < 0:
			kb = maxGrant + granted*(64<<10)
		case k.t == "CACHESTORE_SQLCP" || k.t == "CACHESTORE_OBJCP" || k.t == "CACHESTORE_PHDR":
			kb = int64(float64(planKB) * k.share)
		default:
			kb = int64(float64(targetKB) * k.share * (0.9 + 0.2*noise(name+k.t, t)))
		}
		total += kb
		out = append(out, Row{"kind": "clerk", "clerk_type": k.t, "pages_kb": kb, "vm_committed_kb": 0})
	}
	return append(out, Row{"kind": "clerks", "clerks_kb": total + total/50, "plan_cache_kb": planKB})
}

// mssqlFileIODemoRows: the cumulative virtual file stats of each instance's files at t. A file's latency is fixed
// per file except sql01's sales log, which slows in the afternoon.
func (g *Gen) mssqlFileIODemoRows(t time.Time) []Row {
	type file struct {
		db             string
		dbID, fileID   int
		name, typ      string
		reads, writes  float64 // per load minute
		readMS, wrMS   float64 // per operation
		readKB, writKB float64 // per operation
	}
	files := []file{
		{"master", 1, 1, "master", "ROWS", 2, 1, 4, 3, 64, 8},
		{"master", 1, 2, "mastlog", "LOG", 0.1, 2, 2, 1, 60, 4},
		{"tempdb", 2, 1, "tempdev", "ROWS", 120, 300, 1.5, 2.5, 64, 64},
		{"tempdb", 2, 2, "templog", "LOG", 1, 220, 1, 0.8, 60, 30},
		{"sales", 5, 1, "sales", "ROWS", 900, 400, 6, 4, 64, 8},
		{"sales", 5, 2, "sales_log", "LOG", 2, 1500, 1, 2, 60, 12},
	}
	if g.is("-sql02") {
		for i := range files {
			files[i].reads, files[i].writes = files[i].reads/8, files[i].writes/2
		}
	}
	lm := g.mssqlLoadMin(t)
	out := []Row{g.mssqlPerfState(t)}
	for _, f := range files {
		// the log's stall grows in the afternoon (its volume is shared with the reports' extracts)
		wr := f.wrMS
		if g.is("-sql01") && f.name == "sales_log" {
			wr += 18 * curve(t) * curve(t)
		}
		reads, writes := int64(lm*f.reads), int64(lm*f.writes)
		dir := "/var/opt/mssql/data/"
		out = append(out, Row{"kind": "file", "database_id": f.dbID, "database_name": f.db, "file_id": f.fileID, "file_name": f.name,
			"type_desc": f.typ, "physical_name": dir + f.name + map[string]string{"ROWS": ".mdf", "LOG": ".ldf"}[f.typ],
			"reads": reads, "read_bytes": int64(float64(reads) * f.readKB * 1024), "read_stall_ms": int64(float64(reads) * f.readMS),
			"writes": writes, "write_bytes": int64(float64(writes) * f.writKB * 1024), "write_stall_ms": int64(float64(writes) * wr)})
	}
	return out
}

// mssqlTempdbDemoRows: tempdb's layout (hourly).
func (g *Gen) mssqlTempdbDemoRows() []Row {
	cpus := g.mssqlCPUs()
	n, sizes := 4, []int64{8 << 30, 8 << 30, 8 << 30, 8 << 30}
	major, mi := 16, false
	switch {
	case g.is("-sql02"):
		n, sizes = 8, []int64{4 << 30, 4 << 30, 4 << 30, 4 << 30, 4 << 30, 4 << 30, 4 << 30, 4 << 30}
	case g.is("-sql03"):
		n, sizes, major, mi = 2, []int64{16 << 30, 6 << 30}, 12, true
	}
	server := Row{"kind": "server", "cpu_count": cpus, "major": major, "tf1117": 0, "tf1118": 0, "flags_required": 0, "memopt_metadata": 0}
	if mi {
		server["memopt_metadata"] = nil
	}
	out := []Row{server}
	dir := "/var/opt/mssql/tempdb/"
	if mi {
		dir = "D:\\tempdb\\"
	}
	for i := 0; i < n; i++ {
		name := "tempdev"
		if i > 0 {
			name = "temp" + string(rune('1'+i))
		}
		out = append(out, Row{"kind": "file", "file_id": map[bool]int{true: 1, false: i + 2}[i == 0], "file_name": name, "type_desc": "ROWS",
			"physical_name": dir + name + ".ndf", "size_bytes": sizes[i], "max_size_bytes": nil, "growth_bytes": int64(512 << 20), "growth_pct": 0, "volume": dir})
	}
	return append(out, Row{"kind": "file", "file_id": 2, "file_name": "templog", "type_desc": "LOG", "physical_name": dir + "templog.ldf",
		"size_bytes": int64(4 << 30), "max_size_bytes": nil, "growth_bytes": int64(1 << 30), "growth_pct": 0, "volume": dir})
}
