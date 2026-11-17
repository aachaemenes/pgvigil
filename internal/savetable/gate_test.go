package savetable

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Task 7b: the route's gates from the instance's door on, with a fake door (no store, no server). Each refusal says
// whether it writes an audit row (review-29 N8), and nothing is opened before the confirmation and the identifiers
// pass.

func TestOffWordsOrder(t *testing.T) {
	all := Instance{Name: "pg1", Engine: Postgres, Allowed: true, Configured: true, Resolved: true}
	for _, c := range []struct {
		name string
		on   bool
		in   Instance
		want string // a word the off text holds; "" = on
	}{
		{"the switch off first, whatever else is off", false, Instance{Name: "pg1", Engine: Postgres}, OffSwitch},
		{"the switch off, all else on", false, all, OffSwitch},
		{"a page instance", true, Instance{Name: "pg1", Engine: Postgres, Page: true, Allowed: true, Configured: true, Resolved: true}, "Admin > Instances"},
		{"no list entry", true, Instance{Name: "pg1", Engine: Postgres, Configured: true, Resolved: true}, OffList},
		{"no actions_dsn", true, Instance{Name: "pg1", Engine: Postgres, Allowed: true}, OffNoDSN},
		{"an actions_dsn that did not resolve", true, Instance{Name: "pg1", Engine: Postgres, Allowed: true, Configured: true}, "resolved"},
		{"every switch on", true, all, ""},
	} {
		got := OffWords(c.on, c.in)
		if c.want == "" && got != "" || c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s: OffWords = %q, want %q", c.name, got, c.want)
		}
	}
}

// fakeConn is one login's side of the fake door.
type fakeConn struct {
	server, login         string
	super                 bool
	schemaOK, schemaOwned bool
	exists                bool
	fail                  string // a method name that answers an error
	asked                 []string
}

func (f *fakeConn) err(m string) error {
	f.asked = append(f.asked, m)
	if f.fail == m {
		return errors.New(m + " failed")
	}
	return nil
}
func (f *fakeConn) Server(context.Context) (string, error) { return f.server, f.err("Server") }
func (f *fakeConn) Login(context.Context) (string, bool, error) {
	return f.login, f.super, f.err("Login")
}
func (f *fakeConn) Schema(context.Context) (bool, bool, error) {
	return f.schemaOK, f.schemaOwned, f.err("Schema")
}
func (f *fakeConn) Exists(_ context.Context, quoted string) (bool, error) {
	f.asked = append(f.asked, "Exists "+quoted)
	return f.exists, nil
}

