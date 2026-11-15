package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// task 304b, on a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): a replica's restore chain is decided from
// the members of its availability group, and the members are found through mssql_backup_state's group rows (0066's
// import_mssql_backups). The collector reads mssql_restore_chain in its own hourly loop, so a chain read can come before
// the backups read that names the group: a backups import whose group rows changed decides the chain again (0264) - for
// the instance and for every member of the old and the new group that has a chain read of that database. Checked at each
// step: the stored verdict (its words and restorable point) is the one mssql_restore_chain answers now.

// regroupFx holds one test's store, names and clock.
type regroupFx struct {
	t    *testing.T
	ctx  context.Context
	pool *pgxpool.Pool
	tag  int64
	now  time.Time
}

func newRegroupFx(t *testing.T) *regroupFx {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	f := &regroupFx{t: t, ctx: ctx, pool: pool, tag: time.Now().UnixNano() % 1000000000, now: time.Now().UTC().Truncate(time.Second)}
	t.Cleanup(func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name LIKE $1`, fmt.Sprintf("rg-%%-%d", f.tag)); err != nil {
			t.Error(err)
		}
		pool.Close()
	})
	return f
}

func (f *regroupFx) inst(n string) int {
	f.t.Helper()
	var id int
	if err := f.pool.QueryRow(f.ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`, fmt.Sprintf("rg-%s-%d", n, f.tag)).Scan(&id); err != nil {
		f.t.Fatal(err)
	}
	return id
}

func (f *regroupFx) at(d time.Duration) string { return f.now.Add(d).Format(time.RFC3339) }
func (f *regroupFx) snap(m int) time.Time      { return f.now.Add(time.Duration(m) * time.Minute) }
func (f *regroupFx) group(n string) string {
	return fmt.Sprintf("%08x-0000-0000-0000-0000000000%s", f.tag, n)
}

func (f *regroupFx) db(n, group string) map[string]any {
	r := map[string]any{"kind": "database", "database_name": n, "state": "ONLINE", "recovery_model": "FULL", "created_utc": f.at(-30 * 24 * time.Hour),
		"is_snapshot": 0, "is_read_only": 0, "is_standby": 0}
	if group != "" {
		r["ag_group_id"], r["ag_name"] = group, "ag"
	}
	return r
}

// set: a set of database dbn; LSNs x 1,000,000,000; a log names its full's checkpoint (fullFirst, the full's first LSN)
func (f *regroupFx) set(dbn, role string, id, first, last int64, finish time.Duration, fullFirst int64) map[string]any {
	const fork = "00000000-0000-0000-0000-00000000f0f0"
	r := map[string]any{"kind": "set", "database_name": dbn, "role": role, "backup_set_id": id, "backup_set_uuid": fmt.Sprintf("%08x-0000-0000-0000-%012d", f.tag, id),
		"set_type": map[string]string{"full": "D", "log": "L"}[role], "sink": "backup", "is_copy_only": 0, "position": 1,
		"first_lsn": fmt.Sprintf("%d000000001", first), "last_lsn": fmt.Sprintf("%d000000001", last), "checkpoint_lsn": fmt.Sprintf("%d000000001", first),
		"database_backup_lsn": "0", "last_recovery_fork_guid": fork, "first_recovery_fork_guid": fork, "recovery_model": "FULL",
		"start_utc": f.at(finish - time.Minute), "finish_utc": f.at(finish), "family_count": 1, "mirror_count": 1}
	if role == "log" {
		r["database_backup_lsn"] = fmt.Sprintf("%d000000001", fullFirst)
	}
	return r
}

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func (f *regroupFx) call(q execer, fn string, id int, s time.Time, rows []map[string]any) error {
	b, _ := json.Marshal(rows)
	_, err := q.Exec(f.ctx, `SELECT pgvigil.`+fn+`($1, $2, $3::jsonb)`, id, s, string(b))
	return err
}

func (f *regroupFx) backups(id int, s time.Time, dbs ...map[string]any) {
	f.t.Helper()
	if err := f.call(f.pool, "import_mssql_backups", id, s, dbs); err != nil {
		f.t.Fatalf("import_mssql_backups: %v", err)
	}
}

