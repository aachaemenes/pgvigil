package mssql

import (
	"strings"
	"testing"
	"time"
)

// mssql_restore_chain (task 304): registered hourly, run where mssql_backups runs.
func TestRestoreChainCollector(t *testing.T) {
	c, ok := Get("mssql_restore_chain")
	if !ok {
		t.Fatal("mssql_restore_chain is not registered")
	}
	if c.DefaultInterval() != time.Hour {
		t.Errorf("mssql_restore_chain runs every %v", c.DefaultInterval())
	}
	for _, info := range []Info{{Kind: KindServer, Major: 16, MsdbAccess: true}, {Kind: KindAzureDB, MsdbAccess: true}, {Kind: KindServer, Major: 16}} {
		ok1, why1 := c.Applies(info)
		ok2, why2 := backupsCollector{}.Applies(info)
		if ok1 != ok2 || why1 != why2 {
			t.Errorf("%+v: mssql_restore_chain %v %q, mssql_backups %v %q", info, ok1, why1, ok2, why2)
		}
	}
}

// The read: LSNs as text, this server's own rows of the database as it is now, the candidates ranked by last_lsn, the
// logs by LSN behind one finish-date floor, at most restoreLogKeep per database, SQL Server 2022's column gated.
func TestRestoreSetsSQL(t *testing.T) {
	for _, has2022 := range []bool{false, true} {
		q := restoreSetsSQL(has2022)
		for _, must := range []string{
			"CAST(bs.last_lsn AS varchar(25)) AS last_lsn", "CAST(bs.fork_point_lsn AS varchar(25)) AS fork_point_lsn",
			"bs.server_name IN (@@SERVERNAME", "bs.backup_finish_date >= DATEADD(hour, -1, dbs.create_date)",
			"ORDER BY b.last_lsn DESC, b.backup_set_id DESC", "bs.backup_finish_date >= @floor", "bs.last_lsn > st.first_lsn",
			"g2.newest <= 2016", "c.differential_base_guid = nf.backup_set_uuid OR c.database_backup_lsn = nf.checkpoint_lsn",
			"DROP TABLE #pgv_rc_cand",
		} {
			if !strings.Contains(q, must) {
				t.Errorf("2022 %v: the statement lacks %q", has2022, must)
			}
		}
		if strings.Contains(q, "bs.last_valid_restore_time") != has2022 {
			t.Errorf("2022 %v: last_valid_restore_time named: %v", has2022, !has2022)
		}
	}
}

// Never a backup or a restore run by pgvigil: the package's statements hold neither verb; the check itself turns red on a
// planted one and passes words that only look like it (F10 of 304's design pass).
func TestRestoreChainSQLHasNoBackupOrRestoreVerb(t *testing.T) {
	for name, q := range map[string]string{"restoreSetsSQL": restoreSetsSQL(true), "restoreFilesSQL": restoreFilesSQL, "backupSetsSQL": backupSetsSQL(true),
		"backupFilesSQL": backupFilesSQL, "backupDBFilesSQL": backupDBFilesSQL, "backupWritersSQL": backupWritersSQL, "backupsSQL": backupsSQL} {
		if m := restoreVerbs.FindString(q); m != "" {
			t.Errorf("%s holds a statement verb: %q", name, m)
		}
	}
	for _, planted := range []string{"SELECT 1;\nRESTORE LOG x FROM DISK = N'y'", "BACKUP DATABASE x TO DISK = N'y'", "IF 1 = 1 BEGIN RESTORE DATABASE x FROM URL = N'y' END", "; backup log [x] to disk = 'nul'"} {
		if !restoreVerbs.MatchString(planted) {
			t.Errorf("the verb check misses %q", planted)
		}
	}
	for _, fine := range []string{"FROM msdb.dbo.backupset bs", "msdb.dbo.restorehistory", "bs.backup_finish_date", "SELECT 'backup' AS sink"} {
		if restoreVerbs.MatchString(fine) {
			t.Errorf("the verb check flags %q", fine)
		}
	}
}
