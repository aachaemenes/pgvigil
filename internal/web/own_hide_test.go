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
