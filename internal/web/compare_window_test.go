package web

import (
	"testing"
	"time"
)

// TestCompareShiftFreeWindow (P25 F102: DBA Dash's Object Execution 'Compare To' a second window of the reader's
// own): compare=at:<RFC 3339 time> is a second window of the range's length starting at that time - the shift the
// compare reads take is from minus that start; a start not before the range, or not a time, is refused. The fixed
// picks (prev, day, week) stay as they were.
func TestCompareShiftFreeWindow(t *testing.T) {
	from := time.Date(2026, 11, 17, 8, 0, 0, 0, time.UTC)
	to := from.Add(2 * time.Hour)
	if shift, on, err := compareShift("at:2026-11-10T08:00:00Z", from, to); err != nil || !on || shift != 7*24*3600 {
		t.Errorf("at a week before: shift %v on %v err %v, want 604800 true nil", shift, on, err)
	}
	if shift, on, err := compareShift("at:2026-11-17T05:30:00Z", from, to); err != nil || !on || shift != 2.5*3600 {
		t.Errorf("at 05:30: shift %v on %v err %v, want 9000 true nil", shift, on, err)
	}
	for _, bad := range []string{"at:2026-11-17T08:00:00Z", "at:2026-11-18T00:00:00Z", "at:yesterday", "at:"} {
		if _, _, err := compareShift(bad, from, to); err == nil {
			t.Errorf("%q: no error, want a refusal (a start before the range, as a time)", bad)
		}
	}
	if shift, on, err := compareShift("prev", from, to); err != nil || !on || shift != 7200 {
		t.Errorf("prev: shift %v on %v err %v, want 7200 true nil", shift, on, err)
	}
}
