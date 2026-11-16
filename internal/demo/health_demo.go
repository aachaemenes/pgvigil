package demo

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// The demo's hourly collection health (B6.2, the lead's 23:2x call B6.2-b and 00:5x call on the review's #3): the demo
// has no heartbeat, so the fleet writes collection_health_hour itself, under the collector id 'demo', from the same
// per-minute rule its logged runs follow (runStatus): the seed writes the last 24 hours with one collection_log error
// per failed minute (logHistoryErrors), and each Tick adds the minute it logged. Only the minutes known to be run are
// counted (the seeded 24 hours and every minute a Tick logged: a tick that failed or was dropped counts nothing), so
// the page's Failed counts and its error list agree.

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
	// B6g-1: the imports (the demo has no import failure) and, on a SQL Server instance, each run's own session cost
	ImportFailed int   `json:"import_failed"`
	ImportRuns   int   `json:"import_runs"`
	ImportSum    int64 `json:"import_ms_sum"`
	ImportMax    int   `json:"import_ms_max"`
	CPURuns      int   `json:"cpu_runs"`
	CPUSum       int64 `json:"cpu_ms_sum"`
	CPUMax       int   `json:"cpu_ms_max"`
	ReadsSum     int64 `json:"reads_sum"`
}

// healthRows: the totals of every instance and collection for each UTC hour, over the minutes from .. to (both
// included) that known holds (nil = every one): a known run (ok, partial, error) counts its duration, a skip does not;
// the last ok includes a partial (a success for Last Success, as the collector's)
func healthRows(gens []*Gen, ids []int, from, to time.Time, known func(int, time.Time) bool) []demoHealth {
	from, to = from.UTC().Truncate(time.Minute), to.UTC().Truncate(time.Minute)
	var out []demoHealth
	for i, g := range gens {
		for _, c := range g.Collections() {
			idx := map[time.Time]int{}
			for m := from; !m.After(to); m = m.Add(time.Minute) {
				if known != nil && !known(i, m) {
					continue
				}
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
				// a SQL Server run reads its own session at its end, a failed run too: a quarter of the run's time on
				// the CPU, 40 logical reads a millisecond (the demo's figures: no server is asked)
				if g.Spec.Engine == EngineSQLServer {
					cpu := max(ms/4, 1)
					r.CPURuns++
					r.CPUSum += int64(cpu)
					r.CPUMax = max(r.CPUMax, cpu)
					r.ReadsSum += int64(40 * ms)
				}
				// a run that did not fail at its read wrote into the repository: a fifth of its time, at least 1 ms
				if status != "error" {
					imp := max(ms/5, 1)
					r.ImportRuns++
					r.ImportSum += int64(imp)
					r.ImportMax = max(r.ImportMax, imp)
				}
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

// known: a minute instance i's hourly rows count - inside the seeded 24 hours, or one a Tick logged for it
func (f *Fleet) known(i int, m time.Time) bool {
	if !f.histFrom.IsZero() && !m.Before(f.histFrom) && !m.After(f.histTo) {
		return true
	}
	f.tickMu.Lock()
	defer f.tickMu.Unlock()
	return f.ticked[i][m]
}

// markTicked: minute t is logged for instance i; its minutes older than 3 hours are let go
func (f *Fleet) markTicked(i int, t time.Time) {
	f.tickMu.Lock()
	defer f.tickMu.Unlock()
	if f.ticked == nil {
		f.ticked = map[int]map[time.Time]bool{}
	}
	if f.ticked[i] == nil {
		f.ticked[i] = map[time.Time]bool{}
	}
	f.ticked[i][t] = true
	for m := range f.ticked[i] {
		if m.Before(t.Add(-3 * time.Hour)) {
			delete(f.ticked[i], m)
		}
	}
}

// writeHealth writes the hour of t and the hour before it (its last minutes land in the next hour's first tick), from
// the seeded history's start at the earliest
func (f *Fleet) writeHealth(ctx context.Context, t time.Time) error {
	from := t.UTC().Truncate(time.Hour).Add(-time.Hour)
	if from.Before(f.histFrom) {
		from = f.histFrom
	}
	return f.writeHealthSpan(ctx, from, t)
}

// writeHealthSpan writes every hour from .. to over the known minutes (the seed: the 24 hours at once)
func (f *Fleet) writeHealthSpan(ctx context.Context, from, to time.Time) error {
	if f.histFrom.IsZero() || from.After(to) {
		return nil
	}
	body, err := json.Marshal(healthRows(f.gens, f.ids, from, to, f.known))
	if err != nil {
		return err
	}
	if _, err := f.pool.Exec(ctx, `
INSERT INTO pgvigil.collection_health_hour AS h (hour, instance_id, collection, collector_id, runs, ok, partial, failed, skipped, rows_written,
       dur_ms_sum, dur_ms_max, runs_over_half, runs_over_interval, interval_s, last_ok_at, last_failure_at, last_partial_at,
       import_failed, import_runs, import_ms_sum, import_ms_max, cpu_runs, cpu_ms_sum, cpu_ms_max, reads_sum)
SELECT x.hour, x.instance_id, x.collection, 'demo', x.runs, x.ok, x.partial, x.error, x.skipped, x.rows, x.dur_ms_sum, x.dur_ms_max, 0, 0, 60,
       x.last_ok_at, x.last_error_at, x.last_partial_at,
       x.import_failed, x.import_runs, x.import_ms_sum, x.import_ms_max, x.cpu_runs, x.cpu_ms_sum, x.cpu_ms_max, x.reads_sum
  FROM jsonb_to_recordset($1::jsonb) AS x(hour timestamptz, instance_id int, collection text, runs int, ok int, partial int, error int, skipped int,
       rows bigint, dur_ms_sum bigint, dur_ms_max int, last_ok_at timestamptz, last_error_at timestamptz, last_partial_at timestamptz,
       import_failed int, import_runs int, import_ms_sum bigint, import_ms_max int, cpu_runs int, cpu_ms_sum bigint, cpu_ms_max int, reads_sum bigint)
ON CONFLICT (hour, instance_id, collection, collector_id) DO UPDATE
   SET runs = EXCLUDED.runs, ok = EXCLUDED.ok, partial = EXCLUDED.partial, failed = EXCLUDED.failed, skipped = EXCLUDED.skipped,
       rows_written = EXCLUDED.rows_written, dur_ms_sum = EXCLUDED.dur_ms_sum, dur_ms_max = EXCLUDED.dur_ms_max,
       last_ok_at = EXCLUDED.last_ok_at, last_failure_at = EXCLUDED.last_failure_at, last_partial_at = EXCLUDED.last_partial_at,
       import_failed = EXCLUDED.import_failed, import_runs = EXCLUDED.import_runs, import_ms_sum = EXCLUDED.import_ms_sum,
       import_ms_max = EXCLUDED.import_ms_max, cpu_runs = EXCLUDED.cpu_runs, cpu_ms_sum = EXCLUDED.cpu_ms_sum,
       cpu_ms_max = EXCLUDED.cpu_ms_max, reads_sum = EXCLUDED.reads_sum
 WHERE (h.runs, h.skipped) IS DISTINCT FROM (EXCLUDED.runs, EXCLUDED.skipped)`, string(body)); err != nil {
		return fmt.Errorf("demo collection health: %w", err)
	}
	return nil
}

// logHistoryErrors logs, in order, one collection_log error per minute from .. to (both included) whose run fails by
// runStatus (a StmtBroken instance's statements): the 24 hours the hourly rows cover hold the errors they count (the
// lead's 00:5x call on the review of B6.2, #3). One statement per failing collection.
func (m *importer) logHistoryErrors(ctx context.Context, id int, g *Gen, from, to time.Time) error {
	for _, c := range g.Collections() {
		var ats []time.Time
		var mss []int
		note := ""
		for t := from; !t.After(to); t = t.Add(time.Minute) {
			if st, n := runStatus(g, c, t); st == "error" {
				ats, mss, note = append(ats, t), append(mss, runMs(g, c, t)), n
			}
		}
		if len(ats) == 0 {
			continue
		}
		if _, err := m.pool.Exec(ctx, `SELECT count(pgvigil.log_collection($1, $2, x.at, x.ms, 'error', $5))
  FROM unnest($3::timestamptz[], $4::int[]) WITH ORDINALITY AS x(at, ms, n)`, id, c, ats, mss, nullIf(note)); err != nil {
			return fmt.Errorf("log_collection history %s: %w", c, err)
		}
	}
	return nil
}
