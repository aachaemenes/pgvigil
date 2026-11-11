package collect

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/logparse"
)

// auditLine is one stderr line of pgaudit under the prefix '%m [%p] %q%u@%d ' in the server's zone (PST).
func auditLine(at time.Time, pid int, user, db, rest string) string {
	return fmt.Sprintf("%s PST [%d] %s@%s LOG:  AUDIT: %s\n", at.In(pst).Format("2006-01-02 15:04:05.000"), pid, user, db, rest)
}

// aggAt is an aggregator whose read happens at now (the settle rule is measured from it).
func aggAt(now time.Time, keepText, keepParams bool) *auditAgg {
	a := newAuditAgg(keepText, keepParams)
	a.now = now
	return a
}

func auditCounts(rows []Row) map[string]int64 {
	out := map[string]int64{}
	for _, r := range rows {
		if r["kind"] == "count" {
			k := fmt.Sprintf("%s|%s|%s|%s|%s", r["sec"].(time.Time).UTC().Format("15:04:05"), r["usename"], r["class"], r["command"], r["object_name"])
			out[k] += r["entries"].(int64)
		}
	}
	return out
}

func TestPgauditAgg(t *testing.T) {
	at := time.Date(2026, 11, 11, 20, 0, 1, 0, time.UTC)
	entries := []logparse.AuditEntry{
		{At: at, User: "postgres", Database: "shop", PID: 7, Type: "SESSION", StatementID: 1, SubstatementID: 1, Class: "ROLE", Command: "CREATE ROLE",
			Statement: "create role app password 'hunter2'", Rows: -1, Key: "k1"},
		{At: at, User: "postgres", Database: "shop", PID: 7, Type: "SESSION", StatementID: 2, SubstatementID: 1, Class: "DDL", Command: "DROP TABLE",
			ObjectType: "TABLE", ObjectName: "public.t2", Statement: "drop table t2", Parameters: "42", Rows: 3, Key: "k2"},
		{At: at, User: "app", Database: "shop", PID: 8, Type: "SESSION", Class: "READ", Command: "SELECT", ObjectType: "TABLE", ObjectName: "public.t",
			Statement: "select * from t where name = 'LEAK'", Rows: -1, Key: "k3"},
		{At: at.Add(300 * time.Millisecond), User: "app", Database: "shop", PID: 8, Type: "SESSION", Class: "READ", Command: "SELECT", ObjectType: "TABLE",
			ObjectName: "public.t", Statement: "select * from t where name = 'LEAK'", Rows: -1, Key: "k4"},
		{At: at.Add(time.Second), User: "app", Database: "shop", PID: 8, Type: "OBJECT", Class: "WRITE", Command: "INSERT", ObjectType: "TABLE",
			ObjectName: "public.t", Rows: -1, Key: "k5"},
	}
	for _, c := range []struct {
		text, params bool
	}{{false, false}, {true, false}, {true, true}} {
		a := newAuditAgg(c.text, c.params)
		for _, e := range entries {
			a.add("serverlog:log:f1", "f1", e)
		}
		rows := a.rows()
		if a.entries != 5 || !a.newest.Equal(at.Add(time.Second)) {
			t.Errorf("entries %d newest %s", a.entries, a.newest)
		}
		var events []Row
		for _, r := range rows {
			if r["kind"] == "event" {
				events = append(events, r)
			}
			// a counted entry never carries text, whatever the switches say
			if r["kind"] == "count" {
				if _, has := r["statement"]; has {
					t.Errorf("a count row carries a statement: %v", r)
				}
			}
		}
		if len(events) != 2 {
			t.Fatalf("text %v: %d event rows, want 2 (ROLE and DDL)", c.text, len(events))
		}
		role, ddl := events[0], events[1]
		if role["object_type"] != "ROLE" || role["object_name"] != "app" || role["class"] != "ROLE" || role["usename"] != "postgres" {
			t.Errorf("the role row: %v", role)
		}
		if ddl["row_count"] != int64(3) || ddl["object_name"] != "public.t2" {
			t.Errorf("the ddl row: %v", ddl)
		}
		if _, has := role["row_count"]; has {
			t.Errorf("a row count on an entry without one: %v", role)
		}
		_, hasText := role["statement"]
		_, hasParams := ddl["parameters"]
		if hasText != c.text || hasParams != c.params {
			t.Errorf("text %v params %v: statement kept %v, parameters kept %v", c.text, c.params, hasText, hasParams)
		}
		if c.text {
			if s, _ := role["statement"].(string); !strings.Contains(s, "create role app") || strings.Contains(s, "hunter2") {
				t.Errorf("the kept statement is not masked: %q", s)
			}
		}
		for _, r := range rows {
			for k, v := range r {
				if s, ok := v.(string); ok && strings.Contains(s, "LEAK") {
					t.Errorf("a counted statement's literal is in column %s of %v", k, r)
				}
			}
		}
		got := auditCounts(rows)
		if len(got) != 2 || got["20:00:01|app|READ|SELECT|public.t"] != 2 || got["20:00:02|app|WRITE|INSERT|public.t"] != 1 {
			t.Errorf("counts: %v", got)
		}
	}
	// a SET: pgaudit writes it as MISC; the audit's own settings (however the name is written), a log setting, an
	// enforcement setting and the session authorization given to a named role are rows; every other setting is counted
	// by its name, SET ROLE with the role taken, the session authorization given back with none
	b := newAuditAgg(true, true)
	for i, stmt := range []string{"set pgaudit.log = 'none'", "SET SESSION AUTHORIZATION admin", `SET "PGAUDIT.LOG_CATALOG" = off`,
		"set log_lock_waits = off", "set allow_system_table_mods = on", "SET statement_timeout = '30s'",
		"SET statement_timeout = '5s'", "set role admin", "reset role", "set app.tenant = 'LEAK'",
		"SET SESSION AUTHORIZATION DEFAULT", "reset session authorization"} {
		cmd := "SET"
		if strings.HasPrefix(stmt, "reset") {
			cmd = "RESET"
		}
		b.add("s:f1", "f1", logparse.AuditEntry{At: at, User: "app", Database: "shop", Type: "SESSION", Class: "MISC", Command: cmd,
			Statement: stmt, Rows: -1, Key: fmt.Sprintf("set%d", i)})
	}
	var kept []string
	for _, r := range b.rows() {
		if r["kind"] == "event" {
			kept = append(kept, fmt.Sprintf("%s %s %v", r["class"], r["object_name"], r["target_role"]))
		}
		if r["kind"] == "count" {
			if _, has := r["statement"]; has {
				t.Errorf("a counted SET carries its statement: %v", r)
			}
		}
	}
	if strings.Join(kept, "; ") != "MISC_SET pgaudit.log <nil>; MISC_SET session_authorization admin; MISC_SET pgaudit.log_catalog <nil>; "+
		"MISC_SET log_lock_waits <nil>; MISC_SET allow_system_table_mods <nil>" {
		t.Errorf("SET rows: %v", kept)
	}
	sets := auditCounts(b.rows())
	if len(sets) != 6 || sets["20:00:01|app|MISC_SET|SET|statement_timeout"] != 2 || sets["20:00:01|app|MISC_SET|SET|role = admin"] != 1 ||
		sets["20:00:01|app|MISC_SET|RESET|role"] != 1 || sets["20:00:01|app|MISC_SET|SET|app.tenant"] != 1 ||
		sets["20:00:01|app|MISC_SET|SET|session_authorization"] != 1 || sets["20:00:01|app|MISC_SET|RESET|session_authorization"] != 1 {
		t.Errorf("SET counts: %v", sets)
	}

	// pgaudit 13 to 16: the whole multi-statement text on each entry. Routine SETs that differ are counted with no
	// setting; a string that holds an audit setting keeps each of its entries as a row under it
	c := newAuditAgg(false, false)
	for i := 0; i < 4; i++ {
		c.add("s:f1", "f1", logparse.AuditEntry{At: at, User: "mon", Database: "postgres", Type: "SESSION", Class: "MISC", Command: "SET", StatementID: int64(i + 1),
			Statement: "SET default_transaction_read_only = on;\nSET statement_timeout = '30s';\nSET lock_timeout = '2s';\nSET application_name = 'pgvigil';", Rows: -1, Key: fmt.Sprintf("m%d", i)})
	}
	for i := 0; i < 2; i++ {
		c.add("s:f1", "f1", logparse.AuditEntry{At: at, User: "app", Database: "shop", Type: "SESSION", Class: "MISC", Command: "SET", StatementID: int64(i + 1),
			Statement: "set statement_timeout = 0; set pgaudit.log = 'none'", Rows: -1, Key: fmt.Sprintf("h%d", i)})
	}
	var hidden int
	for _, r := range c.rows() {
		if r["kind"] == "event" {
			hidden++
			if r["usename"] != "app" || r["object_name"] != "pgaudit.log" {
				t.Errorf("a row of the multi-statement strings: %v", r)
			}
		}
	}
	if got := auditCounts(c.rows()); hidden != 2 || len(got) != 1 || got["20:00:01|mon|MISC_SET|SET|"] != 4 {
		t.Errorf("multi-statement SETs: %d rows, counts %v", hidden, got)
	}

	// an entry cut by the end of the read is neither a row nor a count: the next read has it whole
	d := newAuditAgg(true, true)
	d.add("s:f1", "f1", logparse.AuditEntry{At: at, User: "app", Database: "shop", Type: "SESSION", Class: "MISC", Command: "SET",
		Statement: "set", Truncated: true, Rows: -1, Key: "cut1"})
	d.add("s:f1", "f1", logparse.AuditEntry{At: at, User: "app", Database: "shop", Type: "SESSION", Class: "READ", Command: "SELECT",
		Statement: "select", Truncated: true, Rows: -1, Key: "cut2"})
	if d.entries != 0 || len(d.rows()) != 0 {
		t.Errorf("a cut entry was taken: %d entries, %v", d.entries, d.rows())
	}

	// the last entry of a read waits for the next read while it is young: what follows it is not known yet
	last := entries[0]
	last.Last = true
	young, old := aggAt(at.Add(2*time.Second), false, false), aggAt(at.Add(time.Minute), false, false)
	young.add("s:f1", "f1", last)
	old.add("s:f1", "f1", last)
	if young.entries != 0 || len(young.rows()) != 0 || old.entries != 1 || len(old.rows()) != 1 {
		t.Errorf("the settle rule: young %d entries, old %d", young.entries, old.entries)
	}

	// an entry that is not pgaudit's is neither a row nor a count: the read says how many, the newest and whose
	f := aggAt(at.Add(time.Hour), true, true)
	forged := entries[0]
	forged.Forged, forged.User = true, "mallory"
	f.add("s:f1", "f1", forged)
	forged.At = at.Add(-time.Minute)
	f.add("s:f1", "f1", forged)
	if f.entries != 0 || len(f.rows()) != 0 || f.forged != 2 || !f.forgedAt.Equal(at) || f.forgedBy != "mallory@shop" {
		t.Errorf("forged: %d entries, %d forged, at %s by %s", f.entries, f.forged, f.forgedAt, f.forgedBy)
	}

	// the same entry under another file is another row; the same entry twice under one file has one key
	a := newAuditAgg(false, false)
	a.add("s:f1", "f1", entries[0])
	a.add("s:f1", "f1", entries[0])
	a.add("s:f2", "f2", entries[0])
	r := a.rows()
	if r[0]["event_key"] != r[1]["event_key"] || r[0]["event_key"] == r[2]["event_key"] {
		t.Errorf("event keys: %v %v %v", r[0]["event_key"], r[1]["event_key"], r[2]["event_key"])
	}
}

