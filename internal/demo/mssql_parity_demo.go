package demo

import (
	"fmt"
	"math"
	"time"
)

// The pages P25 added, with data on the demo (task 11b): a page that shows only its empty-state words on the demo
// reads as not working. Every row goes in through its import function as the collector hands it:
//
//	-azure-sqldb01 / -sqldb02  two Azure SQL Databases on the logical server demo-sqlsrv01, each moved from Standard S0
//	        into the Basic elastic pool pool-ledger during the week (sqldb02 five days before the anchor, sqldb01 two:
//	        the Service Objectives grid's tier change), the pool's limits raised from 50 to 100 eDTU and 5 to 10 GB
//	        three days before the anchor (Pool history, from master's 14 days).
//	-sql01  its Sales database's scoped configuration (MAXDOP set from 0 to 4 three days before the anchor), a database
//	        snapshot of Sales, and function and trigger statistics (the Object Execution grid, the Execution Stats
//	        strip). The collector sends the scoped configuration and the snapshots inside mssql_confcheck (0391 / 0392,
//	        their join lines): the demo hands them to their own import functions.
//
// Demo data, like every other demo row: the names, the figures and the governance view's values are made up.

const (
	demoAzPlatform = "azuresqldb"
	demoAzServer   = "demo-sqlsrv01"
	demoAzPool     = "pool-ledger"
)

// azureDBCollections names what the collector runs on a pooled Azure SQL Database (for the collection log).
var azureDBCollections = []string{"mssql_instance", "mssql_azuredb_resources", "mssql_azuredb_governance", "mssql_pool", "mssql_pool_limits"}

// azureMovedAt is when the database moved into the pool.
func (g *Gen) azureMovedAt() time.Time {
	if g.is("-sqldb02") {
		return g.end.Add(-5 * 24 * time.Hour)
	}
	return g.end.Add(-2 * 24 * time.Hour)
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
	g.prev = t
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
// snapshots (mssql_confcheck's hour), every five minutes the function and trigger statistics.
func (g *Gen) mssqlParityBatches(t time.Time, first bool) []Batch {
	if !g.is("-sql01") {
		return nil
	}
	var out []Batch
	if first || t.Minute() == 0 || t.Equal(g.end) {
		out = append(out, Batch{Collection: "mssql_db_scoped_config", At: t, Rows: g.mssqlScopedRows(t)})
		if rows := g.mssqlSnapshotRows(t); len(rows) > 0 {
			out = append(out, Batch{Collection: "mssql_db_snapshots", At: t, Rows: rows})
		}
	}
	if first || t.Minute()%5 == 0 || t.Equal(g.end) {
		out = append(out, Batch{Collection: "mssql_funcstats", At: t, Rows: g.mssqlFuncStatRows(t)})
	}
	return out
}

// mssqlScopedRows is sys.database_scoped_configurations of Sales and Ledger: Sales' MAXDOP set from 0 to 4 three days
// before the anchor, Ledger on the legacy cardinality estimator.
func (g *Gen) mssqlScopedRows(t time.Time) []Row {
	maxdop := "0"
	if !t.Before(g.end.Add(-3 * 24 * time.Hour)) {
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

// mssqlSnapshotRows lists Sales' database snapshot from its creation 18 hours before the anchor (none before it).
func (g *Gen) mssqlSnapshotRows(t time.Time) []Row {
	made := g.end.Add(-18 * time.Hour)
	if t.Before(made) {
		return nil
	}
	size := int64(8<<20) + int64(t.Sub(made).Hours()*float64(2<<20))
	return []Row{{"kind": "db_snapshot", "snapshot_name": "Sales_snap_daily", "source_database": "Sales", "created_utc": made.UTC().Format(time.RFC3339),
		"size_on_disk_bytes": size, "files": 1, "size_note": nil}}
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