func (f *regroupFx) chainRead(id int, s time.Time, rows ...map[string]any) {
	f.t.Helper()
	if err := f.call(f.pool, "import_mssql_restore_chain", id, s, append(rows, map[string]any{"kind": "read"})); err != nil {
		f.t.Fatalf("import_mssql_restore_chain: %v", err)
	}
}

type regroupVerdict struct {
	words, state string
	to, decided  time.Time
}

func (f *regroupFx) stored(id int, dbn string) regroupVerdict {
	f.t.Helper()
	var v regroupVerdict
	var to *time.Time
	if err := f.pool.QueryRow(f.ctx, `SELECT coalesce(verdict, ''), state, restorable_to, decided_at FROM pgvigil.mssql_restore_verdicts WHERE instance_id = $1 AND database_name = $2`, id, dbn).Scan(&v.words, &v.state, &to, &v.decided); err != nil {
		f.t.Fatalf("the stored verdict of instance %d's %s: %v", id, dbn, err)
	}
	if to != nil {
		v.to = *to
	}
	return v
}

// same: the stored verdict is the one the chain answers now
func (f *regroupFx) same(step string, id int, dbn, who string) regroupVerdict {
	f.t.Helper()
	var words string
	var to *time.Time
	if err := f.pool.QueryRow(f.ctx, `SELECT coalesce(marks, ''), restorable_to FROM pgvigil.mssql_restore_chain($1, $2) WHERE step = 0`, id, dbn).Scan(&words, &to); err != nil {
		f.t.Fatalf("%s: the live chain of %s: %v", step, who, err)
	}
	v := f.stored(id, dbn)
	live := time.Time{}
	if to != nil {
		live = *to
	}
	if v.words != words || !v.to.Equal(live) {
		f.t.Errorf("%s: %s's stored verdict %q (to %s) is not the live chain's %q (to %s)", step, who, v.words, v.to.Format(time.RFC3339), words, live.Format(time.RFC3339))
	}
	return v
}

