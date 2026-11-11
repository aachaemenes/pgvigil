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
	"\t\n" + // an empty line of the statement
	"\t\tname text default 'x,\"\"y\"\"'\n" +
	"\t);\",<not logged>\n" +
	"2026-11-11 12:00:01 UTC:10.0.0.5(54321):app@shop:[1234]:LOG:  duration: 3.1 ms  statement: select 'AUDIT: SESSION,9,9,READ,SELECT,,,x,y'\n" +
	"2026-11-11 12:00:02.250 PST:[local]:postgres@postgres:[77]:LOG:  AUDIT: OBJECT,5,1,READ,SELECT,TABLE,public.account,select * from account where id = $1,7\n" +
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
	for i, e := range got {
		if e.Forged || e.Truncated || e.Oversize || e.Last != (i == len(got)-1) {
			t.Errorf("entry %d flags: %+v", i, e)
		}
	}
	a := got[0]
	if a.Class != "ROLE" || a.Command != "CREATE ROLE" || a.User != "app" || a.Database != "shop" || a.Client != "10.0.0.5(54321)" || a.PID != 1234 ||
		a.At.UTC().Format(time.RFC3339) != "2026-11-11T12:00:00Z" || a.Statement != "CREATE ROLE auditor LOGIN PASSWORD <REDACTED>" {
		t.Errorf("entry 0: %+v", a)
	}
	b := got[1]
	wantStmt := "create table account\n(\n\tid int, -- a tab-led line of the statement\n\n\tname text default 'x,\"y\"'\n);"
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
	// ParseIn takes none of them as an event, at LOG or at WARNING
	evs, _ := ParseIn(strings.NewReader(auditLog), la)
	for _, ev := range evs {
		if strings.HasPrefix(ev.Detail, "AUDIT: ") {
			t.Errorf("ParseIn took an AUDIT line: %+v", ev)
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
		typ, obj, role := AuditTarget(e) // no command tag: any statement of the class
		if typ != c.wantType || obj != c.wantObj || role != c.wantRole {
			t.Errorf("AuditTarget(%s %q) = %q, %q, %q; want %q, %q, %q", c.class, c.stmt, typ, obj, role, c.wantType, c.wantObj, c.wantRole)
		}
		// with the tag pgaudit writes for the statement the result is the same
		if c.class == "ROLE" && c.stmt != "" {
			f := strings.Fields(strings.ToUpper(c.stmt))
			switch f[0] {
			case "GRANT", "REVOKE":
				e.Command = f[0]
				if !strings.Contains(" "+strings.ToUpper(c.stmt)+" ", " ON ") {
					e.Command += " ROLE"
				}
			default:
				e.Command = f[0] + " ROLE"
			}
		}
		typ, obj, role = AuditTarget(e)
		if typ != c.wantType || obj != c.wantObj || role != c.wantRole {
			t.Errorf("AuditTarget(%s %q) = %q, %q, %q; want %q, %q, %q", c.class, c.stmt, typ, obj, role, c.wantType, c.wantObj, c.wantRole)
		}
	}
}

