package mssql

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestBackupCheckDBRows: sys.databases decides which databases' recovery status is read (task 301b
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
		{"database_id": int64(12), "database_name": "agm", "state": "ONLINE", "recovery_model": "FULL", "is_auto_close_on": int64(0), "is_snapshot": int64(0), "is_standby": int64(0), "is_secondary": int64(2)},
	}
	want := map[string]string{
		"app": "read", "ac": "not read: AUTO_CLOSE (reading would open it)", "off": "not judged: the database is offline",
		"snap": "not judged: a database snapshot", "ls": "not judged: a standby database (restoring logs)",
		"sec": "not judged: a secondary replica", "rst": "not judged: the database is restoring",
		"agm": "not judged: availability group role not readable (VIEW SERVER STATE)",
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

// TestBackupHistorySQLReadsOnly: every statement the two collections send reads - 301b's own and 301's / 301c's they
// call (the databases, the 2022 column, the newest set and its mark, msdb's right, 301c's gate); none writes, backs
// up, restores or calls xp_fileexist (it answers 0 / 0 / 0 to a login that is not sysadmin: probe 301bP1); the one
// EXEC is xp_instance_regread behind 301c's gate. The newest N and M are decision E2.
func TestBackupHistorySQLReadsOnly(t *testing.T) {
	texts := map[string]string{
		"sets": backupSetHistorySQL(true), "sets 2019": backupSetHistorySQL(false), "restores": restoreHistorySQL,
		"right": restoreRightSQL, "newest": restoreNewestSQL, "mark": restoreMarkSQL, "dbs": backupCheckDBsSQL(groupsDMV),
		"dbs no hadr": backupCheckDBsSQL(groupsNone), "dbs member": backupCheckDBsSQL(groupsMember), "recovery": backupRecoverySQL,
		"path": backupPathSQL, "path reg": backupPathRegSQL, "exists": backupExistsSQL, "file sets": backupFileSetsSQL,
		"301 dbs": backupDatabasesSQL(true), "301 dbs no hadr": backupDatabasesSQL(false), "301 has2022": backupHas2022SQL,
		"301 newest": backupNewestSQL, "301 mark": backupMarkSQL, "msdb right": "SELECT HAS_PERMS_BY_NAME(N'msdb.dbo.backupset', 'OBJECT', 'SELECT')",
		"301c gate": propsGateSQL,
	}
	verb := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|BACKUP|RESTORE|GRANT|DENY|REVOKE)\s`)
	for name, q := range texts {
		if m := verb.FindString(q); m != "" {
			t.Errorf("%s: a write-shaped word %q", name, m)
		}
		if strings.Contains(strings.ToLower(q), "xp_fileexist") {
			t.Errorf("%s: calls xp_fileexist", name)
		}
		// EXEC as a statement (EXEC / EXECUTE then a name), not the permission's name in HAS_PERMS_BY_NAME(..., 'EXECUTE')
		if name != "path reg" && regexp.MustCompile(`(?i)\bEXEC(UTE)?\s`).MatchString(q) {
			t.Errorf("%s: an EXEC", name)
		}
	}
	if !strings.Contains(backupSetHistorySQL(true), "r.rn <= 10") || !strings.Contains(restoreHistorySQL, "r.rn <= 20") {
		t.Error("the newest 10 sets / 20 restores are not the statements' bounds")
	}
	if !strings.Contains(backupSetHistorySQL(true), "bs.compression_algorithm") || strings.Contains(backupSetHistorySQL(false), "bs.compression_algorithm") {
		t.Error("compression_algorithm is read only where msdb has it (2022)")
	}
	// the file sets keep only sets kept somewhere, as the history (a BACKUP LOG to NUL is not the newest log)
	if !strings.Contains(backupFileSetsSQL, backupSinkExpr+" = 'backup'") {
		t.Error("the file sets do not filter on the sink")
	}
	// without VIEW SERVER STATE the group DMV is never named (it needs the right); sys.databases' replica_id is
	if strings.Contains(backupCheckDBsSQL(groupsMember), "dm_hadr") || !strings.Contains(backupCheckDBsSQL(groupsMember), "d.replica_id") {
		t.Error("groupsMember reads the DMV or not replica_id")
	}
}

// TestBackupGroupsRead: the group DMV only with VIEW SERVER STATE (as indexes.go's gate), else sys.databases' replica_id.
func TestBackupGroupsRead(t *testing.T) {
	for _, c := range []struct {
		info Info
		want int
	}{{Info{}, groupsNone}, {Info{HADREnabled: true, ViewServerState: true}, groupsDMV}, {Info{HADREnabled: true}, groupsMember}} {
		if got := backupGroupsRead(c.info); got != c.want {
			t.Errorf("%+v: %d, want %d", c.info, got, c.want)
		}
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
		{"database_name": "e", "backup_type": "full", "backup_set_uuid": "u6", "device_type": int64(5), "path": `\\.\Tape0`},
	})
	got := []string{}
	for _, s := range sets {
		got = append(got, s.db+"/"+s.typ+"/"+strings.Join(s.paths, "+")+"/"+map[bool]string{true: "disk", false: "not disk"}[s.disk])
	}
	want := "a/full//d/a_1.bak+/d/a_2.bak/disk ;; a/log/https://acct.blob.core.windows.net/c/a.trn/not disk ;; b/full/NUL/not disk ;; c/full/{4A0C1E3B-1111-2222-3333-444455556666}/not disk ;; d/diff/\\\\nas\\sql\\d.bak/disk ;; e/full/\\\\.\\Tape0/not disk"
	if strings.Join(got, " ;; ") != want {
		t.Errorf("the sets:\n got %s\nwant %s", strings.Join(got, " ;; "), want)
	}
}

// TestBackupFileCheckOffWithoutPool: without the WIRING patch the file check has no pool (it stays off) - an
// instance that opted in included: backupFileDB takes nothing from Info until the patch sets it.
func TestBackupFileCheckOffWithoutPool(t *testing.T) {
	for _, info := range []Info{{}, {Major: 16, HADREnabled: true, ViewServerState: true}} {
		if backupFileDB(info) != nil {
			t.Errorf("%+v: the file check's pool is set by default", info)
		}
	}
}

// TestBackupFilePoolIsItsOwn (run 301bp4's red H3): the file check's pool is its own - more than one connection and
// none kept idle (each Conn a fresh short-lived one) - never RunOnce's, which Connect caps at the collection's one.
// Opening it parses the DSN only; nothing is dialled.
func TestBackupFilePoolIsItsOwn(t *testing.T) {
	db, err := openBackupFilePool(context.Background(), config.Instance{DSNRaw: "sqlserver://pgv:secret@127.0.0.1:1?database=master"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	if got := db.Stats().MaxOpenConnections; got != backupFilePoolConns || got < 2 {
		t.Errorf("the file check's pool takes %d connections, want %d", got, backupFilePoolConns)
	}
	if _, err := openBackupFilePool(context.Background(), config.Instance{}); err == nil {
		t.Error("an empty DSN opened a pool")
	}
}

// TestCappedConnHoldsDeadlines: a deadline the driver sets later never goes past the connection's end (a cleared
// deadline is the end too).
func TestCappedConnHoldsDeadlines(t *testing.T) {
	end := time.Now().Add(time.Minute)
	c := &cappedConn{until: end}
	if !c.held(time.Time{}).Equal(end) || !c.held(end.Add(time.Hour)).Equal(end) {
		t.Error("a cleared or later deadline is not held to the end")
	}
	if early := end.Add(-time.Second); !c.held(early).Equal(early) {
		t.Error("an earlier deadline is not kept")
	}
}

// TestBackupFileStates: the file check's states (F3, F5) without a server: an answered missing file 'gone', its
// missing folder 'folder gone', a root that did not answer 'not judged' with its words; a striped set asks every
// family whose root answered and takes the worst (an answered missing stripe beats a dead root's); the budget's end
// and a refusal 'not judged'; a NULL answer is never 'folder gone'; no connection keeps every row, 'not judged'.
func TestBackupFileStates(t *testing.T) {
	sets := []*backupFileSet{
		{db: "ok", typ: "full", uuid: "u1", disk: true, paths: []string{"/b/x/ok_1.bak", "/b/x/ok_2.bak"}},
		{db: "gone", typ: "full", uuid: "u2", disk: true, paths: []string{"/b/x/gone.bak"}},
		{db: "dir", typ: "log", uuid: "u3", disk: true, paths: []string{"/b/old/dir.trn"}},
		{db: "stripe", typ: "full", uuid: "u4", disk: true, paths: []string{`\\nasa\sql\s_1.bak`, `\\nasb\sql\s_2.bak`}},
		{db: "dead", typ: "full", uuid: "u5", disk: true, paths: []string{`\\nasa\sql\d.bak`}},
		{db: "late", typ: "full", uuid: "u6", disk: true, paths: []string{"/b/x/late.bak"}},
		{db: "ref", typ: "full", uuid: "u7", disk: true, paths: []string{"/b/x/ref.bak"}},
		{db: "url", typ: "log", uuid: "u8", disk: false, paths: []string{"https://a.blob.core.windows.net/c/u.trn"}},
		{db: "worst", typ: "full", uuid: "u9", disk: true, paths: []string{"/b/x/w_1.bak", "/b/old/w_2.bak", "/b/x/w_3.bak"}},
		{db: "null", typ: "full", uuid: "u10", disk: true, paths: []string{"/b/x/null.bak"}},
	}
	roots := map[string]string{"/b/x": "", "/b/old": "", `\\nasa\sql`: `not judged: \\nasa\sql did not answer`, `\\nasb\sql`: ""}
	asked := map[string]bool{}
	exists := func(p string) (int64, int64, error) {
		asked[p] = true
		switch p {
		case "/b/x/gone.bak", `\\nasb\sql\s_2.bak`, "/b/x/w_3.bak":
			return 0, 1, nil
		case "/b/old/dir.trn", "/b/old/w_2.bak":
			return 0, 0, nil
		case "/b/x/late.bak":
			return 0, 0, errBackupBudget
		case "/b/x/ref.bak", "/b/x/null.bak":
			return 0, 0, errors.New("refused")
		}
		return 1, 1, nil
	}
	want := map[string]string{
		"ok":     "present||/b/x/ok_1.bak",
		"gone":   "gone|the file is gone|/b/x/gone.bak",
		"dir":    "folder gone|the folder /b/old/ is gone|/b/old/dir.trn",
		"stripe": `gone|the file is gone|\\nasb\sql\s_2.bak`,
		"dead":   `not judged|not judged: \\nasa\sql did not answer|\\nasa\sql\d.bak`,
		"late":   "not judged|not judged: the read's 60-second budget ran out|/b/x/late.bak",
		"ref":    "not judged|not judged: the existence check was refused|/b/x/ref.bak",
		"url":    "not judged|not checked: not a disk path|https://a.blob.core.windows.net/c/u.trn",
		"worst":  "folder gone|the folder /b/old/ is gone|/b/old/w_2.bak",
		"null":   "not judged|not judged: the existence check was refused|/b/x/null.bak",
	}
	check := func(label string, rows []collect.Row, want map[string]string) {
		t.Helper()
		if len(rows) != len(sets) {
			t.Fatalf("%s: %d rows, want %d (one per set)", label, len(rows), len(sets))
		}
		for _, r := range rows {
			db := r["database_name"].(string)
			if got := fmt.Sprintf("%v|%v|%v", r["state"], r["detail"], r["path"]); got != want[db] {
				t.Errorf("%s: %s -> %s, want %s", label, db, got, want[db])
			}
		}
	}
	check("answered", backupFileStates(sets, roots, exists), want)
	if asked[`\\nasa\sql\s_1.bak`] || asked[`\\nasa\sql\d.bak`] {
		t.Error("a path under a root that did not answer was asked")
	}
	if !asked[`\\nasb\sql\s_2.bak`] || !asked["/b/x/w_3.bak"] {
		t.Error("a striped set's later family was not asked")
	}
	// no connection for the file check: every row kept, the disk ones 'not judged' with the words (a dead root's own)
	noConn := map[string]string{}
	for _, s := range sets {
		switch {
		case !s.disk:
			noConn[s.db] = want[s.db]
		case s.db == "dead" || s.db == "stripe":
			noConn[s.db] = `not judged|not judged: \\nasa\sql did not answer|` + s.paths[0]
		default:
			noConn[s.db] = "not judged|not judged: no connection for the file check|" + s.paths[0]
		}
	}
	check("no connection", backupFileStates(sets, roots, nil), noConn)
}

// TestDefaultBackupPathManagedNotRead: a managed platform's default backup path is never read - no statement, no gate
// (F11; properties.go's rule: the registry is never read on a managed service) - and 2016 has its own words.
func TestDefaultBackupPathManagedNotRead(t *testing.T) {
	gate := func() propGate { t.Error("the gate was asked"); return propGate{} }
	for _, info := range []Info{{Kind: KindAzureMI, Major: 12}, {Kind: KindRDS, Major: 14}, {Kind: KindRDS, Major: 16}, {Kind: KindCloudSQL, Major: 15}, {Major: 13}} {
		// a nil connection: any read would panic
		if p, why := defaultBackupPath(context.Background(), nil, info, gate); p != "" || why == "" {
			t.Errorf("%s %d: path %q, why %q", info.Kind, info.Major, p, why)
		}
	}
}

// TestCursorFromWithoutStoredCursor: no cursor function, none stored, or a stored 0 is one whole pass (0) and asks
// the server nothing (a nil connection).
func TestCursorFromWithoutStoredCursor(t *testing.T) {
	ctx := context.Background()
	for label, cur := range map[string]SeqCursorFunc{
		"none stored": func(context.Context, string) (int64, bool, error) { return 0, false, nil },
		"stored 0":    func(context.Context, string) (int64, bool, error) { return 0, true, nil },
	} {
		if from, err := cursorFrom(ctx, nil, cur, BackupHistoryCursorSource, BackupHistoryMarkSource, backupMarkSQL); err != nil || from != 0 {
			t.Errorf("%s: from %d, err %v", label, from, err)
		}
	}
	if from, err := cursorFrom(ctx, nil, nil, BackupHistoryCursorSource, BackupHistoryMarkSource, backupMarkSQL); err != nil || from != 0 {
		t.Errorf("no cursor: from %d, err %v", from, err)
	}
}
