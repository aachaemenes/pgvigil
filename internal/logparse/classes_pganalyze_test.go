package logparse

import "testing"

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
