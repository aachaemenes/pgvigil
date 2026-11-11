package demo

import (
	"fmt"
	"strings"
	"time"
)

// The demo's mssql_querystore payload (0083), a function of t alone: the stores' state, the store's last closed
// interval and its open one, the plans, the automatic tuning rows. The collection runs hourly, so a seed of two
// days stores 48 intervals per database.
//
//	-sql01  Sales and Orders with Query Store on. Sales: a procedure's statement that changed plan at the top of the
//	        hour before the anchor's and runs five times slower since (the Regressed view; SQL Server's own recommendation to
//	        force the plan before, on the Tuning view), a parallel report with a forced plan. Orders: a forced plan
//	        SQL Server cannot use since its index was dropped (the finding 'a forced plan fails'). Reporting: a
//	        store that filled its 100 MB and went read-only (the Summary's QS cell reads Warning). The other
//	        databases: Query Store off, nobody asked for it.
//	-sql02  the secondary: Sales' store is read-only because the database is a secondary replica (no warning); its
//	        contents are the primary's.
//	-sql03  the managed instance: Ledger on, Staging off.

// qsDemoStore is one database's store.
type qsDemoStore struct {
	db              string
	id              int
	desired, actual string
	reason          int64 // readonly_reason
	currentMB       int64
	maxMB           int64
	stmts           bool // the database carries the demo's statements
}

// qsDemoStmt is one query of a store. slowFrom: the plan (plan+5) and the figures (x slow) it runs with from the
// demo's regression hour on; forced: the plan forced for the query when it is not the one that runs.
type qsDemoStmt struct {
	db           string
	query, plan  int64
	object, text string
	perHour      float64
	durUS, cpuUS float64 // per execution
	reads, rows  float64
	writes       float64
	memPages     int64
	waitUS       float64
	topWait      string
	dop          int64
	failed       float64 // share of executions aborted
	slow         float64 // > 0: the regression's factor
	forcedPlan   int64   // a forced plan that does not run
	forced       bool    // the running plan is forced
}

func (g *Gen) qsDemoStores() []qsDemoStore {
	switch {
	case g.is("-sql02"):
		return []qsDemoStore{
			{"Sales", 5, "READ_WRITE", "READ_ONLY", 8, 612, 1000, true},
			{"msdb", 4, "OFF", "OFF", 0, 0, 100, false},
		}
	case g.is("-sql03"):
		return []qsDemoStore{
			{"Ledger", 5, "READ_WRITE", "READ_WRITE", 0, 211, 1000, true},
			{"Staging", 6, "OFF", "OFF", 0, 0, 100, false},
			{"msdb", 4, "OFF", "OFF", 0, 0, 100, false},
		}
	}
	return []qsDemoStore{
		{"Orders", 6, "READ_WRITE", "READ_WRITE", 0, 184, 1000, true},
		{"Reporting", 7, "READ_WRITE", "READ_ONLY", 65536, 100, 100, false},
		{"Sales", 5, "READ_WRITE", "READ_WRITE", 0, 612, 1000, true},
		{"Sales_archive", 8, "OFF", "OFF", 0, 0, 100, false},
		{"msdb", 4, "OFF", "OFF", 0, 0, 100, false},
		{"scratch_etl", 10, "OFF", "OFF", 0, 0, 100, false},
		{"staging_import", 9, "OFF", "OFF", 0, 0, 100, false},
	}
}

