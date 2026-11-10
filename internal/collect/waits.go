package collect

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// waitsCollector reads the wait-event profile of pg_wait_sampling (Postgres Professional, PostgreSQL licence) every
// minute: the extension samples every backend's wait event each profile_period (10 ms by default) and counts the
// samples per pid, event and queryid since the profile was last reset. The read sums the pids (a pid is gone once its
// backend ends; the event and the statement are what matter) and the repository stores the difference between two
// reads (import_waits, 0030), so a stored row is "how many samples of this wait, for this statement, in this minute".
//
// Azure's pgms_wait_sampling (Azure Database for PostgreSQL flexible server) keeps its own aggregated buckets in
// query_store.pgms_wait_sampling_view; they are read as they are (the last hour's) and stored by their end time.
// That path follows Azure's documented view and is not proven against a live Azure server.
//
// Where neither extension is installed the collection is skipped with that reason, and the Waits tab reads the
// activity samples (the activity collection's one-a-minute look at every active session) instead.
type waitsCollector struct{}

func init() { Register(waitsCollector{}) }

func (waitsCollector) Name() string                   { return "waits" }
func (waitsCollector) DefaultInterval() time.Duration { return time.Minute }
func (waitsCollector) Applies(info platform.Info) (bool, string) {
	if !info.HasWaitSampling {
		return false, "neither pg_wait_sampling nor pgms_wait_sampling is installed in the connected database: the Waits tab reads the activity samples"
	}
	return true, ""
}

// waitsProfileSQL sums the profile over pids; %s is the extension's schema.
const waitsProfileSQL = `
SELECT 'profile' AS kind, p.event_type, p.event, p.queryid, sum(p.count)::bigint AS count
  FROM %s.pg_wait_sampling_profile p
 GROUP BY p.event_type, p.event, p.queryid`

// waitsPgmsSQL reads Azure's buckets of the last hour; %s is the view's schema-qualified name.
const waitsPgmsSQL = `
SELECT 'pgms' AS kind, w.start_time, w.end_time, w.event_type, w.event, w.query_id AS queryid, w.calls
  FROM %s w
 WHERE w.end_time > now() - interval '1 hour'`

func (waitsCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	var ext, schema string
	err := conn.QueryRow(ctx, `
SELECT e.extname::text, n.nspname::text FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname IN ('pg_wait_sampling', 'pgms_wait_sampling') ORDER BY e.extname = 'pg_wait_sampling' DESC LIMIT 1`).Scan(&ext, &schema)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("neither pg_wait_sampling nor pgms_wait_sampling is installed: %w", ErrSkip)
	}
	if err != nil {
		return nil, fmt.Errorf("wait sampling extension: %w", err)
	}
	if ext == "pgms_wait_sampling" {
		rows, err := conn.Query(ctx, fmt.Sprintf(waitsPgmsSQL, "query_store.pgms_wait_sampling_view"))
		if err != nil {
			return nil, fmt.Errorf("pgms_wait_sampling: %w", err)
		}
		return rowsToMaps(rows)
	}
	rows, err := conn.Query(ctx, fmt.Sprintf(waitsProfileSQL, quoteIdent(schema)))
	if err != nil {
		return nil, fmt.Errorf("pg_wait_sampling_profile: %w", err)
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, fmt.Errorf("pg_wait_sampling_profile: %w", err)
	}
	// the sampling period turns samples into time; the setting is readable by any login once the library is loaded
	var period *string
	if err := conn.QueryRow(ctx, `SELECT current_setting('pg_wait_sampling.profile_period', true)`).Scan(&period); err != nil {
		return nil, fmt.Errorf("pg_wait_sampling.profile_period: %w", err)
	}
	if period != nil && *period != "" {
		var ms float64
		if _, err := fmt.Sscanf(*period, "%g", &ms); err == nil && ms > 0 {
			out = append(out, Row{"kind": "period", "ms": ms})
		}
	}
	return out, nil
}
