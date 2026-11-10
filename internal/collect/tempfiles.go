package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// tempFilesCollector is the hourly temp-file read (task 62). The spills themselves are already in the repository:
// pg_stat_statements' temp_blks_read and temp_blks_written per interval (the statements collection's
// statements_delta) and the log readers' 'temporary file' lines (log_events kind temp_file, with the file's size in
// the detail). This read takes from the instance only what turns them into figures: the block size (temp blocks to
// bytes) and the size of its databases (the share a spill hour is of the data). Its import (import_temp_files, 0061)
// rolls the last hours up into temp_sample, per statement and per hour.
//
// The data size is the sum of pg_database_size over the databases that accept connections and that the login may size
// (CONNECT, or pg_read_all_stats, which pg_monitor holds): the databases collector's guard.
//
// Rows: one {kind: 'state', data_bytes, block_size}.
type tempFilesCollector struct{}

func init() { Register(tempFilesCollector{}) }

func (tempFilesCollector) Name() string                   { return "temp_files" }
func (tempFilesCollector) DefaultInterval() time.Duration { return time.Hour }
func (tempFilesCollector) Applies(platform.Info) (bool, string) {
	return true, "" // the statements and logs collections say on their own whether their halves are there
}

func (tempFilesCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	var blockSize int64
	if err := conn.QueryRow(ctx, `SELECT current_setting('block_size')::bigint`).Scan(&blockSize); err != nil {
		return nil, fmt.Errorf("block_size: %w", err)
	}
	// the databases collector's guard: a database the login may not size is left out; a size read that still fails
	// (a managed service's own database) leaves the data size unknown, and the rollup still runs (the 10 % rule then
	// keeps the hour's earlier size, or does not fire)
	var dataBytes *int64
	if err := conn.QueryRow(ctx, `
SELECT sum(pg_database_size(d.oid))::bigint FROM pg_database d
 WHERE d.datallowconn AND (has_database_privilege(d.datname, 'CONNECT') OR pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER'))`).Scan(&dataBytes); err != nil {
		return []Row{{"kind": "state", "data_bytes": nil, "block_size": blockSize},
			{"kind": "collector_error", "source": "database sizes", "message": err.Error()}}, nil
	}
	return []Row{{"kind": "state", "data_bytes": dataBytes, "block_size": blockSize}}, nil
}
