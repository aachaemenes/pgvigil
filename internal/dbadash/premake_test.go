package dbadash

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// N4 (the lead's (c)): a DBA Dash history batch makes PAST months' partitions inside its own call (0134's
// dbadash_import_months) and had no retry. These rows cut the seam (importBatch) and hold it to: no partition made
// inside the batch's call, a parent held by another session ends the batch before its transaction ('busy'), a batch a
// deadlock ended taken again once. Each runs on a database of its own made from PGVIGIL_REPO_TEST_DSN's server.

// premakeStore makes a migrated database of its own and a SQL Server instance in it; it skips, naming why, without the
// DSN or a login that may create a database.
func premakeStore(t *testing.T) (context.Context, *pgxpool.Pool, int) {
	t.Helper()
	base := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if base == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	admin, err := pgxpool.New(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	var may bool
	if err := admin.QueryRow(ctx, `SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user`).Scan(&may); err != nil {
		t.Fatal(err)
	}
	if !may {
		t.Skip("the test login may not create a database (CREATEDB): these tests need a database of their own")
	}
	name := fmt.Sprintf("pgvigil_n4d_%d_%d", os.Getpid(), time.Now().UnixNano()%1000000000)
	if _, err := admin.Exec(ctx, `CREATE DATABASE `+name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), `DROP DATABASE IF EXISTS `+name+` WITH (FORCE)`); err != nil {
			t.Errorf("drop the test database %s: %v", name, err)
		}
	})
	dsn := base + " dbname=" + name
	if strings.HasPrefix(base, "postgres://") || strings.HasPrefix(base, "postgresql://") {
		u, err := url.Parse(base)
		if err != nil {
			t.Fatal(err)
		}
		u.Path = "/" + name
		dsn = u.String()
	}
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance('n4-dbadash', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	// this month's partition for the holders' rows (an unwired Migrate makes no month ahead)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('mssql_cpu_sample', now())`); err != nil {
		t.Fatal(err)
	}
	return ctx, pool, id
}

// cpuMapping is the cpu mapping (mssql_cpu_sample) of importMappings.
func cpuMapping(t *testing.T) importMapping {
	t.Helper()
	for _, m := range importMappings {
		if m.Key == "cpu" {
			return m
		}
	}
	t.Fatal("no cpu mapping")
	return importMapping{}
}

// monthsAgo is the first minute of the UTC month k months before this one, plus d days and an hour.
func monthsAgo(k, d int) time.Time {
	n := time.Now().UTC()
	return time.Date(n.Year(), n.Month()-time.Month(k), 1+d, 1, 0, 0, 0, time.UTC)
}

// cpuRows is a cpu batch as importOne builds it (importValue's time strings).
func cpuRows(at ...time.Time) []map[string]any {
	out := make([]map[string]any, 0, len(at))
	for _, a := range at {
		out = append(out, map[string]any{"at": importValue(a), "sql_pct": 7, "idle_pct": 90})
	}
	return out
}

