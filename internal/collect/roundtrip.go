package collect

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// The query round trip (B24h-1a; dbachecks' Instance#18): once a minute per instance the minute's
// first collection that claims it times ONE simple-protocol 'SELECT 1' on its own connection - the network there and
// back and the server's answer to the smallest query (said so on the page: 'query round trip (network and the
// server's response)', never 'network latency'). Its count, sum and longest ride the beat's load row (rt_*).

// RoundTripDue claims the minute's measure for the instance: true for the first caller of the minute, false while it
// is claimed or once it is measured; false with no heartbeat (`pgvigil collect`, a test).
func RoundTripDue(instance string) bool {
	if h := current.Load(); h != nil {
		h.mu.Lock()
		defer h.mu.Unlock()
		return h.roundTripDue(instance)
	}
	return false
}

// CountRoundTrip keeps a claimed measure (err nil) or releases the claim (err set: a later collection of the minute
// may measure).
func CountRoundTrip(instance string, took time.Duration, err error) {
	if h := current.Load(); h != nil {
		h.mu.Lock()
		defer h.mu.Unlock()
		h.countRoundTrip(instance, took, err)
	}
}

func (h *Heartbeat) roundTripDue(instance string) bool {
	l := h.loadOf(instance)
	if l.rtCount > 0 || l.rtClaimed {
		return false
	}
	l.rtClaimed = true
	return true
}

func (h *Heartbeat) countRoundTrip(instance string, took time.Duration, err error) {
	l := h.loadOf(instance)
	l.rtClaimed = false
	if err != nil {
		return
	}
	ms := took.Milliseconds()
	l.rtCount++
	l.rtMsSum += ms
	l.rtMsMax = max(l.rtMsMax, int(ms))
}

// TimeRoundTrip runs one round trip (do) when the minute's measure is due for the instance, and counts it.
func TimeRoundTrip(instance string, do func() error) {
	if !RoundTripDue(instance) {
		return
	}
	t0 := time.Now()
	err := do()
	CountRoundTrip(instance, time.Since(t0), err)
}

// MeasurePgRoundTrip measures PostgreSQL's round trip through the PgConn - one 'Q' message, no Parse / Bind (pgx's
// cached-statement mode would prepare first: two round trips)
func MeasurePgRoundTrip(ctx context.Context, instance string, conn *pgx.Conn) {
	TimeRoundTrip(instance, func() error {
		_, err := conn.PgConn().Exec(ctx, "SELECT 1").ReadAll()
		return err
	})
}
