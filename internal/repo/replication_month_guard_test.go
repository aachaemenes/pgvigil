package repo

import (
	"context"
	"testing"
	"time"
)

// TestReplicationMonthGuardOnAFreshStore: 0150's two reads of a month from a table's name - replication_hourly_purge()
// (the hours' months past their age) and replication_series() (the oldest month of replication_sample) - read it only
// from a name that ends in a month, inside a CASE, as N4-P10 made job_stats_hourly_purge() and purge() do (the purge
// 22008 fault of v0.3.0). The server may test a WHERE's conditions on every pg_class row before the join to
// pg_inherits, in any order; a table whose name ends in six digits that are no month (a TOAST table pg_toast_<six
// digits> once the database is past OID 100,000) then failed the whole read with 'date/time field value out of range'
// (22008). The plan where that happens is forced here (no nested loop, no index scan: pg_class is scanned whole with
// the name conditions as its filter) and a table named so stands in the store: both reads end without an error.
func TestReplicationMonthGuardOnAFreshStore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	r := haJoinFreshStore(ctx, t)
	if _, err := r.pool.Exec(ctx, `CREATE TABLE pgvigil.zz_guard_100017 (a int)`); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ name, sql string }{
		{"replication_hourly_purge()", `SELECT pgvigil.replication_hourly_purge()`},
		{"replication_series()", `SELECT count(*) FROM pgvigil.replication_series(1, now() - interval '30 days', now(), 3600, 'lag')`},
	} {
		tx, err := r.pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, `SET LOCAL enable_nestloop = off; SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off`); err != nil {
			_ = tx.Rollback(ctx)
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, c.sql); err != nil {
			t.Errorf("%s with a table named zz_guard_100017 (six digits, no month) and pg_class scanned whole: %v", c.name, err)
		}
		_ = tx.Rollback(ctx)
	}
}
