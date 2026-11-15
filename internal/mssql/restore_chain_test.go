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

// The read: LSNs as text, this server's own rows of the database as it is now, each set once by backup_set_uuid, only of
// the database's current recovery fork (its newest set's by backup_finish_date) or its parent up to the fork point, the
// candidates ranked by last_lsn inside it, the logs by LSN behind one finish-date floor, at most restoreLogKeep per
// database, SQL Server 2022's column gated, every temp table dropped.
func TestRestoreSetsSQL(t *testing.T) {
	for _, has2022 := range []bool{false, true} {
		q := restoreSetsSQL(has2022)
		for _, must := range []string{
			"CAST(bs.last_lsn AS varchar(25)) AS last_lsn", "CAST(bs.fork_point_lsn AS varchar(25)) AS fork_point_lsn",
			"bs.server_name IN (@@SERVERNAME", "bs.backup_finish_date >= DATEADD(hour, -1, dbs.create_date)",
			"ORDER BY b.last_lsn DESC, b.backup_set_id DESC", "bs.backup_finish_date >= @floor", "bs.last_lsn > st.first_lsn",
			"g2.newest <= 2016", "c.differential_base_guid = nf.backup_set_uuid OR c.database_backup_lsn = nf.checkpoint_lsn",
			"DROP TABLE #pgv_rc_cand", "DROP TABLE #pgv_rc_fork",
			"bs.backup_finish_date DESC, bs.backup_set_id DESC) AS rn", "JOIN #pgv_rc_fork fk ON fk.database_name = bs.database_name",
			"bs.last_recovery_fork_guid = fk.parent AND bs.last_lsn <= fk.fork_point_lsn",
			"ROW_NUMBER() OVER (PARTITION BY bs.backup_set_uuid ORDER BY bs.backup_set_id) AS dup", "b.dup = 1", "lg0.dup = 1",
			"WHEN bs.type IN ('F', 'G', 'P', 'Q') THEN 1", "fk.partial_sets",
		} {
			if !strings.Contains(q, must) {
				t.Errorf("2022 %v: the statement lacks %q", has2022, must)
			}
		}
		if strings.Contains(q, "bs.last_valid_restore_time") != has2022 {
			t.Errorf("2022 %v: last_valid_restore_time named: %v", has2022, !has2022)
		}
		// the fork filter is in both the candidates' and the logs' pass
		if n := strings.Count(q, restoreForkFilter); n != 2 {
			t.Errorf("2022 %v: the fork filter appears %d times, want 2", has2022, n)
		}
	}
}

// PGVIGIL_RESTORE_LOG_KEEP can only LOWER the keep (a proof's cap); anything else leaves restoreLogKeep.
func TestRestoreLogKeepHook(t *testing.T) {
	for v, want := range map[string]int{"": restoreLogKeep, "3": 3, "1": 1, "0": restoreLogKeep, "-5": restoreLogKeep,
		"5000": restoreLogKeep, "2016": restoreLogKeep, "abc": restoreLogKeep} {
		t.Setenv("PGVIGIL_RESTORE_LOG_KEEP", v)
		if got := restoreLogKeepNow(); got != want {
			t.Errorf("PGVIGIL_RESTORE_LOG_KEEP=%q: keep %d, want %d", v, got, want)
		}
	}
	if q := restoreSetsSQLKeep(true, 3); !strings.Contains(q, "g2.newest <= 3") {
		t.Error("a keep of 3 is not in the statement")
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
	for _, planted := range []string{"SELECT 1;\nRESTORE LOG x FROM DISK = N'y'", "BACKUP DATABASE x TO DISK = N'y'", "IF 1 = 1 BEGIN RESTORE DATABASE x FROM URL = N'y' END", "; backup log [x] to disk = 'nul'",
		"IF 1 = 1 RESTORE DATABASE x FROM DISK = N'y'", "IF 0 = 1 SELECT 1 ELSE BACKUP LOG x TO DISK = N'y'", "EXEC (N'RESTORE DATABASE x FROM DISK = N''y''')"} {
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
