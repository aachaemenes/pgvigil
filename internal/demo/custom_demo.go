package demo

import (
	"math"
	"time"
)

// customDemoRows are two custom checks over the demo's history (DBADash's custom checks; pgvigil's custom collection):
//   - idle_in_transaction on every primary (a value check every 5 minutes, warning > 3, critical > 10): a small count
//     that follows the load, and on aurora-crm01 a climb through the last two hours past warning to critical (an
//     application that leaves transactions open);
//   - disabled_triggers on onprem-erp01 only (a row-count check every hour, warning > 0): none until six hours before
//     the anchor, then two triggers a load switched off and did not switch back on.
//
// Every step lists both definitions (the state and check rows); a result row comes at each check's cadence.
func (g *Gen) customDemoRows(t time.Time, first bool) []Row {
	if g.Spec.Replica {
		return nil
	}
	idle := Row{"kind": "check", "check_name": "idle_in_transaction", "description": "sessions idle inside an open transaction",
		"sql": "SELECT count(*) AS value FROM pg_stat_activity WHERE state LIKE 'idle in transaction%'", "every_secs": 300,
		"rule": "value", "value_column": nil, "compare": ">", "warning": 3.0, "critical": 10.0, "targets": "tags: env:prod"}
	names := []string{"idle_in_transaction"}
	checks := []Row{idle}
	trig := g.is("onprem-erp01")
	if trig {
		names = append(names, "disabled_triggers")
		checks = append(checks, Row{"kind": "check", "check_name": "disabled_triggers", "description": "user triggers that are disabled",
			"sql": "SELECT n.nspname AS schema, c.relname AS table, t.tgname AS trigger FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid " +
				"JOIN pg_namespace n ON n.oid = c.relnamespace WHERE NOT t.tgisinternal AND t.tgenabled = 'D' ORDER BY 1, 2, 3",
			"every_secs": 3600, "rule": "rows", "value_column": nil, "compare": ">", "warning": 0.0, "critical": nil,
			"targets": "instances: onprem-erp01"})
	}
	out := append([]Row{{"kind": "state", "checks": names}}, checks...)

	if first || t.Minute()%5 == 0 {
		v := math.Floor(3 * curve(t) * g.Spec.Load * noise(g.Spec.Name+"|idle", t))
		if g.is("aurora-crm01") {
			if since := t.Sub(g.end.Add(-2 * time.Hour)); since > 0 { // the climb holds at its top past the anchor (the live demo keeps crm01 critical)
				v += math.Round(14 * math.Min(since.Hours(), 2) / 2)
			}
		}
		st := "ok"
		switch {
		case v > 10:
			st = "critical"
		case v > 3:
			st = "warning"
		}
		out = append(out, Row{"kind": "result", "check_name": "idle_in_transaction", "status": st, "value": v, "row_count": 1,
			"columns": []string{"value"}, "rows": [][]any{{int64(v)}}, "rows_kept": true, "duration_ms": 3 + int64(noise(g.Spec.Name+"|idlems", t)*4)})
	}
	if trig && (first || t.Minute() == 0) {
		rows := [][]any{}
		if t.After(g.end.Add(-6 * time.Hour)) {
			rows = [][]any{{"erp", "invoice_line", "trg_invoice_total"}, {"erp", "stock_move", "trg_stock_audit"}}
		}
		st := "ok"
		if len(rows) > 0 {
			st = "warning"
		}
		out = append(out, Row{"kind": "result", "check_name": "disabled_triggers", "status": st, "value": float64(len(rows)),
			"row_count": len(rows), "columns": []string{"schema", "table", "trigger"}, "rows": rows, "rows_kept": true,
			"duration_ms": 6 + int64(noise(g.Spec.Name+"|trgms", t)*6)})
	}
	return out
}