func TestCheckGateOrder(t *testing.T) {
	dbs := []Database{{Name: "master", ID: 1}, {Name: "app", ID: 5}}
	inst := Instance{Name: "ms1", Engine: SQLServer, Allowed: true, Configured: true, Resolved: true}
	body := func(f func(*Body)) Body {
		b := Body{InstanceID: 3, Database: "app", Table: "t1", From: "grid", Confirm: "ms1/app",
			Cols: []Col{{Name: "a", Type: "int"}, {Name: "b", Type: "text"}}, Rows: [][]any{{json.Number("1"), "x"}}}
		if f != nil {
			f(&b)
		}
		return b
	}
	good := func() (*fakeConn, *fakeConn) {
		return &fakeConn{server: "S1 2026-11-17T01:00:00", login: "pgvigil_read"},
			&fakeConn{server: "S1 2026-11-17T01:00:00", login: "pgvigil_actions", schemaOK: true, schemaOwned: true}
	}
	for _, c := range []struct {
		name    string
		in      Instance
		b       Body
		mon     func(*fakeConn)
		act     func(*fakeConn)
		openErr bool
		outcome string // "" = every gate passed
		words   string // a word the refusal holds
		opens   bool   // whether the connections were opened
	}{
		{name: "every gate passes", in: inst, b: body(nil), opens: true},
		{name: "5: the list does not name save_table", in: Instance{Name: "ms1", Engine: SQLServer, Configured: true, Resolved: true}, b: body(nil), outcome: "refused", words: OffList},
		{name: "5: no actions_dsn", in: Instance{Name: "ms1", Engine: SQLServer, Allowed: true}, b: body(nil), outcome: "refused", words: OffNoDSN},
		{name: "6: the table name typed, not the target", in: inst, b: body(func(b *Body) { b.Confirm = "t1" }), outcome: "refused", words: "ms1/app"},
		{name: "6: another database typed", in: inst, b: body(func(b *Body) { b.Confirm = "ms1/master" }), outcome: "refused", words: "ms1/app"},
		{name: "7: a database the instance does not list", in: inst, b: body(func(b *Body) { b.Database = "other"; b.Confirm = "ms1/other" }), outcome: "refused", words: "other"},
		{name: "7: a system database", in: inst, b: body(func(b *Body) { b.Database = "master"; b.Confirm = "ms1/master" }), outcome: "refused", words: "master"},
		{name: "7: a '#' table", in: inst, b: body(func(b *Body) { b.Table = "#x" }), outcome: "refused", words: "#"},
		{name: "7: a column twice", in: inst, b: body(func(b *Body) { b.Cols[1].Name = "A" }), outcome: "refused", words: "twice"},
		{name: "7: a kind off the list", in: inst, b: body(func(b *Body) { b.Cols[1].Type = "json" }), outcome: "refused", words: "json"},
		{name: "8: the writing login cannot connect", in: inst, b: body(nil), openErr: true, outcome: "failed", words: "connect", opens: true},
		{name: "8: another server", in: inst, b: body(nil), act: func(f *fakeConn) { f.server = "S2 2026-11-01T00:00:00" }, outcome: "refused", words: "another server", opens: true},
		{name: "8: the read login writes", in: inst, b: body(nil), act: func(f *fakeConn) { f.login = "PGVIGIL_READ" }, outcome: "refused", words: "login of its own", opens: true},
		{name: "8: a sysadmin", in: inst, b: body(nil), act: func(f *fakeConn) { f.super = true }, outcome: "refused", words: "sysadmin", opens: true},
		{name: "8: no schema pgvigil_saved", in: inst, b: body(nil), act: func(f *fakeConn) { f.schemaOK, f.schemaOwned = false, false }, outcome: "refused", words: OffSchema, opens: true},
		{name: "8: the schema owned by another login", in: inst, b: body(nil), act: func(f *fakeConn) { f.schemaOwned = false }, outcome: "refused", words: "another login", opens: true},
		{name: "8: the server check fails", in: inst, b: body(nil), act: func(f *fakeConn) { f.fail = "Server" }, outcome: "failed", words: "server check", opens: true},
		{name: "9: the table exists", in: inst, b: body(nil), act: func(f *fakeConn) { f.exists = true }, outcome: "refused", words: "never overwrites", opens: true},
	} {
		mon, act := good()
		if c.mon != nil {
			c.mon(mon)
		}
		if c.act != nil {
			c.act(act)
		}
		opened := 0
		open := func(context.Context) (Conn, Conn, error) {
			opened++
			if c.openErr {
				return nil, nil, errors.New("login failed for user 'pgvigil_actions'")
			}
			return mon, act, nil
		}
		v := Check(context.Background(), c.in, dbs, c.b, open)
		if v.Outcome != c.outcome || c.words != "" && !strings.Contains(v.Words, c.words) {
			t.Errorf("%s: %q %q, want %q holding %q", c.name, v.Outcome, v.Words, c.outcome, c.words)
		}
		if c.outcome != "" && !v.Row {
			t.Errorf("%s: a refusal from the door's gates on writes its audit row (Row false)", c.name)
		}
		if (opened > 0) != c.opens {
			t.Errorf("%s: the connections opened %d time(s), want opened=%v (nothing opens before gates 5-7 pass)", c.name, opened, c.opens)
		}
		if c.outcome == "" {
			if want := Quoted(SQLServer, Target{Database: "app", Schema: Schema, Table: "t1"}); v.Target != want || want == "" {
				t.Errorf("%s: Target %q, want %q", c.name, v.Target, want)
			}
			if !contains(act.asked, "Exists "+v.Target) {
				t.Errorf("%s: the existence read was not given the one quoted form %q (asked %q)", c.name, v.Target, act.asked)
			}
			// every check runs on the WRITING connection too (review-29 B1), not only on the monitoring one
			for _, m := range []string{"Server", "Login", "Schema"} {
				if !contains(act.asked, m) {
					t.Errorf("%s: %s was not asked of the writing connection (asked %q)", c.name, m, act.asked)
				}
			}
		}
	}
}