// pgaudit 16.1 writes the whole text of a multi-statement string on each entry of it (box job s157-proof3: pgvigil's
// own four session SETs all carried the text that starts with the first). The statement an entry is has to match
// its command tag; where several do, each is a result and AuditTarget names none unless they agree.
func TestAuditTargetsMultiStatement(t *testing.T) {
	setup := "SET default_transaction_read_only = on;\nSET statement_timeout = '30s';\nSET lock_timeout = '2s';\nSET application_name = 'pgvigil';"
	e := AuditEntry{Class: "MISC", Command: "SET", Statement: setup}
	ts := AuditTargets(e)
	var names []string
	for _, o := range ts {
		names = append(names, o.Type+" "+o.Name)
	}
	if strings.Join(names, ", ") != "SETTING default_transaction_read_only, SETTING statement_timeout, SETTING lock_timeout, SETTING application_name" {
		t.Errorf("the four SETs: %v", names)
	}
	if typ, obj, role := AuditTarget(e); typ != "" || obj != "" || role != "" {
		t.Errorf("four different settings named one: %q %q %q", typ, obj, role)
	}
	// the same statement twice agrees with itself
	if _, obj, _ := AuditTarget(AuditEntry{Class: "MISC", Command: "SET", Statement: "set work_mem = '1MB'; set work_mem = '2MB'"}); obj != "work_mem" {
		t.Errorf("two SETs of one setting: %q", obj)
	}
	// a string of several commands: each entry reads the statement of its own tag
	mixed := "create table t (a int default 1); create role app password 'x;y'; grant select on t to app; grant admins to app; set role app; reset role; drop role old1, old2"
	for _, c := range []struct {
		class, command    string
		wantType, wantObj string
		wantRole          string
	}{
		{"ROLE", "CREATE ROLE", "ROLE", "app", ""},
		{"ROLE", "GRANT", "", "t", "app"},
		{"ROLE", "GRANT ROLE", "ROLE", "admins", "app"},
		{"ROLE", "DROP ROLE", "ROLE", "old1, old2", ""},
		{"ROLE", "REVOKE", "", "", ""},     // no REVOKE in the text
		{"ROLE", "ALTER ROLE", "", "", ""}, // nor an ALTER ROLE
		{"MISC", "SET", "SETTING", "role", "app"},
		{"MISC", "RESET", "SETTING", "role", ""},
		{"ROLE", "ALTER DEFAULT PRIVILEGES", "", "", ""}, // a tag whose statement is not read
	} {
		typ, obj, role := AuditTarget(AuditEntry{Class: c.class, Command: c.command, Statement: mixed})
		if typ != c.wantType || obj != c.wantObj || role != c.wantRole {
			t.Errorf("%s in the mixed string = %q, %q, %q; want %q, %q, %q", c.command, typ, obj, role, c.wantType, c.wantObj, c.wantRole)
		}
	}
	// two GRANTs that differ: neither is named, pgaudit's own type stays
	if typ, obj, role := AuditTarget(AuditEntry{Class: "ROLE", Command: "GRANT", ObjectType: "TABLE",
		Statement: "grant select on a to x; grant select on b to y"}); typ != "TABLE" || obj != "" || role != "" {
		t.Errorf("two different GRANTs: %q %q %q", typ, obj, role)
	}
	// a semicolon inside a literal, a comment or parentheses does not cut a statement
	if n := len(AuditTargets(AuditEntry{Class: "MISC", Command: "SET", Statement: "set a.b = 'x; set pgaudit.log = none' /* ; set c.d = 1 */"})); n != 1 {
		t.Errorf("%d statements read from one", n)
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
		_, obj, role := AuditTarget(AuditEntry{Class: "ROLE", Command: strings.ToUpper(strings.Fields(stmt)[0]) + " ROLE", Statement: stmt})
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

// What ends an entry, and what the line after it says about it.
func TestScanAuditBoundaries(t *testing.T) {
	const p = "2026-11-11 12:00:00 UTC:10.0.0.5(54321):app@shop:"
	read := func(log string) []AuditEntry {
		t.Helper()
		got, err := ParseAudit(strings.NewReader(log), time.UTC)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	// a message a session raised itself has pgaudit's first line and its own CONTEXT and STATEMENT lines after it
	forged := read(p + "[77]:LOG:  AUDIT: SESSION,1,1,ROLE,CREATE ROLE,,,create role evil,<none>\n" +
		p + "[77]:CONTEXT:  PL/pgSQL function inline_code_block line 1 at RAISE\n" +
		p + "[77]:STATEMENT:  do $$ begin raise log 'AUDIT: SESSION,1,1,ROLE,CREATE ROLE,,,create role evil,<none>'; end $$\n" +
		// a STATEMENT line of another process says nothing about this entry; a LOCATION line (log_error_verbosity
		// verbose) follows pgaudit's own entries too
		p + "[77]:LOG:  AUDIT: SESSION,2,1,ROLE,CREATE ROLE,,,create role real1,<none>\n" +
		p + "[78]:STATEMENT:  select 1\n" +
		p + "[77]:LOG:  00000: AUDIT: SESSION,3,1,ROLE,CREATE ROLE,,,create role real2,<none>\n" +
		p + "[77]:LOCATION:  log_audit_event, pgaudit.c:870\n")
	if len(forged) != 3 || !forged[0].Forged || forged[1].Forged || forged[2].Forged {
		t.Fatalf("forged / real / real: %+v", forged)
	}
	if forged[2].Statement != "create role real2" || forged[2].StatementID != 3 || forged[2].Last {
		t.Errorf("the entry under log_error_verbosity verbose: %+v", forged[2])
	}
	// a line with no prefix ends the open entry: the tab-led lines after it are another entry's
	cut := read(p + "[77]:LOG:  AUDIT: SESSION,1,1,DDL,CREATE TABLE,TABLE,public.t,\"create table t (\n" +
		"2026-11-11 12:00:00 UTC:10.0.0.5(54321):app@sh:op:[78]:LOG:  duration: 9.1 ms  statement: select\n" +
		"\t'SECRET'\n")
	if len(cut) != 1 || !cut[0].Truncated || strings.Contains(cut[0].Statement+cut[0].Parameters, "SECRET") || cut[0].Statement != "create table t (" {
		t.Errorf("an entry ended by a line without a prefix: %+v", cut)
	}
	// only the text's last entry is Last
	if two := read(p + "[77]:LOG:  AUDIT: SESSION,1,1,READ,SELECT,,,select 1,<none>\n" + p + "[77]:LOG:  AUDIT: SESSION,2,1,READ,SELECT,,,select 2,<none>\n"); len(two) != 2 || two[0].Last || !two[1].Last {
		t.Errorf("last: %+v", two)
	}
	// a line longer than the reader keeps: the entry stands on its fixed fields, without text, and the scan goes on
	big := read(p + "[77]:LOG:  AUDIT: SESSION,1,1,WRITE,INSERT,TABLE,public.t,insert into t values ('" + strings.Repeat("x", auditLineMax+10) + "'),<none>,5\n" +
		p + "[77]:LOG:  AUDIT: SESSION,2,1,ROLE,CREATE ROLE,,,create role after_it,<none>\n")
	if len(big) != 2 {
		t.Fatalf("oversize: %d entries, want 2", len(big))
	}
	if !big[0].Oversize || big[0].Truncated || big[0].Statement != "" || big[0].Rows != -1 || big[0].Class != "WRITE" ||
		big[0].ObjectName != "public.t" || len(big[0].Key) > 700 || big[1].Statement != "create role after_it" {
		t.Errorf("oversize: class %s object %s oversize %v truncated %v rows %d statement %d bytes key %d bytes; then %q",
			big[0].Class, big[0].ObjectName, big[0].Oversize, big[0].Truncated, big[0].Rows, len(big[0].Statement), len(big[0].Key), big[1].Statement)
	}
}

// In the hour a zone repeats the abbreviation says which of the two it is.
func TestScanAuditClockChange(t *testing.T) {
	ny, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Skip(err)
	}
	got, err := ParseAudit(strings.NewReader(
		"2026-11-01 01:30:00 EDT:10.0.0.5(54321):app@shop:[77]:LOG:  AUDIT: SESSION,1,1,READ,SELECT,,,select 1,<none>\n"+
			"2026-11-01 01:30:00 EST:10.0.0.5(54321):app@shop:[77]:LOG:  AUDIT: SESSION,2,1,READ,SELECT,,,select 2,<none>\n"+
			"2026-11-01 12:00:00.250 EST:10.0.0.5(54321):app@shop:[77]:LOG:  AUDIT: SESSION,3,1,READ,SELECT,,,select 3,<none>\n"), ny)
	if err != nil || len(got) != 3 {
		t.Fatalf("%v %+v", err, got)
	}
	for i, want := range []string{"2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-11-01T17:00:00.25Z"} {
		if at := got[i].At.UTC().Format(time.RFC3339Nano); at != want {
			t.Errorf("entry %d at %s, want %s", i, at, want)
		}
	}
}

// Forms whose first reading would name the wrong thing, or a thing that is not a name.
func TestAuditTargetForms(t *testing.T) {
	for _, c := range []struct {
		class, command, stmt        string
		wantType, wantObj, wantRole string
	}{
		// pgaudit cuts a CREATE or ALTER ROLE at the first 'password', inside a role's name as well: such a name is not read
		{"ROLE", "CREATE ROLE", "CREATE ROLE password <REDACTED>", "", "", ""},
		{"ROLE", "ALTER ROLE", "ALTER ROLE svc_password <REDACTED>", "", "", ""},
		{"ROLE", "CREATE ROLE", `CREATE ROLE "Password <REDACTED>`, "", "", ""},
		{"ROLE", "CREATE ROLE", "CREATE ROLE app LOGIN PASSWORD <REDACTED>", "ROLE", "app", ""},
		{"ROLE", "ALTER ROLE", "ALTER ROLE svc_password_rotator NOLOGIN", "ROLE", "svc_password_rotator", ""}, // not redacted: whole
		{"ROLE", "DROP ROLE", "DROP ROLE password_bot", "ROLE", "password_bot", ""},
		// a keyword that stands for roles is not a role of that name
		{"ROLE", "ALTER ROLE", "ALTER ROLE ALL SET log_statement = 'none'", "ROLE", "ALL", ""},
		{"ROLE", "ALTER ROLE", `ALTER ROLE "all" IN DATABASE d SET work_mem = '1MB'`, "ROLE", "all", ""},
		{"ROLE", "ALTER ROLE", "alter role current_user set search_path = app", "ROLE", "CURRENT_USER", ""},
		{"ROLE", "GRANT ROLE", "GRANT admins TO SESSION_USER", "ROLE", "admins", "SESSION_USER"},
		{"MISC", "SET", "SET SESSION AUTHORIZATION DEFAULT", "SETTING", "session_authorization", ""},
		{"MISC", "SET", "set local session authorization 'quoted'", "SETTING", "session_authorization", ""},
		{"MISC", "SET", "SET ROLE NONE", "SETTING", "role", ""},
		{"MISC", "SET", "SET LOCAL ROLE none", "SETTING", "role", ""},
		{"MISC", "RESET", "RESET SESSION AUTHORIZATION", "SETTING", "session_authorization", ""},
		// a user mapping is not a role
		{"ROLE", "CREATE ROLE", "CREATE USER MAPPING FOR app SERVER s OPTIONS (password 'x'); CREATE ROLE bob", "ROLE", "bob", ""},
		// settings whose name is not their first word
		{"MISC", "RESET", "RESET TIME ZONE", "SETTING", "timezone", ""},
		{"MISC", "SET", "SET XML OPTION DOCUMENT", "SETTING", "xmloption", ""},
		{"MISC", "SET", "SET SCHEMA 'app'", "SETTING", "search_path", ""},
		// a setting is looked up without regard to case or quotes
		{"MISC", "SET", `SET "pgaudit.log" = 'none'`, "SETTING", "pgaudit.log", ""},
		{"MISC", "SET", `SET "LOG_STATEMENT" = 'none'`, "SETTING", "log_statement", ""},
		{"MISC", "SET", "SET PGAudit.Log_Catalog = off", "SETTING", "pgaudit.log_catalog", ""},
		{"MISC", "RESET", `reset "Session_Replication_Role"`, "SETTING", "session_replication_role", ""},
	} {
		typ, obj, role := AuditTarget(AuditEntry{Class: c.class, Command: c.command, Statement: c.stmt})
		if typ != c.wantType || obj != c.wantObj || role != c.wantRole {
			t.Errorf("%s %q = %q, %q, %q; want %q, %q, %q", c.command, c.stmt, typ, obj, role, c.wantType, c.wantObj, c.wantRole)
		}
	}
	// a plain literal with a backslash ends at a different quote under standard_conforming_strings = off: what follows
	// it may be the inside of a literal, so nothing is read from the text
	for _, stmt := range []string{
		`SET application_name = 'a\'; SET SESSION AUTHORIZATION hunter2; --'`,
		`SET application_name = 'a\'; set pgaudit.log = none; --'`,
	} {
		if ts := AuditTargets(AuditEntry{Class: "MISC", Command: "SET", Statement: stmt}); ts != nil {
			t.Errorf("%q: read %+v", stmt, ts)
		}
	}
	// an E-prefixed literal says how it ends whatever the setting: read
	if _, obj, _ := AuditTarget(AuditEntry{Class: "MISC", Command: "SET", Statement: `SET pgaudit.log = E'a\'b'`}); obj != "pgaudit.log" {
		t.Errorf("an E-prefixed literal: %q", obj)
	}
}

func TestStripSQLState(t *testing.T) {
	for in, want := range map[string]string{
		"00000: AUDIT: SESSION,1,1,READ,SELECT,,,x,y": "AUDIT: SESSION,1,1,READ,SELECT,,,x,y",
		"P0001: raised":                        "raised",
		"AUDIT: SESSION,1,1,READ,SELECT,,,x,y": "AUDIT: SESSION,1,1,READ,SELECT,,,x,y",
		"ERROR: not a state":                   "ERROR: not a state",
	} {
		if got := stripSQLState(in); got != want {
			t.Errorf("stripSQLState(%q) = %q, want %q", in, got, want)
		}
	}
}
