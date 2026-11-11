package collect

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

var platformInfoNone = platform.Info{}

func TestAmcheckGate(t *testing.T) {
	c := amcheckCollector{}
	if c.DefaultInterval() != 0 {
		t.Fatal("amcheck must be off by default")
	}
	if ok, why := c.Configured(config.Instance{Name: "a"}); ok || !strings.Contains(why, "opt-in") {
		t.Errorf("no schedule: %v %q", ok, why)
	}
	if ok, _ := c.Configured(config.Instance{Schedules: map[string]config.Duration{"amcheck": {Duration: 0}}}); ok {
		t.Error("a zero schedule turned it on")
	}
	if ok, _ := c.Configured(config.Instance{Schedules: map[string]config.Duration{"amcheck": {Duration: 24 * time.Hour}}}); !ok {
		t.Error("a named schedule did not turn it on")
	}
}

func TestAmcheckRunStatus(t *testing.T) {
	rels := []amRel{{1, "public.a"}, {2, "public.b"}, {3, "public.c"}}
	far := time.Now().Add(time.Hour)
	cases := []struct {
		name   string
		check  func(amRel) ([]string, error)
		dl     time.Time
		status string
		counts [3]int // checked, corrupt, errors
	}{
		{"clean", func(amRel) ([]string, error) { return nil, nil }, far, "ok", [3]int{3, 0, 0}},
		{"index damage", func(r amRel) ([]string, error) {
			if r.oid == 2 {
				return nil, &pgconn.PgError{Code: "XX002", Message: `item order invariant violated for index "b"`}
			}
			return nil, nil
		}, far, "corrupt", [3]int{3, 1, 0}},
		{"heap rows", func(r amRel) ([]string, error) {
			if r.oid == 3 {
				return []string{"block 0 offset 1: line pointer to page offset 32767 is not maximally aligned"}, nil
			}
			return nil, nil
		}, far, "corrupt", [3]int{3, 1, 0}},
		{"timeout", func(r amRel) ([]string, error) {
			if r.oid == 1 {
				return nil, &pgconn.PgError{Code: "57014", Message: "canceling statement due to statement timeout"}
			}
			return nil, nil
		}, far, "partial", [3]int{2, 0, 1}},
		{"all fail", func(amRel) ([]string, error) { return nil, errors.New("conn closed") }, far, "error", [3]int{0, 0, 3}},
		{"dropped", func(r amRel) ([]string, error) {
			if r.oid == 2 {
				return nil, &pgconn.PgError{Code: "42P01", Message: "relation does not exist"}
			}
			return nil, nil
		}, far, "ok", [3]int{2, 0, 0}},
		{"budget", func(amRel) ([]string, error) { return nil, nil }, time.Now().Add(-time.Second), "partial", [3]int{0, 0, 0}},
		{"gone since the list", func(r amRel) ([]string, error) {
			if r.oid == 1 {
				return nil, errAmcheckGone
			}
			return nil, nil
		}, far, "ok", [3]int{2, 0, 0}},
		{"file missing", func(r amRel) ([]string, error) {
			if r.oid == 3 {
				return nil, &pgconn.PgError{Code: "58P01", Message: `could not open file "base/5/16400": No such file or directory`}
			}
			return nil, nil
		}, far, "corrupt", [3]int{3, 1, 0}},
	}
	for _, c := range cases {
		r := amcheckRun(context.Background(), "db", "bt_index_check", rels, 0, c.dl, c.check)
		got := [3]int{r["checked"].(int), r["corrupt"].(int), r["errors"].(int)}
		if r["status"] != c.status || got != c.counts || r["total"] != 3 {
			t.Errorf("%s: %v %v total %v, want %s %v", c.name, r["status"], got, r["total"], c.status, c.counts)
		}
	}
}

