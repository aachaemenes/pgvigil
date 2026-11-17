package demo

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"time"
)

// The pages P25 added, with data on the demo (task 11b): a page that shows only its empty-state words on the demo
// reads as not working. Every row goes in through its import function as the collector hands it:
//
//	-azure-sqldb01 / -sqldb02  two Azure SQL Databases (ledger01, ledger02) on the logical server demo-sqlsrv01, each
//	        moved from Standard S0 into the Basic elastic pool pool-ledger during the week (sqldb02 five days before
//	        the anchor, sqldb01 30 hours: the Service Objectives grid's tier change), the pool's limits raised from 50
//	        to 100 eDTU and 5 to 10 GB three days before the anchor (Pool history, from master's 14 days); for the
//	        nodes' tabs, what the collector reads on an Azure SQL Database: the requests (Running Queries), the
//	        database's own files (DB Space), a database-scoped session's slow completions (Slow Queries) and the
//	        function and trigger statistics (Object Execution: control audit row A8).
//	-sql01  its Sales database's scoped configuration (MAXDOP set from 0 to 4 30 hours before the anchor), the schema
//	        reads of Sales and Ledger with changes in the last day (the Snapshot Summary tab: DBA Dash's schema
//	        snapshots), and function and trigger statistics (the Object Execution grid, the Execution Stats strip). The
//	        collector sends the scoped configuration inside mssql_confcheck (0391, its join line): the demo hands it to
//	        its own import function.
//
// Demo data, like every other demo row: the names, the figures and the governance view's values are made up.

const (
	demoAzPlatform = "azuresqldb"
	demoAzServer   = "demo-sqlsrv01"
	demoAzPool     = "pool-ledger"
)

// azureDBCollections names what the collector runs on a pooled Azure SQL Database (for the collection log).
var azureDBCollections = []string{"mssql_instance", "mssql_azuredb_resources", "mssql_azuredb_governance", "mssql_pool", "mssql_pool_limits",
	"mssql_requests", "mssql_storage", "mssql_xe", "mssql_funcstats"}

// azureMovedAt is when the database moved into the pool.
func (g *Gen) azureMovedAt() time.Time {
	if g.is("-sqldb02") {
		return g.end.Add(-5 * 24 * time.Hour)
	}
	return g.end.Add(-30 * time.Hour)
}

// azurePoolRaisedAt is when the pool's limits went from 50 to 100 eDTU (and 5 to 10 GB).
func (g *Gen) azurePoolRaisedAt() time.Time { return g.end.Add(-3 * 24 * time.Hour) }

// azureDBStep is Step for an Azure SQL Database: the server row every six hours, the resources' minutes since the
// last step, the governance row every five minutes, and once in the pool the pool's minutes and, hourly, master's
// limits (mssql_pool_limits).
func (g *Gen) azureDBStep(t time.Time) []Batch {
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
		add("mssql_instance", azureInstanceRows())
	}
	add("mssql_azuredb_resources", g.azureMinuteRows(prev, t))
	if first || t.Minute()%5 == 0 || t.Equal(g.end) {
		add("mssql_azuredb_governance", g.azureGovRows(t))
	}
	if !t.Before(g.azureMovedAt()) {
		add("mssql_pool", g.azurePoolRows(prev, t))
		if first || t.Minute() == 0 || t.Equal(g.end) {
			add("mssql_pool_limits", g.azurePoolLimitRows(t))
		}
	}
	// the node tabs' sources (Running Queries, DB Space, Slow Queries), as the collector reads them on an Azure SQL
	// Database: its requests every snapshot, its own files hourly, the slow completions of a database-scoped session
	add("mssql_requests", g.azureRequestsRows(t))
	if first || t.Minute() == 0 || t.Equal(g.end) {
		add("mssql_storage", g.azureStorageRows(t))
	}
	if t.Equal(g.end.Add(-time.Minute)) || !t.Before(g.end) {
		add("mssql_xe", g.azureXERows(t))
	}
	if first || t.Minute()%5 == 0 || t.Equal(g.end) {
		add("mssql_funcstats", g.azureFuncStatRows(t))
	}
	g.prev = t
	return out
}

// azureDBName is the Azure SQL Database's own name (DB_NAME() on its connection): ledger01, ledger02.
func (g *Gen) azureDBName() string { return "ledger" + g.Spec.Name[len(g.Spec.Name)-2:] }

