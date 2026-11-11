package logparse

import (
	"strings"
	"testing"
)

func TestMessageShape(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{`relation "orders_typo" does not exist`, `relation "..." does not exist`},
		{`relation "nosuch_a" does not exist at character 15`, `relation "..." does not exist`},
		{`duplicate key value violates unique constraint "a""b"`, `duplicate key value violates unique constraint "..."`},
		{`invalid input syntax for type integer: 'x''y'`, `invalid input syntax for type integer: '...'`},
		{`process 2001 still waiting for ExclusiveLock on tuple (0,5) of relation 16384 of database 5 after 1000.071 ms`,
			`process ... still waiting for ExclusiveLock on tuple (...) of relation ... of database ... after ... ms`},
		{`zeroing out 3 invalid pages among blocks 8..15 of relation "base/1/2"`, `zeroing out ... invalid pages among blocks ... of relation "..."`},
		{`redo starts at 0/1A2B3C4D`, `redo starts at ...`},
		{`no such table pg_toast_2619 or t1`, `no such table ... or ...`}, // a name with a digit is masked too
		{"  two\t spaces  ", `two spaces`},
		{`value -5 and $1 and x.5`, `value ... and ... and ...`},
		// review 1: values a shape must not keep
		{`Customer alice@example.com has insufficient balance`, `Customer ... has insufficient balance`},
		{`balance $5000 too low for acct_7781`, `balance ... too low for ...`},
		{`token 3fa9c0 expired`, `token ... expired`},
		{`card 550e8400-e29b-41d4-a716-446655440000 declined`, `card ... declined`},
		{`malformed array literal: "{"secret1","secret2"}"`, `malformed array literal: "..."`},
		{`host 10.0.0.5 refused`, `host ... refused`},
		{`column "x" of relation "y" does not exist`, `column "..." does not exist`}, // greedy: the two names are one run
		{"caf\u00e9 1\u00a0x", "caf\u00e9 ...\u00a0x"},                               // ASCII rules: an NBSP is not white space
	} {
		if got := MessageShape(c.in); got != c.want {
			t.Errorf("MessageShape(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	if got := []rune(MessageShape(strings.Repeat("\u00e9", 400))); len(got) != messageShapeMax {
		t.Errorf("cap: %d characters, want %d", len(got), messageShapeMax)
	}
}

// events-grouped.log: two checkpoints (PostgreSQL 13's complete line and 18's, with SLRU buffers and the LSNs), a
// standby's restartpoint start, two duplicate-key errors (one shape), a WARNING, an error raised inside PL/pgSQL, a
// LOG line no rule takes (not stored) and the frequent-checkpoint warning (its own class); then two back-to-back wal
// checkpoints whose first complete and second start share a second.
func TestEventsGrouped(t *testing.T) {
	evs := parseFile(t, "events-grouped.log")
	want := []struct {
		kind  Kind
		level string
		msg   string
		dur   float64
	}{
		{Checkpoint, "LOG", "checkpoint starting: time", 0},
		{Checkpoint, "LOG", "checkpoint complete: wrote ... buffers (...%); ... WAL file(s) added, ... removed, ... recycled; write=... s, sync=... s, total=... s; sync files=..., longest=... s, average=... s; distance=... kB, estimate=... kB", 317},
		{Checkpoint, "LOG", "checkpoint starting: immediate force wait", 0},
		{Checkpoint, "LOG", "checkpoint complete: wrote ... buffers (...%), wrote ... SLRU buffers; ... WAL file(s) added, ... removed, ... recycled; write=... s, sync=... s, total=... s; sync files=..., longest=... s, average=... s; distance=... kB, estimate=... kB; lsn=..., redo lsn=...", 358},
		{Checkpoint, "LOG", "restartpoint starting: wal", 0},
		{Error, "ERROR", `duplicate key value violates unique constraint "..."`, 0},
		{Error, "ERROR", `duplicate key value violates unique constraint "..."`, 0},
		{Error, "WARNING", "there is no transaction in progress", 0},
		{Error, "ERROR", `invalid input syntax for type integer: "..."`, 0},
		{CheckpointFrequent, "LOG", "checkpoints are occurring too frequently (... seconds apart)", 0},
	}
	if len(evs) != len(want)+4 {
		t.Fatalf("got %d events, want %d: %+v", len(evs), len(want)+4, evs)
	}
	for i, w := range want {
		e := evs[i]
		if e.Kind != w.kind || e.Level != w.level || e.Message != w.msg || e.DurationMS != w.dur {
			t.Errorf("event %d = %s/%s/%q/%v, want %s/%s/%q/%v", i, e.Kind, e.Level, e.Message, e.DurationMS, w.kind, w.level, w.msg, w.dur)
		}
	}
	// the duplicate key's DETAIL (a row value) is in Detail, which the query-text policy governs (Error is not a
	// message-detail kind); its STATEMENT is the statement
	if evs[5].Detail != "duplicate key value violates unique constraint \"orders_pkey\"\nDETAIL: Key (id)=(42) already exists." ||
		evs[5].Statement != "insert into orders values (42, 'secret')" || DetailIsMessage(Error) {
		t.Errorf("error detail / statement: %q / %q", evs[5].Detail, evs[5].Statement)
	}
	// a CONTEXT that quotes a statement goes to Statement, the function line stays in Detail
	if evs[8].Statement != "select 'abc'::int" || !strings.Contains(evs[8].Detail, "CONTEXT: PL/pgSQL function f() line 3 at PERFORM") {
		t.Errorf("error context: %q / %q", evs[8].Statement, evs[8].Detail)
	}
	// a complete line carries its start, paired in log order (review 1): the PG 13 checkpoint and the PG 18 one; the
	// restartpoint's start has no completion
	if !DetailIsMessage(Checkpoint) || !strings.HasSuffix(evs[1].Detail, "\nSTARTED: 2026-11-10T10:00:00Z time") ||
		!strings.HasSuffix(evs[3].Detail, "\nSTARTED: 2026-11-10T10:01:00Z immediate force wait") || strings.Contains(evs[4].Detail, "STARTED") {
		t.Errorf("checkpoint pairing: %q / %q / %q", evs[1].Detail, evs[3].Detail, evs[4].Detail)
	}
	// two back-to-back wal checkpoints with a whole-seconds prefix: the first's complete and the second's start share
	// 10:04:40; each complete pairs with its own start
	ck := byKind(evs[10:], Checkpoint)
	if len(ck) != 4 || !strings.HasSuffix(ck[1].Detail, "\nSTARTED: 2026-11-10T10:04:00Z wal") ||
		!strings.HasSuffix(ck[3].Detail, "\nSTARTED: 2026-11-10T10:04:40Z wal") || strings.Contains(ck[2].Detail, "STARTED") {
		t.Errorf("same-second pairing: %+v", ck)
	}
	if !KnownKind("error") || !KnownKind("checkpoint") {
		t.Error("AllKinds lacks error or checkpoint")
	}
}
