package web

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/plans"
)

// testPassword: a throwaway login's password from crypto/rand, unrelated to its name (the names are in pg_roles for
// any login of the server to read; a run killed before its deferred drops leaves the logins behind) - the code review
// of REPORT ROLE, part B
func testPassword(t *testing.T) string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return "Rr" + hex.EncodeToString(b)
}

// memberNamed: the check's words name role among the roles the login is a member of ('is a member of a, b: ...').
func memberNamed(words, role string) bool {
	_, list, ok := strings.Cut(words, "is a member of ")
	if !ok {
		return false
	}
	list, _, _ = strings.Cut(list, ": ")
	for _, r := range strings.Split(list, ", ") {
		if r == role {
			return true
		}
	}
	return false
}

// TestStoreReportsLoginOnAStore (REPORT ROLE): on a migrated repository (PGVIGIL_REPO_TEST_DSN, a superuser; skipped
// without it) the store reports' check passes a login IN ROLE pgvigil_reader alone and refuses, on its SESSION user,
// the UI's login (pgvigil_auth), the UI's login started as the reader (ALTER ROLE ... SET role: the run could set it
// back), a superuser, a NOINHERIT member of a superuser role, a NOINHERIT member of the schema's owner, a login holding pg_monitor beside the reader, a login
// that may not read the schema, and a reader-alone login on another database with a pgvigil schema (not serve's
// repository); on the reader-alone login a report that sets the role back and plans ui_password_hash at run time is
// refused by the server. The door's own words: no key, a key that resolves to nothing, a dsn that does not parse.
func TestStoreReportsLoginOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	pw := testPassword(t)
	var owner string
	if err := pool.QueryRow(ctx, `SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'pgvigil'`).Scan(&owner); err != nil {
		t.Fatal(err)
	}
	name := func(k string) string { return fmt.Sprintf("pgvrr_%s_%d", k, sfx) }
	other := fmt.Sprintf("pgvrr_db_%d", sfx)
	logins := []struct{ key, make string }{
		{"rd", "IN ROLE pgvigil_reader"},
		{"ui", "IN ROLE pgvigil_reader, pgvigil_auth"},
		{"uiset", "IN ROLE pgvigil_reader, pgvigil_auth"},
		{"su", "SUPERUSER"},
		{"insu", "NOINHERIT IN ROLE pgvigil_reader, " + name("su")}, // a member of a superuser role (part B)
		{"noinh", "NOINHERIT IN ROLE pgvigil_reader, " + pgx.Identifier{owner}.Sanitize()},
		{"mon", "IN ROLE pgvigil_reader, pg_monitor"},
		{"none", ""},
		{"rad", "IN ROLE pg_read_all_data"},
	}
	defer func() {
		bg := context.Background()
		if _, err := pool.Exec(bg, `DROP DATABASE IF EXISTS `+other+` WITH (FORCE)`); err != nil {
			t.Error(err)
		}
		for _, l := range logins {
			if _, err := pool.Exec(bg, `DROP ROLE IF EXISTS `+name(l.key)); err != nil {
				t.Error(err)
			}
		}
	}()
	for _, l := range logins {
		if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN PASSWORD '%s' %s`, name(l.key), pw, l.make)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pool.Exec(ctx, `ALTER ROLE `+name("uiset")+` SET role = pgvigil_reader`); err != nil {
		t.Fatal(err)
	}
	// another database of the same server with a pgvigil schema the reader may use: not serve's repository
	if _, err := pool.Exec(ctx, `CREATE DATABASE `+other); err != nil {
		t.Fatal(err)
	}
	base, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	oc := base.Copy()
	oc.Database = other
	oconn, err := pgx.ConnectConfig(ctx, oc)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := oconn.Exec(ctx, `CREATE SCHEMA pgvigil; GRANT USAGE ON SCHEMA pgvigil TO pgvigil_reader`); err != nil {
		t.Fatal(err)
	}
	_ = oconn.Close(ctx)

	s := &Server{pool: pool}
	door := func(user, db string) *reportsDoor {
		d := s.newReportsDoor(ctx, &ReportsConfig{Raw: "env:X", DSN: dsn})
		if d.cfg == nil || d.serve == nil {
			t.Fatalf("the door: off %q, serve's pool held %v", d.off, d.serve != nil)
		}
		d.cfg.User, d.cfg.Password = user, pw
		if db != "" {
			d.cfg.Database = db
		}
		return d
	}
	for _, c := range []struct {
		key, db string
		want    string // "" = passes
	}{
		{"rd", "", ""},
		{"ui", "", "is a member of pgvigil_auth"},
		{"uiset", "", "is a member of pgvigil_auth"},
		{"su", "", "is a superuser"},
		{"noinh", "", "is a member of "}, // and the owner among the roles named (below)
		{"insu", "", "is a member of "},  // and the superuser role among them (below)
		{"mon", "", "pg_monitor"},
		{"none", "", "may not read the repository"},
		{"rd", other, "reaches another server or database"},
	} {
		got, _ := door(name(c.key), c.db).check(ctx)
		switch {
		case c.want == "" && got != "":
			t.Errorf("%s: refused, want passed: %s", c.key, got)
		case c.want != "" && !strings.Contains(got, c.want):
			t.Errorf("%s on %q: %q, want it to say %q", c.key, c.db, got, c.want)
		case c.want != "" && !strings.Contains(got, "IN ROLE pgvigil_reader alone") && !strings.Contains(got, "GRANT pgvigil_reader") && !strings.Contains(got, "another server"):
			t.Errorf("%s: the words do not say what to do: %q", c.key, got)
		}
		// noinh is a member of the owner, so of pg_database_owner too (the owner owns the database): the words name
		// every role it is a member of, in name order (reportrole-g2: 'is a member of pg_database_owner, postgres')
		if c.key == "noinh" && !memberNamed(got, owner) {
			t.Errorf("noinh: %q, want %s among the roles it is a member of", got, owner)
		}
		if c.key == "insu" && !memberNamed(got, name("su")) {
			t.Errorf("insu: %q, want %s among the roles it is a member of", got, name("su"))
		}
	}
	// the reader-alone login: the role set back and the hash planned at run time is the server's refusal
	d := door(name("rd"), "")
	_, why, err := runPG(ctx, d.cfg, `SELECT set_config('role', 'none', true), query_to_xml('select left(pgvigil.ui_password_hash(''x''), 10) as h', false, false, '')`,
		pgx.NamedArgs{}, 10*time.Second, 10, d.refusal)
	if why != "" || err == nil || !strings.Contains(err.Error(), "permission denied for function ui_password_hash") {
		t.Errorf("the escape on the reader-alone login: refused %q, err %v; want the server's permission denied", why, err)
	}
	// pgRefusal (every PostgreSQL run of user SQL: an instance's custom report, a community tool, EXPLAIN, the advisor's
	// hypothetical index) where the run's database is a repository: a NOINHERIT member of the schema's owner (CREATE
	// answers false for it, SET ROLE reaches the owner) and pg_read_all_data are refused in words; the reader alone runs;
	// on a database without a pgvigil schema pg_read_all_data runs (a monitoring login's usual grant) - the code review
	// of REPORT ROLE, part A; a NOINHERIT member of a superuser role is refused on any database (part B)
	plain := fmt.Sprintf("pgvrr_plain_%d", sfx)
	if _, err := pool.Exec(ctx, `CREATE DATABASE `+plain); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DROP DATABASE IF EXISTS `+plain+` WITH (FORCE)`); err != nil {
			t.Error(err)
		}
	}()
	refusalAs := func(user, db string) string {
		c := base.Copy()
		c.User, c.Password = user, pw
		if db != "" {
			c.Database = db
		}
		conn, err := pgx.ConnectConfig(ctx, c)
		if err != nil {
			t.Fatalf("%s on %q: %v", user, db, err)
		}
		defer func() { _ = conn.Close(context.Background()) }()
		tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(context.Background()) }()
		why, err := pgRefusal(ctx, tx)
		if err != nil {
			t.Fatalf("%s on %q: pgRefusal: %v", user, db, err)
		}
		return why
	}
	for _, c := range []struct {
		key, db, want string // want "" = runs
	}{
		{"noinh", "", "a member of the pgvigil schema's owner"},
		{"rad", "", "a member of pg_read_all_data in a pgvigil repository"},
		{"rd", "", ""},
		{"rad", plain, ""},
		{"insu", plain, "a member of a superuser role"}, // SET ROLE reaches the superuser (part B)
	} {
		got := refusalAs(name(c.key), c.db)
		switch {
		case c.want == "" && got != "":
			t.Errorf("pgRefusal: %s on %q refused, want it to run: %s", c.key, c.db, got)
		case c.want != "" && !strings.Contains(got, c.want):
			t.Errorf("pgRefusal: %s on %q: %q, want it to say %q", c.key, c.db, got, c.want)
		}
	}
	// the door's own words before any connection
	for _, c := range []struct {
		rc   *ReportsConfig
		want string
	}{
		{nil, "reports_dsn in pgvigil.yaml names one"},
		{&ReportsConfig{}, "reports_dsn in pgvigil.yaml names one"},
		{&ReportsConfig{Raw: "env:PGVRR_UNSET", DSN: ""}, "reports_dsn (env:PGVRR_UNSET) resolves to nothing"},
		{&ReportsConfig{Raw: "x", DSN: "host=h port=notaport"}, "reports_dsn does not parse"},
	} {
		if got := s.newReportsDoor(ctx, c.rc).state(ctx); !strings.Contains(got, c.want) {
			t.Errorf("%+v: %q, want %q", c.rc, got, c.want)
		}
	}
}

