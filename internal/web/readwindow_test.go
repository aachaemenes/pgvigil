package web

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TestReadWindow: a window up to a year is taken; a part reads its reach of it (the default 31 days and an hour), the
// newest end, and the request keeps what was asked and what was read; a window inside the reach is read whole and
// leaves no read window; a part with a year's reach reads a year whole; past a year and an hour is refused.
func TestReadWindow(t *testing.T) {
	end := time.Date(2026, 11, 13, 20, 0, 0, 0, time.UTC)
	call := func(from time.Time, reach time.Duration) (time.Time, *readWindow, error) {
		var got time.Time
		var rw *readWindow
		var err error
		h := withReadWindow(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
			_, got, _, err = paramsReach(r, true, reach)
			rw = readWindowOf(r)
		}))
		u := "/api/x?instance=1&from=" + from.Format(time.RFC3339) + "&to=" + end.Format(time.RFC3339)
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, u, nil))
		return got, rw, err
	}
	year := end.Add(-365 * 24 * time.Hour)
	from, rw, err := call(year, defaultReach)
	if err != nil || !from.Equal(end.Add(-defaultReach)) || rw == nil || !rw.asked.Equal(year) || !rw.from.Equal(from) || !rw.to.Equal(end) {
		t.Fatalf("a year at the default reach: from %v, read window %+v, err %v; want from %v and the asked start kept", from, rw, err, end.Add(-defaultReach))
	}
	if from, rw, err = call(end.Add(-20*24*time.Hour), defaultReach); err != nil || !from.Equal(end.Add(-20*24*time.Hour)) || rw != nil {
		t.Fatalf("20 days: from %v, read window %+v, err %v; want the window whole and no read window", from, rw, err)
	}
	// a 31-day month with a fall-back hour (744 h + 1 h) is inside the default reach
	if _, rw, err = call(end.Add(-745*time.Hour), defaultReach); err != nil || rw != nil {
		t.Fatalf("745 hours: read window %+v, err %v; want none", rw, err)
	}
	if from, rw, err = call(year, maxWindow); err != nil || !from.Equal(year) || rw != nil {
		t.Fatalf("a year at a year's reach: from %v, read window %+v, err %v; want the whole year", from, rw, err)
	}
	if _, _, err = call(end.Add(-maxWindow-time.Second), maxWindow); err == nil {
		t.Fatal("366 days, an hour and a second: no error; want 'window longer than a year'")
	}
	// the multi part that read the window carries it; one that did not (no time argument equal to its start) does not
	if !readArgs([]any{1, end.Add(-defaultReach), end}, end.Add(-defaultReach)) || readArgs([]any{1}, end.Add(-defaultReach)) {
		t.Fatal("readArgs: a part's window start not told apart")
	}
}

// TestRunWindow: a custom report's run window takes up to a year (maxWindow) and words its limit as the API does.
func TestRunWindow(t *testing.T) {
	if _, _, err := runWindow("2025-11-13T20:00:00Z", "2026-11-13T20:00:00Z"); err != nil {
		t.Fatalf("a year: %v; want taken", err)
	}
	_, _, err := runWindow("2024-11-13T20:00:00Z", "2026-11-13T20:00:00Z")
	if err == nil || !strings.Contains(err.Error(), "at most a year") {
		t.Fatalf("two years: %v; want 'at most a year'", err)
	}
}