// azureRequestsRows is the mssql_requests payload of an Azure SQL Database at t (requestsPreAzureDBSQL: sp_WhoIsActive
// looked for in the database itself, not installed): the summary, and in about half the minutes the ledger's
// month-end posting running.
func (g *Gen) azureRequestsRows(t time.Time) []Row {
	name, db := g.Spec.Name, g.azureDBName()
	summary := Row{"kind": "summary", "server_utc": t, "source": "dmv",
		"source_note": "sp_WhoIsActive is not installed in master or in the connection's database", "memory_grants_pending": 0,
		"read_ms": 40 + int(30*noise(name+"read", t))}
	if noise(name+"post", t) < 0.5 {
		return []Row{summary}
	}
	el := int64(1500 + 6000*noise(name+"el", t))
	req := Row{"kind": "request", "session_id": 71, "status": "running", "login_name": "ledger_app", "host_name": "app-2",
		"program_name": "LedgerApi", "database_name": db, "is_user_process": 1, "blocking_session_id": 0, "isolation_level": "read committed",
		"login_time": t.Add(-4 * time.Hour), "request_id": 0, "command": "UPDATE", "wait_type": "LOG_RATE_GOVERNOR", "wait_ms": 40,
		"cpu_ms": el / 3, "reads": 18, "writes": 240, "logical_reads": 9200, "dop": 1, "task_count": 1, "granted_memory_kb": 1024,
		"elapsed_ms": el, "start_time": t.Add(-time.Duration(el) * time.Millisecond), "open_tran": 1, "sql_handle": azHandlePost,
		"stmt_start": 0, "stmt_end": -1, "plan_handle": "0x0600050088C2D41E" + mssqlPlanTail, "stmt_query_hash": "0x4E21B7C09A3F6D15",
		"stmt_plan_hash": "0x6B90E3A2D1C47F08"}
	return []Row{req, {"kind": "text", "sql_handle": azHandlePost, "stmt_start": 0, "stmt_end": -1, "statement": azPost, "full_chars": len(azPost)}, summary}
}

// the posting statement the Azure databases' requests run (demo data)
const (
	azHandlePost = "0x02000000C4E1A97B3D5F20E86A1C0B4D9F7E2A3B5C6D7E8F0000000000000000000000000000000000000000"
	azPost       = "UPDATE dbo.LedgerBalance SET balance = balance + p.amount FROM dbo.LedgerBalance b JOIN dbo.Posting p ON p.account_id = b.account_id WHERE p.period = @period"
)

// azureStorageRows is the mssql_storage payload of an Azure SQL Database at t (azureDBFilesSQL: sys.database_files
// of its one database, no volume): the data file, its used space the governance row's user data figure, its maximum
// the database's (Standard S0 250 GB before the move into the pool, Basic pooled 2 GB after), and the log.
func (g *Gen) azureStorageRows(t time.Time) []Row {
	db := g.azureDBName()
	maxData := int64(250) << 30
	if !t.Before(g.azureMovedAt()) {
		maxData = int64(2) << 30
	}
	usedMB := int64(180 + int(t.Sub(g.end.Add(-7*24*time.Hour)).Hours()/12))
	file := func(id int, name, typ, path string, size, maxSize, used int64, fg any) Row {
		r := Row{"kind": "file", "database_id": 5, "database_name": db, "database_state": "ONLINE", "file_id": id, "file_name": name,
			"type_desc": typ, "physical_name": path, "state_desc": "ONLINE", "size_bytes": size, "max_size_bytes": maxSize,
			"growth_bytes": int64(16) << 20, "growth_pct": 0, "used_read": 1, "used_bytes": used}
		if fg != nil {
			r["filegroup"] = fg
		}
		return r
	}
	return []Row{file(1, "data_0", "ROWS", db+"_data_0.mdf", int64(512)<<20, maxData, usedMB<<20, "PRIMARY"),
		file(2, "log", "LOG", db+"_log.ldf", int64(64)<<20, int64(1)<<30, int64(6)<<20, nil)}
}

// azureFuncStatRows is the mssql_funcstats payload of an Azure SQL Database at t: -sql01's two functions and trigger
// in the database itself (the read is cut to the connection's database there: control audit row A8).
func (g *Gen) azureFuncStatRows(t time.Time) []Row {
	rows := g.mssqlFuncStatRows(t)
	for _, r := range rows {
		if r["kind"] != "state" {
			r["database_name"] = g.azureDBName()
		}
	}
	return rows
}

// azureXERows is the mssql_xe payload of an Azure SQL Database at t: the slow completions' capture (a
// database-scoped session: xeScopeWords) and its events, every one in the database itself; no blocked-process
// capture there (xe.go), and the demo keeps the deadlocks and attentions to the boxes.
func (g *Gen) azureXERows(t time.Time) []Row {
	db := g.azureDBName()
	var out []Row
	for _, r := range g.mssqlXEDemoRows(t) {
		switch {
		case r["kind"] == "state" && r["capture"] == "slow":
			out = append(out, r)
		case r["kind"] == "slow":
			r["database_name"] = db
			out = append(out, r)
		}
	}
	// every capture's state, as xe.go sends it (review t11-10 SHOULD 3): no session of the other three on this database
	for _, c := range []string{"deadlocks", "blocked", "attention"} {
		out = append(out, Row{"kind": "state", "capture": c, "state": "not installed", "source": "product"})
	}
	return out
}

