package collect

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// rightsCall is where a rights check starts: pg_has_role( and has_*_privilege(.
var rightsCall = regexp.MustCompile(`\b(pg_has_role|has_[a-z_]+_privilege)\(`)

// rightsLiterals finds the rights checks in a source's text: each name's call up to its BALANCED closing bracket (a
// check's own inner brackets - DB_NAME(), QUOTENAME(...), to_regprocedure(...) - are part of it), or to the line's end.
func rightsLiterals(src string) []string {
	var out []string
	for _, at := range rightsCall.FindAllStringIndex(src, -1) {
		depth, end := 0, len(src)
	scan:
		for i := at[1] - 1; i < len(src); i++ {
			switch src[i] {
			case '\n':
				end = i
				break scan
			case '(':
				depth++
			case ')':
				if depth--; depth == 0 {
					end = i + 1
					break scan
				}
			}
		}
		out = append(out, src[at[0]:end])
	}
	return out
}

// TestRightsCatalogueNamesEveryCheck (ST2, row R6): every rights check a statement of this package asks about is
// named by a right of the catalogue (its Checks) or by a listed exception with its reason. A collector that asks
// about a new right fails this test until the catalogue names it.
func TestRightsCatalogueNamesEveryCheck(t *testing.T) {
	known := map[string]string{}
	for _, r := range Rights {
		for _, c := range r.Checks {
			known[c] = r.Key
		}
	}
	for c := range RightsExceptions {
		if k, dup := known[c]; dup {
			t.Errorf("%s is both the right %s's and an exception", c, k)
		}
		known[c] = "exception"
	}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") || f == "rights.go" {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, lit := range rightsLiterals(string(b)) {
			seen[lit] = true
			if _, ok := known[lit]; !ok {
				t.Errorf("%s asks %s: no right of the catalogue (rights.go) and no exception names it", f, lit)
			}
		}
	}
	for c, k := range known {
		if !seen[c] {
			t.Errorf("%s (%s) is named in rights.go, and no statement of the package asks it any more", c, k)
		}
	}
	if len(seen) < 10 {
		t.Errorf("only %d checks found in the package's statements: the scan is broken", len(seen))
	}
}

// unquoted is a statement with its string literals taken out: a privilege's name ('CREATE', 'EXECUTE') is a value the
// server is asked about, not a statement.
func unquoted(q string) string { return regexp.MustCompile(`'[^']*'`).ReplaceAllString(q, "''") }

