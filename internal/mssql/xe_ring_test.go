package mssql

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestSysHealthDoneRing (A2 review 4, 6): system_health's state row after a ring buffer read - the events passed over
// apart from the ones stored, and a ring that came back cut off or dropped events said in its note (before: both
// counts were every event past the cursor, and the cut-off and dropped counts were lost).
func TestSysHealthDoneRing(t *testing.T) {
	var got []collect.Row
	emit := func(rows []collect.Row) error { got = append(got, rows...); return nil }
	none := func(context.Context, string) (Cursor, error) { return Cursor{}, nil }
	side := collect.Row{"new_events": int64(2), "scanned_events": int64(40), "truncated": true, "dropped_events": int64(3)}
	if err := sysHealthDone(context.Background(), none, emit, "ring_buffer", side); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("rows %v", got)
	}
	s := got[0]
	note, _ := s["note"].(string)
	if s["scope"] != "ring_buffer" || s["scanned"] != int64(40) || s["stored"] != int64(2) ||
		!strings.Contains(note, "cut off: the newest events are the ones missing") || !strings.Contains(note, "3 event(s) dropped") {
		t.Fatalf("state row %v", s)
	}
	// a whole ring with nothing dropped: no note
	got = nil
	if err := sysHealthDone(context.Background(), none, emit, "ring_buffer", collect.Row{"new_events": int64(0), "scanned_events": int64(0), "truncated": false, "dropped_events": int64(0)}); err != nil {
		t.Fatal(err)
	}
	if got[0]["note"] != nil || got[0]["scanned"] != int64(0) || got[0]["stored"] != int64(0) {
		t.Fatalf("a whole ring: %v", got[0])
	}
}

// TestReadSessionMIFileOnly (A2 review 8): on a Managed Instance a server's own session with an event file alone
// (AlwaysOn_health on Business Critical) is a note on its state row, never a failed read; the product's own session
// in that shape (the wrong -form installed) stays an error.
func TestReadSessionMIFileOnly(t *testing.T) {
	r := &xeRun{ctx: context.Background(), info: Info{Kind: KindAzureMI}, opt: BatchOptions{Deadline: time.Now().Add(time.Hour)}}
	s := &xeSession{name: "AlwaysOn_health", running: true, targets: map[string]xeTarget{"event_file": {}}}
	state := collect.Row{}
	if err := r.readSession(s, "AlwaysOn_health", xeAGEvents, state); err != nil {
		t.Fatalf("AlwaysOn_health file-only on MI: %v, want a note", err)
	}
	if n, _ := state["note"].(string); !strings.Contains(n, "Azure Blob storage URL") {
		t.Fatalf("state %v", state)
	}
	p := &xeSession{name: "pgvigil_x_deadlocks", running: true, targets: map[string]xeTarget{"event_file": {}}}
	if err := r.readSession(p, "product", []string{"xml_deadlock_report"}, collect.Row{}); err == nil || !strings.Contains(err.Error(), "Azure Blob storage URL") {
		t.Fatalf("the product's file-only session on MI: %v, want the error", err)
	}
}

