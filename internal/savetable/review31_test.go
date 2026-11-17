package savetable

import (
	"encoding/json"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Task 7b, review-31 part A1's fold: each finding's row, red before its code.

// SHOULD-FIX 1: a key given twice is refused at Decode (a second 'cols' after the rows were checked against the first
// let ConvertRows index past the columns: a panic and no audit row), and ConvertRows refuses a row whose length is not
// the columns', whatever reached it.
func TestDecodeRefusesRepeatedKey(t *testing.T) {
	for _, body := range []string{
		`{"instance_id":1,"database":"d","table":"t","from":"grid","confirm":"i/d","cols":[{"name":"a","type":"int"},{"name":"b","type":"int"}],"rows":[[1,2]],"cols":[{"name":"a","type":"int"}]}`,
		`{"instance_id":1,"cols":[{"name":"a","type":"int"}],"rows":[[1]],"rows":[[1],[2]]}`,
		`{"instance_id":1,"table":"t","table":"u","cols":[{"name":"a","type":"int"}],"rows":[]}`,
	} {
		if _, err := Decode(strings.NewReader(body), Postgres, DefaultLimits); err == nil || !strings.Contains(err.Error(), "twice") {
			t.Errorf("%s: %v, want refused with 'twice'", body, err)
		}
	}
}

func TestConvertRowsRowLength(t *testing.T) {
	one := []Col{{Name: "a", Type: "int"}}
	two := []Col{{Name: "a", Type: "int"}, {Name: "b", Type: "int"}}
	for _, c := range []struct {
		name string
		cols []Col
		rows [][]any
	}{
		{"a row longer than the columns", one, [][]any{{json.Number("1"), json.Number("2")}}},
		{"a row shorter than the columns", two, [][]any{{json.Number("1"), json.Number("2")}, {json.Number("1")}}},
	} {
		func() {
			defer func() {
				if p := recover(); p != nil {
					t.Errorf("%s: ConvertRows panicked (%v), want refused naming the row", c.name, p)
				}
			}()
			if _, _, err := ConvertRows(Postgres, c.cols, c.rows); err == nil || !strings.Contains(err.Error(), "row ") {
				t.Errorf("%s: %v, want refused naming the row", c.name, err)
			}
		}()
	}
}

// SHOULD-FIX 2: a dec cell's cost is bounded before big.Rat - over 64 characters, or an exponent beyond 1000, is
// refused (a browser's number is at most 24 characters); never converted at the cost of its digits.
func TestConvertDecBounded(t *testing.T) {
	for _, c := range []struct {
		engine, v string
	}{
		{Postgres, "1e999999"},
		{SQLServer, "1e999999"},
		{Postgres, "1e-999999"},
		{Postgres, "1E1001"},
		{Postgres, strings.Repeat("7", 65)},
		{SQLServer, strings.Repeat("7", 2_000_000)},
	} {
		start := time.Now()
		_, err := Convert(c.engine, "dec", 4, "price", json.Number(c.v))
		short := c.v
		if len(short) > 12 {
			short = short[:12] + "..."
		}
		if err == nil || !strings.Contains(err.Error(), "row 4") {
			t.Errorf("%s dec %s: %v, want refused naming row 4", c.engine, short, err)
		}
		if d := time.Since(start); d > 50*time.Millisecond {
			t.Errorf("%s dec %s: %v to answer, want a refusal before any arithmetic", c.engine, short, d)
		}
	}
	for _, v := range []string{"1e3", "-2.5E-3", "12.3456789012", "1E1000"} {
		if _, err := Convert(Postgres, "dec", 1, "c", json.Number(v)); err != nil {
			t.Errorf("postgres dec %s: %v, want converted", v, err)
		}
	}
}

// SHOULD-FIX 3: Decode counts cells as they stream - a row longer than the columns is refused at its first extra
// value, never built whole; a cell that is a list or an object is refused (it would count as one cell); a column
// object with a field of its own is refused.
func TestDecodeStreamsCells(t *testing.T) {
	col := `"cols":[{"name":"a","type":"int"}]`
	for _, c := range []struct {
		name, body, words string
	}{
		{"a list in a cell", `{` + col + `,"rows":[[[1,2,3]]]}`, "list or an object"},
		{"an object in a cell", `{` + col + `,"rows":[[{"x":1}]]}`, "list or an object"},
		{"a column with a field of its own", `{"cols":[{"name":"a","type":"int","x":[1,2,3]}],"rows":[]}`, "column 1"},
	} {
		if _, err := Decode(strings.NewReader(c.body), Postgres, DefaultLimits); err == nil || !strings.Contains(err.Error(), c.words) {
			t.Errorf("%s: %v, want refused with %q", c.name, err, c.words)
		}
	}
	// one column and a row of 4,000,000 values: refused at the second value, without the row in memory
	var sb strings.Builder
	sb.WriteString(`{` + col + `,"rows":[[`)
	for i := 0; i < 4_000_000; i++ {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteByte('0')
	}
	sb.WriteString(`]]}`)
	body := sb.String()
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	_, err := Decode(strings.NewReader(body), Postgres, DefaultLimits)
	runtime.ReadMemStats(&after)
	if err == nil || !strings.Contains(err.Error(), "row 1") {
		t.Errorf("a row of 4,000,000 values for one column: %v, want refused naming row 1", err)
	}
	if got := after.TotalAlloc - before.TotalAlloc; got > 8<<20 {
		t.Errorf("a row of 4,000,000 values for one column: Decode allocated %d MB before refusing, want under 8 MB", got>>20)
	}
}

// SHOULD-FIX 6 (this package's half): the database and table names are checked before the database is looked up, so
// a refused name never reaches the words raw.
func TestCheckNamesBeforeLookup(t *testing.T) {
	inst := Instance{Name: "ms1", Engine: SQLServer, Allowed: true, Configured: true, Resolved: true}
	bad := "a‮b"
	b := Body{InstanceID: 3, Database: bad, Table: "t1", From: "grid", Confirm: "ms1/" + bad,
		Cols: []Col{{Name: "a", Type: "int"}}, Rows: [][]any{{json.Number("1")}}}
	v := Check(t.Context(), inst, []Database{{Name: "app", ID: 5}}, b, nil)
	if v.Outcome != "refused" || !strings.Contains(v.Words, "invisible") || strings.Contains(v.Words, bad) {
		t.Errorf("a database name with a direction override: %+v, want refused as invisible, the raw name never in the words", v)
	}
}

// SHOULD-FIX 7: SQL Server's DATE and DATETIMEOFFSET start at 0001-01-01 (UTC for a time): an earlier one is refused
// naming the row and column, never wrapped by the driver.
func TestConvertSQLServerYearOne(t *testing.T) {
	for _, c := range []struct{ kind, v string }{
		{"day", "0000-06-01"},
		{"time", "0001-01-01T03:00:00+05:00"},
		{"time", "0000-12-31T23:00:00Z"},
	} {
		if _, err := Convert(SQLServer, c.kind, 2, "when", c.v); err == nil || !strings.Contains(err.Error(), "row 2") {
			t.Errorf("sqlserver %s %s: %v, want refused naming row 2", c.kind, c.v, err)
		}
	}
	for _, c := range []struct{ kind, v string }{
		{"day", "0001-01-01"},
		{"time", "0001-01-01T00:00:00Z"},
	} {
		if _, err := Convert(SQLServer, c.kind, 2, "when", c.v); err != nil {
			t.Errorf("sqlserver %s %s: %v, want converted (the first day)", c.kind, c.v, err)
		}
	}
}

// NIT 8: a SQL Server name ending in a space is refused (SQL Server drops a delimited name's trailing spaces, so the
// bulk copy's column match would fail); NIT 9: the invisible characters past Cc / Cf; NIT 10: PostgreSQL's system
// column names.
func TestCheckNameReview31(t *testing.T) {
	for _, c := range []struct {
		engine, field, name, want string
	}{
		{SQLServer, "table", "x ", "space"},
		{SQLServer, "column 1", "a ", "space"},
		{Postgres, "table", "x ", ""},
		{Postgres, "table", "a b", "invisible"},  // a no-break space
		{SQLServer, "table", "a　b", "invisible"}, // an ideographic space
		{Postgres, "table", "a b", "invisible"},  // an em space
		{Postgres, "table", "a͏b", "invisible"},  // the combining grapheme joiner
		{SQLServer, "table", "a️b", "invisible"}, // a variation selector
		{Postgres, "table", "ㅤ", "invisible"},    // the Hangul filler
		{SQLServer, "table", "a⠀b", "invisible"}, // the braille blank
		{Postgres, "table", "ab", "invisible"},  // private use
		{Postgres, "table", "Grand Total", ""},   // an ordinary space stays
		{SQLServer, "table", "Größe", ""},
	} {
		err := CheckName(c.engine, c.field, c.name)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s %q: refused (%v), want accepted", c.engine, c.name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s %q: %v, want refused with %q", c.engine, c.name, err, c.want)
		}
	}
	for _, n := range []string{"xmin", "xmax", "cmin", "cmax", "ctid", "tableoid"} {
		if err := CheckColumns(Postgres, []string{"a", n}); err == nil || !strings.Contains(err.Error(), "system column") {
			t.Errorf("postgres column %q: %v, want refused as a system column", n, err)
		}
		if err := CheckColumns(SQLServer, []string{"a", n}); err != nil {
			t.Errorf("sqlserver column %q: %v, want accepted", n, err)
		}
	}
	if err := CheckColumns(Postgres, []string{"XMIN"}); err != nil {
		t.Errorf("postgres column \"XMIN\": %v, want accepted (quoted, not the system column)", err)
	}
}

// NIT 11: a time keeps microseconds on both engines (PostgreSQL's timestamptz holds no more), so the two tables of one
// grid hold the same value.
func TestConvertTimeMicroseconds(t *testing.T) {
	for _, e := range []string{Postgres, SQLServer} {
		got, err := Convert(e, "time", 1, "at", "2026-11-17T02:10:25.1234567Z")
		tm, ok := got.(time.Time)
		if err != nil || !ok || tm.Nanosecond() != 123456000 {
			t.Errorf("%s time with 7 places: %v, %v - want 123456000 ns", e, got, err)
		}
	}
}