// PostgreSQL's words for a superuser, and its login names compared as written (a quoted role keeps its case).
func TestCheckPostgresLogins(t *testing.T) {
	inst := Instance{Name: "pg1", Engine: Postgres, Allowed: true, Configured: true, Resolved: true}
	b := Body{Database: "app", Table: "t1", Confirm: "pg1/app", Cols: []Col{{Name: "a", Type: "int"}}, Rows: [][]any{{json.Number("1")}}}
	dbs := []Database{{Name: "app"}, {Name: "template1", IsTemplate: true}}
	for _, c := range []struct {
		name, actLogin string
		super          bool
		outcome, words string
	}{
		{"a superuser", "pgvigil_actions", true, "refused", "superuser"},
		{"the read login", "pgvigil_read", false, "refused", "login of its own"},
		{"another login, its name differing in case only", "PGVIGIL_READ", false, "", ""},
	} {
		mon := &fakeConn{server: "2026-11-17 01:00:00+00", login: "pgvigil_read"}
		act := &fakeConn{server: "2026-11-17 01:00:00+00", login: c.actLogin, super: c.super, schemaOK: true, schemaOwned: true}
		v := Check(context.Background(), inst, dbs, b, func(context.Context) (Conn, Conn, error) { return mon, act, nil })
		if v.Outcome != c.outcome || c.words != "" && !strings.Contains(v.Words, c.words) {
			t.Errorf("%s: %q %q, want %q holding %q", c.name, v.Outcome, v.Words, c.outcome, c.words)
		}
	}
	bt := b
	bt.Database, bt.Confirm = "template1", "pg1/template1"
	if v := Check(context.Background(), inst, dbs, bt, func(context.Context) (Conn, Conn, error) { return nil, nil, fmt.Errorf("not opened") }); v.Outcome != "refused" || !strings.Contains(v.Words, "template1") {
		t.Errorf("a template database: %q %q, want refused naming template1", v.Outcome, v.Words)
	}
}

// review-29 S5: the body's limits hold while it is decoded; numbers keep their digits.
func TestDecodeLimits(t *testing.T) {
	lim := Limits{Rows: 3, Cells: 10}
	dec := func(engine, s string) (Body, error) { return Decode(strings.NewReader(s), engine, lim) }
	b, err := dec(Postgres, `{"instance_id":3,"database":"app","table":"t","from":"data","confirm":"pg1/app","cols":[{"name":"a","type":"int"},{"name":"b","type":"dec"}],"rows":[[9007199254740993,1.12345678901234567890]]}`)
	if err != nil || len(b.Rows) != 1 || b.InstanceID != 3 || b.Table != "t" {
		t.Fatalf("a small body: %+v, %v", b, err)
	}
	if b.Rows[0][0] != json.Number("9007199254740993") || b.Rows[0][1] != json.Number("1.12345678901234567890") {
		t.Errorf("numbers: %#v, want json.Number with every digit (UseNumber)", b.Rows[0])
	}
	cols := func(n int) string {
		var cs []string
		for i := 0; i < n; i++ {
			cs = append(cs, fmt.Sprintf(`{"name":"c%d","type":"int"}`, i))
		}
		return `"cols":[` + strings.Join(cs, ",") + `]`
	}
	for _, c := range []struct {
		name, engine, body, words string
	}{
		{"four rows over three", Postgres, `{` + cols(1) + `,"rows":[[1],[2],[3],[4]]}`, "3 rows"},
		{"eleven cells over ten", Postgres, `{` + cols(4) + `,"rows":[[1,2,3,4],[1,2,3,4],[1,2,3,4]]}`, "10 cells"},
		{"a row shorter than the columns", SQLServer, `{` + cols(2) + `,"rows":[[1,2],[1]]}`, "row 2"},
		{"SQL Server's 1,025 columns", SQLServer, `{` + cols(1025) + `,"rows":[]}`, "1024"},
		{"PostgreSQL's 1,601 columns", Postgres, `{` + cols(1601) + `,"rows":[]}`, "1600"},
		{"not JSON", Postgres, `{"rows":[[1,}`, "body"},
	} {
		if _, err := dec(c.engine, c.body); err == nil || !strings.Contains(err.Error(), c.words) {
			t.Errorf("%s: %v, want refused with %q", c.name, err, c.words)
		}
	}
	if _, err := dec(Postgres, `{`+cols(1025)+`,"rows":[]}`); err != nil {
		t.Errorf("PostgreSQL's 1,025 columns: %v, want accepted (its cap is 1,600)", err)
	}
}

func contains(xs []string, x string) bool {
	for _, s := range xs {
		if s == x {
			return true
		}
	}
	return false
}
