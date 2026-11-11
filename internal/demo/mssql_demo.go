package demo

import (
	"encoding/json"
	"math/rand/v2"
	"strconv"
	"strings"
	"time"
)

// The demo's three SQL Server instances. Each runs only the mssql_ collections, handed to the repository through
// their import functions as the collector hands them:
//
//	-sql01  the busy primary of the availability group ag_sales: a parallel report, a blocking chain with a sleeping
//	        head every third hour and at the anchor, deadlocks, blocked-process reports, slow completions, attentions
//	        and a failover in AlwaysOn_health, a redo queue that grows on the secondary, a failed Agent job, a database
//	        without a log backup, a volume under 10 % free and a version store one session holds.
//	-sql02  its secondary: quiet.
//	-sql03  a managed instance without some sources: no slow-queries session, no host volumes, no availability
//	        group, sp_WhoIsActive as the running-queries source.

// mssqlStep is Step for a SQL Server instance: the batches of one snapshot time.
func (g *Gen) mssqlStep(t time.Time) []Batch {
	first := g.prev.IsZero()
	var out []Batch
	add := func(c string, at time.Time, rows []Row) {
		if len(rows) > 0 {
			out = append(out, Batch{Collection: c, At: at, Rows: rows})
		}
	}
	name := g.Spec.Name
	if first || (t.Minute() == 0 && t.Hour()%6 == 0) || t.Equal(g.end) {
		add("mssql_instance", t, g.mssqlInstanceRows(t))
	}
	if first || t.Minute()%5 == 0 || t.Equal(g.end) {
		add("mssql_services", t, g.mssqlServicesRows(t))
	}
	add("mssql_requests", t, g.mssqlRequestsRows(t))
	add("mssql_waits", t, g.mssqlWaitsRows(t))
	add("mssql_ag", t, g.mssqlAgDemoRows(t))
	add("mssql_cpu", t, g.mssqlCPUDemoRows(t))
	add("mssql_memory", t, g.mssqlMemoryDemoRows(t))
	add("mssql_fileio", t, g.mssqlFileIODemoRows(t))
	if first || t.Minute() == 0 || t.Equal(g.end) {
		add("mssql_tempdb", t, g.mssqlTempdbDemoRows())
		add("mssql_querystore", t, g.mssqlQueryStoreDemoRows(t))
	}
	if first || t.Minute()%5 == 0 {
		add("mssql_jobs", t, g.mssqlJobsDemoRows(t))
	}
	if first || t.Minute() == 0 {
		add("mssql_backups", t, g.mssqlBackupsDemoRows(t))
	}
	// the files and volumes: a read a day for the year before the seed's history (the Storage tab's 30 to 365 day
	// windows), then hourly
	if first {
		for at := g.end.Add(-365 * 24 * time.Hour); at.Before(t); at = at.Add(24 * time.Hour) {
			add("mssql_storage", at, g.mssqlStorageRows(at))
		}
	}
	if first || t.Minute() == 0 || t.Equal(g.end) {
		add("mssql_storage", t, g.mssqlStorageRows(t))
	}
	if !t.Before(g.end.Add(-3 * time.Hour)) { // the rates are differences between two reads: the last three hours, in order
		add("mssql_versionstore", t, mssqlVersionStoreRows(name, t, g.end))
	}
	if t.Equal(g.end.Add(-time.Minute)) || !t.Before(g.end) {
		add("mssql_xe", t, g.mssqlXEDemoRows(t))
	}
	g.prev = t
	return out
}

// mssqlXEPeriod is how often a live tick carries new events.
const mssqlXEPeriod = 20 * time.Minute

