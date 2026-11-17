package savetable

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Task 7b, review-31 part A2's fold: each finding's row, red before its code.

// a2Door is a door whose every gate passes on engine: the instance, its databases as the store lists them, a body and
// the two logins' fake connections.
func a2Door(engine string) (Instance, []Database, Body, *fakeConn, *fakeConn) {
	in := Instance{Name: "i1", Engine: engine, Allowed: true, Configured: true, Resolved: true}
	dbs := []Database{{Name: "app", ID: 5}, {Name: "distribution", ID: 7}}
	b := Body{InstanceID: 3, Database: "app", Table: "t1", From: "grid", Confirm: "i1/app",
		Cols: []Col{{Name: "a", Type: "int"}}, Rows: [][]any{{json.Number("1")}}}
	mon := &fakeConn{server: "S1", login: "pgvigil_read"}
	act := &fakeConn{server: "S1", login: "pgvigil_actions", schemaOK: true, schemaOwned: true, place: Place{DB: Database{Name: "app", ID: 5}}}
	return in, dbs, b, mon, act
}

func a2Check(in Instance, dbs []Database, b Body, mon, act *fakeConn) Verdict {
	return Check(context.Background(), in, dbs, b, func(context.Context) (Conn, Conn, error) { return mon, act, nil })
}

// SHOULD-FIX 4 (and part A1's held S4): what the database IS comes from the WRITING connection at the save, whatever
// the store's last read holds - a distribution database (the store's list never says so), a database turned into a
// template since the last read, a system database by its id.
func TestCheckReadsThePlace(t *testing.T) {
	for _, c := range []struct {
		name, engine string
		place        func(*Place)
		fail         bool
		outcome      string
		words        string
	}{
		{"every gate passes", SQLServer, nil, false, "", ""},
		{"sqlserver: a distribution database, the list silent", SQLServer, func(p *Place) { p.DB.IsDistributor = true }, false, "refused", "replication distribution database"},
		{"sqlserver: a system database by its id on the connection", SQLServer, func(p *Place) { p.DB.ID = 3 }, false, "refused", "system database"},
		{"postgres: a template since the last read", Postgres, func(p *Place) { p.DB.IsTemplate = true }, false, "refused", "template"},
		{"the read fails", SQLServer, nil, true, "failed", "database check"},
	} {
		in, dbs, b, mon, act := a2Door(c.engine)
		if c.place != nil {
			c.place(&act.place)
		}
		if c.fail {
			act.fail = "Place"
		}
		v := a2Check(in, dbs, b, mon, act)
		if v.Outcome != c.outcome || !strings.Contains(v.Words, c.words) {
			t.Errorf("%s: %q %q, want %q holding %q", c.name, v.Outcome, v.Words, c.outcome, c.words)
		}
		if !v.Row {
			t.Errorf("%s: the verdict writes no audit row", c.name)
		}
		if !contains(act.asked, "Place") {
			t.Errorf("%s: Place was not asked of the writing connection (asked %q)", c.name, act.asked)
		}
		if contains(mon.asked, "Place") {
			t.Errorf("%s: Place was asked of the read login's connection: the writing connection's answer is the one that counts", c.name)
		}
		if c.outcome != "" && strings.Contains(strings.Join(act.asked, " "), "Exists") {
			t.Errorf("%s: the existence read ran after the refusal (asked %q)", c.name, act.asked)
		}
	}
}

// SHOULD-FIX 1: SQL Server runs a database's DDL trigger as the caller, so the door's CREATE TABLE would run a
// database owner's code as the actions login. A database that holds an enabled one is refused, the trigger named in a
// quoted, cut form.
func TestCheckRefusesDDLTriggers(t *testing.T) {
	in, dbs, b, mon, act := a2Door(SQLServer)
	act.place.Triggers = []string{"probe"}
	v := a2Check(in, dbs, b, mon, act)
	if v.Outcome != "refused" || !strings.Contains(v.Words, `"probe"`) || !strings.Contains(v.Words, "DDL trigger") || !v.Row {
		t.Errorf("one trigger: %q %q row %v, want refused naming \"probe\" as a DDL trigger, with its audit row", v.Outcome, v.Words, v.Row)
	}
	if strings.Contains(strings.Join(act.asked, " "), "Exists") {
		t.Errorf("one trigger: the existence read ran after the refusal (asked %q)", act.asked)
	}

	in, dbs, b, mon, act = a2Door(SQLServer)
	act.place.Triggers = []string{"a‮b" + strings.Repeat("x", 500), "second", "third"}
	v = a2Check(in, dbs, b, mon, act)
	if v.Outcome != "refused" || strings.ContainsRune(v.Words, '‮') || len(v.Words) > 400 || !strings.Contains(v.Words, "2 more") {
		t.Errorf("a hostile name and two more: %q (%d bytes) %q, want refused, no raw U+202E, under 400 bytes, '2 more'", v.Outcome, len(v.Words), v.Words)
	}
}

