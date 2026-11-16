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
		{"the set cut by the connection's error", blitzRead{set: true, rows: []blitzFinding{{}}}, errors.New("read tcp: reset"), false, "failed", "ended early: read tcp: reset"},
		{"no set, only pgvigil's note", blitzRead{msgs: []blitzMsg{{proc: "pgvigil", text: "sp_Blitz's version was not read"}}}, nil, false, "failed", "no result set and no message"},
		{"past the timeout", blitzRead{set: true}, context.DeadlineExceeded, true, "timed out", "within 7 s"},
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
// list stops at blitzMsgsMax while the count goes on, an error taking the place of the oldest notice.
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
	// a full list keeps errors over notices: the notice gave its place to an error
	for _, m := range rd.msgs {
		if m.class < 11 {
			t.Errorf("a notice kept in a full list of errors: %+v", m)
		}
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

// TestBlitzNoteFirst: the per-database note heads the messages and survives a full list (the lead 05:0x).
func TestBlitzNoteFirst(t *testing.T) {
	var rd blitzRead
	rd.add(mssqldb.Error{Class: 0, Message: "a notice"})
	rd.add(mssqldb.Error{Class: 16, Number: 229, Message: "an error"})
	rd.noteFirst("first")
	if len(rd.msgs) != 3 || rd.msgs[0].proc != "pgvigil" || rd.msgs[0].text != "first" || rd.msgs[2].number != 229 {
		t.Fatalf("msgs %+v", rd.msgs)
	}
	var full blitzRead
	for i := 0; i < blitzMsgsMax-1; i++ {
		full.add(mssqldb.Error{Class: 16, Message: "an error"})
	}
	full.add(mssqldb.Error{Class: 0, Message: "the newest notice"})
	full.noteFirst("first")
	if len(full.msgs) != blitzMsgsMax || full.msgs[0].text != "first" {
		t.Fatalf("a full list: %d messages, the first %+v", len(full.msgs), full.msgs[0])
	}
	for _, m := range full.msgs {
		if m.text == "the newest notice" {
			t.Errorf("the notice kept, an error dropped")
		}
	}
	var errsOnly blitzRead
	for i := 0; i < blitzMsgsMax; i++ {
		errsOnly.add(mssqldb.Error{Class: 16, Number: int32(i + 1), Message: "an error"})
	}
	errsOnly.noteFirst("first")
	if len(errsOnly.msgs) != blitzMsgsMax || errsOnly.msgs[0].text != "first" || errsOnly.msgs[blitzMsgsMax-1].number != blitzMsgsMax-1 {
		t.Errorf("a list of errors: %d messages, the last %+v", len(errsOnly.msgs), errsOnly.msgs[len(errsOnly.msgs)-1])
	}
}

// TestBlitzDBSkipNote: the words for none and for some databases read.
func TestBlitzDBSkipNote(t *testing.T) {
	none, some := blitzDBSkipNote(5, 0, "mon"), blitzDBSkipNote(5, 2, "mon")
	for _, c := range []struct{ got, want string }{
		{none, "sp_Blitz's per-database checks ran on no database (0 of 5): "},
		{some, "sp_Blitz's per-database checks left out 3 of 5 databases: "},
	} {
		if !strings.HasPrefix(c.got, c.want) {
			t.Errorf("%q does not start %q", c.got, c.want)
		}
		for _, w := range []string{"fn_my_permissions", "the login mon", "SELECT ALL USER SECURABLES", "sysadmin"} {
			if !strings.Contains(c.got, w) {
				t.Errorf("%q lacks %q", c.got, w)
			}
		}
	}
}

// TestBlitzNoteFirstCorners: the cap's corners (review-23 N2): the only notice not last, exactly the cap, and a pgvigil
// note never dropped for it (N1).
func TestBlitzNoteFirstCorners(t *testing.T) {
	var mid blitzRead
	for i := 0; i < blitzMsgsMax; i++ {
		if i == 10 {
			mid.add(mssqldb.Error{Class: 0, Message: "the only notice"})
			continue
		}
		mid.add(mssqldb.Error{Class: 16, Number: int32(i + 1), Message: "an error"})
	}
	mid.noteFirst("first")
	if len(mid.msgs) != blitzMsgsMax || mid.msgs[0].text != "first" {
		t.Fatalf("the notice in the middle: %d messages, the first %+v", len(mid.msgs), mid.msgs[0])
	}
	for _, m := range mid.msgs[1:] {
		if m.class < 11 {
			t.Errorf("the notice kept while an error was dropped: %+v", m)
		}
	}
	var exact blitzRead
	for i := 0; i < blitzMsgsMax-1; i++ {
		exact.add(mssqldb.Error{Class: 0, Number: int32(i + 1), Message: "a notice"})
	}
	exact.noteFirst("first")
	if len(exact.msgs) != blitzMsgsMax || exact.msgs[blitzMsgsMax-1].number != blitzMsgsMax-1 {
		t.Errorf("exactly the cap: %d messages, the last %+v", len(exact.msgs), exact.msgs[len(exact.msgs)-1])
	}
	var own blitzRead
	for i := 0; i < blitzMsgsMax-1; i++ {
		own.add(mssqldb.Error{Class: 16, Number: int32(i + 1), Message: "an error"})
	}
	own.note("sp_Blitz's version was not read")
	own.noteFirst("first")
	if len(own.msgs) != blitzMsgsMax || own.msgs[0].text != "first" || own.msgs[blitzMsgsMax-1].text != "sp_Blitz's version was not read" {
		t.Errorf("a pgvigil note last: %d messages, the last %+v", len(own.msgs), own.msgs[len(own.msgs)-1])
	}
}
