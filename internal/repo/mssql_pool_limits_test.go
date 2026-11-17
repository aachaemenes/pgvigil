package repo

import (
	"encoding/json"
	"testing"
	"time"
)

// TestPoolLimitHistoryOnAStore (P25 task 9b, migration 0395: DBA Dash's Pool history): on a store,
// pgvigil.import_mssql_pool_limits keeps a pooled database's copy of its elastic pool's limits as periods of equal
// limits (master's sys.elastic_pool_resource_stats, collapsed by the read: DTU, storage, and the CPU limit Microsoft
// calls informational) and the read's state. The read covers master's 14 days every hour, so reads overlap: a later
// read merges into the stored periods - an unchanged period only extends its valid_to and keeps the start an earlier
// read saw (master no longer holds it), a limit change splits the period once, the same read twice stores nothing
// twice. A read without the right (no dbmanager) or without a login in master keeps the periods and records why.
// Each member database keeps its own copy (the instance scope's policy follows the instance).
func TestPoolLimitHistoryOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	b := s.instance("b")
	base := time.Now().UTC().Truncate(time.Hour)
	at := func(n float64) time.Time { return base.Add(time.Duration(n * float64(time.Hour))) }
	h := func(n float64) string { return at(n).Format(time.RFC3339) }
	imp := func(id int, when float64, rows ...map[string]any) {
		t.Helper()
		js, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.pool.Exec(s.ctx, `SELECT pgvigil.import_mssql_pool_limits($1, $2, $3::jsonb)`, id, at(when), string(js)); err != nil {
			t.Fatalf("import_mssql_pool_limits at %+.1f h: %v", when, err)
		}
	}
	read := func(from, to float64) map[string]any {
		return map[string]any{"kind": "limit_read", "server": "srv1", "pool": "pool1", "state": "read", "window_from": h(from), "window_to": h(to)}
	}
	period := func(from, to float64, dtu, storage int, cpu any) map[string]any {
		return map[string]any{"kind": "limit_period", "server": "srv1", "pool": "pool1", "valid_from": h(from), "valid_to": h(to),
			"dtu_limit": dtu, "storage_limit_mb": storage, "cpu_limit": cpu}
	}
	// the periods in minutes from base: from, to, DTU, storage, CPU (as text: vals prints a numeric's pgx struct)
	periods := func(id int) string {
		t.Helper()
		return s.vals(`SELECT (extract(epoch FROM valid_from - $2::timestamptz) / 60)::int, (extract(epoch FROM valid_to - $2::timestamptz) / 60)::int,
		                      dtu_limit, storage_limit_mb, cpu_limit::text
		                 FROM pgvigil.mssql_pool_limit_history WHERE instance_id = $1 AND server = 'srv1' AND pool = 'pool1' ORDER BY valid_from`, id, at(0))
	}
	// the first read: master's 14 days, 50 DTUs until 100 hours ago, 100 since
	imp(s.id, 0, read(-336, 0), period(-336, -100, 50, 5000, nil), period(-100, 0, 100, 10000, 2.0))
	if got, want := periods(s.id), "-20160 -6000 50 5000 NULL | -6000 0 100 10000 2.00"; got != want {
		t.Errorf("after the first read:\n got %s\nwant %s", got, want)
	}
	// an hour later: master no longer holds the first hour, the limits unchanged - nothing stored twice, the first
	// period keeps its start, the open one ends later
	imp(s.id, 1, read(-335, 1), period(-335, -100, 50, 5000, nil), period(-100, 1, 100, 10000, 2.0))
	if got, want := periods(s.id), "-20160 -6000 50 5000 NULL | -6000 60 100 10000 2.00"; got != want {
		t.Errorf("after an overlapping read with no change:\n got %s\nwant %s", got, want)
	}
	// the pool rescaled to 200 DTUs 90 minutes after base: one split
	imp(s.id, 2, read(-334, 2), period(-334, -100, 50, 5000, nil), period(-100, 1.5, 100, 10000, 2.0), period(1.5, 2, 200, 10000, 4.0))
	want3 := "-20160 -6000 50 5000 NULL | -6000 90 100 10000 2.00 | 90 120 200 10000 4.00"
	if got := periods(s.id); got != want3 {
		t.Errorf("after the change:\n got %s\nwant %s", got, want3)
	}
	// the same read again stores nothing twice
	imp(s.id, 2, read(-334, 2), period(-334, -100, 50, 5000, nil), period(-100, 1.5, 100, 10000, 2.0), period(1.5, 2, 200, 10000, 4.0))
	if got := periods(s.id); got != want3 {
		t.Errorf("after the same read twice:\n got %s\nwant %s", got, want3)
	}
	// the right taken away: the periods kept, the read's state and its words stored
	imp(s.id, 3, map[string]any{"kind": "limit_read", "server": "srv1", "pool": "pool1", "state": "no_right", "note": "the login is not a member of dbmanager in master"})
	if got := periods(s.id); got != want3 {
		t.Errorf("after a read without the right:\n got %s\nwant %s (kept)", got, want3)
	}
	if got, want := s.vals(`SELECT server, pool, state, note, (extract(epoch FROM read_at - $2::timestamptz) / 60)::int FROM pgvigil.mssql_pool_limit_read WHERE instance_id = $1`, s.id, at(0)),
		"srv1 pool1 no_right the login is not a member of dbmanager in master 180"; got != want {
		t.Errorf("the read's state:\n got %s\nwant %s", got, want)
	}
	// another database of the same pool keeps its own copy; the first one's is untouched
	imp(b, 3, read(-333, 3), period(-333, 1.5, 100, 10000, 2.0), period(1.5, 3, 200, 10000, 4.0))
	if got, want := periods(b), "-19980 90 100 10000 2.00 | 90 180 200 10000 4.00"; got != want {
		t.Errorf("the second database's copy:\n got %s\nwant %s", got, want)
	}
	if got := periods(s.id); got != want3 {
		t.Errorf("the first database's copy after the second's read:\n got %s\nwant %s", got, want3)
	}
	// a database that is no longer read (deleted) takes its copy with it
	if _, err := s.pool.Exec(s.ctx, `DELETE FROM pgvigil.instances WHERE instance_id = $1`, b); err != nil {
		t.Fatal(err)
	}
	if got := s.vals(`SELECT count(*) FROM pgvigil.mssql_pool_limit_history WHERE instance_id = $1`, b); got != "0" {
		t.Errorf("a deleted instance left %s periods", got)
	}
}
