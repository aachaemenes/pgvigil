package repo

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestImportRetriesADeadlockOnAStore: an import that makes a new month's partition holds the parent's lock while
// it goes on to upsert a shared query_text row; a second import into an existing month that already holds that
// query_text row then waits on the parent, and PostgreSQL ends one of the two with 40P01 (the demo seed met it
// across a month line: import_activity, 'deadlock detected'). The waiter that waited first is the one PostgreSQL
// ends - here the Repo's import, since the raw transaction waits later and with a 10 s deadlock_timeout - so
// Repo.Import must take that import again and return no error, and both instances' rows must be stored.
func TestImportRetriesADeadlockOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	// the retry must have run: a run with no deadlock (no WARN) fails instead of passing
	var logged bytes.Buffer
	r.SetLog(slog.New(slog.NewTextHandler(&logged, &slog.HandlerOptions{Level: slog.LevelWarn})))

	tag := time.Now().UnixNano() % 1000000000
	// Two months far ahead, so neither partition exists before the test: m0 is made first (the 'existing' month),
	// m1 is the one the Repo's import makes.
	year := 2300 + int(tag%400)
	m0 := time.Date(year, time.March, 10, 12, 0, 0, 0, time.UTC)
	m1 := time.Date(year, time.April, 10, 12, 0, 0, 0, time.UTC)
	parts := []string{fmt.Sprintf("activity_sample_%04d03", year), fmt.Sprintf("activity_sample_%04d04", year)}
	hash := 9100000000000 + tag
	defer func() {
		bg := context.Background()
		if _, err := pool.Exec(bg, `DELETE FROM pgvigil.instances WHERE name LIKE $1`, fmt.Sprintf("dl-%%-%d", tag)); err != nil {
			t.Error(err)
		}
		for _, p := range parts {
			if _, err := pool.Exec(bg, fmt.Sprintf(`DROP TABLE IF EXISTS pgvigil.%s`, p)); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(bg, `DELETE FROM pgvigil.query_text WHERE query_hash = $1`, hash); err != nil {
			t.Error(err)
		}
	}()
	inst := func(n string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`, fmt.Sprintf("dl-%s-%d", n, tag)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	i0, i1 := inst("old"), inst("new")
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('activity_sample', $1)`, m0); err != nil {
		t.Fatal(err)
	}
	row := func(pid int) []map[string]any {
		return []map[string]any{{"kind": "session", "pid": pid, "state": "active", "query_hash": hash, "query": "select 'dl'"}}
	}

	// tx1 holds the shared query_text row first.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release()
	tx1, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx1.Rollback(context.Background()) //nolint:errcheck // committed below on the happy path
	if _, err := tx1.Exec(ctx, `SET LOCAL deadlock_timeout = '10s'`); err != nil {
		t.Fatal(err)
	}
	var pid1 int
	if err := tx1.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&pid1); err != nil {
		t.Fatal(err)
	}
	if _, err := tx1.Exec(ctx, `INSERT INTO pgvigil.query_text (query_hash, first_seen, last_seen, query) VALUES ($1, $2, $2, 'select ''dl''')`, hash, m0); err != nil {
		t.Fatal(err)
	}

	// The Repo's import into the new month: it makes m1's partition (the parent's lock) and then waits on tx1's row.
	done := make(chan error, 1)
	go func() { done <- r.Import(ctx, i1, "activity", m1, row(2)) }()
	waiting := false
	for i := 0; i < 200 && !waiting; i++ {
		// exactly the wait that matters: a backend blocked by tx1 (its query_text row), never any other lock waiter
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY (pg_blocking_pids(pid)))`, pid1).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if !waiting {
			time.Sleep(20 * time.Millisecond)
		}
	}
	if !waiting {
		t.Fatal("the Repo's import never waited on tx1's query_text row")
	}

	// tx1 now imports into the existing month: it waits on the parent the Repo's import holds - the cycle.
	if _, err := tx1.Exec(ctx, `SELECT pgvigil.import_activity($1, $2, $3::jsonb)`, i0, m0, `[{"kind":"session","pid":1,"state":"active","query_hash":`+fmt.Sprint(hash)+`,"query":"select 'dl'"}]`); err != nil {
		t.Fatalf("tx1's import (the later waiter, deadlock_timeout 10 s) was ended: %v", err)
	}
	if err := tx1.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Repo.Import into a new month after a deadlock: %v (want it taken again and stored)", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("Repo.Import did not return within 60 s")
	}
	if got := strings.Count(logged.String(), "taking it again"); got != 1 || !strings.Contains(logged.String(), "attempt=1") {
		t.Fatalf("the retry's WARN lines: %d, log %q (want exactly one, attempt=1: a pass without a deadlock proves nothing)", got, logged.String())
	}
	var n0, n1 int
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE instance_id = $1), count(*) FILTER (WHERE instance_id = $2)
	  FROM pgvigil.activity_sample WHERE instance_id IN ($1, $2)`, i0, i1).Scan(&n0, &n1); err != nil {
		t.Fatal(err)
	}
	if n0 != 1 || n1 != 1 {
		t.Fatalf("activity rows stored: old month %d, new month %d (want 1 and 1)", n0, n1)
	}
}
