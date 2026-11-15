package mssql

import (
	"regexp"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestBackupCheckDBRows: sys.databases decides which databases' recovery status is read (task 301b, the lead's 04:5x
// AUTO_CLOSE rule): an AUTO_CLOSE database is left out unless the instance opts in, its cell says why; offline,
// snapshot, standby and a secondary replica's copy are not judged; every other database is read by its id.
func TestBackupCheckDBRows(t *testing.T) {
	dbs := []collect.Row{
		{"database_id": int64(5), "database_name": "app", "state": "ONLINE", "recovery_model": "FULL", "is_auto_close_on": int64(0), "is_snapshot": int64(0), "is_standby": int64(0), "is_secondary": int64(0)},
		{"database_id": int64(6), "database_name": "ac", "state": "ONLINE", "recovery_model": "FULL", "is_auto_close_on": int64(1), "is_snapshot": int64(0), "is_standby": int64(0), "is_secondary": int64(0)},
		{"database_id": int64(7), "database_name": "off", "state": "OFFLINE", "recovery_model": "FULL", "is_auto_close_on": int64(0), "is_snapshot": int64(0), "is_standby": int64(0), "is_secondary": int64(0)},
		{"database_id": int64(8), "database_name": "snap", "state": "ONLINE", "recovery_model": "SIMPLE", "is_auto_close_on": int64(0), "is_snapshot": int64(1), "is_standby": int64(0), "is_secondary": int64(0)},
		{"database_id": int64(9), "database_name": "ls", "state": "ONLINE", "recovery_model": "FULL", "is_auto_close_on": int64(0), "is_snapshot": int64(0), "is_standby": int64(1), "is_secondary": int64(0)},
		{"database_id": int64(10), "database_name": "sec", "state": "ONLINE", "recovery_model": "FULL", "is_auto_close_on": int64(0), "is_snapshot": int64(0), "is_standby": int64(0), "is_secondary": int64(1)},
		{"database_id": int64(11), "database_name": "rst", "state": "RESTORING", "recovery_model": "FULL", "is_auto_close_on": int64(0), "is_snapshot": int64(0), "is_standby": int64(0), "is_secondary": int64(0)},
	}
	want := map[string]string{
		"app": "read", "ac": "not read: AUTO_CLOSE (reading would open it)", "off": "not judged: the database is offline",
		"snap": "not judged: a database snapshot", "ls": "not judged: a standby database (restoring logs)",
		"sec": "not judged: a secondary replica", "rst": "not judged: the database is restoring",
	}
	rows, ids := backupCheckDBRows(dbs, false)
	for _, r := range rows {
		if got := r["lsn_state"]; got != want[r["database_name"].(string)] {
			t.Errorf("default: %s -> %v, want %s", r["database_name"], got, want[r["database_name"].(string)])
		}
	}
	if strings.Join(ids, ",") != "5" {
		t.Errorf("default: the ids read %v, want [5] (AUTO_CLOSE left out)", ids)
	}
	rows, ids = backupCheckDBRows(dbs, true)
	if rows[1]["lsn_state"] != "read" || strings.Join(ids, ",") != "5,6" {
		t.Errorf("opted in: ac %v, ids %v, want read and [5 6]", rows[1]["lsn_state"], ids)
	}
	// the recovery status lands on its database by id; a database the view did not return is not judged
	applyRecovery(rows, []collect.Row{{"database_id": int64(5), "last_log_backup_lsn": "42000000031200001"}})
	if rows[0]["last_log_backup_lsn"] != "42000000031200001" || rows[1]["lsn_state"] != "not judged: no recovery status row" {
		t.Errorf("applyRecovery: app %v, ac %v", rows[0]["last_log_backup_lsn"], rows[1]["lsn_state"])
	}
}

// TestBackupHistorySQLReadsOnly: every statement of the two collections reads; none writes, backs up, restores or
// calls xp_fileexist (it answers 0 / 0 / 0 to a login that is not sysadmin: probe 301bP1); the one EXEC is
// xp_instance_regread behind 301c's gate. The newest N and M are the lead's E2.
func TestBackupHistorySQLReadsOnly(t *testing.T) {
	texts := map[string]string{
		"sets": backupSetHistorySQL(true), "sets 2019": backupSetHistorySQL(false), "restores": restoreHistorySQL,
		"right": restoreRightSQL, "newest": restoreNewestSQL, "mark": restoreMarkSQL, "dbs": backupCheckDBsSQL(true),
		"dbs no hadr": backupCheckDBsSQL(false), "recovery": backupRecoverySQL, "path": backupPathSQL, "path reg": backupPathRegSQL,
		"exists": backupExistsSQL,
	}
	verb := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|BACKUP|RESTORE|GRANT|DENY|REVOKE)\s`)
	for name, q := range texts {
		if m := verb.FindString(q); m != "" {
			t.Errorf("%s: a write-shaped word %q", name, m)
		}
		if strings.Contains(strings.ToLower(q), "xp_fileexist") {
			t.Errorf("%s: calls xp_fileexist", name)
		}
		if name != "path reg" && strings.Contains(strings.ToUpper(q), "EXEC") {
			t.Errorf("%s: an EXEC", name)
		}
	}
	if !strings.Contains(backupSetHistorySQL(true), "r.rn <= 10") || !strings.Contains(restoreHistorySQL, "r.rn <= 20") {
		t.Error("the newest 10 sets / 20 restores are not the statements' bounds")
	}
	if !strings.Contains(backupSetHistorySQL(true), "bs.compression_algorithm") || strings.Contains(backupSetHistorySQL(false), "bs.compression_algorithm") {
		t.Error("compression_algorithm is read only where msdb has it (2022)")
	}
}

// TestBackupCheckOptionsOffByDefault: both opt-ins are off until the WIRING patch reads the instance's configuration.
func TestBackupCheckOptionsOffByDefault(t *testing.T) {
	if a, f := backupCheckOptions(Info{}); a || f {
		t.Errorf("opt-ins on by default: auto_close %v, files %v", a, f)
	}
}
