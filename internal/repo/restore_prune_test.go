package repo

import (
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), on PostgreSQL 13 as on the newest: the logs a chain read
// no longer sends (0147's import, its prune of the stored logs). A log below the lowest log the read sent goes; one above
// it (inside the range the read covers) is kept; with no log sent for the database every stored log goes; a log that msdb
// holds with no last_lsn is never pruned by its LSN (it has none to compare). The reads one after the other:
//
//	P1 a log with no last_lsn, not in a read that sends logs: kept
//	P2 the same log, not in a read that sends no log: kept
//	P3 a log below the read's lowest: gone
//	P4 a log above the read's lowest: kept
//	P5 every log with a last_lsn, when the read sends no log of the database: gone
func TestRestoreChainPruneOnAStore(t *testing.T) {
	f := newRegroupFx(t)
	h := time.Hour
	p := f.inst("prune")
	full := f.set("dbp", "full", 1, 1000, 1010, -10*h, 1000)
	logOf := func(id, first int64, finish time.Duration) map[string]any {
		return f.set("dbp", "log", id, first, first+10, finish, 1000)
	}
	noLast := logOf(3, 1020, -8*h-30*time.Minute)
	delete(noLast, "last_lsn")
	logs := func(step string) string {
		t.Helper()
		var ids string
		if err := f.pool.QueryRow(f.ctx, `SELECT coalesce(string_agg(backup_set_id::text, ' ' ORDER BY backup_set_id), '') FROM pgvigil.mssql_restore_sets
		    WHERE instance_id = $1 AND database_name = 'dbp' AND role = 'log'`, p).Scan(&ids); err != nil {
			t.Fatalf("%s: the stored logs: %v", step, err)
		}
		return ids
	}

	// the first read: the full, log 2, log 3 (no last_lsn), logs 4, 5 and 6
	f.chainRead(p, f.snap(0), f.db("dbp", ""), full, logOf(2, 1010, -9*h), noLast, logOf(4, 1020, -8*h), logOf(5, 1030, -7*h), logOf(6, 1040, -6*h))
	if got, want := logs("read 1"), "2 3 4 5 6"; got != want {
		t.Errorf("read 1: the stored logs %q, want %q (each log the read sent, the one with no last_lsn too)", got, want)
	}
	if n := countWhere(t, f, `last_lsn IS NULL AND backup_set_id = 3`, p); n != 1 {
		t.Errorf("read 1: log 3 stored with no last_lsn %d time(s), want 1 (the case P1 and P2 read)", n)
	}

	// the second read sends logs 4 and 5 only (its lowest last_lsn: log 4's)
	f.chainRead(p, f.snap(1), f.db("dbp", ""), full, logOf(4, 1020, -8*h), logOf(5, 1030, -7*h))
	got := logs("read 2")
	for _, c := range []struct {
		id   string
		kept bool
		why  string
	}{
		{"3", true, "P1: no last_lsn, not in a read that sends logs"},
		{"2", false, "P3: below the read's lowest log"},
		{"6", true, "P4: above the read's lowest log"},
	} {
		if in := hasWord(got, c.id); in != c.kept {
			t.Errorf("read 2: log %s kept=%v, want kept=%v (%s); the stored logs %q", c.id, in, c.kept, c.why, got)
		}
	}
	if want := "3 4 5 6"; got != want {
		t.Errorf("read 2: the stored logs %q, want %q", got, want)
	}

	// the third read sends the full and no log of the database
	f.chainRead(p, f.snap(2), f.db("dbp", ""), full)
	got = logs("read 3")
	if !hasWord(got, "3") {
		t.Errorf("read 3: log 3 is gone, want kept (P2: no last_lsn, not in a read that sends no log); the stored logs %q", got)
	}
	for _, id := range []string{"4", "5", "6"} {
		if hasWord(got, id) {
			t.Errorf("read 3: log %s kept, want gone (P5: the read sent no log of the database); the stored logs %q", id, got)
		}
	}
	if n := countWhere(t, f, `role = 'full' AND backup_set_id = 1`, p); n != 1 {
		t.Errorf("read 3: the full stored %d time(s), want 1 (the read sent it)", n)
	}
}

// countWhere: the stored sets of instance id's dbp that match cond (a fixed condition of the test, never input)
func countWhere(t *testing.T, f *regroupFx, cond string, id int) int {
	t.Helper()
	var n int
	if err := f.pool.QueryRow(f.ctx, fmt.Sprintf(`SELECT count(*) FROM pgvigil.mssql_restore_sets WHERE instance_id = $1 AND database_name = 'dbp' AND %s`, cond), id).Scan(&n); err != nil {
		t.Fatalf("the stored sets where %s: %v", cond, err)
	}
	return n
}

// hasWord: id is one of the space-separated words of list
func hasWord(list, id string) bool { return slices.Contains(strings.Fields(list), id) }
