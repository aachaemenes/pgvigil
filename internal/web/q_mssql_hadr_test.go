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
			_, _ = fmt.Sscan(x, &f)
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

// TestLogShipExtrasOnAStore (task LSX): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it) the
// log shipping extras are judged from payloads imported the way the collector hands them over
// (pgvigil.import_mssql_logshipping: 'lsconfig' and 'lsforeign' rows beside msdb's monitor rows). Expected (written
// before the first run):
//
//	P (a primary), 11 findings: lsx_simple critical 'a log-shipped database is in SIMPLE recovery' (Microsoft's
//	  sentence in the detail); lsx_bulk warning '... in BULK_LOGGED recovery' (Microsoft's two sentences of that
//	  model); 'the log shipping alert is off' info ONCE for lsx_alertoff and lsx_alertoff2 ('primary: 2 databases',
//	  both named, the first one's words); lsx_tight info 'a log shipping alert threshold is under three times its job
//	  interval' (threshold 30, the backup job every 15 minutes; Microsoft's 14420 words); lsx_nojob critical 'a log
//	  shipping job is missing' naming the job's id; lsx_disabled and lsx_nosched (enabled, no enabled schedule)
//	  critical 'a log shipping job is disabled'; four critical 'a log backup outside log shipping broke the chain':
//	  lsx_foreign - ONE finding for its two files, naming the newest, '2 log backups', 'stays for 24 hours', and
//	  'probably the job DatabaseBackup - USER_DATABASES - LOG: its run covers that backup' (never the job that ended
//	  before the backup did, never log shipping's own backup job whose run covers it too); lsx_foreign2 (a backup to
//	  NUL, no run at its time) 'not known (no job run'; lsx_foreign3 (a virtual device, a run covering it) 'not
//	  known: it went to a virtual device'; lsx_foreign4 (two runs covering it) 'probably one of the jobs Job A; Job
//	  B: their runs cover that backup'. Nothing for lsx_ok (threshold 60 = 4 x 15) or lsx_hours (no interval).
//	S (a secondary), 5 findings: lsx_s_restoreoff critical 'a log shipping job is disabled' naming
//	  LSRestore_PRI_lsx_s_restoreoff with 'Its last run succeeded' (mssql_jobs, read now); lsx_s_copygone critical 'a
//	  log shipping job is missing' (the copy job's id); the monitor's alert job LSAlert_SEC disabled = warning;
//	  lsx_s_alertoff info; lsx_s_tight info (restore threshold 2, the restore job every minute; 14421's words).
//	  The judge keeps lsx_s_alertoff's own row (an info finding never turns a database's Status to N/A): one info
//	  row and one judged-OK row; lsx_s_restoreoff has its critical row and no OK row. THE PAGE (page=logshipping at
//	  S): lsx_s_restoreoff Status critical with the job check as its finding; lsx_s_alertoff Status ok with 'the log
//	  shipping alert is off' as its finding; the Summary critical 1, Log Shipped DBs 2.
//	T (read 20 minutes ago: a disabled job, SIMPLE, the alert off, a threshold under three intervals, a foreign
//	  backup): no finding.
//	R (a role change done Microsoft's way): lsx_r_swapped - its backup job disabled while the same server holds the
//	  database as a secondary with copy and restore enabled and scheduled: NO finding; lsx_r_half - the backup job
//	  disabled and the other role's restore job disabled too: both critical; lsx_r_gone - the backup job MISSING
//	  with the other role sound: 'missing' stays critical. 3 findings.
//	M (a secondary that is also the monitor: its table lists lsx_m on this server, threshold 100, and on another
//	  server, threshold 45; its own restore job runs every 60 minutes): with no mssql_instance row neither is judged
//	  (two rows share the name and none can be told as this server's); with one naming this server: one info, for
//	  this server's row (100 under 180) - never the other server's 45 against this server's job.
//	U (read 20 minutes ago with a disabled job; read now with the configuration part failed and the alert off): the
//	  kept configuration row is too old to judge: only the alert's info.
//	A later read of S whose configuration part failed (a collector_error with source 'log shipping
//	  configuration') keeps S's 11 configuration rows and its 5 findings; a later read of P whose foreign part failed
//	  keeps its 5 foreign rows and four chain findings; a later clean read of P with no configuration or foreign
//	  rows clears both tables for P: only lsx_alertoff's info is left (msdb's monitor row; one database: its own object).
func TestLogShipExtrasOnAStore(t *testing.T) {
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
	ids := map[string]int{}
	defer func() {
		var all []int
		for _, id := range ids {
			all = append(all, id)
		}
		for _, tb := range []string{"mssql_job_runs", "mssql_logrestore_sample", "collection_dates"} {
			if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.`+tb+` WHERE instance_id = ANY ($1)`, all); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, all); err != nil {
			t.Error(err)
		}
	}()
	for _, k := range []string{"P", "S", "T", "R", "M", "U"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			"lsx"+strings.ToLower(k)+"-"+sfx).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[k] = id
	}
	P, S, T, R, M, U := ids["P"], ids["S"], ids["T"], ids["R"], ids["M"], ids["U"]
	now := time.Now().UTC().Truncate(time.Second)
	z := func(m int) string { return now.Add(-time.Duration(m) * time.Minute).Format("2006-01-02T15:04:05Z") }
	imp := func(id int, at time.Time, rows []map[string]any) {
		t.Helper()
		b, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		exec(`SELECT pgvigil.import_mssql_logshipping($1, $2, $3::jsonb)`, id, at, string(b))
	}
	pri, sec := "PRI-"+sfx, "SEC-"+sfx

	// ---- P: the primary
	monPrimary := func(db string, threshold, alert int) map[string]any {
		return map[string]any{"kind": "primary", "primary_server": pri, "database_name": db, "threshold_minutes": threshold,
			"alert_enabled": alert, "last_backup_file": db + ".trn", "last_backup_utc": z(5)}
	}
	cfgPrimary := func(db, recovery string, exists, enabled, schedules any, interval any) map[string]any {
		r := map[string]any{"kind": "lsconfig", "role": "primary", "database_name": db, "recovery_model": recovery,
			"backup_directory": `C:\LS\` + db, "backup_share": `\\` + pri + `\LS\` + db, "job_role": "backup", "job_id": "JOB-" + db,
			"job_exists": exists, "job_enabled": enabled, "enabled_schedules": schedules, "interval_min": interval}
		if exists == 1 {
			r["job_name"] = "LSBackup_" + db
		}
		return r
	}
	pRows := []map[string]any{
		monPrimary("lsx_ok", 60, 1), cfgPrimary("lsx_ok", "FULL", 1, 1, 1, 15.0),
		monPrimary("lsx_simple", 60, 1), cfgPrimary("lsx_simple", "SIMPLE", 1, 1, 1, 15.0),
		monPrimary("lsx_bulk", 60, 1), cfgPrimary("lsx_bulk", "BULK_LOGGED", 1, 1, 1, 15.0),
		monPrimary("lsx_alertoff", 60, 0), cfgPrimary("lsx_alertoff", "FULL", 1, 1, 1, 15.0),
		monPrimary("lsx_alertoff2", 60, 0), cfgPrimary("lsx_alertoff2", "FULL", 1, 1, 1, 15.0),
		monPrimary("lsx_tight", 30, 1), cfgPrimary("lsx_tight", "FULL", 1, 1, 1, 15.0),
		monPrimary("lsx_nojob", 60, 1), cfgPrimary("lsx_nojob", "FULL", 0, nil, 0, nil),
		monPrimary("lsx_disabled", 60, 1), cfgPrimary("lsx_disabled", "FULL", 1, 0, 1, 15.0),
		monPrimary("lsx_nosched", 60, 1), cfgPrimary("lsx_nosched", "FULL", 1, 1, 0, nil),
		monPrimary("lsx_hours", 5, 1), cfgPrimary("lsx_hours", "FULL", 1, 1, 1, nil),
		monPrimary("lsx_foreign", 60, 1), cfgPrimary("lsx_foreign", "FULL", 1, 1, 1, 15.0),
		monPrimary("lsx_foreign2", 60, 1), cfgPrimary("lsx_foreign2", "FULL", 1, 1, 1, 15.0),
		{"kind": "lsforeign", "database_name": "lsx_foreign", "file_name": `D:\Backup\lsx_foreign_1.trn`, "device": "disk",
			"started_utc": z(121), "finished_utc": z(120), "backup_directory": `C:\LS\lsx_foreign`},
		{"kind": "lsforeign", "database_name": "lsx_foreign", "file_name": `D:\Backup\lsx_foreign_2.trn`, "device": "disk",
			"started_utc": z(31), "finished_utc": z(30), "backup_directory": `C:\LS\lsx_foreign`},
		{"kind": "lsforeign", "database_name": "lsx_foreign2", "file_name": "NUL", "device": "disk",
			"started_utc": z(200), "finished_utc": z(200), "backup_directory": `C:\LS\lsx_foreign2`},
		monPrimary("lsx_foreign3", 60, 1), cfgPrimary("lsx_foreign3", "FULL", 1, 1, 1, 15.0),
		{"kind": "lsforeign", "database_name": "lsx_foreign3", "file_name": "{6F9619FF-8B86-D011-B42D-00C04FC964FF}", "device": "virtual device",
			"started_utc": z(91), "finished_utc": z(90), "backup_directory": `C:\LS\lsx_foreign3`},
		monPrimary("lsx_foreign4", 60, 1), cfgPrimary("lsx_foreign4", "FULL", 1, 1, 1, 15.0),
		{"kind": "lsforeign", "database_name": "lsx_foreign4", "file_name": `D:\Backup\lsx_foreign4.trn`, "device": "disk",
			"started_utc": z(61), "finished_utc": z(60), "backup_directory": `C:\LS\lsx_foreign4`},
	}
	imp(P, now, pRows)
	// job runs (step 0: the run's start and its length). A run is named only when it covers the backup from its start
	// to its finish: lsx_foreign's newest backup ran from 31:00 to 30:00 ago
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', $1)`, now.Add(-2*time.Hour))
	exec(`SELECT pgvigil.ensure_month_partition('mssql_job_runs', $1)`, now)
	run := func(startAgo time.Duration, secs int, hist int, jobID, name string) {
		t.Helper()
		exec(`INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, run_status, duration_s)
		      VALUES ($1, $2, $3, $4, $5, 0, 1, $6)`, P, now.Add(-startAgo), hist, jobID, name, secs)
	}
	run(31*time.Minute+20*time.Second, 90, 1, "JOB-OLA", "DatabaseBackup - USER_DATABASES - LOG") // 31:20 to 29:50 ago: covers it
	run(31*time.Minute+20*time.Second, 90, 2, "JOB-lsx_foreign", "LSBackup_lsx_foreign")          // log shipping's own job: never named
	run(31*time.Minute+5*time.Second, 10, 3, "JOB-SHORT", "Short job")                            // ended 55 s before the backup did
	run(91*time.Minute+20*time.Second, 90, 4, "JOB-V", "Tool wrapper job")                        // covers lsx_foreign3's: a virtual device, no guess
	run(61*time.Minute+20*time.Second, 90, 5, "JOB-A", "Job A")                                   // two runs cover lsx_foreign4's
	run(61*time.Minute+10*time.Second, 90, 6, "JOB-B", "Job B")

	// ---- S: the secondary (and the monitor's alert job)
	monSecondary := func(db string, threshold, alert int) map[string]any {
		return map[string]any{"kind": "secondary", "secondary_server": sec, "database_name": db, "primary_server": pri,
			"primary_database": db, "threshold_minutes": threshold, "alert_enabled": alert, "last_copied_file": db + ".trn",
			"last_copied_utc": z(3), "last_restored_file": db + ".trn", "last_restored_utc": z(2), "last_restored_latency_min": 2}
	}
	cfgSecondary := func(db, jobRole string, exists, enabled any, interval any) map[string]any {
		id := map[string]string{"copy": "C-", "restore": "R-"}[jobRole] + db
		r := map[string]any{"kind": "lsconfig", "role": "secondary", "database_name": db, "primary_server": pri, "primary_database": db,
			"restore_mode": 0, "job_role": jobRole, "job_id": id, "job_exists": exists, "job_enabled": enabled,
			"enabled_schedules": exists, "interval_min": interval}
		if exists == 1 {
			r["job_name"] = map[string]string{"copy": "LSCopy_PRI_", "restore": "LSRestore_PRI_"}[jobRole] + db
		}
		return r
	}
	restoreRow := func(db string) map[string]any {
		return map[string]any{"kind": "restore", "database_name": db, "database_state": "RESTORING", "is_in_standby": 0,
			"recovery_model": "FULL", "created_utc": now.Add(-30 * 24 * time.Hour).Format("2006-01-02T15:04:05Z"), "is_mirrored": 0,
			"in_availability_group": 0, "last_log_restore_utc": z(2), "last_log_backup_start_utc": z(4), "source_server": pri,
			"source_database": db, "last_file": db + ".trn", "last_restore_utc": z(2), "last_restore_type": "L"}
	}
	sMon := []map[string]any{monSecondary("lsx_s_ok", 45, 1), monSecondary("lsx_s_restoreoff", 45, 1), monSecondary("lsx_s_copygone", 45, 1),
		monSecondary("lsx_s_alertoff", 45, 0), monSecondary("lsx_s_tight", 2, 1), restoreRow("lsx_s_alertoff"), restoreRow("lsx_s_restoreoff")}
	sCfg := []map[string]any{
		cfgSecondary("lsx_s_ok", "copy", 1, 1, 15.0), cfgSecondary("lsx_s_ok", "restore", 1, 1, 15.0),
		cfgSecondary("lsx_s_restoreoff", "copy", 1, 1, 15.0), cfgSecondary("lsx_s_restoreoff", "restore", 1, 0, 15.0),
		cfgSecondary("lsx_s_copygone", "copy", 0, nil, nil), cfgSecondary("lsx_s_copygone", "restore", 1, 1, 15.0),
		cfgSecondary("lsx_s_alertoff", "copy", 1, 1, 15.0), cfgSecondary("lsx_s_alertoff", "restore", 1, 1, 15.0),
		cfgSecondary("lsx_s_tight", "copy", 1, 1, 1.0), cfgSecondary("lsx_s_tight", "restore", 1, 1, 1.0),
		{"kind": "lsconfig", "role": "monitor", "database_name": "", "job_role": "alert", "job_id": "A-1", "job_name": "LSAlert_SEC",
			"job_exists": 1, "job_enabled": 0, "enabled_schedules": 1, "interval_min": 2.0},
	}
	imp(S, now, append(append([]map[string]any{}, sMon...), sCfg...))
	exec(`INSERT INTO pgvigil.mssql_jobs (instance_id, job_id, snapshot_at, name, enabled, last_outcome, last_run_at)
	      VALUES ($1, 'R-lsx_s_restoreoff', now(), 'LSRestore_PRI_lsx_s_restoreoff', false, 1, $2)`, S, now.Add(-90*time.Minute))

	// ---- T: the same faults, read 20 minutes ago
	imp(T, now.Add(-20*time.Minute), []map[string]any{monPrimary("lsx_old", 30, 0), cfgPrimary("lsx_old", "SIMPLE", 1, 0, 1, 15.0),
		monPrimary("lsx_old2", 30, 1), cfgPrimary("lsx_old2", "FULL", 1, 1, 1, 15.0), // enabled and scheduled: only freshness keeps its threshold unjudged
		{"kind": "lsforeign", "database_name": "lsx_old", "file_name": `D:\x.trn`, "device": "disk", "started_utc": z(40), "finished_utc": z(40)}})

	extras := []string{"a log shipping job is missing", "a log shipping job is disabled", "a log backup outside log shipping broke the chain",
		"a log-shipped database is in SIMPLE recovery", "a log-shipped database is in BULK_LOGGED recovery", "the log shipping alert is off",
		"a log shipping alert threshold is under three times its job interval"}
	findings := func(id int) (list []string, detail map[string]string) {
		t.Helper()
		detail = map[string]string{}
		rows, err := pool.Query(ctx, `SELECT check_name, severity, object, detail FROM pgvigil.mssql_hadr_findings
		                               WHERE instance_id = $1 AND check_name = ANY ($2)`, id, extras)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		for rows.Next() {
			var c, sv, o, d string
			if err := rows.Scan(&c, &sv, &o, &d); err != nil {
				t.Fatal(err)
			}
			list = append(list, c+" | "+sv+" | "+o)
			detail[o] = d
		}
		sort.Strings(list)
		return list, detail
	}
	same := func(what string, got, want []string) {
		t.Helper()
		sort.Strings(want)
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Errorf("%s:\n got (%d):\n  %s\n want (%d):\n  %s", what, len(got), strings.Join(got, "\n  "), len(want), strings.Join(want, "\n  "))
		}
	}
	has := func(what, text string, parts ...string) {
		t.Helper()
		for _, p := range parts {
			if !strings.Contains(text, p) {
				t.Errorf("%s: the detail lacks %q: %q", what, p, text)
			}
		}
	}

	pGot, pDet := findings(P)
	same("P findings", pGot, []string{
		"a log-shipped database is in SIMPLE recovery | critical | primary / lsx_simple",
		"a log-shipped database is in BULK_LOGGED recovery | warning | primary / lsx_bulk",
		"the log shipping alert is off | info | primary: 2 databases",
		"a log shipping alert threshold is under three times its job interval | info | primary / lsx_tight",
		"a log shipping job is missing | critical | primary / lsx_nojob / backup job JOB-lsx_nojob",
		"a log shipping job is disabled | critical | primary / lsx_disabled / LSBackup_lsx_disabled",
		"a log shipping job is disabled | critical | primary / lsx_nosched / LSBackup_lsx_nosched",
		"a log backup outside log shipping broke the chain | critical | primary / lsx_foreign",
		"a log backup outside log shipping broke the chain | critical | primary / lsx_foreign2",
		"a log backup outside log shipping broke the chain | critical | primary / lsx_foreign3",
		"a log backup outside log shipping broke the chain | critical | primary / lsx_foreign4",
	})
	has("the alert off, two databases", pDet["primary: 2 databases"], "2 primary databases (lsx_alertoff, lsx_alertoff2)", "The first: primary database lsx_alertoff:")
	has("lsx_bulk", pDet["primary / lsx_bulk"], "Point-in-time recovery isn't supported", "Log backups might be large")
	has("lsx_simple", pDet["primary / lsx_simple"], "switching the database to simple recovery will cause log shipping to stop functioning")
	has("lsx_tight", pDet["primary / lsx_tight"], "30 minutes", "every 15 minutes", "at least three times the frequency of the backup job")
	has("lsx_nosched", pDet["primary / lsx_nosched / LSBackup_lsx_nosched"], "has no enabled schedule")
	has("lsx_disabled", pDet["primary / lsx_disabled / LSBackup_lsx_disabled"], "is disabled")
	has("lsx_foreign", pDet["primary / lsx_foreign"], `D:\Backup\lsx_foreign_2.trn`, "2 log backups", `C:\LS\lsx_foreign`,
		"probably the job DatabaseBackup - USER_DATABASES - LOG: its run covers that backup", "this finding stays for 24 hours")
	for _, never := range []string{"LSBackup_lsx_foreign", "Short job"} {
		if strings.Contains(pDet["primary / lsx_foreign"], never) {
			t.Errorf("lsx_foreign names %q (log shipping's own job, or a run that ended before the backup did): %q", never, pDet["primary / lsx_foreign"])
		}
	}
	has("lsx_foreign2", pDet["primary / lsx_foreign2"], "NUL", "1 log backup ", "is not known (no job run")
	has("lsx_foreign3", pDet["primary / lsx_foreign3"], "is not known: it went to a virtual device")
	if strings.Contains(pDet["primary / lsx_foreign3"], "Tool wrapper job") {
		t.Errorf("lsx_foreign3 guesses a job for a virtual device: %q", pDet["primary / lsx_foreign3"])
	}
	has("lsx_foreign4", pDet["primary / lsx_foreign4"], "probably one of the jobs Job A; Job B: their runs cover that backup")

	sWant := []string{
		"a log shipping job is disabled | critical | secondary / lsx_s_restoreoff / LSRestore_PRI_lsx_s_restoreoff",
		"a log shipping job is missing | critical | secondary / lsx_s_copygone / copy job C-lsx_s_copygone",
		"a log shipping job is disabled | warning | monitor / LSAlert_SEC",
		"the log shipping alert is off | info | secondary / lsx_s_alertoff on " + sec,
		"a log shipping alert threshold is under three times its job interval | info | secondary / lsx_s_tight on " + sec,
	}
	sGot, sDet := findings(S)
	same("S findings", sGot, sWant)
	has("lsx_s_restoreoff", sDet["secondary / lsx_s_restoreoff / LSRestore_PRI_lsx_s_restoreoff"], "Its last run succeeded")
	has("lsx_s_tight", sDet["secondary / lsx_s_tight on "+sec], "2 minutes", "every 1 minute", "at least three times the frequency of the restore job")
	has("the alert job", sDet["monitor / LSAlert_SEC"], "raises no alert of its own")
	var info, okRow, crit, okRow2 int
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE database_name = 'lsx_s_alertoff' AND severity = 'info'),
	        count(*) FILTER (WHERE database_name = 'lsx_s_alertoff' AND severity IS NULL AND na_reason IS NULL),
	        count(*) FILTER (WHERE database_name = 'lsx_s_restoreoff' AND severity = 'critical'),
	        count(*) FILTER (WHERE database_name = 'lsx_s_restoreoff' AND severity IS NULL)
	   FROM pgvigil.mssql_logship_judged() WHERE instance_id = $1`, S).Scan(&info, &okRow, &crit, &okRow2); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(info, okRow, crit, okRow2) != "1 1 1 0" {
		t.Errorf("the judge's rows for lsx_s_alertoff (info, OK) and lsx_s_restoreoff (critical, OK) = %d %d %d %d, want 1 1 1 0", info, okRow, crit, okRow2)
	}

	// the page reads the same judge: a secondary's job finding is its database's Status, an info finding only its text
	srv := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	rec := httptest.NewRecorder()
	srv.MSSQLHADRFleet(rec, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/mssql/hadr/fleet?page=logshipping&instance=%d", S), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("the page at S: %d %s", rec.Code, rec.Body.String())
	}
	page := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	cell := func(tb *table, row []any, col string) string {
		for i, c := range tb.Columns {
			if c == col {
				return fmt.Sprint(row[i])
			}
		}
		return "no column " + col
	}
	pageRows := map[string]string{}
	if page["detail"] != nil {
		for _, r := range page["detail"].Rows {
			pageRows[cell(page["detail"], r, "database_name")] = cell(page["detail"], r, "status") + " | " + cell(page["detail"], r, "checks")
		}
	}
	if fmt.Sprint(pageRows) != fmt.Sprint(map[string]string{"lsx_s_restoreoff": "critical | a log shipping job is disabled",
		"lsx_s_alertoff": "ok | the log shipping alert is off"}) {
		t.Errorf("the page's detail at S = %v", pageRows)
	}
	if page["summary"] == nil || len(page["summary"].Rows) != 1 {
		t.Fatalf("the page's summary at S = %v", page["summary"])
	}
	if got := cell(page["summary"], page["summary"].Rows[0], "status") + " " + cell(page["summary"], page["summary"].Rows[0], "critical_count") + " " +
		cell(page["summary"], page["summary"].Rows[0], "log_shipped_dbs"); got != "critical 1 2" {
		t.Errorf("the page's summary at S (status, critical, log shipped) = %q, want \"critical 1 2\"", got)
	}

	tGot, _ := findings(T)
	same("T findings (read 20 minutes ago)", tGot, nil)

	// ---- R: a role change done Microsoft's way leaves the original direction's jobs disabled on purpose
	imp(R, now, []map[string]any{
		cfgPrimary("lsx_r_swapped", "FULL", 1, 0, 1, 15.0), cfgSecondary("lsx_r_swapped", "copy", 1, 1, 15.0), cfgSecondary("lsx_r_swapped", "restore", 1, 1, 15.0),
		cfgPrimary("lsx_r_half", "FULL", 1, 0, 1, 15.0), cfgSecondary("lsx_r_half", "copy", 1, 1, 15.0), cfgSecondary("lsx_r_half", "restore", 1, 0, 15.0),
		cfgPrimary("lsx_r_gone", "FULL", 0, nil, 0, nil), cfgSecondary("lsx_r_gone", "copy", 1, 1, 15.0), cfgSecondary("lsx_r_gone", "restore", 1, 1, 15.0),
	})
	rGot, _ := findings(R)
	same("R findings (a role change)", rGot, []string{
		"a log shipping job is disabled | critical | primary / lsx_r_half / LSBackup_lsx_r_half",
		"a log shipping job is disabled | critical | secondary / lsx_r_half / LSRestore_PRI_lsx_r_half",
		"a log shipping job is missing | critical | primary / lsx_r_gone / backup job JOB-lsx_r_gone",
	})

	// ---- M: a secondary that is also the monitor: its table lists another server's row of the same database
	mon, oth := "MON-"+sfx, "OTH-"+sfx
	monRow := func(server string, threshold int) map[string]any {
		return map[string]any{"kind": "secondary", "secondary_server": server, "database_name": "lsx_m", "primary_server": pri,
			"primary_database": "lsx_m", "threshold_minutes": threshold, "alert_enabled": 1, "last_restored_utc": z(2), "last_copied_utc": z(3)}
	}
	imp(M, now, []map[string]any{monRow(mon, 100), monRow(oth, 45),
		cfgSecondary("lsx_m", "copy", 1, 1, 60.0), cfgSecondary("lsx_m", "restore", 1, 1, 60.0)})
	mGot, _ := findings(M)
	same("M findings with no server name to tell the rows apart", mGot, nil)
	exec(`INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, server_name) VALUES ($1, now(), $2)`, M, strings.ToLower(mon))
	mGot, mDet := findings(M)
	same("M findings", mGot, []string{"a log shipping alert threshold is under three times its job interval | info | secondary / lsx_m on " + mon})
	has("lsx_m", mDet["secondary / lsx_m on "+mon], "100 minutes", "every 60 minutes")

	// ---- U: rows kept from a read whose part failed are judged only while they are fresh
	imp(U, now.Add(-20*time.Minute), []map[string]any{monPrimary("lsx_u", 60, 0), cfgPrimary("lsx_u", "FULL", 1, 0, 1, 15.0)})
	imp(U, now, []map[string]any{monPrimary("lsx_u", 60, 0),
		{"kind": "collector_error", "source": "log shipping configuration", "message": "SELECT permission denied"}})
	uGot, _ := findings(U)
	same("U findings (a kept configuration row 20 minutes old)", uGot, []string{"the log shipping alert is off | info | primary / lsx_u"})

	// a later read of S whose configuration part failed keeps the stored rows; a clean read of P without them clears
	imp(S, now.Add(time.Second), append(append([]map[string]any{}, sMon...),
		map[string]any{"kind": "collector_error", "source": "log shipping configuration", "message": "SELECT permission denied"}))
	var kept int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_logship_config WHERE instance_id = $1`, S).Scan(&kept); err != nil {
		t.Fatal(err)
	}
	if kept != 11 {
		t.Errorf("S's configuration rows after a read whose part failed = %d, want 11 kept", kept)
	}
	sGot2, _ := findings(S)
	same("S findings after a read whose configuration part failed", sGot2, sWant)
	var withoutForeign []map[string]any
	for _, r := range pRows {
		if r["kind"] != "lsforeign" {
			withoutForeign = append(withoutForeign, r)
		}
	}
	imp(P, now.Add(time.Second), append(withoutForeign,
		map[string]any{"kind": "collector_error", "source": "log shipping foreign log backups", "message": "SELECT permission denied"}))
	var keptForeign, chain int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.mssql_logship_foreign_logs WHERE instance_id = $1),
	        (SELECT count(*) FROM pgvigil.mssql_hadr_findings WHERE instance_id = $1 AND check_name = 'a log backup outside log shipping broke the chain')`,
		P).Scan(&keptForeign, &chain); err != nil {
		t.Fatal(err)
	}
	if keptForeign != 5 || chain != 4 {
		t.Errorf("P after a read whose foreign part failed: %d foreign rows and %d chain findings, want 5 kept and 4", keptForeign, chain)
	}
	imp(P, now.Add(2*time.Second), []map[string]any{monPrimary("lsx_alertoff", 60, 0), monPrimary("lsx_tight", 30, 1)})
	var cfgLeft, foreignLeft int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.mssql_logship_config WHERE instance_id = $1),
	        (SELECT count(*) FROM pgvigil.mssql_logship_foreign_logs WHERE instance_id = $1)`, P).Scan(&cfgLeft, &foreignLeft); err != nil {
		t.Fatal(err)
	}
	if cfgLeft != 0 || foreignLeft != 0 {
		t.Errorf("P after a clean read with no configuration or foreign rows: %d / %d rows left, want 0 / 0", cfgLeft, foreignLeft)
	}
	pGot2, _ := findings(P)
	same("P findings after that read", pGot2, []string{"the log shipping alert is off | info | primary / lsx_alertoff"})
}

