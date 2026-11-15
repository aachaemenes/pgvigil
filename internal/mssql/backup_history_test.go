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
		"exists": backupExistsSQL, "file sets": backupFileSetsSQL,
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

// TestBackupFileRoots: the file check's roots (0140's mssql_backup_root for a disk path) and directories, and which
// newest sets are disk sets (a URL, a tape, a virtual device or NUL is 'not checked: not a disk path').
func TestBackupFileRoots(t *testing.T) {
	for p, want := range map[string]string{
		`\\NAS01\SQL\app\app_1.bak`: `\\nas01\sql`,
		`d:\Backup\db\x.bak`:        `D:\`,
		`/var/opt/mssql/data/x.bak`: `/var/opt`,
		`/x.bak`:                    `/`,
		`/mnt/nfs/x.bak`:            `/mnt/nfs`,
	} {
		if got := backupPathRoot(p); got != want {
			t.Errorf("root of %s: %s, want %s", p, got, want)
		}
	}
	if got := backupDirOf(`/mnt/old/hdb_diff.bak`); got != "/mnt/old/" {
		t.Errorf("dir: %s", got)
	}
	if got := backupDirOf(`D:\Backup\db\x.bak`); got != `D:\Backup\db\` {
		t.Errorf("dir: %s", got)
	}
	sets := backupFileSetsOf([]collect.Row{
		{"database_name": "a", "backup_type": "full", "backup_set_uuid": "u1", "device_type": int64(2), "path": "/d/a_1.bak"},
		{"database_name": "a", "backup_type": "full", "backup_set_uuid": "u1", "device_type": int64(2), "path": "/d/a_2.bak"},
		{"database_name": "a", "backup_type": "log", "backup_set_uuid": "u2", "device_type": int64(9), "path": "https://acct.blob.core.windows.net/c/a.trn"},
		{"database_name": "b", "backup_type": "full", "backup_set_uuid": "u3", "device_type": int64(2), "path": "NUL"},
		{"database_name": "c", "backup_type": "full", "backup_set_uuid": "u4", "device_type": int64(7), "path": "{4A0C1E3B-1111-2222-3333-444455556666}"},
		{"database_name": "d", "backup_type": "diff", "backup_set_uuid": "u5", "device_type": int64(102), "path": `\\nas\sql\d.bak`},
	})
	got := []string{}
	for _, s := range sets {
		got = append(got, s.db+"/"+s.typ+"/"+strings.Join(s.paths, "+")+"/"+map[bool]string{true: "disk", false: "not disk"}[s.disk])
	}
	want := "a/full//d/a_1.bak+/d/a_2.bak/disk ;; a/log/https://acct.blob.core.windows.net/c/a.trn/not disk ;; b/full/NUL/not disk ;; c/full/{4A0C1E3B-1111-2222-3333-444455556666}/not disk ;; d/diff/\\\\nas\\sql\\d.bak/disk"
	if strings.Join(got, " ;; ") != want {
		t.Errorf("the sets:\n got %s\nwant %s", strings.Join(got, " ;; "), want)
	}
}

// TestBackupFileCheckOffWithoutPool: the file check stays off until the WIRING patch hands the collector a pool, even
// where the instance opted in.
func TestBackupFileCheckOffWithoutPool(t *testing.T) {
	if backupFileDB(Info{}) != nil {
		t.Error("the file check's pool is set by default")
	}
}