// TestExplainFoldOnAStore (REPORT ROLE, the design pass's S1): EXPLAIN on a monitoring login plans the DBA's statement,
// and the planner evaluates STABLE functions while it estimates (a hash cast to int then names itself in the error).
// On a migrated repository (PGVIGIL_REPO_TEST_DSN) taken as an instance whose login holds pgvigil_auth: without a check
// (the old behaviour) the run says whether the fold reads the hash - logged, the red's evidence, never a failure either
// way; with pgRefusal the run is refused naming pgvigil_auth and nothing is planned.
func TestExplainFoldOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	login, user, pw := fmt.Sprintf("pgvrr_ex_%d", sfx), fmt.Sprintf("pgvrr%d", sfx), testPassword(t)
	defer func() {
		bg := context.Background()
		if _, err := pool.Exec(bg, `DELETE FROM pgvigil.ui_users WHERE username = $1`, user); err != nil {
			t.Error(err)
		}
		if _, err := pool.Exec(bg, `DROP ROLE IF EXISTS `+login); err != nil {
			t.Error(err)
		}
	}()
	if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE pgvigil_reader, pgvigil_auth`, login, pw)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.ui_users (username, password_hash) VALUES ($1, '$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA')`, user); err != nil {
		t.Fatal(err)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	mon := fmt.Sprintf("host=%s port=%d dbname=%s user=%s password=%s", cfg.Host, cfg.Port, cfg.Database, login, pw)
	stmt := fmt.Sprintf(`SELECT 1 FROM pg_class c WHERE c.relname = (pgvigil.ui_password_hash('%s')::int)::text`, user)
	_, err = plans.Explain(ctx, mon, "", stmt, nil)
	switch {
	case err != nil && strings.Contains(err.Error(), "argon2id"):
		t.Logf("without a check (the old behaviour) the fold READ the hash: %.120s", err.Error())
	default:
		t.Logf("without a check the fold did not read the hash here: %v", err)
	}
	_, err = plans.Explain(ctx, mon, "", stmt, pgRefusal)
	if err == nil || !strings.Contains(err.Error(), "the login is a member of pgvigil_auth") || strings.Contains(err.Error(), "argon2id") {
		t.Errorf("with pgRefusal: %v; want refused naming pgvigil_auth, no hash", err)
	}
}
