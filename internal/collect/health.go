package collect

import (
	"encoding/json"
	"errors"
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
	// OutcomeImportFailed (B6g-1, N27): the read succeeded and the write of its collected rows into the repository
	// failed, so the run ended as an error at that write - DBA Dash's meaning. Set only where a
	// TimedImport returned the error that ended the run; the log's stage 'import' is wider (any failure on the
	// repository's side: a cursor read, a thresholds store), which the hour counts as a plain error. An error for every count that judges, and
	// counted once more as Import Failed. DBA Dash keeps its FailedCount and ImportFailedCount apart and judges their
	// sum; pgvigil's failed holds both and the page shows failed - import_failed beside Import Failed
	OutcomeImportFailed = "import failed"
)

// PartialOutcome is OutcomePartial for a run whose logged status is "partial", "" for any other (the SQL Server
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
	case res.Err != nil && res.Outcome == OutcomeImportFailed:
		return OutcomeImportFailed
	case res.Err != nil:
		return OutcomeError
	case res.Outcome != "" && res.Outcome != OutcomeImportFailed: // 'import failed' is an error's outcome: nothing without one
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
	// B6g-1: the imports (N27) and the runs that read their own session's CPU and logical reads at their end (N25 / N26)
	importFailed, importRuns, importMax, cpuRuns, cpuMax int
	importSum, cpuSum, readsSum                          int64
	lastOk, lastErr, lastPartial                         time.Time // lastOk: an ok or a partial run
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
	// B6g-1 (N27): ImportFailed is inside Error; ImportRuns are the runs that attempted an import (the divisor of the
	// average), ImportSum / ImportMax their time in ms, apart from the run's own duration (which holds it too)
	ImportFailed int   `json:"import_failed"`
	ImportRuns   int   `json:"import_runs"`
	ImportSum    int64 `json:"import_ms_sum"`
	ImportMax    int   `json:"import_ms_max"`
	// B6g-1 (N25 / N26): CPURuns are the runs that read their session's cpu_time and logical_reads at their end (SQL
	// Server); the sums and the highest CPU are over those runs alone
	CPURuns  int   `json:"cpu_runs"`
	CPUSum   int64 `json:"cpu_ms_sum"`
	CPUMax   int   `json:"cpu_ms_max"`
	ReadsSum int64 `json:"reads_sum"`
}

// health counts one run into its hour (under h.mu, from record()): the hour is UTC's, never the collector's zone, and
// the run's START's (its collection_log row's snapshot_at), so a run crossing an hour edge is counted where it is
// listed; the row's last times are the start too; a run with no start known is filed by now. The newest hour and a
// clock step are read by the record clock (now), never by the start: a run longer than an hour is no clock step - it
// is filed under the oldest hour still held. A connect failure is an error; a
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
		if o == OutcomeImportFailed {
			a.importFailed++
		}
	}
	if o != OutcomeError && o != OutcomeImportFailed {
		a.rows += int64(res.Rows)
	}
	if res.Imported {
		ims := int(res.Import.Milliseconds())
		a.importRuns++
		a.importSum += int64(ims)
		a.importMax = max(a.importMax, ims)
	}
	if res.CPUMs != nil {
		a.cpuRuns++
		a.cpuSum += *res.CPUMs
		a.cpuMax = max(a.cpuMax, int(*res.CPUMs))
		if res.Reads != nil {
			a.readsSum += *res.Reads
		}
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
			OverInterval: a.overInterval, IntervalS: a.intervalS,
			ImportFailed: a.importFailed, ImportRuns: a.importRuns, ImportSum: a.importSum, ImportMax: a.importMax,
			CPURuns: a.cpuRuns, CPUSum: a.cpuSum, CPUMax: a.cpuMax, ReadsSum: a.readsSum}
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

// ImportError is a batched run's failed write of collected rows, a value of its own: EndedAtImport tells it by its
// identity, so a later error that only shares a cause with it (a deadline, a dropped connection) is not taken for it.
// Unwrap keeps the cause in the chain (a stop's context.Canceled stays readable).
type ImportError struct{ Err error }

func (e *ImportError) Error() string { return e.Err.Error() }
func (e *ImportError) Unwrap() error { return e.Err }

// EndedAtImport says whether err, the error that ended a batched run, is the import error last handed back to its reader
// (lastImport, an *ImportError) - by identity through the chain: every reader wraps what emit returned with %w or
// returns it as it is. A run whose part was refused and which then ended at a READ did not end at an import.
func EndedAtImport(err error, lastImport *ImportError) bool {
	return err != nil && lastImport != nil && errors.Is(err, lastImport)
}
