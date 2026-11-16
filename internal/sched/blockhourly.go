package sched

import (
	"context"
	"log/slog"
	"time"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// blockHourlyAt is the minute past each hour the blocking rollup runs: an hour is rolled once it ended 15 minutes ago
// (migration 0165), so at 16 past the hour before is in.
const blockHourlyAt = 16 * time.Minute

// blockHourlyTimeout bounds one call; blockHourlyBatch caps its instance-hours (a call cut by its timeout keeps
// nothing), and the calls repeat while one returns its cap: a large fleet's first fill goes in pieces.
const (
	blockHourlyTimeout = 5 * time.Minute
	blockHourlyBatch   = 200
)

// nextBlockHourly is the first 16-past-the-hour after now on a UTC hour: the fallback when the repository cannot say
// its own (NextBlockHourly) - a zone whose hours do not start on a UTC hour then waits up to an hour longer.
func nextBlockHourly(now time.Time) time.Time {
	t := now.UTC().Truncate(time.Hour).Add(blockHourlyAt)
	if !t.After(now) {
		t = t.Add(time.Hour)
	}
	return t
}

// blockWait is the wait until the next call: the repository's own 16 past the hour, else the UTC fallback.
func blockWait(ctx context.Context, log *slog.Logger, r *repo.Repo) time.Duration {
	qctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	d, err := r.NextBlockHourly(qctx)
	cancel()
	if err != nil || d <= 0 || d > time.Hour+time.Minute {
		if err != nil && ctx.Err() == nil {
			log.Warn("blocking rollup: next hour from the repository", "err", err)
		}
		return time.Until(nextBlockHourly(time.Now()))
	}
	return d
}

// blockHourly calls the blocking rollup once an hour for every engine, on a timer of its own (never inside a
// collection's run or the heartbeat's): the spike's usual then fills on a repository with no SQL Server instance,
// whose Extended Events import (the rollup's other caller) never runs. Several collectors on one repository each call
// it; the rollup's advisory lock lets one work and the others return 0.
func blockHourly(ctx context.Context, log *slog.Logger, r *repo.Repo) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(blockWait(ctx, log, r)):
		}
		total := 0
		for ctx.Err() == nil {
			cctx, cancel := context.WithTimeout(ctx, blockHourlyTimeout)
			n, err := r.RollupBlockHourly(cctx, blockHourlyBatch)
			cancel()
			if err != nil {
				log.Warn("blocking rollup", "err", err, "hours before it", total)
				break
			}
			total += n
			if n < blockHourlyBatch {
				break
			}
		}
		if total > 0 {
			log.Info("blocking rollup", "hours", total)
		}
	}
}
