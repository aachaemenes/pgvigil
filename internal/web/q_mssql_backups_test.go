package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// seedBackupLocations stores, through the two import functions, one SQL Server instance's read of mssql_backups and
// mssql_backup_files: 'app' with a full striped over two files of a share, a copy-only full to D:\temp, a log by two
// logins to one share; 'lnx' with a full in its data directory (a same-volume finding) and log backups to two
// destinations. It returns the instance and a func that removes it.
func seedBackupLocations(t *testing.T, ctx context.Context, pool *pgxpool.Pool, name string) (int, func()) {
	t.Helper()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	drop := func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}
	now := time.Now().UTC().Truncate(time.Second)
	at := func(d time.Duration) string { return now.Add(d).Format(time.RFC3339) }
	db := func(n string) map[string]any {
		return map[string]any{"kind": "database", "database_name": n, "state": "ONLINE", "recovery_model": "FULL", "created_utc": at(-30 * 24 * time.Hour),
			"is_snapshot": 0, "is_read_only": 0, "is_standby": 0}
	}
	set := func(dbn, typ string, copyOnly int, sid int64, finish time.Duration, families int, alg string) map[string]any {
		return map[string]any{"kind": "set", "database_name": dbn, "backup_type": typ, "is_copy_only": copyOnly, "backup_set_id": sid,
			"backup_set_uuid": fmt.Sprintf("00000000-0000-0000-0000-%012d", sid), "finish_utc": at(finish), "start_utc": at(finish - 2*time.Minute),
			"duration_s": 120, "size_bytes": 2097152000, "compressed_bytes": 524288000, "has_checksums": 1, "is_damaged": 0, "is_password_protected": 0,
			"key_algorithm": "NO_Encryption", "compression_algorithm": alg, "family_count": families, "mirror_count": 1, "software_name": "Microsoft SQL Server",
			"user_name": "svc_sql", "machine_name": "SRV01", "set_name": dbn + " " + typ, "description": "nightly", "recovery_model": "FULL"}
	}
	file := func(sid int64, family int, path string) map[string]any {
		return map[string]any{"kind": "file", "backup_set_id": sid, "family": family, "mirror": 0, "device_kind": "disk", "path": path}
	}
	dbfile := func(sid int64, path string) map[string]any {
		return map[string]any{"kind": "dbfile", "backup_set_id": sid, "file_number": 1, "file_type": "D", "physical_name": path}
	}
	writer := func(dbn, kind, dir, user string, n int) map[string]any {
		return map[string]any{"kind": "writer", "database_name": dbn, "device_kind": kind, "directory": dir, "user_name": user, "sets": n,
			"first_utc": at(-6 * 24 * time.Hour), "last_utc": at(-time.Hour)}
	}
	dbs := []map[string]any{db("app"), db("lnx")}
	rows := append([]map[string]any{}, dbs...)
	rows = append(rows,
		set("app", "full", 0, 11, -26*time.Hour, 2, "MS_XPRESS"), file(11, 1, `\\nas01\sql\app\app_1.bak`), file(11, 2, `\\nas01\sql\app\app_2.bak`), dbfile(11, `D:\data\app.mdf`),
		set("app", "full", 1, 12, -2*time.Hour, 1, "ZSTD"), file(12, 1, `D:\temp\app.bak`), dbfile(12, `D:\data\app.mdf`),
		set("app", "log", 0, 13, -time.Hour, 1, "MS_XPRESS"), file(13, 1, `\\nas01\sql\app\app.trn`), dbfile(13, `D:\data\app.mdf`),
		set("lnx", "full", 0, 21, -3*time.Hour, 1, ""), file(21, 1, `/var/opt/mssql/data/lnx.bak`), dbfile(21, `/var/opt/mssql/data/lnx.mdf`),
		writer("app", "disk", `\\nas01\sql\app\`, "svc_sql", 20), writer("app", "disk", `\\nas01\sql\app\`, "dba1", 1),
		writer("lnx", "disk", `/var/opt/mssql/backup/`, "sa", 5), writer("lnx", "url", `https://acct.blob.core.windows.net/cont/`, "tool", 3),
		map[string]any{"kind": "writers_read"}, map[string]any{"kind": "cursor", "last_set_id": 21, "mark": 5})
	js := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	for _, c := range []struct{ fn, payload string }{{"import_mssql_backups", js(dbs)}, {"import_mssql_backup_files", js(rows)}} {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.`+c.fn+`($1, $2, $3::jsonb)`, id, now, c.payload); err != nil {
			drop()
			t.Fatal(err)
		}
	}
	return id, drop
}

// apiParts calls a handler as the API serves it and returns its parts' rows by column name.
func apiParts(t *testing.T, h http.HandlerFunc, path string) (int, map[string][]map[string]any) {
	t.Helper()
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodGet, path, nil))
	if rec.Code != http.StatusOK {
		return rec.Code, nil
	}
	var raw map[string]struct {
		Columns []string `json:"columns"`
		Rows    [][]any  `json:"rows"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("%s: %v: %s", path, err, rec.Body.String())
	}
	out := map[string][]map[string]any{}
	for name, tb := range raw {
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				if i < len(r) {
					m[c] = r[i]
				}
			}
			out[name] = append(out[name], m)
		}
		if out[name] == nil {
			out[name] = []map[string]any{}
		}
	}
	return rec.Code, out
}

