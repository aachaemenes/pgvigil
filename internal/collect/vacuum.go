package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// Vacuuming, two collections:
//
// vacuum (every minute): what vacuums and analyzes now - pg_stat_progress_vacuum and
// pg_stat_progress_analyze with their sessions from pg_stat_activity (the table, phase, heap blocks
// scanned of total, dead tuples found, elapsed, the wait), every autovacuum worker, and a VACUUM or
// ANALYZE still waiting for its table lock (the progress views list a run only once it holds the lock);
// one summary row (autovacuum on, workers running of the maximum); and the xmin holders that are not
// sessions (replication slots, prepared transactions, standbys with hot_standby_feedback). The
// repository folds the samples into a run history.
//
// vacuum_tables (hourly): per database the tables autovacuum should be reaching - dead rows against the
// threshold computed from the table's reloptions and the server settings (and the insert threshold,
// PG13+, and the analyze threshold), autovacuum_enabled, never or long unvacuumed, near a forced freeze;
// the per-database counts; the settings; and the wraparound row of every database (age(datfrozenxid),
// mxid_age(datminmxid)).
//
// Both read only catalog and statistics views (pg_monitor); neither opens a relation, so neither waits
// on a table lock.
type vacuumCollector struct{}
type vacuumTablesCollector struct{}

func init() {
	Register(vacuumCollector{})
	Register(vacuumTablesCollector{})
}

// vacuumTablesTopN caps the tables listed per database; vacuumTablesMaxDatabases the databases read per
// run (vars: tests lower them).
var (
	vacuumTablesTopN         = 50
	vacuumTablesMaxDatabases = 50
)

func vacuumApplies(info platform.Info) (bool, string) {
	if info.ServerVersionNum < 130000 {
		return false, "needs PostgreSQL 13 or later (pg_stat_progress_analyze)"
	}
	if info.IsReplica {
		return false, "a standby does not vacuum: its primary's read covers it"
	}
	return true, ""
}

func (vacuumCollector) Name() string                           { return "vacuum" }
func (vacuumCollector) DefaultInterval() time.Duration         { return time.Minute }
func (vacuumCollector) Applies(i platform.Info) (bool, string) { return vacuumApplies(i) }

// vacuumRunningSQL: %[1]s dead tuples, %[2]s max dead tuples, %[3]s indexes_total, %[4]s indexes_processed
// (the columns PG17 renamed or added), %[5]s the masked query text.
const vacuumRunningSQL = `
SELECT CASE WHEN v.pid IS NOT NULL THEN 'vacuum' WHEN an.pid IS NOT NULL THEN 'analyze'
            WHEN a.query ~* '^\s*vacuum' THEN 'vacuum' WHEN a.query ~* '^\s*analy[sz]e' THEN 'analyze'
            WHEN a.query ~* '^autovacuum: VACUUM' THEN 'vacuum' WHEN a.query ~* '^autovacuum: ANALYZE' THEN 'analyze'
            ELSE 'worker' END AS kind,
       a.pid, a.datid::bigint AS dbid, a.datname::text AS datname, coalesce(v.relid, an.relid, w.relation)::bigint AS relid,
       coalesce((SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE a.datname = current_database() AND c.oid = coalesce(v.relid, an.relid, w.relation)),
                substring(a.query FROM '^autovacuum: (?:VACUUM ANALYZE|VACUUM|ANALYZE) ([^ ]+)'))::text AS table_name,
       a.backend_type::text AS backend_type, a.backend_type = 'autovacuum worker' AS is_auto,
       coalesce(a.query ~ 'to prevent wraparound', false) AS is_wraparound,
       coalesce(v.phase, an.phase)::text AS phase,
       v.heap_blks_total, v.heap_blks_scanned, v.heap_blks_vacuumed, v.index_vacuum_count,
       %[3]s AS indexes_total, %[4]s AS indexes_processed, %[1]s AS dead_tuples, %[2]s AS max_dead_tuples,
       an.sample_blks_total, an.sample_blks_scanned,
       a.xact_start, a.query_start, extract(epoch FROM clock_timestamp() - a.query_start)::int AS elapsed_secs,
       a.wait_event_type::text AS wait_event_type, a.wait_event::text AS wait_event,
       CASE WHEN a.wait_event_type = 'Lock' THEN pg_blocking_pids(a.pid) END AS blocking_pids,
       left(%[5]s, 500) AS query
  FROM pg_stat_activity a
  LEFT JOIN pg_stat_progress_vacuum v ON v.pid = a.pid
  LEFT JOIN pg_stat_progress_analyze an ON an.pid = a.pid
  -- a run waiting for its table lock is not in the progress views yet: its table is the relation it waits on
  LEFT JOIN LATERAL (SELECT l.relation FROM pg_locks l
                      WHERE l.pid = a.pid AND NOT l.granted AND l.locktype = 'relation' LIMIT 1) w ON a.wait_event_type = 'Lock'
 WHERE a.pid <> pg_backend_pid()
   AND (a.backend_type = 'autovacuum worker' OR v.pid IS NOT NULL OR an.pid IS NOT NULL
        OR (a.state = 'active' AND a.wait_event_type = 'Lock' AND a.query ~* '^\s*(vacuum|analy[sz]e)'))`

