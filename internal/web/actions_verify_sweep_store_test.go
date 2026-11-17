package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestVerifySweepAsTheAuditLoginOnAStore (J16-SWEEP; a box row: PGVIGIL_REPO_TEST_DSN, a login that
// may CREATE ROLE): serve's sweep of the verifies a stopped serve left 'started' (SweepVerifies: at serve's start and
// hourly) runs on the actions door's audit pool, whose login is a member of pgvigil_collector (docs/alerts.md: the
// collector role is the actions door's audit login). apply_roles takes every pgvigil table from that role, so the
// sweep reaches actions_log only through the collector's door - a read of the table there is 'permission denied'
// (42501), and serve WARNed it at every start and every hour while a stopped serve's 'started' verify stayed open. On
// such a login: the sweep returns no error, writes one 'ended unknown' row for the open verify of an instance whose
// verify lock is free, writes nothing for an instance whose lock another session holds (a verify runs there), and a
// second sweep writes no second end row; once the lock is free that instance's verify is ended too.
func TestVerifySweepAsTheAuditLoginOnAStore(t *testing.T) {
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
	t.Cleanup(pool.Close) // registered first, so it runs after every cleanup below that uses it
	sfx := time.Now().UnixNano() % 1000000000
	free, held := fmt.Sprintf("j16sweep-free-%d", sfx), fmt.Sprintf("j16sweep-held-%d", sfx)
	ids := map[string]int{}
	for _, n := range []string{free, held} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, n).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
	}
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.actions_log WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, []int{ids[free], ids[held]}); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	})
	// one 'started' verify on each instance, two hours old, with no end row: what a stopped serve leaves
	for i, n := range []string{free, held} {
		set := fmt.Sprintf("00000000-0000-0000-0016-%012d", i+1)
		row := fmt.Sprintf(`[{"instance_name": %q, "ui_user": "j16sweep", "client": "t", "action": "verify_backup", "target": %q,
			"target_id": %q, "reason": "J16-SWEEP store test", "outcome": "started", "statement": "RESTORE VERIFYONLY"}]`, n, set, set)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_actions_log($1, now() - interval '2 hours', $2::jsonb)`, ids[n], row); err != nil {
			t.Fatalf("the 'started' verify of %s: %v", n, err)
		}
	}
	audit := collectorPool(ctx, t, pool, dsn, sfx)
	// the test's audit login is a correctly roled one: it reads no pgvigil table
	var n int
	if err := audit.QueryRow(ctx, `SELECT count(*) FROM pgvigil.actions_log`).Scan(&n); err == nil || !strings.Contains(err.Error(), "42501") {
		t.Fatalf("the audit login read actions_log (%d rows, err %v): the test's login is not the collector's", n, err)
	}
	// a verify runs on the held instance: its lock, on a session of its own
	lock, err := pgx.ConnectConfig(ctx, pool.Config().ConnConfig.Copy())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lock.Close(context.Background()) })
	if _, err := lock.Exec(ctx, `SELECT pg_advisory_lock($1, $2)`, verifyLockClass, ids[held]); err != nil {
		t.Fatal(err)
	}
	ends := func(name string) (int, string) {
		t.Helper()
		var k int
		var detail string
		if err := pool.QueryRow(ctx, `SELECT count(*), coalesce(min(detail), '') FROM pgvigil.actions_log
		                               WHERE instance_id = $1 AND action = 'verify_backup' AND outcome = 'ended unknown'`, ids[name]).Scan(&k, &detail); err != nil {
			t.Fatal(err)
		}
		return k, detail
	}
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: audit}}
	if err := s.SweepVerifies(ctx); err != nil {
		t.Fatalf("the sweep as the audit login: %v (want no error: the collector's login reads actions_log only through its door)", err)
	}
	if k, d := ends(free); k != 1 || !strings.HasPrefix(d, "ended unknown: serve stopped") {
		t.Errorf("the free instance's open verify: %d 'ended unknown' row(s) %q, want 1 starting 'ended unknown: serve stopped'", k, d)
	}
	if k, _ := ends(held); k != 0 {
		t.Errorf("the held instance (a verify runs there): %d 'ended unknown' row(s), want 0", k)
	}
	if err := s.SweepVerifies(ctx); err != nil {
		t.Fatalf("the second sweep: %v", err)
	}
	if k, _ := ends(free); k != 1 {
		t.Errorf("after a second sweep the free instance has %d 'ended unknown' rows, want still 1", k)
	}
	if _, err := lock.Exec(ctx, `SELECT pg_advisory_unlock($1, $2)`, verifyLockClass, ids[held]); err != nil {
		t.Fatal(err)
	}
	if err := s.SweepVerifies(ctx); err != nil {
		t.Fatalf("the sweep after the lock is free: %v", err)
	}
	if k, _ := ends(held); k != 1 {
		t.Errorf("the held instance once its lock is free: %d 'ended unknown' row(s), want 1", k)
	}
}