// azureInstanceRows is the mssql_instance payload of an Azure SQL Database: @@SERVERNAME is the logical server's name.
func azureInstanceRows() []Row {
	return []Row{{"kind": "server", "machine_name": demoAzServer, "server_name": demoAzServer, "instance_name": nil, "edition": "SQL Azure",
		"engine_edition": 5, "product_version": "12.0.2000.8", "product_level": "RTM", "product_update_level": nil,
		"product_update_reference": nil, "collation": "SQL_Latin1_General_CP1_CI_AS", "is_clustered": 0, "is_hadr_enabled": 0,
		"is_integrated_security_only": 0}}
}

// azurePct is a percentage of the database's load at t: the day's curve, the instance's multiplier, a little noise.
func (g *Gen) azurePct(what string, t time.Time, scale float64) float64 {
	v := scale * g.Spec.Load * curve(t) * (0.75 + 0.5*noise(g.Spec.Name+what, t))
	return math.Round(math.Min(v, 99)*100) / 100
}

// buckets is a histogram of a minute's four 15-second rows: three at the average's tenth, one at the maximum's.
func buckets(avg, top float64) []int {
	b := make([]int, 10)
	at := func(v float64) int { return min(9, max(0, int(v/10))) }
	b[at(avg)] += 3
	b[at(top)]++
	return b
}

// azureMinuteRows is the mssql_azuredb_resources payload: a 'minute' row for each minute from prev up to t.
func (g *Gen) azureMinuteRows(prev, t time.Time) []Row {
	var rows []Row
	for m := prev.Truncate(time.Minute); m.Before(t); m = m.Add(time.Minute) {
		cpu, data, logw := g.azurePct("cpu", m, 55), g.azurePct("data", m, 30), g.azurePct("log", m, 20)
		top := func(v float64) float64 { return math.Min(100, math.Round(v*1.4*100)/100) }
		dtuLimit := 10 // Standard S0
		if !m.Before(g.azureMovedAt()) {
			dtuLimit = 5 // a Basic pool's per-database maximum
		}
		dtu := math.Max(cpu, math.Max(data, logw))
		rows = append(rows, Row{"kind": "minute", "minute": m.UTC().Format(time.RFC3339), "samples": 4,
			"avg_cpu_percent": cpu, "max_cpu_percent": top(cpu), "avg_data_io_percent": data, "max_data_io_percent": top(data),
			"avg_log_write_percent": logw, "max_log_write_percent": top(logw),
			"avg_memory_usage_percent": g.azurePct("mem", m, 40), "max_memory_usage_percent": top(g.azurePct("mem", m, 40)),
			"avg_xtp_storage_percent": 0, "max_xtp_storage_percent": 0,
			"max_worker_percent": g.azurePct("workers", m, 25), "max_session_percent": g.azurePct("sessions", m, 15),
			"avg_instance_cpu_percent": nil, "max_instance_cpu_percent": nil, "avg_instance_memory_percent": nil, "max_instance_memory_percent": nil,
			"dtu_limit": dtuLimit, "cpu_limit": nil, "replica_role": 0,
			"avg_dtu_percent": dtu, "max_dtu_percent": top(dtu), "avg_dtu": math.Round(dtu*float64(dtuLimit)) / 100,
			"max_dtu":     math.Round(top(dtu)*float64(dtuLimit)) / 100,
			"dtu_buckets": buckets(dtu, top(dtu)), "cpu_buckets": buckets(cpu, top(cpu)), "data_buckets": buckets(data, top(data)),
			"log_buckets": buckets(logw, top(logw))})
	}
	return rows
}

// azureGovRows is the mssql_azuredb_governance payload: Standard S0 before the move, a Basic pooled database after.
func (g *Gen) azureGovRows(t time.Time) []Row {
	edition, objective, slo, dtu, maxSize := "Standard", "S0", "SQLDB_S0", 10, int64(250)<<30
	var pool, from any
	if !t.Before(g.azureMovedAt()) {
		edition, objective, slo, dtu, maxSize = "Basic", "ElasticPool", "SQLDB_BASIC_POOL", 5, int64(2)<<30
		pool, from = demoAzPool, "service objectives"
	}
	gov := Row{"database_id": 5, "slo_name": slo, "server_name": demoAzServer, "dtu_limit": dtu, "cpu_limit": nil, "max_dop": 0,
		"max_sessions": 30000, "primary_group_max_workers": 60, "primary_max_log_rate": 2621440,
		"user_data_directory_space_usage_mb": 180 + int(t.Sub(g.end.Add(-7*24*time.Hour)).Hours()/12)}
	return []Row{{"kind": "governance", "gov": gov, "edition": edition, "service_objective": objective, "max_size_bytes": maxSize,
		"pool": pool, "pool_from": from, "pool_note": nil}}
}

