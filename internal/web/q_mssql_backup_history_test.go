package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestMSSQLBackupHistoryAPIOnAStore (task 301b): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it)
// /api/mssql/backup_files answers 301b's parts beside 301's: with a database its backup history (newest first, the
// set's last verify from the actions log) and its restore history; with an instance alone the checks' cells, the
// default backup path and the check findings but no history; with no instance the fleet's check findings.
func TestMSSQLBackupHistoryAPIOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	name := fmt.Sprintf("bkhapi-%d", time.Now().UnixNano()%1000000000)
	id, drop := seedBackupLocations(ctx, t, pool, name)
	defer drop()
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).Format(time.RFC3339) }
	uuid := func(n int64) string { return fmt.Sprintf("00000000-0000-0000-0003-%012d", n) }
	set := func(typ string, n int64, finish time.Duration) map[string]any {
		return map[string]any{"kind": "set", "database_name": "lnx", "backup_type": typ, "is_copy_only": 0, "backup_set_id": n,
			"backup_set_uuid": uuid(n), "start_utc": at(finish - 100*time.Second), "finish_utc": at(finish), "size_bytes": 104857600,
			"compressed_bytes": 26214400, "recovery_model": "FULL", "user_name": "sa", "machine_name": "lnx1", "server_name": "lnx1",
			"set_name": nil, "has_checksums": 1, "is_damaged": 0, "is_password_protected": 0, "key_algorithm": "NO_Encryption",
			"compression_algorithm": "MS_XPRESS", "family_count": 1, "position": 1, "device_kind": "disk",
			"path": fmt.Sprintf("/var/opt/mssql/data/lnx_%d.bak", n), "first_lsn": "1", "last_lsn": "9", "checkpoint_lsn": "1",
			"database_backup_lsn": "0", "differential_base_guid": nil}
	}
	history := []map[string]any{
		{"kind": "database", "database_name": "lnx", "created_utc": at(-30 * 24 * time.Hour)},
		{"kind": "database", "database_name": "app", "created_utc": at(-30 * 24 * time.Hour)},
		set("full", 31, -50*time.Hour), set("full", 32, -26*time.Hour), set("log", 33, -time.Hour),
		{"kind": "restore", "restore_history_id": 7, "restore_utc": at(-3 * time.Hour), "destination_database_name": "lnx", "user_name": "sa",
			"restore_type": "D", "replace": 1, "recovery": 1, "stop_at_utc": nil, "source_server": "old1", "source_database": "lnx",
			"source_type": "D", "source_finish_utc": at(-4 * time.Hour), "source_backup_set_uuid": uuid(9), "source_path": "/mnt/in/lnx.bak"},
		{"kind": "read", "from_set_id": 0, "restore_read": "read"},
	}
	checks := []map[string]any{
		{"kind": "database", "database_name": "lnx", "recovery_model": "FULL", "lsn_state": "read", "last_log_backup_lsn": nil},
		{"kind": "database", "database_name": "app", "recovery_model": "FULL", "lsn_state": "read", "last_log_backup_lsn": "42000000001600001"},
		{"kind": "file", "database_name": "lnx", "backup_type": "full", "backup_set_uuid": uuid(32), "path": "/var/opt/mssql/data/lnx_32.bak",
			"state": "gone", "detail": "the file is gone"},
		{"kind": "files_read", "state": "read"},
		{"kind": "default_path", "path": "/var/opt/mssql/data", "state": "directory", "detail": "a directory the service account sees (writing not tried)"},
	}
	for _, c := range []struct {
		fn   string
		rows []map[string]any
	}{{"import_mssql_backup_history", history}, {"import_mssql_backup_checks", checks}} {
		b, err := json.Marshal(c.rows)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `SELECT pgvigil.`+c.fn+`($1, $2, $3::jsonb)`, id, now, string(b)); err != nil {
			t.Fatalf("%s: %v", c.fn, err)
		}
	}
	// two verifies of set 32 (the newest wins), as the door's audit writes them (target_id = the uuid, upper case)
	for i, o := range []string{"started", "done"} {
		row := fmt.Sprintf(`[{"instance_name": %q, "ui_user": "dba1", "action": "verify_backup", "target": "lnx full", "target_id": %q,
			"reason": "api test", "outcome": %q, "detail": "the backup set on file 1 is valid"}]`, name, strings.ToUpper(uuid(32)), o)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_actions_log($1, $2, $3::jsonb)`, id, now.Add(time.Duration(i)*time.Minute), row); err != nil {
			t.Fatal(err)
		}
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}

	// a database: its history newest first, its restores, its checks' cells
	code, p := apiParts(t, s.MSSQLBackupFiles, fmt.Sprintf("/api/mssql/backup_files?instance=%d&db=lnx", id))
	if code != http.StatusOK {
		t.Fatalf("db=lnx: %d", code)
	}
	var hist []string
	for _, r := range p["history"] {
		hist = append(hist, fmt.Sprintf("%v %v %v %v", r["backup_set_id"], r["backup_type"], r["verify_outcome"], r["verify_user"]))
	}
	if got := strings.Join(hist, "; "); got != "33 log <nil> <nil>; 32 full done dba1; 31 full <nil> <nil>" {
		t.Errorf("history: %s", got)
	}
	if len(p["history"]) == 3 {
		r := p["history"][1]
		if got := fmt.Sprintf("%v %.1f %.1f %v %v %v", r["duration_s"], r["mb_s"], r["saving_pct"], r["is_compressed"], r["is_encrypted"], r["backup_set_uuid"]); got != "100 1.0 75.0 true false "+uuid(32) {
			t.Errorf("set 32: %s", got)
		}
	}
	if len(p["restores"]) != 1 || fmt.Sprintf("%v %v %v %v", p["restores"][0]["restore_type"], p["restores"][0]["is_replace"], p["restores"][0]["source_server"], p["restores"][0]["source_type"]) != "D true old1 full" {
		t.Errorf("restores: %v", p["restores"])
	}
	if len(p["checks"]) != 1 || !strings.HasPrefix(fmt.Sprint(p["checks"][0]["pseudo_simple"]), "yes: FULL") || p["checks"][0]["file_full"] != "the file is gone" {
		t.Errorf("checks: %v", p["checks"])
	}
	if len(p["path"]) != 1 || fmt.Sprint(p["path"][0]["default_backup_path"], " ", p["path"][0]["reachable"], " ", p["path"][0]["files_state"], " ", p["path"][0]["restore_state"]) != "/var/opt/mssql/data yes read read" {
		t.Errorf("path: %v", p["path"])
	}
	var found []string
	for _, r := range p["check_findings"] {
		found = append(found, fmt.Sprint(r["check_name"], ": ", r["object"]))
	}
	if got := strings.Join(found, "; "); got != "backup file missing: lnx (full); pseudo-simple recovery: lnx" && got != "pseudo-simple recovery: lnx; backup file missing: lnx (full)" {
		t.Errorf("check findings: %s", got)
	}

	// the instance alone: no history part (a server's whole history is never one answer), every database's cells
	_, p = apiParts(t, s.MSSQLBackupFiles, fmt.Sprintf("/api/mssql/backup_files?instance=%d", id))
	if _, ok := p["history"]; ok {
		t.Errorf("no database asked, yet a history part")
	}
	if _, ok := p["restores"]; ok {
		t.Errorf("no database asked, yet a restores part")
	}
	if len(p["checks"]) != 2 || p["checks"][0]["database_name"] != "app" || p["checks"][0]["pseudo_simple"] != "no" {
		t.Errorf("checks of the instance: %v", p["checks"])
	}

	// the fleet: the check findings of every active instance
	_, p = apiParts(t, s.MSSQLBackupFiles, "/api/mssql/backup_files")
	n := 0
	for _, r := range p["check_findings"] {
		if fmt.Sprint(r["instance_id"]) == fmt.Sprint(id) {
			n++
		}
	}
	if n != 2 {
		t.Errorf("the fleet's check findings of this instance: %d, want 2", n)
	}
}
