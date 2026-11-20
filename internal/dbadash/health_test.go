package dbadash

import (
	"testing"
	"time"
)

// TestHealthDetail: the detail CollectionHealth says what DBA Dash's Summary_Upd used for an instance's count when it
// last wrote the Summary row - collection health only on a repository at 4.25.0 or later, for a row written after that
// deploy, for an instance with run rows; the 24 h errors for a row written before the deploy (DBA Dash's cache is
// rebuilt only when Summary_Upd runs) or an instance without runs; unknown when the login may not read the runs.
func TestHealthDetail(t *testing.T) {
	at := func(s string) time.Time {
		v, err := time.Parse("2006-01-02 15:04", s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	ptr := func(s string) *time.Time { v := at(s); return &v }
	upgraded := []deploy{{"4.25.0", at("2026-11-14 10:00")}, {"4.24.1", at("2026-10-01 09:00")}}
	twice := []deploy{{"4.26.1", at("2026-11-20 10:00")}, {"4.25.0", at("2026-11-14 10:00")}, {"4.24.1", at("2026-10-01 09:00")}}
	back := []deploy{{"4.24.1", at("2026-11-20 10:00")}, {"4.25.0", at("2026-11-14 10:00")}}
	for _, c := range []struct {
		name      string
		hist      []deploy
		refreshed *time.Time
		runs      bool
		read      any // the read's EXISTS bit (nil: not read)
		want      any // nil: no detail
	}{
		{"older repository", []deploy{{"4.24.1", at("2026-10-01 09:00")}}, ptr("2026-11-14 11:00"), true, nil, nil},
		{"no history", nil, ptr("2026-11-14 11:00"), true, true, nil},
		{"runs, written after the deploy", upgraded, ptr("2026-11-14 10:05"), true, true, true},
		{"no runs, written after the deploy", upgraded, ptr("2026-11-14 10:05"), true, false, false},
		{"runs, written before the deploy", upgraded, ptr("2026-11-14 09:30"), true, true, false},
		{"runs, never written", upgraded, nil, true, true, false},
		{"the runs not readable", upgraded, ptr("2026-11-14 10:05"), false, nil, "unknown"},
		{"the runs not readable, written before the deploy", upgraded, ptr("2026-11-14 09:30"), false, nil, false},
		{"4.25.0 then 4.26.1: from 4.25.0's deploy", twice, ptr("2026-11-15 08:00"), true, true, true},
		{"back to 4.24.1", back, ptr("2026-11-21 08:00"), true, true, nil},
	} {
		d := map[string]any{"CollectionErrorCount": 3.0}
		if c.read != nil {
			d[HealthKey] = c.read
		}
		healthDetail(d, c.refreshed, healthSince(c.hist), c.runs)
		got, ok := d[HealthKey]
		if (c.want == nil && ok) || (c.want != nil && got != c.want) {
			t.Errorf("%s: %v (present %v), want %v", c.name, got, ok, c.want)
		}
	}
	for v, want := range map[string]bool{"4.25.0.0": true, "4.25": true, "4.26.1.0": true, "5.0.0.0": true, "5": true,
		"4.24.1.0": false, "4.19.0.0": false, "4": false, "": false, "4.25.0-beta": false, "beta": false, "4..25": false} {
		if got := HealthVersion(v); got != want {
			t.Errorf("HealthVersion(%q) = %v, want %v", v, got, want)
		}
	}
}
