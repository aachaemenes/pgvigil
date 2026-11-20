package repo

import (
	"context"
	"sync/atomic"
)

// A run's deadlock retries (N4): the collector's scheduler hands each run a counter in its context (WithRetryCounter);
// Import adds one to it for every import it takes again after PostgreSQL ended it as a deadlock's victim, and the
// heartbeat carries the run's count into collector_runs.retries (0271) - the Collector page's 'retried after a
// deadlock'. The WARN line of each retry stays in the log.

type retryCounterKey struct{}

// WithRetryCounter returns ctx carrying n: each Import under ctx (or a context made from it) adds its deadlock
// retries to n.
func WithRetryCounter(ctx context.Context, n *atomic.Int64) context.Context {
	return context.WithValue(ctx, retryCounterKey{}, n)
}

// countRetry adds one to ctx's retry counter; nothing when ctx carries none.
func countRetry(ctx context.Context) {
	if n, ok := ctx.Value(retryCounterKey{}).(*atomic.Int64); ok && n != nil {
		n.Add(1)
	}
}