// mssqlXEDemoRows is the mssql_xe payload at t. The day's events go in twice a minute apart at the seed's end (an
// event is stored once; a capture's state must be seen twice before its finding fires). A live tick after the
// anchor carries the capture states, and every twenty minutes the events of the twenty minutes before it: one
// deadlock, the blocked-process reports of the one head statement and the slow completions, so the findings that
// count the last hour stay on the page while the demo is served. The failover happened once: its finding is shown
// for an hour, as it would be.
func (g *Gen) mssqlXEDemoRows(t time.Time) []Row {
	name := g.Spec.Name
	live := t.After(g.end)
	asOf, fresh := g.end, false
	if live && t.Sub(g.end)%mssqlXEPeriod == 0 {
		asOf, fresh = t, true
	}
	rows := mssqlXERows(name, asOf, rand.New(rand.NewPCG(uint64(hash64(name)), 97)))
	keep := rows[:0:0]
	for _, r := range rows {
		kind, _ := r["kind"].(string)
		stmt, _ := r["statement"].(string)
		var at time.Time
		if v, ok := r["event_at"].(string); ok {
			at, _ = time.Parse(time.RFC3339Nano, v)
		}
		from := asOf.Add(-mssqlXEPeriod)
		switch {
		case kind == "state":
			keep = append(keep, r)
		// the secondary takes no writes: no deadlock and no blocked-process report there, and of the slow
		// completions only the report's SELECT
		case g.is("-sql02") && (kind == "deadlock" || kind == "blocked" || (kind == "slow" && !strings.HasPrefix(stmt, "SELECT"))):
		case !live:
			keep = append(keep, r)
		case !fresh:
		case kind == "blocked", kind == "slow" && at.After(from), kind == "deadlock" && at.Equal(from):
			keep = append(keep, r)
		}
	}
	if !g.is("-sql03") {
		return keep
	}
	// the managed instance's one application database is Ledger: the events name it, not the pair's Sales
	b, err := json.Marshal(keep)
	if err != nil {
		return keep
	}
	var renamed []Row
	if json.Unmarshal([]byte(strings.ReplaceAll(string(b), "Sales", "Ledger")), &renamed) != nil {
		return keep
	}
	return renamed
}

// mssqlFailoverAt is when the availability group's primary moved to DEMO-SQL01: 30 minutes before the anchor, the
// time of the role changes in AlwaysOn_health (mssql_xe_demo.go).
func (g *Gen) mssqlFailoverAt() time.Time { return g.end.Add(-30 * time.Minute) }

// mssqlStart is when the SQL Server last started: the instance's start, or an hour before the history where a long
// history (-days over 41) begins before it, so no counter is ever read before the server was up.
func (g *Gen) mssqlStart() time.Time {
	if !g.pmStart.Before(g.start) {
		return g.start.Add(-time.Hour)
	}
	return g.pmStart
}

// mssqlStorageRows is mssqlStorageRows of the instance. The managed instance shows no host volumes, and its files
// are blobs of the service's storage account, not paths of a machine.
func (g *Gen) mssqlStorageRows(t time.Time) []Row {
	rows := mssqlStorageRows(g.Spec.Name, t, g.end)
	if !g.is("-sql03") {
		return rows
	}
	out := rows[:0:0]
	for _, r := range rows {
		if r["kind"] == "volume" {
			continue
		}
		if p, ok := r["physical_name"].(string); ok {
			r["physical_name"] = "https://demomi03.blob.core.windows.net/data/" + p[strings.LastIndex(p, "/")+1:]
		}
		delete(r, "volume")
		out = append(out, r)
	}
	return out
}

// mssqlCollections names what a SQL Server instance's collector runs (for the collection log).
func (g *Gen) mssqlCollections() []string {
	c := []string{"mssql_instance", "mssql_services", "mssql_requests", "mssql_waits", "mssql_xe", "mssql_storage", "mssql_versionstore", "mssql_ag", "mssql_cpu", "mssql_memory", "mssql_fileio", "mssql_tempdb", "mssql_querystore"}
	if g.is("-sql01") || g.is("-sql02") {
		c = append(c, "mssql_backups")
	}
	if g.is("-sql01") {
		c = append(c, "mssql_jobs")
	}
	return c
}

// mssqlSkipNote is why a collection of a SQL Server instance is logged as skipped, "" when it ran.
func (g *Gen) mssqlSkipNote(collection string) string {
	if g.Spec.Engine == EngineSQLServer && collection == "mssql_ag" && g.is("-sql03") {
		return "Always On availability groups are not enabled on this instance"
	}
	return ""
}

