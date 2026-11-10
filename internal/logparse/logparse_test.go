package logparse

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestParseAuroraFixture(t *testing.T) {
	f, err := os.Open("testdata/aurora.log")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	evs, err := Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	want := []struct {
		kind Kind
		pid  int
		dur  float64
		stmt string
	}{
		{Slow, 1234, 612.345, "select pg_sleep(0.6),\n'two lines'"},
		{Slow, 1235, 1500, "update orders set x = $1 where id = $2"},
		{LockWait, 2001, 1000.071, "update orders set x = 1 where id = 1"},
		{Deadlock, 2001, 0, "update orders set x = 1 where id = 1"},
		{AuthFail, 3001, 0, ""},
		{AuthFail, 4001, 0, ""},
	}
	if len(evs) != len(want) {
		t.Fatalf("got %d events, want %d: %+v", len(evs), len(want), evs)
	}
	for i, w := range want {
		e := evs[i]
		if e.Kind != w.kind || e.PID != w.pid || e.DurationMS != w.dur || e.Statement != w.stmt {
			t.Errorf("event %d = %s/%d/%v/%q, want %s/%d/%v/%q", i, e.Kind, e.PID, e.DurationMS, e.Statement, w.kind, w.pid, w.dur, w.stmt)
		}
	}
	if evs[0].User != "app" || evs[0].Database != "shop" || evs[0].Client != "10.0.0.5(54321)" || evs[0].At.UTC().Format("15:04:05") != "12:00:01" {
		t.Errorf("prefix fields: %+v", evs[0])
	}
	if d := evs[3].Detail; d == "" || !strings.Contains(d, "Process 2002: update orders set x = 2 where id = 2") {
		t.Errorf("deadlock detail lost its continuation lines: %q", d)
	}
	if evs[2].Detail != "Process holding the lock: 2002. Wait queue: 2001." {
		t.Errorf("lock wait detail: %q", evs[2].Detail)
	}
}