// NIT 6: an actions login that is the database's owner or in db_owner there is refused as sysadmin is - the door
// login has no rights over dbo (review-29 B2), and a schema it made without AUTHORIZATION would pass as 'its own'.
func TestCheckRefusesDatabaseOwner(t *testing.T) {
	in, dbs, b, mon, act := a2Door(SQLServer)
	act.place.Owner = true
	v := a2Check(in, dbs, b, mon, act)
	if v.Outcome != "refused" || !strings.Contains(v.Words, "db_owner") || !v.Row {
		t.Errorf("%q %q row %v, want refused naming db_owner, with its audit row", v.Outcome, v.Words, v.Row)
	}
	if strings.Contains(strings.Join(act.asked, " "), "Schema") {
		t.Errorf("the schema was read after the refusal (asked %q)", act.asked)
	}
}

// SHOULD-FIX 3 (and part A1's held S6, the route's half): the audit row and the log carry a name only once CheckName
// passed it - a NUL would fail the row's jsonb (no audit row at all), an invisible character would read as another
// name, an unbounded one would be written three times.
func TestAuditNames(t *testing.T) {
	for _, c := range []struct {
		name, db, table string
		datname, target string
	}{
		{"good names", "app", "t1", "app", "app.pgvigil_saved.t1"},
		{"a NUL in the database", "app\x00x", "t1", RefusedName, RefusedName},
		{"an invisible character in the table", "app", "a‮b", "app", RefusedName},
		{"a megabyte of database name", strings.Repeat("d", 1<<20), "t1", RefusedName, RefusedName},
		{"both empty", "", "", RefusedName, RefusedName},
	} {
		for _, engine := range []string{Postgres, SQLServer} {
			d, tg := AuditNames(engine, Body{Database: c.db, Table: c.table})
			if d != c.datname || tg != c.target {
				t.Errorf("%s %s: datname %.60q target %.60q, want %q %q", engine, c.name, d, tg, c.datname, c.target)
			}
		}
	}
}

// SHOULD-FIX 3: gate 6's words name the typed target only once the database's name passed CheckName.
func TestConfirmWordsCarryNoRawName(t *testing.T) {
	in, dbs, b, mon, act := a2Door(SQLServer)
	b.Database, b.Confirm = "app\x00x", "nope"
	v := a2Check(in, dbs, b, mon, act)
	if v.Outcome != "refused" || strings.ContainsRune(v.Words, 0) || !v.Row {
		t.Errorf("a NUL in the database: %q %q row %v, want refused with no NUL in the words", v.Outcome, v.Words, v.Row)
	}
	in, dbs, b, mon, act = a2Door(SQLServer)
	b.Database, b.Confirm = strings.Repeat("d", 5000), "nope"
	v = a2Check(in, dbs, b, mon, act)
	if v.Outcome != "refused" || len(v.Words) > 300 {
		t.Errorf("a 5000-character database: %q, %d bytes of words, want refused in under 300", v.Outcome, len(v.Words))
	}
	if len(mon.asked)+len(act.asked) != 0 {
		t.Errorf("a refused name opened or asked a connection (%q %q)", mon.asked, act.asked)
	}
}

// NIT 8: an error from the COMMIT itself leaves the outcome unknown (the server may have committed before the
// connection was cut), so the words never say 'nothing was kept' for it.
func TestWriteWords(t *testing.T) {
	tg := Target{Database: "app", Schema: Schema, Table: "t1"}
	for _, c := range []struct {
		name    string
		n       int64
		nuls    int
		err     error
		outcome string
		holds   string
		lacks   string
		rows    int64
	}{
		{"done", 3, 0, nil, "done", "Saved 3 rows to app.pgvigil_saved.t1", "NUL", 3},
		{"done with NULs dropped", 3, 2, nil, "done", "2 NUL character(s) dropped from text cells", "", 3},
		{"the table exists", 0, 0, ErrExists, "refused", "never overwrites", "", 0},
		{"the write failed", 0, 0, errors.New("boom"), "failed", "nothing was kept (the transaction rolled back): boom", "unknown", 0},
		{"the commit was cut", 3, 0, fmt.Errorf("%w: %v", ErrCommitUnknown, context.DeadlineExceeded), "failed", "outcome is unknown", "nothing was kept", 0},
	} {
		outcome, detail, rows := WriteWords(tg, c.n, c.nuls, c.err)
		if outcome != c.outcome || !strings.Contains(detail, c.holds) || c.lacks != "" && strings.Contains(detail, c.lacks) || rows != c.rows {
			t.Errorf("%s: %q %q rows %d, want %q holding %q without %q, rows %d", c.name, outcome, detail, rows, c.outcome, c.holds, c.lacks, c.rows)
		}
	}
}
