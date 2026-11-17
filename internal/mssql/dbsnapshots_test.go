package mssql

import (
	"fmt"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestSnapshotRows (P25 row 2b): the instance's database snapshots as the hourly read lists them become 0392's
// 'db_snapshot' rows; without the permission sys.dm_io_virtual_file_stats asks (VIEW SERVER STATE, VIEW SERVER
// PERFORMANCE STATE from 2022) the size is NULL and each row says why; the statement asks for the size only then.
func TestSnapshotRows(t *testing.T) {
	read := []collect.Row{{"snapshot_name": "sales_snap1", "source_database": "sales", "created_utc": "2026-11-17T06:00:00.000Z", "files": int64(2), "size_on_disk_bytes": int64(65536)}}
	rows := snapshotRows(read, "")
	if len(rows) != 1 || fmt.Sprint(rows[0]["kind"], " ", rows[0]["snapshot_name"], " ", rows[0]["source_database"], " ", rows[0]["size_on_disk_bytes"], " ", rows[0]["size_note"]) != "db_snapshot sales_snap1 sales 65536 <nil>" {
		t.Errorf("rows %v", rows)
	}
	rows = snapshotRows([]collect.Row{{"snapshot_name": "s2", "source_database": "hr", "size_on_disk_bytes": nil}}, "not read: the login lacks VIEW SERVER STATE")
	if rows[0]["size_note"] != "not read: the login lacks VIEW SERVER STATE" || rows[0]["size_on_disk_bytes"] != nil {
		t.Errorf("no permission: %v", rows[0])
	}
	if s := snapshotsSQL(true); !strings.Contains(s, "sys.dm_io_virtual_file_stats(s.database_id, NULL)") {
		t.Errorf("with the permission the statement reads no size: %s", s)
	}
	if s := snapshotsSQL(false); strings.Contains(s, "dm_io_virtual_file_stats") || !strings.Contains(s, "source_database_id IS NOT NULL") {
		t.Errorf("without the permission the statement still asks the size, or lists no snapshot: %s", s)
	}
	if got := snapshotRows(nil, ""); len(got) != 0 {
		t.Errorf("no snapshot: %d rows, want 0", len(got))
	}
}
