package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// iostatsCollector reads pg_stat_io (PG16+) by backend type, object and context, the rows
// with any reads, writes or hits, and stores them as read; iostats_rate() takes the
// difference to the previous row over a window (the web UI passes it a lookback of three
// intervals for the first point's baseline; the function's own default is 15 minutes). It
// is the largest series pgvigil stores (most of what dbstats stored while it read it every
// minute: the README's Sizing section), so it is its own collection at 5 minutes;
// `schedules: iostats: 1m` restores the minute. The rows keep kind io, so import_dbstats
// takes them too (the demo's generator still sends them that way).
type iostatsCollector struct{}

func init() { Register(iostatsCollector{}) }

func (iostatsCollector) Name() string                   { return "iostats" }
func (iostatsCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (iostatsCollector) Applies(info platform.Info) (bool, string) {
	if !info.HasPgStatIO {
		return false, "pg_stat_io needs PostgreSQL 16 or later"
	}
	return true, ""
}

func (iostatsCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	ioc, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_io")
	if err != nil {
		return nil, err
	}
	ioSQL := fmt.Sprintf(`
SELECT 'io' AS kind, i.backend_type, i.object, i.context, i.stats_reset,
       i.reads, %s AS read_bytes, i.read_time, i.writes, %s AS write_bytes, i.write_time, i.writebacks, i.writeback_time,
       i.extends, %s AS extend_bytes, i.extend_time, %s AS op_bytes, i.hits, i.evictions, i.reuses, i.fsyncs, i.fsync_time
  FROM pg_stat_io i
 WHERE i.reads IS NOT NULL OR i.writes IS NOT NULL OR i.hits IS NOT NULL`,
		col(ioc, "i", "read_bytes", "numeric"), col(ioc, "i", "write_bytes", "numeric"),
		col(ioc, "i", "extend_bytes", "numeric"), col(ioc, "i", "op_bytes", "bigint"))
	rows, err := conn.Query(ctx, ioSQL)
	if err != nil {
		return nil, fmt.Errorf("pg_stat_io: %w", err)
	}
	return rowsToMaps(rows)
}
