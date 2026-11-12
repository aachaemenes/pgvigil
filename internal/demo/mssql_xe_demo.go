package demo

import (
	"fmt"
	"math/rand/v2"
	"strconv"
	"strings"
	"time"
)

// mssqlXERows is the payload of one import_mssql_xe call for a demo SQL Server instance, the events of the day
// before end: the four captures as running sessions (the instance whose name ends in "-sql03": the slow session
// not installed, so the Slow queries tab shows its 'not installed' line and the finding), three deadlocks, about
// 400 slow completions of four shapes with their statements' hashes, four blocked-process reports of one head
// statement, two attentions and, on the instance whose name ends in "-sql01", a failover seen from the new primary
// (AlwaysOn_health). The seed imports it twice a minute apart: the capture findings hold for two reads, and an
// event is stored once by its time and key (a counter here; rng must be seeded the same for both calls).
func mssqlXERows(name string, end time.Time, rng *rand.Rand) []Row {
	ts := func(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }
	n := 0
	key := func() string { n++; return fmt.Sprintf("%032x-0", n) }
	var rows []Row

	// the capture states
	slowInstalled := !strings.HasSuffix(name, "-sql03")
	state := func(capture, target string, kb int, installed bool) Row {
		if !installed {
			return Row{"kind": "state", "capture": capture, "state": "not installed", "source": "product"}
		}
		return Row{"kind": "state", "capture": capture, "state": "running", "source": "product", "session_name": "pgvigil_demo_" + capture,
			"target": target, "buffer_kb": kb, "buffer_used_kb": kb / 20, "event_count": 3, "total_processed": 3, "new_events": 0,
			"dropped_events": 0, "dropped_buffers": 0, "truncated": false, "unknown_events": 0}
	}
	blocked := state("blocked", "ring_buffer", 4096, true)
	blocked["threshold_s"] = 15
	attention := state("attention", "ring_buffer", 1024, true)
	attention["counter"] = 2
	rows = append(rows, state("deadlocks", "ring_buffer", 4096, true), blocked, state("slow", "event_file", 51200, slowInstalled), attention)

	// three deadlocks: 20 minutes, 5 hours and 19 hours ago
	for i, ago := range []time.Duration{20 * time.Minute, 5 * time.Hour, 19 * time.Hour} {
		at := end.Add(-ago)
		a, b := 101+i*4, 103+i*4
		stmtA := "UPDATE dbo.OrderLine SET qty = qty - 1 WHERE order_id = 18841 AND line = 2"
		stmtB := "UPDATE dbo.Stock SET on_hand = on_hand - 1 WHERE sku = N'BX-2210'"
		proc := func(spid int, victim bool, login, stmt, waitsOn string) map[string]any {
			return map[string]any{"process": fmt.Sprintf("process%x", spid*4099), "spid": spid, "victim": victim, "login": login,
				"host": "app-" + strconv.Itoa(1+spid%3), "program": "orders-api", "database": "Sales", "isolation": "read committed (2)",
				"status": "suspended", "trancount": 2, "wait_resource": "KEY: 5:72057594049593344 (8194443284a0)", "wait_ms": 2500 + spid,
				"lock_mode": "X", "transaction": "user_transaction", "log_used": 368, "statement": stmt, "waits_on": waitsOn, "waits_mode": "X"}
		}
		res := func(object, index string, owner, waiter int) map[string]any {
			return map[string]any{"type": "keylock", "object": object, "index": index, "mode": "X",
				"owners":  []map[string]any{{"spid": owner, "mode": "X"}},
				"waiters": []map[string]any{{"spid": waiter, "mode": "X"}}}
		}
		rows = append(rows, Row{"kind": "deadlock", "event_at": ts(at), "event_key": key(), "event_name": "xml_deadlock_report",
			"source": "product", "session_name": "pgvigil_demo_deadlocks", "process_count": 2, "victim_count": 1, "victim_spid": a,
			"victim_login": "orders_app", "victim_program": "orders-api", "statement": stmtA, "database_names": "Sales",
			"object_names": "Sales.dbo.OrderLine, Sales.dbo.Stock",
			"processes":    []map[string]any{proc(a, true, "orders_app", stmtA, "Sales.dbo.Stock"), proc(b, false, "stock_job", stmtB, "Sales.dbo.OrderLine")},
			"resources":    []map[string]any{res("Sales.dbo.Stock", "PK_Stock", b, a), res("Sales.dbo.OrderLine", "PK_OrderLine", a, b)},
			"graph":        "<deadlock><victim-list><victimProcess id=\"process" + fmt.Sprintf("%x", a*4099) + "\"/></victim-list><process-list/><resource-list/></deadlock>"})
	}

	// blocked-process reports: one head statement, four reports over a minute, 40 minutes ago
	head := "BEGIN TRAN; UPDATE dbo.Customer SET credit_hold = 1 WHERE customer_id = 5521"
	for i := 0; i < 4; i++ {
		at := end.Add(-40*time.Minute + time.Duration(i)*15*time.Second)
		rows = append(rows, Row{"kind": "blocked", "event_at": ts(at), "event_key": key(), "event_name": "blocked_process_report",
			"session_name": "pgvigil_demo_blocked", "database_name": "Sales", "wait_resource": "KEY: 5:72057594050183168 (61a06abd401c)",
			"wait_ms": 15000 * (i + 1), "lock_mode": "U", "blocked_spid": 88 + i%2, "blocked_login": "orders_app", "blocked_host": "app-2",
			"blocked_program": "orders-api", "blocked_statement": "UPDATE dbo.Customer SET last_order = SYSDATETIME() WHERE customer_id = 5521",
			"blocking_spid": 72, "blocking_status": "sleeping", "blocking_trancount": 1, "blocking_login": "credit_svc", "blocking_host": "batch-1",
			"blocking_program": "credit-review", "statement": head, "blocking_last_batch": at.Add(-3 * time.Minute).UTC().Format("2006-01-02T15:04:05.000"),
			"head_key": "de30bead00000001",
			// both sides' columns of 0116 (task 177 D04), so the demo's Blocked reports findings read in full
			"transaction_id": 4100 + i, "blocked_wait_ms": 15000 * (i + 1), "resource_owner_type": "LOCK",
			"blocked_status": "suspended", "blocked_isolation": "read committed (2)", "blocking_isolation": "read committed (2)",
			"blocked_transaction_name": "UPDATE", "blocking_transaction_name": "user_transaction"})
	}

	// a day of slow completions: four shapes
	if slowInstalled {
		shapes := []struct {
			event, shape, stmt, object, db, hash string
			baseMs                               float64
			share                                int
		}{
			{"rpc_completed", "usp_MonthEndClose", "exec dbo.usp_MonthEndClose @period = 202610", "usp_MonthEndClose", "Finance", "0x9A1F3C55D2E07B41", 4200, 5},
			{"sql_batch_completed", "SELECT c.name, SUM(o.total) FROM dbo.Orders o JOIN dbo.Customer c ON c.customer_id = o.customer_id WHERE o.ordered >= ? GROUP BY c.name", "SELECT c.name, SUM(o.total) FROM dbo.Orders o JOIN dbo.Customer c ON c.customer_id = o.customer_id WHERE o.ordered >= '2026-10-01' GROUP BY c.name", "", "Sales", "0x51C0E2A47B93D6F8", 1900, 50},
			{"rpc_completed", "usp_SearchOrders", "exec dbo.usp_SearchOrders @text = N'bolt', @top = 200", "usp_SearchOrders", "Sales", "0xD40B77A19C3E5F02", 1300, 35},
			{"sql_batch_completed", "DELETE TOP (?) FROM dbo.AuditLog WHERE logged < ?", "DELETE TOP (5000) FROM dbo.AuditLog WHERE logged < '2026-08-01'", "", "Sales", "0x0E88C1F2A6D4B937", 2600, 10},
		}
		for i := 0; i < 400; i++ {
			at := end.Add(-time.Duration(rng.Int64N(int64(24 * time.Hour))))
			pick, roll := shapes[0], rng.IntN(100)
			for _, s := range shapes {
				if roll < s.share {
					pick = s
					break
				}
				roll -= s.share
			}
			dur := pick.baseMs * (0.7 + 1.6*rng.Float64())
			result := "OK"
			if rng.IntN(60) == 0 {
				result = "Abort"
			}
			row := Row{"kind": "slow", "event_at": ts(at), "event_key": key(), "event_name": pick.event, "session_name": "pgvigil_demo_slow",
				"duration_us": int64(dur * 1000), "cpu_us": int64(dur * 1000 * 0.6), "logical_reads": int64(dur * 90), "physical_reads": int64(dur * 2),
				"writes": int64(dur / 40), "row_count": 1 + rng.IntN(500), "result": result, "statement": pick.stmt, "login_name": "orders_app",
				"host_name": "app-" + strconv.Itoa(1+rng.IntN(3)), "program_name": "orders-api", "database_name": pick.db, "session_id": 60 + rng.IntN(40),
				"query_hash_hex": pick.hash, "query_plan_hash_hex": pick.hash[:10] + "00000000", "shape": pick.shape,
				"shape_key": fmt.Sprintf("%016x", uint64(hash64(pick.shape)))}
			if pick.object != "" {
				row["object_name"] = pick.object
			}
			rows = append(rows, row)
		}
	}

	// two attentions
	for _, ago := range []time.Duration{50 * time.Minute, 7 * time.Hour} {
		rows = append(rows, Row{"kind": "attention", "event_at": ts(end.Add(-ago)), "event_key": key(), "event_name": "attention",
			"session_name": "pgvigil_demo_attention", "session_id": 77, "request_id": 0, "interrupt_us": 410,
			"statement": "SELECT * FROM dbo.Orders WHERE note LIKE N'%urgent%'", "login_name": "report_user", "host_name": "rpt-1",
			"program_name": "reporting", "database_name": "Sales"})
	}

	// a failover 30 minutes ago, seen from the new primary
	if strings.HasSuffix(name, "-sql01") {
		rows = append(rows, Row{"kind": "state", "capture": "ag", "state": "running", "source": "AlwaysOn_health", "session_name": "AlwaysOn_health", "target": "event_file"})
		f := end.Add(-30 * time.Minute)
		step := func(d time.Duration, prev, cur string, failover bool) Row {
			return Row{"kind": "ag_event", "event_at": ts(f.Add(d)), "event_key": key(), "event_name": "availability_replica_state_change",
				"ag_name": "ag_sales", "replica_name": "DEMO-SQL01", "previous_state": prev, "current_state": cur, "is_failover": failover}
		}
		rows = append(rows,
			Row{"kind": "ag_event", "event_at": ts(f.Add(-2 * time.Second)), "event_key": key(), "event_name": "error_reported", "ag_name": nil,
				"error_number": 35206, "severity": 10, "family": "connection", "is_failover": false,
				"message": "A connection timeout has occurred on a previously established connection to availability replica 'DEMO-SQL02'."},
			step(0, "SECONDARY_NORMAL", "RESOLVING_PENDING_FAILOVER", true),
			step(300*time.Millisecond, "RESOLVING_PENDING_FAILOVER", "RESOLVING_NORMAL", false),
			step(900*time.Millisecond, "RESOLVING_NORMAL", "PRIMARY_PENDING", false),
			step(1400*time.Millisecond, "PRIMARY_PENDING", "PRIMARY_NORMAL", false))
	}
	return rows
}
