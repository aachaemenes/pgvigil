package logparse

import (
	"os"
	"strings"
	"testing"
)

func TestParseAuroraFixture(t *testing.T) {
	f, err := os.Open("testdata/aurora.log")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
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
