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

// TestHADRCursor0140Is0083PlusBackupSets: 0140's mssql_hadr_cursor is 0083's with the one arm for the collection
// mssql_backup_files; an edit of 0083's arms is made in 0140 too.
func TestHADRCursor0140Is0083PlusBackupSets(t *testing.T) {
	fn := func(file string) string {
		t.Helper()
		b, err := migrations.ReadFile("sql/" + file)
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		i := strings.Index(s, "CREATE OR REPLACE FUNCTION pgvigil.mssql_hadr_cursor(")
		if i < 0 {
			t.Fatalf("%s: no mssql_hadr_cursor", file)
		}
		j := strings.Index(s[i:], "\n$$;")
		if j < 0 {
			t.Fatalf("%s: mssql_hadr_cursor has no end", file)
		}
		return s[i : i+j]
	}
	arm := `    WHEN p_source IN ('backup_sets', 'backup_sets_mark') THEN
      (SELECT CASE p_source WHEN 'backup_sets' THEN c.last_set_id ELSE c.mark END
         FROM pgvigil.mssql_backup_files_cursor c WHERE c.instance_id = p_instance_id)
`
	got := fn("0140_backup_locations.sql")
	if strings.Count(got, arm) != 1 {
		t.Fatalf("0140's mssql_hadr_cursor holds the backup_sets arm %d times, want once", strings.Count(got, arm))
	}
	if want := fn("0083_mssql_querystore.sql"); strings.Replace(got, arm, "", 1) != want {
		t.Fatalf("0140's mssql_hadr_cursor is not 0083's plus the backup_sets arm:\n%s\n--- 0083:\n%s", got, want)
	}
}

// bkRows is a payload of mssql_backup_files or mssql_backups as JSON rows.
type bkRows []map[string]any