// azurePoolLimits is the pool's DTU and storage limits at t.
func (g *Gen) azurePoolLimits(t time.Time) (dtu int, storageMB int64) {
	if t.Before(g.azurePoolRaisedAt()) {
		return 50, 5120
	}
	return 100, 10240
}

// azurePoolRows is the mssql_pool payload: the pool's minutes from prev up to t, the same from both its databases
// (keyed by the pool, so the second import of a minute stores nothing twice).
func (g *Gen) azurePoolRows(prev, t time.Time) []Row {
	var rows []Row
	key := demoAzServer + "/" + demoAzPool
	for m := prev.Truncate(time.Minute); m.Before(t); m = m.Add(time.Minute) {
		pct := func(what string, scale float64) float64 {
			return math.Round(math.Min(scale*curve(m)*(0.75+0.5*noise(key+what, m)), 99)*100) / 100
		}
		_, limit := g.azurePoolLimits(m)
		used := 1800 + 2*m.Sub(g.end.Add(-7*24*time.Hour)).Hours()
		cpu := pct("cpu", 45)
		rows = append(rows, Row{"server": demoAzServer, "pool": demoAzPool, "name_from": "service objectives", "minute": m.UTC().Format(time.RFC3339),
			"samples": 4, "avg_cpu_percent": cpu, "max_cpu_percent": math.Min(100, math.Round(cpu*1.3*100)/100),
			"avg_data_io_percent": pct("data", 25), "avg_log_write_percent": pct("log", 18), "avg_edtu_percent": math.Max(cpu, pct("data", 25)),
			// control audit A3 (0418): the minute's largest samples, said as demo data (each its average's 1.3 times, capped)
			"max_data_io_percent": math.Min(100, math.Round(pct("data", 25)*130)/100), "max_log_write_percent": math.Min(100, math.Round(pct("log", 18)*130)/100),
			"max_edtu_percent": math.Min(100, math.Round(math.Max(cpu, pct("data", 25))*130)/100),
			// control audit A5: the minute's four samples in the 10 % buckets (three at the average, one at the largest)
			"cpu_buckets": buckets(cpu, math.Min(100, cpu*1.3)), "data_buckets": buckets(pct("data", 25), math.Min(100, pct("data", 25)*1.3)),
			"log_buckets":        buckets(pct("log", 18), math.Min(100, pct("log", 18)*1.3)),
			"dtu_buckets":        buckets(math.Max(cpu, pct("data", 25)), math.Min(100, math.Max(cpu, pct("data", 25))*1.3)),
			"max_worker_percent": pct("workers", 20), "max_session_percent": pct("sessions", 10),
			"avg_instance_cpu_percent": nil, "avg_instance_memory_percent": nil, "instance_vcores": nil,
			"used_storage_mb": math.Round(used), "allocated_storage_mb": math.Round(used * 1.2), "storage_limit_mb": limit,
			"used_storage_percent": math.Round(used/float64(limit)*10000) / 100, "allocated_storage_percent": math.Round(used*1.2/float64(limit)*10000) / 100})
	}
	return rows
}

// azurePoolLimitRows is the mssql_pool_limits payload at t: master's 14 days as periods of equal limits and the read.
func (g *Gen) azurePoolLimitRows(t time.Time) []Row {
	from, raised := t.Add(-14*24*time.Hour), g.azurePoolRaisedAt()
	period := func(a, b time.Time) Row {
		dtu, storage := g.azurePoolLimits(a)
		return Row{"kind": "limit_period", "server": demoAzServer, "pool": demoAzPool, "valid_from": a.UTC().Format(time.RFC3339),
			"valid_to": b.UTC().Format(time.RFC3339), "dtu_limit": dtu, "storage_limit_mb": storage, "cpu_limit": nil}
	}
	var rows []Row
	if t.After(raised) && from.Before(raised) {
		rows = append(rows, period(from, raised), period(raised, t))
	} else {
		rows = append(rows, period(from, t))
	}
	return append(rows, Row{"kind": "limit_read", "server": demoAzServer, "pool": demoAzPool, "state": "read", "note": nil,
		"window_from": from.UTC().Format(time.RFC3339), "window_to": t.UTC().Format(time.RFC3339)})
}

