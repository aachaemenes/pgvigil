package collect

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// statementsCollector reads pg_stat_statements (cumulative since its last reset)
// every five minutes. The repository keeps the last cumulative row per statement
// and stores the difference, so the stored rows are "what ran in this interval",
// with a reset (pg_stat_statements_reset, a restart) detected per row.
//
// Column names differ by extension version (PG17 renamed blk_read_time to
// shared_blk_read_time; toplevel arrived with PG14), so the query is built from
// the columns the installed view actually has, not from the server version.
type statementsCollector struct{}

func init() { Register(statementsCollector{}) }

func (statementsCollector) Name() string                   { return "statements" }
func (statementsCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (statementsCollector) Applies(info platform.Info) (bool, string) {
	if !info.HasPgStatStmts {
		return false, "pg_stat_statements is not installed in the connected database"
	}
	return true, ""
}

// statementsTopN bounds one snapshot: the top set by total time, plus the top
// set by calls so frequent cheap statements are not lost. A statement outside
// both sets keeps its last cumulative row in the repository; when it returns,
// its delta carries the whole gap as interval_secs, and the repository's
// top_statements scales such a delta by its share inside the asked window.
const (
	statementsTopN     = 500
	statementsTopCalls = 200
	// statementsTextMax caps the text sent per statement; the repository keeps
	// only the first text it sees per queryid, so resending the whole text of
	// 500 statements every interval buys nothing and can run to hundreds of MB.
	statementsTextMax = 16384
)

func (statementsCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	var schema string
	err := conn.QueryRow(ctx, `SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_stat_statements'`).Scan(&schema)
	if err != nil {
		return nil, fmt.Errorf("pg_stat_statements schema: %w", err)
	}
	cols := map[string]bool{}
	rows, err := conn.Query(ctx, `SELECT a.attname FROM pg_attribute a WHERE a.attrelid = ($1 || '.pg_stat_statements')::regclass AND a.attnum > 0 AND NOT a.attisdropped`, quoteIdent(schema))
	if err != nil {
		return nil, fmt.Errorf("pg_stat_statements columns: %w", err)
	}
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			rows.Close()
			return nil, err
		}
		cols[c] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	pick := func(want, fallback string) string {
		if cols[want] {
			return "s." + want
		}
		return fallback
	}
	readTime := pick("shared_blk_read_time", pick("blk_read_time", "0::float8"))
	writeTime := pick("shared_blk_write_time", pick("blk_write_time", "0::float8"))
	toplevel := pick("toplevel", "true")
	walBytes := pick("wal_bytes", "0::numeric")
	tempReadTime := pick("temp_blk_read_time", "0::float8")
	tempWriteTime := pick("temp_blk_write_time", "0::float8")
	// task 155 (K11.01): planning, JIT, WAL records and full-page images, workers, local blocks and generic / custom
	// plan counts, each NULL where the installed view lacks it (plans and wal_* from 1.8 / PG13, jit_* from 1.10 /
	// PG15, jit_deform_* from 1.11 / PG17, wal_buffers_full and parallel_workers_* from 1.12 / PG18; generic_plan_calls
	// and custom_plan_calls are not in 1.12 and are read where a later version has them)
	depth := []string{}
	for _, c := range []struct{ col, as, typ string }{
		{"plans", "plans", "bigint"}, {"total_plan_time", "total_plan_ms", "float8"},
		{"local_blks_hit", "local_blks_hit", "bigint"}, {"local_blks_read", "local_blks_read", "bigint"},
		{"local_blks_dirtied", "local_blks_dirtied", "bigint"}, {"local_blks_written", "local_blks_written", "bigint"},
		{"wal_records", "wal_records", "bigint"}, {"wal_fpi", "wal_fpi", "bigint"}, {"wal_buffers_full", "wal_buffers_full", "bigint"},
		{"jit_functions", "jit_functions", "bigint"}, {"jit_generation_time", "jit_generation_ms", "float8"},
		{"jit_inlining_count", "jit_inlining_count", "bigint"}, {"jit_inlining_time", "jit_inlining_ms", "float8"},
		{"jit_optimization_count", "jit_optimization_count", "bigint"}, {"jit_optimization_time", "jit_optimization_ms", "float8"},
		{"jit_emission_count", "jit_emission_count", "bigint"}, {"jit_emission_time", "jit_emission_ms", "float8"},
		{"jit_deform_count", "jit_deform_count", "bigint"}, {"jit_deform_time", "jit_deform_ms", "float8"},
		{"parallel_workers_to_launch", "parallel_workers_to_launch", "bigint"}, {"parallel_workers_launched", "parallel_workers_launched", "bigint"},
		{"generic_plan_calls", "generic_plan_calls", "bigint"}, {"custom_plan_calls", "custom_plan_calls", "bigint"},
	} {
		depth = append(depth, pick(c.col, "NULL::"+c.typ)+" AS "+c.as)
	}

	// The view is read ONCE (a materialized CTE) and both top sets are picked from that read. Two
	// scans of pg_stat_statements see different counters for a statement that ran in between, UNION
	// then keeps both versions of one (dbid, userid, queryid, toplevel) and import_statements' upsert
	// into statements_current fails on the second ("cannot affect row a second time"), losing the
	// whole cycle; seen on a busy target polled every 90 s.
	sql := fmt.Sprintf(`
WITH pss AS MATERIALIZED (SELECT * FROM %[7]s.pg_stat_statements WHERE queryid IS NOT NULL),
picked AS (
  (SELECT * FROM pss ORDER BY total_exec_time DESC LIMIT %[8]d)
  UNION
  (SELECT * FROM pss ORDER BY calls DESC LIMIT %[9]d)
)
SELECT 'stmt'                         AS kind,
       s.dbid::bigint                 AS dbid,
       d.datname::text                AS datname,
       s.userid::bigint               AS userid,
       r.rolname::text                AS usename,
       s.queryid                      AS queryid,
       %[1]s                          AS toplevel,
       s.calls,
       s.total_exec_time              AS total_exec_ms,
       s.rows,
       s.shared_blks_hit, s.shared_blks_read, s.shared_blks_dirtied, s.shared_blks_written,
       s.temp_blks_read, s.temp_blks_written,
       %[2]s                          AS blk_read_ms,
       %[3]s                          AS blk_write_ms,
       %[4]s                          AS temp_read_ms,
       %[5]s                          AS temp_write_ms,
       %[6]s                          AS wal_bytes,
       %[11]s,
       %[10]s                         AS query
  FROM picked s
  LEFT JOIN pg_database d ON d.oid = s.dbid
  LEFT JOIN pg_roles r    ON r.oid = s.userid`, toplevel, readTime, writeTime, tempReadTime, tempWriteTime, walBytes, quoteIdent(schema), statementsTopN, statementsTopCalls, maskSQL(fmt.Sprintf("left(s.query, %d)", statementsTextMax)),
		strings.Join(depth, ",\n       "))

	srows, err := conn.Query(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("pg_stat_statements: %w", err)
	}
	out, err := rowsToMaps(srows)
	if err != nil {
		return nil, err
	}

	// the extension's own bookkeeping (PG14+): dealloc count and the last reset
	if cols["toplevel"] {
		var dealloc *int64
		var statsReset *time.Time
		// a failure here is a failure of the collection: a cycle without the info row would make
		// the repository treat every statement as reset on the next cycle
		if err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT dealloc, stats_reset FROM %s.pg_stat_statements_info`, quoteIdent(schema))).Scan(&dealloc, &statsReset); err != nil {
			return nil, fmt.Errorf("pg_stat_statements_info: %w", err)
		}
		out = append(out, Row{"kind": "info", "dealloc": dealloc, "stats_reset": statsReset})
	}
	return out, nil
}

// quoteIdent double-quotes an identifier (schema names from the catalog).
func quoteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }
