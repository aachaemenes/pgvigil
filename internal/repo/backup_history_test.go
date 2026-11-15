package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): stubbed reads of mssql_backup_history and
// mssql_backup_checks through their imports (task 301b, migration 0191; the design fold's F1, F4-F6, F10, F12, the
// probes' facts and the lead's AUTO_CLOSE rule): the newest N sets per database, type and copy-only, 0066's two guards,
// the cursor (through the joined tree's mssql_hadr_cursor, scripts/inv-301b-joined-cursor.sql) and a database listed
// again, the newest M restores per destination and restore type, a restore read without the right, the three findings
// and the cells that are not judged or not read, and actions_log taking verify_backup with its three new outcomes.
//
// The payloads (the collector internal/mssql/backup_history.go sends them):
//
//	mssql_backup_history: 'database' {database_name, created_utc}; 'set' {database_name, backup_type full|diff|log,
//	  is_copy_only, backup_set_id, backup_set_uuid, start_utc, finish_utc, size_bytes, compressed_bytes, recovery_model,
//	  user_name, machine_name, server_name, set_name, has_checksums, is_damaged, is_password_protected, key_algorithm,
//	  compression_algorithm, family_count, position, device_kind, path, first_lsn, last_lsn, checkpoint_lsn,
//	  database_backup_lsn, differential_base_guid}; 'restore' {restore_history_id, restore_utc, destination_database_name,
//	  user_name, restore_type, replace, recovery, stop_at_utc, source_server, source_database, source_type,
//	  source_finish_utc, source_backup_set_uuid, source_path}; one 'read' {from_set_id, restore_read read|no right};
//	  'cursor' {source backup_history|restore_history, last_id, mark}.
//	mssql_backup_checks: 'database' {database_name, recovery_model, lsn_state read|not read: ...|not judged: ...,
//	  last_log_backup_lsn}; 'file' {database_name, backup_type, backup_set_uuid, path, state present|gone|folder gone|
//	  not judged, detail}; one 'files_read' {state read|not read: ...}; one 'default_path' {path, state directory|gone|
//	  not judged, detail}.
func TestBackupHistoryOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tag := time.Now().UnixNano() % 1000000000
	name := func(s string) string { return fmt.Sprintf("bkhist-%s-%d", s, tag) }
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name LIKE $1`, fmt.Sprintf("bkhist-%%-%d", tag)); err != nil {
			t.Error(err)
		}
	}()
	inst := func(n string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}', 'sqlserver')`, name(n)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	one := func(q string, args ...any) string {
		t.Helper()
		var s *string
		if err := pool.QueryRow(ctx, q, args...).Scan(&s); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		if s == nil {
			return "<nil>"
		}
		return *s
	}
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).Format(time.RFC3339) }
	db := func(n string, created time.Duration) map[string]any {
		return map[string]any{"kind": "database", "database_name": n, "state": "ONLINE", "recovery_model": "FULL", "created_utc": at(created),
			"is_snapshot": 0, "is_read_only": 0, "is_standby": 0}
	}
	set := func(dbn, typ string, copyOnly bool, id int64, finish time.Duration) map[string]any {
		return map[string]any{"kind": "set", "database_name": dbn, "backup_type": typ, "is_copy_only": map[bool]int{false: 0, true: 1}[copyOnly],
			"backup_set_id": id, "backup_set_uuid": fmt.Sprintf("00000000-0000-0000-0001-%012d", id), "start_utc": at(finish - time.Minute),
			"finish_utc": at(finish), "size_bytes": 1000, "compressed_bytes": 400, "recovery_model": "FULL", "user_name": "sa",
			"machine_name": "box1", "server_name": "box1", "set_name": nil, "has_checksums": 1, "is_damaged": 0, "is_password_protected": 0,
			"key_algorithm": "NO_Encryption", "compression_algorithm": nil, "family_count": 1, "position": 1, "device_kind": "disk",
			"path": fmt.Sprintf("/var/opt/mssql/data/%s_%s_%d.bak", dbn, typ, id), "first_lsn": fmt.Sprintf("%d00000001", id),
			"last_lsn": fmt.Sprintf("%d00000009", id), "checkpoint_lsn": fmt.Sprintf("%d00000001", id), "database_backup_lsn": "0",
			"differential_base_guid": nil}
	}
	restore := func(id int64, when time.Duration, dest, typ string, src int64) map[string]any {
		return map[string]any{"kind": "restore", "restore_history_id": id, "restore_utc": at(when), "destination_database_name": dest,
			"user_name": "sa", "restore_type": typ, "replace": 0, "recovery": 1, "stop_at_utc": nil, "source_server": "box1",
			"source_database": "hdb", "source_type": "D", "source_finish_utc": at(-48 * time.Hour),
			"source_backup_set_uuid": fmt.Sprintf("00000000-0000-0000-0001-%012d", src), "source_path": "/var/opt/mssql/data/hdb_full.bak"}
	}
	read := func(from int64, restores string) map[string]any {
		return map[string]any{"kind": "read", "from_set_id": from, "restore_read": restores}
	}
	cursor := func(source string, last, mark int64) map[string]any {
		return map[string]any{"kind": "cursor", "source": source, "last_id": last, "mark": mark}
	}
	history := func(id int, rows bkRows) {
		t.Helper()
		exec(`SELECT pgvigil.import_mssql_backup_history($1, $2, $3::jsonb)`, id, now, rows.json(t))
	}
	count := func(id int, where string) string {
		t.Helper()
		return one(`SELECT count(*)::text FROM pgvigil.mssql_backup_history WHERE instance_id = $1 AND `+where, id)
	}

	// RED before 0191: the history import does not exist on a store of 128 migrations.
	a := inst("a")
	rows := bkRows{db("hdb", -30*24*time.Hour), db("other", -30*24*time.Hour)}
	for i := int64(1); i <= 12; i++ {
		rows = append(rows, set("hdb", "full", false, i, time.Duration(i-13)*time.Hour), set("hdb", "log", false, 100+i, time.Duration(i-13)*time.Hour+time.Minute))
	}
	rows = append(rows, set("hdb", "diff", false, 50, -90*time.Minute), set("hdb", "full", true, 51, -80*time.Minute),
		// 0066's rules: a database the read does not list, and a set that finished before its database was created
		set("gone", "full", false, 60, -2*time.Hour), set("other", "full", false, 61, -31*24*time.Hour),
		read(0, "read"), cursor("backup_history", 112, 7), cursor("restore_history", 0, 0))
	history(a, rows)

	// ---- H1: N = 10 per database, type and copy-only, newest first; the oldest two of each pruned
	for _, c := range []struct{ where, want string }{
		{`database_name = 'hdb' AND backup_type = 'D' AND NOT is_copy_only`, "10"},
		{`database_name = 'hdb' AND backup_type = 'L'`, "10"},
		{`database_name = 'hdb' AND backup_type = 'I'`, "1"},
		{`database_name = 'hdb' AND backup_type = 'D' AND is_copy_only`, "1"},
		{`backup_set_id IN (1, 2, 101, 102)`, "0"},
		{`database_name = 'gone'`, "0"},
		{`database_name = 'other'`, "0"},
	} {
		if got := count(a, c.where); got != c.want {
			t.Errorf("H1 history %s: %s rows, want %s", c.where, got, c.want)
		}
	}
	if got := one(`SELECT min(backup_set_id)::text || '-' || max(backup_set_id)::text FROM pgvigil.mssql_backup_history WHERE instance_id = $1 AND backup_type = 'D' AND NOT is_copy_only`, a); got != "3-12" {
		t.Errorf("H1 the fulls kept: %s, want 3-12", got)
	}
	if got := one(`SELECT path || '|' || device_kind || '|' || last_lsn || '|' || `+utcText("finish_at")+` FROM pgvigil.mssql_backup_history WHERE instance_id = $1 AND backup_set_id = 12`, a); got != fmt.Sprintf("/var/opt/mssql/data/hdb_full_12.bak|disk|1200000009|%s", now.Add(-time.Hour).Format("2006-01-02 15:04:05")) {
		t.Errorf("H1 set 12: %s", got)
	}

	// ---- the cursor, through the joined tree's mssql_hadr_cursor (the join takes 0191's two arms)
	joined, err := os.ReadFile("../../scripts/inv-301b-joined-cursor.sql")
	if err != nil {
		t.Fatal(err)
	}
	// the store is shared: the function this test replaces is put back after it (on the joined tree 0300's holds
	// other branches' arms, 0145's azdb_since among them, that the file's 0140-plus-arm text does not)
	var before string
	if err := pool.QueryRow(ctx, `SELECT pg_get_functiondef('pgvigil.mssql_hadr_cursor(int, text)'::regprocedure)`).Scan(&before); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := pool.Exec(context.Background(), before); err != nil {
			t.Errorf("mssql_hadr_cursor not put back: %v", err)
		}
	})
	exec(string(joined))
	for src, want := range map[string]string{"backup_history": "112", "backup_history_mark": "7", "restore_history": "0", "restore_history_mark": "0", "backup_sets": "<nil>"} {
		if got := one(`SELECT pgvigil.mssql_hadr_cursor($1, $2)::text`, a, src); got != want {
			t.Errorf("cursor %s: %s, want %s", src, got, want)
		}
	}
	// a cursor read with one more log: still 10 logs, the newest in, the oldest out
	history(a, bkRows{db("hdb", -30*24*time.Hour), db("other", -30*24*time.Hour), set("hdb", "log", false, 113, -time.Minute),
		read(112, "read"), cursor("backup_history", 113, 8), cursor("restore_history", 0, 0)})
	if got := one(`SELECT count(*)::text || '|' || min(backup_set_id)::text || '|' || max(backup_set_id)::text FROM pgvigil.mssql_backup_history WHERE instance_id = $1 AND backup_type = 'L'`, a); got != "10|104|113" {
		t.Errorf("H1 a cursor read of one more log: %s, want 10|104|113", got)
	}
	if got := one(`SELECT pgvigil.mssql_hadr_cursor($1, 'backup_history')::text`, a); got != "113" {
		t.Errorf("cursor after the second read: %s, want 113", got)
	}
	// a database listed again on a cursor read: the cursor goes to 0 (the next read is one whole pass, 301's F7)
	history(a, bkRows{db("hdb", -30*24*time.Hour), db("other", -30*24*time.Hour), db("back", -40*24*time.Hour),
		read(113, "read"), cursor("backup_history", 113, 8), cursor("restore_history", 0, 0)})
	if got := one(`SELECT pgvigil.mssql_hadr_cursor($1, 'backup_history')::text`, a); got != "0" {
		t.Errorf("a database listed again: the cursor %s, want 0", got)
	}
	// a database created anew under its old name loses the sets stored for the old one - those that finished more than
	// 0066's hour of slack before its creation; the five within the hour (full 12, the diff, the copy-only full, logs
	// 112 and 113) stay by that rule
	history(a, bkRows{db("hdb", -30*time.Minute), db("other", -30*24*time.Hour), db("back", -40*24*time.Hour),
		read(0, "read"), cursor("backup_history", 113, 8), cursor("restore_history", 0, 0)})
	if got := one(`SELECT string_agg(backup_set_id::text, ',' ORDER BY backup_set_id) FROM pgvigil.mssql_backup_history WHERE instance_id = $1 AND database_name = 'hdb'`, a); got != "12,50,51,112,113" {
		t.Errorf("a database created anew: the sets kept %s, want 12,50,51,112,113 (the hour of slack)", got)
	}

	// ---- H2: M = 20 restores per destination and restore type, newest first; the server's local time stored as UTC
	b := inst("b")
	rows = bkRows{db("hdb", -30*24*time.Hour), read(0, "read"), cursor("backup_history", 0, 0)}
	for i := int64(1); i <= 22; i++ {
		rows = append(rows, restore(i, time.Duration(i-23)*time.Hour, "r1", "D", 5))
	}
	rows = append(rows, restore(30, -10*time.Minute, "r1", "L", 6), restore(31, -5*time.Minute, "r2", "D", 5), cursor("restore_history", 31, 99))
	history(b, rows)
	for _, c := range []struct{ where, want string }{
		{`destination_database_name = 'r1' AND restore_type = 'D'`, "20"},
		{`destination_database_name = 'r1' AND restore_type = 'L'`, "1"},
		{`destination_database_name = 'r2'`, "1"},
		{`restore_history_id IN (1, 2)`, "0"},
	} {
		if got := one(`SELECT count(*)::text FROM pgvigil.mssql_restore_history WHERE instance_id = $1 AND `+c.where, b); got != c.want {
			t.Errorf("H2 restores %s: %s, want %s", c.where, got, c.want)
		}
	}
	if got := one(`SELECT `+utcText("restore_at")+` || '|' || source_backup_set_uuid::text || '|' || source_path FROM pgvigil.mssql_restore_history WHERE instance_id = $1 AND restore_history_id = 31`, b); got != fmt.Sprintf("%s|00000000-0000-0000-0001-000000000005|/var/opt/mssql/data/hdb_full.bak", now.Add(-5*time.Minute).Format("2006-01-02 15:04:05")) {
		t.Errorf("H2 restore 31: %s", got)
	}
	if got := one(`SELECT pgvigil.mssql_hadr_cursor($1, 'restore_history')::text || '|' || pgvigil.mssql_hadr_cursor($1, 'restore_history_mark')::text`, b); got != "31|99" {
		t.Errorf("H2 the restore cursor: %s, want 31|99", got)
	}
	// a read without SELECT on restorehistory: the state says so, the rows stored stay
	history(b, bkRows{db("hdb", -30*24*time.Hour), read(0, "no right"), cursor("backup_history", 0, 0)})
	if got := one(`SELECT restore_state FROM pgvigil.mssql_backup_history_cursor WHERE instance_id = $1`, b); got != "not read: no right (SELECT on msdb.dbo.restorehistory)" {
		t.Errorf("H2 no right: %s", got)
	}
	if got := one(`SELECT count(*)::text FROM pgvigil.mssql_restore_history WHERE instance_id = $1`, b); got != "22" {
		t.Errorf("H2 no right: %s restores kept, want 22", got)
	}

	// ---- the checks (Database#7, Database#39, Instance#14) and their findings; judged as 0066's view judges
	c := inst("c")
	exec(`SELECT pgvigil.import_mssql_backups($1, $2, $3::jsonb)`, c, now, bkRows{db("hdb", -30*24*time.Hour), db("pfull", -30*24*time.Hour),
		db("pok", -30*24*time.Hour), db("pac", -30*24*time.Hour), db("model", -30*24*time.Hour), db("fresh", -2*time.Hour)}.json(t))
	dbc := func(n, model, state string, lsn any) map[string]any {
		return map[string]any{"kind": "database", "database_name": n, "recovery_model": model, "lsn_state": state, "last_log_backup_lsn": lsn}
	}
	fileOf := func(n, typ, uuid, path, state, detail string) map[string]any {
		return map[string]any{"kind": "file", "database_name": n, "backup_type": typ, "backup_set_uuid": uuid,
			"path": path, "state": state, "detail": detail}
	}
	file := func(n, typ, path, state, detail string) map[string]any {
		return fileOf(n, typ, "00000000-0000-0000-0002-000000000001", path, state, detail)
	}
	checks := func(id int, rows bkRows) {
		t.Helper()
		exec(`SELECT pgvigil.import_mssql_backup_checks($1, $2, $3::jsonb)`, id, now, rows.json(t))
	}
	checks(c, bkRows{
		dbc("pfull", "FULL", "read", nil), dbc("pok", "FULL", "read", "42000000031200001"),
		dbc("pac", "FULL", "not read: AUTO_CLOSE (reading would open it)", nil), dbc("model", "FULL", "read", nil),
		dbc("fresh", "FULL", "read", nil), dbc("hdb", "SIMPLE", "read", nil),
		file("hdb", "full", "/var/opt/mssql/data/hdb_full.bak", "present", ""),
		file("hdb", "log", "/var/opt/mssql/data/hdb_log.trn", "gone", "the file is gone"),
		file("hdb", "diff", "/mnt/old/hdb_diff.bak", "folder gone", "the folder /mnt/old/ is gone"),
		file("pok", "full", `\\nas\sql\pok.bak`, "not judged", `not judged: \\nas\sql did not answer`),
		{"kind": "files_read", "state": "read"},
		{"kind": "default_path", "path": "/var/opt/mssql/nobackup", "state": "gone", "detail": "not a directory the service account sees"},
	})
	got := one(`SELECT string_agg(check_name || '|' || object || '|' || severity, ' ;; ' ORDER BY check_name, object) FROM pgvigil.mssql_backup_check_findings WHERE instance_id = $1`, c)
	want := "backup file missing|hdb (diff)|warning ;; backup file missing|hdb (log)|warning ;; default backup path not reachable|/var/opt/mssql/nobackup|warning ;; pseudo-simple recovery|pfull|warning"
	if got != want {
		t.Errorf("the findings:\n got %s\nwant %s", got, want)
	}
	for _, c2 := range []struct{ q, want string }{
		{`SELECT detail FROM pgvigil.mssql_backup_check_findings WHERE instance_id = $1 AND object = 'pfull'`,
			"FULL, but no log backup can be taken: no full or differential backup since the log chain began"},
		{`SELECT detail FROM pgvigil.mssql_backup_check_findings WHERE instance_id = $1 AND object = 'hdb (log)'`,
			"the newest log backup's file is not where msdb says it was written: /var/opt/mssql/data/hdb_log.trn (the file is gone) - a job may have moved it, or it was deleted"},
		{`SELECT pseudo_simple FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'pac'`,
			"not read: AUTO_CLOSE (reading would open it)"},
		{`SELECT pseudo_simple FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'fresh'`, "not judged: a new database"},
		{`SELECT pseudo_simple FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'model'`, "not judged: model"},
		{`SELECT pseudo_simple FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'pok'`, "no"},
		{`SELECT pseudo_simple FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'hdb'`, "no (SIMPLE)"},
		{`SELECT file_full || ' | ' || file_log || ' | ' || file_diff FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'hdb'`,
			"present | the file is gone | the folder /mnt/old/ is gone"},
		{`SELECT file_full FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'pok'`, `not judged: \\nas\sql did not answer`},
		{`SELECT reachable FROM pgvigil.mssql_backup_path_cells WHERE instance_id = $1`, "no"},
	} {
		if got := one(c2.q, c); got != c2.want {
			t.Errorf("%s:\n got %s\nwant %s", c2.q, got, c2.want)
		}
	}
	// the file check off for the instance (O2: an admin's opt-in): every file cell grey, no file finding; a later read
	// replaces the file rows and the default path's state
	checks(c, bkRows{dbc("pfull", "FULL", "read", nil), {"kind": "files_read", "state": "not read: the file check is off"},
		{"kind": "default_path", "path": "/var/opt/mssql/data", "state": "directory", "detail": "a directory the service account sees (writing not tried)"}})
	if got := one(`SELECT count(*)::text FROM pgvigil.mssql_backup_check_findings WHERE instance_id = $1 AND check_name <> 'pseudo-simple recovery'`, c); got != "0" {
		t.Errorf("the file check off and the path back: %s findings, want 0", got)
	}
	if got := one(`SELECT file_full FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'pfull'`, c); got != "not read: the file check is off" {
		t.Errorf("the file check off: %s", got)
	}
	if got := one(`SELECT default_backup_path || ' | ' || default_backup_path_state || ' | ' || reachable FROM pgvigil.mssql_backup_path_cells WHERE instance_id = $1`, c); got != "/var/opt/mssql/data | a directory the service account sees (writing not tried) | yes" {
		t.Errorf("the default path: %s", got)
	}

	// ---- F6: a group's file finding only on the judged set (the group's newest of its type that is not copy-only, 0140):
	// replica p2's own msdb names its full of a month ago (its file deleted by the cleanup); the group's newest full ran
	// on s2 yesterday. p2's check: no finding, its cell names s2; s2's own judged full gone: the finding.
	p2, s2 := inst("p2"), inst("s2")
	g := fmt.Sprintf("%08x-0000-0000-0000-000000000301", tag)
	agdb := db("agdb", -60*24*time.Hour)
	agdb["ag_group_id"], agdb["ag_name"] = g, "ag301b"
	locSet := func(id int64, finish time.Duration) bkRows {
		return bkRows{{"kind": "set", "database_name": "agdb", "backup_type": "full", "is_copy_only": 0, "backup_set_id": id,
			"backup_set_uuid": fmt.Sprintf("00000000-0000-0000-0003-%012d", id), "finish_utc": at(finish), "start_utc": at(finish - time.Minute),
			"size_bytes": 1000, "compressed_bytes": 400, "has_checksums": 1, "is_damaged": 0, "is_password_protected": 0,
			"key_algorithm": "NO_Encryption", "family_count": 1, "mirror_count": 1, "software_name": "Microsoft SQL Server",
			"user_name": "sa", "checkpoint_lsn": fmt.Sprintf("%d000000001", id), "is_snapshot": 0},
			{"kind": "file", "backup_set_id": id, "family": 1, "mirror": 0, "device_kind": "disk", "path": fmt.Sprintf("/bk/agdb_%d.bak", id)}}
	}
	for _, r := range []struct {
		id   int
		sets bkRows
	}{{p2, locSet(701, -30*24*time.Hour)}, {s2, locSet(711, -24*time.Hour)}} {
		exec(`SELECT pgvigil.import_mssql_backups($1, $2, $3::jsonb)`, r.id, now, bkRows{agdb}.json(t))
		exec(`SELECT pgvigil.import_mssql_backup_files($1, $2, $3::jsonb)`, r.id, now, append(bkRows{agdb}, r.sets...).json(t))
	}
	checks(p2, bkRows{dbc("agdb", "FULL", "read", "42000000031200001"),
		fileOf("agdb", "full", "00000000-0000-0000-0003-000000000701", "/bk/agdb_701.bak", "gone", "the file is gone"),
		{"kind": "files_read", "state": "read"}})
	checks(s2, bkRows{dbc("agdb", "FULL", "read", "42000000031200001"),
		fileOf("agdb", "full", "00000000-0000-0000-0003-000000000711", "/bk/agdb_711.bak", "gone", "the file is gone"),
		{"kind": "files_read", "state": "read"}})
	for _, c3 := range []struct {
		id      int
		q, want string
	}{
		{p2, `SELECT count(*)::text FROM pgvigil.mssql_backup_check_findings WHERE instance_id = $1 AND check_name = 'backup file missing'`, "0"},
		{p2, `SELECT file_full FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'agdb'`, "not judged: a newer full backup ran on " + name("s2")},
		{s2, `SELECT count(*)::text FROM pgvigil.mssql_backup_check_findings WHERE instance_id = $1 AND check_name = 'backup file missing'`, "1"},
		{s2, `SELECT file_full FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'agdb'`, "the file is gone"},
	} {
		if got := one(c3.q, c3.id); got != c3.want {
			t.Errorf("F6 group (%d) %s:\n got %s\nwant %s", c3.id, c3.q, got, c3.want)
		}
	}
	// a read older than the stored one (a one-off collect imported late) changes nothing (0066's mssql_hadr_read)
	exec(`SELECT pgvigil.import_mssql_backup_checks($1, $2, $3::jsonb)`, s2, now.Add(-time.Hour), bkRows{dbc("agdb", "FULL", "read", nil),
		{"kind": "files_read", "state": "not read: the file check is off"}}.json(t))
	if got := one(`SELECT file_full FROM pgvigil.mssql_backup_check_cells WHERE instance_id = $1 AND database_name = 'agdb'`, s2); got != "the file is gone" {
		t.Errorf("a late older read replaced the checks: %s", got)
	}

	// ---- F1: actions_log takes verify_backup (no pid) with its three new outcomes beside 0157's actions
	for _, o := range []string{"started", "done", "failed", "refused", "cut by shutdown", "ended unknown"} {
		exec(`SELECT pgvigil.import_mssql_actions_log($1, $2, $3::jsonb)`, c, now, fmt.Sprintf(`[{"instance_name": %q, "ui_user": "proof", "action": "verify_backup",
			"target": "00000000-0000-0000-0002-000000000001", "reason": "store test", "outcome": %q}]`, name("c"), o))
	}
	exec(`SELECT pgvigil.import_mssql_actions_log($1, $2, $3::jsonb)`, c, now, fmt.Sprintf(`[{"instance_name": %q, "ui_user": "proof", "action": "plan_evict",
		"target": "0x01", "reason": "store test", "outcome": "done"}]`, name("c")))
	if got := one(`SELECT count(*)::text FROM pgvigil.actions_log WHERE instance_id = $1`, c); got != "7" {
		t.Errorf("actions_log: %s rows, want 7", got)
	}
}