// The recorded corruption lines (internal/logparse/testdata, a PostgreSQL 18.6 cluster with checksums, the RDS
// prefix in UTC) through both readers: the CloudWatch reader (logRows, one event per line as the fixture of
// logs_test.go does) and the server log reader (serverlogRows over the same file under its own prefix).
func TestCorruptionBothReaders(t *testing.T) {
	raw, err := os.ReadFile("../logparse/testdata/corruption-pg18-ioworker.log")
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	want := map[string]int{"checkpoint": 6, "corruption": 9, "plan": 2} // the recording's log_checkpoints lines are events since 0079

	base := time.Date(2026, 11, 9, 23, 52, 0, 0, time.UTC)
	var evs []cwEvent
	for i, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		evs = append(evs, cwEvent{Stream: "a", Time: base.Add(time.Duration(i) * time.Millisecond), Message: line})
	}
	cw := logRows(evs, "cloudwatch:/g", base.Add(-time.Minute), time.UTC, false)
	if got := kinds(cw); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("CloudWatch reader kinds %v, want %v", got, want)
	}

	lp, err := compilePrefix("%t:%r:%u@%d:[%p]:")
	if err != nil {
		t.Fatal(err)
	}
	end := time.Date(2026, 11, 9, 23, 52, 35, 0, time.UTC)
	d := &memDir{files: map[string]string{"postgresql-a.log": text}, mod: map[string]time.Time{"postgresql-a.log": end}}
	sl, err := serverlogRows(context.Background(), d, lp, fixedZone(time.UTC), "serverlog:log", base.Add(-time.Hour), 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if got := kinds(sl); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("server log reader kinds %v, want %v", got, want)
	}
	for _, rows := range [][]Row{cw, sl} {
		for _, r := range rows {
			if r["kind_of"] == "corruption" && strings.Contains(fmt.Sprint(r["detail"]), "unexpected chunk number") &&
				r["statement"] != "select length(v) from tt" {
				t.Errorf("the toast event's statement: %v", r["statement"])
			}
			if r["kind_of"] == "plan" && !strings.Contains(fmt.Sprint(r["statement"]), "Query Text") {
				t.Errorf("a plan without its text: %v", r["statement"])
			}
		}
	}
}

// The start point moves by day and covers every position; a run from it visits each relation once, wrapping.
func TestAmcheckRotation(t *testing.T) {
	seen := map[int]bool{}
	day := time.Date(2026, 11, 1, 3, 0, 0, 0, time.UTC)
	for d := 0; d < 40; d++ {
		seen[amcheckStart(day.Add(time.Duration(d)*24*time.Hour), 7)] = true
	}
	if len(seen) != 7 {
		t.Errorf("40 days reached %d of 7 start points", len(seen))
	}
	var order []int64
	rels := []amRel{{1, "a"}, {2, "b"}, {3, "c"}, {4, "d"}}
	amcheckRun(context.Background(), "db", "x", rels, 2, time.Now().Add(time.Hour), func(r amRel) ([]string, error) {
		order = append(order, r.oid)
		return nil, nil
	})
	if fmt.Sprint(order) != "[3 4 1 2]" {
		t.Errorf("visit order %v, want [3 4 1 2]", order)
	}
	if amcheckStart(day, 0) != 0 {
		t.Error("no relation: start 0")
	}
}

// A run inside the interval since the last one is skipped (a service restart does not start another full read).
func TestAmcheckSkipsInsideInterval(t *testing.T) {
	in := config.Instance{Schedules: map[string]config.Duration{"amcheck": {Duration: 24 * time.Hour}}}
	cur := func(context.Context, string) (time.Time, bool, error) {
		return time.Now().Add(-2 * time.Hour), true, nil
	}
	_, err := amcheckCollector{}.RunInstance(context.Background(), nil, platformInfoNone, in, cur)
	if !errors.Is(err, ErrSkip) || !strings.Contains(err.Error(), "the next is due from") {
		t.Errorf("inside the interval: %v", err)
	}
}
