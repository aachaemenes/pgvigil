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

// 0127 re-creates import_admin_instance to take auth entra-identity (CLOUDSQL C1). The function must stay 0122's in
// every other line: an edit of 0122's function in place (allowed before a release) that 0127 does not carry would be
// undone on every store, since 0127 runs after 0122. With its three entra-identity changes taken back out, 0127's
// function is 0122's, character for character.
func TestAdmin0127IsAdmin0122PlusEntraIdentity(t *testing.T) {
	body := func(file string) string {
		t.Helper()
		b, err := migrations.ReadFile("sql/" + file)
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		i := strings.Index(s, "CREATE OR REPLACE FUNCTION pgvigil.import_admin_instance(")
		if i < 0 {
			t.Fatalf("%s: no import_admin_instance", file)
		}
		j := strings.Index(s[i:], "END $$;")
		if j < 0 {
			t.Fatalf("%s: import_admin_instance has no end", file)
		}
		return s[i : i+j]
	}
	got := body("0127_entra_identity.sql")
	for _, c := range []struct{ now, was string }{
		{"('sql', 'windows', 'entra', 'entra-identity', 'password', 'pgpass')", "('sql', 'windows', 'entra', 'password', 'pgpass')"},
		{"'auth is sql, windows, entra or entra-identity (SQL Server), password or pgpass (PostgreSQL)'", "'auth is sql, windows or entra (SQL Server), password or pgpass (PostgreSQL)'"},
		{"('sql', 'windows', 'entra', 'entra-identity')))", "('sql', 'windows', 'entra')))"},
	} {
		if strings.Count(got, c.now) != 1 {
			t.Fatalf("0127's import_admin_instance holds %q %d times, want once", c.now, strings.Count(got, c.now))
		}
		got = strings.Replace(got, c.now, c.was, 1)
	}
	if want := body("0122_instances_admin.sql"); got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("0127's import_admin_instance differs from 0122's beyond entra-identity at its line %d:\n0127: %s\n0122: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("0127's import_admin_instance has %d lines, 0122's %d", len(gl), len(wl))
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): 0127 replaced 0122's auth CHECK (one CHECK on
// admin_instances.auth, taking entra-identity), and import_admin_instance adds a SQL Server with auth entra-identity
// and refuses it for PostgreSQL in its own words.
func TestEntraIdentityOnAStore(t *testing.T) {
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
	var checks int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_constraint WHERE conrelid = 'pgvigil.admin_instances'::regclass AND contype = 'c'
	                                AND pg_get_constraintdef(oid) LIKE '%auth%'`).Scan(&checks); err != nil {
		t.Fatal(err)
	}
	if checks != 1 {
		t.Fatalf("admin_instances has %d CHECKs on auth, want 1 (0127's)", checks)
	}
	name := fmt.Sprintf("mi-%d", time.Now().UnixNano()%1000000000)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.instances WHERE name = $1`, `DELETE FROM pgvigil.admin_instances WHERE name = $1`} {
			if _, err := pool.Exec(context.Background(), q, name); err != nil {
				t.Error(err)
			}
		}
	}()
	call := func(engine string) (string, string) {
		var outcome, detail string
		payload := fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":%q,"dsn_ref":"file:/x/%s.dsn","host":"srv1.database.windows.net","auth":"entra-identity"}`, name, engine, name)
		if err := pool.QueryRow(ctx, `SELECT r->>'outcome', r->>'detail' FROM pgvigil.import_admin_instance(now(), $1::jsonb) AS t(r)`, payload).Scan(&outcome, &detail); err != nil {
			t.Fatal(err)
		}
		return outcome, detail
	}
	if o, d := call("postgres"); o != "refused" || d != "auth entra-identity is not one of the postgres engine's" {
		t.Fatalf("entra-identity for PostgreSQL: %s %q", o, d)
	}
	if o, d := call("sqlserver"); o != "done" {
		t.Fatalf("entra-identity for SQL Server: %s %q", o, d)
	}
	var auth string
	if err := pool.QueryRow(ctx, `SELECT auth FROM pgvigil.admin_instances WHERE name = $1`, name).Scan(&auth); err != nil || auth != "entra-identity" {
		t.Fatalf("the row's auth %q, %v", auth, err)
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), C1's wiring of 205's sources and approve: 0127
// replaced admin_sources' auth CHECK too (one CHECK, taking entra-identity); a SQL Server source with auth
// entra-identity needs no credential file (as windows), one with auth sql still does; an Entra-only server's proposal
// is approved with entra-identity, and a SQL login is refused there in 0123's words.
func TestEntraIdentitySourceOnAStore(t *testing.T) {
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
	var checks int
	var def string
	if err := pool.QueryRow(ctx, `SELECT count(*), coalesce(max(pg_get_constraintdef(oid)), '') FROM pg_constraint
	                               WHERE conrelid = 'pgvigil.admin_sources'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%auth%'`).Scan(&checks, &def); err != nil {
		t.Fatal(err)
	}
	if checks != 1 || !strings.Contains(def, "entra-identity") {
		t.Fatalf("admin_sources has %d CHECKs on auth (%s), want 1 taking entra-identity (0127's)", checks, def)
	}
	n := time.Now().UnixNano() % 1000000000
	src, inst := fmt.Sprintf("mi-src-%d", n), fmt.Sprintf("mi-inst-%d", n)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.instances WHERE name = $1`, `DELETE FROM pgvigil.admin_instances WHERE name = $1`} {
			if _, err := pool.Exec(context.Background(), q, inst); err != nil {
				t.Error(err)
			}
		}
		for _, s := range []string{src, src + "-sql"} {
			if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_sources WHERE name = $1`, s); err != nil {
				t.Error(err)
			}
		}
	}()
	call := func(fn, payload string) (string, string) {
		t.Helper()
		var outcome, detail string
		if err := pool.QueryRow(ctx, `SELECT r->>'outcome', coalesce(r->>'detail', '') FROM pgvigil.`+fn+`(now(), $1::jsonb) AS t(r)`, payload).Scan(&outcome, &detail); err != nil {
			t.Fatal(err)
		}
		return outcome, detail
	}
	add := func(name, auth string) (string, string) {
		return call("import_admin_source", fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"kind":"sqlserver_list","ref":"/etc/pgvigil/servers.csv","auth":%q,"every_s":"3600"}`, name, auth))
	}
	if o, d := add(src+"-sql", "sql"); o != "refused" || !strings.Contains(d, "or auth windows or entra-identity") {
		t.Fatalf("a sql source without a credential: %s %q", o, d)
	}
	if o, d := add(src, "entra-identity"); o != "done" {
		t.Fatalf("an entra-identity source without a credential: %s %q", o, d)
	}
	var id int64
	if err := pool.QueryRow(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, port, dbname, login, entra_only, note)
	                               VALUES ($1, 'srv1/db1', 'sqlserver', 'srv1.database.windows.net', 1433, 'db1', 'admin1', true,
	                                       'Microsoft Entra-only authentication: a SQL login cannot sign in (approve with an Entra login)')
	                               RETURNING proposal_id`, src).Scan(&id); err != nil {
		t.Fatal(err)
	}
	approve := func(auth string) (string, string) {
		return call("import_admin_decision", fmt.Sprintf(`{"op":"approve","ui_user":"test","proposal_id":"%d","name":%q,"dsn_ref":"file:/x/%s.dsn","auth":%q}`, id, inst, inst, auth))
	}
	if o, d := approve("sql"); o != "refused" || !strings.HasSuffix(d, "approve it with an Entra login (a service principal, or this host's managed identity)") {
		t.Fatalf("an Entra-only server with a SQL login: %s %q", o, d)
	}
	if o, d := approve("entra-identity"); o != "done" {
		t.Fatalf("an Entra-only server with entra-identity: %s %q", o, d)
	}
	var auth, state string
	if err := pool.QueryRow(ctx, `SELECT i.auth, p.state FROM pgvigil.admin_instances i JOIN pgvigil.admin_proposals p ON p.instance_name = i.name
	                               WHERE i.name = $1`, inst).Scan(&auth, &state); err != nil || auth != "entra-identity" || state != "approved" {
		t.Fatalf("the approved row: auth %q, proposal %q, %v", auth, state, err)
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), the join's review 3e: a proposal keeps the
// platform word its cloud gave when it is one of its engine's (admin_read_rows), and the approve gives the instance
// that platform - a Cloud SQL for SQL Server proposal is 'cloudsql', never 'auto' - while a proposal with none stays
// 'auto' until the first read.
func TestProposalPlatformOnAStore(t *testing.T) {
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
	var kept string
	if err := pool.QueryRow(ctx, `SELECT string_agg(server || '=' || coalesce(platform, '-'), ' ' ORDER BY server) FROM pgvigil.admin_read_rows($1::jsonb)`,
		`[{"server":"a","engine":"sqlserver","host":"h1","platform":"cloudsql"},{"server":"b","engine":"sqlserver","host":"h2","platform":"aurora"},
		  {"server":"c","engine":"postgres","host":"h3","platform":"aurora"},{"server":"d","engine":"postgres","host":"h4"}]`).Scan(&kept); err != nil {
		t.Fatal(err)
	}
	if kept != "a=cloudsql b=- c=aurora d=-" {
		t.Fatalf("admin_read_rows kept %q; want a=cloudsql b=- (aurora is no SQL Server word) c=aurora d=-", kept)
	}
	n := time.Now().UnixNano() % 1000000000
	src, i1, i2 := fmt.Sprintf("plat-src-%d", n), fmt.Sprintf("plat-gcs-%d", n), fmt.Sprintf("plat-list-%d", n)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.instances WHERE name IN ($1, $2)`, `DELETE FROM pgvigil.admin_instances WHERE name IN ($1, $2)`} {
			if _, err := pool.Exec(context.Background(), q, i1, i2); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_sources WHERE name = $1`, src); err != nil {
			t.Error(err)
		}
	}()
	var o, d string
	if err := pool.QueryRow(ctx, `SELECT r->>'outcome', coalesce(r->>'detail', '') FROM pgvigil.import_admin_source(now(), $1::jsonb) AS t(r)`,
		fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"kind":"sqlserver_list","ref":"/etc/pgvigil/servers.csv","auth":"windows","every_s":"3600"}`, src)).Scan(&o, &d); err != nil || o != "done" {
		t.Fatalf("the source: %s %q %v", o, d, err)
	}
	for _, c := range []struct{ inst, server, plat, want string }{{i1, "gcs1", "cloudsql", "cloudsql"}, {i2, "list1", "", "auto"}} {
		var id int64
		if err := pool.QueryRow(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, port, platform) VALUES ($1, $2, 'sqlserver', $2 || '.example', 1433, nullif($3, ''))
		                               RETURNING proposal_id`, src, c.server, c.plat).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if err := pool.QueryRow(ctx, `SELECT r->>'outcome', coalesce(r->>'detail', '') FROM pgvigil.import_admin_decision(now(), $1::jsonb) AS t(r)`,
			fmt.Sprintf(`{"op":"approve","ui_user":"test","proposal_id":"%d","name":%q,"dsn_ref":"file:/x/%s.dsn","auth":"windows"}`, id, c.inst, c.inst)).Scan(&o, &d); err != nil || o != "done" {
			t.Fatalf("the approve of %s: %s %q %v", c.server, o, d, err)
		}
		var pa, pi string
		if err := pool.QueryRow(ctx, `SELECT a.platform, i.platform FROM pgvigil.admin_instances a JOIN pgvigil.instances i USING (name) WHERE a.name = $1`, c.inst).Scan(&pa, &pi); err != nil {
			t.Fatal(err)
		}
		if pa != c.want || pi != c.want {
			t.Fatalf("%s approved as platform %q (page) / %q (instances); want %q", c.server, pa, pi, c.want)
		}
	}
}
