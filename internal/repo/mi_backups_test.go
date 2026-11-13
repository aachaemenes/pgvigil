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

// 0129 re-creates mssql_backup_judged with one more not_judged reason (CLOUDSQL C5: a Managed Instance's system
// databases). The view must stay 0066's in every other line: an edit of 0066's view in place that 0129 does not
// carry would be undone on every store, since 0129 runs after 0066. With its one reason taken back out, 0129's view
// is 0066's, character for character.
func TestBackupJudged0129Is0066PlusManagedInstance(t *testing.T) {
	view := func(file string) string {
		t.Helper()
		b, err := migrations.ReadFile("sql/" + file)
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		i := strings.Index(s, "CREATE OR REPLACE VIEW pgvigil.mssql_backup_judged AS")
		if i < 0 {
			t.Fatalf("%s: no mssql_backup_judged", file)
		}
		j := strings.Index(s[i:], "  FROM j;")
		if j < 0 {
			t.Fatalf("%s: mssql_backup_judged has no end", file)
		}
		return s[i : i+j]
	}
	got := view("0129_mssql_mi_backups.sql")
	reason := `              WHEN m.database_name IN ('master', 'model', 'msdb')
                   AND EXISTS (SELECT 1 FROM pgvigil.instances x WHERE x.instance_id = m.instance_id AND x.platform = 'azuresqlmi')
                THEN 'Azure SQL Managed Instance backs up its system databases itself and does not record those backups in msdb'
`
	if strings.Count(got, reason) != 1 {
		t.Fatalf("0129's mssql_backup_judged holds the Managed Instance reason %d times, want once", strings.Count(got, reason))
	}
	got = strings.Replace(got, reason, "", 1)
	if want := view("0066_mssql_hadr.sql"); got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("0129's mssql_backup_judged differs from 0066's beyond the Managed Instance reason at its line %d:\n0129: %s\n0066: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("0129's mssql_backup_judged has %d lines, 0066's %d", len(gl), len(wl))
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): a Managed Instance's master, model and msdb are
// not judged, with Microsoft's reason, and its user database is judged as anywhere; on a server someone runs, model
// with no backup is still 'never'.
func TestManagedInstanceBackupsOnAStore(t *testing.T) {
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
	tag := time.Now().UnixNano() % 1000000000
	mi, onprem := fmt.Sprintf("mi-bk-%d", tag), fmt.Sprintf("srv-bk-%d", tag)
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name IN ($1, $2)`, mi, onprem); err != nil {
			t.Error(err)
		}
	}()
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-30 * 24 * time.Hour).Format(time.RFC3339)
	db := func(name, model string) string {
		return fmt.Sprintf(`{"kind":"database","database_name":%q,"state":"ONLINE","recovery_model":%q,"created_utc":%q,"is_snapshot":0,"is_read_only":0,"is_standby":0}`, name, model, created)
	}
	payload := "[" + strings.Join([]string{db("master", "SIMPLE"), db("model", "FULL"), db("msdb", "SIMPLE"), db("app", "FULL"),
		fmt.Sprintf(`{"kind":"backup","database_name":"app","backup_type":"full","sink":"backup","finish_utc":%q,"size_bytes":1,"compressed_bytes":1,"duration_s":1,"is_copy_only":0,"is_snapshot":0,"device":"url","device_name":"https://x/app.bak"}`, now.Add(-2*time.Hour).Format(time.RFC3339)),
		fmt.Sprintf(`{"kind":"history","backup_sets":1,"oldest_utc":%q}`, created)}, ",") + "]"
	judged := map[string]map[string][2]string{}
	for _, inst := range []struct{ name, platform string }{{mi, "azuresqlmi"}, {onprem, "sqlserver"}} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '16.0', 160000, false, '{}', 'sqlserver')`, inst.name, inst.platform).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_backups($1, $2, $3::jsonb)`, id, now, payload); err != nil {
			t.Fatal(err)
		}
		rows, err := pool.Query(ctx, `SELECT database_name, coalesce(not_judged, ''), full_status FROM pgvigil.mssql_backup_judged WHERE instance_id = $1`, id)
		if err != nil {
			t.Fatal(err)
		}
		judged[inst.platform] = map[string][2]string{}
		for rows.Next() {
			var name, why, full string
			if err := rows.Scan(&name, &why, &full); err != nil {
				t.Fatal(err)
			}
			judged[inst.platform][name] = [2]string{why, full}
		}
		rows.Close()
	}
	const reason = "Azure SQL Managed Instance backs up its system databases itself and does not record those backups in msdb"
	for _, name := range []string{"master", "model", "msdb"} {
		if got := judged["azuresqlmi"][name]; got != [2]string{reason, "not judged"} {
			t.Errorf("Managed Instance %s: %q, want not judged with Microsoft's reason", name, got)
		}
	}
	if got := judged["azuresqlmi"]["app"]; got != [2]string{"", "ok"} {
		t.Errorf("Managed Instance app: %q, want judged and ok", got)
	}
	if got := judged["sqlserver"]["model"]; got != [2]string{"", "never"} {
		t.Errorf("a server's model: %q, want judged and never", got)
	}
	if got := judged["sqlserver"]["app"]; got != [2]string{"", "ok"} {
		t.Errorf("a server's app: %q, want judged and ok", got)
	}
}
