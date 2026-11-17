package web

import (
	"net/http"
	"time"
)

// The Vacuum tab: GET /api/vacuum?instance=<id>[&from=&to=] (Server.Vacuum). The history covers the window,
// never less than the last 7 days to its end.

// VacuumOverviewCheckSQL is the overview's "vacuum" check (the Summary column Vacuum): the rows of
// pgvigil.vacuum_checks for the active instances.
const VacuumOverviewCheckSQL = `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.vacuum_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`

// sqlVacuumState: the autovacuum state and settings, with the age of the minute read.
const sqlVacuumState = `
SELECT s.*, extract(epoch FROM now() - s.snapshot_at)::int AS read_secs_ago
  FROM pgvigil.vacuum_state s
 WHERE s.instance_id = $1`

// sqlVacuumRunning: running now (the view names a table the collector could not from the hourly reads).
const sqlVacuumRunning = `
SELECT r.kind, r.pid, r.datname,
       coalesce(r.table_name, 'relid ' || r.relid::text) AS table_name,
       r.is_auto, r.is_wraparound, coalesce(r.phase, CASE WHEN r.wait_event_type = 'Lock' THEN 'waiting for its lock' END) AS phase,
       r.heap_blks_total, r.heap_blks_scanned, r.scanned_pct, r.heap_blks_vacuumed, r.index_vacuum_count,
       r.indexes_total, r.indexes_processed, r.dead_tuples, r.sample_blks_total, r.sample_blks_scanned,
       r.elapsed_secs, r.wait_event_type, r.wait_event, r.blocking_pids, r.query AS "query@stmt", r.snapshot_at
  FROM pgvigil.vacuum_running r
 WHERE r.instance_id = $1
 ORDER BY r.kind = 'worker', r.elapsed_secs DESC NULLS LAST`

// sqlVacuumTables: the tables of interest, the furthest over a threshold first.
const sqlVacuumTables = `
SELECT t.datname, t.schema_name, t.table_name, t.n_live_tup, t.n_dead_tup, t.vac_threshold, t.dead_ratio,
       t.n_ins_since_vacuum, t.ins_threshold, t.ins_ratio, t.n_mod_since_analyze, t.anl_threshold, t.anl_ratio,
       t.over_vacuum, t.over_insert, t.over_analyze, t.hours_over, t.autovacuum_enabled, t.has_own_settings,
       t.last_vacuum, t.last_autovacuum, t.last_analyze, t.last_autoanalyze, t.autovacuum_count, t.autoanalyze_count,
       t.xid_age, t.mxid_age, t.freeze_max_age, t.freeze_pct, t.snapshot_at
  FROM pgvigil.vacuum_table_state t
 WHERE t.instance_id = $1
 ORDER BY (t.over_vacuum OR t.over_insert) DESC, t.hours_over DESC NULLS LAST,
          greatest(t.dead_ratio, coalesce(t.ins_ratio, 0), t.anl_ratio) DESC NULLS LAST`

const sqlVacuumWraparound = `
SELECT w.datname, w.allow_conn, w.xid_age, w.xid_freeze_pct, w.mxid_age, w.mxid_freeze_pct, w.xid_horizon_pct,
       w.freeze_max_age, w.failsafe_age, w.user_tables, w.over_vacuum, w.over_insert, w.over_analyze, w.autovacuum_off,
       w.never_vacuumed, w.tables_at, w.snapshot_at
  FROM pgvigil.vacuum_wraparound w
 WHERE w.instance_id = $1
 ORDER BY w.xid_age DESC NULLS LAST, w.datname`

// sqlVacuumHeadroom is PerformanceMonitor's Per-Database Headroom (map-pm-web.tsv:238; server-tabs.js
// PG_WRAPAROUND_COLUMNS): per database the XIDs and the MultiXacts left before the server stops assigning them (2^31
// less PostgreSQL 14's 3 million stop margin, as its collector's ladder), the share of the way to the wrap and to the
// forced (emergency) vacuum, the window's peak xid age from the size history (database_sizes, the page's own window)
// and whether freezing keeps up - the age now below that peak (PerformanceMonitor's rule; equal = only climbing).
const sqlVacuumHeadroom = `
SELECT w.datname, w.xid_age,
       greatest(0, 2147483648 - 3000000 - w.xid_age) AS xids_left,
       round(100.0 * w.xid_age / 2147483648, 2) AS pct_wrap,
       w.xid_freeze_pct AS pct_emergency,
       greatest(w.xid_age, p.peak) AS peak_age,
       CASE WHEN p.peak IS NULL OR w.xid_age IS NULL THEN NULL ELSE w.xid_age < p.peak END AS keeping_up,
       w.mxid_age, greatest(0, 2147483648 - 3000000 - w.mxid_age) AS mxids_left,
       round(100.0 * w.mxid_age / 2147483648, 2) AS pct_mx_wrap,
       w.mxid_freeze_pct AS pct_mx_emergency, w.allow_conn, w.snapshot_at
  FROM pgvigil.vacuum_wraparound w
  LEFT JOIN (SELECT s.datname, max(s.xid_age) AS peak
               FROM pgvigil.database_sizes s
              WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
              GROUP BY s.datname) p ON p.datname = w.datname
 WHERE w.instance_id = $1
 ORDER BY greatest(w.xid_age, coalesce(w.mxid_age, 0)) DESC NULLS LAST, w.datname`

const sqlVacuumHolders = `
SELECT h.holder AS "holder@holder", h.name, h.datname, h.xmin_age, h.catalog_xmin_age, h.active, h.since, h.detail AS "detail@holderdetail", h.snapshot_at
  FROM pgvigil.vacuum_xmin_holders h
 WHERE h.instance_id = $1
 ORDER BY greatest(h.xmin_age, h.catalog_xmin_age) DESC NULLS LAST
 LIMIT 20`

const sqlVacuumHistory = `SELECT * FROM pgvigil.vacuum_history($1, $2, $3) /* text: detail=stmt */`

const sqlVacuumChecks = `
SELECT c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.vacuum_checks c
 WHERE c.instance_id = $1
 ORDER BY CASE c.severity WHEN 'critical' THEN 0 ELSE 1 END, c.check_name, c.object`

// Vacuum serves the Vacuum tab of one instance.
func (s *Server) Vacuum(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	pageFrom := from // the page's own window: the headroom's peak age (the history below reads at least a week)
	if week := to.Add(-7 * 24 * time.Hour); week.Before(from) {
		from = week
	}
	s.multi(w, r, []part{
		{"state", sqlVacuumState, []any{id}},
		{"checks", sqlVacuumChecks, []any{id}},
		{"running", sqlVacuumRunning, []any{id}},
		{"tables", sqlVacuumTables, []any{id}},
		{"wraparound", sqlVacuumWraparound, []any{id}},
		{"headroom", sqlVacuumHeadroom, []any{id, pageFrom, to}},
		{"holders", sqlVacuumHolders, []any{id}},
		{"history", sqlVacuumHistory, []any{id, from, to}},
	})
}