// mssqlServicesRows is the mssql_services payload. -sql01: Agent running, Database Mail started, three dump
// files, the newest three days before the anchor (a warning). -sql02: Database Mail stopped (a warning). -sql03, the
// managed instance: no service list (the Agent judged by its sessions), no dump.
func (g *Gen) mssqlServicesRows(_ time.Time) []Row {
	svc := func(name, startup string, pid int) Row {
		return Row{"kind": "service", "service_name": name, "startup_type": startup, "status": "Running", "process_id": pid,
			"last_startup_at_utc": g.mssqlStart().UTC().Format(time.RFC3339), "service_account": `DEMO\svc-sql`, "is_clustered": "N", "ifi_enabled": nil}
	}
	mail := func(receiving int) Row {
		return Row{"kind": "dbmail", "xps_in_use": 1, "queues_seen": 1, "receive_enabled": receiving}
	}
	switch {
	case g.is("-sql03"):
		return []Row{{"kind": "agent", "sessions": 3, "engine_edition": 8}, mail(1), {"kind": "dumps", "dump_count": 0, "last_dump_at_utc": nil}}
	case g.is("-sql02"):
		return []Row{{"kind": "agent", "sessions": 4, "engine_edition": 3}, svc("SQL Server (MSSQLSERVER)", "Automatic", 4212),
			svc("SQL Server Agent (MSSQLSERVER)", "Automatic", 5120), mail(0), {"kind": "dumps", "dump_count": 0, "last_dump_at_utc": nil}}
	}
	engine := svc("SQL Server (MSSQLSERVER)", "Automatic", 3980)
	engine["ifi_enabled"] = "Y"
	return []Row{{"kind": "agent", "sessions": 4, "engine_edition": 3}, engine, svc("SQL Server Agent (MSSQLSERVER)", "Automatic", 4876),
		svc("SQL Full-text Filter Daemon Launcher (MSSQLSERVER)", "Manual", 6012), mail(1),
		{"kind": "dumps", "dump_count": 3, "last_dump_at_utc": g.end.Add(-72 * time.Hour).UTC().Format(time.RFC3339)}}
}

// mssqlInstanceRows is the mssql_instance payload: the server's description, a few configuration values and what
// sys.dm_os_sys_info says of the machine.
func (g *Gen) mssqlInstanceRows(t time.Time) []Row {
	type srv struct {
		machine, edition, version, level, update, ref, vm string
		engineEdition, hadr, cpus                         int
		memKB, maxMemMB                                   int64
	}
	s := srv{"DEMO-SQL01", "Enterprise Edition (64-bit)", "16.0.4165.4", "RTM", "CU16", "KB5048033", "HYPERVISOR", 3, 1, 16, 128 << 20, 110000}
	switch {
	case g.is("-sql02"):
		s.machine = "DEMO-SQL02"
	case g.is("-sql03"):
		s = srv{"DEMO-MI03", "SQL Azure", "12.0.2000.8", "RTM", "", "", "HYPERVISOR", 8, 0, 8, 40 << 20, 2147483647}
	}
	rows := []Row{{"kind": "server", "machine_name": s.machine, "server_name": s.machine, "instance_name": nil, "edition": s.edition,
		"engine_edition": s.engineEdition, "product_version": s.version, "product_level": s.level, "product_update_level": nullIf(s.update),
		"product_update_reference": nullIf(s.ref), "collation": "SQL_Latin1_General_CP1_CI_AS", "is_clustered": 0, "is_hadr_enabled": s.hadr,
		"is_integrated_security_only": 0}}
	cfg := func(name string, value, minimum, maximum int64, dynamic, advanced int) Row {
		return Row{"kind": "config", "name": name, "value": value, "value_in_use": value, "minimum": minimum, "maximum": maximum,
			"is_dynamic": dynamic, "is_advanced": advanced}
	}
	// -sql01: max degree of parallelism was the default 0 until a day before the anchor (a change the tab shows)
	maxdop := int64(8)
	if g.is("-sql01") && t.Before(g.end.Add(-24*time.Hour)) {
		maxdop = 0
	}
	rows = append(rows,
		cfg("max server memory (MB)", s.maxMemMB, 128, 2147483647, 1, 1),
		cfg("min server memory (MB)", 0, 0, 2147483647, 1, 1),
		cfg("max degree of parallelism", maxdop, 0, 32767, 1, 1),
		cfg("cost threshold for parallelism", 50, 0, 32767, 1, 1),
		cfg("optimize for ad hoc workloads", 1, 0, 1, 1, 1),
		cfg("blocked process threshold (s)", 15, 0, 86400, 1, 1),
		cfg("backup compression default", 1, 0, 1, 1, 0),
		cfg("remote admin connections", 1, 0, 1, 1, 0),
		cfg("xp_cmdshell", 0, 0, 1, 1, 1),
		cfg("clr enabled", 0, 0, 1, 1, 0))
	// -sql02: a larger max server memory was set and RECONFIGURE not run: set, not in use yet
	if g.is("-sql02") {
		rows[1]["value"] = s.maxMemMB + 10000
	}
	return append(rows, Row{"kind": "sysinfo", "cpu_count": s.cpus, "hyperthread_ratio": 2, "physical_memory_kb": s.memKB,
		"committed_target_kb": s.memKB * 8 / 10, "max_workers_count": 512 + 16*(s.cpus-4), "scheduler_count": s.cpus,
		"virtual_machine_type": s.vm, "started_at_utc": g.mssqlStart().UTC().Format(time.RFC3339)})
}

