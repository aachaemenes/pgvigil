package collect

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func fixtureEvents(t *testing.T) []cwEvent {
	t.Helper()
	raw, err := os.ReadFile("../logparse/testdata/aurora.log")
	if err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	var evs []cwEvent
	for i, line := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		evs = append(evs, cwEvent{Stream: "a", Time: base.Add(time.Duration(i) * time.Second), Message: line})
	}
	return evs
}

func events(rows []Row) (map[string]Row, Row) {
	out := map[string]Row{}
	var cur Row
	for _, r := range rows {
		if r["kind"] == "cursor" {
			cur = r
			continue
		}
		out[r["event_key"].(string)] = r
	}
	return out, cur
}

func TestLogRowsStreamsAndRereads(t *testing.T) {
	a := fixtureEvents(t)
	evs := append([]cwEvent{}, a...)
	for i := len(a) - 1; i >= 0; i-- { // stream b: the same lines, given in reverse, ending 30 s earlier
		evs = append(evs, cwEvent{Stream: "b", Time: a[i].Time.Add(-30 * time.Second), Message: a[i].Message})
	}
	from := a[0].Time.Add(-time.Minute)
	rows := logRows(evs, "cloudwatch:/g", from, time.UTC, false)
	got, cur := events(rows)
	if len(got) != 12 {
		t.Errorf("distinct events %d, want 12 (6 per stream)", len(got))
	}
	// the cursor waits for the stream that is behind: b's latest event
	if want := a[len(a)-1].Time.Add(-30 * time.Second); !cur["read_to"].(time.Time).Equal(want) {
		t.Errorf("cursor %v, want %v (the lagging stream)", cur["read_to"], want)
	}
	again, _ := events(logRows(evs, "cloudwatch:/g", from, time.UTC, false))
	for k := range got {
		if _, ok := again[k]; !ok {
			t.Fatalf("event key %s changed on a re-read", k)
		}
	}
}

func TestLogRowsFullBatchMovesOn(t *testing.T) {
	evs := fixtureEvents(t)
	last := evs[len(evs)-1].Time
	_, cur := events(logRows(evs, "cloudwatch:/g", evs[0].Time, time.UTC, true))
	// next run reads from cursor - overlap = the last event read, not the same window again
	if next := cur["read_to"].(time.Time).Add(-logsOverlap); !next.Equal(last) {
		t.Errorf("next start %v, want the last event %v", next, last)
	}
}

func TestLogRowsSplitEntryKeepsItsKey(t *testing.T) {
	evs := fixtureEvents(t)
	cut := -1
	for i, e := range evs {
		if strings.Contains(e.Message, "ERROR:  deadlock detected") {
			cut = i + 1
		}
	}
	if cut < 0 {
		t.Fatal("no deadlock line in the fixture")
	}
	part, _ := events(logRows(evs[:cut], "cloudwatch:/g", evs[0].Time, time.UTC, false))
	whole, _ := events(logRows(evs, "cloudwatch:/g", evs[0].Time, time.UTC, false))
	var key string
	for k, r := range part {
		if r["kind_of"] == "deadlock" {
			key = k
			if r["statement"] != nil {
				t.Errorf("the cut read should lack the statement: %v", r["statement"])
			}
		}
	}
	w, ok := whole[key]
	if !ok || w["statement"] == nil {
		t.Errorf("the whole read lost the deadlock's key or statement: %v", w)
	}
}

func TestLogRowsRealLabBatch(t *testing.T) {
	raw, err := os.ReadFile("testdata/aurora-lab-events.json")
	if err != nil {
		t.Fatal(err)
	}
	var rec []struct {
		S string `json:"s"`
		T int64  `json:"t"`
		M string `json:"m"`
	}
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatal(err)
	}
	var evs []cwEvent
	for _, r := range rec {
		evs = append(evs, cwEvent{Stream: r.S, Time: time.UnixMilli(r.T), Message: r.M})
	}
	got, _ := events(logRows(evs, "cloudwatch:/g", evs[0].Time, time.UTC, false))
	kinds := map[string][]Row{}
	for _, r := range got {
		kinds[r["kind_of"].(string)] = append(kinds[r["kind_of"].(string)], r)
	}
	if len(kinds["slow"]) != 2 || len(kinds["lock_wait"]) != 1 || len(kinds["deadlock"]) != 1 || len(kinds) != 3 {
		t.Fatalf("kinds %v", len(kinds))
	}
	for _, r := range kinds["slow"] {
		if s := r["statement"].(string); strings.Contains(s, "rdsauthproxy") || strings.Contains(s, "* Host") {
			t.Errorf("curl lines leaked into a statement: %q", s)
		}
	}
	if d := kinds["deadlock"][0]["detail"].(string); !strings.Contains(d, "Process 1092: begin; update pgvigil_proof_7090") {
		t.Errorf("deadlock detail: %q", d)
	}
}

func TestMaskTextAndZones(t *testing.T) {
	if got := maskText("ALTER ROLE app PASSWORD 'hunter2' VALID UNTIL 'x'"); strings.Contains(got, "hunter2") {
		t.Errorf("password kept: %q", got)
	}
	if got := maskText("host=db password=s3cret dbname=x"); strings.Contains(got, "s3cret") {
		t.Errorf("conninfo password kept: %q", got)
	}
	if got := maskText(strings.Repeat("é", statementsTextMax)); len(got) > statementsTextMax || !strings.HasSuffix(got, "é") {
		t.Errorf("cap: %d bytes, valid end %v", len(got), strings.HasSuffix(got, "é"))
	}
}
