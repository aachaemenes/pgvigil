package web

import (
	"context"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"
)

// resetCommunityCache empties the package's check cache and sets the GET's budget for one test.
func resetCommunityCache(t *testing.T, budget time.Duration) {
	t.Helper()
	old := checkBudget
	checkBudget = budget
	communityCache.Lock()
	communityCache.m = map[checkKey]*checkEntry{}
	communityCache.Unlock()
	t.Cleanup(func() {
		checkBudget = old
		communityCache.Lock()
		communityCache.m = map[checkKey]*checkEntry{}
		communityCache.Unlock()
	})
}

func firstWhat(c *communityCheck) string {
	if len(c.Inst) == 0 {
		return ""
	}
	return c.Inst[0].What
}

// TestChecksLookAgain: a check that outlives the GET's budget answers 'not checked' now; Look again (fresh) then gets
// that check's own answer, not a new check that runs past the budget again; once shown, Look again checks again, and a
// plain view within the keep gets the kept answer.
func TestChecksLookAgain(t *testing.T) {
	resetCommunityCache(t, 300*time.Millisecond)
	s := &Server{log: discardLog()}
	k := checkKey{s: s, id: 1, db: "master"}
	var runs atomic.Int32
	release := make(chan struct{})
	slow := func(context.Context) *communityCheck {
		n := runs.Add(1)
		if n == 1 {
			<-release
		}
		return &communityCheck{DB: "master", Tools: map[string][]toolNeed{}, Inst: []toolNeed{noteNeed(fmt.Sprint("answer ", n), "", "live")}}
	}
	ctx := context.Background()
	if got := firstWhat(s.checks(ctx, k, "i1", false, slow)); !strings.HasPrefix(got, "not checked: the checks of i1 took over") {
		t.Fatalf("a check past the budget: %q", got)
	}
	close(release)
	communityCache.Lock()
	e := communityCache.m[k]
	communityCache.Unlock()
	<-e.done
	if got := firstWhat(s.checks(ctx, k, "i1", true, slow)); got != "answer 1" || runs.Load() != 1 {
		t.Fatalf("Look again after the background check ended: %q after %d runs, want its own answer, 1 run", got, runs.Load())
	}
	if got := firstWhat(s.checks(ctx, k, "i1", true, slow)); got != "answer 2" || runs.Load() != 2 {
		t.Fatalf("Look again on a shown answer: %q after %d runs, want a new check", got, runs.Load())
	}
	if got := firstWhat(s.checks(ctx, k, "i1", false, slow)); got != "answer 2" || runs.Load() != 2 {
		t.Fatalf("a view within the keep: %q after %d runs, want the kept answer", got, runs.Load())
	}
}

// TestChecksRecover: a check that panics answers 'not checked' with the reason and the process goes on.
func TestChecksRecover(t *testing.T) {
	resetCommunityCache(t, time.Second)
	s := &Server{log: discardLog()}
	got := firstWhat(s.checks(context.Background(), checkKey{s: s, id: 2}, "i2", false, func(context.Context) *communityCheck {
		panic("a check that breaks")
	}))
	if !strings.HasPrefix(got, "not checked: the checks of i2 broke") {
		t.Fatalf("a check that broke: %q", got)
	}
}

// TestChecksRunMax: no more than checkRunMax checks run at once; the next GET is answered 'not checked'.
func TestChecksRunMax(t *testing.T) {
	resetCommunityCache(t, 10*time.Millisecond)
	s := &Server{log: discardLog()}
	block := make(chan struct{})
	defer close(block)
	wait := func(context.Context) *communityCheck {
		<-block
		return &communityCheck{Tools: map[string][]toolNeed{}}
	}
	for i := 0; i < checkRunMax; i++ {
		s.checks(context.Background(), checkKey{s: s, id: 100 + i}, "x", false, wait)
	}
	got := firstWhat(s.checks(context.Background(), checkKey{s: s, id: 999}, "x", false, wait))
	if !strings.Contains(got, "is running 16 checks of community tools already") {
		t.Fatalf("the check past the cap: %q", got)
	}
}

// TestDeclinedBy: only message 50000 with a listed procedure's own text is declined; a listed procedure's other
// error, an unlisted procedure's 50000 and the listed text under another number all stay failed runs.
func TestDeclinedBy(t *testing.T) {
	cases := []struct {
		proc string
		me   mssqldb.Error
		want bool
	}{
		{"sp_LogHunter", mssqldb.Error{Number: 50000, Message: "Current user does not have EXECUTE permission on xp_readerrorlog, so we can't read the error log"}, true},
		{"sp_LogHunter", mssqldb.Error{Number: 50000, Message: "Something else went wrong in sp_LogHunter"}, false},
		{"sp_LogHunter", mssqldb.Error{Number: 229, Message: "Current user does not have EXECUTE permission on xp_readerrorlog"}, false},
		{"sp_HumanEventsBlockViewer", mssqldb.Error{Number: 50000, Message: "A session with the name pgcr_none does not exist or is not currently active."}, true},
		{"sp_HumanEventsBlockViewer", mssqldb.Error{Number: 50000, Message: "A session with the name pgcr_none was dropped"}, false},
		{"sp_IndexCleanup", mssqldb.Error{Number: 50000, Message: "  No valid databases found to process.  "}, true},
		{"sp_BlitzIndex", mssqldb.Error{Number: 50000, Message: "No valid databases found to process."}, false},
		{"sp_BlitzIndex", mssqldb.Error{Number: 50000, Message: "pgcr_seed database failed to process. The SELECT permission was denied"}, false},
		{"sp_BlitzCache", mssqldb.Error{Number: 102, Message: "Incorrect syntax near '$.message.content'."}, false},
	}
	for _, c := range cases {
		if got := declinedBy(c.proc, c.me); got != c.want {
			t.Errorf("declinedBy(%s, %d %q) = %v, want %v", c.proc, c.me.Number, c.me.Message, got, c.want)
		}
	}
}

// TestGrantLine: CREATE USER only when the login has no user in the database; GRANT names the user, both quoted.
func TestGrantLine(t *testing.T) {
	if got, want := grantLine("master", "pgcr_reader", "pgcr_reader", "sys.xp_readerrorlog"), "USE [master]; GRANT EXECUTE ON sys.xp_readerrorlog TO [pgcr_reader];"; got != want {
		t.Errorf("a user there: %q, want %q", got, want)
	}
	if got, want := grantLine("db]x", "", "dom\\reader", "dbo.[sp_Blitz]"), "USE [db]]x]; CREATE USER [dom\\reader] FOR LOGIN [dom\\reader]; GRANT EXECUTE ON dbo.[sp_Blitz] TO [dom\\reader];"; got != want {
		t.Errorf("no user there: %q, want %q", got, want)
	}
	if got, want := grantLine("Sales", "app_reader", "CORP\\svc", "dbo.[sp_Blitz]"), "USE [Sales]; GRANT EXECUTE ON dbo.[sp_Blitz] TO [app_reader];"; got != want {
		t.Errorf("a user named apart from its login: %q, want %q", got, want)
	}
}

// TestIsSystemDB: the databases sp_IndexCleanup skips, in any case.
func TestIsSystemDB(t *testing.T) {
	for db, want := range map[string]bool{"master": true, "MSDB": true, "tempdb": true, "model": true, "rdsadmin": true, "pgcr_seed": false, "masterdata": false, "": false} {
		if got := isSystemDB(db); got != want {
			t.Errorf("isSystemDB(%q) = %v, want %v", db, got, want)
		}
	}
}