// The statements of the running-queries snapshots.
const (
	mssqlHeadBatch = "BEGIN TRAN; UPDATE dbo.Orders SET Status = 'HOLD' WHERE CustomerId = 4411"
	mssqlVictim1   = "UPDATE dbo.Orders SET ShippedAt = SYSUTCDATETIME() WHERE OrderId = @p0"
	mssqlVictim2   = "SELECT o.OrderId, o.Status FROM dbo.Orders o WHERE o.CustomerId = @p0 ORDER BY o.OrderId"
	mssqlReport    = "SELECT c.Region, SUM(l.Amount) FROM dbo.OrderLines l JOIN dbo.Orders o ON o.OrderId = l.OrderId JOIN dbo.Customers c ON c.CustomerId = o.CustomerId GROUP BY c.Region"
	mssqlLookup    = "SELECT TOP (50) EntryId, PostedAt, Amount FROM dbo.LedgerEntry WHERE AccountId = @p0 ORDER BY PostedAt DESC"

	mssqlHandleReport  = "0x0200000063A1F02E5D3C1B7A9E44C0D18B6F2A7711C3E5D9"
	mssqlHandleHead    = "0x0200000071B2E19F0A6D4C3B8E55D1C29A7F3B8822D4F6EA"
	mssqlHandleVictim1 = "0x0200000084C3F2A01B7E5D4C9F66E2D3AB804C9933E507FB"
	mssqlHandleVictim2 = "0x0200000092D4A3B12C8F6E5DA077F3E4BC915DAA44F618AC"
	mssqlHandleLookup  = "0x02000000A5E6B7C83D9F1A2B4C5D6E7F8091A2B3C4D5E6F7"
	mssqlPlanTail      = "0200000001000000000000000000000000000000000000000000000000000000"

	// the anchor's chain: it starts 12 minutes before the seed's end and, on the live ticks after it, lasts 22
	// minutes of every 30, so the walk-through always has a chain to open or a quiet minute to slide to
	mssqlChainLead   = 12 * time.Minute
	mssqlChainPeriod = 30 * time.Minute
	mssqlChainLength = 22 * time.Minute
)

// mssqlChain says whether sql01's blocking chain stands at t, and since when its first victim has waited: ten
// minutes from minute 20 of every third hour, and the anchor's chain.
func (g *Gen) mssqlChain(t time.Time) (bool, time.Time) {
	if since := t.Sub(g.end.Add(-mssqlChainLead)); since >= 0 {
		if in := since % mssqlChainPeriod; in < mssqlChainLength {
			return true, t.Add(-in - 15*time.Second)
		}
		return false, time.Time{}
	}
	// a chain of the history that would run into the anchor's is left out: one chain cannot restart its own wait
	if t.Hour()%3 == 0 && t.Minute() >= 20 && t.Minute() < 30 && mssqlHistoryChain(t.Truncate(time.Hour), g.end) {
		return true, t.Truncate(time.Hour).Add(20*time.Minute - 15*time.Second)
	}
	return false, time.Time{}
}

