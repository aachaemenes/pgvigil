package web

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestCollectorBackoffWordsL214 (L214, B2): the Collector page names an instance backing off - the handler computes
// 'backing off: <n> connects failed in a row' and the next try from the stored (connect) streak with the same Go rule
// the loop uses (collect.BackoffWindow), and collector.ts shows the line (its times in the page's format: N-2).
func TestCollectorBackoffWordsL214(t *testing.T) {
	q, err := os.ReadFile("q_collector.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"collect.BackoffWindow", "backing_off", "backing off: "} {
		if !strings.Contains(string(q), want) {
			t.Errorf("q_collector.go lacks %q: the streak rows carry no backing-off line", want)
		}
	}
	ts, err := os.ReadFile(filepath.Join("..", "..", "web", "src", "collector.ts"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"backing_off", "backoff_next", "due now"} {
		if !strings.Contains(string(ts), want) {
			t.Errorf("collector.ts lacks %q: the page never shows the backing-off line", want)
		}
	}
}

// TestBackingOff (rn-l214 S-5): the streaks' rework over a table, offline - a connect streak of 3 or more gains its
// words and its next try (the instance's shortest interval capping the wait: B-1), every other row nil; a table
// without a column it reads gains neither column, never panics, and the reason is logged.
func TestBackingOff(t *testing.T) {
	last := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	tb := &table{
		Columns: []string{"instance_id", "instance", "collection", "fail_streak", "failing_since", "last_run_at", "last_error", "every_s"},
		Rows: [][]any{
			{int32(1), "pg1", "(connect)", int32(4), last.Add(-5 * time.Minute), last, "refused", nil},
			{int32(1), "pg1", "activity", int32(9), last, last, "permission denied", nil},
			{int32(2), "pg2", "(connect)", int32(2), last, last, "refused", int32(60)},
			{int32(3), "pg3", "(connect)", int32(9), last, last, "refused", int32(60)},
			{int32(4), "pg4", "(connect)", int32(9), nil, nil, "refused", int32(60)},
		},
	}
	backingOff(tb, nil)
	if n := len(tb.Columns); n != 10 || tb.Columns[8] != "backing_off" || tb.Columns[9] != "backoff_next" {
		t.Fatalf("columns %v: want backing_off and backoff_next added", tb.Columns)
	}
	for i, want := range []struct {
		words any
		next  any
	}{
		{"backing off: 4 connects failed in a row", last.Add(2 * time.Minute)}, // no interval known: the doubling alone
		{nil, nil}, // a collection's streak
		{nil, nil}, // two failures: no back-off yet
		{"backing off: 9 connects failed in a row", last.Add(3 * time.Minute)}, // a minute instance: the cap at 1 + 2 minutes
		{nil, nil}, // no last run: nothing to count from
	} {
		row := tb.Rows[i]
		if row[8] != want.words {
			t.Errorf("row %d: backing_off = %v, want %v", i, row[8], want.words)
		}
		if got, ok := row[9].(time.Time); want.next == nil && row[9] != nil || want.next != nil && (!ok || !got.Equal(want.next.(time.Time))) {
			t.Errorf("row %d: backoff_next = %v, want %v", i, row[9], want.next)
		}
	}
	var buf bytes.Buffer
	short := &table{Columns: []string{"instance_id", "collection", "fail_streak", "every_s"}, Rows: [][]any{{int32(1), "(connect)", int32(4), nil}}}
	backingOff(short, slog.New(slog.NewTextHandler(&buf, nil)))
	if len(short.Columns) != 4 || len(short.Rows[0]) != 4 {
		t.Errorf("a table without last_run_at gained columns: %v", short.Columns)
	}
	if !strings.Contains(buf.String(), "no column last_run_at") {
		t.Errorf("the missing column is not logged: %q", buf.String())
	}
}
