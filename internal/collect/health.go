package collect

import "time"

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
	lastOk, lastErr, lastPartial                                                time.Time
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

// health counts one run into its hour (under h.mu, from record()): the hour is UTC's, never the collector's zone; a
// connect failure is an error; a run over half its interval, and over all of it, counted for 'runs long' (B6.4)
func (h *Heartbeat) health(instance, collection string, res Result, now time.Time, every time.Duration) {
	hour := now.UTC().Truncate(time.Hour)
	if h.hourly == nil {
		h.hourly = map[healthKey]*healthAgg{}
	}
	k := healthKey{instance, collection, hour}
	a := h.hourly[k]
	if a == nil {
		a = &healthAgg{}
		h.hourly[k] = a
	}
	if hour.After(h.hourNew) {
		h.hourNew = hour
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
