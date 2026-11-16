package mssql

import (
	"context"
	"errors"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// TestBlitzOutcome: each outcome of a run from what the call returned (blitz.go's list).
func TestBlitzOutcome(t *testing.T) {
	notice := blitzMsg{class: 0, state: 11, text: "The user x does not have VIEW SERVER STATE permissions."}
	e229 := blitzMsg{number: 229, class: 14, text: "The EXECUTE permission was denied on the object 'sp_BlitzBackups'"}
	for _, c := range []struct {
		name     string
		rd       blitzRead
		err      error
		timedOut bool
		want     string
		why      string // a part of the words; "" = none
	}{
		{"the set alone", blitzRead{set: true}, nil, false, "done", ""},
		{"the set and an error", blitzRead{set: true, msgs: []blitzMsg{e229}, errs: 1}, nil, false, "done with messages", ""},
		{"the set and a notice", blitzRead{set: true, msgs: []blitzMsg{notice}}, nil, false, "done", ""},
		{"no set, a notice", blitzRead{msgs: []blitzMsg{notice}}, nil, false, "refused", "does not have VIEW SERVER STATE permissions"},
		{"no set, an error", blitzRead{msgs: []blitzMsg{notice, e229}, errs: 1}, nil, false, "failed", "Msg 229, severity 14"},
		{"no set, nothing", blitzRead{}, nil, false, "failed", "no result set and no message"},
		{"no set, the connection's error", blitzRead{}, errors.New("read tcp: reset"), false, "failed", "reset"},
		{"past the timeout", blitzRead{set: true}, context.DeadlineExceeded, true, "timed out", "its 7 s timeout"},
	} {
		got, why := blitzOutcome(c.rd, c.err, c.timedOut, 7)
		if got != c.want || (c.why == "") != (why == "") || !strings.Contains(why, c.why) {
			t.Errorf("%s: %q, %q; want %q with %q", c.name, got, why, c.want, c.why)
		}
	}
	// pgvigil's own notes never stand for the server's words
	rd := blitzRead{msgs: []blitzMsg{notice}}
	rd.note("sp_Blitz's version was not read")
	if _, why := blitzOutcome(rd, nil, false, 7); strings.Contains(why, "version") {
		t.Errorf("a pgvigil note in the refusal: %q", why)
	}
}

// TestBlitzAdd: a server message is kept with its number and severity; severity 11 and more counts as an error; the
// list stops at blitzMsgsMax while the count goes on.
func TestBlitzAdd(t *testing.T) {
	var rd blitzRead
	rd.add(mssqldb.Error{Number: 0, Class: 0, State: 11, Message: "The user x does not have VIEW SERVER STATE permissions."})
	rd.add(mssqldb.Error{Number: 8134, Class: 16, LineNo: 9764, ProcName: "sp_Blitz", Message: "Divide by zero error encountered."})
	rd.add(errors.New("a driver error"))
	if rd.errs != 2 || len(rd.msgs) != 3 || rd.msgs[1].number != 8134 || rd.msgs[1].line != 9764 || rd.msgs[2].class != 16 {
		t.Fatalf("errs %d, msgs %+v", rd.errs, rd.msgs)
	}
	for i := 0; i < blitzMsgsMax+5; i++ {
		rd.add(mssqldb.Error{Class: 16, Message: "again"})
	}
	if len(rd.msgs) != blitzMsgsMax || rd.errs != 2+blitzMsgsMax+5 {
		t.Errorf("msgs %d (max %d), errs %d", len(rd.msgs), blitzMsgsMax, rd.errs)
	}
}

// TestBlitzCells: sp_Blitz's integer and text cells as the payload carries them.
func TestBlitzCells(t *testing.T) {
	if blitzInt(int64(223)) != int64(223) || blitzInt(uint8(5)) != int64(5) || blitzInt(nil) != nil || blitzInt("1") != nil {
		t.Error("blitzInt")
	}
	long := strings.Repeat("é", blitzTextMax+10)
	if got := blitzText(long).(string); len([]rune(got)) != blitzTextMax {
		t.Errorf("a long Details cell kept %d characters", len([]rune(got)))
	}
	if blitzText([]byte("x")) != "x" || blitzText(nil) != nil {
		t.Error("blitzText")
	}
}

// TestBlitzSkips: off and not due are skips with the repository's words; a plan the repository could not give is an
// error, never a run.
func TestBlitzSkips(t *testing.T) {
	c := blitzCollector{}
	for _, st := range []string{"off", "not due"} {
		_, err := c.RunPlanned(context.Background(), nil, Info{}, func(context.Context) (repo.BlitzPlan, error) {
			return repo.BlitzPlan{State: st, Why: "the words of " + st}, nil
		})
		if !errors.Is(err, collect.ErrSkip) || !strings.HasPrefix(err.Error(), "the words of "+st+": ") {
			t.Errorf("%s: %v", st, err)
		}
	}
	_, err := c.RunPlanned(context.Background(), nil, Info{}, func(context.Context) (repo.BlitzPlan, error) {
		return repo.BlitzPlan{}, errors.New("repository down")
	})
	if err == nil || errors.Is(err, collect.ErrSkip) || !strings.Contains(err.Error(), "repository down") {
		t.Errorf("a failed plan: %v", err)
	}
	if _, err := c.Run(context.Background(), nil, Info{}); !errors.Is(err, collect.ErrSkip) {
		t.Errorf("Run without a plan: %v", err)
	}
	if ok, why := c.Applies(Info{Kind: KindAzureDB}); ok || !strings.Contains(why, "Azure SQL Database") {
		t.Errorf("Azure SQL Database: %v %q", ok, why)
	}
}

// TestChecksJudgedCoversTheRules: every sp_Blitz CheckID a rule of this package names (a "sp_Blitz <n>" string, an
// offByDefault option) is in ChecksJudged, and judgedRules names none that no rule names any more.
func TestChecksJudgedCoversTheRules(t *testing.T) {
	files, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	lit := regexp.MustCompile(`"sp_Blitz (\d+)`)
	off := regexp.MustCompile(`offByDefault\("[^"]*", "[^"]*", (\d+)\)`)
	named := map[int]bool{}
	for _, f := range files {
		n := f.Name()
		if !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") || n == "blitz.go" {
			continue
		}
		b, err := os.ReadFile(n)
		if err != nil {
			t.Fatal(err)
		}
		for _, re := range []*regexp.Regexp{lit, off} {
			for _, m := range re.FindAllStringSubmatch(string(b), -1) {
				id, _ := strconv.Atoi(m[1])
				named[id] = true
			}
		}
	}
	if len(named) < 20 {
		t.Fatalf("only %d rules found: the scan is broken", len(named))
	}
	judged := map[int]bool{}
	for _, id := range ChecksJudged() {
		judged[id] = true
	}
	var missing, stale []int
	for id := range named {
		if !judged[id] {
			missing = append(missing, id)
		}
	}
	for _, id := range judgedRules {
		if !named[id] {
			stale = append(stale, id)
		}
	}
	sort.Ints(missing)
	sort.Ints(stale)
	if len(missing) > 0 || len(stale) > 0 {
		t.Errorf("judgedRules: missing %v (a rule names them), stale %v (no rule names them)", missing, stale)
	}
	for _, id := range []int{12, 13, 14, 1001} {
		if !judged[id] {
			t.Errorf("ChecksJudged lacks %d", id)
		}
	}
}
