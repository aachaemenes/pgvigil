package mssql

import "database/sql"

// The WIRING of task 301b (scripts/inv-301b-wiring.patch): mssql_backup_checks' two opt-ins and the file check's pool
// come from the instance's configuration through Info (the runner sets them); without this file both stay off.
func init() {
	backupCheckOptions = func(i Info) (bool, bool) { return i.ReadAutoCloseDatabases, i.CheckBackupFiles }
	backupFileDB = func(i Info) *sql.DB {
		if !i.CheckBackupFiles {
			return nil
		}
		return i.BackupFilePool
	}
}
