package collect

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// rightsLiteral finds the rights checks in a statement's text: pg_has_role(...) and has_*_privilege(...) up to their
// first closing bracket.
var rightsLiteral = regexp.MustCompile(`(pg_has_role|has_[a-z_]+_privilege)\([^)]*\)?`)

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
		for _, lit := range rightsLiteral.FindAllString(string(b), -1) {
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
		if m := write.FindString(r.Check); m != "" {
			t.Errorf("%s: its check holds a write-shaped word %q", r.Key, m)
		}
	}
	for _, q := range []string{rightsIdentitySQL, rightsNoConnectSQL, rightsSQL(Rights)} {
		if m := write.FindString(q); m != "" {
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
