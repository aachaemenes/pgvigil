package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): task 302's 0148 - the import replaces a read whole, the
// destinations view (read beside entered, 'not known', the managed line), the findings (a credential in the archiver's
// command, WAL discarded, the tool read off), the audited entry with its history and its refusals, and 0103's
// pg_backup_tools taking 'not_read'.
func TestBackupDestOnAStore(t *testing.T) {
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
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name LIKE $1`, fmt.Sprintf("bd-%%-%d", tag)); err != nil {
			t.Error(err)
		}
	}()
	inst := func(n, platform string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '17.2', 170002, false, '{}', 'postgres')`, fmt.Sprintf("bd-%s-%d", n, tag), platform).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	imp := func(fn string, id int, rows []map[string]any) {
		t.Helper()
		b, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.`+fn+`($1, now(), $2::jsonb)`, id, string(b)); err != nil {
			t.Fatalf("%s: %v", fn, err)
		}
	}
	settings := func(mode string) map[string]any {
		return map[string]any{"kind": "settings", "is_replica": false, "archive_mode": mode, "archive_command_set": true, "archive_library_set": false,
			"restore_command_set": true, "standby_archives": true}
	}
	dest := func(source, role string, seq int, tool, kind, container, path, detail string, secret bool) map[string]any {
		return map[string]any{"kind": "dest", "source": source, "role": role, "seq": seq, "tool": tool, "dest_kind": kind, "container": container,
			"path": path, "detail": detail, "secret_seen": secret}
	}
	a := inst("a", "onprem")
	imp("import_backup_dest", a, []map[string]any{settings("on"),
		dest("archive_command", "wal", 1, "pgbackrest", "", "", "", "stanza demo: the repository is in pgBackRest's configuration", true),
		dest("archive_command", "base", 1, "pgbackrest", "", "", "", "stanza demo (base backups go where its WAL goes)", true),
		dest("restore_command", "restore", 1, "pgbackrest", "", "", "", "stanza demo", false),
		{"kind": "read", "tool": "pgbackrest", "name": "demo", "state": "off", "message": "not read: the tool read is off"}})
	view := func(id int, role string) (read, known, entered string, beside bool) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT coalesce(read_text, ''), coalesce(not_known, ''), coalesce(entered_text, ''), entered_beside_read
			FROM pgvigil.pg_backup_destinations WHERE instance_id = $1 AND role = $2`, id, role).Scan(&read, &known, &entered, &beside); err != nil {
			t.Fatalf("the view, %s: %v", role, err)
		}
		return
	}
	if r, _, _, _ := view(a, "wal"); !strings.HasPrefix(r, "pgbackrest - stanza demo") || !strings.HasSuffix(r, "[archive_command]") {
		t.Errorf("WAL to: %q", r)
	}
	findings := func(id int) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(severity || ':' || check_name || ':' || object, ' | ' ORDER BY check_name, object), '')
			FROM pgvigil.pg_backup_dest_findings WHERE instance_id = $1`, id).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	if f := findings(a); f != "warning:a credential is written in the archiver's command:archive_command | info:backup tool read off:pgbackrest demo" {
		t.Errorf("a's findings: %q", f)
	}
	// the entry: shown beside the read value, history kept, refusals
	entry := func(role, text, note string) error {
		_, err := pool.Exec(ctx, `SELECT pgvigil.import_backup_dest_entry($1, $2, $3, $4, 'tester')`, a, role, text, note)
		return err
	}
	if err := entry("base", "the NFS share backup1:/srv/pg", "weekly, by the storage team"); err != nil {
		t.Fatal(err)
	}
	if err := entry("base", "backup1:/srv/pg2", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, e, beside := view(a, "base"); e != "backup1:/srv/pg2" || !beside {
		t.Errorf("the entry in force: %q beside %v", e, beside)
	}
	var hist, open int
	if err := pool.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE ended_at IS NULL) FROM pgvigil.pg_backup_dest_entered WHERE instance_id = $1`, a).Scan(&hist, &open); err != nil || hist != 2 || open != 1 {
		t.Errorf("the history: %d rows, %d in force (%v)", hist, open, err)
	}
	for _, bad := range []string{"https://user:hunter2@files/x", "https://acct.blob.core.windows.net/c?sv=1&sig=abc", "password=hunter2 on the share", "a\x01b", strings.Repeat("x", 501)} {
		if err := entry("wal", bad, ""); err == nil {
			t.Errorf("the entry %q was taken", bad)
		}
	}
	if err := entry("base", "", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, e, _ := view(a, "base"); e != "" {
		t.Errorf("an empty entry did not end the one in force: %q", e)
	}
	// a read without its settings row changes nothing; the next read replaces the destinations whole
	imp("import_backup_dest", a, []map[string]any{dest("archive_command", "wal", 1, "copy", "posix", "", "/x", "", false)})
	if r, _, _, _ := view(a, "wal"); !strings.Contains(r, "pgbackrest") {
		t.Errorf("a read without settings changed the destinations: %q", r)
	}
	imp("import_backup_dest", a, []map[string]any{settings("on"), dest("archive_command", "wal", 1, "copy", "discard", "", "", "WAL is discarded: the command copies to /dev/null", false)})
	if r, _, _, _ := view(a, "base"); r != "" {
		t.Errorf("the base row stayed: %q", r)
	}
	if _, k, _, _ := view(a, "base"); k != "not known" {
		t.Errorf("base backups with nothing read: %q", k)
	}
	if f := findings(a); f != "warning:WAL is discarded:archive_command" {
		t.Errorf("a's findings after the discard: %q", f)
	}
	// 0103's tools table takes 'not_read'
	imp("import_backup_tools", a, []map[string]any{{"kind": "detect", "is_replica": false, "archive_mode": "on", "archive_command_set": true, "tools": 1},
		{"kind": "tool", "tool": "pgbackrest", "name": "demo", "named_by": "archive_command", "state": "not_read", "message": "not read: the tool read is off"}})
	var st string
	if err := pool.QueryRow(ctx, `SELECT state FROM pgvigil.pg_backup_tools WHERE instance_id = $1`, a).Scan(&st); err != nil || st != "not_read" {
		t.Errorf("pg_backup_tools state: %q (%v)", st, err)
	}
	// RDS: the service's line
	r := inst("r", "rds")
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.backup_state (instance_id, kind, name, snapshot_at, retention_days, earliest_restorable_time, latest_restorable_time, backup_window)
		VALUES ($1, 'cloud', 'db1', now(), 7, '2026-11-07 03:00+00', '2026-11-14 03:00+00', '03:00-03:30')`, r); err != nil {
		t.Fatal(err)
	}
	var line string
	if err := pool.QueryRow(ctx, `SELECT coalesce(platform_line, '') FROM pgvigil.pg_backup_destinations WHERE instance_id = $1 AND role = 'base'`, r).Scan(&line); err != nil ||
		line != "kept by RDS: automated backups, retention 7 days, restorable 2026-11-07 03:00 to 2026-11-14 03:00 UTC, window 03:00-03:30" {
		t.Errorf("the RDS line: %q (%v)", line, err)
	}
}