// qsDemoStmts: the statements of the demo's stores (Sales' are Ledger's on the managed instance).
func qsDemoStmts() []qsDemoStmt {
	return []qsDemoStmt{
		{db: "Sales", query: 1, plan: 7, object: "dbo.usp_GetOrderHistory",
			text:    "SELECT o.OrderID, o.OrderDate, o.Total FROM dbo.Orders AS o WHERE o.CustomerID = @CustomerID ORDER BY o.OrderDate DESC",
			perHour: 5200, durUS: 2400, cpuUS: 1900, reads: 14, rows: 9, topWait: "CPU", waitUS: 120, dop: 1, slow: 5},
		{db: "Sales", query: 2, plan: 3, object: "dbo.usp_AddOrderLine",
			text:    "INSERT INTO dbo.OrderLines (OrderID, ProductID, Qty, Price) VALUES (@OrderID, @ProductID, @Qty, @Price)",
			perHour: 38000, durUS: 350, cpuUS: 190, reads: 6, rows: 1, writes: 3, topWait: "Tran Log IO", waitUS: 110, dop: 1},
		{db: "Sales", query: 3, plan: 5, object: "dbo.usp_RevenueByRegion",
			text: "SELECT c.Region, SUM(ol.Qty * ol.Price) AS Revenue FROM dbo.OrderLines AS ol JOIN dbo.Orders AS o ON o.OrderID = ol.OrderID " +
				"JOIN dbo.Customers AS c ON c.CustomerID = o.CustomerID WHERE o.OrderDate >= @From GROUP BY c.Region",
			perHour: 12, durUS: 8.4e6, cpuUS: 21e6, reads: 2.1e6, rows: 14, memPages: 235930, topWait: "Parallelism", waitUS: 3.1e6, dop: 8, forced: true},
		{db: "Sales", query: 4, plan: 9, object: "dbo.usp_ReserveStock",
			text:    "UPDATE dbo.Inventory SET OnHand = OnHand - @Qty WHERE ProductID = @ProductID",
			perHour: 9000, durUS: 1100, cpuUS: 300, reads: 8, rows: 1, writes: 2, topWait: "Lock", waitUS: 600, dop: 1},
		{db: "Sales", query: 5, plan: 11,
			text:    "SELECT p.ProductID, p.Name, p.Price FROM dbo.Products AS p WHERE p.Name LIKE @Search",
			perHour: 2600, durUS: 46000, cpuUS: 44000, reads: 5200, rows: 22, topWait: "CPU", waitUS: 1500, dop: 1},
		{db: "Sales", query: 6, plan: 14,
			text:    "SELECT TOP (50) * FROM dbo.Orders WHERE Status = N'open' ORDER BY OrderDate",
			perHour: 700, durUS: 18000, cpuUS: 6000, reads: 900, rows: 50, memPages: 128, topWait: "Buffer IO", waitUS: 9000, dop: 1},
		{db: "Sales", query: 7, plan: 15,
			text:    "DELETE FROM dbo.SessionState WHERE ExpiresAt < SYSUTCDATETIME()",
			perHour: 60, durUS: 310000, cpuUS: 120000, reads: 21000, rows: 400, writes: 900, topWait: "Lock", waitUS: 150000, dop: 1, failed: 0.04},
		{db: "Sales", query: 8, plan: 16,
			text:    "SELECT COUNT(*) FROM dbo.AuditLog WHERE EventTime >= @Since",
			perHour: 240, durUS: 95000, cpuUS: 90000, reads: 12800, rows: 1, topWait: "CPU", waitUS: 2000, dop: 1},
		{db: "Orders", query: 31, plan: 45, object: "dbo.usp_ShippedSince",
			text: "SELECT o.OrderID, s.TrackingNo FROM dbo.Shipments AS s JOIN dbo.Orders AS o ON o.OrderID = s.OrderID WHERE s.ShippedAt >= @Since",
			// plan 44 is forced; its index IX_Shipments_ShippedAt was dropped, so the query runs with plan 45
			perHour: 900, durUS: 64000, cpuUS: 52000, reads: 7400, rows: 120, memPages: 256, topWait: "Buffer IO", waitUS: 8000, dop: 1, forcedPlan: 44},
		{db: "Orders", query: 32, plan: 46, object: "dbo.usp_SetShipmentStatus",
			text:    "UPDATE dbo.Shipments SET Status = @Status WHERE ShipmentID = @ShipmentID",
			perHour: 4000, durUS: 800, cpuUS: 260, reads: 6, rows: 1, writes: 2, topWait: "Tran Log IO", waitUS: 240, dop: 1},
	}
}

// qsRegressFrom is the hour from which Sales' query 1 runs with its new, slower plan.
func (g *Gen) qsRegressFrom() time.Time { return g.end.Truncate(time.Hour).Add(-time.Hour) }

func qsHex(s string) (string, int64) {
	n := hash64(s)
	return fmt.Sprintf("0x%016X", uint64(n)), n
}

// qsShowplan is a small showplan document of the shape SQL Server writes (one statement, one operator): what the
// demo's .sqlplan download carries.
func qsShowplan(text, queryHash, planHash, op string, parallel bool) string {
	esc := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;").Replace(text)
	par := "0"
	if parallel {
		par = "1"
	}
	return `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564" Build="16.0.4135.4">` +
		`<BatchSequence><Batch><Statements><StmtSimple StatementText="` + esc + `" StatementId="1" StatementCompId="1" StatementType="SELECT" ` +
		`StatementSubTreeCost="0.0032831" StatementEstRows="1" QueryHash="` + queryHash + `" QueryPlanHash="` + planHash + `">` +
		`<QueryPlan CachedPlanSize="24" CompileTime="1" CompileCPU="1" CompileMemory="168">` +
		`<RelOp NodeId="0" PhysicalOp="` + op + `" LogicalOp="` + op + `" EstimateRows="1" EstimateIO="0.003125" EstimateCPU="0.0001581" AvgRowSize="45" ` +
		`EstimatedTotalSubtreeCost="0.0032831" Parallel="` + par + `" EstimateRebinds="0" EstimateRewinds="0" EstimatedExecutionMode="Row"><OutputList/></RelOp>` +
		`</QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>`
}

