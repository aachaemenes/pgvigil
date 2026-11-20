package repo

import (
	"context"
	"time"
)

// RollupBlockHourly writes at most limit of the blocking rollup's finished hours, the oldest first, on the
// repository's own clock (pgvigil.import_block_hourly with its now() default, migration 0165): the hours written,
// 0 when another caller holds the rollup's lock or nothing is due.
func (r *Repo) RollupBlockHourly(ctx context.Context, limit int) (int, error) {
	var n int
	err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_block_hourly(p_limit => $1)`, limit).Scan(&n)
	return n, err
}

// NextBlockHourly is the wait until the next 16 minutes past an hour of the repository's own clock and time zone - the
// hours the rollup cuts (date_trunc in the session's TimeZone): a +5:30 or +5:45 zone's hour does not start on a UTC
// hour.
func (r *Repo) NextBlockHourly(ctx context.Context) (time.Duration, error) {
	var secs float64
	err := r.pool.QueryRow(ctx, `SELECT extract(epoch FROM date_trunc('hour', now() - interval '16 minutes') + interval '76 minutes' - now())::float8`).Scan(&secs)
	return time.Duration(secs * float64(time.Second)), err
}