const vacuumSummarySQL = `
SELECT 'summary' AS kind, current_setting('autovacuum') AS autovacuum, current_setting('track_counts') AS track_counts,
       current_setting('autovacuum_max_workers')::int AS max_workers,
       (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'autovacuum worker')::int AS workers_running`

// vacuumHoldersSQL: the xmin holders that are not sessions (the sessions come from the activity samples).
const vacuumHoldersSQL = `
SELECT 'holder' AS kind, 'slot' AS holder, s.slot_name::text AS name, s.database::text AS datname,
       age(s.xmin)::bigint AS xmin_age, age(s.catalog_xmin)::bigint AS catalog_xmin_age, s.active,
       NULL::timestamptz AS since, s.slot_type::text || CASE WHEN s.active THEN ', active' ELSE ', inactive' END AS detail
  FROM pg_replication_slots s
 WHERE s.xmin IS NOT NULL OR s.catalog_xmin IS NOT NULL
UNION ALL
SELECT 'holder', 'prepared', p.gid, p.database::text, age(p.transaction)::bigint, NULL, false, p.prepared,
       'prepared by ' || p.owner::text
  FROM pg_prepared_xacts p
UNION ALL
SELECT 'holder', 'standby', coalesce(nullif(r.application_name, ''), host(r.client_addr), r.pid::text), NULL,
       age(r.backend_xmin)::bigint, NULL, true, r.backend_start, 'hot_standby_feedback from ' || coalesce(host(r.client_addr), 'local')
  FROM pg_stat_replication r
 WHERE r.backend_xmin IS NOT NULL`

func (vacuumCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	cols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_progress_vacuum")
	if err != nil {
		return nil, err
	}
	dead := col(cols, "v", "num_dead_tuples", "bigint")
	if cols["num_dead_item_ids"] {
		dead = "v.num_dead_item_ids"
	}
	q := fmt.Sprintf(vacuumRunningSQL, dead, col(cols, "v", "max_dead_tuples", "bigint"),
		col(cols, "v", "indexes_total", "bigint"), col(cols, "v", "indexes_processed", "bigint"), maskSQL("a.query"))
	out := []Row{}
	for _, part := range []struct{ name, sql string }{{"summary", vacuumSummarySQL}, {"running", q}, {"holders", vacuumHoldersSQL}} {
		r, err := conn.Query(ctx, part.sql)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", part.name, err)
		}
		rows, err := rowsToMaps(r)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", part.name, err)
		}
		out = append(out, rows...)
	}
	return out, nil
}

func (vacuumTablesCollector) Name() string                           { return "vacuum_tables" }
func (vacuumTablesCollector) DefaultInterval() time.Duration         { return time.Hour }
func (vacuumTablesCollector) Applies(i platform.Info) (bool, string) { return vacuumApplies(i) }

func (vacuumTablesCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("vacuum_tables needs the instance config: %w", ErrSkip)
}

