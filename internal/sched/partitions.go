package sched

import (
	"context"
	"log/slog"
	"time"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// partitionsEvery is how often a running collector makes the partitions its next imports need (repo.AheadWindow: this
// month and the next, today and two days on); every collector of a repository does it (a second one finds them made).
const partitionsEvery = time.Hour

// startPartitions is Run's partitions-ahead duty (0271, N4): a first pass before any instance's loop starts, so a
// collector back after a month meets no missing month in its first imports; then a pass every `every` until ctx ends.
func startPartitions(ctx context.Context, log *slog.Logger, r *repo.Repo, every time.Duration) {
	partitionsPass(ctx, log, r, true)
	go partitionsLoop(ctx, log, r, every)
}

// partitionsPass makes the partitions due now, within two minutes; a failure is a warning (the imports still make a
// missing partition themselves, and the next pass tries again).
func partitionsPass(ctx context.Context, log *slog.Logger, r *repo.Repo, first bool) {
	pctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	res, err := r.PartitionsAhead(pctx, time.Now())
	switch {
	case err != nil && ctx.Err() == nil:
		log.Warn("partitions ahead: not all made", "due", res.Due, "made", res.Made, "busy", res.Busy, "err", err)
	case first || res.Made > 0 || res.Busy > 0:
		log.Info("partitions ahead", "due", res.Due, "made", res.Made, "busy", res.Busy)
	}
}

// partitionsLoop runs partitionsPass every `every` until ctx ends.
func partitionsLoop(ctx context.Context, log *slog.Logger, r *repo.Repo, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			partitionsPass(ctx, log, r, false)
		}
	}
}