func TestPgauditCloudwatch(t *testing.T) {
	t0 := time.Date(2026, 11, 11, 20, 0, 0, 0, time.UTC)
	line := func(at time.Time, pid int, rest string) string {
		return fmt.Sprintf("%s UTC:10.0.0.5(5000):app@shop:[%d]:LOG:  AUDIT: %s", at.Format("2006-01-02 15:04:05"), pid, rest)
	}
	evs := []cwEvent{
		{Stream: "writer", Time: t0.Add(1 * time.Second), Message: line(t0.Add(1*time.Second), 10, "SESSION,1,1,READ,SELECT,TABLE,public.t,select 1,<not logged>")},
		{Stream: "writer", Time: t0.Add(1 * time.Second), Message: line(t0.Add(1*time.Second), 10, "SESSION,2,1,READ,SELECT,TABLE,public.t,select 1,<not logged>")},
		// an entry of two events: the statement's second line is its own event
		{Stream: "writer", Time: t0.Add(2 * time.Second), Message: line(t0.Add(2*time.Second), 10, `SESSION,3,1,ROLE,GRANT,TABLE,,"grant select`)},
		{Stream: "writer", Time: t0.Add(2 * time.Second), Message: "\ton public.t to bob\",<not logged>"},
		{Stream: "writer", Time: t0.Add(9 * time.Second), Message: "2026-11-11 20:00:09 UTC:10.0.0.5(5000):app@shop:[10]:LOG:  checkpoint starting: time"},
		{Stream: "reader", Time: t0.Add(4 * time.Second), Message: line(t0.Add(4*time.Second), 20, "SESSION,1,1,READ,SELECT,TABLE,public.t,select 1,<not logged>")},
	}
	a := aggAt(t0.Add(time.Hour), false, false)
	readTo, _ := pgauditCloudwatch(evs, "cloudwatch:/g", t0, time.UTC, false, a)
	// the reader stream's latest event is the earliest of the two streams' latest: the next read starts behind it
	if !readTo.Equal(t0.Add(4 * time.Second)) {
		t.Errorf("readTo %s, want the slower stream's latest event", readTo)
	}
	rows := a.rows()
	got := auditCounts(rows)
	if len(got) != 2 || got["20:00:01|app|READ|SELECT|public.t"] != 2 || got["20:00:04|app|READ|SELECT|public.t"] != 1 {
		t.Errorf("counts: %v", got)
	}
	var grant Row
	for _, r := range rows {
		if r["kind"] == "event" {
			grant = r
		}
		if r["kind"] == "count" && r["sec"].(time.Time).Second() == 4 && r["source"] != "cloudwatch:/g:reader" {
			t.Errorf("the reader's count carries the source %v", r["source"])
		}
	}
	if grant == nil || grant["command"] != "GRANT" || grant["object_name"] != "public.t" || grant["target_role"] != "bob" || grant["source"] != "cloudwatch:/g:writer" {
		t.Errorf("the grant row: %v", grant)
	}
	// a full batch: one overlap past its last event, so the next read starts a guard second before that event's second
	if got, extra := pgauditCloudwatch(evs, "cloudwatch:/g", t0, time.UTC, true, aggAt(t0.Add(time.Hour), false, false)); !got.Equal(t0.Add(9*time.Second+logsOverlap)) || len(extra) != 0 {
		t.Errorf("full batch readTo %s %v", got, extra)
	}
	// a full batch that did not get two seconds past its start: the cursor goes one second on, and the read says so
	if got, extra := pgauditCloudwatch(evs[:2], "cloudwatch:/g", t0, time.UTC, true, aggAt(t0.Add(time.Hour), false, false)); !got.Equal(t0.Add(2*time.Second+logsOverlap)) || len(extra) != 1 {
		t.Errorf("stalled batch readTo %s %v", got, extra)
	}
	// nothing fetched: the cursor stays
	if got, _ := pgauditCloudwatch(nil, "cloudwatch:/g", t0, time.UTC, false, aggAt(t0.Add(time.Hour), false, false)); !got.Equal(t0) {
		t.Errorf("empty readTo %s", got)
	}
}

