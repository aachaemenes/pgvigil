package demo

import (
	"fmt"
	"time"
)

// bufferCacheDemoRows: hourly (first || t.Minute() == 0)
func (g *Gen) bufferCacheDemoRows(t time.Time) []Row {
	if g.Spec.Name != "onprem-erp01" {
		return []Row{{"kind": "total", "status": "not available",
			"reason": "pg_buffercache is not installed in the connected database (an opt-in: CREATE EXTENSION pg_buffercache; pg_monitor then reads it)"}}
	}
	const total = 524288 // 4 GB of 8 kB pages
	used := int64(float64(total) * (0.95 + 0.04*curve(t)))
	out := []Row{{"kind": "total", "status": "ok", "reason": nil, "total_buffers": total, "used_buffers": used,
		"dirty_buffers": int64(float64(used) * (0.02 + 0.05*curve(t))), "block_size": 8192}}
	rels := []struct {
		schema, name, kind string
		share, dirty       float64
		usage              float64
	}{
		{"public", "orders", "r", 0.41, 0.06, 3.8},
		{"public", "order_lines", "r", 0.18, 0.04, 2.9},
		{"public", "orders_pkey", "i", 0.09, 0.01, 4.6},
		{"public", "order_lines_order_id_idx", "i", 0.07, 0.01, 4.1},
		{"public", "customers", "r", 0.05, 0.00, 3.2},
		{"public", "invoices", "r", 0.04, 0.02, 1.7},
		{"pg_toast", "pg_toast_16702", "t", 0.03, 0.00, 1.1},
		{"public", "audit_log", "r", 0.02, 0.09, 0.6},
	}
	for i, r := range rels {
		b := int64(float64(used) * r.share * (0.97 + 0.06*noise(fmt.Sprintf("%s|buf|%d", g.Spec.Name, i), t)))
		out = append(out, Row{"kind": "rel", "datname": g.Spec.DBs[0], "schemaname": r.schema, "relname": r.name, "relkind": r.kind,
			"relfilenode": int64(16702 + i*3), "buffers": b, "dirty": int64(float64(b) * r.dirty), "usage_avg": r.usage,
			"usage_hot": int64(float64(b) * r.usage / 5)})
	}
	// a relation of another database: named by its database and file node only
	out = append(out, Row{"kind": "rel", "datname": "postgres", "schemaname": nil, "relname": nil, "relkind": nil,
		"relfilenode": int64(1259), "buffers": int64(float64(used) * 0.004), "dirty": int64(0), "usage_avg": 5.0, "usage_hot": int64(float64(used) * 0.004)})
	return out
}

// tempFilesDemoRows: hourly (first || t.Minute() == 0); the rollup reads the statements and logs rows already stored
func (g *Gen) tempFilesDemoRows(t time.Time) []Row {
	data := int64(180) << 30 // 180 GB
	if g.Spec.Name != "onprem-erp01" {
		data = int64(24) << 30
	}
	return []Row{{"kind": "state", "data_bytes": data + int64(float64(data)*0.0004*t.Sub(g.start).Hours()), "block_size": 8192}}
}

// erp01's temporary-file lines: add to logRows (gen.go) under `if s.Name == "onprem-erp01"`, through its ev helper, one file
// every 10 minutes from 01:00 to 03:00 (the nightly report), 200-260 MB each:
//
//	for at := prev.Truncate(10 * time.Minute).Add(10 * time.Minute); !at.After(t); at = at.Add(10 * time.Minute) {
//		if h := at.Hour(); h >= 1 && h < 3 {
//			size := 200<<20 + int64(noise(s.Name+"tmp", at)*60*(1<<20))
//			ev("temp_file", at, 2000+int(noise(s.Name+"tmppid", at)*60000), "app_"+s.App, g.stmts[stReport].text,
//				fmt.Sprintf("temporary file: path \"base/pgsql_tmp/pgsql_tmp%d.%d\", size %d", 2000+at.Minute(), at.Hour(), size), nil)
//		}
//	}
//
// (and the same lines to serverlogRows for an onprem erp01; erp01 is onprem in fleet.go, so serverlogRows is the one
// that runs: ev there has the same shape)