// mssqlHistoryChain says whether the hour (a multiple of three) has its ten-minute chain: every such hour whose
// chain is over five minutes before the anchor's begins.
func mssqlHistoryChain(hour, end time.Time) bool {
	return hour.Add(30 * time.Minute).Before(end.Add(-mssqlChainLead - 5*time.Minute))
}

// mssqlRequestsRows is the mssql_requests payload at t (0064): the request rows with their chain already on them,
// one text row per statement, one blocking row per head and the summary.
func (g *Gen) mssqlRequestsRows(t time.Time) []Row {
	text := func(handle string, start, end int, s string) Row {
		return Row{"kind": "text", "sql_handle": handle, "stmt_start": start, "stmt_end": end, "statement": s, "full_chars": len(s)}
	}
	base := func(session int, status, login, program, db string) Row {
		return Row{"kind": "request", "session_id": session, "status": status, "login_name": login, "host_name": "app-" + strconv.Itoa(1+session%3),
			"program_name": program, "database_name": db, "is_user_process": 1, "blocking_session_id": 0, "isolation_level": "read committed",
			"login_time": t.Add(-6 * time.Hour)}
	}
	set := func(r Row, kv map[string]any) Row {
		for k, v := range kv {
			r[k] = v
		}
		return r
	}
	ago := func(ms int64) time.Time { return t.Add(-time.Duration(ms) * time.Millisecond) }
	summary := Row{"kind": "summary", "server_utc": t, "source": "dmv",
		"source_note": "sp_WhoIsActive is not installed in master or in the connection's database", "memory_grants_pending": 0,
		"read_ms": 30 + int(20*noise(g.Spec.Name+"read", t))}

	switch {
	case g.is("-sql03"):
		summary["source"], summary["source_note"] = "sp_whoisactive", "sp_WhoIsActive in master, completed from the DMVs by session and request id"
		el := int64(400 + 2500*noise(g.Spec.Name+"el", t))
		return []Row{set(base(58, "running", "ledger_app", "LedgerApi", "Ledger"), map[string]any{"request_id": 0, "command": "SELECT",
			"cpu_ms": el / 2, "reads": 12, "writes": 0, "logical_reads": 1840, "dop": 1, "task_count": 1, "granted_memory_kb": 2048,
			"elapsed_ms": el, "start_time": ago(el), "open_tran": 0, "sql_handle": mssqlHandleLookup, "stmt_start": 0, "stmt_end": -1,
			"plan_handle": "0x06000500A5E6B7C8" + mssqlPlanTail, "stmt_query_hash": "0x7C12E9A04B63D5F8", "stmt_plan_hash": "0x2A94C7E1305B8D6F"}),
			text(mssqlHandleLookup, 0, -1, mssqlLookup), summary}
	case g.is("-sql02"):
		// the readable secondary: a report now and then, most minutes nothing
		if noise(g.Spec.Name+"rep", t) < 0.6 {
			return []Row{summary}
		}
		el := int64(3000 + 9000*noise(g.Spec.Name+"el", t))
		return []Row{set(base(66, "running", "svc_reports", "ReportServer", "Sales"), map[string]any{"request_id": 0, "command": "SELECT",
			"cpu_ms": el * 7 / 10, "reads": 220, "writes": 0, "logical_reads": 48200, "dop": 1, "task_count": 1, "granted_memory_kb": 65536,
			"elapsed_ms": el, "start_time": ago(el), "open_tran": 0, "isolation_level": "snapshot", "sql_handle": mssqlHandleReport,
			"stmt_start": 0, "stmt_end": -1, "plan_handle": "0x0600050063A1F02E" + mssqlPlanTail, "stmt_query_hash": "0x8F3A11C27D90B4E6",
			"stmt_plan_hash": "0x1B77E0A9C3D25F48"}), text(mssqlHandleReport, 0, -1, mssqlReport), summary}
	}

	// sql01: the report is a parallel request, so the page marks the coordinator's counters and shows the task sums
	el := int64(20000 + 15000*curve(t))
	out := []Row{set(base(63, "running", "svc_reports", "ReportServer", "Sales"), map[string]any{"request_id": 0, "command": "SELECT",
		"wait_type": "CXCONSUMER", "wait_ms": 12, "cpu_ms": el / 9, "reads": 310, "writes": 0, "logical_reads": 3058, "dop": 8, "task_count": 17,
		"tasks_cpu_ms": el * 6, "tasks_physical_io": 229841, "granted_memory_kb": 786432, "tempdb_alloc_kb": 204800, "tempdb_current_kb": 180224,
		"elapsed_ms": el, "start_time": ago(el), "open_tran": 0, "transaction_id": 88120000 + t.Unix()%100000, "sql_handle": mssqlHandleReport,
		"stmt_start": 0, "stmt_end": -1, "plan_handle": "0x0600050063A1F02E" + mssqlPlanTail, "stmt_query_hash": "0x8F3A11C27D90B4E6",
		"stmt_plan_hash": "0x1B77E0A9C3D25F48", "session_waits": []Row{{"wait": "CXCONSUMER", "ms": 91000, "tasks": 420},
			{"wait": "PAGEIOLATCH_SH", "ms": 30500, "tasks": 3100}}}), text(mssqlHandleReport, 0, -1, mssqlReport)}
	if on, since := g.mssqlChain(t); on {
		waited := t.Sub(since).Milliseconds()
		w2 := max(waited-9000, 1000)
		tranStart := since.Add(-20 * time.Second)
		out = append(out,
			set(base(71, "sleeping", "svc_orders", "OrderEntry", "Sales"), map[string]any{"open_tran": 1, "transaction_id": 88054321, "tran_start": tranStart,
				"tran_log_bytes": 4096, "is_implicit_tran": 0, "last_request_start": tranStart, "last_request_end": tranStart.Add(time.Second),
				"cpu_ms": 16, "reads": 2, "writes": 1, "logical_reads": 44, "sql_handle": mssqlHandleHead, "stmt_start": -1, "stmt_end": -1,
				"head_session_id": 71, "chain_depth": 0, "victims": 2, "longest_victim_wait_ms": waited}),
			set(base(84, "suspended", "svc_orders", "OrderEntry", "Sales"), map[string]any{"request_id": 0, "command": "UPDATE", "wait_type": "LCK_M_U",
				"wait_ms": waited, "wait_resource": "KEY: 5:72057594043432960 (8194443284a0)", "blocking_session_id": 71, "open_tran": 1,
				"transaction_id": 88054400, "tran_start": ago(waited), "tran_log_bytes": 0, "elapsed_ms": waited, "start_time": ago(waited), "cpu_ms": 0,
				"reads": 0, "writes": 0, "logical_reads": 6, "dop": 1, "task_count": 1, "sql_handle": mssqlHandleVictim1, "stmt_start": 0, "stmt_end": -1,
				"plan_handle": "0x0600050084C3F2A0" + mssqlPlanTail, "stmt_query_hash": "0x2C61D04E9B37A8F1", "stmt_plan_hash": "0x77A2096CE41D3B50",
				"head_session_id": 71, "chain_depth": 1}),
			set(base(92, "suspended", "svc_web", "Storefront", "Sales"), map[string]any{"request_id": 0, "command": "SELECT", "wait_type": "LCK_M_S",
				"wait_ms": w2, "wait_resource": "KEY: 5:72057594043432960 (61a06abd401c)", "blocking_session_id": 84, "open_tran": 0, "elapsed_ms": w2,
				"start_time": ago(w2), "cpu_ms": 0, "reads": 0, "writes": 0, "logical_reads": 2, "dop": 1, "task_count": 1, "sql_handle": mssqlHandleVictim2,
				"stmt_start": 0, "stmt_end": -1, "plan_handle": "0x0600050092D4A3B1" + mssqlPlanTail, "stmt_query_hash": "0x5E90A73B1C48D2F6",
				"stmt_plan_hash": "0x3D15B8F27A609CE4", "head_session_id": 71, "chain_depth": 2}),
			text(mssqlHandleHead, -1, -1, mssqlHeadBatch), text(mssqlHandleVictim1, 0, -1, mssqlVictim1), text(mssqlHandleVictim2, 0, -1, mssqlVictim2),
			Row{"kind": "blocking", "head_session_id": 71, "victims": 2, "longest_wait_ms": waited})
	}
	return append(out, summary)
}