func (r bkRows) json(t *testing.T) string {
	t.Helper()
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): stubbed reads of mssql_backup_files through its import
// (task 301; the design fold's F2-F7, F10-F12): 0066's two guards, a copy-only full beside the full that is not, the
// differential's base, each file of a striped set, the destination roots, the volume and directory rules, the writers,
// the roots seen, the cursor, an availability group's merge and the platforms not judged.
func TestBackupLocationsOnAStore(t *testing.T) {
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
	name := func(s string) string { return fmt.Sprintf("bkloc-%s-%d", s, tag) }
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name LIKE $1`, fmt.Sprintf("bkloc-%%-%d", tag)); err != nil {
			t.Error(err)
		}
	}()
	inst := func(n, platform string) int {
		t.Helper()
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '16.0', 160000, false, '{}', 'sqlserver')`, name(n), platform).Scan(&id); err != nil {
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
	db := func(n string, created time.Duration, group string) map[string]any {
		r := map[string]any{"kind": "database", "database_name": n, "state": "ONLINE", "recovery_model": "FULL", "created_utc": at(created),
			"is_snapshot": 0, "is_read_only": 0, "is_standby": 0}
		if group != "" {
			r["ag_group_id"], r["ag_name"] = group, "ag_"+group[:4]
		}
		return r
	}
	set := func(dbn, typ string, copyOnly bool, id int64, finish time.Duration, extra map[string]any) map[string]any {
		r := map[string]any{"kind": "set", "database_name": dbn, "backup_type": typ, "is_copy_only": map[bool]int{false: 0, true: 1}[copyOnly],
			"backup_set_id": id, "backup_set_uuid": fmt.Sprintf("00000000-0000-0000-0000-%012d", id), "finish_utc": at(finish), "start_utc": at(finish - time.Minute),
			"size_bytes": 1000, "compressed_bytes": 400, "has_checksums": 1, "is_damaged": 0, "is_password_protected": 0, "key_algorithm": "NO_Encryption",
			"family_count": 1, "mirror_count": 1, "software_name": "Microsoft SQL Server", "user_name": "sa", "checkpoint_lsn": fmt.Sprintf("%d000000001", id)}
		for k, v := range extra {
			r[k] = v
		}
		return r
	}
	file := func(id int64, family, mirror int, kind, path string) map[string]any {
		return map[string]any{"kind": "file", "backup_set_id": id, "family": family, "mirror": mirror, "device_kind": kind, "path": path}
	}
	dbfile := func(id int64, n int, path string) map[string]any {
		return map[string]any{"kind": "dbfile", "backup_set_id": id, "file_number": n, "file_type": map[bool]string{true: "L", false: "D"}[strings.HasSuffix(path, ".ldf")], "physical_name": path}
	}
	writer := func(dbn, kind, dir, user string, n int) map[string]any {
		return map[string]any{"kind": "writer", "database_name": dbn, "device_kind": kind, "directory": dir, "user_name": user, "sets": n,
			"first_utc": at(-6 * 24 * time.Hour), "last_utc": at(-time.Hour)}
	}
	importBoth := func(id int, snap time.Time, dbs bkRows, files bkRows) {
		t.Helper()
		exec(`SELECT pgvigil.import_mssql_backups($1, $2, $3::jsonb)`, id, snap, dbs.json(t))
		exec(`SELECT pgvigil.import_mssql_backup_files($1, $2, $3::jsonb)`, id, snap, append(append(bkRows{}, dbs...), files...).json(t))
	}

	// ---- the roots of the six path shapes (F6)
	for _, c := range []struct{ path, kind, soft, want string }{
		{`\\NAS01\SQL\app\app_1.bak`, "disk", "", `\\nas01\sql`},
		{`\\10.1.2.3\sql$\x.bak`, "disk", "", `\\10.1.2.3\sql$`},
		{`d:\Backup\db\x.bak`, "disk", "", `D:\`},
		{`/var/opt/mssql/backup/x.bak`, "disk", "", `/var/opt`},
		{`/mnt/nfs_old/db/x.bak`, "disk", "", `/mnt/nfs_old`},
		{`/x.bak`, "disk", "", `/x.bak`},
		{`https://Acct.blob.core.windows.net/cont/2026/x.bak`, "url", "", `https://acct.blob.core.windows.net/cont`},
		{`s3://minio.lab:9000/bucket/2026-11-14/x.bak`, "disk", "", `s3://minio.lab:9000/bucket`},
		{`s3://10.0.0.5/bucket/x.bak`, "url", "", `s3://10.0.0.5/bucket`},
		{`s3://s3.us-west-2.amazonaws.com/bucket/x.bak`, "url", "", `s3://s3.us-west-2.amazonaws.com/bucket`},
		{`s3://mybucket.s3.us-west-2.amazonaws.com/2026-11-14/x.bak`, "url", "", `s3://mybucket.s3.us-west-2.amazonaws.com`},
		// a path style URL with no port on a name (Learn's own example): the bucket kept
		{`s3://objects.corp.local/sqlbak/db/x.bak`, "url", "", `s3://objects.corp.local/sqlbak`},
		// a file right after the host is never part of a root: a virtual host with a port, a bucket's top
		{`s3://bkt.store.local:9000/db_20261114.bak`, "url", "", `s3://bkt.store.local:9000`},
		{`https://acct.blob.core.windows.net/x.bak`, "url", "", `https://acct.blob.core.windows.net`},
		// a writer's directory reads as its files do
		{`s3://minio.lab:9000/bucket/`, "url", "", `s3://minio.lab:9000/bucket`},
		{`{4A0C1E3B-1111-2222-3333-444455556666}`, "virtual device", "Veeam Backup", `virtual device (Veeam Backup)`},
		{`NUL`, "disk", "", `NUL`},
	} {
		if got := one(`SELECT pgvigil.mssql_backup_root($1, $2, nullif($3, ''))`, c.path, c.kind, c.soft); got != c.want {
			t.Errorf("root of %s (%s): %s, want %s", c.path, c.kind, got, c.want)
		}
	}

	// ---- one server, read three times
	a := inst("a", "sqlserver")
	// mssql_volumes holds only the volumes a database file sits on (storage.go reads sys.dm_os_volume_stats per file): a
	// folder mounted for the backups alone is never listed. D:\Logs\ is a mounted folder with a log file on it.
	exec(`INSERT INTO pgvigil.mssql_volumes (instance_id, volume, snapshot_at, is_present) VALUES
	        ($1, 'C:\', now(), true), ($1, 'C:\ClusterStorage\Volume1\', now(), true), ($1, 'D:\', now(), true), ($1, 'D:\Logs\', now(), true)`, a)
	exec(`INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, physical_name, volume, snapshot_at, first_seen) VALUES
	        ($1, 1, 1, 'master', 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\master.mdf', 'C:\', now(), now()),
	        ($1, 5, 1, 'win', 'C:\ClusterStorage\Volume1\data\win.mdf', 'C:\ClusterStorage\Volume1\', now(), now()),
	        ($1, 6, 1, 'app', 'D:\data\app.mdf', 'D:\', now(), now()),
	        ($1, 7, 2, 'wm', 'D:\Logs\wm.ldf', 'D:\Logs\', now(), now())`, a)
	h := time.Hour
	d := 24 * h
	dbs1 := bkRows{db("app", -30*d, ""), db("fresh", -3*h, ""), db("win", -30*d, ""), db("lnx", -30*d, ""), db("wm", -30*d, "")}
	files1 := bkRows{
		set("app", "full", false, 101, -2*d, map[string]any{"family_count": 4}),
		file(101, 1, 0, "disk", `\\NAS01\SQL\app\app_1.bak`), file(101, 2, 0, "disk", `\\NAS01\SQL\app\app_2.bak`),
		file(101, 3, 0, "disk", `\\NAS01\SQL\app\app_3.bak`), file(101, 4, 0, "disk", `\\NAS01\SQL\app\app_4.bak`),
		dbfile(101, 1, `D:\data\app.mdf`), dbfile(101, 2, `D:\data\app.ldf`),
		set("app", "diff", false, 102, -d, map[string]any{"differential_base_guid": "00000000-0000-0000-0000-000000000101"}),
		file(102, 1, 0, "disk", `\\nas01\sql\app\app.dif`), dbfile(102, 1, `D:\data\app.mdf`),
		set("app", "log", false, 103, -h, nil), file(103, 1, 0, "disk", `\\nas01\sql\app\app.trn`), dbfile(103, 1, `D:\data\app.mdf`),
		set("app", "full", true, 104, -12*h, map[string]any{"user_name": "dev1"}), file(104, 1, 0, "disk", `D:\temp\app.bak`), dbfile(104, 1, `D:\data\app.mdf`),
		// the database 'fresh' was created 3 hours ago: last month's differential under its name is another database's (F2 A)
		set("fresh", "diff", false, 201, -20*d, nil), file(201, 1, 0, "disk", `D:\old\fresh.dif`),
		set("fresh", "full", false, 202, -2*h, nil), file(202, 1, 0, "disk", `/var/opt/mssql/data/fresh.bak`), dbfile(202, 1, `/var/opt/mssql/data/fresh.mdf`),
		// a name msdb remembers and the server does not list (F2 B)
		set("ghost", "full", false, 301, -h, nil), file(301, 1, 0, "disk", `D:\data\ghost.bak`),
		// Windows (F3, the review's 1): at a Cluster Shared Volume's root beside the data = yes; in the data's own directory, d:\
		// against D:\ without case = yes; D:\Backup\ (no database file there: it may be a folder mounted for the backups
		// alone, which mssql_volumes never lists) = not judged; to D:\Backup\ with the log file on the mounted folder
		// D:\Logs\ = no (two volumes either way)
		set("win", "full", false, 401, -3*h, nil), file(401, 1, 0, "disk", `C:\ClusterStorage\Volume1\win.bak`), dbfile(401, 1, `C:\ClusterStorage\Volume1\data\win.mdf`),
		set("win", "log", false, 402, -h, nil), file(402, 1, 0, "disk", `D:\Backup\win.trn`), dbfile(402, 1, `D:\data\win.ldf`),
		set("win", "diff", false, 403, -2*h, nil), file(403, 1, 0, "disk", `d:\data\win.dif`), dbfile(403, 1, `D:\data\win.mdf`),
		set("wm", "log", false, 601, -h, nil), file(601, 1, 0, "disk", `D:\Backup\wm.trn`), dbfile(601, 1, `D:\Logs\wm.ldf`),
		// Linux: in the database's own directory = yes; a sibling directory on the same filesystem = not judged; a directory
		// below the database's (it may be a mounted folder) = not judged (F3, the review's 1)
		set("lnx", "full", false, 501, -3*h, nil), file(501, 1, 0, "disk", `/var/opt/mssql/data/lnx.bak`), dbfile(501, 1, `/var/opt/mssql/data/lnx.mdf`),
		set("lnx", "log", false, 502, -h, nil), file(502, 1, 0, "disk", `/var/opt/mssql/backup/lnx.trn`), dbfile(502, 1, `/var/opt/mssql/data/lnx.ldf`),
		set("lnx", "diff", false, 503, -2*h, nil), file(503, 1, 0, "disk", `/var/opt/mssql/data/bk/lnx.dif`), dbfile(503, 1, `/var/opt/mssql/data/lnx.mdf`),
		// writers (F5): app's two logins to one share (cased two ways) = one destination; lnx's local directory and a URL = two
		writer("app", "disk", `\\nas01\sql\app\`, "svc_a", 10), writer("app", "disk", `\\NAS01\SQL\app\`, "dba_b", 2),
		writer("lnx", "disk", `/var/opt/mssql/backup/`, "sa", 5), writer("lnx", "url", `https://acct.blob.core.windows.net/cont/`, "tool", 3),
		{"kind": "writers_read"}, {"kind": "read", "cursor": true}, {"kind": "cursor", "last_set_id": 600, "mark": 77},
	}
	t1 := now
	importBoth(a, t1, dbs1, files1)

	keys := func(id int, dbn string) string {
		return one(`SELECT coalesce(string_agg(backup_type || CASE WHEN is_copy_only THEN '/copy' ELSE '' END || ':' || backup_set_id, ' ' ORDER BY backup_type, is_copy_only), '')
		              FROM pgvigil.mssql_backup_sets WHERE instance_id = $1 AND database_name = $2`, id, dbn)
	}
	if got := keys(a, "app"); got != "diff:102 full:101 full/copy:104 log:103" {
		t.Errorf("app's sets: %q", got)
	}
	if got := keys(a, "fresh"); got != "full:202" {
		t.Errorf("fresh's sets: %q, want its own full only (the differential before its creation is another database's)", got)
	}
	if got := keys(a, "ghost"); got != "" {
		t.Errorf("a database the server does not list has sets: %q", got)
	}
	if got := one(`SELECT count(*)::text || ' ' || array_to_string(s.roots, ',') || ' ' || s.folder FROM pgvigil.mssql_backup_files f
	                 JOIN pgvigil.mssql_backup_sets s USING (instance_id, database_name, backup_type, is_copy_only)
	                WHERE f.instance_id = $1 AND f.database_name = 'app' AND f.backup_type = 'full' AND NOT f.is_copy_only GROUP BY s.roots, s.folder`, a); got != `4 \\nas01\sql \\NAS01\SQL\app\` {
		t.Errorf("app's striped full: %q", got)
	}
	loc := func(id int, dbn, typ string, copyOnly bool, col string) string {
		return one(`SELECT `+col+`::text FROM pgvigil.mssql_backup_locations WHERE instance_id = $1 AND database_name = $2 AND backup_type = $3 AND is_copy_only = $4`, id, dbn, typ, copyOnly)
	}
	// F4: the copy-only full is shown, the full that is not is judged, the differential's base named
	if got := loc(a, "app", "full", true, "shown::text || '/' || judged::text"); got != "true/false" {
		t.Errorf("app's copy-only full shown/judged: %s", got)
	}
	if got := loc(a, "app", "full", false, "shown::text || '/' || judged::text"); got != "false/true" {
		t.Errorf("app's full shown/judged: %s", got)
	}
	if got := loc(a, "app", "diff", false, "diff_base"); got != "the last full that is not copy-only" {
		t.Errorf("app's differential base: %s", got)
	}
	if got := one(`SELECT full_to || ' | ' || diff_to || ' | ' || log_to FROM pgvigil.mssql_backup_loc_db WHERE instance_id = $1 AND database_name = 'app'`, a); got != `D:\temp\ | \\nas01\sql\app\ | \\nas01\sql\app\` {
		t.Errorf("app's to cells: %s", got)
	}
	// the 'full to' cell's marks come from the stored set shown there, never from mssql_backup_state (F2, the review's 4)
	if got := one(`SELECT full_to_copy_only::text || '/' || full_to_snapshot::text FROM pgvigil.mssql_backup_loc_db WHERE instance_id = $1 AND database_name = 'app'`, a); got != "true/false" {
		t.Errorf("app's full to marks: %s, want true/false (the copy-only full is shown)", got)
	}
	for _, c := range []struct{ dbn, typ, want string }{
		{"win", "full", `yes: C:\ClusterStorage\Volume1\win.bak is on C:\CLUSTERSTORAGE\VOLUME1\, the volume of C:\ClusterStorage\Volume1\data\win.mdf`},
		{"win", "log", `not judged: D:\Backup\ may be a mounted folder of its own - only the volumes that hold a database file are read, and no database file sits there (by the path it is on D:\, the volume of D:\data\win.ldf)`},
		{"win", "diff", `yes: d:\data\win.dif is on D:\, the volume of D:\data\win.mdf`},
		{"wm", "log", "no"},
		{"lnx", "full", "yes: /var/opt/mssql/data/lnx.bak is in /var/opt/mssql/data/, the directory of /var/opt/mssql/data/lnx.mdf"},
		{"lnx", "log", "not judged: on Linux only a backup in the directory of the database's own files is judged (the volume of another directory is not read)"},
		{"lnx", "diff", "not judged: /var/opt/mssql/data/bk/ is below /var/opt/mssql/data/, the directory of /var/opt/mssql/data/lnx.mdf, and may be a mounted folder of its own (the volume of another directory is not read)"},
		{"app", "full", "no"},
	} {
		if got := loc(a, c.dbn, c.typ, false, "same_volume"); got != c.want {
			t.Errorf("%s %s same volume: %q, want %q", c.dbn, c.typ, got, c.want)
		}
	}
	findings := func(id int) string {
		return one(`SELECT coalesce(string_agg(severity || ' ' || check_name || ': ' || object, '; ' ORDER BY check_name, object), '') FROM pgvigil.mssql_backup_loc_findings WHERE instance_id = $1`, id)
	}
	// 'fresh' is a new database (not judged): its same-volume full raises nothing (F10)
	want1 := "warning a differential backup on the volume of the database's own files: win; warning a full backup on the volume of the database's own files: lnx; " +
		"warning a full backup on the volume of the database's own files: win; warning log backups to two destinations: lnx"
	if got := findings(a); got != want1 {
		t.Errorf("findings after read 1:\n got %s\nwant %s", got, want1)
	}
	if got := one(`SELECT array_to_string(users, ',') || ' ' || sets FROM pgvigil.mssql_backup_writers WHERE instance_id = $1 AND database_name = 'app'`, a); got != "dba_b,svc_a 12" {
		t.Errorf("app's one writer: %s", got)
	}
	if got := one(`SELECT pgvigil.mssql_hadr_cursor($1, 'backup_sets')::text || '/' || pgvigil.mssql_hadr_cursor($1, 'backup_sets_mark')::text`, a); got != "600/77" {
		t.Errorf("the cursor: %s", got)
	}

	// ---- read 2: app's full goes to another share (a root not seen before); an older log read again changes nothing;
	// 'win' is created anew under its name; 'lnx' is dropped
	t2 := now.Add(time.Minute)
	dbs2 := bkRows{db("app", -30*d, ""), db("fresh", -3*h, ""), db("win", -2*h, ""), db("wm", -30*d, "")}
	files2 := bkRows{
		set("app", "full", false, 110, -30*time.Minute, nil), file(110, 1, 0, "disk", `\\nas02\sql\app\app.bak`), dbfile(110, 1, `D:\data\app.mdf`),
		set("app", "log", false, 90, -3*d, nil), file(90, 1, 0, "disk", `\\old\sql\app.trn`),
		set("win", "full", false, 410, -h, nil), file(410, 1, 0, "disk", `E:\bk\win.bak`), dbfile(410, 1, `D:\data\win.mdf`),
		{"kind": "read", "cursor": true}, {"kind": "cursor", "last_set_id": 700, "mark": 78},
	}
	importBoth(a, t2, dbs2, files2)
	if got := keys(a, "app"); got != "diff:102 full:110 full/copy:104 log:103" {
		t.Errorf("app's sets after read 2: %q", got)
	}
	if got := one(`SELECT string_agg(path, ',') FROM pgvigil.mssql_backup_files WHERE instance_id = $1 AND database_name = 'app' AND backup_type = 'full' AND NOT is_copy_only`, a); got != `\\nas02\sql\app\app.bak` {
		t.Errorf("app's full files after read 2: %s (the old set's four stripes must go)", got)
	}
	if got := keys(a, "win"); got != "full:410" {
		t.Errorf("win created anew: %q, want only the new full", got)
	}
	if got := keys(a, "lnx"); got != "" {
		t.Errorf("lnx dropped: %q", got)
	}
	if got := loc(a, "app", "full", false, "shown::text || '/' || judged::text"); got != "true/true" {
		t.Errorf("app's new full shown/judged: %s", got)
	}
	want2 := `info a backup destination not seen before: app`
	if got := findings(a); got != want2 {
		t.Errorf("findings after read 2:\n got %s\nwant %s", got, want2)
	}
	// ---- read 3: back to the first share - nothing new is written (F11)
	importBoth(a, now.Add(2*time.Minute), dbs2, bkRows{set("app", "full", false, 120, -10*time.Minute, nil), file(120, 1, 0, "disk", `\\nas01\sql\app\app.bak`)})
	if got := one(`SELECT count(*)::text FROM pgvigil.mssql_backup_roots_seen WHERE instance_id = $1 AND database_name = 'app' AND backup_type = 'full'`, a); got != "2" {
		t.Errorf("app's full roots seen after a flip back: %s, want 2", got)
	}
	// an older read imported late changes nothing
	importBoth(a, t1.Add(-time.Hour), dbs1, files1)
	if got := keys(a, "app"); got != "diff:102 full:120 full/copy:104 log:103" {
		t.Errorf("app's sets after a late old read: %q", got)
	}

	// ---- two fulls in one second to two shares (msdb keeps finish times to the second): the second is 'not seen before'
	dbsTie := append(append(bkRows{}, dbs2...), db("tie", -30*d, ""))
	importBoth(a, now.Add(3*time.Minute), dbsTie, bkRows{set("tie", "full", false, 980, -h, nil), file(980, 1, 0, "disk", `\\nas01\sql\t.bak`)})
	importBoth(a, now.Add(4*time.Minute), dbsTie, bkRows{set("tie", "full", false, 981, -h, nil), file(981, 1, 0, "disk", `\\nas02\sql\t.bak`)})
	if got := one(`SELECT coalesce(string_agg(severity || ' ' || check_name, '; '), '') FROM pgvigil.mssql_backup_loc_findings WHERE instance_id = $1 AND object = 'tie'`, a); got != "info a backup destination not seen before" {
		t.Errorf("two fulls in one second to two shares: %q", got)
	}

	// ---- a database a read did not list (read 2 dropped lnx's sets) is listed again: a cursor read cannot see its sets
	// older than the cursor, so the cursor goes back to 0 and the next read is one whole pass (the review's 3)
	cur := func(id int) string {
		return one(`SELECT coalesce(last_set_id::text, '-') || '/' || coalesce(mark::text, '-') || ' ' || array_to_string(unlisted, ',') FROM pgvigil.mssql_backup_files_cursor WHERE instance_id = $1`, id)
	}
	if got := cur(a); got != "700/78 lnx" {
		t.Errorf("the cursor with lnx unlisted: %q", got)
	}
	dbsBack := append(append(bkRows{}, dbsTie...), db("lnx", -30*d, ""))
	importBoth(a, now.Add(5*time.Minute), dbsBack, bkRows{{"kind": "read", "cursor": true, "from": 650}, {"kind": "cursor", "last_set_id": 720, "mark": 79}})
	if got := cur(a); got != "0/- " {
		t.Errorf("the cursor after lnx came back on a cursor read: %q, want 0/- (one whole pass next)", got)
	}
	importBoth(a, now.Add(6*time.Minute), dbsBack, bkRows{set("lnx", "full", false, 501, -3*h, nil), file(501, 1, 0, "disk", `/var/opt/mssql/data/lnx.bak`),
		{"kind": "read", "cursor": true, "from": 0}, {"kind": "cursor", "last_set_id": 730, "mark": 80}})
	if got := cur(a) + " " + keys(a, "lnx"); got != "730/80  full:501" {
		t.Errorf("the cursor and lnx's sets after the whole pass: %q", got)
	}

	// ---- an availability group: the newest set of each type over the monitored replicas (F10)
	p, s := inst("p", "sqlserver"), inst("s", "sqlserver")
	g := fmt.Sprintf("%08x-0000-0000-0000-000000000001", tag)
	importBoth(p, now, bkRows{db("agdb", -30*d, g)}, bkRows{set("agdb", "full", false, 801, -5*h, nil), file(801, 1, 0, "disk", `\\nas01\sql\agdb\p.bak`)})
	importBoth(s, now, bkRows{db("agdb", -30*d, g)}, bkRows{set("agdb", "full", true, 811, -h, nil), file(811, 1, 0, "disk", `\\nas01\sql\agdb\s.bak`),
		set("agdb", "log", false, 812, -10*time.Minute, nil), file(812, 1, 0, "disk", `\\nas01\sql\agdb\s.trn`)})
	if got := one(`SELECT string_agg(backup_type || CASE WHEN is_copy_only THEN '/copy' ELSE '' END || '@' || from_instance || ':' || shown::text, ' ' ORDER BY backup_type, is_copy_only)
	                 FROM pgvigil.mssql_backup_locations WHERE instance_id = $1 AND database_name = 'agdb'`, p); got != fmt.Sprintf("full@%s:false full/copy@%s:true log@%s:true", name("p"), name("s"), name("s")) {
		t.Errorf("the group's merged sets seen from the primary: %s", got)
	}

	// ---- Amazon RDS and Managed Instance: the volume is not judged (F12)
	r := inst("r", "rdssqlserver")
	importBoth(r, now, bkRows{db("rdb", -30*d, "")}, bkRows{set("rdb", "full", false, 901, -h, nil), file(901, 1, 0, "disk", `D:\S3\rdb.bak`), dbfile(901, 1, `D:\data\rdb.mdf`)})
	if got := loc(r, "rdb", "full", false, "same_volume"); !strings.HasPrefix(got, "not judged: Amazon RDS") {
		t.Errorf("RDS same volume: %s", got)
	}
	// ---- Windows with no volume read: not judged (F3)
	w := inst("w", "sqlserver")
	importBoth(w, now, bkRows{db("wdb", -30*d, "")}, bkRows{set("wdb", "full", false, 951, -h, nil), file(951, 1, 0, "disk", `D:\bk\wdb.bak`), dbfile(951, 1, `D:\data\wdb.mdf`)})
	if got := loc(w, "wdb", "full", false, "same_volume"); !strings.HasPrefix(got, "not judged: volumes not read") {
		t.Errorf("no volumes read: %s", got)
	}
	if got := findings(w); got != "" {
		t.Errorf("findings with no volume read: %s", got)
	}
}