// A second read that starts at an earlier whole second counts every second it reads in full as the first read did
// (the import then gains nothing), and counts the newest second higher once that second has grown.
func TestPgauditServerlogRereadCountsTheSame(t *testing.T) {
	lp, err := compilePrefix("%m [%p] %q%u@%d ")
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 11, 11, 20, 0, 0, 0, time.UTC)
	var b strings.Builder
	// 3 entries in each of the seconds 0..4, at .100, .400 and .700
	for s := 0; s < 5; s++ {
		for i, ms := range []int{100, 400, 700} {
			b.WriteString(auditLine(t0.Add(time.Duration(s)*time.Second+time.Duration(ms)*time.Millisecond), 30, "app", "shop",
				fmt.Sprintf("SESSION,%d,1,READ,SELECT,TABLE,public.t,select 1,<not logged>", s*3+i+1)))
		}
	}
	b.WriteString("2026-11-11 12:00:05.000 PST [30] app@shop LOG:  duration: 1.5 ms  statement: select 'AUDIT: SESSION,1,1,READ,SELECT,,,x,y'\n")
	dir := &memDir{files: map[string]string{"pg.log": b.String()}, mod: map[string]time.Time{"pg.log": t0.Add(time.Minute)}}
	read := func(from time.Time) (map[string]int64, time.Time, []Row) {
		a := aggAt(t0.Add(time.Hour), false, false)
		readTo, extra, err := pgauditServerlog(context.Background(), dir, lp, fixedZone(pst), "serverlog:log", from, serverlogMaxBytes, a)
		if err != nil {
			t.Fatal(err)
		}
		return auditCounts(a.rows()), readTo, extra
	}
	first, readTo, extra := read(t0)
	if len(first) != 5 || len(extra) != 0 {
		t.Fatalf("first read: %v %v", first, extra)
	}
	for k, n := range first {
		if n != 3 {
			t.Errorf("second %s counted %d, want 3", k, n)
		}
	}
	if !readTo.Equal(t0.Add(5 * time.Second)) { // the slow statement's line is the newest line read
		t.Errorf("readTo %s", readTo)
	}
	// the second 4 grows by two entries; the next read starts two whole seconds back
	dir.files["pg.log"] += auditLine(t0.Add(4*time.Second+800*time.Millisecond), 31, "app", "shop", "SESSION,1,1,READ,SELECT,TABLE,public.t,select 1,<not logged>") +
		auditLine(t0.Add(4*time.Second+900*time.Millisecond), 31, "app", "shop", "SESSION,2,1,READ,SELECT,TABLE,public.t,select 1,<not logged>")
	second, _, _ := read(t0.Add(2 * time.Second))
	if len(second) != 3 || second["20:00:02|app|READ|SELECT|public.t"] != 3 || second["20:00:03|app|READ|SELECT|public.t"] != 3 ||
		second["20:00:04|app|READ|SELECT|public.t"] != 5 {
		t.Errorf("second read: %v", second)
	}
}

