package repo

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The partitions-ahead pass (0271, N4), ported from an earlier build of the same design onto
// databases of their own (throwawayRepo): on the shared test database another package's Migrate makes a month under
// them. The retry rows of that build are not ported (Import's own retry and its test are another branch's).

// TestPartitionsAheadTwice (R13): with next month's partitions of every month parent dropped, two passes at once both
// end without an error and every one of them exists again (a partition cannot exist twice; one of two makers finds it
// made).
func TestPartitionsAheadTwice(t *testing.T) {
	ctx, r, _, _ := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	from, monthsTo, daysTo := AheadWindow(now)
	next := monthsTo.Format("200601")
	rows, err := r.pool.Query(ctx, `SELECT parent FROM pgvigil.partition_parents() WHERE unit = 'month' ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	parents, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil || len(parents) < 80 {
		t.Fatalf("partition_parents: %d, %v; want at least 80", len(parents), err)
	}
	for _, p := range parents {
		if _, err := r.pool.Exec(ctx, `DROP TABLE IF EXISTS `+pgx.Identifier{"pgvigil", p + "_" + next}.Sanitize()); err != nil {
			t.Fatal(err)
		}
	}
	var wg sync.WaitGroup
	errs := make([]error, 2)
	res := make([]AheadResult, 2)
	for i := range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			res[i], errs[i] = PartitionsAhead(ctx, r.pool, from, monthsTo, daysTo)
		}()
	}
	wg.Wait()
	if err := errors.Join(errs...); err != nil {
		t.Fatalf("two passes at once: %v", err)
	}
	var missing int
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM unnest($1::text[]) p WHERE to_regclass('pgvigil.' || p || '_' || $2) IS NULL`, parents, next).Scan(&missing); err != nil || missing != 0 {
		t.Fatalf("after two passes: %d of %d next-month partitions missing (%v); passes %+v", missing, len(parents), err, res)
	}
	if res[0].Made+res[1].Made < len(parents) {
		t.Errorf("made %d + %d < %d dropped", res[0].Made, res[1].Made, len(parents))
	}
}

// TestPartitionsAheadLastDayOfMonth: on the last UTC day of a month the window still reaches two days on - the daily
// parent's partition of the 2nd of the next month is made.
func TestPartitionsAheadLastDayOfMonth(t *testing.T) {
	ctx, r, _, _ := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	last := time.Date(now.Year(), now.Month(), 1, 10, 0, 0, 0, time.UTC).AddDate(0, -1, -1) // the last day of the month two back, 10:00
	name := "mssql_requests_" + last.Add(48*time.Hour).Format("20060102")
	if _, err := r.pool.Exec(ctx, `DROP TABLE IF EXISTS `+pgx.Identifier{"pgvigil", name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	from, monthsTo, daysTo := AheadWindow(last)
	if _, err := PartitionsAhead(ctx, r.pool, from, monthsTo, daysTo); err != nil {
		t.Fatal(err)
	}
	var made bool
	if err := r.pool.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, "pgvigil."+name).Scan(&made); err != nil {
		t.Fatal(err)
	}
	if !made {
		t.Fatalf("a pass at %s left %s unmade (its window reaches %s)", last.Format(time.RFC3339), name, daysTo.Format(time.RFC3339))
	}
}

// TestMigrateOnOneConnection: Migrate's partitions pass needs no second connection - a repository DSN with
// pool_max_conns=1 migrates and makes its partitions without waiting on its own migrate connection.
func TestMigrateOnOneConnection(t *testing.T) {
	_, _, _, dsn := throwawayRepo(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	one := dsn + " pool_max_conns=1"
	if strings.Contains(dsn, "://") {
		sep := "?"
		if strings.Contains(dsn, "?") {
			sep = "&"
		}
		one = dsn + sep + "pool_max_conns=1"
	}
	r1, err := Open(ctx, one)
	if err != nil {
		t.Fatal(err)
	}
	defer r1.Close()
	if _, err := r1.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	skipUnwiredMigrate(ctx, t, r1.pool)
	_, monthsTo, _ := AheadWindow(time.Now())
	var made bool
	if err := r1.pool.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, "pgvigil.activity_sample_"+monthsTo.Format("200601")).Scan(&made); err != nil {
		t.Fatal(err)
	}
	if !made || ctx.Err() != nil {
		t.Fatalf("Migrate on a one-connection pool: next month's activity_sample made %v (%v)", made, ctx.Err())
	}
}

// TestPartitionsAheadOneTransactionEach: each make of a pass is its own transaction. Next month's partitions of
// activity_sample and wait_sample are dropped and wait_sample is held by an open ROW EXCLUSIVE lock; while the pass
// waits on wait_sample (pg_locks), activity_sample - made by the same pass a moment before - takes an ACCESS EXCLUSIVE
// lock within 100 ms (a pass in one transaction would still hold it); the pass then answers made 1, busy 1, no error.
func TestPartitionsAheadOneTransactionEach(t *testing.T) {
	ctx, r, _, dsn := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	// every partition made first, so the pass below has only the two it is about (on an unwired tree Migrate makes none)
	if _, err := r.PartitionsAhead(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	_, monthsTo, _ := AheadWindow(now)
	for _, p := range []string{"activity_sample", "wait_sample"} {
		if _, err := r.pool.Exec(ctx, `DROP TABLE IF EXISTS `+pgx.Identifier{"pgvigil", p + "_" + monthsTo.Format("200601")}.Sanitize()); err != nil {
			t.Fatal(err)
		}
	}
	hold, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = hold.Close(context.Background()) }()
	htx, err := hold.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = htx.Rollback(context.Background()) }()
	if _, err := htx.Exec(ctx, `LOCK TABLE pgvigil.wait_sample IN ROW EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	probe, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = probe.Close(context.Background()) }()
	type out struct {
		res AheadResult
		err error
	}
	done := make(chan out, 1)
	go func() {
		res, err := r.PartitionsAhead(ctx, now)
		done <- out{res, err}
	}()
	waiting := false
	for range 300 {
		if err := probe.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_locks WHERE NOT granted AND relation = 'pgvigil.wait_sample'::regclass)`).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !waiting {
		t.Fatal("the pass never waited on the held parent wait_sample")
	}
	ptx, err := probe.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ptx.Exec(ctx, `SET LOCAL lock_timeout = '100ms'`); err != nil {
		t.Fatal(err)
	}
	_, lockErr := ptx.Exec(ctx, `LOCK TABLE pgvigil.activity_sample IN ACCESS EXCLUSIVE MODE`)
	_ = ptx.Rollback(ctx)
	o := <-done
	if lockErr != nil || o.err != nil || o.res.Made != 1 || o.res.Busy != 1 {
		t.Fatalf("activity_sample during the wait: %v; the pass: %+v, %v; want a free lock, made 1, busy 1, no error", lockErr, o.res, o.err)
	}
	_ = htx.Rollback(ctx)
	if res, err := r.PartitionsAhead(ctx, now); err != nil || res.Made != 1 {
		t.Fatalf("the pass after the hold: %+v, %v; want wait_sample's made", res, err)
	}
}