// mssqlParityBatches are -sql01's rows for the database tabs P25 added: hourly the scoped configuration and the
// schema read, every five minutes the function and trigger statistics.
func (g *Gen) mssqlParityBatches(t time.Time, first bool) []Batch {
	if !g.is("-sql01") {
		return nil
	}
	var out []Batch
	if first || t.Minute() == 0 || t.Equal(g.end) {
		out = append(out, Batch{Collection: "mssql_db_scoped_config", At: t, Rows: g.mssqlScopedRows(t)})
		out = append(out, Batch{Collection: "mssql_schema", At: t, Rows: g.mssqlSchemaRows(t)})
	}
	if first || t.Minute()%5 == 0 || t.Equal(g.end) {
		out = append(out, Batch{Collection: "mssql_funcstats", At: t, Rows: g.mssqlFuncStatRows(t)})
		// the object page (OBJ): the procedures the plan cache's texts name, with their execution statistics
		out = append(out, Batch{Collection: "mssql_procstats", At: t, Rows: g.mssqlProcStatRows(t)})
		// the database page's Query Stats (the plan cache cut to Sales) and its Service Broker tab (P25 row 73)
		out = append(out, Batch{Collection: "mssql_plancache", At: t, Rows: g.mssqlPlanCacheRows(t)})
		out = append(out, Batch{Collection: "mssql_service_broker", At: t, Rows: g.mssqlBrokerRows(t)})
	}
	return out
}

// mssqlPlanCacheRows is the mssql_plancache payload at t (said as demo data): the state row, -sql01's two databases,
// and three statements of Sales' procedures with their counters since their plans were compiled at the server's
// start, rising with the day's load - two reads make the first difference (0092's rule); their texts once an hour.
func (g *Gen) mssqlPlanCacheRows(t time.Time) []Row {
	start := g.mssqlStart()
	local := func(x time.Time) string { return x.UTC().Format("2006-01-02T15:04:05") }
	rows := []Row{{"kind": "state", "server_utc": t.UTC().Format(time.RFC3339), "server_start": start.UTC().Format(time.RFC3339),
		"server_local": local(t), "capped": false},
		{"kind": "database", "database_id": 5, "database_name": "Sales", "database_state": "ONLINE", "query_store_on": 1},
		{"kind": "database", "database_id": 6, "database_name": "Ledger", "database_state": "ONLINE", "query_store_on": 0}}
	stmts := []struct {
		key, object, query    string
		start, end            int
		rate, workerUS, reads float64
	}{
		{"0x7A1F3C2B9D4E5A60", "dbo.usp_GetOrders", "SELECT o.OrderId, o.CustomerId, o.Total FROM dbo.Orders AS o WHERE o.CustomerId = @CustomerId AND o.Status = @Status", 120, 640, 30, 850, 120},
		{"0x2C9B8E1D4F6A7B03", "dbo.usp_AddOrder", "INSERT INTO dbo.Orders (CustomerId, Total, Status) VALUES (@CustomerId, @Total, N'open')", 96, 410, 8, 320, 14},
		{"0x5E3A7D9C1B2F4E86", "dbo.usp_MonthEnd", "SELECT c.CustomerId, SUM(o.Total) AS Total FROM dbo.Orders AS o JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId GROUP BY c.CustomerId", 64, 980, 0.2, 240000, 52000},
	}
	secs := t.Sub(start).Seconds()
	for i, st := range stmts {
		n := int64(st.rate * secs * 0.5 * g.Spec.Load)
		worker := int64(float64(n) * st.workerUS)
		rows = append(rows, Row{"kind": "stmt", "plan_handle": fmt.Sprintf("0x0600050%07X%s", 4100+i, mssqlPlanTail[:32]), "stmt_start": st.start, "stmt_end": st.end,
			"creation_time": local(start), "database_id": 5, "database_name": "Sales", "query_key": st.key, "execution_count": n,
			"worker_us": worker, "elapsed_us": worker + worker/4, "logical_reads": int64(float64(n) * st.reads), "physical_reads": int64(float64(n) * st.reads / 50),
			"logical_writes": int64(float64(n) * 0.5), "row_count": n * 3, "spills": 0, "max_grant_kb": 1024, "max_used_grant_kb": 512, "max_dop": 1,
			"last_execution": local(t.Add(-30 * time.Second)), "last_elapsed_us": int64(st.workerUS * 1.25)})
		if t.Minute() == 0 || t.Equal(g.start) {
			rows = append(rows, Row{"kind": "text", "query_key": st.key, "database_id": 5, "object_name": st.object, "query": st.query})
		}
	}
	return rows
}