// TestRingRowsSysHealth (A2 review 4, 5, 6): system_health's ring buffer as a Managed Instance's syshealth reader takes
// it - only the events past the cursor, new_events the wanted ones and scanned_events all of them, the cut-off flag
// and the dropped count kept, the batch's cursor at the newest event; a ring whose oldest event is newer than the
// cursor says it wrapped between reads.
func TestRingRowsSysHealth(t *testing.T) {
	cutAt := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	head := `<RingBufferTarget truncated="1" processingTime="0" totalEventsProcessed="900" eventCount="4" droppedCount="3" memoryUsed="4096">`
	run := func(doc string) ([]collect.Row, collect.Row) {
		t.Helper()
		ring, err := parseRing(doc)
		if err != nil {
			t.Fatal(err)
		}
		var rows []collect.Row
		r := &xeRun{ctx: context.Background(), info: Info{Kind: KindAzureMI}, now: time.Date(2026, 11, 14, 0, 0, 0, 0, time.UTC),
			opt:    BatchOptions{Deadline: time.Now().Add(time.Hour)},
			cursor: func(context.Context, string) (Cursor, error) { return Cursor{Found: true, LastEventAt: cutAt}, nil },
			emit:   func(b []collect.Row) error { rows = append(rows, b...); return nil }}
		side := collect.Row{}
		if err := r.ringRows(sysHealthSource, ring, 1, sysEventList(), xeContext{source: "system_health", session: "system_health"}, side); err != nil {
			t.Fatal(err)
		}
		return rows, side
	}
	// one event before the cursor (passed over), two wanted after it, one the reader does not store (a batch event)
	rows, side := run(head + fixtureSystemClean + fixtureResourceWarning + fixBatch + fixtureBroker + `</RingBufferTarget>`)
	if side["new_events"] != int64(2) || side["scanned_events"] != int64(3) || side["truncated"] != true || side["dropped_events"] != int64(4) {
		t.Fatalf("side %v", side)
	}
	if n, _ := side["note"].(string); strings.Contains(n, "wrapped") {
		t.Fatalf("an event older than the cursor is still in the ring: no wrap, got %q", n)
	}
	var comps, cursors int
	var last collect.Row
	for _, row := range rows {
		switch row["kind"] {
		case "component":
			comps++
		case CursorKind:
			cursors++
			last = row
		}
	}
	if comps != 2 || cursors != 1 || !strings.HasPrefix(last["last_event_at"].(string), "2026-11-12T01:02:03.456") {
		t.Fatalf("rows: %d components, %d cursors, the last %v (all: %v)", comps, cursors, last, rows)
	}
	// the ring wrapped between reads: its oldest event is newer than the cursor
	_, side = run(head + fixtureResourceWarning + fixtureBroker + `</RingBufferTarget>`)
	if n, _ := side["note"].(string); !strings.Contains(n, "wrapped between reads") {
		t.Fatalf("no wrap note: %v", side)
	}
}

// TestRingRowsFailedBatchNotDone (B24 Fixed 1, its build review part A, finding 1): a ring read whose batch import
// fails leaves no new_events (nor scanned_events) in its state, so 0153's mssql_attention_reads never marks that read
// done and the cursor takes its events again next run; before, new_events was set ahead of the batches.
func TestRingRowsFailedBatchNotDone(t *testing.T) {
	cutAt := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	head := `<RingBufferTarget truncated="0" processingTime="0" totalEventsProcessed="900" eventCount="4" droppedCount="0" memoryUsed="4096">`
	ring, err := parseRing(head + fixtureSystemClean + fixtureResourceWarning + fixBatch + fixtureBroker + `</RingBufferTarget>`)
	if err != nil {
		t.Fatal(err)
	}
	was := xeBatchEvents
	xeBatchEvents = 1 // one event per batch: three batches past the cursor
	defer func() { xeBatchEvents = was }()
	for _, c := range []xeContext{{source: "system_health", session: "system_health"}, {source: "product", session: "pgvigil_attention"}} {
		calls := 0
		r := &xeRun{ctx: context.Background(), info: Info{Kind: KindAzureMI}, now: time.Date(2026, 11, 14, 0, 0, 0, 0, time.UTC),
			opt:    BatchOptions{Deadline: time.Now().Add(time.Hour)},
			cursor: func(context.Context, string) (Cursor, error) { return Cursor{Found: true, LastEventAt: cutAt}, nil },
			emit: func([]collect.Row) error {
				calls++
				if calls == 2 {
					return context.Canceled // the store refused the second batch
				}
				return nil
			}}
		state := collect.Row{}
		if err := r.ringRows(sysHealthSource, ring, 0, sysEventList(), c, state); err == nil {
			t.Fatalf("%s: the failed batch gave no error", c.source)
		}
		if v, ok := state["new_events"]; ok {
			t.Fatalf("%s: a read whose second batch failed carries new_events %v: it would count as a done read", c.source, v)
		}
		if v, ok := state["scanned_events"]; ok {
			t.Fatalf("%s: a read whose second batch failed carries scanned_events %v", c.source, v)
		}
		if calls != 2 {
			t.Fatalf("%s: %d batch imports, want 2 (the read stops at the failed one)", c.source, calls)
		}
	}
}
