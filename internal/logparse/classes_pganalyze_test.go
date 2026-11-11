package logparse

import (
	"strings"
	"testing"
)

// TestClassifyMore: the recorded lines were written by PostgreSQL 18 in a throwaway container (2026-11-10, a
// statement timeout, a lock timeout, a role at its connection limit, a sort spilling with log_temp_files = 0, a
// repeatable read update conflict, a pg_cancel_backend); the constructed ones carry the message text of the
// PostgreSQL source for the events a sandbox cannot produce on demand (a crash, wraparound, an archive failure).
func TestClassifyMore(t *testing.T) {
	for _, c := range []struct {
		level, msg string
		kind       Kind
		class      string
	}{
		// recorded
		{"ERROR", "canceling statement due to statement timeout", Timeout, "STATEMENT_CANCELED_TIMEOUT"},
		{"ERROR", "canceling statement due to lock timeout at character 37", Timeout, "LOCK_TIMEOUT"},
		{"FATAL", `too many connections for role "lim"`, ConnectionLimit, "TOO_MANY_CONNECTIONS_ROLE"},
		{"LOG", `temporary file: path "base/pgsql_tmp/pgsql_tmp148.1", size 2457600`, TempFile, "SERVER_TEMP_FILE_CREATED"},
		{"ERROR", "could not serialize access due to concurrent update", SerializationFailure, "COULD_NOT_SERIALIZE_REPEATABLE_READ"},
		{"ERROR", "canceling statement due to user request", Canceled, "STATEMENT_CANCELED_USER"},
		// recorded by the slice's review in a throwaway PostgreSQL 18 container (a backend killed with SIGSEGV)
		{"LOG", "client backend (PID 83) was terminated by signal 11: Segmentation fault", Crash, "SERVER_CRASHED"},
		// constructed
		{"LOG", "client backend (PID 84) was terminated by signal 9: Killed", OutOfMemory, "SERVER_OUT_OF_MEMORY"},
		{"LOG", "autovacuum worker (PID 85) was terminated by signal 6: Aborted", Crash, "SERVER_CRASHED"},
		{"ERROR", `database is not accepting commands that assign new transaction IDs to avoid wraparound data loss in database "shop"`, Wraparound, "TXID_WRAPAROUND_ERROR"},
		{"ERROR", `database is not accepting commands that assign new MultiXactIds to avoid wraparound data loss in database "shop"`, Wraparound, "TXID_WRAPAROUND_ERROR"},
		{"ERROR", `database is not accepting commands that generate new MultiXactIds to avoid wraparound data loss in database "shop"`, Wraparound, "TXID_WRAPAROUND_ERROR"},
		{"WARNING", `database "shop" must be vacuumed before 400000 more MultiXactIds are used`, Wraparound, "TXID_WRAPAROUND_WARNING"},
		{"FATAL", "sorry, too many clients already", ConnectionLimit, "OUT_OF_CONNECTIONS"},
		{"FATAL", "remaining connection slots are reserved for roles with the SUPERUSER attribute", ConnectionLimit, "OUT_OF_CONNECTIONS"},
		{"LOG", "server process (PID 4242) was terminated by signal 11: Segmentation fault", Crash, "SERVER_CRASHED"},
		{"LOG", "server process (PID 4242) was terminated by signal 9: Killed", OutOfMemory, "SERVER_OUT_OF_MEMORY"},
		{"LOG", "terminating any other active server processes", Crash, "SERVER_CRASHED"},
		{"WARNING", `database "shop" must be vacuumed within 9000000 transactions`, Wraparound, "TXID_WRAPAROUND_WARNING"},
		{"ERROR", `database is not accepting commands to avoid wraparound data loss in database "shop"`, Wraparound, "TXID_WRAPAROUND_ERROR"},
		{"LOG", "archive command failed with exit code 1", ArchiveFailed, "WAL_ARCHIVE_COMMAND_FAILED"},
		{"ERROR", "canceling autovacuum task", AutovacuumCancel, "AUTOVACUUM_CANCEL"},
		{"LOG", `skipping vacuum of "orders" --- lock not available`, VacuumSkipped, "SKIPPING_VACUUM_LOCK_NOT_AVAILABLE"},
		{"LOG", "checkpoints are occurring too frequently (12 seconds apart)", CheckpointFrequent, "CHECKPOINT_TOO_FREQUENT"},
		{"FATAL", "unexpected EOF on client connection with an open transaction", ConnectionLost, "CONNECTION_LOST_OPEN_TX"},
		{"ERROR", "canceling statement due to conflict with recovery", StandbyConflict, "STANDBY_STATEMENT_CANCELED"},
		{"ERROR", "out of memory", OutOfMemory, "SERVER_OUT_OF_MEMORY"},
	} {
		k, cl, ok := ClassifyMore(c.level, c.msg)
		if !ok || k != c.kind || cl != c.class {
			t.Errorf("%s %q: got %q %q %v, want %q %q", c.level, c.msg, k, cl, ok, c.kind, c.class)
		}
	}
	// not taken: no class, or a continuation level
	for _, c := range [][2]string{
		{"LOG", "checkpoint starting: time"},
		{"LOG", "connection received: host=10.0.0.5 port=54321"},
		{"ERROR", `duplicate key value violates unique constraint "orders_pkey"`},
		{"DETAIL", "canceling statement due to statement timeout"},
		{"LOG", "server process (PID 1) was terminated by signal 15: Terminated"},
		{"LOG", "client backend (PID 1) was terminated by signal 15: Terminated"},
		{"LOG", "background worker \"logical replication launcher\" (PID 1) exited with exit code 1"},
		{"LOG", "database system is ready to accept connections"},
	} {
		if k, cl, ok := ClassifyMore(c[0], c[1]); ok {
			t.Errorf("%s %q: classified as %q %q", c[0], c[1], k, cl)
		}
	}
	// every kind is listed in Kinds, and every class maps to a listed kind
	known := map[Kind]bool{}
	for _, k := range Kinds {
		known[k] = true
	}
	for _, c := range Classes {
		if !known[c.Kind] {
			t.Errorf("class %s: kind %q not in Kinds", c.Name, c.Kind)
		}
	}
}

// TestParsePganalyze runs the classes through the reader itself (classify's default branch): the kind, the detail
// (the message with its DETAIL and HINT lines, an autovacuum cancel's CONTEXT) and the statement (the STATEMENT
// line; a crash's "Failed process was running:" DETAIL) per line of testdata/pganalyze-pg18.log, which also carries
// a deadlock (an earlier case keeps it), a bare duration line and a checkpoint line (both dropped).
func TestParsePganalyze(t *testing.T) {
	evs := parseFile(t, "pganalyze-pg18.log")
	byPID := map[int][]Event{}
	for _, e := range evs {
		byPID[e.PID] = append(byPID[e.PID], e)
	}
	want := []struct {
		pid    int
		kind   Kind
		detail string // a substring of the detail
		stmt   string // the whole statement
	}{
		{6101, Timeout, "canceling statement due to statement timeout", "select pg_sleep(10) where 1 = 1"},
		{6102, ConnectionLimit, `too many connections for role "lim"`, ""},
		{6103, TempFile, `size 1073741824`, "select * from orders where total > 100 order by placed_at"},
		{6104, SerializationFailure, "could not serialize access due to concurrent update", "update orders set total = 7 where id = 1"},
		{6105, Canceled, "canceling statement due to user request", "select count(*) from orders where total = 99"},
		{6107, OutOfMemory, `DETAIL: Failed on request of size 16 in memory context "ExecutorState".`, "select array_agg(x) from generate_series(1, 2000000000) x"},
		{6108, Wraparound, "HINT: To avoid XID assignment failures", ""},
		{6109, ArchiveFailed, "DETAIL: The failed archive command was: cp pg_wal/000000010000000000000042", ""},
		{6110, AutovacuumCancel, `CONTEXT: automatic vacuum of table "shop.public.orders"`, ""},
		{6111, VacuumSkipped, `skipping vacuum of "orders"`, ""},
		{6112, CheckpointFrequent, `HINT: Consider increasing the configuration parameter "max_wal_size".`, ""},
		{6113, ConnectionLost, "unexpected EOF on client connection with an open transaction", ""},
		{6114, StandbyConflict, "DETAIL: User query might have needed to see row versions that must be removed.", "select * from orders where id = 5"},
		{6115, Deadlock, "Process 6115 waits for ShareLock", "update orders set total = 1 where id = 2"},
	}
	for _, w := range want {
		es := byPID[w.pid]
		if len(es) != 1 {
			t.Errorf("pid %d: %d events, want 1: %+v", w.pid, len(es), es)
			continue
		}
		e := es[0]
		if e.Kind != w.kind || !strings.Contains(e.Detail, w.detail) || e.Statement != w.stmt {
			t.Errorf("pid %d: kind %q detail %q statement %q; want %q, a detail with %q, statement %q", w.pid, e.Kind, e.Detail, e.Statement, w.kind, w.detail, w.stmt)
		}
	}
	// the crash: two events (the signal, then the postmaster's terminating line), the failed statement in Statement, not in Detail
	if cr := byPID[6106]; len(cr) != 2 || cr[0].Kind != Crash || cr[0].Statement != "select crashme('secret-arg')" || strings.Contains(cr[0].Detail, "secret-arg") || cr[1].Kind != Crash {
		t.Errorf("the crash: %+v", cr)
	}
	if len(byPID[6116]) != 0 {
		t.Errorf("pid 6116 must give no event: %+v", byPID[6116])
	}
	// a checkpoint's progress line is a Checkpoint event since 0079 (the IO page's causes and times)
	if ck := byPID[6117]; len(ck) != 1 || ck[0].Kind != Checkpoint || ck[0].Detail != "checkpoint starting: time" {
		t.Errorf("pid 6117 must give one checkpoint event: %+v", ck)
	}
}