// poolerDemoRows: every step on crm01 (the collection is per minute)
func (g *Gen) poolerDemoRows(t time.Time) []Row {
	if g.Spec.Name != "aurora-crm01" {
		return nil
	}
	busy := t.After(g.end.Add(-12 * time.Minute))
	load := curve(t)
	crmActive := int64(10 + 25*load)
	poolSize := int64(20)
	svActive := crmActive
	if svActive > poolSize {
		svActive = poolSize
	}
	waiting, maxwait := int64(0), 0.0
	if busy {
		svActive, waiting, maxwait = poolSize, int64(4+noise("crm01pgb", t)*6), 1200+noise("crm01pgbw", t)*2400
	}
	out := []Row{
		{"kind": "state", "status": "ok", "reason": nil, "version": "PgBouncer 1.24.1"},
		{"kind": "database", "name": "crm", "host": "10.40.2.11", "port": int64(5432), "database": "crm", "pool_size": poolSize,
			"min_pool_size": int64(5), "reserve_pool": int64(0), "pool_mode": "transaction", "max_connections": int64(0),
			"current_connections": svActive + 2, "paused": false, "disabled": false},
		{"kind": "database", "name": "crm_reports", "host": "10.40.2.11", "port": int64(5432), "database": "crm", "pool_size": int64(5),
			"min_pool_size": int64(0), "reserve_pool": int64(2), "pool_mode": "session", "max_connections": int64(0),
			"current_connections": int64(2), "paused": false, "disabled": false},
		{"kind": "pool", "database": "crm", "user": "app_crm", "cl_active": crmActive + waiting, "cl_waiting": waiting,
			"sv_active": svActive, "sv_idle": poolSize - svActive, "sv_used": int64(0), "sv_tested": int64(0), "sv_login": int64(0),
			"maxwait_ms": maxwait, "pool_mode": "transaction", "pool_size": poolSize},
		{"kind": "pool", "database": "crm_reports", "user": "report_ro", "cl_active": int64(2), "cl_waiting": int64(0),
			"sv_active": int64(1), "sv_idle": int64(1), "sv_used": int64(0), "sv_tested": int64(0), "sv_login": int64(0),
			"maxwait_ms": 0.0, "pool_mode": "session", "pool_size": int64(5)},
		{"kind": "stats", "database": "crm", "xact_rate": int64(180 + 420*load), "query_rate": int64(900 + 2100*load),
			"avg_wait_us": int64(maxwait * 300), "avg_query_us": int64(2400 + 1800*load), "total_xact_count": int64(t.Sub(g.start).Seconds() * 300),
			"total_query_count": int64(t.Sub(g.start).Seconds() * 1500), "total_wait_us": int64(t.Sub(g.start).Seconds() * 40)},
		{"kind": "stats", "database": "crm_reports", "xact_rate": int64(2), "query_rate": int64(6), "avg_wait_us": int64(0),
			"avg_query_us": int64(850000), "total_xact_count": int64(t.Sub(g.start).Seconds() * 2), "total_query_count": int64(t.Sub(g.start).Seconds() * 6),
			"total_wait_us": int64(0)},
	}
	for _, kv := range [][2]string{{"pool_mode", "transaction"}, {"max_client_conn", "2000"}, {"default_pool_size", "20"},
		{"reserve_pool_size", "0"}, {"server_idle_timeout", "600"}, {"query_wait_timeout", "120"}, {"stats_period", "60"}} {
		out = append(out, Row{"kind": "config", "key": kv[0], "value": kv[1], "changeable": kv[0] != "pool_mode"})
	}
	return out
}
