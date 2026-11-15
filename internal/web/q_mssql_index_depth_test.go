package web

import (
	"strings"
	"testing"
)

// TestJobDSN: the fragmentation job's connection carries no per-read timeout (go-mssqldb v1.11.2 sets the dsn's
// 'connection timeout' as a deadline on every read for the connection's life: a read held 30 s on a lock, or one that
// reads a large heap before its first row, would end in an i/o timeout; proof G4 on 2022 at 8a1db62b): the setting is
// replaced by 0 in each form, whatever its spelling, and every other key is kept.
func TestJobDSN(t *testing.T) {
	for _, c := range []struct{ in, has, not string }{
		{"sqlserver://u:p@h:1433?database=master&encrypt=true&connection+timeout=20", "connection+timeout=0", "timeout=20"},
		{"sqlserver://u:p@h:1433?database=master", "connection+timeout=0", ""},
		{"sqlserver://u@h?Connection%20Timeout=30&app+name=x", "connection+timeout=0", "=30"},
		{"server=h;user id=u;password=p;connection timeout=20;database=master", ";connection timeout=0", "=20"},
		{"server=h;user id=u;Connect Timeout=45", ";connection timeout=0", "45"},
		{"odbc:server=h;user id=u;connection timeout=20", ";connection timeout=0", "=20"},
	} {
		got := jobDSN(c.in)
		if !strings.Contains(strings.ToLower(got), c.has) || (c.not != "" && strings.Contains(got, c.not)) {
			t.Errorf("jobDSN(%q) = %q; want %q and not %q", c.in, got, c.has, c.not)
		}
		if strings.Count(strings.ToLower(got), "timeout=") != 1 {
			t.Errorf("jobDSN(%q) = %q: one timeout key", c.in, got)
		}
		for _, k := range []string{"database=master", "user id=u", "app+name=x"} {
			if strings.Contains(c.in, k) && !strings.Contains(got, k) {
				t.Errorf("jobDSN(%q) = %q lost %s", c.in, got, k)
			}
		}
	}
}