// mssqlWaitsRows is the mssql_waits payload at t (0064): the server's counters as they stand, cumulative since its
// start, so the import stores the differences. They are a function of t alone (no state between steps): the load
// minutes since the start times each wait's rate, and for the lock waits the chains that have ended by t (a lock
// wait is counted when it ends: the read after a chain breaks carries its whole wait).
func (g *Gen) mssqlWaitsRows(t time.Time) []Row {
	// load minutes since the server started: whole hours at the hour's load, then the minutes of the running hour
	var loadMin float64
	started := g.mssqlStart()
	h := started.Truncate(time.Hour)
	for ; h.Add(time.Hour).Before(t); h = h.Add(time.Hour) {
		loadMin += 60 * (0.4 + 0.6*curve(h))
	}
	loadMin += t.Sub(h).Minutes() * (0.4 + 0.6*curve(h))
	loadMin *= g.Spec.Load
	idleMin := t.Sub(started).Minutes()

	// sql01's chains that have ended by t: the ten-minute ones of the history (the first victim waited 615 s, the
	// second 606) and the anchor's 22-minute ones on the live ticks (1,335 s and 1,326 s)
	var short, long int64
	if g.is("-sql01") {
		for d := g.start.Truncate(3 * time.Hour); d.Before(t); d = d.Add(3 * time.Hour) {
			if e := d.Add(30 * time.Minute); !e.Before(g.start) && !e.After(t) && mssqlHistoryChain(d, g.end) {
				short++
			}
		}
		if since := t.Sub(g.end.Add(-mssqlChainLead)); since >= mssqlChainLength {
			long = 1 + int64((since-mssqlChainLength)/mssqlChainPeriod)
		}
	}
	type wait struct {
		name, category   string
		benign           bool
		tasks, ms, sigMS float64 // a load minute's (an idle minute's, for a benign wait)
	}
	waits := []wait{
		{"SOS_SCHEDULER_YIELD", "CPU", false, 5200, 2600, 2580},
		{"PAGEIOLATCH_SH", "Disk", false, 900, 7400, 60},
		{"WRITELOG", "Transaction log", false, 1400, 3900, 110},
		{"CXCONSUMER", "Parallelism", false, 300, 11000, 240},
		{"ASYNC_NETWORK_IO", "Query (client, spills, spools)", false, 650, 2100, 40},
		{"HADR_SYNC_COMMIT", "Availability group", false, 1300, 2900, 90},
		{"LAZYWRITER_SLEEP", "", true, 60, 60000, 5},
		{"SQLTRACE_INCREMENTAL_FLUSH_SLEEP", "", true, 15, 60000, 1},
		{"XE_TIMER_EVENT", "", true, 12, 60000, 1},
		{"HADR_WORK_QUEUE", "", true, 240, 240000, 30},
	}
	out := []Row{{"kind": "state", "server_utc": t, "server_start": started, "source": "sys.dm_os_wait_stats"}}
	for _, w := range waits {
		if g.is("-sql03") && (w.name == "HADR_SYNC_COMMIT" || w.name == "HADR_WORK_QUEUE") {
			continue
		}
		m := loadMin
		if w.benign {
			m = idleMin
		}
		r := Row{"kind": "wait", "wait_type": w.name, "waiting_tasks": int64(w.tasks * m), "wait_ms": int64(w.ms * m), "signal_ms": int64(w.sigMS * m),
			"max_wait_ms": int64(max(w.ms/10, 1000)), "is_benign": w.benign}
		if w.category != "" {
			r["category"] = w.category
		}
		out = append(out, r)
	}
	if n := short + long; n > 0 {
		longest := func(shortMS, longMS int64) int64 {
			if long > 0 {
				return longMS
			}
			return shortMS
		}
		out = append(out,
			Row{"kind": "wait", "wait_type": "LCK_M_U", "category": "Locking", "waiting_tasks": n, "wait_ms": short*615000 + long*1335000,
				"signal_ms": n, "max_wait_ms": longest(615000, 1335000), "is_benign": false},
			Row{"kind": "wait", "wait_type": "LCK_M_S", "category": "Locking", "waiting_tasks": n, "wait_ms": short*606000 + long*1326000,
				"signal_ms": n, "max_wait_ms": longest(606000, 1326000), "is_benign": false})
	}
	return out
}
