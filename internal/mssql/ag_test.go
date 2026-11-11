package mssql

import (
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// A distributed group has no database row for its primary side: the estimate of the link's data loss takes the
// primary's last commit from the database's own row in the local member group, and only there. The expression and
// the join are pinned whole: a column swapped inside the expression, or a condition added to the join (which would
// reach a plain group's rows), is a change of this text.
func TestAgDatabaseSQLDistributedLink(t *testing.T) {
	q := agDatabaseSQL
	const estimate = `  CASE WHEN drs.is_primary_replica = 1 OR COALESCE(p.last_commit_time, own.last_commit_time) IS NULL OR drs.last_commit_time IS NULL THEN NULL
       WHEN drs.last_commit_time >= COALESCE(p.last_commit_time, own.last_commit_time) THEN 0
       WHEN DATEDIFF(day, drs.last_commit_time, COALESCE(p.last_commit_time, own.last_commit_time)) > 20000 THEN NULL
       ELSE DATEDIFF(second, drs.last_commit_time, COALESCE(p.last_commit_time, own.last_commit_time)) END AS est_data_loss_s,
`
	const joins = `LEFT JOIN sys.dm_hadr_database_replica_states p
       ON p.group_id = drs.group_id AND p.group_database_id = drs.group_database_id AND p.is_primary_replica = 1
LEFT JOIN sys.dm_hadr_database_replica_states own
       ON ag.is_distributed = 1 AND drs.is_local = 0 AND own.database_id = drs.database_id
      AND own.group_id <> drs.group_id AND own.is_local = 1 AND own.is_primary_replica = 1
ORDER BY ag.name, ar.replica_server_name, 5`
	if !strings.Contains(q, estimate) {
		t.Errorf("the estimate of the data loss is not the pinned expression:\n%s", estimate)
	}
	if !strings.HasSuffix(q, joins) {
		t.Errorf("the statement does not end with the pinned joins (p inside the group, own for a distributed group's other side only):\n%s", joins)
	}
	// own is read for its commit time alone: a queue or a state taken from it would be the member group's, not the link's
	if n := strings.Count(q, "own."); n != 8 {
		t.Errorf("own is named %d times; want 8 (its four join columns and the four reads of its last commit time)", n)
	}
	// every read of the primary's commit time goes through the stand-in: none is left bare
	if bare := strings.Count(q, "p.last_commit_time") - strings.Count(q, "COALESCE(p.last_commit_time, own.last_commit_time)"); bare != 0 {
		t.Errorf("%d read(s) of p.last_commit_time outside the stand-in", bare)
	}
}

// groupRows picks a group's rows of one kind out of a collector's payload.
func groupRows(rows []collect.Row, kind, group string) []collect.Row {
	var out []collect.Row
	for _, r := range rows {
		if r["kind"] == kind && r["group_name"] == group {
			out = append(out, r)
		}
	}
	return out
}

func isOne(v any) bool { n, ok := number(v); return ok && n == 1 }

// The collector against a node of a distributed availability group (nothing is written). PGVIGIL_MSSQL_TEST_DSN is
// the node, PGVIGIL_MSSQL_TEST_DAG is "<distributed group>:<side>" with the side the node has in it:
//
//	global     the primary of the member group that is the distributed group's PRIMARY
//	forwarder  the primary of the member group that is its SECONDARY
//	secondary  a secondary of either member group
//
// scripts/proof-mssql-dag.sh runs it on all four nodes of its lab as the monitoring login.
func TestAgDistributedLive(t *testing.T) {
	spec := os.Getenv("PGVIGIL_MSSQL_TEST_DAG")
	if spec == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_DAG is not set")
	}
	dag, side, ok := strings.Cut(spec, ":")
	if !ok || dag == "" || (side != "global" && side != "forwarder" && side != "secondary") {
		t.Fatalf("PGVIGIL_MSSQL_TEST_DAG = %q; want <distributed group>:<global|forwarder|secondary>", spec)
	}
	ctx, conn, info := liveConn(t)
	if okay, why := (agCollector{}).Applies(info); !okay {
		t.Fatalf("mssql_ag does not apply to this login: %s", why)
	}
	rows, err := agCollector{}.Run(ctx, conn, info)
	if err != nil {
		t.Fatal(err)
	}
	reps, dbs := groupRows(rows, "replica", dag), groupRows(rows, "database", dag)
	t.Logf("%s as the %s node reads it: %d member group row(s), %d database row(s)", dag, side, len(reps), len(dbs))

	// no database row twice (a join that multiplies rows is collapsed by the import, so it is caught here), and the
	// plain groups' rows as before the distributed group's stand-in: a primary's own row carries no estimate, a
	// secondary's own row none either (it cannot know), a secondary's row on its primary one of 0 or more
	seen, plain := map[string]bool{}, 0
	for _, d := range rows {
		if d["kind"] != "database" {
			continue
		}
		key := fmt.Sprint(d["group_id"], "|", d["replica_server"], "|", d["database_name"])
		if seen[key] {
			t.Errorf("the database row %s is read twice", key)
		}
		seen[key] = true
		if d["group_name"] == dag {
			continue
		}
		plain++
		loss, has := number(d["est_data_loss_s"])
		switch {
		case isOne(d["is_primary_replica"]) || isOne(d["is_local"]):
			if has {
				t.Errorf("plain group row %s (primary %v, local %v) carries an estimated data loss of %v; want none", key, d["is_primary_replica"], d["is_local"], loss)
			}
		case d["last_commit_utc"] != nil:
			if !has || loss < 0 {
				t.Errorf("plain group row %s, a secondary as its primary reads it, has no estimated data loss: %v", key, d["est_data_loss_s"])
			}
		}
	}
	if plain == 0 {
		t.Errorf("no database row of a plain group was read on the %s node (each lab node carries one member group with a database)", side)
	}

	if side == "secondary" {
		// a secondary's catalog names the distributed group, with no replica of it: nothing is read, nothing is stored
		if len(reps) != 0 || len(dbs) != 0 {
			t.Fatalf("a secondary of a member group reads %d member row(s) and %d database row(s) of %s; want none", len(reps), len(dbs), dag)
		}
		return
	}
	if len(reps) != 2 {
		t.Fatalf("%d member group rows of %s; want 2: %v", len(reps), dag, reps)
	}
	var local, other collect.Row
	for _, r := range reps {
		if !isOne(r["is_distributed"]) {
			t.Errorf("member %v of %s is not marked distributed: is_distributed = %v", r["replica_server"], dag, r["is_distributed"])
		}
		if isOne(r["is_local"]) {
			local = r
		} else {
			other = r
		}
	}
	if local == nil || other == nil {
		t.Fatalf("want one local member group and one other: %v", reps)
	}
	wantLocal, wantPrimary := "PRIMARY", local["replica_server"]
	if side == "forwarder" {
		wantLocal, wantPrimary = "SECONDARY", other["replica_server"]
	}
	if local["role"] != wantLocal {
		t.Errorf("the local member group %v has role %v; want %s", local["replica_server"], local["role"], wantLocal)
	}
	if local["primary_replica"] != wantPrimary {
		t.Errorf("%s names %v as its primary; want the member group %v", dag, local["primary_replica"], wantPrimary)
	}
	if side == "forwarder" {
		// the forwarder does not see the global primary's state, and has no database row of the link
		if other["role"] != nil || other["connected_state"] != nil {
			t.Errorf("the forwarder reads a state of the other member group: role %v, connected %v", other["role"], other["connected_state"])
		}
		if len(dbs) != 0 {
			t.Errorf("the forwarder reads %d database row(s) of %s; want none (the link's rows are the global primary's)", len(dbs), dag)
		}
		return
	}
	if other["role"] != "SECONDARY" || other["connected_state"] == nil || other["synchronization_health"] == nil {
		t.Errorf("the other member group as the global primary sees it: role %v, connected %v, health %v", other["role"], other["connected_state"], other["synchronization_health"])
	}
	if len(dbs) == 0 {
		t.Fatalf("the global primary reads no database row of %s", dag)
	}
	for _, d := range dbs {
		name := d["database_name"]
		if d["replica_server"] != other["replica_server"] || isOne(d["is_local"]) || isOne(d["is_primary_replica"]) {
			t.Errorf("database %v: the link's row is the other member group's (%v), not local, not a primary: replica %v, is_local %v, is_primary_replica %v",
				name, other["replica_server"], d["replica_server"], d["is_local"], d["is_primary_replica"])
		}
		if name == nil || name == "" {
			t.Errorf("a database row of %s has no name: %v", dag, d)
		}
		if _, ok := number(d["redo_queue_kb"]); !ok {
			t.Errorf("database %v: no redo queue of the link: %v", name, d["redo_queue_kb"])
		}
		if d["last_commit_utc"] != nil {
			if loss, ok := number(d["est_data_loss_s"]); !ok || loss < 0 {
				t.Errorf("database %v: the link's data loss is not estimated (est_data_loss_s = %v with a last commit of %v)", name, d["est_data_loss_s"], d["last_commit_utc"])
			}
		}
	}
	// the estimate against the views' own times, read again right after: the local primary's last commit less the
	// link row's, never below 0. The two reads are moments apart, so a few seconds of difference are allowed.
	gaps, err := QueryRows(ctx, conn, `SELECT CAST(DB_NAME(l.database_id) AS nvarchar(128)) AS database_name,
  DATEDIFF(second, l.last_commit_time, o.last_commit_time) AS gap_s
FROM sys.dm_hadr_database_replica_states l
JOIN sys.availability_groups g ON g.group_id = l.group_id AND g.is_distributed = 1 AND g.name = @p1
JOIN sys.dm_hadr_database_replica_states o ON o.database_id = l.database_id AND o.is_local = 1 AND o.is_primary_replica = 1 AND o.group_id <> l.group_id
WHERE l.is_local = 0`, dag)
	if err != nil {
		t.Fatal(err)
	}
	if len(gaps) != len(dbs) {
		t.Errorf("%d link row(s) read by the collector, %d by the check's own statement", len(dbs), len(gaps))
	}
	for _, g := range gaps {
		want, ok := number(g["gap_s"])
		if !ok {
			continue // a side without a commit time: the collector stores no estimate either
		}
		if want < 0 {
			want = 0
		}
		for _, d := range dbs {
			if d["database_name"] != g["database_name"] {
				continue
			}
			got, _ := number(d["est_data_loss_s"])
			t.Logf("database %v: estimated data loss %v s; the views' own times give %v s", d["database_name"], got, want)
			if got < want-3 || got > want+3 {
				t.Errorf("database %v: estimated data loss %v s, but the local primary's last commit less the link's is %v s", d["database_name"], got, want)
			}
		}
	}
}
