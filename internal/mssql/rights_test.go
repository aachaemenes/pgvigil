package mssql

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// rightsCall is where a rights check starts: HAS_PERMS_BY_NAME(, HAS_DBACCESS(, IS_SRVROLEMEMBER(, IS_ROLEMEMBER(,
// IS_MEMBER(.
var rightsCall = regexp.MustCompile(`\b(HAS_PERMS_BY_NAME|HAS_DBACCESS|IS_SRVROLEMEMBER|IS_ROLEMEMBER|IS_MEMBER)\(`)

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
		for _, lit := range rightsLiterals(string(b)) {
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

// unquoted is a statement with its string literals taken out: a permission's name ('ALTER TRACE', 'EXECUTE') is a
// value the server is asked about, not a statement: the scan once took 'ALTER TRACE' for an ALTER.
func unquoted(q string) string { return regexp.MustCompile(`'[^']*'`).ReplaceAllString(q, "''") }

// TestRightsCatalogueShape: keys unique and usable as column names; each right has its words, a check that reads only
// (judged outside its string literals) and a statement that names its principal only through a placeholder ({p} the
// login or its user, {login} the login, {user} the database user).
func TestRightsCatalogueShape(t *testing.T) {
	key := regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	write := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|GRANT|DENY|REVOKE|EXEC|EXECUTE)\b`)
	seen := map[string]bool{}
	for _, r := range Rights {
		if !key.MatchString(r.Key) || seen[r.Key] {
			t.Errorf("key %q: not a plain name, or twice", r.Key)
		}
		seen[r.Key] = true
		if r.Name == "" || r.For == "" || r.Check == "" || r.Grant == "" || r.On == nil || len(r.Checks) == 0 {
			t.Errorf("%s: a field is empty", r.Key)
		}
		if !strings.Contains(r.Grant, "{p}") && !strings.Contains(r.Grant, "{login}") && !strings.Contains(r.Grant, "{user}") {
			t.Errorf("%s: its statement names no principal placeholder: %s", r.Key, r.Grant)
		}
		if r.UserDB != "" && r.UserDB != "master" && r.UserDB != "msdb" {
			t.Errorf("%s: its user's database %q is neither master nor msdb (the read resolves those two)", r.Key, r.UserDB)
		}
		if m := regexp.MustCompile(`(?i)\b(DROP|DELETE|UPDATE|INSERT|TRUNCATE|SHUTDOWN|sysadmin|CONTROL SERVER|securityadmin|db_owner)\b`).FindString(r.Grant); m != "" {
			t.Errorf("%s: its statement holds %q", r.Key, m)
		}
		if m := write.FindString(unquoted(r.Check)); m != "" {
			t.Errorf("%s: its check holds a write-shaped word %q", r.Key, m)
		}
	}
	for _, q := range []string{rightsIdentitySQL, rightsNoAccessSQL, rightsSQL(Rights)} {
		if m := write.FindString(unquoted(q)); m != "" {
			t.Errorf("a statement of the read holds %q", m)
		}
	}
}

// TestRightsOnPlatforms: which rights are listed where. Azure SQL Database lists its database right - or, on Basic,
// S0, S1 and in an elastic pool, ##MS_ServerStateReader## (Detect asks the server-level right there) - and the database's
// VIEW DEFINITION (the schema read's probe; VIEW ANY DEFINITION is a server right it does not have); a managed platform
// lists the registry rights as not applying; Cloud SQL lists CONNECT ANY DATABASE as not grantable; before SQL Server
// 2022 the audit's events say why; Amazon RDS lists its own reader. Pool history's dbmanager (an opt-in, P25 task 9b)
// is listed only in an elastic pool.
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
	const (
		head    = "view_server_state view_any_definition msdb_reader"
		azHide  = "view_database_state azure_server_state_reader azure_dbmanager_pool_history view_definition_db"
		dbRight = "view_any_definition msdb_reader database_access restore_history registry_instance registry_machine default_trace audit_events audit_events_rds sp_whoisactive"
	)
	for _, c := range []struct {
		name               string
		info               Info
		apply, off, hidden string
	}{
		{"SQL Server 2022", Info{Major: 16}, head + " database_access restore_history registry_instance registry_machine default_trace audit_events sp_whoisactive", "", azHide + " audit_events_rds"},
		{"SQL Server 2019", Info{Major: 15}, head + " database_access restore_history registry_instance registry_machine default_trace sp_whoisactive", "audit_events", azHide + " audit_events_rds"},
		{"Azure SQL Database (a vCore database)", Info{Kind: KindAzureDB, Major: 12, ServiceObjective: "GP_Gen5_2"}, "view_database_state view_definition_db", "", "view_server_state azure_server_state_reader azure_dbmanager_pool_history " + dbRight},
		{"Azure SQL Database S0", Info{Kind: KindAzureDB, Major: 12, ServiceObjective: "S0"}, "azure_server_state_reader view_definition_db", "", "view_server_state view_database_state azure_dbmanager_pool_history " + dbRight},
		{"Azure SQL Database in an elastic pool", Info{Kind: KindAzureDB, Major: 12, ServiceObjective: "ElasticPool"}, "azure_server_state_reader azure_dbmanager_pool_history view_definition_db", "", "view_server_state view_database_state " + dbRight},
		{"Azure SQL Managed Instance", Info{Kind: KindAzureMI, Major: 12}, head + " database_access restore_history default_trace audit_events sp_whoisactive", "registry_instance registry_machine", azHide + " audit_events_rds"},
		{"Amazon RDS 2019", Info{Kind: KindRDS, Major: 15}, head + " database_access restore_history default_trace audit_events_rds sp_whoisactive", "registry_instance registry_machine", azHide + " audit_events"},
		{"Google Cloud SQL 2022", Info{Kind: KindCloudSQL, Major: 16}, head + " restore_history default_trace audit_events sp_whoisactive", "database_access registry_instance registry_machine", azHide + " audit_events_rds"},
	} {
		if a, o, h := listed(c.info); a != c.apply || o != c.off || h != c.hidden {
			t.Errorf("%s:\n apply  %s\n   want %s\n off    %s\n   want %s\n hidden %s\n   want %s", c.name, a, c.apply, o, c.off, h, c.hidden)
		}
	}
}

// TestRightsGuard (review F1): a name the server answered that holds a line break or another control character -
// the login, the server, a user, a listed database - prints no script and takes every statement out; so does an
// account with no login of its own (a Windows group's member); a plain name prints one.
func TestRightsGuard(t *testing.T) {
	read := func(login, server, db string) RightsRead {
		return RightsRead{Login: login, Server: server, Missing: 1, MissingCore: 1, Rights: []RightState{
			{Key: "database_access", Name: "CONNECT ANY DATABASE", Core: true, For: "each database", State: "missing",
				Grant: "USE master;\nGRANT CONNECT ANY DATABASE TO [m];", Databases: []string{db}}}}
	}
	for _, c := range []struct {
		name, login, server, db string
		own                     bool
		script                  bool
	}{
		{"plain names", "m", "S1", "[app]", true, true},
		{"a database across a line break", "m", "S1", "[a\nALTER SERVER ROLE sysadmin ADD MEMBER [m];--]", true, false},
		{"a login with a carriage return", "m\rx", "S1", "[app]", true, false},
		{"a server name with U+2028", "m", "S1\u2028x", "[app]", true, false},
		{"a tab in a database name", "m", "S1", "[a\tb]", true, false},
		{"a Windows group's member", "CORP\\svc", "S1", "[app]", false, false},
	} {
		r := read(c.login, c.server, c.db)
		r.guard(rightsIdentity{login: c.login, server: c.server, ownLogin: c.own}, Info{Major: 16})
		got := r.Script("now")
		if c.script != (got != "") {
			t.Errorf("%s: script printed %v (want %v): no_script %q", c.name, got != "", c.script, r.NoScript)
		}
		if !c.script && (r.NoScript == "" || r.Rights[0].Grant != "" || strings.Contains(got, "ALTER SERVER ROLE")) {
			t.Errorf("%s: no_script %q, a statement left %q", c.name, r.NoScript, r.Rights[0].Grant)
		}
	}
}

// TestRightsGrantFor (review F5): a server permission names the login; a database's names the user the read found
// mapped to the login's SID, under its own name; with none found the block finds it when it runs, creates one only
// where neither it nor a same-named user is there, and raises an error rather than grant to a same-named user that is
// not the login's. Names are filled in one pass: a login whose name holds a placeholder's text is not filled again.
func TestRightsGrantFor(t *testing.T) {
	byKey := map[string]Right{}
	for _, r := range Rights {
		byKey[r.Key] = r
	}
	id := rightsIdentity{login: "m{p}", quoted: "[m{p}]", literal: "N'm{p}'", ownLogin: true, users: map[string]string{"msdb": "[mon_user]"}}
	if got := grantFor(byKey["view_server_state"], id); got != "USE master;\nGRANT VIEW SERVER STATE TO [m{p}];" {
		t.Errorf("a server permission: %q", got)
	}
	if got := grantFor(byKey["msdb_reader"], id); got != "USE msdb;\nALTER ROLE db_datareader ADD MEMBER [mon_user];\nGO" {
		t.Errorf("a database's, the user found: %q", got)
	}
	got := grantFor(byKey["registry_instance"], id) // master: no user found
	for _, want := range []string{
		"USE master;\n",
		"DECLARE @pgv_user sysname = (SELECT name FROM sys.database_principals WHERE sid = SUSER_SID(N'm{p}'));",
		"IF @pgv_user IS NULL AND DATABASE_PRINCIPAL_ID(N'm{p}') IS NULL",
		"CREATE USER [m{p}] FOR LOGIN [m{p}];",
		"RAISERROR(N'pgvigil: a user named as the login is in this database but is not mapped to the login",
		"DECLARE @pgv_sql nvarchar(max) = N'GRANT EXECUTE ON dbo.xp_instance_regread TO ' + QUOTENAME(@pgv_user) + N';';",
		"EXEC sys.sp_executesql @pgv_sql;",
		"\nGO",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("the block without a user found lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "EXEC (") {
		t.Errorf("the block runs a function call through EXEC (), which T-SQL refuses:\n%s", got)
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

// TestRightsMsdbTables (review F12): every msdb table a collector asks msdbReadable about - a literal argument, or a
// table of an inline list it loops over - is one msdb_reader's check asks, so the row never reads 'held' while a
// collection is skipped for a table it does not ask.
func TestRightsMsdbTables(t *testing.T) {
	asked := map[string]bool{}
	for _, tb := range msdbReaderTables {
		asked[tb] = true
		if !strings.Contains(msdbReaderCheck(), "N'msdb.dbo."+tb+"'") {
			t.Errorf("msdb_reader's check does not ask %s", tb)
		}
	}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	literal := regexp.MustCompile(`msdbReadable\(ctx, conn, "(\w+)"\)`)
	inline := regexp.MustCompile(`range \[\]string\{([^}]*)\} \{\s*if err := msdbReadable\(`)
	word := regexp.MustCompile(`"(\w+)"`)
	found := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var tables []string
		for _, m := range literal.FindAllStringSubmatch(string(b), -1) {
			tables = append(tables, m[1])
		}
		for _, m := range inline.FindAllStringSubmatch(string(b), -1) {
			for _, w := range word.FindAllStringSubmatch(m[1], -1) {
				tables = append(tables, w[1])
			}
		}
		for _, tb := range tables {
			found++
			if !asked[tb] {
				t.Errorf("%s asks msdbReadable about msdb.dbo.%s: msdb_reader's check (msdbReaderTables) does not", f, tb)
			}
		}
	}
	if found < 3 {
		t.Errorf("only %d msdb tables found at the calls: the scan is broken", found)
	}
}
