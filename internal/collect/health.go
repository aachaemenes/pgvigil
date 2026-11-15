package collect

import (
	"encoding/json"
	"fmt"
	"time"
)

// The outcome of a run (B6.1, DBA Dash's run status): a producer sets OutcomePartial when its run ended with a
// collector error row; every other outcome is derived from the Result (outcomeOf).
const (
	OutcomeOK      = "ok"
	OutcomePartial = "partial"
	OutcomeError   = "error"
	OutcomeSkipped = "skipped"
)

// PartialOutcome: OutcomePartial for a run whose logged status is "partial", "" for any other (the SQL Server
// collectors' form of partialOutcome)
func PartialOutcome(status string) string { return partialOutcome(status) }

func partialOutcome(status string) string {
	if status == "partial" {
		return OutcomePartial
	}
	return ""
}

// outcomeOf: a run's outcome - an error first, then the producer's own (partial), then skipped, else ok
func outcomeOf(res Result) string {
	switch {
	case res.Err != nil:
		return OutcomeError
	case res.Outcome != "":
		return res.Outcome
	case skipped(res):
		return OutcomeSkipped
	}
	return OutcomeOK
}

type healthKey struct {
	instance, collection string
	hour                 time.Time
}

type healthAgg struct {
	runs, ok, partial, errs, skipped, overHalf, overInterval, durMax, intervalS int
	rows, durSum                                                                int64
	lastOk, lastErr, lastPartial                                                time.Time // lastOk: an ok or a partial run
}

// beatHealth: one instance, collection and UTC hour's running totals since this run began (the repository keeps them
// per collector_id; its readers sum the collectors). Runs are the known runs (ok, partial, error); a skip is not one.
type beatHealth struct {
	Instance     string     `json:"instance"`
	Collection   string     `json:"collection"`
	Hour         time.Time  `json:"hour"`
	Runs         int        `json:"runs"`
	Ok           int        `json:"ok"`
	Partial      int        `json:"partial"`
	Error        int        `json:"error"`
	Skipped      int        `json:"skipped"`
	Rows         int64      `json:"rows"`
	DurSum       int64      `json:"dur_ms_sum"`
	DurMax       int        `json:"dur_ms_max"`
	OverHalf     int        `json:"over_half"`
	OverInterval int        `json:"over_interval"`
	IntervalS    int        `json:"interval_s"`
	LastOk       *time.Time `json:"last_ok_at,omitempty"`
	LastError    *time.Time `json:"last_error_at,omitempty"`
	LastPartial  *time.Time `json:"last_partial_at,omitempty"`
}

// health counts one run into its hour (under h.mu, from record()): the hour is UTC's, never the collector's zone, and
// the run's START's (its collection_log row's snapshot_at), so a run crossing an hour edge is counted where it is
// listed (the review B6f3 #1); the row's last times are the start too; a run with no start known is filed by now. The
// newest hour and a clock step are read by the record clock (now), never by the start: a run longer than an hour is
// no clock step (the review B6f5 #1) - it is filed under the oldest hour still held. A connect failure is an error; a
// run over half its interval, and over all of it, counted for 'runs long' (B6.4)
func (h *Heartbeat) health(instance, collection string, res Result, now time.Time, every time.Duration) {
	end := now.UTC().Truncate(time.Hour)
	switch {
	case end.After(h.hourNew):
		h.hourNew = end
	case end.Before(h.hourNew.Add(-time.Hour)):
		// the clock stepped back (NTP after a clock that ran fast, a VM resumed): this hour is the newest again, and
		// the hours ahead of it, sent already, are sent no more (takeHealth would otherwise drop this run's hour)
		h.hourNew = end
		for k := range h.hourly {
			if k.hour.After(end) {
				delete(h.hourly, k)
			}
		}
	}
	if !res.Start.IsZero() {
		now = res.Start
	}
	// filed by the start's hour within the two hours held: a start before the oldest (a run over an hour) under the
	// oldest, a start ahead of the newest (the clock stepped back during the run) under the newest
	hour := now.UTC().Truncate(time.Hour)
	if hour.After(h.hourNew) {
		hour = h.hourNew
	}
	if old := h.hourNew.Add(-time.Hour); hour.Before(old) {
		hour = old
	}
	if h.hourly == nil {
		h.hourly = map[healthKey]*healthAgg{}
	}
	k := healthKey{instance, collection, hour}
	a := h.hourly[k]
	if a == nil {
		a = &healthAgg{}
		h.hourly[k] = a
	}
	if s := int(every / time.Second); s > 0 && (a.intervalS == 0 || s < a.intervalS) {
		a.intervalS = s
	}
	o := outcomeOf(res)
	if o == OutcomeSkipped {
		a.skipped++
		return
	}
	a.runs++
	switch o {
	case OutcomeOK:
		a.ok++
		a.lastOk = now
	case OutcomePartial:
		a.partial++
		a.lastPartial = now
		a.lastOk = now // a partial is a success for Last Success, as collection_run_status.last_ok_at (0166)
	default:
		a.errs++
		a.lastErr = now
	}
	if o != OutcomeError {
		a.rows += int64(res.Rows)
	}
	ms := int(res.Duration.Milliseconds())
	a.durSum += int64(ms)
	a.durMax = max(a.durMax, ms)
	if every > 0 && res.Duration > every/2 {
		a.overHalf++
	}
	if every > 0 && res.Duration > every {
		a.overInterval++
	}
}

// takeHealth (under h.mu, from take()): every hour still kept, as running totals; an hour older than the one before
// the newest is dropped first (its last runs were sent by the beats of the hour after it)
func (h *Heartbeat) takeHealth() []beatHealth {
	out := []beatHealth{}
	keep := h.hourNew.Add(-time.Hour)
	for k, a := range h.hourly {
		if k.hour.Before(keep) {
			delete(h.hourly, k)
			continue
		}
		r := beatHealth{Instance: k.instance, Collection: k.collection, Hour: k.hour, Runs: a.runs, Ok: a.ok, Partial: a.partial,
			Error: a.errs, Skipped: a.skipped, Rows: a.rows, DurSum: a.durSum, DurMax: a.durMax, OverHalf: a.overHalf,
			OverInterval: a.overInterval, IntervalS: a.intervalS}
		r.LastOk, r.LastError, r.LastPartial = timePtr(a.lastOk), timePtr(a.lastErr), timePtr(a.lastPartial)
		out = append(out, r)
	}
	return out
}

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	u := t.UTC()
	return &u
}

// healthBody: the hourly rows' own statement body for import_collection_health ({"health": [...]}); the heartbeat's
// body never carries them (import_collector_beat would parse them and ignore them)
func healthBody(hs []beatHealth) ([]byte, error) {
	return json.Marshal(struct {
		Health []beatHealth `json:"health"`
	}{hs})
}

// amcheckUnchecked: a collector_error row for each amcheck run row (one database and check) that left relations
// unchecked - a missing EXECUTE on the check function, a relation's lock_timeout - so the run ends partial (B6.1's
// fold, X2: the run's Outcome in every producer); a run that only reached its budget (its note) stays ok: that is the
// planned rotation
func amcheckUnchecked(rows []Row) []Row {
	var out []Row
	for _, r := range rows {
		if r["kind"] != "run" {
			continue
		}
		n, _ := r["errors"].(int)
		if n <= 0 {
			continue
		}
		out = append(out, Row{"kind": "collector_error", "source": fmt.Sprintf("amcheck:%v", r["datname"]),
			"message": fmt.Sprintf("%v: %d relation(s) not checked", r["check_name"], n)})
	}
	return out
}
