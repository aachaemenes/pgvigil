package repo

import (
	"fmt"
	"sort"
	"strings"
	"testing"
)

// funcText is a migration's CREATE OR REPLACE FUNCTION pgvigil.<name>( ... END $$; with its whole-line comments taken
// out (a copy of a function may carry comments of its own; its code lines are what must match).
func funcText(t *testing.T, file, name string) string {
	t.Helper()
	b, err := migrations.ReadFile("sql/" + file)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "CREATE OR REPLACE FUNCTION pgvigil."+name+"(")
	if i < 0 {
		t.Fatalf("%s: no %s", file, name)
	}
	j := strings.Index(s[i:], "END $$;")
	if j < 0 {
		t.Fatalf("%s: %s has no end", file, name)
	}
	var keep []string
	for _, l := range strings.Split(s[i:i+j], "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "--") {
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "\n")
}

// 0488 re-makes 0127's import_admin_instance - 0136 renamed it import_admin_instance_base - to take auth kerberos for a
// PostgreSQL instance. With its two kerberos lines put back as 0127 has them, its code is 0127's line for line: a
// change of 0127's function that 0488 does not carry would be undone on every repository, as 0488 runs later.
func TestAdmin0488IsAdmin0127PlusKerberos(t *testing.T) {
	got := strings.Replace(funcText(t, "0488_pg_kerberos_kind.sql", "import_admin_instance_base"), "pgvigil.import_admin_instance_base(", "pgvigil.import_admin_instance(", 1)
	for _, c := range []struct{ now, was string }{
		{"('sql', 'windows', 'entra', 'entra-identity', 'password', 'pgpass', 'kerberos') THEN", "('sql', 'windows', 'entra', 'entra-identity', 'password', 'pgpass') THEN"},
		{"'auth is sql, windows, entra or entra-identity (SQL Server), password, pgpass or kerberos (PostgreSQL)'", "'auth is sql, windows, entra or entra-identity (SQL Server), password or pgpass (PostgreSQL)'"},
	} {
		if n := strings.Count(got, c.now); n != 1 {
			t.Fatalf("0488's function holds %q %d times, want once", c.now, n)
		}
		got = strings.Replace(got, c.now, c.was, 1)
	}
	want := funcText(t, "0127_entra_identity.sql", "import_admin_instance")
	if got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("0488's function differs from 0127's beyond kerberos at its code line %d:\n0488: %s\n0127: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("0488's function has %d code lines, 0127's %d", len(gl), len(wl))
	}
}

// newestAuthMakerKeepsKerberos: of the migrations given (file name -> text), the newest by name that makes
// admin_instances_auth_check or defines pgvigil.import_admin_instance_base must hold 'kerberos' - a later re-make from
// 0127's text would drop the kind (a Save refused; on a repository holding a kerberos row, the check's ADD CONSTRAINT
// failing with 23514 and the migrate stopping there).
func newestAuthMakerKeepsKerberos(files map[string]string) error {
	var names []string
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	for k := len(names) - 1; k >= 0; k-- {
		s := files[names[k]]
		if strings.Contains(s, "admin_instances_auth_check") || strings.Contains(s, "FUNCTION pgvigil.import_admin_instance_base") {
			if !strings.Contains(s, "'kerberos'") {
				return fmt.Errorf("%s makes the instances' auth check or import_admin_instance_base without 'kerberos'", names[k])
			}
			return nil
		}
	}
	return fmt.Errorf("no migration makes admin_instances_auth_check or import_admin_instance_base")
}

func TestNewestAuthMakerKeepsKerberos(t *testing.T) {
	entries, err := migrations.ReadDir("sql")
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]string{}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".sql") {
			b, err := migrations.ReadFile("sql/" + e.Name())
			if err != nil {
				t.Fatal(err)
			}
			files[e.Name()] = string(b)
		}
	}
	if err := newestAuthMakerKeepsKerberos(files); err != nil {
		t.Fatal(err)
	}
	// the guard catches what it is for: a later file re-making the check from 0127's list
	files["9999_later.sql"] = "ALTER TABLE pgvigil.admin_instances ADD CONSTRAINT admin_instances_auth_check\n  CHECK (auth IN ('sql', 'windows', 'entra', 'entra-identity', 'password', 'pgpass'));"
	if err := newestAuthMakerKeepsKerberos(files); err == nil {
		t.Fatal("a later re-make of the check without 'kerberos' was not caught")
	}
}
