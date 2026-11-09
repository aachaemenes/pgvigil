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

// statementsTopN bounds one snapshot. Statements outside the top set still get a
// correct rate later: each delta row carries its own interval since the last
// time that statement was seen.
const statementsTopN = 500

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

	sql := fmt.Sprintf(`
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
       s.query
  FROM %[7]s.pg_stat_statements s
  LEFT JOIN pg_database d ON d.oid = s.dbid
  LEFT JOIN pg_roles r    ON r.oid = s.userid
 WHERE s.queryid IS NOT NULL
 ORDER BY s.total_exec_time DESC
 LIMIT %[8]d`, toplevel, readTime, writeTime, tempReadTime, tempWriteTime, walBytes, quoteIdent(schema), statementsTopN)

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
		err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT dealloc, stats_reset FROM %s.pg_stat_statements_info`, quoteIdent(schema))).Scan(&dealloc, &statsReset)
		if err == nil {
			out = append(out, Row{"kind": "info", "dealloc": dealloc, "stats_reset": statsReset})
		}
	}
	return out, nil
}

// quoteIdent double-quotes an identifier (schema names from the catalog).
func quoteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }
