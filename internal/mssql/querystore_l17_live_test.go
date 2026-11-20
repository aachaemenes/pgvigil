package mssql

import (
	"database/sql"
	"fmt"
	"os"
	"testing"
)

// TestQSReplicaFilterLive (RELNOTES L17): on a server whose Query Store holds no other replica's rows the cut read
// loses no row of the uncut one. The role is read only where the database has sys.query_store_replicas (Microsoft's
// page names SQL Server 2025, yet 2022 CU28 holds it too - rn-8): a read-write database is role 1, and the guard keeps
// every row of a store that never saw that role. The rows are compared by plan and interval, never by count: the
// store records the test's own reads, so a later read may hold a row more. PGVIGIL_MSSQL_TEST_QSDB names a database
// with Query Store on and executions in it (the proof job makes it); nothing is written by the test.
func TestQSReplicaFilterLive(t *testing.T) {
	db := os.Getenv("PGVIGIL_MSSQL_TEST_QSDB")
	if db == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_QSDB is not set")
	}
	ctx, conn, info := liveConn(t)
	quoted := "[" + db + "]"
	role, filtered, err := qsReplicaRole(ctx, conn, quoted, info)
	if err != nil {
		t.Fatal(err)
	}
	has, err := qsRead(ctx, conn, quoted, "SELECT CASE WHEN OBJECT_ID('sys.query_store_replicas') IS NULL THEN 0 ELSE 1 END AS has_view", "")
	if err != nil || len(has) != 1 {
		t.Fatalf("the view's presence: %v (%d rows)", err, len(has))
	}
	view := fmt.Sprint(has[0]["has_view"]) == "1"
	t.Logf("SQL Server %d: sys.query_store_replicas %v, role %d, filtered %v", info.Major, view, role, filtered)
	if filtered != view {
		t.Errorf("filtered = %v on SQL Server %d where the view's presence is %v; want them equal", filtered, info.Major, view)
	}
	if filtered && role != 1 {
		t.Errorf("a read-write database's role_type %d, want 1", role)
	}
	// rn-l17 N1: what the view held and the runtime rows' groups, so 'lost 0' says which branch held - rows the view
	// assigns to other roles cut, or none to cut (an unlisted group kept)
	if view {
		reps, err := qsRead(ctx, conn, quoted, "SELECT CAST(q.replica_group_id AS bigint) AS g, CAST(q.role_type AS int) AS r FROM sys.query_store_replicas q", "")
		groups, gerr := qsRead(ctx, conn, quoted, "SELECT DISTINCT CAST(s.replica_group_id AS bigint) AS g FROM sys.query_store_runtime_stats s", "")
		t.Logf("sys.query_store_replicas: %v (%v); the runtime rows' groups: %v (%v)", reps, err, groups, gerr)
	}
	decl := "@first bigint, @last bigint, @top int"
	args := []any{sql.Named("first", int64(0)), sql.Named("last", int64(1)<<62), sql.Named("top", 1000)}
	plain, err := qsRead(ctx, conn, quoted, qsCandidatesQuery(qsHasWaits(info), 0, false), decl, args...)
	if err != nil {
		t.Fatal(err)
	}
	if len(plain) == 0 {
		t.Fatal("no candidate rows: the job's executions did not reach the store")
	}
	if !filtered {
		return
	}
	cut, err := qsRead(ctx, conn, quoted, qsCandidatesQuery(qsHasWaits(info), role, true), decl, args...)
	if err != nil {
		t.Fatal(err)
	}
	key := func(r map[string]any) string { return fmt.Sprint(r["plan_id"], "/", r["interval_id"]) }
	inCut := map[string]bool{}
	for _, r := range cut {
		inCut[key(r)] = true
	}
	lost := 0
	for _, r := range plain {
		if !inCut[key(r)] {
			lost++
			t.Errorf("plan / interval %s of the uncut read is not in the cut read: a standalone server's store lost it to the filter", key(r))
		}
	}
	t.Logf("the uncut read %d rows, the cut %d, lost %d", len(plain), len(cut), lost)
}