// mssqlBrokerRows is the mssql_service_broker payload at t (said as demo data): Sales visited, OrderQueue draining and
// filling with the hour, AuditQueue receive-disabled (as a poison message leaves it) with its messages kept, one
// transmission group to a remote service, the conversations, no endpoint, and the Broker counters rising.
func (g *Gen) mssqlBrokerRows(t time.Time) []Row {
	depth := int64(t.Minute() % 20)
	secs := int64(t.Sub(g.mssqlStart()).Seconds())
	return []Row{{"kind": "database", "database_name": "Sales"},
		{"kind": "queue", "database_name": "Sales", "schema_name": "dbo", "queue_name": "OrderQueue", "object_id": 1093578934,
			"is_receive_enabled": true, "is_enqueue_enabled": true, "is_retention_enabled": false, "is_activation_enabled": true,
			"is_poison_message_handling_enabled": true, "activation_procedure": "[Sales].[dbo].[usp_ProcessOrderQueue]", "activation_procedure_exists": true,
			"max_readers": 4, "message_count": depth, "activated_tasks": 2, "monitor_state": "RECEIVES_OCCURRING", "monitor_tasks_waiting": 0,
			"monitor_last_activated_time": t.Add(-time.Minute).UTC().Format(time.RFC3339), "oldest_message_time": t.Add(-time.Duration(depth) * time.Second).UTC().Format(time.RFC3339)},
		{"kind": "queue", "database_name": "Sales", "schema_name": "dbo", "queue_name": "AuditQueue", "object_id": 1109579001,
			"is_receive_enabled": false, "is_enqueue_enabled": true, "is_retention_enabled": false, "is_activation_enabled": true,
			"is_poison_message_handling_enabled": true, "activation_procedure": "[Sales].[dbo].[usp_ProcessAudit]", "activation_procedure_exists": true,
			"max_readers": 1, "message_count": 37, "activated_tasks": 0, "monitor_state": "INACTIVE", "monitor_tasks_waiting": 0,
			"oldest_message_time": g.end.Add(-6 * time.Hour).UTC().Format(time.RFC3339)},
		{"kind": "transmission", "database_name": "Sales", "to_service_name": "//ledger/post", "transmission_status": "Connection attempt failed with error: '10061(No connection could be made because the target machine actively refused it.)'.",
			"message_count": 12, "oldest_enqueue_time": g.end.Add(-2 * time.Hour).UTC().Format(time.RFC3339)},
		{"kind": "conversation", "database_name": "Sales", "state": "CO", "conversation_count": 18},
		{"kind": "conversation", "database_name": "Sales", "state": "DI", "conversation_count": 3},
		{"kind": "endpoints_read"},
		{"kind": "counter", "object": "Broker Statistics", "instance_name": "", "counter_name": "SQL SEND Total", "cntr_value": secs / 3},
		{"kind": "counter", "object": "Broker Statistics", "instance_name": "", "counter_name": "SQL RECEIVE Total", "cntr_value": secs/3 - depth},
		{"kind": "counter", "object": "Broker Statistics", "instance_name": "", "counter_name": "Enqueued Messages Total", "cntr_value": secs / 3},
	}
}

// mssqlScopedRows is sys.database_scoped_configurations of Sales and Ledger: Sales' MAXDOP set from 0 to 4 30 hours
// before the anchor, Ledger on the legacy cardinality estimator.
func (g *Gen) mssqlScopedRows(t time.Time) []Row {
	maxdop := "0"
	if !t.Before(g.end.Add(-30 * time.Hour)) {
		maxdop = "4"
	}
	var rows []Row
	for _, db := range []string{"Sales", "Ledger"} {
		set := map[string]string{"MAXDOP": "0", "LEGACY_CARDINALITY_ESTIMATION": "0", "PARAMETER_SNIFFING": "1", "QUERY_OPTIMIZER_HOTFIXES": "0",
			"OPTIMIZE_FOR_AD_HOC_WORKLOADS": "0", "ACCELERATED_PLAN_FORCING": "1", "LAST_QUERY_PLAN_STATS": "0", "LIGHTWEIGHT_QUERY_PROFILING": "1"}
		if db == "Sales" {
			set["MAXDOP"] = maxdop
		} else {
			set["LEGACY_CARDINALITY_ESTIMATION"] = "1"
		}
		def := map[string]string{"MAXDOP": "0", "LEGACY_CARDINALITY_ESTIMATION": "0", "PARAMETER_SNIFFING": "1", "QUERY_OPTIMIZER_HOTFIXES": "0",
			"OPTIMIZE_FOR_AD_HOC_WORKLOADS": "0", "ACCELERATED_PLAN_FORCING": "1", "LAST_QUERY_PLAN_STATS": "0", "LIGHTWEIGHT_QUERY_PROFILING": "1"}
		for _, name := range []string{"MAXDOP", "LEGACY_CARDINALITY_ESTIMATION", "PARAMETER_SNIFFING", "QUERY_OPTIMIZER_HOTFIXES",
			"OPTIMIZE_FOR_AD_HOC_WORKLOADS", "ACCELERATED_PLAN_FORCING", "LAST_QUERY_PLAN_STATS", "LIGHTWEIGHT_QUERY_PROFILING"} {
			isDefault := 0
			if set[name] == def[name] {
				isDefault = 1
			}
			rows = append(rows, Row{"kind": "scoped_config", "database_name": db, "name": name, "value": set[name], "value_for_secondary": nil,
				"is_value_default": isDefault})
		}
	}
	return rows
}

