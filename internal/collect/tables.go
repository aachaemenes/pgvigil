package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// tablesCollector is the hourly table health read, per database: the biggest tables with their
// size (heap, TOAST, indexes), live and dead rows, the visibility map's coverage, the last vacuum
// and analyze, the transaction-id age, and a bloat estimate from the planner statistics; plus one
// summary row per database (user tables, how many were never vacuumed or analyzed since the
// statistics reset). It answers "has vacuum reached the tables after a load" and "which table is
// bloated or close to a forced freeze" without a per-minute cost.
//
// pg_stat_user_tables and pg_class are per database, so the collector reads the connected
// database on its own connection and opens one short connection per other database the login
// may connect to (the instance DSN with its dbname replaced). A database that cannot be read
// gives a collector_error row and the others still import.
type tablesCollector struct{}

func init() { Register(tablesCollector{}) }

// tablesTopN is how many tables per database are read (the biggest by size); tablesMaxDatabases
// caps the databases read per run (vars: tests lower them).
var (
	tablesTopN         = 25
	tablesMaxDatabases = 50
)

func (tablesCollector) Name() string                   { return "tables" }
func (tablesCollector) DefaultInterval() time.Duration { return time.Hour }
func (tablesCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (tablesCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("tables needs the instance config: %w", ErrSkip)
}

// tablesDatabasesSQL lists the databases to read: connectable, not a template, CONNECT granted
// (a managed platform's own database, rdsadmin or azure_maintenance, refuses CONNECT and drops out).
const tablesDatabasesSQL = `
SELECT d.datname::text
  FROM pg_database d
 WHERE d.datallowconn AND NOT d.datistemplate AND has_database_privilege(d.datname, 'CONNECT')
 ORDER BY d.datname = current_database() DESC, d.datname`

// tablesDBSQL is the database's summary row (the after-load section of a slow-read diagnostic): user tables, how many
// carry no vacuum or analyze since the statistics reset, and the tables of 8 MB or more (1,000 pages)
// that were never vacuumed or have under half of their pages all-visible.
const tablesDBSQL = `
SELECT 'db' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname,
       (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()) AS stats_reset,
       count(*) AS user_tables,
       count(*) FILTER (WHERE s.last_vacuum IS NULL AND s.last_autovacuum IS NULL) AS never_vacuumed,
       count(*) FILTER (WHERE s.last_analyze IS NULL AND s.last_autoanalyze IS NULL) AS never_analyzed,
       count(*) FILTER (WHERE c.relpages >= 1000) AS big_tables,
       count(*) FILTER (WHERE c.relpages >= 1000 AND s.last_vacuum IS NULL AND s.last_autovacuum IS NULL) AS big_never_vacuumed,
       count(*) FILTER (WHERE c.relpages >= 1000 AND c.relallvisible < c.relpages * 0.5) AS big_under_half_visible,
       coalesce(sum(c.relpages) FILTER (WHERE c.relpages >= 1000), 0) AS big_pages,
       coalesce(sum(c.relallvisible) FILTER (WHERE c.relpages >= 1000), 0) AS big_visible_pages
  FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
 WHERE c.relkind IN ('r', 'm')`

// tablesCandidatesSQL is the shared head of the table read: the candidates come from the catalog (the
// biggest 4N by pages and the biggest 4N by row count: a table loaded and never vacuumed or analyzed still
// has relpages 0, but its insert counter moved), and "locked" are the candidates with an AccessExclusiveLock
// held or queued on the table, one of its indexes, its TOAST table or the TOAST index (a VACUUM FULL, an
// ALTER, a TRUNCATE, a REINDEX): the size functions open every one of those relations, so asking would wait
// behind that lock. %[1]s = n_ins_since_vacuum (PG13+), %[2]d = N.
const tablesCandidatesSQL = `
WITH s AS (
  SELECT s.relid, s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, %[1]s AS n_ins_since_vacuum,
         s.last_vacuum, s.last_autovacuum, s.last_analyze, s.last_autoanalyze,
         s.vacuum_count, s.autovacuum_count, s.analyze_count, s.autoanalyze_count, s.seq_scan, s.idx_scan
    FROM pg_stat_user_tables s
), cand AS (
  (SELECT c.oid FROM pg_class c JOIN s ON s.relid = c.oid WHERE c.relkind IN ('r', 'm')
    ORDER BY c.relpages DESC LIMIT 4 * %[2]d)
  UNION
  (SELECT c.oid FROM pg_class c JOIN s ON s.relid = c.oid WHERE c.relkind IN ('r', 'm')
    ORDER BY s.n_live_tup + s.n_dead_tup DESC LIMIT 4 * %[2]d)
), locked AS (
  SELECT x.oid FROM cand x JOIN pg_class c ON c.oid = x.oid
   WHERE EXISTS (SELECT 1 FROM pg_locks l
                  WHERE l.locktype = 'relation' AND l.mode = 'AccessExclusiveLock'
                    AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
                    AND (l.relation = x.oid
                         OR (c.reltoastrelid <> 0 AND l.relation = c.reltoastrelid)
                         OR l.relation IN (SELECT i.indexrelid FROM pg_index i
                                            WHERE i.indrelid = x.oid OR (c.reltoastrelid <> 0 AND i.indrelid = c.reltoastrelid))))
), free AS (
  SELECT x.oid FROM cand x WHERE x.oid NOT IN (SELECT oid FROM locked)
`

// tablesSkippedSQL names the candidates left out for a lock: the import keeps their last row present
// (not read this hour is not "left the top N").
const tablesSkippedSQL = tablesCandidatesSQL + `)
SELECT 'table_skipped' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       l.oid::bigint AS relid
  FROM locked l`

// tablesSQL reads the top N free candidates by total size. The bloat estimate is pg_gather's
// (gather_report.sql, after ioguix's pgsql-bloat-estimation): the expected heap pages from the live row
// count and the average row width in pg_stats, at the table's fillfactor (ioguix's est_tblpages_ff), plus
// the TOAST pages as they are (TOAST bloat is not estimated), against the heap and TOAST pages on disk. It
// needs SELECT on the table to see its pg_stats rows (stats_readable), and every live column to have
// statistics (a column added since the last ANALYZE would understate the row width: no estimate then).
const tablesSQL = tablesCandidatesSQL + `), sized AS (
  SELECT c.oid, c.relnamespace, c.relname, c.relkind, c.reltoastrelid, c.relpages, c.reltuples, c.relallvisible,
         c.relfrozenxid, c.relminmxid,
         coalesce((SELECT o.option_value::int FROM pg_options_to_table(c.reloptions) o WHERE o.option_name = 'fillfactor'), 100) AS fillfactor,
         (SELECT count(*) FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS ncols,
         coalesce(array_to_string(c.reloptions, ',') ~* '(^|,)autovacuum_enabled=(false|off|no|n|f|0)(,|$)', false) AS autovacuum_off,
         pg_total_relation_size(c.oid) AS total_bytes, pg_relation_size(c.oid) AS heap_bytes,
         pg_indexes_size(c.oid) AS index_bytes,
         CASE WHEN c.reltoastrelid <> 0 THEN pg_relation_size(c.reltoastrelid) ELSE 0 END AS toast_heap_bytes,
         CASE WHEN c.reltoastrelid <> 0 THEN pg_total_relation_size(c.reltoastrelid) ELSE 0 END AS toast_bytes
    FROM free f JOIN pg_class c ON c.oid = f.oid
   ORDER BY total_bytes DESC
   LIMIT %[2]d
), st AS (
  SELECT z.oid, count(*) AS attcount, bool_or(coalesce(p.null_frac, 0) > 0) AS any_null,
         sum((1 - coalesce(p.null_frac, 0)) * coalesce(p.avg_width, 0)) AS tpl_data_size
    FROM sized z
    JOIN pg_namespace n ON n.oid = z.relnamespace
    JOIN pg_stats p ON p.schemaname = n.nspname AND p.tablename = z.relname AND NOT p.inherited
   GROUP BY z.oid
), est AS (
  SELECT z.oid, st.attcount,
         CASE WHEN st.attcount > 0 AND st.attcount >= z.ncols AND s.n_live_tup > 0 THEN
           ceil(s.n_live_tup / ((current_setting('block_size')::numeric - 24) * z.fillfactor / 100 /
             (4 + h.hdr + st.tpl_data_size + 16
                - CASE WHEN h.hdr %% 8 = 0 THEN 8 ELSE h.hdr %% 8 END
                - CASE WHEN ceil(st.tpl_data_size)::int %% 8 = 0 THEN 8 ELSE ceil(st.tpl_data_size)::int %% 8 END)))
           + z.toast_heap_bytes / current_setting('block_size')::numeric
         END AS est_pages
    FROM sized z
    JOIN s ON s.relid = z.oid
    LEFT JOIN st ON st.oid = z.oid
    LEFT JOIN LATERAL (SELECT 23 + CASE WHEN st.any_null THEN (7 + st.attcount) / 8 ELSE 0 END AS hdr) h ON true
)
SELECT 'table' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, z.oid::bigint AS relid, n.nspname::text AS schema_name, z.relname::text AS table_name,
       z.relkind::text AS relkind, z.total_bytes, z.heap_bytes, z.toast_bytes, z.index_bytes,
       z.relpages::bigint AS relpages, z.reltuples::float8 AS reltuples, z.relallvisible::bigint AS relallvisible,
       s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, s.n_ins_since_vacuum,
       greatest(s.last_vacuum, s.last_autovacuum) AS last_vacuum, s.last_autovacuum,
       greatest(s.last_analyze, s.last_autoanalyze) AS last_analyze, s.last_autoanalyze,
       s.vacuum_count + s.autovacuum_count AS vacuums, s.analyze_count + s.autoanalyze_count AS analyzes,
       s.seq_scan, s.idx_scan,
       z.autovacuum_off, age(z.relfrozenxid)::bigint AS xid_age, mxid_age(z.relminmxid)::bigint AS mxid_age,
       has_table_privilege(z.oid, 'SELECT') AS stats_readable, coalesce(e.attcount, 0) AS stats_columns,
       e.est_pages::bigint AS est_pages,
       CASE WHEN e.est_pages IS NOT NULL AND (z.heap_bytes + z.toast_heap_bytes) > 0
            THEN greatest(0, (z.heap_bytes + z.toast_heap_bytes) - e.est_pages * current_setting('block_size')::numeric)::bigint END AS bloat_bytes,
       CASE WHEN e.est_pages IS NOT NULL AND (z.heap_bytes + z.toast_heap_bytes) > 0
            THEN round(greatest(0, 100 * (1 - e.est_pages * current_setting('block_size')::numeric / (z.heap_bytes + z.toast_heap_bytes)))::numeric, 1) END AS bloat_pct
  FROM sized z
  JOIN pg_namespace n ON n.oid = z.relnamespace
  JOIN s ON s.relid = z.oid
  LEFT JOIN est e ON e.oid = z.oid
 ORDER BY z.total_bytes DESC`

// RunInstance reads the connected database on conn and every other connectable database on its own
// connection, up to tablesMaxDatabases.
func (tablesCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
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
	q := fmt.Sprintf(tablesSQL, insCol, tablesTopN)
	qs := fmt.Sprintf(tablesSkippedSQL, insCol, tablesTopN)

	out := []Row{}
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	if len(dbs) > tablesMaxDatabases {
		out = append(out, Row{"kind": "collector_error", "source": "tables",
			"message": fmt.Sprintf("%d databases: the first %d by name are read (tablesMaxDatabases)", len(dbs), tablesMaxDatabases)})
		dbs = dbs[:tablesMaxDatabases]
	}
	for _, db := range dbs {
		var rows []Row
		if db == cur {
			rows, err = tablesRead(ctx, conn, q, qs)
		} else {
			rows, err = tablesReadOther(ctx, in, db, q, qs)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, Row{"kind": "collector_error", "source": "tables:" + db, "message": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}

func tablesDatabases(ctx context.Context, conn *pgx.Conn) ([]string, error) {
	rows, err := conn.Query(ctx, tablesDatabasesSQL)
	if err != nil {
		return nil, fmt.Errorf("databases: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// tablesRead runs the summary and the table read on one database's connection.
func tablesRead(ctx context.Context, conn *pgx.Conn, q, qs string) ([]Row, error) {
	r, err := conn.Query(ctx, tablesDBSQL)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	db, err := rowsToMaps(r)
	if err != nil {
		return nil, fmt.Errorf("summary: %w", err)
	}
	r, err = conn.Query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("tables: %w", err)
	}
	t, err := rowsToMaps(r)
	if err != nil {
		return nil, fmt.Errorf("tables: %w", err)
	}
	// the candidates left out for a lock: the import keeps their rows present. A lock taken between the
	// candidate pick and the size calls makes the read wait its lock_timeout and fail for this database,
	// which keeps every row of it as it was (a collector_error, not an absence)
	r, err = conn.Query(ctx, qs)
	if err != nil {
		return nil, fmt.Errorf("skipped tables: %w", err)
	}
	k, err := rowsToMaps(r)
	if err != nil {
		return nil, fmt.Errorf("skipped tables: %w", err)
	}
	db = append(db, t...)
	return append(db, k...), nil
}

// tablesReadOther connects to another database with the instance's DSN and the collector's session
// settings, reads it, and closes the connection.
func tablesReadOther(ctx context.Context, in config.Instance, db, q, qs string) ([]Row, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("dsn %q resolved to an empty string", in.DSNRaw)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.Database = db
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		return nil, fmt.Errorf("session setup: %w", err)
	}
	return tablesRead(ctx, conn, q, qs)
}