// The reads one after the other:
//
//	G1 a new replica's chain read before its first backups read: after the backups read it is decided with its group
//	G2 a member leaves the group (its database in no group): both sides are decided without each other
//	G3 a member's database is gone from its read (is_present false): the group's other member is decided without it
//	G4 one read moves a database from one group to another: both groups' members are decided again
//	G5 two databases change in one read: each is decided with its group
//	C1 a backups read with no group change decides nothing (decided_at kept)
//	C2 a grouped database's backups read on an instance with no chain read: no error, no verdict
func TestRestoreRegroupOnAStore(t *testing.T) {
	f := newRegroupFx(t)
	h := time.Hour
	g, g2 := f.group("b1"), f.group("b2")
	fullTo, logTo := f.now.Add(-2*h), f.now.Add(-h-time.Minute) // a full's restorable point: its finish; a log's: its start
	p, s := f.inst("p"), f.inst("s")
	full := func(dbn string, id, first int64) map[string]any {
		return f.set(dbn, "full", id, first, first+10, -2*h, first)
	}
	logOf := func(dbn string, id, first int64) map[string]any {
		return f.set(dbn, "log", id, first+10, first+20, -h, first)
	}

	// G1: p backs up its full and reads it; s's chain read (its log after p's full) comes before s's first backups read
	f.backups(p, f.snap(0), f.db("dbx", g))
	f.chainRead(p, f.snap(0), f.db("dbx", g), full("dbx", 1, 1000))
	f.chainRead(s, f.snap(0), f.db("dbx", g), logOf("dbx", 2, 1000))
	f.backups(s, f.snap(1), f.db("dbx", g))
	if v := f.same("G1", s, "dbx", "s"); v.state != "whole" {
		t.Errorf("G1: s's stored verdict %s (%q), want whole: decided with p's full once its group row is there", v.state, v.words)
	}
	if v := f.same("G1", p, "dbx", "p"); !v.to.Equal(logTo) {
		t.Errorf("G1: p's stored restorable point %s, want %s (s's log)", v.to.Format(time.RFC3339), logTo.Format(time.RFC3339))
	}

	// G2: s chain-reads again (both decided with each other), then its database leaves the group
	f.chainRead(s, f.snap(2), f.db("dbx", g), logOf("dbx", 2, 1000))
	f.backups(s, f.snap(3), f.db("dbx", ""))
	if v := f.same("G2", p, "dbx", "p"); !v.to.Equal(fullTo) {
		t.Errorf("G2: p's stored restorable point %s, want %s (its own full: s left the group)", v.to.Format(time.RFC3339), fullTo.Format(time.RFC3339))
	}
	if v := f.same("G2", s, "dbx", "s"); v.state != "no full" {
		t.Errorf("G2: s's stored verdict %s (%q), want no full (out of the group, its log alone)", v.state, v.words)
	}

	// G3: s's database joins again, then is gone from s's read
	f.backups(s, f.snap(4), f.db("dbx", g))
	f.same("G3 joined", p, "dbx", "p")
	f.same("G3 joined", s, "dbx", "s")
	f.backups(s, f.snap(5), f.db("other", ""))
	if v := f.same("G3", p, "dbx", "p"); !v.to.Equal(fullTo) {
		t.Errorf("G3: p's stored restorable point %s, want %s (s's database is gone from its read)", v.to.Format(time.RFC3339), fullTo.Format(time.RFC3339))
	}

	// C1: a backups read of p that changes no group row decides nothing
	before := f.stored(p, "dbx")
	f.backups(p, f.snap(6), f.db("dbx", g))
	if after := f.stored(p, "dbx"); !after.decided.Equal(before.decided) {
		t.Errorf("C1: p's decided_at moved from %s to %s on a backups read with no group change", before.decided.Format(time.RFC3339), after.decided.Format(time.RFC3339))
	}

	// C2: a grouped database's backups read on an instance that has no chain read
	q := f.inst("q")
	f.backups(q, f.snap(0), f.db("dbz", g2))
	var n int
	if err := f.pool.QueryRow(f.ctx, `SELECT count(*) FROM pgvigil.mssql_restore_verdicts WHERE instance_id = $1`, q).Scan(&n); err != nil || n != 0 {
		t.Errorf("C2: q's verdicts %d (%v), want 0", n, err)
	}

	// G4: one read moves a database straight from group gA to group gB: gA's member is decided without it
	ga, gb := f.group("c1"), f.group("c2")
	p4, s4 := f.inst("p4"), f.inst("s4")
	f.backups(p4, f.snap(0), f.db("dbx", ga))
	f.chainRead(p4, f.snap(0), f.db("dbx", ga), full("dbx", 11, 1000))
	f.backups(s4, f.snap(0), f.db("dbx", ga))
	f.chainRead(s4, f.snap(0), f.db("dbx", ga), logOf("dbx", 12, 1000))
	f.same("G4 before", p4, "dbx", "p4")
	f.backups(s4, f.snap(1), f.db("dbx", gb))
	if v := f.same("G4", p4, "dbx", "p4"); !v.to.Equal(fullTo) {
		t.Errorf("G4: p4's stored restorable point %s, want %s (s4 moved to another group)", v.to.Format(time.RFC3339), fullTo.Format(time.RFC3339))
	}
	if v := f.same("G4", s4, "dbx", "s4"); v.state != "no full" {
		t.Errorf("G4: s4's stored verdict %s, want no full (its new group holds no full)", v.state)
	}

	// G5: two databases of a new replica change in its one first backups read
	gc := f.group("c3")
	p5, s5 := f.inst("p5"), f.inst("s5")
	f.backups(p5, f.snap(0), f.db("dbx", gc), f.db("dby", gc))
	f.chainRead(p5, f.snap(0), f.db("dbx", gc), f.db("dby", gc), full("dbx", 21, 1000), full("dby", 22, 2000))
	f.chainRead(s5, f.snap(0), f.db("dbx", gc), f.db("dby", gc), logOf("dbx", 23, 1000), logOf("dby", 24, 2000))
	f.backups(s5, f.snap(1), f.db("dbx", gc), f.db("dby", gc))
	for _, dbn := range []string{"dbx", "dby"} {
		if v := f.same("G5", s5, dbn, "s5"); v.state != "whole" {
			t.Errorf("G5: s5's %s %s, want whole", dbn, v.state)
		}
		f.same("G5", p5, dbn, "p5")
	}
}

