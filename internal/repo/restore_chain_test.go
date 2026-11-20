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
// and the chain the repository decides: the steps in LSN order, the differential on its full, a newer copy-only full
// as the start set, a NUL log as a hole, a gap as a break or held while a replica's read is older than the set after
// it, a copy-only log never a step, the previous fork's full past the fork point not taken; and a restore over the
// database whose new fork's LSNs lie BELOW the old fork's (the fork of the
// newest set by its finish), a capped read and a replica without a start set (a gap below what they listed is held 'not
// read whole'), a distributed group (held 'not judged'), a backup_set_uuid sent twice, a 25-digit LSN round trip, the
// device and NUL marks, a log's start as its restorable point where msdb has no last_valid_restore_time.
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
			r["database_backup_lsn"] = fmt.Sprintf("%d000000001", map[string]int64{"db1": 100, "db2": 200, "db3": 300, "db4": 400, "db5": 500, "db6": 600,
				"db7": 705, "db8": 800, "db10": 1000, "db11": 1100, "db12": 1200, "db13": 1300}[dbn])
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
		// mssql_backups first, as the collector does: the restore chain's import reads the group's members from its rows
		// (a map here gave a random order - run 302d's db10 decided before its replica's group row existed)
		for _, step := range []struct {
			fn string
			p  []map[string]any
		}{{"import_mssql_backups", dbs}, {"import_mssql_restore_chain", rows}} {
			b, _ := json.Marshal(step.p)
			if _, err := pool.Exec(ctx, `SELECT pgvigil.`+step.fn+`($1, $2, $3::jsonb)`, id, snap, string(b)); err != nil {
				t.Fatalf("%s: %v", step.fn, err)
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
	rows := []map[string]any{db("db1", ""), db("db2", ""), db("db3", ""), db("db4", ""), db("db8", ""), db("db12", ""), db("db13", ""), db("db9", ""),
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
		// db8: a capped read (5 logs since the start set, the newest 2 sent): the gap below them is held, never a break
		set("db8", "full", 80, 800, 810, -10*h, nil), set("db8", "log", 83, 830, 840, -2*h, map[string]any{"logs_since": 5}),
		set("db8", "log", 84, 840, 850, -h, map[string]any{"logs_since": 5}),
		// db12: one backup_set_uuid sent twice (a RESTORE on the server writes the set's rows again): stored once, the lowest id
		set("db12", "full", 120, 1200, 1210, -10*h, nil), set("db12", "full", 121, 1200, 1210, -10*h, map[string]any{"backup_set_uuid": "00000000-0000-0000-0000-000000000120"}),
		set("db12", "log", 122, 1205, 1220, -9*h, nil),
		// db13: a snapshot full to a virtual device, then a newer full to NUL, a log: the start marked, the NUL full noted
		set("db13", "full", 130, 1300, 1310, -10*h, map[string]any{"is_snapshot": 1}), set("db13", "full", 131, 1320, 1330, -8*h, map[string]any{"sink": "nul"}),
		set("db13", "log", 132, 1305, 1340, -7*h, nil),
		{"kind": "file", "backup_set_id": 130, "family": 1, "mirror": 0, "device_kind": "virtual device", "path": "{6F9619FF-8B86-D011-B42D-00C04FC964FF}"},
		{"kind": "file", "backup_set_id": 132, "family": 1, "mirror": 0, "device_kind": "disk", "path": "/var/opt/mssql/bk/l132.trn"},
		// db9: LSNs of 25 digits (numeric(25,0) whole) through the payload, the store and the chain's text
		set("db9", "full", 90, 0, 0, -10*h, map[string]any{"first_lsn": "1234567890123456789012340", "last_lsn": "1234567890123456789012345",
			"checkpoint_lsn": "1234567890123456789012340"}),
		set("db9", "log", 91, 0, 0, -9*h, map[string]any{"first_lsn": "1234567890123456789012341", "last_lsn": "9999999999999999999999999",
			"database_backup_lsn": "1234567890123456789012340"}),
		{"kind": "read", "nostart_days": 7},
	}
	importAll(a, now, rows)
	for _, c := range []struct{ db, steps, verdict string }{
		{"db1", "full:10 diff:13 log:14", "restorable from these backups to"},
		{"db2", "copy_full:21[a copy-only full: no differential can follow it] log:23", "restorable from these backups to"},
		{"db3", "full:30 log:31", "went to NUL at"},
		{"db4", "full:40 log:41", "broken before the log of"},
		{"db8", "full:80", "not read whole: rc-a-"},
		{"db12", "full:120 log:122", "restorable from these backups to"},
		{"db9", "full:90 log:91", "restorable from these backups to"},
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
	for dbn, want := range map[string]string{"db1": "whole", "db2": "whole", "db3": "broken", "db4": "broken", "db8": "held", "db12": "whole"} {
		if got := state(a, dbn); got != want {
			t.Errorf("%s's stored verdict: %s, want %s", dbn, got, want)
		}
	}
	// a log's restorable point where msdb has no last_valid_restore_time: its start (db1's log 14 began a minute before it ended)
	var to time.Time
	if err := pool.QueryRow(ctx, `SELECT restorable_to FROM pgvigil.mssql_restore_verdicts WHERE instance_id = $1 AND database_name = 'db1'`, a).Scan(&to); err != nil {
		t.Fatal(err)
	} else if !to.Equal(now.Add(-6*h - time.Minute)) {
		t.Errorf("db1 restorable to %v, want the last log's start %v", to, now.Add(-6*h-time.Minute))
	}
	// db12: the uuid sent twice is stored once, by the lowest backup_set_id
	var n12 int
	var id12 int64
	if err := pool.QueryRow(ctx, `SELECT count(*), min(backup_set_id) FROM pgvigil.mssql_restore_sets WHERE instance_id = $1 AND database_name = 'db12' AND role = 'full'`, a).Scan(&n12, &id12); err != nil || n12 != 1 || id12 != 120 {
		t.Errorf("db12's full stored %d times, id %d (%v), want once, 120", n12, id12, err)
	}
	// db9: the LSNs leave the chain as the same 25-digit text
	var f9, l9 string
	if err := pool.QueryRow(ctx, `SELECT max(first_lsn) FILTER (WHERE step = 1), max(last_lsn) FILTER (WHERE step = 2) FROM pgvigil.mssql_restore_chain($1, 'db9')`, a).Scan(&f9, &l9); err != nil ||
		f9 != "1234567890123456789012340" || l9 != "9999999999999999999999999" {
		t.Errorf("db9's LSNs came back %q and %q (%v)", f9, l9, err)
	}
	// db13: the start marked as a snapshot to a virtual device and the newer full to NUL noted; the log a step
	steps, verdict := chain(a, "db13")
	if len(steps) != 2 || !strings.HasPrefix(steps[0], "full:130[") || !strings.Contains(steps[0], "a snapshot backup") ||
		!strings.Contains(steps[0], "a virtual-device backup") || !strings.Contains(steps[0], "a newer full went to NUL at") || steps[1] != "log:132" {
		t.Errorf("db13: %v | %q", steps, verdict)
	}
	// a replica of db5's group read before the set after the gap: the break is held (F3)
	g := fmt.Sprintf("%08x-0000-0000-0000-00000000aaaa", tag)
	p, s := inst("p"), inst("s")
	importAll(p, now.Add(-3*h), []map[string]any{db("db5", g), set("db5", "full", 50, 500, 510, -10*h, nil), set("db5", "log", 51, 505, 520, -9*h, nil), {"kind": "read"}})
	importAll(s, now, []map[string]any{db("db5", g), set("db5", "log", 53, 530, 540, -h, nil), {"kind": "read"}})
	steps, verdict = chain(s, "db5")
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
	// db7: a restore over the database to an older point. The old fork: full 70, log 71 and a safety copy-only full 72
	// (last_lsn 800); the new fork: full 73 and log 74 with LSNs BELOW 800. The chain is the new fork's (the newest set by
	// its finish), never the old fork's greater last_lsn; the next read sends the new fork only and the old fork's sets go.
	const fork7 = "00000000-0000-0000-0000-00000000f7f7"
	c := inst("c")
	nf7 := map[string]any{"first_recovery_fork_guid": fork7, "last_recovery_fork_guid": fork7}
	new7 := []map[string]any{set("db7", "full", 73, 705, 720, -2*h, nf7), set("db7", "log", 74, 715, 730, -h, nf7)}
	importAll(c, now, append([]map[string]any{db("db7", ""), set("db7", "full", 70, 700, 750, -10*h, map[string]any{"database_backup_lsn": "0"}),
		set("db7", "log", 71, 740, 800, -9*h, map[string]any{"database_backup_lsn": "700000000001"}),
		set("db7", "copy_full", 72, 790, 800, -3*h, nil), {"kind": "read"}}, new7...))
	if steps, verdict = chain(c, "db7"); strings.Join(steps, " ") != "full:73 log:74" || !strings.HasPrefix(verdict, "restorable from these backups to") {
		t.Errorf("db7 after a restore over: %v | %q", steps, verdict)
	}
	importAll(c, now.Add(time.Minute), append([]map[string]any{db("db7", ""), {"kind": "read"}}, new7...))
	var n7 int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_restore_sets WHERE instance_id = $1 AND database_name = 'db7'`, c).Scan(&n7); err != nil || n7 != 2 {
		t.Errorf("db7's stored sets after the new fork's read: %d (%v), want 2", n7, err)
	}
	// db10: a replica without a start set lists its last 7 days only: a gap older than that is held 'not read whole'
	g10 := fmt.Sprintf("%08x-0000-0000-0000-00000000bbbb", tag)
	p10, s10 := inst("p10"), inst("s10")
	importAll(p10, now, []map[string]any{db("db10", g10), set("db10", "full", 100, 1000, 1010, -10*24*h, nil), {"kind": "read"}})
	importAll(s10, now, []map[string]any{db("db10", g10), set("db10", "log", 103, 1030, 1040, -h, nil), {"kind": "read", "nostart_days": 7}})
	if steps, verdict = chain(s10, "db10"); strings.Join(steps, " ") != "full:100" || !strings.HasPrefix(verdict, "not read whole: rc-s10-") {
		t.Errorf("db10 with a replica that reads its last 7 days: %v | %q", steps, verdict)
	}
	if got := state(s10, "db10"); got != "held" {
		t.Errorf("db10's stored verdict: %s, want held", got)
	}
	// db11: a group in a distributed availability group (its other side not merged): a gap is held 'not judged'
	g11 := fmt.Sprintf("%08x-0000-0000-0000-00000000cccc", tag)
	p11, s11 := inst("p11"), inst("s11")
	for _, r := range [][]any{{p11, g11, "rc-p11", "ag11", false}, {p11, "dd000000-0000-0000-0000-0000000000dd", "ag11", "dag11", true}} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_ag_state (instance_id, group_id, replica_server, snapshot_at, group_name, is_distributed) VALUES ($1, $2, $3, now(), $4, $5)`, r...); err != nil {
			t.Fatal(err)
		}
	}
	importAll(p11, now, []map[string]any{db("db11", g11), set("db11", "full", 110, 1100, 1110, -10*h, nil), set("db11", "log", 111, 1105, 1120, -9*h, nil), {"kind": "read"}})
	importAll(s11, now, []map[string]any{db("db11", g11), set("db11", "log", 113, 1130, 1140, -h, nil), {"kind": "read"}})
	if steps, verdict = chain(s11, "db11"); strings.Join(steps, " ") != "full:110 log:111" || !strings.HasPrefix(verdict, "not judged (the distributed availability group dag11") {
		t.Errorf("db11 in a distributed group: %v | %q", steps, verdict)
	}
	var f11 int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_restore_findings WHERE instance_id IN ($1, $2) AND object = 'db11'`, p11, s11).Scan(&f11); err != nil || f11 != 0 {
		t.Errorf("db11 raised %d findings (%v), want none", f11, err)
	}
}
