package collect

import (
	"errors"
	"os"
	"regexp"
	"testing"
	"time"
)

// TestRoundTripOncePerMinute (B24h-1a; Instance#18, the fold's #4): one 'SELECT 1' timed per instance and minute, by
// the minute's first collection that claims it; its count, sum and longest ride the beat's load row; the next minute is
// due again; a measure that failed releases the claim so a later collection of the minute can take it
func TestRoundTripOncePerMinute(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	if !h.roundTripDue("i1") {
		t.Fatal("the minute's first collection: due, want true")
	}
	if h.roundTripDue("i1") {
		t.Error("a second collection while the first measures: due, want false (claimed)")
	}
	h.countRoundTrip("i1", 0, errors.New("broken pipe"))
	if !h.roundTripDue("i1") {
		t.Error("after a failed measure: due, want true (the claim released)")
	}
	h.countRoundTrip("i1", 12*time.Millisecond, nil)
	if h.roundTripDue("i1") {
		t.Error("after the minute's measure: due, want false")
	}
	if !h.roundTripDue("i2") {
		t.Error("another instance: due, want true")
	}
	h.countRoundTrip("i2", 40*time.Millisecond, nil)
	b := h.take()
	got := map[string]beatLoad{}
	for _, l := range b.Load {
		got[l.Instance] = l
	}
	if l := got["i1"]; l.RtCount != 1 || l.RtMsSum != 12 || l.RtMsMax != 12 {
		t.Errorf("i1's load row rt %d / %d / %d, want 1 / 12 / 12", l.RtCount, l.RtMsSum, l.RtMsMax)
	}
	if l := got["i2"]; l.RtCount != 1 || l.RtMsSum != 40 || l.RtMsMax != 40 {
		t.Errorf("i2's load row rt %d / %d / %d, want 1 / 40 / 40", l.RtCount, l.RtMsSum, l.RtMsMax)
	}
	if !h.roundTripDue("i1") {
		t.Error("the next minute: due, want true")
	}
}

// TestRoundTripSimpleProtocol (the fold's #4): the round trip is ONE simple-protocol message - PostgreSQL through the
// PgConn (pgx's cached-statement mode prepares first: two round trips), SQL Server one batch with no parameters
func TestRoundTripSimpleProtocol(t *testing.T) {
	b, err := os.ReadFile("roundtrip.go")
	if err != nil {
		t.Fatalf("roundtrip.go: %v", err)
	}
	if !regexp.MustCompile(`\.PgConn\(\)\.Exec\(ctx, "SELECT 1"\)\.ReadAll\(\)`).Match(b) {
		t.Error("the PostgreSQL round trip is not conn.PgConn().Exec(ctx, \"SELECT 1\").ReadAll()")
	}
	if regexp.MustCompile(`conn\.(Exec|QueryRow|Query)\(ctx, "SELECT 1"`).Match(b) {
		t.Error("the PostgreSQL round trip goes through pgx's extended protocol")
	}
}
