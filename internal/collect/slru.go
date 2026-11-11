package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// slruCollector reads pg_stat_slru (PostgreSQL 13+) every 5 minutes: per SLRU cache (commit status, subtransactions,
// multixact offsets and members, notify, serializable, commit timestamps, other) the pages zeroed, hit, read, written and
// checked for existence, the flushes and truncations since its stats_reset. Stored as read (cumulative); the repository
// takes the difference between reads (pgvigil.slru_rate) and raises a finding when the subtransaction or a multixact
// cache read pages from disk between the two newest reads: its buffers no longer hold the working set (a transaction
// with more than 64 subtransactions while a long one keeps old snapshots alive; heavy row locking by several sessions).
// The cache names are CamelCase to 16 (Subtrans, MultiXactMember) and lower case with underscores from 17
// (subtransaction, multixact_member): stored as the server gives them.
type slruCollector struct{}

func init() { Register(slruCollector{}) }

func (slruCollector) Name() string                   { return "slru" }
func (slruCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (slruCollector) Applies(info platform.Info) (bool, string) {
	if info.ServerVersionNum < 130000 {
		return false, "pg_stat_slru arrived in PostgreSQL 13"
	}
	return true, ""
}

const slruSQL = `
SELECT 'slru' AS kind, s.name::text AS name, s.blks_zeroed, s.blks_hit, s.blks_read, s.blks_written, s.blks_exists,
       s.flushes, s.truncates, s.stats_reset
  FROM pg_stat_slru s
 ORDER BY s.name`

func (slruCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	rows, err := conn.Query(ctx, slruSQL)
	if err != nil {
		return nil, fmt.Errorf("pg_stat_slru: %w", err)
	}
	return rowsToMaps(rows)
}