// mssqlQueryStoreDemoRows is the mssql_querystore payload at t.
func (g *Gen) mssqlQueryStoreDemoRows(t time.Time) []Row {
	var out []Row
	hour := t.Truncate(time.Hour)
	regress := g.qsRegressFrom()
	for _, st := range g.qsDemoStores() {
		store := Row{"kind": "store", "database_id": st.id, "database_name": st.db, "database_state": "ONLINE", "database_read_only": 0, "read": 1,
			"desired_state": st.desired, "actual_state": st.actual, "readonly_reason": st.reason, "current_mb": st.currentMB, "max_mb": st.maxMB,
			"flush_interval_s": 900, "interval_minutes": 60, "stale_days": 30, "max_plans_per_query": 200, "capture_mode": "AUTO",
			"cleanup_mode": "AUTO", "wait_stats_mode": "ON", "additional_info": "", "can_read": 1,
			"policy_execution_count": 30, "policy_compile_cpu_ms": 1000, "policy_exec_cpu_ms": 100, "policy_stale_hours": 24}
		if st.actual == "OFF" {
			store["capture_mode"], store["wait_stats_mode"] = "ALL", "OFF"
		}
		if st.db == "Reporting" {
			store["cleanup_mode"] = "OFF" // nothing made room: the store filled and went read-only
		}
		out = append(out, store, Row{"kind": "tuning_option", "database_name": st.db, "option_name": "FORCE_LAST_GOOD_PLAN",
			"desired_state": "DEFAULT", "actual_state": "OFF", "reason": "INHERITED_FROM_SERVER"})
		if !st.stmts {
			continue
		}
		// the statements of this store: Ledger carries Sales' on the managed instance
		src := st.db
		if st.db == "Ledger" {
			src = "Sales"
		}
		// the interval that closed at the top of this hour, and the open one up to t
		for _, iv := range []struct {
			start time.Time
			frac  float64
		}{{hour.Add(-time.Hour), 1}, {hour, t.Sub(hour).Hours()}} {
			if iv.frac <= 0 {
				continue
			}
			var plans, execs, durUS, cpuUS, reads, waitMS int64
			var rows []Row
			for _, s := range qsDemoStmts() {
				if s.db != src {
					continue
				}
				key := st.db + fmt.Sprint(s.query)
				load := (0.4 + 0.6*curve(iv.start.Add(30*time.Minute))) * (0.85 + 0.3*noise(key, iv.start)) * g.Spec.Load
				n := int64(s.perHour * load * iv.frac)
				if n == 0 {
					continue
				}
				plan, f := s.plan, 1.0
				if s.slow > 0 && !iv.start.Before(regress) {
					plan, f = s.plan+5, s.slow
				}
				jit := 0.9 + 0.2*noise(key+"d", iv.start)
				d, c := int64(float64(n)*s.durUS*f*jit), int64(float64(n)*s.cpuUS*f*jit)
				lr := int64(float64(n) * s.reads * (1 + (f-1)*6))
				w := int64(float64(n) * s.waitUS * f / 1000)
				rows = append(rows, Row{"kind": "runtime", "database_name": st.db, "interval_start": iv.start, "interval_id": iv.start.Unix() / 3600,
					"plan_id": plan, "executions": n, "failed": int64(float64(n) * s.failed), "duration_us": d, "cpu_us": c, "logical_reads": lr,
					"physical_reads": lr / 50, "logical_writes": int64(float64(n) * s.writes), "row_count": int64(float64(n) * s.rows),
					"max_duration_us": int64(s.durUS * f * (3 + 4*noise(key+"m", iv.start))), "memory_pages": n * s.memPages,
					"max_memory_pages": s.memPages + s.memPages/5, "max_dop": s.dop, "first_execution": iv.start.Add(5 * time.Second),
					"last_execution": iv.start.Add(time.Duration(iv.frac*float64(time.Hour)) - 3*time.Second), "wait_ms": w, "top_wait": s.topWait})
				plans, execs, durUS, cpuUS, reads, waitMS = plans+1, execs+n, durUS+d, cpuUS+c, reads+lr, waitMS+w
			}
			// the interval's totals are over every plan: the kept ones and a tail of small statements under the cut
			out = append(out, Row{"kind": "interval", "database_name": st.db, "interval_id": iv.start.Unix() / 3600, "interval_start": iv.start,
				"interval_end": iv.start.Add(time.Hour), "plans": plans + 40, "executions": execs + execs/9, "duration_us": durUS + durUS/12,
				"cpu_us": cpuUS + cpuUS/12, "logical_reads": reads + reads/15, "wait_ms": waitMS + waitMS/12})
			out = append(out, rows...)
		}
		// the plans: every plan that ran or is forced, with its query's text; the showplan of each
		for _, s := range qsDemoStmts() {
			if s.db != src {
				continue
			}
			qh, _ := qsHex(src + s.text)
			type pl struct {
				id           int64
				forced       bool
				failures     int64
				failure, op  string
				lastCompiled time.Time
			}
			ps := []pl{{id: s.plan, forced: s.forced, op: "Clustered Index Seek", lastCompiled: g.end.Add(-9 * 24 * time.Hour)}}
			if s.slow > 0 && !t.Before(regress) {
				ps = append(ps, pl{id: s.plan + 5, op: "Clustered Index Scan", lastCompiled: regress.Add(2 * time.Minute)})
			}
			if s.forcedPlan > 0 {
				ps = append(ps, pl{id: s.forcedPlan, forced: true, failures: 17 + int64(max(0, t.Sub(g.end).Hours())), failure: "NO_INDEX", op: "Index Seek",
					lastCompiled: g.end.Add(-20 * 24 * time.Hour)})
			}
			for _, p := range ps {
				ph, pn := qsHex(fmt.Sprint(src, s.query, p.id))
				xml := qsShowplan(s.text, qh, ph, p.op, s.dop > 1)
				forcing := "NONE"
				if p.forced {
					forcing = "MANUAL"
				}
				row := Row{"kind": "plan", "database_name": st.db, "plan_id": p.id, "query_id": s.query, "query_hash_hex": qh, "plan_hash_hex": ph,
					"plan_hash_n": pn, "is_forced": map[bool]int{true: 1}[p.forced], "forcing_type": forcing, "force_failure_count": p.failures,
					"is_parallel": map[bool]int{true: 1}[s.dop > 1], "is_trivial": 0, "count_compiles": 3, "compatibility_level": 160,
					"initial_compile": p.lastCompiled, "last_compile": p.lastCompiled, "plan_last_execution": t.Add(-4 * time.Second),
					"query_last_execution": t.Add(-4 * time.Second), "parameterization": "None", "plan_count": len(ps),
					"plan_xml_bytes": 2 * len(xml), "query": s.text}
				if s.object != "" {
					row["object_name"] = s.object
				}
				if p.failures > 0 {
					row["force_failure_reason"] = p.failure
					row["plan_last_execution"] = g.end.Add(-3 * 24 * time.Hour) // it last ran before its index was dropped
				}
				out = append(out, row, Row{"kind": "plan_xml", "kind_of": "plan", "database_name": st.db, "plan_id": p.id, "statement": xml})
			}
		}
		out = append(out, Row{"kind": "forced_read", "database_name": st.db})
		// SQL Server's own recommendation for the regressed statement: force the plan it ran with before
		if src == "Sales" && !t.Before(regress.Add(30*time.Minute)) {
			since := regress.Add(30 * time.Minute)
			out = append(out, Row{"kind": "tuning", "database_name": st.db, "rec_name": "PR_1", "rec_type": "FORCE_LAST_GOOD_PLAN",
				"reason":      "Average query CPU time changed from 1.9ms to 9.5ms",
				"valid_since": since.UTC().Format(time.RFC3339), "last_refresh": t.UTC().Format(time.RFC3339),
				"rec_state": "Active", "state_reason": "AutomaticTuningOptionNotEnabled", "is_executable": 1, "is_revertable": 0, "score": 62,
				"query_id": 1, "regressed_plan_id": 12, "recommended_plan_id": 7,
				"script":      "exec sp_query_store_force_plan @query_id = 1, @plan_id = 7",
				"rec_details": `{"planForceDetails":{"queryId":1,"regressedPlanId":12,"recommendedPlanId":7},"implementationDetails":{"method":"TSql","script":"exec sp_query_store_force_plan @query_id = 1, @plan_id = 7"}}`})
		}
		out = append(out, Row{"kind": "tuning_read", "database_name": st.db})
	}
	return out
}
