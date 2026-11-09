package collect

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// memDir is a log directory held in memory.
type memDir struct {
	files map[string]string
	mod   map[string]time.Time
	reads int
}

func (d *memDir) List(context.Context) ([]logFile, error) {
	var out []logFile
	for n, s := range d.files {
		out = append(out, logFile{Name: n, Size: int64(len(s)), Modified: d.mod[n]})
	}
	return out, nil
}

func (d *memDir) Read(_ context.Context, name string, off, n int64) ([]byte, error) {
	d.reads++
	s, ok := d.files[name]
	if !ok {
		return nil, nil
	}
	if off >= int64(len(s)) {
		return []byte{}, nil
	}
	end := min(int64(len(s)), off+n)
	return []byte(s[off:end]), nil
}

var pst = func() *time.Location { l, _ := time.LoadLocation("America/Los_Angeles"); return l }()

// recordedLog is a PostgreSQL 18.6 stderr log (log_line_prefix '%m [%p] %q%u@%d ', log_timezone
// America/Los_Angeles) written by the proof cluster of scripts/proof-slow.sh: two slow statements (one
// over two lines), a lock wait, a deadlock, a failed login and the server's own lines. One log_directory
// path in it was replaced by /var/log/pglog.
func recordedLog(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("testdata/slow/pg18-stderr.log")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func kinds(rows []Row) map[string]int {
	out := map[string]int{}
	for _, r := range rows {
		if r["kind"] == "event" {
			out[r["kind_of"].(string)]++
		}
	}
	return out
}

func TestServerlogRecorded(t *testing.T) {
	lp, err := compilePrefix("%m [%p] %q%u@%d ")
	if err != nil {
		t.Fatal(err)
	}
	log := recordedLog(t)
	end := time.Date(2026, 11, 9, 14, 19, 19, 140e6, pst)
	d := &memDir{files: map[string]string{"postgresql-a.log": log, "postgresql-a.csv": "x\n"}, mod: map[string]time.Time{"postgresql-a.log": end, "postgresql-a.csv": end}}
	from := time.Date(2026, 11, 9, 13, 0, 0, 0, pst)
	rows, err := serverlogRows(context.Background(), d, lp, pst, "serverlog:log", from, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int{"slow": 2, "lock_wait": 1, "deadlock": 1, "auth_fail": 1}
	if got := kinds(rows); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("kinds %v, want %v", got, want)
	}
	evs, cur := events(rows)
	if !cur["read_to"].(time.Time).Equal(end.UTC()) {
		t.Errorf("cursor %v, want the newest line %v", cur["read_to"], end.UTC())
	}
	var multi, slow1 Row
	for _, r := range evs {
		if r["kind_of"] == "slow" && strings.Contains(r["statement"].(string), "multi") {
			multi = r
		}
		if r["kind_of"] == "slow" && strings.Contains(r["statement"].(string), "slow1") {
			slow1 = r
		}
		if r["source"] != "serverlog:log:postgresql-a.log" {
			t.Errorf("source %v", r["source"])
		}
	}
	if multi == nil || !strings.Contains(multi["statement"].(string), "'line two'") || multi["duration_ms"] != 121.220 {
		t.Errorf("the two-line slow statement: %v", multi)
	}
	if slow1 == nil || slow1["usename"] != "postgres" || slow1["datname"] != "postgres" || slow1["pid"] != 89466 ||
		!slow1["at"].(time.Time).Equal(time.Date(2026, 11, 9, 22, 19, 17, 792e6, time.UTC)) {
		t.Errorf("slow1 fields (PST read in log_timezone): %v", slow1)
	}

	// a re-read from the cursor minus the overlap yields the same keys (the repository drops them)
	again, err := serverlogRows(context.Background(), d, lp, pst, "serverlog:log", end.Add(-logsOverlap), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	ev2, _ := events(again)
	if len(ev2) != len(evs) {
		t.Fatalf("re-read: %d events, want %d", len(ev2), len(evs))
	}
	for k := range ev2 {
		if _, ok := evs[k]; !ok {
			t.Errorf("re-read made a new key %s", k)
		}
	}
}

func TestServerlogSeekAndBudget(t *testing.T) {
	lp, err := compilePrefix("%t [%p]: user=%u,db=%d,app=%a,client=%h ")
	if err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	var b strings.Builder
	for i := 0; i < 20000; i++ { // one line a second over 5.5 hours, a slow statement every 100th
		at := base.Add(time.Duration(i) * time.Second).Format("2006-01-02 15:04:05")
		if i%100 == 0 {
			fmt.Fprintf(&b, "%s UTC [%d]: user=app,db=erp,app=psql,client=10.1.1.1 LOG:  duration: %d.5 ms  statement: select %d\n", at, 1000+i, 500+i, i)
		} else {
			fmt.Fprintf(&b, "%s UTC [%d]: user=app,db=erp,app=psql,client=10.1.1.1 LOG:  connection authorized: user=app\n", at, 1000+i)
		}
	}
	log := b.String()
	d := &memDir{files: map[string]string{"big.log": log}, mod: map[string]time.Time{"big.log": base.Add(20000 * time.Second)}}
	from := base.Add(19000 * time.Second)
	rows, err := serverlogRows(context.Background(), d, lp, time.UTC, "serverlog:log", from, 1<<30)
	if err != nil {
		t.Fatal(err)
	}
	// the seek lands at most one probe before from: the 10 slow statements from 19000 on, and the few before it
	if n := kinds(rows)["slow"]; n < 10 || n > 12 {
		t.Errorf("after the seek %d slow events, want 10 (and at most a probe's worth before)", n)
	}
	for _, r := range rows {
		if r["kind"] == "event" && r["client"] != "10.1.1.1(0)" {
			t.Errorf("client from %%h: %v", r["client"])
			break
		}
	}
	// a budget cut: the cursor goes one overlap past the last line read, so the next run starts there
	rows, err = serverlogRows(context.Background(), d, lp, time.UTC, "serverlog:log", base, 100000)
	if err != nil {
		t.Fatal(err)
	}
	_, cur := events(rows)
	head := log[:100000]
	head = head[:strings.LastIndexByte(head, '\n')]
	lastLine, _ := time.Parse("2006-01-02 15:04:05", head[strings.LastIndexByte(head, '\n')+1:][:19])
	got := cur["read_to"].(time.Time)
	if !got.Equal(lastLine.Add(logsOverlap)) {
		t.Errorf("budget cursor %v, want about %v", got, lastLine.Add(logsOverlap))
	}
	// a file not written since from is not read at all
	d.reads = 0
	if _, err := serverlogRows(context.Background(), d, lp, time.UTC, "serverlog:log", base.Add(30000*time.Second), 1<<30); err != nil || d.reads != 0 {
		t.Errorf("an old file was read (%d reads, %v)", d.reads, err)
	}
}

func TestCompilePrefix(t *testing.T) {
	for _, c := range []struct{ prefix, line, want string }{
		{"%m [%p] %q%u@%d ", "2026-11-09 14:18:45.975 PST [82038] LOG:  checkpoint starting: time",
			"2026-11-09 14:18:45.975 PST::@:[82038]:LOG:  checkpoint starting: time"},
		{"%m [%p] %q%u@%d ", "2026-11-09 14:18:46.082 PST [82052] mon@postgres ERROR:  boom",
			"2026-11-09 14:18:46.082 PST::mon@postgres:[82052]:ERROR:  boom"},
		{"%t:%r:%u@%d:[%p]:", "2026-11-09 12:00:00 UTC:10.0.0.1(5432):app@erp:[77]:LOG:  duration: 9.1 ms  statement: select 1",
			"2026-11-09 12:00:00 UTC:10.0.0.1(5432):app@erp:[77]:LOG:  duration: 9.1 ms  statement: select 1"},
		{"%n [%-6p] %l %c %x %v %e %Q ", "1762725600.500 [77    ] 3 6730a1b2.4d 0 3/12 00000 -12345 LOG:  hello",
			"2025-11-09 22:00:00.500 UTC::@:[77]:LOG:  hello"},
		{"%% %m [%p] %a %b %i %s %P %L %r ", "% 2026-11-09 14:18:46.082 +03 [9] psql client backend SELECT 2026-11-09 14:00:00 +03 12 10.0.0.2 [local] LOG:  hi",
			"2026-11-09 14:18:46.082 +03:[local]:@:[9]:LOG:  hi"},
	} {
		lp, err := compilePrefix(c.prefix)
		if err != nil {
			t.Fatalf("%q: %v", c.prefix, err)
		}
		got, _ := lp.rewrite(c.line, time.UTC)
		if strings.TrimSuffix(got, "\n") != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.prefix, got, c.want)
		}
	}
	for _, p := range []string{"[%p] %u@%d ", "%m %u@%d "} {
		if _, err := compilePrefix(p); !errors.Is(err, errPrefix) {
			t.Errorf("%q: want the prefix refusal, got %v", p, err)
		}
	}
}

func TestServerlogCheck(t *testing.T) {
	ok := serverlogSettings{Collector: "on", Destination: "stderr,csvlog", CanList: true, CanRead: true}
	if why := ok.check(); why != "" {
		t.Errorf("ok settings refused: %s", why)
	}
	for _, c := range []struct {
		s    serverlogSettings
		want string
	}{
		{serverlogSettings{Collector: "off", Destination: "stderr", CanList: true, CanRead: true}, "logging_collector is off"},
		{serverlogSettings{Collector: "on", Destination: "jsonlog", CanList: true, CanRead: true}, "log_destination"},
		{serverlogSettings{Collector: "on", Destination: "stderr", CanRead: true}, "pg_monitor"},
		{serverlogSettings{Collector: "on", Destination: "stderr", CanList: true}, "GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file"},
	} {
		if why := c.s.check(); !strings.Contains(why, c.want) {
			t.Errorf("%+v: %q, want %q", c.s, why, c.want)
		}
	}
}