// A run that spends its whole budget inside the first two seconds: the cursor goes a second on and the run says what
// it left.
func TestPgauditServerlogSecondOverBudget(t *testing.T) {
	lp, err := compilePrefix("%m [%p] %q%u@%d ")
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 11, 11, 20, 0, 0, 0, time.UTC)
	var b strings.Builder
	for i := 0; i < 200; i++ {
		b.WriteString(auditLine(t0.Add(time.Duration(i)*time.Millisecond), 30, "app", "shop",
			fmt.Sprintf("SESSION,%d,1,READ,SELECT,TABLE,public.t,select 1,<not logged>", i+1)))
	}
	b.WriteString(auditLine(t0.Add(3*time.Second), 30, "app", "shop", "SESSION,999,1,READ,SELECT,TABLE,public.t,select 1,<not logged>"))
	dir := &memDir{files: map[string]string{"pg.log": b.String()}, mod: map[string]time.Time{"pg.log": t0.Add(time.Minute)}}
	a := aggAt(t0.Add(time.Hour), false, false)
	readTo, extra, err := pgauditServerlog(context.Background(), dir, lp, fixedZone(pst), "serverlog:log", t0, 4096, a)
	if err != nil {
		t.Fatal(err)
	}
	if !readTo.Equal(t0.Add(pgauditGuard + time.Second + logsOverlap)) {
		t.Errorf("readTo %s, want two seconds past the start plus the overlap (the next read then starts one second on)", readTo)
	}
	if len(extra) != 1 || extra[0]["kind"] != "collector_error" || !strings.Contains(extra[0]["message"].(string), "what is left of them is not read") {
		t.Errorf("extra rows: %v", extra)
	}
	if a.entries == 0 || a.entries >= 200 {
		t.Errorf("entries read within the budget: %d", a.entries)
	}
}

