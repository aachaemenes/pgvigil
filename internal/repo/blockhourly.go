package repo

import (
	"context"
	"time"
)

// RollupBlockHourly writes the blocking rollup's finished hours as at the time at (pgvigil.import_block_hourly,
// migration 0165): the hours written, 0 when another caller holds the rollup's lock.
func (r *Repo) RollupBlockHourly(ctx context.Context, at time.Time) (int, error) {
	var n int
	err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_block_hourly($1)`, at).Scan(&n)
	return n, err
}
