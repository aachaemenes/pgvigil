package collect

import (
	"strings"
	"testing"
)

// TestAuroraSQLLeavesOutRejectedCalls: the Aurora variants of the rolechange and backups reads leave out every call a
// real Aurora PostgreSQL 17.9 reader rejects (SQLSTATE 0A000, seen in proof-pg-aurora.sh's lab run); a strings.Replace
// that matched nothing would bring the failure back silently.
func TestAuroraSQLLeavesOutRejectedCalls(t *testing.T) {
	if backupsArchiverAuroraSQL == backupsArchiverSQL {
		t.Fatal("backupsArchiverAuroraSQL equals backupsArchiverSQL: the replace matched nothing")
	}
	for name, q := range map[string]string{"backupsArchiverAuroraSQL": backupsArchiverAuroraSQL, "roleBaseAuroraSQL": roleBaseAuroraSQL} {
		for _, f := range []string{"pg_last_wal_receive_lsn", "pg_last_wal_replay_lsn", "pg_last_xact_replay_timestamp", "pg_is_wal_replay_paused", "pg_stat_wal_receiver"} {
			if strings.Contains(q, f) {
				t.Errorf("%s calls %s, which Aurora rejects", name, f)
			}
		}
	}
}