// The cursor always moves on. Each read starts where the repository's cursor rule puts it (the largest read_to
// stored, pgauditFrom); a log that holds more than a run's budget in one second, or one line longer than the budget,
// must not bring a read back to where an earlier one started.
func TestPgauditServerlogCursorMovesOn(t *testing.T) {
	t0 := time.Date(2026, 11, 11, 20, 0, 0, 0, time.UTC)
	stamp := func(at time.Time, layout string) string { return at.In(pst).Format(layout) + " PST" }
	for _, c := range []struct {
		name, prefix, layout string
		build                func(line func(at time.Time, rest string) string) string
	}{
		// a prefix of whole seconds (%t): 300 entries stamped with the one second t0+10, then one at t0+20
		{"a second above the budget, %t", "%t [%p] %q%u@%d ", "2006-01-02 15:04:05", func(line func(time.Time, string) string) string {
			var b strings.Builder
			for i := 0; i < 300; i++ {
				b.WriteString(line(t0.Add(10*time.Second), fmt.Sprintf("SESSION,%d,1,READ,SELECT,TABLE,public.t,select 1,<not logged>", i+1)))
			}
			b.WriteString(line(t0.Add(20*time.Second), "SESSION,999,1,ROLE,CREATE ROLE,,,create role after_it,<not logged>"))
			b.WriteString(line(t0.Add(21*time.Second), "SESSION,1000,1,READ,SELECT,TABLE,public.t,select 1,<not logged>"))
			return b.String()
		}},
		// one line longer than the budget, the first of its second, the next line 300 ms after it
		{"a line above the budget", "%m [%p] %q%u@%d ", "2006-01-02 15:04:05.000", func(line func(time.Time, string) string) string {
			return line(t0.Add(10*time.Second), "SESSION,1,1,WRITE,INSERT,TABLE,public.t,insert into t values ('"+strings.Repeat("x", 9000)+"'),<not logged>") +
				line(t0.Add(10*time.Second+300*time.Millisecond), "SESSION,2,1,READ,SELECT,TABLE,public.t,select 1,<not logged>") +
				line(t0.Add(20*time.Second), "SESSION,999,1,ROLE,CREATE ROLE,,,create role after_it,<not logged>") +
				line(t0.Add(21*time.Second), "SESSION,1000,1,READ,SELECT,TABLE,public.t,select 1,<not logged>")
		}},
	} {
		lp, err := compilePrefix(c.prefix)
		if err != nil {
			t.Fatal(err)
		}
		text := c.build(func(at time.Time, rest string) string {
			return fmt.Sprintf("%s [30] app@shop LOG:  AUDIT: %s\n", stamp(at, c.layout), rest)
		})
		dir := &memDir{files: map[string]string{"pg.log": text}, mod: map[string]time.Time{"pg.log": t0.Add(time.Minute)}}
		cursor, found, lastFrom, sawAfter := time.Time{}, false, time.Time{}, false
		now := t0.Add(9*time.Second + logsOverlap + pgauditGuard) // the first read starts at t0+9s, as after an earlier read
		cursor, found = now.Add(-pgauditGuard), true
		for run := 0; run < 40 && !sawAfter; run++ {
			from := pgauditFrom(cursor, found, now)
			if run > 0 && !from.After(lastFrom) {
				t.Fatalf("%s: read %d starts at %s, no later than the read before it (%s): the reader stalls", c.name, run, from, lastFrom)
			}
			lastFrom = from
			a := aggAt(t0.Add(time.Hour), false, false)
			readTo, _, err := pgauditServerlog(context.Background(), dir, lp, fixedZone(pst), "serverlog:log", from, 4096, a)
			if err != nil {
				t.Fatal(err)
			}
			if readTo.After(cursor) { // the repository keeps the largest
				cursor = readTo
			}
			for _, r := range a.rows() {
				if r["kind"] == "event" && r["object_name"] == "after_it" {
					sawAfter = true
				}
			}
		}
		if !sawAfter {
			t.Errorf("%s: the entry after the heavy stretch was never read (the cursor ended at %s)", c.name, cursor)
		}
	}
}