// vacuumSettingsSQL: the settings the thresholds come from. A setting a version lacks reads NULL
// (current_setting(name, true)).
const vacuumSettingsSQL = `
SELECT 'settings' AS kind, current_setting('autovacuum') AS autovacuum, current_setting('track_counts') AS track_counts,
       current_setting('autovacuum_max_workers')::int AS max_workers,
       (SELECT setting::int * CASE unit WHEN 'ms' THEN 0.001 WHEN 'min' THEN 60 ELSE 1 END FROM pg_settings WHERE name = 'autovacuum_naptime')::int AS naptime_secs,
       current_setting('autovacuum_vacuum_threshold')::float8 AS vacuum_threshold,
       current_setting('autovacuum_vacuum_scale_factor')::float8 AS vacuum_scale_factor,
       nullif(current_setting('autovacuum_vacuum_max_threshold', true), '')::float8 AS vacuum_max_threshold,
       nullif(current_setting('autovacuum_vacuum_insert_threshold', true), '')::float8 AS insert_threshold,
       nullif(current_setting('autovacuum_vacuum_insert_scale_factor', true), '')::float8 AS insert_scale_factor,
       current_setting('autovacuum_analyze_threshold')::float8 AS analyze_threshold,
       current_setting('autovacuum_analyze_scale_factor')::float8 AS analyze_scale_factor,
       current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
       current_setting('autovacuum_multixact_freeze_max_age')::bigint AS mxid_freeze_max_age,
       nullif(current_setting('vacuum_failsafe_age', true), '')::bigint AS failsafe_age,
       (SELECT CASE WHEN setting::int < 0 THEN current_setting('vacuum_cost_limit')::int ELSE setting::int END
          FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_limit') AS cost_limit,
       (SELECT CASE WHEN setting::float8 < 0 THEN current_setting('vacuum_cost_delay')::float8 ELSE setting::float8 END
          FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_delay') AS cost_delay_ms,
       (SELECT setting::int FROM pg_settings WHERE name = 'log_autovacuum_min_duration') AS log_min_duration_ms`

const vacuumWrapSQL = `
SELECT 'wrap' AS kind, d.oid::bigint AS dbid, d.datname::text AS datname, d.datallowconn AS allow_conn,
       age(d.datfrozenxid)::bigint AS xid_age, mxid_age(d.datminmxid)::bigint AS mxid_age
  FROM pg_database d`

// vacuumThresholdCTE computes each user table's autovacuum thresholds as autovacuum does
// (relation_needs_vacanalyze): base + scale factor x reltuples, the table's reloption over the server
// setting, the vacuum threshold capped by autovacuum_vacuum_max_threshold (PG18+), reltuples -1 (never
// vacuumed or analyzed, PG14+) as 0. PG18 also scales the insert threshold by the unfrozen fraction of the
// table (pg_class.relallfrozen); %[3]s is that fraction, 1 before PG18.
// %[1]s = n_ins_since_vacuum (PG13+ column, or NULL).
const vacuumThresholdCTE = `
WITH g AS (
  SELECT current_setting('autovacuum_vacuum_threshold')::float8 AS vt, current_setting('autovacuum_vacuum_scale_factor')::float8 AS vs,
         coalesce(nullif(current_setting('autovacuum_vacuum_max_threshold', true), '')::float8, -1) AS vmax,
         coalesce(nullif(current_setting('autovacuum_vacuum_insert_threshold', true), '')::float8, -1) AS it,
         coalesce(nullif(current_setting('autovacuum_vacuum_insert_scale_factor', true), '')::float8, 0) AS isf,
         current_setting('autovacuum_analyze_threshold')::float8 AS at, current_setting('autovacuum_analyze_scale_factor')::float8 AS asf,
         current_setting('autovacuum_freeze_max_age')::bigint AS fma
), t AS (
  SELECT c.oid, n.nspname, c.relname, c.relkind, greatest(c.reltuples, 0)::float8 AS rt, c.reltuples::float8 AS reltuples,
         %[3]s AS unfrozen,
         c.relfrozenxid, c.relminmxid,
         coalesce((SELECT jsonb_object_agg(o.option_name, o.option_value) FROM pg_options_to_table(c.reloptions) o
                    WHERE o.option_name LIKE 'autovacuum%%'), '{}'::jsonb) AS o,
         s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, %[1]s AS n_ins_since_vacuum,
         s.last_vacuum, s.last_autovacuum, s.last_analyze, s.last_autoanalyze, s.autovacuum_count, s.autoanalyze_count
    FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r', 'm')
), th AS (
  SELECT t.*,
         coalesce((t.o->>'autovacuum_enabled')::boolean, true) AS av_enabled,   -- the server's own boolean parser
         t.o <> '{}'::jsonb AS has_own,
         CASE WHEN coalesce((t.o->>'autovacuum_vacuum_max_threshold')::float8, g.vmax) >= 0
              THEN least(coalesce((t.o->>'autovacuum_vacuum_threshold')::float8, g.vt) + coalesce((t.o->>'autovacuum_vacuum_scale_factor')::float8, g.vs) * t.rt,
                         coalesce((t.o->>'autovacuum_vacuum_max_threshold')::float8, g.vmax))
              ELSE coalesce((t.o->>'autovacuum_vacuum_threshold')::float8, g.vt) + coalesce((t.o->>'autovacuum_vacuum_scale_factor')::float8, g.vs) * t.rt
         END AS vac_thr,
         CASE WHEN t.n_ins_since_vacuum IS NOT NULL AND coalesce((t.o->>'autovacuum_vacuum_insert_threshold')::float8, g.it) >= 0
              THEN coalesce((t.o->>'autovacuum_vacuum_insert_threshold')::float8, g.it) + coalesce((t.o->>'autovacuum_vacuum_insert_scale_factor')::float8, g.isf) * t.rt * t.unfrozen
         END AS ins_thr,
         coalesce((t.o->>'autovacuum_analyze_threshold')::float8, g.at) + coalesce((t.o->>'autovacuum_analyze_scale_factor')::float8, g.asf) * t.rt AS anl_thr,
         least(coalesce((t.o->>'autovacuum_freeze_max_age')::bigint, g.fma), g.fma) AS fma,
         age(t.relfrozenxid)::bigint AS xid_age, mxid_age(t.relminmxid)::bigint AS mxid_age
    FROM t CROSS JOIN g
), x AS (
  SELECT th.*, th.av_enabled AND th.n_dead_tup > th.vac_thr AS over_vac,
         th.av_enabled AND th.ins_thr IS NOT NULL AND th.n_ins_since_vacuum > th.ins_thr AS over_ins,
         th.av_enabled AND th.n_mod_since_analyze > th.anl_thr AS over_anl,
         th.last_vacuum IS NULL AND th.last_autovacuum IS NULL AND th.n_live_tup + th.n_dead_tup >= 1000 AS never_vac
    FROM th
)`

