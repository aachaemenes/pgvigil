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
// The data size is the sum of pg_database_size over the databases that accept connections (pg_monitor holds
// pg_read_all_stats, which the function needs for a database the login has no CONNECT on).
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
	var dataBytes *int64
	var blockSize int64
	if err := conn.QueryRow(ctx, `
SELECT (SELECT sum(pg_database_size(oid))::bigint FROM pg_database WHERE datallowconn), current_setting('block_size')::bigint`).Scan(&dataBytes, &blockSize); err != nil {
		return nil, fmt.Errorf("database sizes: %w", err)
	}
	return []Row{{"kind": "state", "data_bytes": dataBytes, "block_size": blockSize}}, nil
}
