package collect

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// statementsMonitorCollector is the statements source where pg_stat_statements is absent and Percona's
// pg_stat_monitor (PostgreSQL licence) is installed. pg_stat_monitor keeps statements in time buckets
// (pgsm_bucket_time, 60 s by default, pgsm_max_buckets of them, then the oldest is reused) instead of cumulative
// counters, so this read sends the FINISHED buckets it can see, summed per statement over the client, application
// and plan columns pg_stat_monitor splits them by; import_statements_monitor (0030) adds each bucket once to a
// running total per statement and hands the totals to the statements import, so the Statements tab, the top
// statements and the purge read the same rows as from pg_stat_statements.
//
// A bucket that rolled over between two reads is lost: the read runs every minute and pg_stat_monitor keeps ten
// buckets by default, so that takes a gap of ten minutes.
type statementsMonitorCollector struct{}

func init() { Register(statementsMonitorCollector{}) }

func (statementsMonitorCollector) Name() string                   { return "statements_monitor" }
func (statementsMonitorCollector) DefaultInterval() time.Duration { return time.Minute }
func (statementsMonitorCollector) Applies(info platform.Info) (bool, string) {
	if info.HasPgStatStmts {
		return false, "pg_stat_statements is installed: the statements collection reads it"
	}
	return true, ""
}

// statementsMonitorSQL: %[1]s the schema, %[2]s..%[5]s the IO time columns of this pg_stat_monitor version,
// %[6]s the WAL bytes column, %[7]s the masked query text, %[8]s the finished-bucket filter.
const statementsMonitorSQL = `
SELECT 'bucket'                       AS kind,
       m.bucket_start_time            AS bucket_start,
       m.dbid::bigint                 AS dbid,
       max(m.datname)::text           AS datname,
       m.userid::bigint               AS userid,
       max(m.username)::text          AS usename,
       m.queryid                      AS queryid,
       m.toplevel                     AS toplevel,
       sum(m.calls)::bigint           AS calls,
       sum(m.total_exec_time)         AS total_exec_ms,
       sum(m.rows)::bigint            AS rows,
       sum(m.shared_blks_hit)::bigint AS shared_blks_hit, sum(m.shared_blks_read)::bigint AS shared_blks_read,
       sum(m.shared_blks_dirtied)::bigint AS shared_blks_dirtied, sum(m.shared_blks_written)::bigint AS shared_blks_written,
       sum(m.temp_blks_read)::bigint AS temp_blks_read, sum(m.temp_blks_written)::bigint AS temp_blks_written,
       sum(%[2]s)                     AS blk_read_ms,
       sum(%[3]s)                     AS blk_write_ms,
       sum(%[4]s)                     AS temp_read_ms,
       sum(%[5]s)                     AS temp_write_ms,
       sum(%[6]s)                     AS wal_bytes,
       max(%[7]s)                     AS query
  FROM %[1]s.pg_stat_monitor m
 WHERE m.queryid IS NOT NULL AND m.dbid IS NOT NULL AND m.userid IS NOT NULL %[8]s
 GROUP BY m.bucket_start_time, m.dbid, m.userid, m.queryid, m.toplevel`

func (statementsMonitorCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	var schema string
	err := conn.QueryRow(ctx, `SELECT n.nspname::text FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_stat_monitor'`).Scan(&schema)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("neither pg_stat_statements nor pg_stat_monitor is installed in the connected database: %w", ErrSkip)
	}
	if err != nil {
		return nil, fmt.Errorf("pg_stat_monitor schema: %w", err)
	}
	cols, err := viewColumns(ctx, conn, quoteIdent(schema)+".pg_stat_monitor")
	if err != nil {
		return nil, err
	}
	pick := func(names ...string) string {
		for _, n := range names {
			if cols[n] {
				return "m." + n
			}
		}
		return "0"
	}
	done := ""
	if cols["bucket_done"] {
		done = "AND m.bucket_done"
	} else {
		// before bucket_done (pg_stat_monitor 1.x) a bucket is finished once a newer one exists
		done = fmt.Sprintf("AND m.bucket_start_time < (SELECT max(bucket_start_time) FROM %s.pg_stat_monitor)", quoteIdent(schema))
	}
	q := fmt.Sprintf(statementsMonitorSQL, quoteIdent(schema),
		pick("shared_blk_read_time", "blk_read_time"), pick("shared_blk_write_time", "blk_write_time"),
		pick("temp_blk_read_time"), pick("temp_blk_write_time"), pick("wal_bytes"),
		maskSQL(fmt.Sprintf("left(m.query, %d)", statementsTextMax)), done)
	rows, err := conn.Query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("pg_stat_monitor: %w", err)
	}
	return rowsToMaps(rows)
}
