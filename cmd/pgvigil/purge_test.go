package main

import (
	"errors"
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
