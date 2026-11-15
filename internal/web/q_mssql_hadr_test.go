package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestHADRFleetOnAStore (task 383): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) the HA/DR
// folder's three SQL Server pages answer from rows written the way the collectors store them, as DBA Dash 4.25.0's
// procedures count them. Expected (written before the first run):
//
//	AG summary  A (the primary of ag-<sfx>): Primary Replicas 1, Secondary 0, Readable 0, Sync Commit 1, Synchronized 1,
//	            Remote Not Synchronizing 1 (the DMV's text 'NOT SYNCHRONIZING', with a space), Sync Health NOT_HEALTHY,
//	            Synchronized Status ok, Max Estimated Data Loss 12 s (the remote row), Max Recovery -1 (None (Primary):
//	            the remote row's unknown is -2, the primary's -1 the larger). B (the secondary): Secondary Replicas 1,
//	            Readable 1, Not Synchronizing 1, Synchronized Status warninglow, Max Data Loss -2 (Unknown). P (a
//	            PostgreSQL instance) no row.
//	AG detail   A: two rows, the local one first; its Secondary Lag words 'None (Primary)'; Primary Connections ALL.
//	Role changes (A's folder read, both A and B in scope): XE 'Became Primary' on A (SECONDARY -> PRIMARY, Changed After
//	            the first change after its stable SECONDARY_NORMAL, Changed Before the PRIMARY_NORMAL event); the
//	            Snapshot row 40 s after it on A hidden (an XE row within 2 minutes); the Snapshot failover 10 minutes
//	            ago: 'Became Primary' on A and 'No Longer Primary' on B, both Failover Type Forced with the statement
//	            (B's row matched by its lower-cased old_primary); E, a third replica of the group with its own copy
//	            of that failover row, no row. B's failover 40 minutes ago, whose window holds only a FAILOVER DDL in
//	            phase 'rollback' (lower case): 'No Longer Primary', Failover Type and Reason empty (review 383u B1).
//	            The distributed group dag-<sfx> on A (its local replica the member group ag-<sfx>): XE 'Became
//	            Primary' from FORWARDER to GLOBAL_PRIMARY (review 383b S2). ag2-<sfx>, held by B and E only, failed
//	            over from B to E 20 minutes ago: in the folder read B 'No Longer Primary' and E 'Became Primary'; in
//	            A's own read (the other replicas' changes included) none of the two (review 383b S1). instances=0:
//	            no row. Health events (A): the DDL row present.
//	Mirroring   C: Principal 2, Synchronized 2, Witness Connected 1, status warning (mdb2 has no witness: DBA Dash's MIN
//	            rule, D7); D: Mirror 1, hidden 1, Synchronized 0. Detail: D's row 'shown on the principal ...', its
//	            partner found the other way round (C's row names SRVD) with partner state 4; C's mdb partner D.
//	            Role changes: 'Became Principal' on C for mdb; C's mdb2 'PRINCIPAL => PRINCIPAL (role sequence 3 => 5)'.
//	Log shipping C's detail (status all): ls_ok ok, ls_late warning (30 h > 1440 min), ls_msdb warning (msdb's own
//	            threshold 45 min; its age tier left to msdb), ls_crit critical (50 h > 2880 min; msdb's warning beside
//	            it: the worst counts), ls_stale na 'not read in 15 minutes', ls_none na 'no log restore yet', ls_new na
//	            'New Database', ls_new0 na 'New Database' (made an hour ago, its full restore only: New Database before
//	            'no log restore yet', DBA Dash's order - review 383a S1), ls_gone warning and missing (a stream pair);
//	            no row for ls_mirror, ls_simple or ls_test (a pair of one restore). Every critical / warning row
//	            equals the worst finding mssql_hadr_findings holds for that database, and no ok / na row has one.
//	            status=critical,warning gives the four only; status=none no row. Summary C: critical, Log Shipped DBs
//	            4, Warning 3, Critical 1, Missing 1, New 2, the age key's threshold in force (default 1440 / 2880).
func TestHADRFleetOnAStore(t *testing.T) {
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
	sfx := fmt.Sprint(time.Now().UnixNano() % 1000000000)
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
	}
	names := map[string]string{"A": "SRVA-" + sfx, "B": "SRVB-" + sfx, "C": "SRVC-" + sfx, "D": "SRVD-" + sfx, "E": "SRVE-" + sfx}
	ids := map[string]int{}
	defer func() { // registered first: a Fatal while the instances are made still removes the ones made
		var all []int
		for _, id := range ids {
			all = append(all, id)
		}
		for _, tb := range []string{"mssql_ag_events", "mssql_ag_sample", "mssql_mirroring_sample", "collection_dates"} {
			if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.`+tb+` WHERE instance_id = ANY ($1)`, all); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, all); err != nil {
			t.Error(err)
		}
	}()
	for _, k := range []string{"A", "B", "C", "D", "E", "P"} {
		engine, platform := "sqlserver", "sqlserver"
		if k == "P" {
			engine, platform = "postgres", "onprem"
		}
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '16.0', 160000, false, '{}'::text[], $3)`,
			"hadr383"+strings.ToLower(k)+"-"+sfx, platform, engine).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[k] = id
		// B has no mssql_instance row (its collection has not run): its role change must still match through its own
		// replica row's name (the root cause of part U's first run, 383gaps1: no row matched without it)
		if k != "P" && k != "B" {
			exec(`INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, server_name) VALUES ($1, now(), $2)`, id, names[k])
		}
	}
	A, B, C, D, E := ids["A"], ids["B"], ids["C"], ids["D"], ids["E"]
	G, ag := "G-"+sfx, "ag-"+sfx
	now := time.Now().UTC().Truncate(time.Second)
	for _, k := range []string{"A", "B", "C", "D", "E"} {
		for _, c := range []string{"mssql_ag", "mssql_mirroring", "mssql_logshipping"} {
			exec(`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, $2, now(), 'ok')
			      ON CONFLICT (instance_id, collection) DO UPDATE SET snapshot_at = excluded.snapshot_at, status = excluded.status`, ids[k], c)
		}
	}

	// ---- availability group: A the primary, B the secondary of ag-<sfx>
	rep := `INSERT INTO pgvigil.mssql_ag_state (instance_id, group_id, replica_server, snapshot_at, group_name, is_local, role, availability_mode,
	          secondary_connections, primary_connections) VALUES ($1, $2, $3, now(), $4, $5, $6, 'SYNCHRONOUS_COMMIT', $7, 'ALL')`
	exec(rep, A, G, names["A"], ag, true, "PRIMARY", "NO")
	exec(rep, A, G, names["B"], ag, false, "SECONDARY", "READ_ONLY")
	exec(rep, B, G, names["A"], ag, false, "PRIMARY", "NO")
	exec(rep, B, G, names["B"], ag, true, "SECONDARY", "READ_ONLY")
	exec(rep, E, G, names["E"], ag, true, "SECONDARY", "NO") // a third replica of the group
	G2, ag2 := "G2-"+sfx, "ag2-"+sfx
	exec(rep, B, G2, names["B"], ag2, true, "SECONDARY", "NO")
	exec(rep, E, G2, names["E"], ag2, true, "PRIMARY", "NO")
	DG, dag := "DG-"+sfx, "dag-"+sfx // the distributed group: A's local replica is the member group ag-<sfx>
	exec(`INSERT INTO pgvigil.mssql_ag_state (instance_id, group_id, replica_server, snapshot_at, group_name, is_local, is_distributed, role)
	      VALUES ($1, $2, $3, now(), $4, true, true, 'PRIMARY')`, A, DG, ag, dag)
	dbr := `INSERT INTO pgvigil.mssql_ag_database_state (instance_id, group_id, replica_server, database_name, snapshot_at, group_name, is_local,
	          is_primary_replica, synchronization_state, synchronization_health, is_suspended, redo_queue_kb, est_data_loss_s)
	        VALUES ($1, $2, $3, 'db1', now(), $4, $5, $6, $7, $8, false, $9, $10)`
	exec(dbr, A, G, names["A"], ag, true, true, "SYNCHRONIZED", "HEALTHY", nil, nil)
	exec(dbr, A, G, names["B"], ag, false, false, "NOT SYNCHRONIZING", "NOT_HEALTHY", 100, 12)
	exec(dbr, B, G, names["B"], ag, true, false, "NOT SYNCHRONIZING", "NOT_HEALTHY", 100, nil)
	// the reads before the failover, the failover 10 minutes ago seen by both, AlwaysOn_health's rows
	t10 := now.Add(-10 * time.Minute)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_ag_sample', $1)`, t10.Add(-time.Minute))
	exec(`INSERT INTO pgvigil.mssql_ag_sample (instance_id, snapshot_at, group_name, replica_server, database_name) VALUES ($1, $2, $3, $4, 'db1')`,
		A, t10.Add(-time.Minute), ag, names["A"])
	fo := `INSERT INTO pgvigil.mssql_ag_failovers (instance_id, group_id, at, group_name, old_primary, new_primary) VALUES ($1, $2, $3, $4, $5, $6)`
	exec(fo, A, G, t10, ag, names["B"], names["A"])
	exec(fo, B, G, t10, ag, strings.ToLower(names["B"]), names["A"]) // B matched through old_primary, in another case
	exec(fo, E, G, t10, ag, names["B"], names["A"])                  // E is neither: no row
	t20, t40 := now.Add(-20*time.Minute), now.Add(-40*time.Minute)
	exec(fo, B, G2, t20, ag2, names["B"], names["E"])
	exec(fo, E, G2, t20, ag2, names["B"], names["E"])
	exec(fo, B, G, t40, ag, names["B"], names["A"]) // its window holds only the rolled-back FAILOVER below
	t0 := now.Add(-2 * time.Hour)
	exec(fo, A, G, t0.Add(48*time.Second), ag, names["B"], names["A"]) // the snapshot twin of the XE row below: hidden
	ev := `INSERT INTO pgvigil.mssql_ag_events (instance_id, event_at, event_key, snapshot_at, event_name, ag_name, replica_name, previous_state,
	         current_state, ddl_action, ddl_phase, statement) VALUES ($1, $2, $3, now(), $4, $5, $6, $7, $8, $9, $10, $11)`
	tD := now.Add(-90 * time.Minute)
	for _, at := range []time.Time{t0.Add(-time.Hour), tD.Add(-time.Hour), t40.Add(-20 * time.Second), t10.Add(-30 * time.Second), now} {
		exec(`SELECT pgvigil.ensure_month_partition('mssql_ag_events', $1)`, at)
	}
	exec(ev, A, t0.Add(-time.Hour), "k0", "availability_replica_state_change", ag, names["A"], "RESOLVING_NORMAL", "SECONDARY_NORMAL", nil, nil, nil)
	exec(ev, A, t0, "k1", "availability_replica_state_change", ag, names["A"], "SECONDARY_NORMAL", "RESOLVING_NORMAL", nil, nil, nil)
	exec(ev, A, t0.Add(5*time.Second), "k2", "availability_replica_state_change", ag, names["A"], "RESOLVING_NORMAL", "PRIMARY_PENDING", nil, nil, nil)
	exec(ev, A, t0.Add(8*time.Second), "k3", "availability_replica_state_change", ag, names["A"], "PRIMARY_PENDING", "PRIMARY_NORMAL", nil, nil, nil)
	exec(ev, A, t10.Add(-30*time.Second), "k4", "alwayson_ddl_executed", ag, nil, nil, nil, "alter", "commit",
		"ALTER AVAILABILITY GROUP ["+ag+"] FORCE_FAILOVER_ALLOW_DATA_LOSS")
	exec(ev, B, t40.Add(-20*time.Second), "k5", "alwayson_ddl_executed", ag, nil, nil, nil, "alter", "rollback",
		"ALTER AVAILABILITY GROUP ["+ag+"] FAILOVER")
	exec(ev, A, tD.Add(-time.Hour), "d0", "availability_replica_state_change", dag, ag, "RESOLVING_NORMAL", "FORWARDER", nil, nil, nil)
	exec(ev, A, tD, "d1", "availability_replica_state_change", dag, ag, "FORWARDER", "RESOLVING_NORMAL", nil, nil, nil)
	exec(ev, A, tD.Add(6*time.Second), "d2", "availability_replica_state_change", dag, ag, "RESOLVING_NORMAL", "GLOBAL_PRIMARY", nil, nil, nil)

	// ---- mirroring: C the principal of mdb (D its mirror, read by a login that is not sysadmin) and of mdb2 (no witness)
	mir := `INSERT INTO pgvigil.mssql_mirroring_state (instance_id, database_name, snapshot_at, role, state, state_code, partner_instance,
	          witness, witness_state, values_hidden) VALUES ($1, $2, now(), $3, $4, $5, $6, $7, $8, $9)`
	exec(mir, C, "mdb", "PRINCIPAL", "SYNCHRONIZED", 4, names["D"], "TCP://w:5022", "CONNECTED", false)
	exec(mir, C, "mdb2", "PRINCIPAL", "SYNCHRONIZED", 4, "OTHER-"+sfx, nil, nil, false)
	exec(mir, D, "mdb", "MIRROR", nil, nil, nil, nil, nil, true)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_mirroring_sample', $1)`, now.Add(-6*time.Minute))
	exec(`INSERT INTO pgvigil.mssql_mirroring_sample (instance_id, snapshot_at, database_name, role) VALUES ($1, $2, 'mdb', 'MIRROR')`,
		C, now.Add(-6*time.Minute))
	exec(`INSERT INTO pgvigil.mssql_mirroring_role_changes (instance_id, database_name, at, old_role, new_role, old_sequence, new_sequence, partner)
	      VALUES ($1, 'mdb', $2, 'MIRROR', 'PRINCIPAL', 1, 2, $3)`, C, now.Add(-5*time.Minute), names["D"])
	exec(`INSERT INTO pgvigil.mssql_mirroring_role_changes (instance_id, database_name, at, old_role, new_role, old_sequence, new_sequence, partner)
	      VALUES ($1, 'mdb2', $2, 'PRINCIPAL', 'PRINCIPAL', 3, 5, $3)`, C, now.Add(-4*time.Minute), "OTHER-"+sfx)

	// ---- log shipping from restore history on C
	lrs := `INSERT INTO pgvigil.mssql_logrestore_state (instance_id, database_name, snapshot_at, kind, database_state, recovery_model,
	          created_at, is_mirrored, in_availability_group, last_log_restore_at, last_log_backup_start_at, source_server, source_database,
	          last_file, last_restore_at, last_restore_type, log_restores, last_with_recovery)
	        VALUES ($1, $2, $3, $4, 'RESTORING', $5, $6, $7, false, $8, $9, 'PRIM-` + sfx + `', $2, $2 || '.trn', $10, $11, $12, $13)`
	old := now.Add(-30 * 24 * time.Hour)
	ago := func(m int) time.Time { return now.Add(-time.Duration(m) * time.Minute) }
	exec(lrs, C, "ls_ok", now, "restore", "FULL", old, false, ago(10), ago(15), ago(10), "L", nil, nil)
	exec(lrs, C, "ls_late", now, "restore", "FULL", old, false, ago(1800), ago(1805), ago(1800), "L", nil, nil)
	exec(lrs, C, "ls_msdb", now, "restore", "FULL", old, false, ago(90), ago(95), ago(90), "L", nil, nil)
	exec(lrs, C, "ls_stale", ago(20), "restore", "FULL", old, false, ago(30), ago(35), ago(30), "L", nil, nil)
	exec(lrs, C, "ls_none", now, "restore", "FULL", old, false, nil, nil, ago(60), "D", nil, nil)
	exec(lrs, C, "ls_new", now, "restore", "FULL", ago(60), false, ago(5), ago(8), ago(5), "L", nil, nil)
	exec(lrs, C, "ls_new0", now, "restore", "FULL", ago(60), false, nil, nil, ago(60), "D", nil, nil)
	exec(lrs, C, "ls_crit", now, "restore", "FULL", old, false, ago(3000), ago(3005), ago(3000), "L", nil, nil)
	exec(lrs, C, "ls_mirror", now, "restore", "FULL", old, true, ago(5), ago(8), ago(5), "L", nil, nil)
	exec(lrs, C, "ls_simple", now, "restore", "SIMPLE", old, false, ago(5), ago(8), ago(5), "L", nil, nil)
	exec(lrs, C, "ls_gone", now, "pair", nil, nil, nil, ago(60), ago(65), ago(60), "L", 3, false)
	exec(lrs, C, "ls_test", now, "pair", nil, nil, nil, ago(60), ago(65), ago(60), "L", 1, true)
	exec(`INSERT INTO pgvigil.mssql_logshipping_state (instance_id, role, database_name, snapshot_at, primary_server, primary_database, secondary_server,
	        threshold_minutes, last_restored_at) VALUES ($1, 'secondary', 'ls_msdb', now(), $2, 'ls_msdb', '', 45, $3)`, C, "PRIM-"+sfx, ago(90))
	exec(`INSERT INTO pgvigil.mssql_logshipping_state (instance_id, role, database_name, snapshot_at, primary_server, primary_database, secondary_server,
	        threshold_minutes, last_restored_at) VALUES ($1, 'secondary', 'ls_crit', now(), $2, 'ls_crit', '', 45, $3)`, C, "PRIM-"+sfx, ago(3000))

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(q string) map[string]*table {
		t.Helper()
		rec := httptest.NewRecorder()
		s.MSSQLHADRFleet(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/hadr/fleet?"+q, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q, rec.Code, rec.Body.String())
		}
		out := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return out
	}
	rowsOf := func(tb *table) []map[string]any {
		var out []map[string]any
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			out = append(out, m)
		}
		return out
	}
	num := func(v any) float64 {
		switch x := v.(type) {
		case float64:
			return x
		case string:
			var f float64
			fmt.Sscan(x, &f)
			return f
		}
		return -999
	}
	want := func(what string, got, exp any) {
		t.Helper()
		if fmt.Sprint(got) != fmt.Sprint(exp) {
			t.Errorf("%s = %v, want %v", what, got, exp)
		}
	}
	scope := fmt.Sprintf("instances=%d,%d,%d,%d,%d,%d", A, B, C, D, E, ids["P"])
	if z := call("page=ag&instances=0"); z["summary"] != nil && len(z["summary"].Rows) != 0 {
		t.Errorf("instances=0: %d summary rows, want none", len(z["summary"].Rows))
	}

	// ---- AG summary and detail
	d := call("page=ag&" + scope)
	byInst := map[string]map[string]any{}
	for _, r := range rowsOf(d["summary"]) {
		byInst[fmt.Sprint(r["instance_id"])] = r
	}
	if _, ok := byInst[fmt.Sprint(ids["P"])]; ok {
		t.Error("a PostgreSQL instance has an AG summary row")
	}
	a, b := byInst[fmt.Sprint(A)], byInst[fmt.Sprint(B)]
	if a == nil || b == nil {
		t.Fatalf("AG summary rows: %v", d["summary"])
	}
	for k, v := range map[string]float64{"primary_replicas": 1, "secondary_replicas": 0, "readable_secondaries": 0, "sync_commit": 1,
		"synchronized": 1, "remote_not_synchronizing": 1, "max_data_loss_s": 12, "max_recovery_s": -1} {
		want("A "+k, num(a[k]), v)
	}
	want("A sync_health", a["sync_health"], "NOT_HEALTHY")
	want("A synchronized_status", a["synchronized_status"], "ok")
	for k, v := range map[string]float64{"secondary_replicas": 1, "readable_secondaries": 1, "not_synchronizing": 1, "max_data_loss_s": -2} {
		want("B "+k, num(b[k]), v)
	}
	want("B synchronized_status", b["synchronized_status"], "warninglow")

	det := rowsOf(call(fmt.Sprintf("page=ag&instance=%d", A))["detail"])
	if len(det) != 2 {
		t.Fatalf("A detail rows = %d, want 2", len(det))
	}
	want("A detail first is_local", det[0]["is_local"], true)
	want("A detail lag words", det[0]["secondary_lag_words"], "None (Primary)")
	want("A detail primary connections", det[0]["primary_connections"], "ALL")

	// ---- role changes: the folder read (A and B in scope)
	rcLines := func(tb *table) string {
		var out []string
		for _, r := range rowsOf(tb) {
			out = append(out, fmt.Sprintf("%v|%v|%v|%v|%v|%v", r["instance_id"], r["group_name"], r["change"], r["source"], r["failover_type"], r["reason"]))
		}
		sort.Strings(out)
		return strings.Join(out, "\n")
	}
	forced := "Forced|ALTER AVAILABILITY GROUP [" + ag + "] FORCE_FAILOVER_ALLOW_DATA_LOSS"
	ownRC := []string{
		fmt.Sprintf("%d|%s|Became Primary|Snapshot|%s", A, ag, forced),
		fmt.Sprintf("%d|%s|Became Primary|XE|<nil>|<nil>", A, ag),
		fmt.Sprintf("%d|%s|Became Primary|XE|<nil>|<nil>", A, dag),
		fmt.Sprintf("%d|%s|No Longer Primary|Snapshot|%s", B, ag, forced),
		fmt.Sprintf("%d|%s|No Longer Primary|Snapshot|<nil>|<nil>", B, ag),
	}
	wantRC := append(append([]string{}, ownRC...), fmt.Sprintf("%d|%s|No Longer Primary|Snapshot|<nil>|<nil>", B, ag2),
		fmt.Sprintf("%d|%s|Became Primary|Snapshot|<nil>|<nil>", E, ag2))
	sort.Strings(wantRC)
	want("role changes (the folder)", rcLines(d["role_changes"]), strings.Join(wantRC, "\n"))
	// A's own read: its changes and the other replicas' changes of the groups A holds (ag, dag), never ag2's
	sort.Strings(ownRC)
	want("role changes (A, others included)", rcLines(call(fmt.Sprintf("page=ag&instance=%d&part=role_changes", A))["role_changes"]), strings.Join(ownRC, "\n"))
	for _, r := range rowsOf(d["role_changes"]) {
		if r["source"] == "XE" && r["group_name"] == ag {
			at := func(v any) time.Time { x, _ := time.Parse(time.RFC3339Nano, fmt.Sprint(v)); return x }
			want("XE changed_after", at(r["changed_after"]).Equal(t0), true)
			want("XE changed_before", at(r["changed_before"]).Equal(t0.Add(8*time.Second)), true)
			want("XE previous_role", r["previous_role"], "SECONDARY")
		}
	}
	he := rowsOf(call(fmt.Sprintf("page=ag&instance=%d&part=health_events", A))["health_events"])
	found := false
	for _, r := range he {
		if r["event_name"] == "alwayson_ddl_executed" {
			found = true
		}
	}
	want("A health events hold the DDL", found, true)

	// ---- mirroring
	m := call("page=mirroring&" + scope)
	ms := map[string]map[string]any{}
	for _, r := range rowsOf(m["summary"]) {
		ms[fmt.Sprint(r["instance_id"])] = r
	}
	c, dd := ms[fmt.Sprint(C)], ms[fmt.Sprint(D)]
	if c == nil || dd == nil {
		t.Fatalf("mirroring summary: %v", m["summary"])
	}
	for k, v := range map[string]float64{"principal_count": 2, "synchronized_count": 2, "witness_connected_count": 1} {
		want("C "+k, num(c[k]), v)
	}
	want("C mirroring_status", c["mirroring_status"], "warning")
	for k, v := range map[string]float64{"mirror_count": 1, "hidden_count": 1, "synchronized_count": 0} {
		want("D "+k, num(dd[k]), v)
	}
	for _, r := range rowsOf(m["detail"]) {
		if num(r["instance_id"]) == float64(D) {
			want("D state desc", r["mirroring_state_desc"], "shown on the principal (this login is not sysadmin)")
			want("D partner state", num(r["partner_mirroring_state"]), 4)
			want("D partner instance", r["mirroring_partner_instance"], names["C"])
		}
		if num(r["instance_id"]) == float64(C) && r["database_name"] == "mdb" {
			want("C mdb partner monitored as", r["partner_monitored_as"], "hadr383d-"+sfx)
		}
	}
	var mch []string
	for _, r := range rowsOf(m["role_changes"]) {
		mch = append(mch, fmt.Sprintf("%v|%v", r["database_name"], r["change"]))
	}
	sort.Strings(mch)
	want("mirroring changes", strings.Join(mch, ";"), "mdb2|PRINCIPAL => PRINCIPAL (role sequence 3 => 5);mdb|Became Principal")

	// ---- log shipping: the page's status against the findings view
	ls := call(fmt.Sprintf("page=logshipping&instance=%d", C))
	got := map[string]string{}
	for _, r := range rowsOf(ls["detail"]) {
		got[fmt.Sprint(r["database_name"])] = fmt.Sprintf("%v|%v|%v", r["status"], r["excluded_by"], r["is_missing"])
	}
	wantLS := map[string]string{
		"ls_ok": "ok|<nil>|false", "ls_late": "warning|<nil>|false", "ls_msdb": "warning|<nil>|false",
		"ls_stale": "na|not read in 15 minutes|false", "ls_none": "na|no log restore yet|false", "ls_new": "na|New Database|false",
		"ls_new0": "na|New Database|false", "ls_crit": "critical|<nil>|false", "ls_gone": "warning|<nil>|true",
	}
	want("log shipping detail", fmt.Sprint(got), fmt.Sprint(wantLS))
	frs, err := pool.Query(ctx, `SELECT object, severity FROM pgvigil.mssql_hadr_findings WHERE instance_id = $1
	    AND check_name IN ('log shipping is behind its threshold', 'log restores are behind', 'a database has been restoring for days',
	                       'a log shipping copy is missing')`, C)
	if err != nil {
		t.Fatal(err)
	}
	worst := map[string]string{}
	for frs.Next() {
		var obj, sev string
		if err := frs.Scan(&obj, &sev); err != nil {
			t.Fatal(err)
		}
		db := obj
		if i := strings.Index(db, " (from "); i >= 0 {
			db = db[:i]
		}
		db = strings.TrimPrefix(db, "secondary / ")
		if i := strings.Index(db, " on "); i >= 0 {
			db = db[:i]
		}
		if worst[db] != "critical" {
			worst[db] = sev
		}
	}
	frs.Close()
	for db, v := range got {
		st := strings.SplitN(v, "|", 2)[0]
		if (st == "critical" || st == "warning") != (worst[db] != "") || ((st == "critical" || st == "warning") && st != worst[db]) {
			t.Errorf("%s: page %s, findings %q", db, st, worst[db])
		}
	}
	for db := range worst {
		if _, ok := got[db]; !ok {
			t.Errorf("%s: a finding (%s) and no row on the page", db, worst[db])
		}
	}
	cw := rowsOf(call(fmt.Sprintf("page=logshipping&instance=%d&status=critical,warning&part=detail", C))["detail"])
	want("critical,warning rows", len(cw), 4)
	nr := call(fmt.Sprintf("page=logshipping&instance=%d&status=none&part=detail", C))["detail"]
	want("status=none rows", nr != nil && len(nr.Rows) > 0, false)
	sum := rowsOf(ls["summary"])
	if len(sum) != 1 {
		t.Fatalf("log shipping summary = %v", ls["summary"])
	}
	want("summary status", sum[0]["status"], "critical")
	for k, v := range map[string]float64{"log_shipped_dbs": 4, "warning_count": 3, "critical_count": 1, "missing_count": 1, "new_database_count": 2,
		"age_warn": 1440, "age_crit": 2880} {
		want("summary "+k, num(sum[0][k]), v)
	}
	want("summary age_level", sum[0]["age_level"], "default")
}