const vacuumDBSQL = vacuumThresholdCTE + `
SELECT 'db' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, count(*) AS user_tables,
       count(*) FILTER (WHERE over_vac) AS over_vacuum, count(*) FILTER (WHERE over_ins) AS over_insert,
       count(*) FILTER (WHERE over_anl) AS over_analyze, count(*) FILTER (WHERE NOT av_enabled) AS autovacuum_off,
       count(*) FILTER (WHERE never_vac) AS never_vacuumed
  FROM x`

// vacuumTablesSQL lists the tables of interest in two budgets of N each, so a long list of one kind never
// pushes out the other: the tables over a vacuum, insert or analyze threshold, the furthest over first; and
// the rest - past half a threshold (with 1,000 rows or more changed), autovacuum off, never vacuumed with
// 1,000 rows or more, no vacuum for 7 days with dead rows, or past 90 % of the freeze max age. %[2]d = N.
const vacuumTablesSQL = vacuumThresholdCTE + `, y AS (
  SELECT x.*, greatest(n_dead_tup / nullif(vac_thr, 0), coalesce(n_ins_since_vacuum / nullif(ins_thr, 0), 0),
                       n_mod_since_analyze / nullif(anl_thr, 0), xid_age::float8 / nullif(fma, 0)) AS score,
         over_vac OR coalesce(over_ins, false) OR over_anl AS is_over
    FROM x
), pick AS (
  (SELECT * FROM y WHERE is_over ORDER BY score DESC NULLS LAST LIMIT %[2]d)
  UNION ALL
  (SELECT * FROM y
    WHERE NOT is_over
      AND (NOT av_enabled OR never_vac
           OR (n_dead_tup >= 1000 AND n_dead_tup > 0.5 * vac_thr)
           OR (n_ins_since_vacuum >= 1000 AND n_ins_since_vacuum > 0.5 * ins_thr)
           OR (n_dead_tup > 0 AND greatest(last_vacuum, last_autovacuum) < now() - interval '7 days')
           OR xid_age > 0.9 * fma)
    ORDER BY score DESC NULLS LAST LIMIT %[2]d)
)
SELECT 'table' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, oid::bigint AS relid, nspname::text AS schema_name, relname::text AS table_name,
       relkind::text AS relkind, reltuples, n_live_tup, n_dead_tup, n_ins_since_vacuum, n_mod_since_analyze,
       round(vac_thr::numeric, 1)::float8 AS vac_threshold, round(ins_thr::numeric, 1)::float8 AS ins_threshold,
       round(anl_thr::numeric, 1)::float8 AS anl_threshold, av_enabled AS autovacuum_enabled, has_own AS has_own_settings,
       over_vac AS over_vacuum, coalesce(over_ins, false) AS over_insert, over_anl AS over_analyze,
       last_vacuum, last_autovacuum, last_analyze, last_autoanalyze, autovacuum_count, autoanalyze_count,
       xid_age, mxid_age, fma AS freeze_max_age
  FROM pick
 ORDER BY is_over DESC, score DESC NULLS LAST`