// mssqlSchemaRows is a whole mssql_schema read of Sales and Ledger at t (the Schema tab, and the database page's
// Snapshot Summary: DBA Dash's schema snapshots): Sales' procedure dbo.usp_GetOrders altered 20 hours before the anchor,
// its index IX_Orders_CustomerId made 6 hours before it and IX_Orders_Status dropped 26 hours before it. The rows are
// the collector's (internal/mssql/schema.go): the database's 'mssql_db' row, its 'db' row, its objects, then 'end'.
func (g *Gen) mssqlSchemaRows(t time.Time) []Row {
	var out []Row
	for _, d := range []struct {
		id            int
		name, created string
	}{{5, "Sales", "2023-04-11T08:12:40.370"}, {6, "Ledger", "2023-04-11T08:13:02.117"}} {
		var objs []Row
		obj := func(kind, schema, name, table, def string) {
			identity, parent := schema+"."+name, any(nil)
			switch kind {
			case "schema":
				identity = schema
			case "column":
				identity, parent = schema+"."+table+"."+name, schema+"."+table
			case "index", "constraint", "trigger":
				identity, parent = name+" on "+schema+"."+table, schema+"."+table
			}
			objectName := name
			if kind == "schema" {
				objectName = schema
			}
			h, dh := sha256.Sum256([]byte(kind+"\x00"+def+"\x00dbo")), sha256.Sum256([]byte(def))
			objs = append(objs, Row{"kind": "obj", "dbid": d.id, "datname": d.name, "object_kind": kind, "identity": identity,
				"schema_name": schema, "object_name": objectName, "parent": parent, "definition": def, "owner": "dbo", "acl": nil,
				"hash": hex.EncodeToString(h[:16]), "def_hash": hex.EncodeToString(dh[:16])})
		}
		obj("schema", "dbo", "dbo", "", "schema")
		if d.name == "Sales" {
			obj("table", "dbo", "Orders", "", "table")
			obj("column", "dbo", "OrderId", "Orders", "int not null identity(1,1)")
			obj("column", "dbo", "CustomerId", "Orders", "int not null")
			obj("column", "dbo", "Status", "Orders", "varchar(10) not null")
			obj("column", "dbo", "ShippedAt", "Orders", "datetime2(3) null")
			obj("index", "dbo", "PK_Orders", "Orders", "CLUSTERED PRIMARY KEY (OrderId)")
			if !t.Before(g.end.Add(-6 * time.Hour)) {
				obj("index", "dbo", "IX_Orders_CustomerId", "Orders", "NONCLUSTERED (CustomerId) INCLUDE (Status)")
			}
			if t.Before(g.end.Add(-26 * time.Hour)) {
				obj("index", "dbo", "IX_Orders_Status", "Orders", "NONCLUSTERED (Status)")
			}
			obj("trigger", "dbo", "tr_Orders_Audit", "Orders", "CREATE TRIGGER dbo.tr_Orders_Audit ON dbo.Orders AFTER UPDATE AS INSERT dbo.OrderAudit (OrderId, ChangedAt) SELECT OrderId, SYSUTCDATETIME() FROM inserted")
			proc := "CREATE PROCEDURE dbo.usp_GetOrders @CustomerId int AS SELECT o.OrderId, o.Status FROM dbo.Orders o WHERE o.CustomerId = @CustomerId"
			if !t.Before(g.end.Add(-20 * time.Hour)) {
				proc += " ORDER BY o.OrderId DESC"
			}
			obj("procedure", "dbo", "usp_GetOrders", "", proc)
			obj("function", "dbo", "fn_OrderTotal", "", "CREATE FUNCTION dbo.fn_OrderTotal (@OrderId int) RETURNS decimal(14,2) AS BEGIN RETURN (SELECT SUM(Amount) FROM dbo.OrderLines WHERE OrderId = @OrderId) END")
			obj("function", "dbo", "fn_CustomerTier", "", "CREATE FUNCTION dbo.fn_CustomerTier (@CustomerId int) RETURNS tinyint AS BEGIN RETURN 1 END")
		} else {
			obj("table", "dbo", "LedgerEntry", "", "table")
			obj("column", "dbo", "EntryId", "LedgerEntry", "bigint not null identity(1,1)")
			obj("column", "dbo", "AccountId", "LedgerEntry", "int not null")
			obj("column", "dbo", "PostedAt", "LedgerEntry", "datetime2(3) not null")
			obj("column", "dbo", "Amount", "LedgerEntry", "decimal(14,2) not null")
			obj("index", "dbo", "PK_LedgerEntry", "LedgerEntry", "CLUSTERED PRIMARY KEY (EntryId)")
		}
		out = append(out, Row{"kind": "mssql_db", "database_id": d.id, "name": d.name, "create_date": d.created, "create_local": nil,
			"restored_at": nil, "state": "read", "note": nil, "read_at": t.UTC()},
			Row{"kind": "db", "dbid": d.id, "datname": d.name, "read_at": t.UTC(), "objects": len(objs)})
		out = append(out, objs...)
	}
	return append(out, Row{"kind": "end"})
}

