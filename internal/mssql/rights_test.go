package mssql

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// rightsLiteral finds the rights checks in a statement's text: HAS_PERMS_BY_NAME(...), HAS_DBACCESS(...),
// IS_SRVROLEMEMBER(...), IS_ROLEMEMBER(...), IS_MEMBER(...) up to their first closing bracket.
var rightsLiteral = regexp.MustCompile(`(HAS_PERMS_BY_NAME|HAS_DBACCESS|IS_SRVROLEMEMBER|IS_ROLEMEMBER|IS_MEMBER)\([^)]*\)?`)

// TestRightsCatalogueNamesEveryCheck (ST2, row R6): every rights check a statement of this package asks about is
// named by a right of the catalogue (its Checks) or by a listed exception with its reason. A collector that asks
// about a new right fails this test until the catalogue names it - so the Rights read never lacks a right a
// collection is skipped for.
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
	// a name the catalogue holds that no statement asks any more is stale
	for c, k := range known {
		if !seen[c] {
			t.Errorf("%s (%s) is named in rights.go, and no statement of the package asks it any more", c, k)
		}
	}
	if len(seen) < 10 {
		t.Errorf("only %d checks found in the package's statements: the scan is broken", len(seen))
	}
}

// TestRightsCatalogueShape: keys unique and usable as column names; each right has its words, a check and a statement
// that names the login only through the placeholders (no name typed into a statement).
func TestRightsCatalogueShape(t *testing.T) {
	key := regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	seen := map[string]bool{}
	for _, r := range Rights {
		if !key.MatchString(r.Key) || seen[r.Key] {
			t.Errorf("key %q: not a plain name, or twice", r.Key)
		}
		seen[r.Key] = true
		if r.Name == "" || r.For == "" || r.Check == "" || r.Grant == "" || r.On == nil || len(r.Checks) == 0 {
			t.Errorf("%s: a field is empty", r.Key)
		}
		if !strings.Contains(r.Grant, "{login}") && !strings.Contains(r.Grant, "{user}") {
			t.Errorf("%s: its statement names no principal placeholder: %s", r.Key, r.Grant)
		}
		if m := regexp.MustCompile(`(?i)\b(DROP|DELETE|UPDATE|INSERT|TRUNCATE|SHUTDOWN|sysadmin|CONTROL SERVER|securityadmin|db_owner)\b`).FindString(r.Grant); m != "" {
			t.Errorf("%s: its statement holds %q", r.Key, m)
		}
		if m := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|GRANT|DENY|REVOKE|EXEC)\b`).FindString(r.Check); m != "" {
			t.Errorf("%s: its check holds a write-shaped word %q", r.Key, m)
		}
	}
	for _, q := range []string{rightsIdentitySQL, rightsNoAccessSQL, rightsSQL(Rights)} {
		if m := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|GRANT|DENY|REVOKE|EXEC)\b`).FindString(q); m != "" {
			t.Errorf("a statement of the read holds %q", m)
		}
	}
}

// TestRightsOnPlatforms: which rights are listed where. Azure SQL Database lists its database right alone; a managed
// platform lists the registry rights as not applying; before SQL Server 2022 the audit's events say why; Amazon RDS
// lists its own reader.
func TestRightsOnPlatforms(t *testing.T) {
	listed := func(i Info) (apply, off, hidden string) {
		var a, o, h []string
		for _, r := range Rights {
			switch on := r.On(i); on {
			case "":
				a = append(a, r.Key)
			case "hide":
				h = append(h, r.Key)
			default:
				o = append(o, r.Key)
			}
		}
		return strings.Join(a, " "), strings.Join(o, " "), strings.Join(h, " ")
	}
	const server = "view_server_state view_any_definition msdb_reader database_access restore_history"
	for _, c := range []struct {
		name               string
		info               Info
		apply, off, hidden string
	}{
		{"SQL Server 2022", Info{Major: 16}, server + " registry_instance registry_machine default_trace audit_events sp_whoisactive", "", "view_database_state audit_events_rds"},
		{"SQL Server 2019", Info{Major: 15}, server + " registry_instance registry_machine default_trace sp_whoisactive", "audit_events", "view_database_state audit_events_rds"},
		{"Azure SQL Database", Info{Kind: KindAzureDB, Major: 12}, "view_database_state", "", "view_server_state view_any_definition msdb_reader database_access restore_history registry_instance registry_machine default_trace audit_events audit_events_rds sp_whoisactive"},
		{"Azure SQL Managed Instance", Info{Kind: KindAzureMI, Major: 12}, server + " default_trace audit_events sp_whoisactive", "registry_instance registry_machine", "view_database_state audit_events_rds"},
		{"Amazon RDS 2019", Info{Kind: KindRDS, Major: 15}, server + " default_trace audit_events_rds sp_whoisactive", "registry_instance registry_machine", "view_database_state audit_events"},
	} {
		if a, o, h := listed(c.info); a != c.apply || o != c.off || h != c.hidden {
			t.Errorf("%s:\n apply  %s\n   want %s\n off    %s\n   want %s\n hidden %s\n   want %s", c.name, a, c.apply, o, c.off, h, c.hidden)
		}
	}
}

// TestRightsScript: the printed script holds the missing rights' statements only, each under its name, says whose it
// is and that pgvigil ran nothing; nothing missing prints nothing.
func TestRightsScript(t *testing.T) {
	r := RightsRead{Login: "pgv mon", Server: "SQL01", Missing: 2, Rights: []RightState{
		{Key: "view_server_state", Name: "VIEW SERVER STATE", Core: true, For: "the live reads", State: "held"},
		{Key: "view_any_definition", Name: "VIEW ANY DEFINITION", Core: true, For: "metadata", State: "missing", Grant: "USE master;\nGRANT VIEW ANY DEFINITION TO [pgv mon];"},
		{Key: "database_access", Name: "CONNECT ANY DATABASE", Core: true, For: "each database", State: "missing", Grant: "USE master;\nGRANT CONNECT ANY DATABASE TO [pgv mon];", Databases: []string{"app", "crm"}},
		{Key: "default_trace", Name: "ALTER TRACE", For: "the default trace", State: "held"},
	}}
	want := "-- pgvigil: the rights its monitoring login pgv mon lacks on SQL01 (read 2026-11-15 20:00 UTC).\n" +
		"-- Run it as an administrator of that server. pgvigil did not run it and never does.\n" +
		"\n-- VIEW ANY DEFINITION (needed): metadata\nUSE master;\nGRANT VIEW ANY DEFINITION TO [pgv mon];\n" +
		"\n-- CONNECT ANY DATABASE (needed): each database\n-- the login cannot enter: app, crm\nUSE master;\nGRANT CONNECT ANY DATABASE TO [pgv mon];\n"
	if got := r.Script("2026-11-15 20:00 UTC"); got != want {
		t.Errorf("the script:\n%s\nwant:\n%s", got, want)
	}
	if got := (RightsRead{Login: "m", Server: "S"}).Script("now"); got != "" {
		t.Errorf("nothing missing printed %q", got)
	}
}