// RunInstance reads the settings and the wraparound rows on conn, then each connectable database's tables
// (the connected one on conn, the others on their own short connection), up to vacuumTablesMaxDatabases.
func (vacuumTablesCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	out := []Row{}
	for _, part := range []struct{ name, sql string }{{"settings", vacuumSettingsSQL}, {"wraparound", vacuumWrapSQL}} {
		r, err := conn.Query(ctx, part.sql)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", part.name, err)
		}
		rows, err := rowsToMaps(r)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", part.name, err)
		}
		out = append(out, rows...)
	}
	dbs, err := tablesDatabases(ctx, conn)
	if err != nil {
		return nil, err
	}
	insCol := "NULL::bigint"
	if cols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_user_tables"); err != nil {
		return nil, err
	} else if cols["n_ins_since_vacuum"] {
		insCol = "s.n_ins_since_vacuum"
	}
	// PG18: the insert threshold scales by the unfrozen fraction of the table
	unfrozen := "1::float8"
	if cols, err := viewColumns(ctx, conn, "pg_catalog.pg_class"); err != nil {
		return nil, err
	} else if cols["relallfrozen"] {
		unfrozen = "CASE WHEN c.relpages > 0 THEN 1 - least(c.relallfrozen, c.relpages)::float8 / c.relpages ELSE 1 END"
	}
	qd := fmt.Sprintf(vacuumDBSQL, insCol, 0, unfrozen)
	qt := fmt.Sprintf(vacuumTablesSQL, insCol, vacuumTablesTopN, unfrozen)
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	if len(dbs) > vacuumTablesMaxDatabases {
		out = append(out, Row{"kind": "collector_error", "source": "vacuum_tables",
			"message": fmt.Sprintf("%d databases: the first %d by name are read (vacuumTablesMaxDatabases)", len(dbs), vacuumTablesMaxDatabases)})
		dbs = dbs[:vacuumTablesMaxDatabases]
	}
	for _, db := range dbs {
		var rows []Row
		if db == cur {
			rows, err = vacuumTablesRead(ctx, conn, qd, qt)
		} else {
			rows, err = vacuumTablesReadOther(ctx, in, db, qd, qt)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, Row{"kind": "collector_error", "source": "vacuum_tables:" + db, "message": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}

func vacuumTablesRead(ctx context.Context, conn *pgx.Conn, qd, qt string) ([]Row, error) {
	r, err := conn.Query(ctx, qd)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	db, err := rowsToMaps(r)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	r, err = conn.Query(ctx, qt)
	if err != nil {
		return nil, fmt.Errorf("tables: %w", err)
	}
	t, err := rowsToMaps(r)
	if err != nil {
		return nil, fmt.Errorf("tables: %w", err)
	}
	return append(db, t...), nil
}

// vacuumTablesReadOther connects to another database with the instance's DSN and the collector's session
// settings, reads it, and closes the connection.
func vacuumTablesReadOther(ctx context.Context, in config.Instance, db, qd, qt string) ([]Row, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("dsn %q resolved to an empty string", in.DSNRaw)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.Database = db
	conn, err := connectCounted(ctx, in.Name, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		return nil, fmt.Errorf("session setup: %w", err)
	}
	return vacuumTablesRead(ctx, conn, qd, qt)
}