// mssqlProcStatRows is the mssql_procstats payload at t (said as demo data; the object page, OBJ): the state row and the
// three Sales procedures the plan cache's texts name (mssqlPlanCacheRows), their counters since their plans were cached
// (at the server's start), rising with the day's load.
func (g *Gen) mssqlProcStatRows(t time.Time) []Row {
	cached := g.mssqlStart()
	rows := []Row{{"kind": "state", "server_utc": t.UTC().Format(time.RFC3339), "server_start": cached.UTC().Format(time.RFC3339),
		"server_local": t.UTC().Format("2006-01-02T15:04:05"), "capped": false}}
	objs := []struct {
		name                  string
		id                    int
		rate, workerUS, reads float64
	}{
		{"usp_GetOrders", 965578478, 2, 640, 850},
		{"usp_AddOrder", 981578535, 1.6, 410, 320},
		{"usp_MonthEnd", 997578592, 0.05, 980000, 120000},
	}
	secs := t.Sub(cached).Seconds()
	for _, o := range objs {
		n := int64(o.rate * secs * 0.5 * g.Spec.Load)
		worker := int64(float64(n) * o.workerUS)
		rows = append(rows, Row{"kind": "proc", "plan_handle": fmt.Sprintf("0x05000500%08X%s", o.id, mssqlPlanTail[:32]), "cached_time": cached.UTC().Format(time.RFC3339),
			"database_id": 5, "object_id": o.id, "database_name": "Sales", "schema_name": "dbo", "object_name": o.name, "type_desc": "SQL_STORED_PROCEDURE",
			"execution_count": n, "worker_us": worker, "elapsed_us": worker + worker/4, "logical_reads": int64(float64(n) * o.reads),
			"physical_reads": int64(float64(n)*o.reads) / 300, "logical_writes": n / 20, "spills": 0})
	}
	return rows
}

// mssqlFuncStatRows is the mssql_funcstats payload at t: the state row and, for two scalar functions and a trigger of
// Sales, their counters since their plans were cached (at the server's start), rising with the day's load.
func (g *Gen) mssqlFuncStatRows(t time.Time) []Row {
	cached := g.mssqlStart()
	rows := []Row{{"kind": "state", "server_utc": t.UTC().Format(time.RFC3339), "server_start": cached.UTC().Format(time.RFC3339),
		"server_local": t.UTC().Format("2006-01-02T15:04:05"), "capped": false, "kinds": []string{"function", "trigger"}}}
	objs := []struct {
		kind, schema, name, typeDesc, scope string
		id                                  int
		rate, workerUS, reads               float64
	}{
		{"function", "dbo", "fn_OrderTotal", "SQL_SCALAR_FUNCTION", "", 1013578649, 40, 180, 6},
		{"function", "dbo", "fn_CustomerTier", "SQL_SCALAR_FUNCTION", "", 1029578706, 12, 950, 40},
		{"trigger", "dbo", "tr_Orders_Audit", "SQL_TRIGGER", "OBJECT_OR_COLUMN", 1045578763, 6, 2200, 85},
	}
	secs := t.Sub(cached).Seconds()
	for i, o := range objs {
		// the executions so far: the rate times the seconds, weighed by the day's average load
		n := int64(o.rate * secs * 0.5 * g.Spec.Load)
		worker := int64(float64(n) * o.workerUS)
		r := Row{"kind": o.kind, "plan_handle": fmt.Sprintf("0x05000500%08X%s", o.id, mssqlPlanTail[:32]), "cached_time": cached.UTC().Format(time.RFC3339),
			"database_id": 5, "object_id": o.id, "database_name": "Sales", "schema_name": o.schema, "object_name": o.name, "type_desc": o.typeDesc,
			"trigger_scope": nil, "execution_count": n, "worker_us": worker, "elapsed_us": worker + worker/5, "logical_reads": int64(float64(n) * o.reads),
			"physical_reads": int64(float64(n)*o.reads) / 200, "logical_writes": n / 10 * int64(i), "spills": 0,
			"min_worker_us": int64(o.workerUS / 3), "max_worker_us": int64(o.workerUS * 20), "min_elapsed_us": int64(o.workerUS / 3),
			"max_elapsed_us": int64(o.workerUS * 30), "min_logical_reads": int64(o.reads / 4), "max_logical_reads": int64(o.reads * 15),
			"min_physical_reads": 0, "max_physical_reads": int64(o.reads), "min_logical_writes": 0, "max_logical_writes": int64(i * 4),
			"min_spills": 0, "max_spills": 0}
		if o.scope != "" {
			r["trigger_scope"] = o.scope
		}
		rows = append(rows, r)
	}
	return rows
}