// The reads at the same moment (two connections; the review's two races):
//
//	R1 a new replica's chain import still open while its first backups import runs: once both commit, s and p are
//	   decided with each other (each import decides once the other's rows are committed)
//	R2 a member's chain import while another member's backups import, which changed the group, is still open: the chain
//	   import ends without an error, and its verdict is the group's as committed
func TestRestoreRegroupRacesOnAStore(t *testing.T) {
	f := newRegroupFx(t)
	h := time.Hour
	fullTo := f.now.Add(-2 * h)
	full := func(id int64) map[string]any { return f.set("dbx", "full", id, 1000, 1010, -2*h, 1000) }
	logOf := func(id int64) map[string]any { return f.set("dbx", "log", id, 1010, 1020, -h, 1000) }
	// beside: run fn on a second connection while tx stays open, then commit tx and wait for fn
	beside := func(step string, tx execer, commit func() error, fn func() error) error {
		t.Helper()
		done := make(chan error, 1)
		go func() { done <- fn() }()
		time.Sleep(1500 * time.Millisecond) // the second import reaches its decision (or waits for the first)
		if err := commit(); err != nil {
			t.Fatalf("%s: commit: %v", step, err)
		}
		select {
		case err := <-done:
			return err
		case <-time.After(30 * time.Second):
			t.Fatalf("%s: the second import did not end within 30 s of the first's commit", step)
		}
		return nil
	}

	// R1
	g := f.group("d1")
	p, s := f.inst("r1p"), f.inst("r1s")
	f.backups(p, f.snap(0), f.db("dbx", g))
	f.chainRead(p, f.snap(0), f.db("dbx", g), full(31))
	tx, err := f.pool.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.call(tx, "import_mssql_restore_chain", s, f.snap(1), []map[string]any{f.db("dbx", g), logOf(32), {"kind": "read"}}); err != nil {
		t.Fatalf("R1: s's chain import: %v", err)
	}
	if err := beside("R1", tx, func() error { return tx.Commit(f.ctx) }, func() error {
		return f.call(f.pool, "import_mssql_backups", s, f.snap(1), []map[string]any{f.db("dbx", g)})
	}); err != nil {
		t.Fatalf("R1: s's backups import: %v", err)
	}
	if v := f.same("R1", s, "dbx", "s"); v.state != "whole" {
		t.Errorf("R1: s's stored verdict %s (%q), want whole", v.state, v.words)
	}
	f.same("R1", p, "dbx", "p")

	// R2
	g = f.group("d2")
	p, s = f.inst("r2p"), f.inst("r2s")
	f.backups(p, f.snap(0), f.db("dbx", g))
	f.chainRead(p, f.snap(0), f.db("dbx", g), full(41))
	f.backups(s, f.snap(0), f.db("dbx", g))
	f.chainRead(s, f.snap(0), f.db("dbx", g), logOf(42))
	f.same("R2 before", p, "dbx", "p")
	tx, err = f.pool.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	// s's database leaves the group: its trigger decides p again inside tx
	if err := f.call(tx, "import_mssql_backups", s, f.snap(1), []map[string]any{f.db("dbx", "")}); err != nil {
		t.Fatalf("R2: s's backups import: %v", err)
	}
	if err := beside("R2", tx, func() error { return tx.Commit(f.ctx) }, func() error {
		return f.call(f.pool, "import_mssql_restore_chain", p, f.snap(1), []map[string]any{f.db("dbx", g), full(41), {"kind": "read"}})
	}); err != nil {
		t.Errorf("R2: p's chain import beside s's backups import: %v (want no error)", err)
	}
	if v := f.same("R2", p, "dbx", "p"); !v.to.Equal(fullTo) {
		t.Errorf("R2: p's stored restorable point %s, want %s (s left the group)", v.to.Format(time.RFC3339), fullTo.Format(time.RFC3339))
	}
}