func TestParseZonesAndIPv6(t *testing.T) {
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skip("no tzdata")
	}
	in := `2026-11-09 04:00:01 PST:[2600:1f16::5](54321):app@shop:[11]:LOG:  duration: 600.000 ms  statement: select 1
2026-11-09 15:00:01 +03:2600:1f16::5(54321):app@shop:[12]:LOG:  duration: 600.000 ms  statement: select 2
2026-11-09 12:00:01.250 UTC:[local]:app@shop:[13]:LOG:  duration: 600.000 ms  statement: select 3
`
	evs, err := ParseIn(strings.NewReader(in), la)
	if err != nil || len(evs) != 3 {
		t.Fatalf("events %d err %v", len(evs), err)
	}
	for i, want := range []string{"12:00:01", "12:00:01", "12:00:01.25"} {
		if got := evs[i].At.UTC().Format("15:04:05.999"); got != want {
			t.Errorf("event %d at %s UTC, want %s", i, got, want)
		}
	}
	if evs[1].Client != "2600:1f16::5(54321)" {
		t.Errorf("IPv6 client %q", evs[1].Client)
	}
}
func parseFile(t *testing.T, name string) []Event {
	t.Helper()
	f, err := os.Open("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	evs, err := Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	return evs
}

func byKind(evs []Event, k Kind) []Event {
	var out []Event
	for _, e := range evs {
		if e.Kind == k {
			out = append(out, e)
		}
	}
	return out
}

// The two recordings are one PostgreSQL 18.6 cluster (initdb -k) with io_method worker and sync: a heap page
// overwritten (read plain, with ignore_checksum_failure, and a second page with zero_damaged_pages), a heap file
// truncated under its index, a heap file removed, a TOAST chunk killed with pg_surgery, and two auto_explain plans
// (text, then JSON with analyze). Each damaged read is one ERROR / WARNING and, at LOG level, the checksum line.
func TestCorruptionRecorded(t *testing.T) {
	want := []string{
		"page verification failed, calculated checksum 49361 but expected 16954",
		`invalid page in block 0 of relation "base/5/16387"`,
		"page verification failed, calculated checksum 49361 but expected 16954",
		`ignoring checksum failure in block 0 of relation "base/5/16387"`,
		"page verification failed, calculated checksum 30537 but expected 8583",
		`invalid page in block 0 of relation "base/5/16403"; zeroing out page`,
		`could not read blocks 20..20 in file "base/5/16395": read only 0 of 8192 bytes`,
		`could not open file "base/5/16408": No such file or directory`,
		"unexpected chunk number 1 (expected 0) for toast value 16416 in pg_toast_16411",
	}
	for _, name := range []string{"corruption-pg18-ioworker.log", "corruption-pg18-iosync.log"} {
		evs := parseFile(t, name)
		c := byKind(evs, Corruption)
		if len(c) != len(want) {
			t.Fatalf("%s: %d corruption events, want %d: %+v", name, len(c), len(want), c)
		}
		for i, w := range want {
			if first := strings.SplitN(c[i].Detail, "\n", 2)[0]; first != w {
				t.Errorf("%s: corruption %d = %q, want %q", name, i, first, w)
			}
		}
		if c[1].Statement != "select count(*) from hp" {
			t.Errorf("%s: the invalid page's statement = %q", name, c[1].Statement)
		}
		p := byKind(evs, Plan)
		if len(p) != 2 {
			t.Fatalf("%s: %d plans, want 2", name, len(p))
		}
		if !strings.HasPrefix(p[0].Statement, "Query Text: set auto_explain.log_min_duration=0; select count(*) from hp where id < 100;\nAggregate  (cost=") ||
			!strings.Contains(p[0].Statement, "\n        ->  Bitmap Index Scan on hp_pkey") {
			t.Errorf("%s: the text plan lost its shape: %q", name, p[0].Statement)
		}
		if !strings.HasPrefix(p[1].Statement, "{\n  \"Query Text\": ") || !strings.HasSuffix(p[1].Statement, "\n}") || p[1].DurationMS <= 0 {
			t.Errorf("%s: the JSON plan: %v ms %q", name, p[1].DurationMS, p[1].Statement)
		}
		if n := len(evs) - len(c) - len(p); n != 0 {
			t.Errorf("%s: %d other events, want 0", name, n)
		}
	}
}

// corruption-constructed.log is written by hand (the messages PostgreSQL's source raises that the recording could
// not produce: the freeze checks, a missing chunk, the pre-18 WARNING and short read, the commit log, a PANIC) with
// three lines that must not count: a missing COPY input file, a missing pg_hba.conf at LOG, an unknown relation; then
// the B-tree page check, the multixact wraparound and two of PostgreSQL 18's combined-read messages (read from its
// message catalogue, not produced).
func TestCorruptionConstructed(t *testing.T) {
	evs := parseFile(t, "corruption-constructed.log")
	c := byKind(evs, Corruption)
	want := []int{5101, 5102, 5103, 5104, 5104, 5105, 5106, 5107, 5111, 5112, 5113, 5114}
	if len(c) != len(want) || len(evs) != len(want) {
		t.Fatalf("got %d corruption of %d events, want %d: %+v", len(c), len(evs), len(want), evs)
	}
	for i, pid := range want {
		if c[i].PID != pid {
			t.Errorf("corruption %d pid %d, want %d", i, c[i].PID, pid)
		}
	}
	if !strings.Contains(c[0].Detail, "CONTEXT: while scanning block 0 offset 1 of relation \"public.orders\"\nautomatic vacuum of table") {
		t.Errorf("the freeze check's context: %q", c[0].Detail)
	}
	if !strings.Contains(c[6].Detail, `DETAIL: Could not open file "pg_xact/0003"`) {
		t.Errorf("the commit log's detail: %q", c[6].Detail)
	}
	if c[2].Statement != "select * from pg_statistic" || c[2].Database != "app" {
		t.Errorf("the missing chunk: %+v", c[2])
	}
}

// corruption-pg18-multiblock.log is recorded from a PostgreSQL 18.6 cluster without checksums: two page headers of
// one combined read made invalid (one ERROR "2 invalid pages among blocks", its per-block LOG lines not counted), an
// index page zeroed, two more headers read with zero_damaged_pages (one WARNING each).
func TestCorruptionMultiBlock(t *testing.T) {
	c := byKind(parseFile(t, "corruption-pg18-multiblock.log"), Corruption)
	want := []string{
		`2 invalid pages among blocks 3..6 of relation "base/5/16384"`,
		`index "zp_pkey" contains unexpected zero page at block 2`,
		`invalid page in block 2 of relation "base/5/16397"; zeroing out page`,
		`invalid page in block 3 of relation "base/5/16397"; zeroing out page`,
	}
	if len(c) != len(want) {
		t.Fatalf("%d corruption events, want %d: %+v", len(c), len(want), c)
	}
	for i, w := range want {
		if first := strings.SplitN(c[i].Detail, "\n", 2)[0]; first != w {
			t.Errorf("corruption %d = %q, want %q", i, first, w)
		}
	}
	if !strings.Contains(c[0].Detail, "HINT: See server log for the other 1 invalid block(s).") {
		t.Errorf("the combined read's hint: %q", c[0].Detail)
	}
}
