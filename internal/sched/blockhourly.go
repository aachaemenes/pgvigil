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

// blockHourlyTimeout bounds one call (a new store rolls 24 hours of every instance per call).
const blockHourlyTimeout = 5 * time.Minute

// nextBlockHourly is the first 16-past-the-hour after now.
func nextBlockHourly(now time.Time) time.Time {
	t := now.Truncate(time.Hour).Add(blockHourlyAt)
	if !t.After(now) {
		t = t.Add(time.Hour)
	}
	return t
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
		case <-time.After(time.Until(nextBlockHourly(time.Now()))):
		}
		cctx, cancel := context.WithTimeout(ctx, blockHourlyTimeout)
		n, err := r.RollupBlockHourly(cctx, time.Now())
		cancel()
		if err != nil {
			log.Warn("blocking rollup", "err", err)
			continue
		}
		if n > 0 {
			log.Info("blocking rollup", "hours", n)
		}
	}
}