// TestRightsCatalogueShape: keys unique and usable as column names; each right has its words, a check that reads only
// and a statement that names the login only through its placeholder.
func TestRightsCatalogueShape(t *testing.T) {
	key := regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	write := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COPY|DO|CALL)\b`)
	seen := map[string]bool{}
	for _, r := range Rights {
		if !key.MatchString(r.Key) || seen[r.Key] {
			t.Errorf("key %q: not a plain name, or twice", r.Key)
		}
		seen[r.Key] = true
		if r.Name == "" || r.For == "" || r.Check == "" || r.Grant == "" || r.On == nil || len(r.Checks) == 0 {
			t.Errorf("%s: a field is empty", r.Key)
		}
		if !strings.Contains(r.Grant, "{role}") {
			t.Errorf("%s: its statement names no {role}: %s", r.Key, r.Grant)
		}
		if m := regexp.MustCompile(`(?i)\b(SUPERUSER|BYPASSRLS|CREATEROLE|pg_read_server_files|pg_write_server_files|pg_execute_server_program)\b`).FindString(r.Grant); m != "" && r.Key != "server_log_read" {
			t.Errorf("%s: its statement holds %q", r.Key, m)
		}
		if m := write.FindString(unquoted(r.Check)); m != "" {
			t.Errorf("%s: its check holds a write-shaped word %q", r.Key, m)
		}
	}
	for _, q := range []string{rightsIdentitySQL, rightsNoConnectSQL, rightsSQL(Rights)} {
		if m := write.FindString(unquoted(q)); m != "" {
			t.Errorf("a statement of the read holds %q", m)
		}
	}
}

// TestRightsOnPlatforms: a managed platform lists the rights only a superuser can give as not applying; the two core
// rights apply everywhere.
func TestRightsOnPlatforms(t *testing.T) {
	listed := func(i platform.Info) (apply, off string) {
		var a, o []string
		for _, r := range Rights {
			if r.On(i) == "" {
				a = append(a, r.Key)
			} else {
				o = append(o, r.Key)
			}
		}
		return strings.Join(a, " "), strings.Join(o, " ")
	}
	if a, o := listed(platform.Info{Kind: platform.OnPrem}); a != "pg_monitor connect server_log_list server_log_read hba_rules" || o != "" {
		t.Errorf("self-managed: apply %q, off %q", a, o)
	}
	if a, o := listed(platform.Info{Kind: platform.Kind("rds")}); a != "pg_monitor connect" || o != "server_log_list server_log_read hba_rules" {
		t.Errorf("a managed platform: apply %q, off %q", a, o)
	}
}

// TestRightsScript: the printed script holds the missing rights' statements only, each under its name; nothing
// missing prints nothing.
func TestRightsScript(t *testing.T) {
	r := RightsRead{Login: "Mon User", Server: "10.0.0.5:5432", Missing: 2, Rights: []RightState{
		{Key: "pg_monitor", Name: "pg_monitor", Core: true, For: "statistics", State: "missing", Grant: `GRANT pg_monitor TO "Mon User";`},
		{Key: "connect", Name: "CONNECT on every database", Core: true, For: "each database", State: "missing",
			Grant: "GRANT CONNECT ON DATABASE app TO \"Mon User\";\nGRANT CONNECT ON DATABASE \"Crm\" TO \"Mon User\";", Databases: []string{"app", `"Crm"`}},
		{Key: "hba_rules", Name: "SELECT on pg_hba_file_rules", For: "hba", State: "held"},
	}}
	want := "-- pgvigil: the rights its monitoring login Mon User lacks on 10.0.0.5:5432 (read 2026-11-15 20:00 UTC).\n" +
		"-- Run it as an administrator of that server. pgvigil did not run it and never does.\n" +
		"\n-- pg_monitor (needed): statistics\nGRANT pg_monitor TO \"Mon User\";\n" +
		"\n-- CONNECT on every database (needed): each database\nGRANT CONNECT ON DATABASE app TO \"Mon User\";\nGRANT CONNECT ON DATABASE \"Crm\" TO \"Mon User\";\n"
	if got := r.Script("2026-11-15 20:00 UTC"); got != want {
		t.Errorf("the script:\n%s\nwant:\n%s", got, want)
	}
	if got := (RightsRead{Login: "m", Server: "S"}).Script("now"); got != "" {
		t.Errorf("nothing missing printed %q", got)
	}
}

// TestRightsGuard (review F1): a name the server answered that holds a line break or another control character - the
// login, the server, the database, a listed database - prints no script and takes every statement out; a plain name
// prints one, with the database it is run in named in its head (review F7).
func TestRightsGuard(t *testing.T) {
	read := func(login, server, db, listed string) RightsRead {
		return RightsRead{Login: login, Server: server, Database: db, Missing: 1, MissingCore: 1, Rights: []RightState{
			{Key: "connect", Name: "CONNECT on every database", Core: true, For: "each database", State: "missing",
				Grant: `GRANT CONNECT ON DATABASE ` + listed + ` TO "m";`, Databases: []string{listed}}}}
	}
	for _, c := range []struct {
		name, login, server, db, listed string
		script                          bool
	}{
		{"plain names", "m", "pg1", "app", "crm", true},
		{"a listed database across a line break", "m", "pg1", "app", "\"x\nALTER ROLE m SUPERUSER;--\"", false},
		{"a role across a line break", "x\nALTER ROLE m SUPERUSER;--", "pg1", "app", "crm", false},
		{"a cluster_name with U+2029", "m", "pg1 x", "app", "crm", false},
	} {
		r := read(c.login, c.server, c.db, c.listed)
		r.guard()
		got := r.Script("now")
		if c.script != (got != "") {
			t.Errorf("%s: script printed %v (want %v): no_script %q", c.name, got != "", c.script, r.NoScript)
		}
		if c.script && !strings.Contains(got, "-- Run it connected to the database app: ") {
			t.Errorf("%s: the head does not name the database:\n%s", c.name, got)
		}
		if !c.script && (r.NoScript == "" || r.Rights[0].Grant != "" || strings.Contains(got, "SUPERUSER")) {
			t.Errorf("%s: no_script %q, a statement left %q", c.name, r.NoScript, r.Rights[0].Grant)
		}
	}
}

// TestRightsDoorGuarded (review F7): the server log's door is printed as CREATE OR REPLACE (a door made for an earlier
// role does not stop the script), granted to the role's placeholder.
func TestRightsDoorGuarded(t *testing.T) {
	for _, r := range Rights {
		if r.Key != "server_log_read" {
			continue
		}
		if !strings.Contains(r.Grant, "CREATE OR REPLACE FUNCTION public.pgvigil_read_log(") || strings.Contains(strings.Replace(r.Grant, "CREATE OR REPLACE FUNCTION", "", 1), "CREATE FUNCTION") {
			t.Errorf("the door is not CREATE OR REPLACE:\n%s", r.Grant)
		}
		if !strings.Contains(r.Grant, "{role}") || strings.Contains(r.Grant, "<login>") {
			t.Errorf("the door's grantee is not the role's placeholder:\n%s", r.Grant)
		}
		return
	}
	t.Fatal("no server_log_read right")
}