// TestJoinedCursor301bIs0140PlusArm: scripts/inv-301b-joined-cursor.sql (the joined tree's mssql_hadr_cursor, applied by
// this branch's store test and proof) is 0140's function plus one arm for 0191's cursor; an edit of 0140's arms is made
// there too, and the join takes the same arm (scripts/inv-301b-join-lines.sql).
func TestJoinedCursor301bIs0140PlusArm(t *testing.T) {
	fn := func(s, what string) string {
		t.Helper()
		i := strings.Index(s, "CREATE OR REPLACE FUNCTION pgvigil.mssql_hadr_cursor(")
		if i < 0 {
			t.Fatalf("%s: no mssql_hadr_cursor", what)
		}
		j := strings.Index(s[i:], "\n$$;")
		if j < 0 {
			t.Fatalf("%s: mssql_hadr_cursor has no end", what)
		}
		return s[i : i+j]
	}
	b, err := migrations.ReadFile("sql/0140_backup_locations.sql")
	if err != nil {
		t.Fatal(err)
	}
	j, err := os.ReadFile("../../scripts/inv-301b-joined-cursor.sql")
	if err != nil {
		t.Fatal(err)
	}
	arm := `    WHEN p_source IN ('backup_history', 'backup_history_mark', 'restore_history', 'restore_history_mark') THEN
      (SELECT CASE p_source WHEN 'backup_history' THEN c.last_set_id WHEN 'backup_history_mark' THEN c.set_mark
                            WHEN 'restore_history' THEN c.last_restore_id ELSE c.restore_mark END
         FROM pgvigil.mssql_backup_history_cursor c WHERE c.instance_id = p_instance_id)
`
	got := fn(string(j), "the joined cursor")
	if strings.Count(got, arm) != 1 {
		t.Fatalf("the joined cursor holds 301b's arm %d times, want once", strings.Count(got, arm))
	}
	if want := fn(string(b), "0140"); strings.Replace(got, arm, "", 1) != want {
		t.Fatalf("the joined cursor is not 0140's plus 301b's arm:\n%s\n--- 0140:\n%s", got, want)
	}
	// the store test and the proof run the whole file: past its leading comment lines it holds the function alone
	var body []string
	lead := true
	for _, l := range strings.Split(strings.TrimSpace(string(j)), "\n") {
		if lead && (strings.HasPrefix(l, "--") || strings.TrimSpace(l) == "") {
			continue
		}
		lead = false
		body = append(body, l)
	}
	if whole := strings.Join(body, "\n"); whole != got+"\n$$;" {
		t.Fatalf("scripts/inv-301b-joined-cursor.sql holds more than the function past its comment lines:\n%s", whole)
	}
	lines, err := os.ReadFile("../../scripts/inv-301b-join-lines.sql")
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range strings.Split(strings.TrimSuffix(arm, "\n"), "\n") {
		if !strings.Contains(string(lines), "--"+l) {
			t.Errorf("the join lines lack the arm's line %q", l)
		}
	}
	// 0191 never replaces the joined function (the JOIN-FILE RULE)
	m, err := migrations.ReadFile("sql/0191_backup_history.sql")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(m), "FUNCTION pgvigil.mssql_hadr_cursor") || strings.Contains(string(m), "VIEW pgvigil.findings") {
		t.Error("0191 replaces a joined object")
	}
}

// utcText renders a timestamptz column as UTC text whatever the store's TimeZone ('2026-11-15 06:00:00').
func utcText(col string) string {
	return "to_char(" + col + " AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')"
}
