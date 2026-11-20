package main

import (
	"errors"
	"strings"
	"testing"
)

// A retention under a day is a usage error (exit 2) before anything connects: purge(0) would delete
// every row of the row-level series.
func TestCheckPurgeDays(t *testing.T) {
	for _, d := range []int{0, -1} {
		err := checkPurgeDays(d)
		var ec interface{ ExitCode() int }
		if err == nil || !errors.As(err, &ec) || ec.ExitCode() != 2 {
			t.Errorf("days %d: got %v, want a usage error with exit code 2", d, err)
		}
	}
	for _, d := range []int{1, 30, 400} {
		if err := checkPurgeDays(d); err != nil {
			t.Errorf("days %d: %v", d, err)
		}
	}
}

// TestParseHoursCap: collection_health_hour keeps 30 days at most (0166's CHECK): a larger value is refused in words
// before any table is set - never one table set and the next failing on the constraint, never a -dry-run line that
// prints a value the store would refuse
func TestParseHoursCap(t *testing.T) {
	if _, err := parseHoursFlag("job_stats_hourly=730,collection_health_hour=40"); err == nil || !strings.Contains(err.Error(), "collection_health_hour=40: this table keeps 30 days at most") {
		t.Errorf("collection_health_hour=40: err %v, want 'collection_health_hour=40: this table keeps 30 days at most (0166)'", err)
	}
	if sets, err := parseHoursFlag("collection_health_hour=30,job_stats_hourly=730"); err != nil || len(sets) != 2 {
		t.Errorf("collection_health_hour=30: %v %v, want both pairs", sets, err)
	}
}