// TestLogShipMessagesOnAStore (task LSX, cut 2: G1): what log shipping's own agents said reaches a finding only as
// part of the detail of a finding that its log shipping is behind (the lead's D4), and the Log Shipping page's panel
// lists it. Expected (written before the first run):
//
//	S2 (a secondary; restore-history rows, the defaults 1440 / 2880): lsx_e_chain critical 'log restores are behind'
//	  (50 h) whose detail adds 'The newest error its restore job logged (...): The log in this backup set begins at
//	  LSN ..., which is too recent to apply to the database. ...' and '(6 error lines of that job in 24 hours).' -
//	  the engine's line (the newest row, sequence 1) - and NOT the idle sentence although its restore job also ran
//	  idle (an error wins: a broken chain is no copy-job fault); lsx_e_idle critical, no error, its restore job idle
//	  4 times: 'Its restore job ran 4 times in the last hour ... the copy job is where to look (Microsoft, error
//	  14421).'; lsx_e_standby critical with only a STANDBY copy's read-only rows: neither note; lsx_e_ok (restored
//	  10 minutes ago) with an error row of its own: NO finding (an agent's message raises nothing by itself);
//	  lsx_e_msdb warning 'log shipping is behind its threshold' (msdb's 45 minutes, 90 behind) whose detail names
//	  'its copy job logged'.
//	P2 (a primary): lsx_e_pri warning 'log shipping is behind its threshold' (60 minutes, 200 behind) whose detail
//	  names 'its backup job logged' and cuts its 400-character message at 297 characters and '...'.
//	  (lsx_e_chain's newest session is a real broken chain's: the agent's closing 'Could not find ...' line is the
//	  newest by milliseconds; the note gives the session's highest sequence, the engine's 'too recent' line.)
//	  lsx_e_file critical, its one session the agent's own lines only (sequence 0 each, no engine line stored): the
//	  note gives the session's FIRST line 'The file ... is too recent to apply', never the closing 'Could not find
//	  ...' one written 7 ms after it, and '(2 error lines of that job in 24 hours).'.
//	  (review lsx2) lsx_e_chain's note never takes the backup agent's line stored on this secondary (the role's
//	  agents only); lsx_e_tie critical, a copy and a restore line at the same time: 'its restore job logged' with the
//	  restore line; lsx_e_past warning 'log shipping is behind its threshold' (msdb's 45 minutes, 60 behind) whose
//	  only error was logged BEFORE its last restore: the idle sentence 'Its restore job ran 2 times', never that error.
//	THE PAGE at S2: the messages part holds the 12 rows of lsx_e_chain, lsx_e_file, lsx_e_tie, lsx_e_past, lsx_e_ok and
//	  lsx_e_msdb that are no noise plus 3 idle rows (lsx_e_chain's, lsx_e_idle's, lsx_e_past's; lsx_e_idle's message
//	  '(4 times in the last hour after its last restore)', its count under idle_runs_1h, rows_24h empty) and the 2
//	  noise rows flagged standby_noise; the jobs part the 3 configuration rows, job_severity only on the monitor's
//	  disabled alert job, and 'warning' (the judge's), the copy and restore jobs none; the foreign part none.
//	A later read of S2 whose two message parts failed keeps both tables' rows and the notes; once those kept error rows
//	  are older than 15 minutes, no error note (stale) and no idle note either (what the agents say now is not known);
//	  a later clean read with none of them clears both.
func TestLogShipMessagesOnAStore(t *testing.T) {
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
	ids := map[string]int{}
	defer func() {
		var all []int
		for _, id := range ids {
			all = append(all, id)
		}
		for _, tb := range []string{"mssql_logrestore_sample", "collection_dates"} {
			if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.`+tb+` WHERE instance_id = ANY ($1)`, all); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, all); err != nil {
			t.Error(err)
		}
	}()
	for _, k := range []string{"S2", "P2"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			"lsxe"+strings.ToLower(k)+"-"+sfx).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[k] = id
		exec(`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_logshipping', now(), 'ok')
		      ON CONFLICT (instance_id, collection) DO UPDATE SET snapshot_at = excluded.snapshot_at, status = excluded.status`, id)
	}
	S2, P2 := ids["S2"], ids["P2"]
	now := time.Now().UTC().Truncate(time.Second)
	z := func(m int) string { return now.Add(-time.Duration(m) * time.Minute).Format("2006-01-02T15:04:05Z") }
	imp := func(id int, at time.Time, rows []map[string]any) {
		t.Helper()
		b, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		exec(`SELECT pgvigil.import_mssql_logshipping($1, $2, $3::jsonb)`, id, at, string(b))
	}
	pri := "PRI-" + sfx
	restoreRow := func(db string, agoMin int) map[string]any {
		return map[string]any{"kind": "restore", "database_name": db, "database_state": "RESTORING", "is_in_standby": 0,
			"recovery_model": "FULL", "created_utc": now.Add(-30 * 24 * time.Hour).Format("2006-01-02T15:04:05Z"), "is_mirrored": 0,
			"in_availability_group": 0, "last_log_restore_utc": z(agoMin), "last_log_backup_start_utc": z(agoMin + 2), "source_server": pri,
			"source_database": db, "last_file": db + ".trn", "last_restore_utc": z(agoMin), "last_restore_type": "L"}
	}
	errRow := func(agent, db string, ord, session, seq, agoMin int, msg, source string, rows24 int, noise int) map[string]any {
		return map[string]any{"kind": "lserror", "agent": agent, "database_name": db, "ord": ord, "session_id": session, "sequence_number": seq,
			"logged_utc": z(agoMin), "message": msg, "source": source, "rows_24h": rows24, "standby_noise": noise}
	}
	const agentSrc, engineSrc = "Microsoft.SqlServer.Management.LogShipping", ".Net SqlClient Data Provider"
	chainEngine := "The log in this backup set begins at LSN 42000000064800001, which is too recent to apply to the database. An earlier log backup that includes LSN 42000000054400001 can be restored.  RESTORE LOG is terminating abnormally."
	long := strings.Repeat("abcdefghij", 39) + "TAIL-WORDS" // 400 characters, its last ten never shown
	// a real broken chain's session (proof part O, 14-cut2-proof.log): the agent's closing 'Could not find ...' line is
	// written milliseconds AFTER the engine's 'too recent' line, so by time it is the newest row (ord 1); the note must
	// still give the engine's line (the session's highest sequence), never the closing one, which reads like an idle run
	at := func(d time.Duration) string { return now.Add(-time.Minute + d).Format("2006-01-02T15:04:05.000Z") }
	closing := errRow("restore", "lsx_e_chain", 1, 7, 0, 1, "Could not find a log backup file that could be applied to secondary database 'lsx_e_chain'.", agentSrc, 6, 0)
	closing["logged_utc"] = at(7 * time.Millisecond)
	engineLine := errRow("restore", "lsx_e_chain", 2, 7, 1, 1, chainEngine, engineSrc, 6, 0)
	engineLine["logged_utc"] = at(3 * time.Millisecond)
	fileLine := errRow("restore", "lsx_e_chain", 3, 7, 0, 1, "The file '/ship/lsx_e_chain_20261115194430.trn' is too recent to apply to the secondary database 'lsx_e_chain'.", agentSrc, 6, 0)
	fileLine["logged_utc"] = at(0)
	older := errRow("restore", "lsx_e_chain", 4, 6, 1, 20, "an older session's engine line, never the one shown", engineSrc, 6, 0)
	// a session of the agent's own lines only (no engine line stored): at a tie of sequences the first line is the
	// telling one, the closing line (the newest) never
	fileClosing := errRow("restore", "lsx_e_file", 1, 8, 0, 1, "Could not find a log backup file that could be applied to secondary database 'lsx_e_file'.", agentSrc, 2, 0)
	fileClosing["logged_utc"] = at(7 * time.Millisecond)
	fileFirst := errRow("restore", "lsx_e_file", 2, 8, 0, 1, "The file '/ship/lsx_e_file_20261115194430.trn' is too recent to apply to the secondary database 'lsx_e_file'.", agentSrc, 2, 0)
	fileFirst["logged_utc"] = at(0)
	tieCopy := errRow("copy", "lsx_e_tie", 1, 12, 0, 1, "the copy agent's line at the same time", agentSrc, 1, 0)
	tieCopy["logged_utc"] = at(0)
	tieRestore := errRow("restore", "lsx_e_tie", 1, 13, 0, 1, "the restore agent's line at the same time", agentSrc, 1, 0)
	tieRestore["logged_utc"] = at(0)
	msgRows := []map[string]any{
		closing, engineLine, fileLine, older, fileClosing, fileFirst, tieCopy, tieRestore,
		errRow("backup", "lsx_e_chain", 1, 30, 0, 0, "a backup agent's line, never on a secondary", agentSrc, 1, 0),
		errRow("restore", "lsx_e_past", 1, 11, 1, 120, "Exclusive access could not be obtained (resolved by the later restore)", engineSrc, 1, 0),
		{"kind": "lsidle", "database_name": "lsx_e_past", "last_utc": z(2), "runs": 2},
		errRow("restore", "lsx_e_ok", 1, 3, 1, 30, "Exclusive access could not be obtained because the database is in use.  RESTORE LOG is terminating abnormally.", engineSrc, 1, 0),
		errRow("copy", "lsx_e_msdb", 1, 9, 0, 5, "The copy operation failed: the backup share cannot be reached.", agentSrc, 1, 0),
		errRow("restore", "lsx_e_standby", 1, 4, 1, 2, "Failed to update database 'lsx_e_standby' because the database is read-only.", engineSrc, 2, 1),
		errRow("restore", "lsx_e_standby", 2, 4, 0, 2, "The database is in read-only mode.", agentSrc, 2, 1),
		{"kind": "lsidle", "database_name": "lsx_e_chain", "last_utc": z(1), "runs": 3},
		{"kind": "lsidle", "database_name": "lsx_e_idle", "last_utc": z(2), "runs": 4},
		{"kind": "lsidle", "database_name": "lsx_e_ok", "last_utc": z(3), "runs": 0},
	}
	sRows := []map[string]any{
		restoreRow("lsx_e_chain", 3000), restoreRow("lsx_e_idle", 3000), restoreRow("lsx_e_standby", 3000), restoreRow("lsx_e_ok", 10),
		restoreRow("lsx_e_file", 3000), restoreRow("lsx_e_tie", 3000),
		{"kind": "secondary", "secondary_server": "", "database_name": "lsx_e_past", "primary_server": pri, "primary_database": "lsx_e_past",
			"threshold_minutes": 45, "alert_enabled": 1, "last_copied_utc": z(65), "last_restored_utc": z(60), "last_restored_latency_min": 2},
		{"kind": "lsconfig", "role": "monitor", "database_name": "", "job_role": "alert", "job_id": "A-e", "job_name": "LSAlert_E",
			"job_exists": 1, "job_enabled": 0, "enabled_schedules": 1, "interval_min": 2.0},
		{"kind": "secondary", "secondary_server": "", "database_name": "lsx_e_msdb", "primary_server": pri, "primary_database": "lsx_e_msdb",
			"threshold_minutes": 45, "alert_enabled": 1, "last_copied_utc": z(95), "last_restored_utc": z(90), "last_restored_latency_min": 2},
		{"kind": "lsconfig", "role": "secondary", "database_name": "lsx_e_chain", "primary_server": pri, "primary_database": "lsx_e_chain", "restore_mode": 0,
			"job_role": "copy", "job_id": "C-chain", "job_name": "LSCopy_chain", "job_exists": 1, "job_enabled": 1, "enabled_schedules": 1, "interval_min": 15.0},
		{"kind": "lsconfig", "role": "secondary", "database_name": "lsx_e_chain", "primary_server": pri, "primary_database": "lsx_e_chain", "restore_mode": 0,
			"job_role": "restore", "job_id": "R-chain", "job_name": "LSRestore_chain", "job_exists": 1, "job_enabled": 1, "enabled_schedules": 1, "interval_min": 15.0},
	}
	imp(S2, now, append(append([]map[string]any{}, sRows...), msgRows...))
	imp(P2, now, []map[string]any{
		{"kind": "primary", "primary_server": pri, "database_name": "lsx_e_pri", "threshold_minutes": 60, "alert_enabled": 1,
			"last_backup_file": "lsx_e_pri.trn", "last_backup_utc": z(200)},
		errRow("backup", "lsx_e_pri", 1, 2, 0, 4, long, agentSrc, 1, 0),
	})

	type fnd struct{ sev, detail string }
	findings := func(id int) map[string]fnd {
		t.Helper()
		out := map[string]fnd{}
		rows, err := pool.Query(ctx, `SELECT check_name, severity, object, detail FROM pgvigil.mssql_hadr_findings
		                               WHERE instance_id = $1 AND check_name IN ('log restores are behind', 'log shipping is behind its threshold')`, id)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		for rows.Next() {
			var c, sv, o, d string
			if err := rows.Scan(&c, &sv, &o, &d); err != nil {
				t.Fatal(err)
			}
			db := o
			for _, cut := range []string{" (from ", " on "} {
				if i := strings.Index(db, cut); i >= 0 {
					db = db[:i]
				}
			}
			db = strings.TrimPrefix(strings.TrimPrefix(db, "secondary / "), "primary / ")
			out[db] = fnd{sv, d}
		}
		return out
	}
	has := func(what, text string, parts ...string) {
		t.Helper()
		for _, p := range parts {
			if !strings.Contains(text, p) {
				t.Errorf("%s: the detail lacks %q: %q", what, p, text)
			}
		}
	}
	hasNot := func(what, text string, parts ...string) {
		t.Helper()
		for _, p := range parts {
			if strings.Contains(text, p) {
				t.Errorf("%s: the detail holds %q: %q", what, p, text)
			}
		}
	}
	check := func(when string) {
		t.Helper()
		f := findings(S2)
		got := map[string]string{}
		for k, v := range f {
			got[k] = v.sev
		}
		if fmt.Sprint(got) != fmt.Sprint(map[string]string{"lsx_e_chain": "critical", "lsx_e_file": "critical", "lsx_e_tie": "critical", "lsx_e_idle": "critical", "lsx_e_standby": "critical", "lsx_e_msdb": "warning", "lsx_e_past": "warning"}) {
			t.Errorf("%s: S2's behind findings = %v (lsx_e_ok, with an error of its own, must have none)", when, got)
		}
		has(when+" lsx_e_chain", f["lsx_e_chain"].detail, "The newest error its restore job logged (", "which is too recent to apply to the database", "(6 error lines of that job in 24 hours).")
		hasNot(when+" lsx_e_chain", f["lsx_e_chain"].detail, "the copy job is where to look", "Could not find a log backup file", "an older session", "a backup agent's line")
		has(when+" lsx_e_tie", f["lsx_e_tie"].detail, "The newest error its restore job logged (", "the restore agent's line at the same time")
		hasNot(when+" lsx_e_tie", f["lsx_e_tie"].detail, "the copy agent's line")
		has(when+" lsx_e_past", f["lsx_e_past"].detail, "Its restore job ran 2 times in the last hour after its last restore")
		hasNot(when+" lsx_e_past", f["lsx_e_past"].detail, "resolved by the later restore", "The newest error")
		has(when+" lsx_e_file", f["lsx_e_file"].detail, "The newest error its restore job logged (", "The file '/ship/lsx_e_file_20261115194430.trn' is too recent to apply", "(2 error lines of that job in 24 hours).")
		hasNot(when+" lsx_e_file", f["lsx_e_file"].detail, "Could not find a log backup file", "the copy job is where to look")
		has(when+" lsx_e_idle", f["lsx_e_idle"].detail, "Its restore job ran 4 times in the last hour after its last restore", "the copy job is where to look (Microsoft, error 14421).")
		hasNot(when+" lsx_e_standby", f["lsx_e_standby"].detail, "The newest error", "read-only", "Its restore job ran")
		has(when+" lsx_e_msdb", f["lsx_e_msdb"].detail, "The newest error its copy job logged (", "the backup share cannot be reached")
	}
	check("the first read")
	p := findings(P2)
	if p["lsx_e_pri"].sev != "warning" {
		t.Errorf("P2's lsx_e_pri = %q, want warning", p["lsx_e_pri"].sev)
	}
	has("lsx_e_pri", p["lsx_e_pri"].detail, "The newest error its backup job logged (", long[:297]+"...")
	hasNot("lsx_e_pri", p["lsx_e_pri"].detail, "TAIL-WORDS")

	// the page's panel parts at S2
	srv := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	rec := httptest.NewRecorder()
	srv.MSSQLHADRFleet(rec, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/mssql/hadr/fleet?page=logshipping&instance=%d", S2), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("the page at S2: %d %s", rec.Code, rec.Body.String())
	}
	page := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	col := func(tb *table, name string) int {
		for i, c := range tb.Columns {
			if c == name {
				return i
			}
		}
		t.Fatalf("no column %s in %v", name, tb.Columns)
		return -1
	}
	count := func(part string) int {
		if page[part] == nil {
			return -1
		}
		return len(page[part].Rows)
	}
	noise, idle := 0, 0
	if m := page["messages"]; m != nil {
		for _, r := range m.Rows {
			if r[col(m, "standby_noise")] == true {
				noise++
			}
			if fmt.Sprint(r[col(m, "source")]) == "the restore job's history" {
				idle++
			}
		}
	}
	if got := fmt.Sprintf("messages %d (noise %d, idle %d), jobs %d, foreign %d", count("messages"), noise, idle, count("jobs"), count("foreign")); got != "messages 17 (noise 2, idle 3), jobs 3, foreign 0" {
		t.Errorf("the page's panel at S2: %s, want messages 17 (noise 2, idle 3), jobs 3, foreign 0", got)
	}
	// the fold's columns are looked up without stopping the test (a column missing is one error, the rest still runs)
	colOr := func(tb *table, name string) int {
		for i, c := range tb.Columns {
			if c == name {
				return i
			}
		}
		t.Errorf("the page's part has no column %s (columns %v)", name, tb.Columns)
		return -1
	}
	if m := page["messages"]; m != nil && colOr(m, "idle_runs_1h") >= 0 {
		for _, r := range m.Rows {
			if fmt.Sprint(r[col(m, "database_name")]) == "lsx_e_idle" {
				if !strings.Contains(fmt.Sprint(r[col(m, "message")]), "(4 times in the last hour after its last restore)") ||
					fmt.Sprint(r[col(m, "idle_runs_1h")]) != "4" || r[col(m, "rows_24h")] != nil {
					t.Errorf("the page's idle row of lsx_e_idle: message %q, idle_runs_1h %v, rows_24h %v; want the 4 runs in idle_runs_1h only",
						r[col(m, "message")], r[col(m, "idle_runs_1h")], r[col(m, "rows_24h")])
				}
			}
		}
	}
	if j := page["jobs"]; j != nil && colOr(j, "job_severity") >= 0 {
		var sevs []string
		for _, r := range j.Rows {
			sevs = append(sevs, fmt.Sprintf("%v=%v", r[col(j, "job_role")], r[col(j, "job_severity")]))
		}
		sort.Strings(sevs)
		if got := strings.Join(sevs, ","); got != "alert=warning,copy=<nil>,restore=<nil>" {
			t.Errorf("the page's job_severity at S2: %s, want alert=warning,copy=<nil>,restore=<nil> (the judge's own, a warning for the alert job)", got)
		}
	}

	// a read whose two message parts failed keeps their rows; a clean read without them clears both
	imp(S2, now.Add(time.Second), append(append([]map[string]any{}, sRows...),
		map[string]any{"kind": "collector_error", "source": "log shipping agent errors", "message": "SELECT permission denied"},
		map[string]any{"kind": "collector_error", "source": "log shipping idle restores", "message": "SELECT permission denied"}))
	check("after a read whose message parts failed")
	// the kept error rows grow older than 15 minutes (the parts keep failing): no error note, and no idle note either
	exec(`UPDATE pgvigil.mssql_logship_errors SET snapshot_at = snapshot_at - interval '20 minutes' WHERE instance_id = $1`, S2)
	st := findings(S2)
	hasNot("lsx_e_chain with stale error rows", st["lsx_e_chain"].detail, "The newest error", "Its restore job ran")
	hasNot("lsx_e_idle with stale error rows", st["lsx_e_idle"].detail, "Its restore job ran")
	imp(S2, now.Add(2*time.Second), sRows)
	var errLeft, idleLeft int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.mssql_logship_errors WHERE instance_id = $1),
	        (SELECT count(*) FROM pgvigil.mssql_logship_idle WHERE instance_id = $1)`, S2).Scan(&errLeft, &idleLeft); err != nil {
		t.Fatal(err)
	}
	if errLeft != 0 || idleLeft != 0 {
		t.Errorf("S2 after a clean read with no message rows: %d / %d rows left, want 0 / 0", errLeft, idleLeft)
	}
	f := findings(S2)
	hasNot("lsx_e_chain after the clean read", f["lsx_e_chain"].detail, "The newest error", "Its restore job ran")
	hasNot("lsx_e_file after the clean read", f["lsx_e_file"].detail, "The newest error")
}
