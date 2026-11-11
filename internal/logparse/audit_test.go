package logparse

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestSplitAuditCSV(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
		ok   bool
	}{
		{`SESSION,1,1,READ,SELECT,,,select 1,<not logged>`, []string{"SESSION", "1", "1", "READ", "SELECT", "", "", "select 1", "<not logged>"}, true},
		// a comma, a doubled quote and a line break inside a quoted field
		{"a,\"b,c\",\"say \"\"hi\"\"\",\"two\nlines\",z", []string{"a", "b,c", `say "hi"`, "two\nlines", "z"}, true},
		// a quoted object name: "My Schema"."t"
		{`OBJECT,2,1,READ,SELECT,TABLE,"""My Schema"".""t""",<not logged>,<not logged>`, []string{"OBJECT", "2", "1", "READ", "SELECT", "TABLE", `"My Schema"."t"`, "<not logged>", "<not logged>"}, true},
		{`a,,`, []string{"a", "", ""}, true},
		{`a,""`, []string{"a", ""}, true},
		// the text ends inside a quoted field
		{`a,b,"cut here`, []string{"a", "b", "cut here"}, false},
		{``, []string{""}, true},
	} {
		got, ok := splitAuditCSV(c.in)
		if !reflect.DeepEqual(got, c.want) || ok != c.ok {
			t.Errorf("splitAuditCSV(%q) = %q, %v; want %q, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestParseAuditMessage(t *testing.T) {
	e, ok := ParseAuditMessage(`AUDIT: SESSION,7,2,DDL,CREATE TABLE,TABLE,public.account,"create table account (id int, name text default 'a,b')","1,""x"""`)
	if !ok {
		t.Fatal("not parsed")
	}
	want := AuditEntry{Type: "SESSION", StatementID: 7, SubstatementID: 2, Class: "DDL", Command: "CREATE TABLE", ObjectType: "TABLE",
		ObjectName: "public.account", Statement: "create table account (id int, name text default 'a,b')", Parameters: `1,"x"`, Rows: -1}
	if e != want {
		t.Errorf("got %+v\nwant %+v", e, want)
	}
	// pgaudit.log_rows: a tenth field
	e, ok = ParseAuditMessage(`AUDIT: SESSION,1,1,WRITE,INSERT,TABLE,public.t,insert into t select 1,<none>,42`)
	if !ok || e.Rows != 42 || e.Parameters != "" || e.Statement != "insert into t select 1" {
		t.Errorf("rows entry: %+v %v", e, ok)
	}
	// the texts pgaudit writes in place of a statement are not a statement
	for _, hidden := range []string{"<not logged>,<not logged>", "<previously logged>,<previously logged>"} {
		e, ok = ParseAuditMessage("AUDIT: OBJECT,3,1,READ,SELECT,TABLE,public.t," + hidden)
		if !ok || e.Statement != "" || e.Parameters != "" || e.Type != "OBJECT" {
			t.Errorf("%s: %+v %v", hidden, e, ok)
		}
	}
	// a statement cut by the end of the read: the fixed fields stand, the entry says it is cut
	e, ok = ParseAuditMessage(`AUDIT: SESSION,4,1,ROLE,GRANT,TABLE,,"grant select` + "\n on t")
	if !ok || !e.Truncated || e.Class != "ROLE" || e.Command != "GRANT" || e.Statement != "grant select\n on t" {
		t.Errorf("cut entry: %+v %v", e, ok)
	}
	for _, bad := range []string{
		"duration: 1.2 ms  statement: select 1",
		"AUDIT: SESSION,1,1,READ,SELECT",                // too few fields
		"AUDIT: OTHER,1,1,READ,SELECT,,,x,y",            // not an audit type
		"AUDIT: SESSION,one,1,READ,SELECT,,,x,y",        // the id is not a number
		`AUDIT: SESSION,1,1,READ,SELECT,TABLE,"public.`, // cut inside the object name
		"AUDIT: SESSION,1,1,,SELECT,,,x,y",              // no class
		"audit: SESSION,1,1,READ,SELECT,,,x,y",          // not pgaudit's prefix
	} {
		if _, ok := ParseAuditMessage(bad); ok {
			t.Errorf("parsed %q", bad)
		}
	}
}

const auditLog = "2026-11-11 12:00:00 UTC:10.0.0.5(54321):app@shop:[1234]:LOG:  AUDIT: SESSION,1,1,ROLE,CREATE ROLE,,,CREATE ROLE auditor LOGIN PASSWORD <REDACTED>,<not logged>\n" +
	"2026-11-11 12:00:01 UTC:10.0.0.5(54321):app@shop:[1234]:LOG:  AUDIT: SESSION,2,1,DDL,CREATE TABLE,TABLE,public.account,\"create table account\n" +
	"\t(\n" +
	"\t\tid int, -- a tab-led line of the statement\n" +
	"\n" + // a line that is neither tab-led nor prefixed is passed over
	"\t\tname text default 'x,\"\"y\"\"'\n" +
	"\t);\",<not logged>\n" +
	"2026-11-11 12:00:01 UTC:10.0.0.5(54321):app@shop:[1234]:LOG:  duration: 3.1 ms  statement: select 'AUDIT: SESSION,9,9,READ,SELECT,,,x,y'\n" +
	"2026-11-11 12:00:02.250 PST:[local]:postgres@postgres:[77]:LOG:  AUDIT: OBJECT,5,1,READ,SELECT,TABLE,public.account,select * from account where id = $1,\"7\"\n" +
	"2026-11-11 12:00:02 UTC:10.0.0.5(54321):app@shop:[1234]:ERROR:  relation \"nope\" does not exist at character 15\n" +
	"2026-11-11 12:00:02 UTC:10.0.0.5(54321):app@shop:[1234]:STATEMENT:  select * from nope\n" +
	"2026-11-11 12:00:03 UTC:10.0.0.5(54321):app@shop:[1234]:WARNING:  AUDIT: SESSION,3,1,MISC,SET,,,set pgaudit.log = 'none',<not logged>\n"

func TestScanAudit(t *testing.T) {
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skip(err)
	}
	got, err := ParseAudit(strings.NewReader(auditLog), la)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 4 {
		t.Fatalf("%d entries, want 4 (the slow statement that quotes an AUDIT line and the ERROR are not entries): %+v", len(got), got)
	}
	a := got[0]
	if a.Class != "ROLE" || a.Command != "CREATE ROLE" || a.User != "app" || a.Database != "shop" || a.Client != "10.0.0.5(54321)" || a.PID != 1234 ||
		a.At.UTC().Format(time.RFC3339) != "2026-11-11T12:00:00Z" || a.Statement != "CREATE ROLE auditor LOGIN PASSWORD <REDACTED>" {
		t.Errorf("entry 0: %+v", a)
	}
	b := got[1]
	wantStmt := "create table account\n(\n\tid int, -- a tab-led line of the statement\n\tname text default 'x,\"y\"'\n);"
	if b.Class != "DDL" || b.ObjectType != "TABLE" || b.ObjectName != "public.account" || b.Statement != wantStmt || b.Truncated {
		t.Errorf("entry 1: %+v\nstatement %q\nwant      %q", b, b.Statement, wantStmt)
	}
	// the key is the first line alone: the entry read again with more of its lines keeps it
	if !strings.HasSuffix(b.Key, `|LOG|1234|AUDIT: SESSION,2,1,DDL,CREATE TABLE,TABLE,public.account,"create table account`) {
		t.Errorf("entry 1 key: %q", b.Key)
	}
	c := got[2]
	// a zone abbreviation that is not UTC is read in the server's log_timezone: 12:00:02.250 PST = 20:00:02.250 UTC
	if c.Type != "OBJECT" || c.Parameters != "7" || c.User != "postgres" || c.Client != "[local]" ||
		c.At.UTC().Format("15:04:05.000") != "20:00:02.250" {
		t.Errorf("entry 2: %+v at %s", c, c.At.UTC())
	}
	// pgaudit.log_level warning: the level is not part of what makes a line an entry
	d := got[3]
	if d.Class != "MISC" || d.LogClass() != "MISC_SET" || d.Command != "SET" || d.Statement != "set pgaudit.log = 'none'" {
		t.Errorf("entry 3: %+v", d)
	}
	// ParseIn takes none of them as an event of its own kinds, but for the WARNING-level one, which it keeps as an error
	evs, _ := ParseIn(strings.NewReader(auditLog), la)
	for _, ev := range evs {
		if strings.HasPrefix(ev.Detail, "AUDIT: ") && ev.Level == "LOG" {
			t.Errorf("ParseIn took a LOG-level AUDIT line: %+v", ev)
		}
	}
}

// The lines pgaudit 18.0 wrote on PostgreSQL 18.6 for the statements the proof runs (box job s157-rawlog, 2026-11-11),
// under the on-prem reader's rewrite. What they settle: a SET and a RESET carry the class MISC though pgaudit.log
// named misc_set and not misc; a GRANT on a table names the object type and no object; a role's password is cut
// with everything after it; a DROP TABLE writes one entry per dropped object, all under one statement id.
const pgaudit18Log = `2026-11-11 21:34:57.550 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,1,1,DDL,CREATE EXTENSION,,,create extension pgaudit,<not logged>
2026-11-11 21:34:57.558 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,2,1,DDL,CREATE TABLE,TABLE,public.t,"create table public.t (id int, note text)",<not logged>
2026-11-11 21:34:57.562 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,3,1,DDL,CREATE TABLE,TABLE,public.t2,create table public.t2 (id int primary key),<not logged>
2026-11-11 21:34:57.562 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,3,1,DDL,CREATE INDEX,INDEX,public.t2_pkey,create table public.t2 (id int primary key),<not logged>
2026-11-11 21:34:57.573 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,4,1,ROLE,CREATE ROLE,,,create role app1 login password <REDACTED>,<not logged>
2026-11-11 21:34:57.574 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,5,1,ROLE,GRANT,TABLE,,grant select on public.t to app1,<not logged>
2026-11-11 21:34:57.576 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,6,1,ROLE,GRANT ROLE,,,grant pg_monitor to app1,<not logged>
2026-11-11 21:34:57.578 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,7,1,DDL,DROP TABLE,TABLE,public.t2,drop table public.t2,<not logged>
2026-11-11 21:34:57.578 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,7,1,DDL,DROP TABLE,TABLE CONSTRAINT,t2_id_not_null on public.t2,drop table public.t2,<not logged>
2026-11-11 21:34:57.578 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,7,1,DDL,DROP TABLE,TABLE CONSTRAINT,t2_pkey on public.t2,drop table public.t2,<not logged>
2026-11-11 21:34:57.578 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,7,1,DDL,DROP TABLE,INDEX,public.t2_pkey,drop table public.t2,<not logged>
2026-11-11 21:34:57.580 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,8,1,MISC,SET,,,set pgaudit.log_catalog = off,<not logged>
2026-11-11 21:34:57.580 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,9,1,MISC,SET,,,set role app1,<not logged>
2026-11-11 21:34:57.580 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,10,1,MISC,RESET,,,reset role,<not logged>
2026-11-11 21:34:57.580 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,11,1,READ,SELECT,TABLE,public.t,select note from public.t where id = 1,<not logged>
2026-11-11 21:34:57.580 UTC::postgres@postgres:[104]:LOG:  AUDIT: SESSION,12,1,MISC,SET,,,SET statement_timeout = '30s',<not logged>
`

func TestPgaudit18Lines(t *testing.T) {
	got, err := ParseAudit(strings.NewReader(pgaudit18Log), time.UTC)
	if err != nil {
		t.Fatal(err)
	}
	want := []struct {
		logClass, command, objType, objName, role string
	}{
		{"DDL", "CREATE EXTENSION", "", "", ""},
		{"DDL", "CREATE TABLE", "TABLE", "public.t", ""},
		{"DDL", "CREATE TABLE", "TABLE", "public.t2", ""},
		{"DDL", "CREATE INDEX", "INDEX", "public.t2_pkey", ""},
		{"ROLE", "CREATE ROLE", "ROLE", "app1", ""},
		{"ROLE", "GRANT", "TABLE", "public.t", "app1"},
		{"ROLE", "GRANT ROLE", "ROLE", "pg_monitor", "app1"},
		{"DDL", "DROP TABLE", "TABLE", "public.t2", ""},
		{"DDL", "DROP TABLE", "TABLE CONSTRAINT", "t2_id_not_null on public.t2", ""},
		{"DDL", "DROP TABLE", "TABLE CONSTRAINT", "t2_pkey on public.t2", ""},
		{"DDL", "DROP TABLE", "INDEX", "public.t2_pkey", ""},
		{"MISC_SET", "SET", "SETTING", "pgaudit.log_catalog", ""},
		{"MISC_SET", "SET", "SETTING", "role", "app1"},
		{"MISC_SET", "RESET", "SETTING", "role", ""},
		{"READ", "SELECT", "TABLE", "public.t", ""},
		{"MISC_SET", "SET", "SETTING", "statement_timeout", ""},
	}
	if len(got) != len(want) {
		t.Fatalf("%d entries, want %d", len(got), len(want))
	}
	keys := map[string]bool{}
	for i, w := range want {
		e := got[i]
		typ, obj, role := AuditTarget(e)
		if e.LogClass() != w.logClass || e.Command != w.command || typ != w.objType || obj != w.objName || role != w.role {
			t.Errorf("entry %d = %s / %s / %s / %s / %s, want %+v", i, e.LogClass(), e.Command, typ, obj, role, w)
		}
		if e.User != "postgres" || e.Database != "postgres" || e.PID != 104 || e.Client != "" {
			t.Errorf("entry %d prefix: %+v", i, e)
		}
		// the four entries of one DROP TABLE share their time, pid and ids: the object keeps their keys apart
		if keys[e.Key] {
			t.Errorf("entry %d repeats a key: %s", i, e.Key)
		}
		keys[e.Key] = true
	}
	// the class of the line itself stays as pgaudit wrote it
	if got[11].Class != "MISC" || got[14].LogClass() != "READ" {
		t.Errorf("classes: %s %s", got[11].Class, got[14].LogClass())
	}
}

func TestAuditTarget(t *testing.T) {
	for _, c := range []struct {
		class, stmt       string
		objType, objName  string // as pgaudit wrote them
		wantType, wantObj string
		wantRole          string
	}{
		{"ROLE", "CREATE ROLE auditor LOGIN PASSWORD <REDACTED>", "", "", "ROLE", "auditor", ""},
		{"ROLE", `create user "Mixed Case" with password 'never kept'`, "", "", "ROLE", `"Mixed Case"`, ""},
		{"ROLE", "ALTER ROLE App_RO SET search_path = 'secret_schema'", "", "", "ROLE", "app_ro", ""},
		{"ROLE", "drop role if exists a, b /* c */, \"d\"", "", "", "ROLE", "a, b, d", ""},
		{"ROLE", "GRANT SELECT, UPDATE (name) ON TABLE public.account TO app_ro, GROUP readers WITH GRANT OPTION", "TABLE", "", "TABLE", "public.account", "app_ro, readers"},
		{"ROLE", "grant all on all tables in schema App to bob", "", "", "", "ALL TABLES IN SCHEMA app", "bob"},
		{"ROLE", "GRANT USAGE ON SCHEMA app TO bob", "", "", "SCHEMA", "app", "bob"},
		{"ROLE", "grant execute on function f(int, text) to bob", "", "", "FUNCTION", "f(int, text)", "bob"},
		{"ROLE", "GRANT pg_monitor, admins TO alice GRANTED BY postgres", "", "", "ROLE", "pg_monitor, admins", "alice"},
		{"ROLE", "REVOKE ADMIN OPTION FOR admins FROM alice CASCADE;", "", "", "ROLE", "admins", "alice"},
		{"ROLE", "revoke insert on t from public", "", "", "", "t", "public"},
		// pgaudit named the object: it stays, the grantee is still read
		{"ROLE", "grant select on t to bob", "TABLE", "public.t", "TABLE", "public.t", "bob"},
		{"MISC_SET", "SET pgaudit.log = 'none'", "", "", "SETTING", "pgaudit.log", ""},
		{"MISC_SET", "set local work_mem to '1GB'", "", "", "SETTING", "work_mem", ""},
		{"MISC_SET", "SET SESSION statement_timeout = 0", "", "", "SETTING", "statement_timeout", ""},
		{"MISC_SET", "SET ROLE postgres", "", "", "SETTING", "role", "postgres"},
		{"MISC_SET", "set local role 'quoted'", "", "", "SETTING", "role", ""},
		{"MISC_SET", "SET SESSION AUTHORIZATION admin", "", "", "SETTING", "session_authorization", "admin"},
		{"MISC_SET", "set time zone 'UTC'", "", "", "SETTING", "timezone", ""},
		{"MISC_SET", "RESET ALL", "", "", "SETTING", "all", ""},
		{"MISC_SET", "reset pgaudit.log", "", "", "SETTING", "pgaudit.log", ""},
		// another class is left as pgaudit wrote it (a MISC entry that is no SET among them), and so is an entry
		// without its statement
		{"MISC", "SET CONSTRAINTS ALL DEFERRED", "", "", "", "", ""},
		{"DDL", "create table t (a int)", "", "", "", "", ""},
		{"READ", "select * from t", "TABLE", "public.t", "TABLE", "public.t", ""},
		{"ROLE", "", "", "", "", "", ""},
	} {
		e := AuditEntry{Class: c.class, Statement: c.stmt, ObjectType: c.objType, ObjectName: c.objName}
		if c.class == "MISC_SET" { // as the line carries it
			e.Class, e.Command = "MISC", "SET"
			if strings.HasPrefix(strings.ToUpper(c.stmt), "RESET") {
				e.Command = "RESET"
			}
		}
		typ, obj, role := AuditTarget(e)
		if typ != c.wantType || obj != c.wantObj || role != c.wantRole {
			t.Errorf("AuditTarget(%s %q) = %q, %q, %q; want %q, %q, %q", c.class, c.stmt, typ, obj, role, c.wantType, c.wantObj, c.wantRole)
		}
	}
}

// a literal's text never reaches a target, whatever its quoting
func TestAuditTargetKeepsNoLiteral(t *testing.T) {
	for _, stmt := range []string{
		"ALTER ROLE app SET app.tenant = 'LEAK'",
		"ALTER ROLE app SET app.tenant = E'LE\\'AK'",
		"ALTER ROLE app SET app.tenant = $q$LEAK$q$",
		"ALTER ROLE app VALID UNTIL 'LEAK'",
		"CREATE ROLE app PASSWORD 'LEAK'",
	} {
		_, obj, role := AuditTarget(AuditEntry{Class: "ROLE", Statement: stmt})
		if obj != "app" || strings.Contains(obj+role, "LEAK") || strings.Contains(obj+role, "AK") {
			t.Errorf("%q: object %q role %q", stmt, obj, role)
		}
	}
	for _, stmt := range []string{"SET app.tenant = 'LEAK'", "SET app.tenant TO LEAK", "SET SESSION app.tenant = $$LEAK$$"} {
		_, obj, role := AuditTarget(AuditEntry{Class: "MISC", Command: "SET", Statement: stmt})
		if obj != "app.tenant" || role != "" {
			t.Errorf("%q: object %q role %q", stmt, obj, role)
		}
	}
}
