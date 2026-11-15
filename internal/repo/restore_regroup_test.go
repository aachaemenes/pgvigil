package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), task 304b: a replica's restore chain is decided from the
// members of its availability group, and the members are found through mssql_backup_state's group rows (0066's
// import_mssql_backups). The collector reads mssql_restore_chain in its own hourly loop, so a chain read can come before
// the backups read that names the group: a backups import whose group rows changed decides the chain again (0264) - for
// the instance and for every member of the old and the new group that has a chain read of that database. Checked at each
// step: the stored verdict (its words and restorable point) is the one mssql_restore_chain answers now.
//
//	G1 a new replica's chain read before its first backups read: after the backups read it is decided with its group
//	G2 a member leaves the group (its database in no group): both sides are decided without each other
//	G3 a member's database is gone from its read (is_present false): the group's other member is decided without it
//	C1 a backups read with no group change decides nothing (decided_at kept)
//	C2 a grouped database's backups read on an instance with no chain read: no error, no verdict
func TestRestoreRegroupOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tag := time.Now().UnixNano() % 1000000000
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name LIKE $1`, fmt.Sprintf("rg-%%-%d", tag)); err != nil {
			t.Error(err)
		}
	}()
	inst := func(n string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`, fmt.Sprintf("rg-%s-%d", n, tag)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).Format(time.RFC3339) }
	snap := func(m int) time.Time { return now.Add(time.Duration(m) * time.Minute) }
	h := time.Hour
	g := fmt.Sprintf("%08x-0000-0000-0000-0000000000b1", tag)
	g2 := fmt.Sprintf("%08x-0000-0000-0000-0000000000b2", tag)
	db := func(n, group string) map[string]any {
		r := map[string]any{"kind": "database", "database_name": n, "state": "ONLINE", "recovery_model": "FULL", "created_utc": at(-30 * 24 * h),
			"is_snapshot": 0, "is_read_only": 0, "is_standby": 0}
		if group != "" {
			r["ag_group_id"], r["ag_name"] = group, "ag"
		}
		return r
	}
	const fork = "00000000-0000-0000-0000-00000000f0f0"
	// set: a set of dbx; LSNs x 1,000,000,000; the full's checkpoint is its first LSN (1000), which the log names
	set := func(role string, id int64, first, last int64, finish time.Duration) map[string]any {
		r := map[string]any{"kind": "set", "database_name": "dbx", "role": role, "backup_set_id": id, "backup_set_uuid": fmt.Sprintf("%08x-0000-0000-0000-%012d", tag, id),
			"set_type": map[string]string{"full": "D", "log": "L"}[role], "sink": "backup", "is_copy_only": 0, "position": 1,
			"first_lsn": fmt.Sprintf("%d000000001", first), "last_lsn": fmt.Sprintf("%d000000001", last), "checkpoint_lsn": fmt.Sprintf("%d000000001", first),
			"database_backup_lsn": "0", "last_recovery_fork_guid": fork, "first_recovery_fork_guid": fork, "recovery_model": "FULL",
			"start_utc": at(finish - time.Minute), "finish_utc": at(finish), "family_count": 1, "mirror_count": 1}
		if role == "log" {
			r["database_backup_lsn"] = "1000000000001"
		}
		return r
	}
	call := func(fn string, id int, s time.Time, rows []map[string]any) {
		t.Helper()
		b, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.`+fn+`($1, $2, $3::jsonb)`, id, s, string(b)); err != nil {
			t.Fatalf("%s: %v", fn, err)
		}
	}
	backups := func(id int, s time.Time, dbs ...map[string]any) { t.Helper(); call("import_mssql_backups", id, s, dbs) }
	chainRead := func(id int, s time.Time, rows ...map[string]any) {
		t.Helper()
		call("import_mssql_restore_chain", id, s, append(rows, map[string]any{"kind": "read"}))
	}
	type verdict struct {
		words, state string
		to, decided  time.Time
	}
	stored := func(id int) verdict {
		t.Helper()
		var v verdict
		var to *time.Time
		if err := pool.QueryRow(ctx, `SELECT coalesce(verdict, ''), state, restorable_to, decided_at FROM pgvigil.mssql_restore_verdicts WHERE instance_id = $1 AND database_name = 'dbx'`, id).Scan(&v.words, &v.state, &to, &v.decided); err != nil {
			t.Fatalf("the stored verdict of instance %d: %v", id, err)
		}
		if to != nil {
			v.to = *to
		}
		return v
	}
	// same: the stored verdict is the one the chain answers now
	same := func(step string, id int, who string) verdict {
		t.Helper()
		var words string
		var to *time.Time
		if err := pool.QueryRow(ctx, `SELECT coalesce(marks, ''), restorable_to FROM pgvigil.mssql_restore_chain($1, 'dbx') WHERE step = 0`, id).Scan(&words, &to); err != nil {
			t.Fatalf("%s: the live chain of %s: %v", step, who, err)
		}
		v := stored(id)
		live := time.Time{}
		if to != nil {
			live = *to
		}
		if v.words != words || !v.to.Equal(live) {
			t.Errorf("%s: %s's stored verdict %q (to %s) is not the live chain's %q (to %s)", step, who, v.words, v.to.Format(time.RFC3339), words, live.Format(time.RFC3339))
		}
		return v
	}
	fullTo, logTo := now.Add(-2*h), now.Add(-h-time.Minute) // a full's restorable point: its finish; a log's: its start
	p, s := inst("p"), inst("s")

	// G1: p backs up its full and reads it; s's chain read (its log after p's full) comes before s's first backups read
	backups(p, snap(0), db("dbx", g))
	chainRead(p, snap(0), db("dbx", g), set("full", 1, 1000, 1010, -2*h))
	chainRead(s, snap(0), db("dbx", g), set("log", 2, 1010, 1020, -h))
	backups(s, snap(1), db("dbx", g))
	if v := same("G1", s, "s"); v.state != "whole" {
		t.Errorf("G1: s's stored verdict %s (%q), want whole: decided with p's full once its group row is there", v.state, v.words)
	}
	if v := same("G1", p, "p"); !v.to.Equal(logTo) {
		t.Errorf("G1: p's stored restorable point %s, want %s (s's log)", v.to.Format(time.RFC3339), logTo.Format(time.RFC3339))
	}

	// G2: s chain-reads again (both decided with each other), then its database leaves the group
	chainRead(s, snap(2), db("dbx", g), set("log", 2, 1010, 1020, -h))
	backups(s, snap(3), db("dbx", ""))
	if v := same("G2", p, "p"); !v.to.Equal(fullTo) {
		t.Errorf("G2: p's stored restorable point %s, want %s (its own full: s left the group)", v.to.Format(time.RFC3339), fullTo.Format(time.RFC3339))
	}
	if v := same("G2", s, "s"); v.state != "no full" {
		t.Errorf("G2: s's stored verdict %s (%q), want no full (out of the group, its log alone)", v.state, v.words)
	}

	// G3: s's database joins again, then is gone from s's read
	backups(s, snap(4), db("dbx", g))
	same("G3 joined", p, "p")
	same("G3 joined", s, "s")
	backups(s, snap(5), db("other", ""))
	if v := same("G3", p, "p"); !v.to.Equal(fullTo) {
		t.Errorf("G3: p's stored restorable point %s, want %s (s's database is gone from its read)", v.to.Format(time.RFC3339), fullTo.Format(time.RFC3339))
	}

	// C1: a backups read of p that changes no group row decides nothing
	before := stored(p)
	backups(p, snap(6), db("dbx", g))
	if after := stored(p); !after.decided.Equal(before.decided) {
		t.Errorf("C1: p's decided_at moved from %s to %s on a backups read with no group change", before.decided.Format(time.RFC3339), after.decided.Format(time.RFC3339))
	}

	// C2: a grouped database's backups read on an instance that has no chain read
	q := inst("q")
	backups(q, snap(0), db("dbz", g2))
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_restore_verdicts WHERE instance_id = $1`, q).Scan(&n); err != nil || n != 0 {
		t.Errorf("C2: q's verdicts %d (%v), want 0", n, err)
	}
}
