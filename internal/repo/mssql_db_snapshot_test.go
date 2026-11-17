package repo

import (
	"encoding/json"
	"testing"
	"time"
)

// TestDBSnapshotsOnAStore (P25 row 2b, migration 0392: DBA Dash's database Snapshot Summary): on a store,
// pgvigil.import_mssql_db_snapshots keeps each database snapshot the hourly read lists - its source database, when it
// was created, its sparse files' size on disk and their count (NULL with the note when the login may not read the
// size) - and marks a snapshot the next read no longer lists not present; a read that could not list the snapshots
// ('snapshots_unread') leaves them as they were.
func TestDBSnapshotsOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	t1, t2, t3 := now.Add(-3*time.Hour), now.Add(-2*time.Hour), now.Add(-time.Hour)
	imp := func(at time.Time, rows ...map[string]any) {
		t.Helper()
		b, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.pool.Exec(s.ctx, `SELECT pgvigil.import_mssql_db_snapshots($1, $2, $3::jsonb)`, s.id, at, string(b)); err != nil {
			t.Fatalf("import_mssql_db_snapshots at %s: %v", at.Format(time.RFC3339), err)
		}
	}
	snap := func(name, source string, size any, note any) map[string]any {
		return map[string]any{"kind": "db_snapshot", "snapshot_name": name, "source_database": source, "created_utc": "2026-11-17T06:00:00",
			"size_on_disk_bytes": size, "files": 2, "size_note": note}
	}
	rows := func() string {
		t.Helper()
		return s.vals(`SELECT snapshot_name, source_database, created_at = '2026-11-17 06:00:00+00'::timestamptz, size_on_disk_bytes, files, size_note, is_present
		                 FROM pgvigil.mssql_db_snapshot WHERE instance_id = $1 ORDER BY snapshot_name`, s.id)
	}
	imp(t1, snap("sales_snap1", "sales", 65536, nil), snap("sales_snap2", "sales", nil, "not read: the login lacks VIEW SERVER STATE"))
	if got, want := rows(), "sales_snap1 sales true 65536 2 NULL true | sales_snap2 sales true NULL 2 not read: the login lacks VIEW SERVER STATE true"; got != want {
		t.Errorf("after the first read:\n got %s\nwant %s", got, want)
	}
	imp(t2, snap("sales_snap2", "sales", 131072, nil))
	if got, want := rows(), "sales_snap1 sales true 65536 2 NULL false | sales_snap2 sales true 131072 2 NULL true"; got != want {
		t.Errorf("after the second read (snap1 dropped):\n got %s\nwant %s", got, want)
	}
	imp(t3, map[string]any{"kind": "snapshots_unread", "note": "not read: sys.databases: timeout"})
	if got, want := rows(), "sales_snap1 sales true 65536 2 NULL false | sales_snap2 sales true 131072 2 NULL true"; got != want {
		t.Errorf("after a read that listed none (unread):\n got %s\nwant %s", got, want)
	}
}