// TestHADRFleetProof is driven by scripts/proof-mssql-hadr.sh part U (the real two-node group of part S):
// PGVIGIL_HADR_FLEET_DSN its repository, PGVIGIL_HADR_FLEET_INSTANCES the nodes' instance ids; skipped without them. It
// prints what the AG page answers - one 'FLEET' line per instance (the summary's counts) and one 'RC' line per role
// change - and the script grades them against sa's own reads.
func TestHADRFleetProof(t *testing.T) {
	dsn, inst := os.Getenv("PGVIGIL_HADR_FLEET_DSN"), os.Getenv("PGVIGIL_HADR_FLEET_INSTANCES")
	if dsn == "" || inst == "" {
		t.Skip("PGVIGIL_HADR_FLEET_DSN / _INSTANCES not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	rec := httptest.NewRecorder()
	s.MSSQLHADRFleet(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/hadr/fleet?page=ag&instances="+inst, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	out := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	keys := []string{"primary_replicas", "secondary_replicas", "not_synchronizing", "synchronizing", "synchronized", "reverting", "initializing",
		"remote_not_synchronizing", "remote_synchronizing", "remote_synchronized", "remote_reverting", "remote_initializing"}
	for _, r := range out["summary"].Rows {
		m := map[string]any{}
		for i, c := range out["summary"].Columns {
			m[c] = r[i]
		}
		line := fmt.Sprintf("FLEET %v", m["instance_id"])
		for _, k := range keys {
			line += fmt.Sprintf(" %s=%v", k, m[k])
		}
		fmt.Println(line)
	}
	for _, r := range out["role_changes"].Rows {
		m := map[string]any{}
		for i, c := range out["role_changes"].Columns {
			m[c] = r[i]
		}
		fmt.Printf("RC %v|%v|%v|%v|%v|%v\n", m["instance_id"], m["group_name"], m["change"], m["source"], m["failover_type"], m["reason"])
	}
}
