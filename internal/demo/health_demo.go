package demo

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// The demo's hourly collection health (B6.2, the lead's 23:2x call B6.2-b): the demo has no heartbeat, so the fleet
// writes collection_health_hour itself, under the collector id 'demo', from the same per-minute rule its logged runs
// follow (runStatus), counted from the first minute it logged - its failed runs are then the errors collection_log
// holds, and the Collection Health page's rates, Failed counts and error list agree.

// demoHealth: one instance, collection and UTC hour's totals (the JSON keys are the INSERT's record columns)
type demoHealth struct {
	InstanceID  int        `json:"instance_id"`
	Collection  string     `json:"collection"`
	Hour        time.Time  `json:"hour"`
	Runs        int        `json:"runs"`
	Ok          int        `json:"ok"`
	Partial     int        `json:"partial"`
	Error       int        `json:"error"`
	Skipped     int        `json:"skipped"`
	DurMax      int        `json:"dur_ms_max"`
	DurSum      int64      `json:"dur_ms_sum"`
	Rows        int64      `json:"rows"`
	LastOk      *time.Time `json:"last_ok_at,omitempty"`
	LastError   *time.Time `json:"last_error_at,omitempty"`
	LastPartial *time.Time `json:"last_partial_at,omitempty"`
}

// healthRows: the totals of every instance and collection for each UTC hour, over the minutes from .. to (both
// included): a known run (ok, partial, error) counts its duration, a skip does not; the last ok includes a partial
// (a success for Last Success, as the collector's)
func healthRows(gens []*Gen, ids []int, from, to time.Time) []demoHealth {
	from, to = from.UTC().Truncate(time.Minute), to.UTC().Truncate(time.Minute)
	var out []demoHealth
	for i, g := range gens {
		for _, c := range g.Collections() {
			idx := map[time.Time]int{}
			for m := from; !m.After(to); m = m.Add(time.Minute) {
				h := m.Truncate(time.Hour)
				k, ok := idx[h]
				if !ok {
					out = append(out, demoHealth{InstanceID: ids[i], Collection: c, Hour: h})
					k = len(out) - 1
					idx[h] = k
				}
				r, at := &out[k], m
				status, _ := runStatus(g, c, m)
				if status == "skipped" {
					r.Skipped++
					continue
				}
				r.Runs++
				ms := runMs(g, c, m)
				r.DurSum += int64(ms)
				r.DurMax = max(r.DurMax, ms)
				switch status {
				case "error":
					r.Error++
					r.LastError = &at
				case "partial":
					r.Partial++
					r.LastPartial, r.LastOk = &at, &at
					r.Rows += int64(10 + noise(g.Spec.Name+c+"rows", m)*90)
				default:
					r.Ok++
					r.LastOk = &at
					r.Rows += int64(10 + noise(g.Spec.Name+c+"rows", m)*90)
				}
			}
		}
	}
	return out
}

// writeHealth writes the hour of t and the hour before it (its last minutes land in the next hour's first tick), from
// the first logged minute; nothing before the fleet logged
func (f *Fleet) writeHealth(ctx context.Context, t time.Time) error {
	if f.healthFrom.IsZero() {
		return nil
	}
	from := t.UTC().Truncate(time.Hour).Add(-time.Hour)
	if from.Before(f.healthFrom) {
		from = f.healthFrom
	}
	if from.After(t) {
		return nil
	}
	body, err := json.Marshal(healthRows(f.gens, f.ids, from, t))
	if err != nil {
		return err
	}
	if _, err := f.pool.Exec(ctx, `
INSERT INTO pgvigil.collection_health_hour AS h (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped, rows_written,
       dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at, last_partial_at)
SELECT x.hour, x.instance_id, x.collection, 'demo', x.runs, x.ok, x.partial, x.error, x.skipped, x.rows, x.dur_ms_sum, x.dur_ms_max, 0, 0, 60,
       x.last_ok_at, x.last_error_at, x.last_partial_at
  FROM jsonb_to_recordset($1::jsonb) AS x(hour timestamptz, instance_id int, collection text, runs int, ok int, partial int, error int, skipped int,
       rows bigint, dur_ms_sum bigint, dur_ms_max int, last_ok_at timestamptz, last_error_at timestamptz, last_partial_at timestamptz)
ON CONFLICT (hour, instance_id, collection, collector_id) DO UPDATE
   SET runs = EXCLUDED.runs, ok = EXCLUDED.ok, partial = EXCLUDED.partial, failed = EXCLUDED.failed, skipped = EXCLUDED.skipped,
       rows_written = EXCLUDED.rows_written, dur_ms_sum = EXCLUDED.dur_ms_sum, dur_ms_max = EXCLUDED.dur_ms_max,
       last_ok_at = EXCLUDED.last_ok_at, last_failure_at = EXCLUDED.last_failure_at, last_partial_at = EXCLUDED.last_partial_at
 WHERE (h.runs, h.skipped) IS DISTINCT FROM (EXCLUDED.runs, EXCLUDED.skipped)`, string(body)); err != nil {
		return fmt.Errorf("demo collection health: %w", err)
	}
	return nil
}
