package collect

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestLogRowsFromRecordedEvents(t *testing.T) {
	raw, err := os.ReadFile("../logparse/testdata/aurora.log")
	if err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	var evs []cwEvent
	for i, line := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		// one CloudWatch event per log line, the same lines in two streams (two instances), stream b given in reverse
		evs = append(evs, cwEvent{Stream: "a", Time: base.Add(time.Duration(i) * time.Second), Message: line})
	}
	for i := len(evs) - 1; i >= 0; i-- {
		evs = append(evs, cwEvent{Stream: "b", Time: evs[i].Time, Message: evs[i].Message})
	}
	from := base.Add(-time.Minute)
	rows := logRows(evs, "cloudwatch:/g", from)
	kinds := map[string]int{}
	keys := map[string]bool{}
	var cursor Row
	for _, r := range rows {
		if r["kind"] == "cursor" {
			cursor = r
			continue
		}
		kinds[r["source"].(string)+"/"+r["kind_of"].(string)]++
		keys[r["event_key"].(string)] = true
	}
	for _, s := range []string{"a", "b"} {
		p := "cloudwatch:/g:" + s + "/"
		if kinds[p+"slow"] != 2 || kinds[p+"lock_wait"] != 1 || kinds[p+"deadlock"] != 1 || kinds[p+"auth_fail"] != 2 {
			t.Errorf("stream %s kinds = %v", s, kinds)
		}
	}
	if len(keys) != 12 {
		t.Errorf("distinct event keys %d, want 12", len(keys))
	}
	if cursor == nil || !cursor["read_to"].(time.Time).Equal(evs[len(evs)/2-1].Time) {
		t.Errorf("cursor %v, want %v", cursor, evs[len(evs)/2-1].Time)
	}
	again := logRows(evs, "cloudwatch:/g", from)
	for i := range rows {
		if rows[i]["event_key"] != again[i]["event_key"] {
			t.Fatalf("event key changed on a re-read at row %d", i)
		}
	}
}
