package web

import (
	"strings"
	"testing"
)

// TestOwnHideShared: the instance pages' reads and the fleet's longest-statement pick hide pgvigil's own rows by one
// fragment per engine (B24 OWN, FOLD O6): the fleet never links to a row the page it opens hides.
func TestOwnHideShared(t *testing.T) {
	for _, c := range []struct{ name, sql, frag string }{
		{"mssql running", sqlMssqlRunningInner, ownHideMssql},
		{"mssql running flag", sqlMssqlRunningInner, ownLateralMssql},
		{"activity", sqlSessionsOwnInner, ownHidePg},
		{"fleet pick (SQL Server)", sqlRunningFleet, ownHideMssql},
		{"fleet pick flag (SQL Server)", sqlRunningFleet, ownLateralMssql},
		{"fleet pick (PostgreSQL)", sqlRunningFleet, ownHidePg},
	} {
		if !strings.Contains(c.sql, c.frag) {
			t.Errorf("%s: the shared fragment is not in its query", c.name)
		}
	}
	for _, q := range []string{sqlMssqlRunningOwnHidden, sqlSessionsOwnHidden} {
		if !strings.Contains(q, ownSince) || !strings.Contains(q, "own_sessions") {
			t.Errorf("an own_hidden part lacks since or own_sessions: %.80s", q)
		}
	}
}

// TestSessionsOwnKeepsColumns: the activity read with pgvigil's own hidden (sqlSessionsOwn, the activity handler's query
// once the B24 wiring is applied) returns every column of the plain read (sqlSessions), so the Running page draws the
// same grid either way.
func TestSessionsOwnKeepsColumns(t *testing.T) {
	// the FROM clauses start their own lines (an extract(epoch FROM ...) inside the select list does not)
	from, ownFrom := strings.Index(sqlSessions, "\n  FROM pgvigil."), strings.Index(sqlSessionsOwn, "\n  FROM (")
	if from < 0 || ownFrom < 0 {
		t.Fatalf("the FROM line of sqlSessions (%d) or sqlSessionsOwn (%d) was not found", from, ownFrom)
	}
	sel := sqlSessions[strings.Index(sqlSessions, "SELECT")+len("SELECT") : from]
	outer := sqlSessionsOwn[:ownFrom]
	n := 0
	for _, item := range strings.Split(sel, ",") {
		f := strings.Fields(item)
		if len(f) == 0 {
			continue
		}
		name := f[len(f)-1]
		if i := strings.LastIndex(name, "."); i >= 0 {
			name = name[i+1:]
		}
		n++
		if !strings.Contains(outer, "x."+name) {
			t.Errorf("sqlSessionsOwn does not return %q, a column of sqlSessions", name)
		}
	}
	if n < 15 {
		t.Fatalf("read %d columns of sqlSessions: the select list was not found", n)
	}
}
