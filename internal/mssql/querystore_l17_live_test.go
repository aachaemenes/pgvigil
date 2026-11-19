package mssql

import (
	"database/sql"
	"os"
	"testing"
)

// TestQSReplicaFilterLive (RELNOTES L17): on a server whose Query Store holds no other replica's rows the cut read
// returns what the uncut one does. SQL Server 2022 has no sys.query_store_replicas: no role is read and nothing is
// cut. From SQL Server 2025 the view is there: a read-write database is role 1, and the guard keeps every row of a
// store that never saw that role. PGVIGIL_MSSQL_TEST_QSDB names a database with Query Store on and executions in it
// (the proof job makes it); nothing is written by the test.
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
	t.Logf("SQL Server %d: role %d, filtered %v", info.Major, role, filtered)
	if want := info.Major >= 17; filtered != want {
		t.Errorf("filtered = %v on SQL Server %d; want %v (sys.query_store_replicas from SQL Server 2025)", filtered, info.Major, want)
	}
	if filtered && role != 1 {
		t.Errorf("a read-write database's role_type %d, want 1", role)
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
	if len(cut) != len(plain) {
		t.Errorf("the cut read gives %d rows, the uncut %d: a standalone server's store lost rows to the filter", len(cut), len(plain))
	}
}
