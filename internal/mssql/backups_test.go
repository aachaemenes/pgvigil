package mssql

import (
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_backup_files (task 301): registered hourly, read on from a cursor, run where mssql_backups runs.
func TestBackupFilesCollector(t *testing.T) {
	c, ok := Get("mssql_backup_files")
	if !ok {
		t.Fatal("mssql_backup_files is not registered")
	}
	if c.DefaultInterval() != time.Hour {
		t.Errorf("mssql_backup_files runs every %v", c.DefaultInterval())
	}
	if _, ok := c.(CursorCollector); !ok {
		t.Error("mssql_backup_files does not read on from a cursor")
	}
	full := Info{Kind: KindServer, Major: 16, MsdbAccess: true}
	for _, info := range []Info{full, {Kind: KindAzureDB, MsdbAccess: true}, {Kind: KindServer, Major: 16}} {
		ok1, why1 := c.Applies(info)
		ok2, why2 := backupsCollector{}.Applies(info)
		if ok1 != ok2 || why1 != why2 {
			t.Errorf("%+v: mssql_backup_files %v %q, mssql_backups %v %q", info, ok1, why1, ok2, why2)
		}
	}
}

// The read's statement: past the cursor, this server's own sets kept somewhere, ranked per database, type and copy-only
// by the UTC finish (F4, F7, F14); SQL Server 2022's two columns only where msdb has them (F9).
func TestBackupSetsSQL(t *testing.T) {
	for _, has2022 := range []bool{false, true} {
		q := backupSetsSQL(has2022)
		for _, must := range []string{
			"bs.backup_set_id > @p1",
			"PARTITION BY b.database_name, b.type, b.is_copy_only ORDER BY b.finish_utc_dt DESC, b.backup_set_id DESC",
			"WHERE b.sink = 'backup'",
			"bs.server_name IN (@@SERVERNAME",
			backupFinishUTCExpr + " AS finish_utc_dt",
			"CAST(bs.fork_point_lsn AS varchar(25)) AS fork_point_lsn",
			"CAST(bs.differential_base_guid AS varchar(36)) AS differential_base_guid",
			"CAST(bs.is_password_protected AS int) AS is_password_protected",
			"CAST(ms.is_password_protected AS int) AS media_password",
		} {
			if !strings.Contains(q, must) {
				t.Errorf("2022 %v: the statement lacks %q", has2022, must)
			}
		}
		if got := strings.Contains(q, "bs.compression_algorithm") || strings.Contains(q, "bs.last_valid_restore_time"); got != has2022 {
			t.Errorf("2022 %v: the statement names SQL Server 2022's columns: %v", has2022, got)
		}
	}
	for name, q := range map[string]string{"files": backupFilesSQL, "dbfiles": backupDBFilesSQL} {
		if strings.Count(q, "{ids}") != 1 {
			t.Errorf("%s: %d {ids} places", name, strings.Count(q, "{ids}"))
		}
	}
	// a URL by its scheme before the device type (F6), a path whole (msdb's own nvarchar(260))
	if !strings.Contains(backupFilesSQL, "WHEN f.physical_device_name LIKE N'%://%' THEN 'url'") || !strings.Contains(backupFilesSQL, "CAST(f.physical_device_name AS nvarchar(260)) AS path") {
		t.Error("backupFilesSQL: the device kind or the path")
	}
	// the writers: a fixed window by backup_finish_date, logs that are not copy-only, never NUL (F5)
	for _, must := range []string{"bs.backup_finish_date >= DATEADD(day, -7, GETDATE())", "bs.type = 'L' AND bs.is_copy_only = 0", "NOT IN (N'NUL', N'NUL:')", "N'%[\\/]%'"} {
		if !strings.Contains(backupWritersSQL, must) {
			t.Errorf("backupWritersSQL lacks %q", must)
		}
	}
}

func TestBackupReadFrom(t *testing.T) {
	for last, want := range map[int64]int64{0: 0, 30: 0, 50: 0, 51: 1, 1000: 950} {
		if got := backupReadFrom(last); got != want {
			t.Errorf("backupReadFrom(%d) = %d, want %d", last, got, want)
		}
	}
	got := backupSetIDs([]collect.Row{{"backup_set_id": int64(7)}, {"backup_set_id": int32(9)}, {"backup_set_id": "x"}, {}})
	if strings.Join(got, ",") != "7,9" {
		t.Errorf("backupSetIDs: %v", got)
	}
}
