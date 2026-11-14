package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): stubbed reads of mssql_restore_chain through its import
// and the chain the repository decides (task 304's fold F1-F3, F7, F8): the steps in LSN order, the differential on its
// full, a newer copy-only full as the start set, a NUL log as a hole, a gap as a break or held while a replica's read is
// older than the set after it, a copy-only log never a step, the previous fork's full past the fork point not taken.
func TestRestoreChainOnAStore(t *testing.T) {
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
	tag := time.Now().UnixNano() % 1000000000
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name LIKE $1`, fmt.Sprintf("rc-%%-%d", tag)); err != nil {
			t.Error(err)
		}
	}()
	inst := func(n string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`, fmt.Sprintf("rc-%s-%d", n, tag)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).Format(time.RFC3339) }
	h := time.Hour
	db := func(n, group string) map[string]any {
		r := map[string]any{"kind": "database", "database_name": n, "state": "ONLINE", "recovery_model": "FULL", "created_utc": at(-30 * 24 * h),
			"is_snapshot": 0, "is_read_only": 0, "is_standby": 0}
		if group != "" {
			r["ag_group_id"], r["ag_name"] = group, "ag"
		}
		return r
	}
	const fork = "00000000-0000-0000-0000-00000000f0f0"
	// set: role, id, first and last LSN (x 1,000,000,000 in the stub), finish
	set := func(dbn, role string, id int64, first, last int64, finish time.Duration, extra map[string]any) map[string]any {
		r := map[string]any{"kind": "set", "database_name": dbn, "role": role, "backup_set_id": id, "backup_set_uuid": fmt.Sprintf("00000000-0000-0000-0000-%012d", id),
			"set_type": map[string]string{"full": "D", "copy_full": "D", "diff": "I", "log": "L"}[role], "sink": "backup",
			"is_copy_only": map[bool]int{true: 1, false: 0}[role == "copy_full"], "position": 1,
			"first_lsn": fmt.Sprintf("%d000000001", first), "last_lsn": fmt.Sprintf("%d000000001", last), "checkpoint_lsn": fmt.Sprintf("%d000000001", first),
			"database_backup_lsn": "0", "last_recovery_fork_guid": fork, "first_recovery_fork_guid": fork, "recovery_model": "FULL",
			"start_utc": at(finish - time.Minute), "finish_utc": at(finish), "family_count": 1, "mirror_count": 1}
		// a log or a differential names its full's checkpoint (the database's first full in each stub: LSN <n>00)
		if role == "log" || role == "diff" {
			r["database_backup_lsn"] = fmt.Sprintf("%d000000001", map[string]int64{"db1": 100, "db2": 200, "db3": 300, "db4": 400, "db5": 500, "db6": 600}[dbn])
		}
		for k, v := range extra {
			r[k] = v
		}
		return r
	}
	importAll := func(id int, snap time.Time, rows []map[string]any) {
		t.Helper()
		dbs := []map[string]any{}
		for _, r := range rows {
			if r["kind"] == "database" {
				dbs = append(dbs, r)
			}
		}
		for fn, p := range map[string][]map[string]any{"import_mssql_backups": dbs, "import_mssql_restore_chain": rows} {
			b, _ := json.Marshal(p)
			if _, err := pool.Exec(ctx, `SELECT pgvigil.`+fn+`($1, $2, $3::jsonb)`, id, snap, string(b)); err != nil {
				t.Fatalf("%s: %v", fn, err)
			}
		}
	}
	chain := func(id int, dbn string) (steps []string, verdict string) {
		t.Helper()
		rs, err := pool.Query(ctx, `SELECT step, role, coalesce(right(backup_set_uuid, 3), ''), coalesce(marks, '') FROM pgvigil.mssql_restore_chain($1, $2) ORDER BY step = 0, step`, id, dbn)
		if err != nil {
			t.Fatal(err)
		}
		defer rs.Close()
		for rs.Next() {
			var step int
			var role, id3, marks string
			if err := rs.Scan(&step, &role, &id3, &marks); err != nil {
				t.Fatal(err)
			}
			if step == 0 {
				verdict = marks
				continue
			}
			s := role + ":" + strings.TrimLeft(id3, "0")
			if marks != "" {
				s += "[" + marks + "]"
			}
			steps = append(steps, s)
		}
		return steps, verdict
	}
	a := inst("a")
	// db1: full 10 (LSN 100-110), logs 11 (105-120), 12 (120-130), a differential 13 (125-135) of full 10, log 14 (130-140)
	diffOf10 := map[string]any{"differential_base_guid": "00000000-0000-0000-0000-000000000010"}
	rows := []map[string]any{db("db1", ""), db("db2", ""), db("db3", ""), db("db4", ""),
		set("db1", "full", 10, 100, 110, -10*h, nil), set("db1", "log", 11, 105, 120, -9*h, nil), set("db1", "log", 12, 120, 130, -8*h, nil),
		set("db1", "diff", 13, 125, 135, -7*h, diffOf10), set("db1", "log", 14, 130, 140, -6*h, nil),
		// db2: full 20 (200-210), a copy-only full 21 later (300-310): the start set (F1); logs 22 (210-250) not needed, 23 (305-320)
		set("db2", "full", 20, 200, 210, -10*h, nil), set("db2", "copy_full", 21, 300, 310, -5*h, nil),
		set("db2", "log", 22, 210, 250, -6*h, nil), set("db2", "log", 23, 305, 320, -4*h, nil),
		// db3: full 30 (300-310), log 31 (305-320), a copy-only log 32 (320-325: never a step), a NUL log 33 (320-330), log 34 (330-340)
		set("db3", "full", 30, 300, 310, -10*h, nil), set("db3", "log", 31, 305, 320, -9*h, nil), set("db3", "log", 32, 320, 325, -8*h, map[string]any{"is_copy_only": 1}),
		set("db3", "log", 33, 320, 330, -7*h, map[string]any{"sink": "nul"}), set("db3", "log", 34, 330, 340, -6*h, nil),
		// db4: full 40 (400-410), log 41 (405-420), a gap, log 42 (430-440)
		set("db4", "full", 40, 400, 410, -10*h, nil), set("db4", "log", 41, 405, 420, -9*h, nil), set("db4", "log", 42, 430, 440, -8*h, nil),
		{"kind": "read"},
	}
	importAll(a, now, rows)
	for _, c := range []struct{ db, steps, verdict string }{
		{"db1", "full:10 diff:13 log:14", "restorable from these backups to"},
		{"db2", "copy_full:21[a copy-only full: no differential can follow it] log:23", "restorable from these backups to"},
		{"db3", "full:30 log:31", "went to NUL at"},
		{"db4", "full:40 log:41", "broken before the log of"},
	} {
		steps, verdict := chain(a, c.db)
		if strings.Join(steps, " ") != c.steps || !strings.HasPrefix(verdict, c.verdict) {
			t.Errorf("%s: %v | %q, want %s | %q...", c.db, steps, verdict, c.steps, c.verdict)
		}
	}
	state := func(id int, dbn string) string {
		t.Helper()
		var st string
		if err := pool.QueryRow(ctx, `SELECT state FROM pgvigil.mssql_restore_verdicts WHERE instance_id = $1 AND database_name = $2`, id, dbn).Scan(&st); err != nil {
			t.Fatalf("the verdict of %s: %v", dbn, err)
		}
		return st
	}
	for dbn, want := range map[string]string{"db1": "whole", "db2": "whole", "db3": "broken", "db4": "broken"} {
		if got := state(a, dbn); got != want {
			t.Errorf("%s's stored verdict: %s, want %s", dbn, got, want)
		}
	}
	// a replica of db5's group read before the set after the gap: the break is held (F3)
	g := fmt.Sprintf("%08x-0000-0000-0000-00000000aaaa", tag)
	p, s := inst("p"), inst("s")
	importAll(p, now.Add(-3*h), []map[string]any{db("db5", g), set("db5", "full", 50, 500, 510, -10*h, nil), set("db5", "log", 51, 505, 520, -9*h, nil), {"kind": "read"}})
	importAll(s, now, []map[string]any{db("db5", g), set("db5", "log", 53, 530, 540, -h, nil), {"kind": "read"}})
	steps, verdict := chain(s, "db5")
	if strings.Join(steps, " ") != "full:50 log:51" || !strings.HasPrefix(verdict, "not yet read from rc-p-") {
		t.Errorf("db5 with a replica read before the set after the gap: %v | %q", steps, verdict)
	}
	// once the replica's read is newer, the same gap is a break
	importAll(p, now.Add(time.Minute), []map[string]any{db("db5", g), set("db5", "full", 50, 500, 510, -10*h, nil), set("db5", "log", 51, 505, 520, -9*h, nil), {"kind": "read"}})
	if _, verdict = chain(s, "db5"); !strings.HasPrefix(verdict, "broken before the log of") {
		t.Errorf("db5 with every replica read after the gap: %q", verdict)
	}
	// the replica's late read decided the other member's stored verdict again
	if got := state(s, "db5"); got != "broken" {
		t.Errorf("db5's stored verdict on the member not read: %s, want broken", got)
	}
	// db6: the newest sets are on a new fork; the full is on the parent fork past the fork point: not taken (F2)
	const newFork = "00000000-0000-0000-0000-00000000f1f1"
	b := inst("b")
	importAll(b, now, []map[string]any{db("db6", ""), set("db6", "full", 60, 600, 650, -10*h, nil),
		set("db6", "log", 61, 620, 700, -2*h, map[string]any{"first_recovery_fork_guid": fork, "last_recovery_fork_guid": newFork, "fork_point_lsn": "620000000001"}),
		{"kind": "read"}})
	if steps, verdict = chain(b, "db6"); len(steps) != 0 || !strings.HasPrefix(verdict, "no full backup on the current recovery fork") {
		t.Errorf("db6 across a fork: %v | %q", steps, verdict)
	}
}