// TestImportBatchMakesNoPartition: a batch whose rows fall in two past months (no partition yet) stores them, and no
// partition is made inside the batch's call (an event trigger records each table made with the statement that made
// it: a superuser's, the test skips with that reason otherwise). Red on today's seam: 0134's dbadash_import_months
// makes both inside import_dbadash_cpu.
func TestImportBatchMakesNoPartition(t *testing.T) {
	ctx, pool, id := premakeStore(t)
	var super bool
	if err := pool.QueryRow(ctx, `SELECT rolsuper FROM pg_roles WHERE rolname = current_user`).Scan(&super); err != nil {
		t.Fatal(err)
	}
	if !super {
		t.Skip("the event trigger that records a partition made inside the batch's call needs a superuser (the box's store runs this test)")
	}
	if _, err := pool.Exec(ctx, `
CREATE TABLE public.n4d_made (obj text, stmt text);
CREATE FUNCTION public.n4d_made_fn() RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.n4d_made (obj, stmt)
  SELECT c.object_identity, current_query() FROM pg_event_trigger_ddl_commands() c WHERE c.command_tag = 'CREATE TABLE';
END $$;
CREATE EVENT TRIGGER n4d_made ON ddl_command_end WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION public.n4d_made_fn();`); err != nil {
		t.Fatal(err)
	}
	a, b := monthsAgo(3, 0), monthsAgo(2, 4)
	n, retries, err := importBatch(ctx, pool, cpuMapping(t), id, cpuRows(a, a.Add(time.Minute), b), `{"linux": false}`)
	if err != nil || n != 3 || retries != 0 {
		t.Fatalf("the batch: %d row(s), %d retries, err %v; want 3, 0, nil", n, retries, err)
	}
	var inside, made string
	if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(obj, ', ' ORDER BY obj) FILTER (WHERE stmt ~ 'import_dbadash_'), ''),
	                                     coalesce(string_agg(obj, ', ' ORDER BY obj), '') FROM public.n4d_made`).Scan(&inside, &made); err != nil {
		t.Fatal(err)
	}
	if inside != "" {
		t.Errorf("partitions made inside the batch's call: %s (want none: the batch's months are made first, each in a transaction of its own)", inside)
	}
	for _, m := range []time.Time{a, b} {
		if want := "pgvigil.mssql_cpu_sample_" + m.Format("200601"); !strings.Contains(made, want) {
			t.Errorf("%s was not made (made: %q)", want, made)
		}
	}
}

// TestImportBatchBusyEndsFirst: while another session holds the parent (an open insert into mssql_cpu_sample), a batch
// into a month with no partition ends with 'busy' BEFORE its transaction - no row stored, within 4 s - and is not
// left waiting behind the holder. Red on today's seam: the call's own make waits for the holder, then stores the row.
func TestImportBatchBusyEndsFirst(t *testing.T) {
	ctx, pool, id := premakeStore(t)
	hold, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = hold.Rollback(context.Background()) }()
	if _, err := hold.Exec(ctx, `INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct) VALUES ($1, now(), 1, 1)`, id); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { // the holder lets go after 6 s, longer than the busy answer may take
		defer wg.Done()
		time.Sleep(6 * time.Second)
		_ = hold.Rollback(context.Background())
	}()
	month := monthsAgo(4, 0)
	t0 := time.Now()
	n, _, err := importBatch(ctx, pool, cpuMapping(t), id, cpuRows(month), `{"linux": false}`)
	took := time.Since(t0)
	wg.Wait()
	var stored int
	if qerr := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_cpu_sample WHERE instance_id = $1 AND snapshot_at = $2`, id, month).Scan(&stored); qerr != nil {
		t.Fatal(qerr)
	}
	if err == nil || !strings.Contains(err.Error(), "was busy: the batch was not run") || took > 4*time.Second || n != 0 || stored != 0 {
		t.Errorf("a batch behind a held parent: err %v, %d row(s), stored %d, in %s; want the busy error before its transaction, 0 rows, within 4 s",
			err, n, stored, took.Round(10*time.Millisecond))
	}
}

// TestImportBatchDeadlockRetried: a batch PostgreSQL ends as a deadlock's victim is taken again and its rows stored
// once. The cycle is made on the batch's own two locks (0134: the instance's import lock, then the CPU lock): a holder
// takes the CPU lock, the batch takes the import lock and waits, the holder then waits on the import lock; the batch
// waited first, so its deadlock check runs first and it is the victim. Red on today's seam: no retry.
func TestImportBatchDeadlockRetried(t *testing.T) {
	ctx, pool, id := premakeStore(t)
	month := monthsAgo(1, 2)
	// the month made first, so that the batch's only waits are the two locks of the cycle
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('mssql_cpu_sample', $1)`, month); err != nil {
		t.Fatal(err)
	}
	hold, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = hold.Rollback(context.Background()) }()
	if _, err := hold.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_cpu'), $1)`, id); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	var herr error
	go func() {
		defer wg.Done()
		time.Sleep(500 * time.Millisecond) // the batch holds the import lock and waits on the CPU lock by now
		if _, herr = hold.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('pgvigil.dbadash_import'), $1)`, id); herr == nil {
			herr = hold.Commit(ctx)
		}
	}()
	n, retries, err := importBatch(ctx, pool, cpuMapping(t), id, cpuRows(month, month.Add(time.Minute)), `{"linux": false}`)
	wg.Wait()
	var stored int
	if qerr := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_cpu_sample WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $2 + interval '1 hour'`, id, month).Scan(&stored); qerr != nil {
		t.Fatal(qerr)
	}
	if herr != nil {
		t.Errorf("the holder ended with %v (want its locks and commit: the batch is the deadlock's victim)", herr)
	}
	if err != nil || retries != 1 || n != 2 || stored != 2 {
		t.Errorf("a batch ended by a deadlock: err %v, %d retries, %d row(s), stored %d; want nil, 1, 2, 2 (taken again once, stored once)", err, retries, n, stored)
	}
}