// TestMSSQLBackupFilesOnAStore (task 301): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it)
// /api/mssql/backup_files answers the panel's parts for an instance and a database, and the fleet's texts without one.
func TestMSSQLBackupFilesOnAStore(t *testing.T) {
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
	id, drop := seedBackupLocations(t, ctx, pool, fmt.Sprintf("bkapi-%d", time.Now().UnixNano()%1000000000))
	defer drop()
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}

	code, p := apiParts(t, s.MSSQLBackupFiles, fmt.Sprintf("/api/mssql/backup_files?instance=%d", id))
	if code != http.StatusOK {
		t.Fatalf("instance: %d", code)
	}
	for _, name := range []string{"sets", "files", "writers", "roots", "findings", "read"} {
		if _, ok := p[name]; !ok {
			t.Errorf("no part %s", name)
		}
	}
	var sets []string
	for _, r := range p["sets"] {
		sets = append(sets, fmt.Sprintf("%v %v copy=%v shown=%v judged=%v", r["database_name"], r["backup_type"], r["is_copy_only"], r["shown"], r["judged"]))
	}
	want := "app full copy=true shown=true judged=false; app full copy=false shown=false judged=true; app log copy=false shown=true judged=true; lnx full copy=false shown=true judged=true"
	if got := strings.Join(sets, "; "); got != want {
		t.Errorf("sets:\n got %s\nwant %s", got, want)
	}
	if r := p["sets"][1]; fmt.Sprint(r["folder"], " ", r["family_count"], " ", r["mb_s"], " ", r["saving_pct"], " ", r["user_name"], " ", r["set_name"]) != `\\nas01\sql\app\ 2 16.7 75.0 svc_sql app full` {
		t.Errorf("app's full: folder %v, files %v, MB/s %v, saving %v, by %v, name %v", r["folder"], r["family_count"], r["mb_s"], r["saving_pct"], r["user_name"], r["set_name"])
	}
	var paths []string
	for _, r := range p["files"] {
		paths = append(paths, fmt.Sprint(r["path"]))
	}
	if got := strings.Join(paths, " "); got != `D:\temp\app.bak \\nas01\sql\app\app_1.bak \\nas01\sql\app\app_2.bak \\nas01\sql\app\app.trn /var/opt/mssql/data/lnx.bak` {
		t.Errorf("files: %s", got)
	}
	var notes []string
	for _, r := range p["writers"] {
		notes = append(notes, fmt.Sprint(r["database_name"], ":", r["users"], ":", r["note"], ":", r["destinations"]))
	}
	if got := strings.Join(notes, " | "); !strings.Contains(got, "app:dba1, svc_sql:2 logins write log backups to this destination:1") {
		t.Errorf("writers: %s", got)
	}
	var checks []string
	for _, r := range p["findings"] {
		checks = append(checks, fmt.Sprint(r["severity"], " ", r["check_name"], ": ", r["object"]))
	}
	if got := strings.Join(checks, "; "); got != "warning a full backup on the volume of the database's own files: lnx; warning log backups to two destinations: lnx" &&
		got != "warning log backups to two destinations: lnx; warning a full backup on the volume of the database's own files: lnx" {
		t.Errorf("findings: %s", got)
	}
	if len(p["read"]) != 1 || p["read"][0]["last_set_id"] == nil {
		t.Errorf("read: %v", p["read"])
	}

	// one database, one part
	_, p = apiParts(t, s.MSSQLBackupFiles, fmt.Sprintf("/api/mssql/backup_files?instance=%d&db=lnx", id))
	if len(p["sets"]) != 1 || p["sets"][0]["same_volume"] == nil || !strings.HasPrefix(fmt.Sprint(p["sets"][0]["same_volume"]), "yes: ") {
		t.Errorf("db=lnx: %v", p["sets"])
	}
	code, p = apiParts(t, s.MSSQLBackupFiles, fmt.Sprintf("/api/mssql/backup_files?instance=%d&part=files", id))
	if code != http.StatusOK || len(p) != 1 || len(p["files"]) != 5 {
		t.Errorf("part=files: %d %d parts, %d files", code, len(p), len(p["files"]))
	}
	for _, bad := range []string{"/api/mssql/backup_files?instance=abc", fmt.Sprintf("/api/mssql/backup_files?instance=%d&part=nope", id)} {
		if code, _ := apiParts(t, s.MSSQLBackupFiles, bad); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad, code)
		}
	}

	// the fleet's texts: DBA Dash's 'n/m' over the judged databases with a set of the type, 'NAME(count)'
	_, p = apiParts(t, s.MSSQLBackupFiles, "/api/mssql/backup_files")
	var mine map[string]any
	for _, r := range p["by_instance"] {
		if fmt.Sprint(r["instance_id"]) == fmt.Sprint(id) {
			mine = r
		}
	}
	if mine == nil {
		t.Fatalf("by_instance has no row of the instance: %v", p["by_instance"])
	}
	if got := fmt.Sprint(mine["full_checksums"], " ", mine["full_compressed"], " ", mine["log_checksums"], " ", mine["full_algorithms"]); got != "2/2 2/2 1/1 ZSTD(1)" {
		t.Errorf("by_instance: %s", got)
	}
	found := false
	for _, r := range p["findings"] {
		found = found || fmt.Sprint(r["instance_id"]) == fmt.Sprint(id)
	}
	if !found {
		t.Error("the fleet's findings lack the instance's")
	}
}
