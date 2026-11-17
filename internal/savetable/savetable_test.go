package savetable

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Task 7b, the DONE's named check (1): the table name (and every identifier) is checked AND quoted on both engines -
// never concatenated raw. Each hostile name shows the text it yields or its refusal.

func TestCheckNameRefusals(t *testing.T) {
	long := func(s string, n int) string { return strings.Repeat(s, n) }
	for _, c := range []struct {
		engine, field, name string
		want                string // "" = accepted (quoted); else a word the refusal holds
	}{
		{Postgres, "table", "", "empty"},
		{SQLServer, "table", "", "empty"},
		{Postgres, "table", "a\x00b", "control"},
		{SQLServer, "table", "a\x00b", "control"},
		{Postgres, "column 2", "a\tb", "control"},
		{SQLServer, "table", "a\nb", "control"},
		{Postgres, "table", "a\u200bb", "invisible"},  // a zero-width space
		{SQLServer, "table", "a\u202eb", "invisible"}, // a right-to-left override
		{Postgres, "table", "\ufeffx", "invisible"},   // a byte-order mark
		{SQLServer, "table", "a\u2028b", "invisible"}, // the line separator
		{Postgres, "table", "a\u2029b", "invisible"},  // the paragraph separator
		// PostgreSQL counts 63 BYTES in UTF-8; SQL Server 128 UTF-16 code units (an emoji counts two)
		{Postgres, "table", long("a", 63), ""},
		{Postgres, "table", long("a", 64), "63"},
		{Postgres, "table", long("\U0001F600", 15), ""}, // 60 bytes
		{Postgres, "table", long("\U0001F600", 16), "63"},
		{SQLServer, "table", long("a", 128), ""},
		{SQLServer, "table", long("a", 129), "128"},
		{SQLServer, "table", long("\U0001F600", 64), ""}, // 128 units
		{SQLServer, "table", long("\U0001F600", 65), "128"},
		// a '#' table on SQL Server is a tempdb temporary table that vanishes at close: refused; a column may say '#'
		{SQLServer, "table", "#x", "#"},
		{SQLServer, "table", "##x", "#"},
		{SQLServer, "column 1", "#x", ""},
		{Postgres, "table", "#x", ""},
		// everything else is quoted, never refused for its characters
		{Postgres, "table", `a"b`, ""},
		{SQLServer, "table", `a]b`, ""},
		{Postgres, "table", `a'b`, ""},
		{SQLServer, "table", `a'b`, ""},
		{Postgres, "table", "a.b", ""},
		{SQLServer, "table", "dbo.Customers", ""},
		{Postgres, "table", " x ", ""},
		{SQLServer, "table", " x ", ""},
		{Postgres, "table", "a;DROP TABLE t;--", ""},
		{SQLServer, "table", "a;DROP TABLE t;--", ""},
		{SQLServer, "table", "[x]", ""},
	} {
		err := CheckName(c.engine, c.field, c.name)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s %s %q: refused (%v), want quoted", c.engine, c.field, c.name, err)
		case c.want != "" && err == nil:
			t.Errorf("%s %s %q: accepted, want refused with %q", c.engine, c.field, c.name, c.want)
		case c.want != "" && (!strings.Contains(err.Error(), c.want) || !strings.Contains(err.Error(), c.field)):
			t.Errorf("%s %s %q: refused as %q, want words naming the field %q and holding %q", c.engine, c.field, c.name, err, c.field, c.want)
		}
	}
}

func TestQuoteIdent(t *testing.T) {
	for _, c := range []struct{ engine, name, want string }{
		{Postgres, `a"b`, `"a""b"`},
		{Postgres, `a]b`, `"a]b"`},
		{Postgres, `a'b`, `"a'b"`},
		{Postgres, `a.b`, `"a.b"`},
		{Postgres, ` x `, `" x "`},
		{Postgres, `a;DROP TABLE t;--`, `"a;DROP TABLE t;--"`},
		{Postgres, `[x]`, `"[x]"`},
		{SQLServer, `a"b`, `[a"b]`},
		{SQLServer, `a]b`, `[a]]b]`},
		{SQLServer, `[x]`, `[[x]]]`},
		{SQLServer, `a.b`, `[a.b]`},
		{SQLServer, `a'b`, `[a'b]`},
		{SQLServer, ` x `, `[ x ]`},
		{SQLServer, `a;DROP TABLE t;--`, `[a;DROP TABLE t;--]`},
	} {
		if got := QuoteIdent(c.engine, c.name); got != c.want {
			t.Errorf("QuoteIdent(%s, %q) = %q, want %q", c.engine, c.name, got, c.want)
		}
	}
}

// review-29 S1: ONE quoted form everywhere. A dotted table name stays one part: CopyIn gets the same bracketed text as
// the CREATE (go-mssqldb splits its table argument only outside brackets), and pgx's CopyFrom the same identifier.
func TestQuotedIsTheOneForm(t *testing.T) {
	pg := Target{Database: "app", Schema: Schema, Table: "dbo.Customers"}
	if got, want := Quoted(Postgres, pg), `"pgvigil_saved"."dbo.Customers"`; got != want {
		t.Errorf("Quoted(postgres) = %q, want %q", got, want)
	}
	if got, want := Quoted(Postgres, pg), (pgx.Identifier{pg.Schema, pg.Table}).Sanitize(); got != want {
		t.Errorf("Quoted(postgres) = %q, but CopyFrom's identifier reads %q: two forms", got, want)
	}
	ms := Target{Database: "my]db", Schema: Schema, Table: "dbo.Customers"}
	got := Quoted(SQLServer, ms)
	if want := `[my]]db].[pgvigil_saved].[dbo.Customers]`; got != want {
		t.Errorf("Quoted(sqlserver) = %q, want %q", got, want)
	}
	if parts := splitBracketed(got); len(parts) != 3 || parts[0] != ms.Database || parts[1] != ms.Schema || parts[2] != ms.Table {
		t.Errorf("Quoted(sqlserver) = %q reads back as %q, want the three parts %q / %q / %q", got, parts, ms.Database, ms.Schema, ms.Table)
	}
	for _, name := range []string{`a'b`, ` x `, `a]b`, `[x]`} {
		q := Quoted(SQLServer, Target{Database: "app", Schema: Schema, Table: name})
		if parts := splitBracketed(q); len(parts) != 3 || parts[2] != name {
			t.Errorf("Quoted(sqlserver, table %q) = %q reads back as %q", name, q, parts)
		}
	}
}

// splitBracketed reads a multi-part name the way go-mssqldb's bulk copy does (review-29 S1: a dot splits only outside
// a bracketed part, ']]' inside one is a ']'); a part outside brackets is kept as written.
func splitBracketed(s string) []string {
	var parts []string
	var b strings.Builder
	in := false
	for i := 0; i < len(s); i++ {
		ch := s[i]
		switch {
		case in && ch == ']' && i+1 < len(s) && s[i+1] == ']':
			b.WriteByte(']')
			i++
		case in && ch == ']':
			in = false
		case !in && ch == '[':
			in = true
		case !in && ch == '.':
			parts = append(parts, b.String())
			b.Reset()
		default:
			b.WriteByte(ch)
		}
	}
	return append(parts, b.String())
}

func TestCheckColumns(t *testing.T) {
	for _, c := range []struct {
		engine string
		names  []string
		want   string
	}{
		{Postgres, nil, "no column"},
		{SQLServer, []string{}, "no column"},
		{Postgres, []string{"a", "a"}, "twice"},
		{SQLServer, []string{"a", "a"}, "twice"},
		{SQLServer, []string{"Total", "total"}, "twice"}, // SQL Server's names are case-insensitive
		{Postgres, []string{"Total", "total"}, ""},       // two quoted names on PostgreSQL
		{Postgres, []string{"ok", "a\x00"}, "column 2"},
		{SQLServer, []string{"ok", "", "c"}, "column 2"},
		{SQLServer, []string{"#", "a]b", "x y"}, ""},
	} {
		err := CheckColumns(c.engine, c.names)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s %q: refused (%v), want accepted", c.engine, c.names, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s %q: %v, want refused with %q", c.engine, c.names, err, c.want)
		}
	}
}

// review-29 S2: a system or template database never takes a table (model and template1 copy it into every database
// made later), whatever the monitoring read's list holds.
func TestRefuseDatabase(t *testing.T) {
	for _, c := range []struct {
		engine string
		d      Database
		refuse bool
	}{
		{SQLServer, Database{Name: "master", ID: 1}, true},
		{SQLServer, Database{Name: "tempdb", ID: 2}, true},
		{SQLServer, Database{Name: "model", ID: 3}, true},
		{SQLServer, Database{Name: "msdb", ID: 4}, true},
		{SQLServer, Database{Name: "distribution", ID: 7, IsDistributor: true}, true},
		{SQLServer, Database{Name: "rdsadmin", ID: 5}, true},
		{SQLServer, Database{Name: "RDSAdmin", ID: 6}, true},
		{SQLServer, Database{Name: "Sales", ID: 5}, false},
		{Postgres, Database{Name: "template0", IsTemplate: true}, true},
		{Postgres, Database{Name: "template1", IsTemplate: true}, true},
		{Postgres, Database{Name: "my_template", IsTemplate: true}, true},
		{Postgres, Database{Name: "cloudsqladmin"}, true},
		{Postgres, Database{Name: "rdsadmin"}, true},
		{Postgres, Database{Name: "azure_maintenance"}, true},
		{Postgres, Database{Name: "azure_sys"}, true},
		{Postgres, Database{Name: "postgres"}, false},
		{Postgres, Database{Name: "app"}, false},
	} {
		words := RefuseDatabase(c.engine, c.d)
		if (words != "") != c.refuse {
			t.Errorf("%s %+v: refusal %q, want refused=%v", c.engine, c.d, words, c.refuse)
		}
		if words != "" && !strings.Contains(words, c.d.Name) {
			t.Errorf("%s %+v: refusal %q does not name the database", c.engine, c.d, words)
		}
	}
}

// The closed type list (review-29 N3: 'day' as the export has it, gridwriters.ts sqlType).
func TestColumnType(t *testing.T) {
	want := map[string][2]string{
		"int":  {"bigint", "BIGINT"},
		"dec":  {"numeric", "DECIMAL(38,10)"},
		"time": {"timestamptz", "DATETIMEOFFSET"},
		"day":  {"date", "DATE"},
		"text": {"text", "NVARCHAR(MAX)"},
		"bool": {"boolean", "BIT"},
	}
	for kind, w := range want {
		for i, e := range []string{Postgres, SQLServer} {
			got, err := ColumnType(e, kind)
			if err != nil || got != w[i] {
				t.Errorf("ColumnType(%s, %s) = %q, %v; want %q", e, kind, got, err, w[i])
			}
		}
	}
	for _, e := range []string{Postgres, SQLServer} {
		if _, err := ColumnType(e, "json"); err == nil {
			t.Errorf("ColumnType(%s, json): accepted, want refused (a closed list)", e)
		}
	}
}

// Check (2)'s conversions: a value travels as data in the type the driver binds; a refusal names the row and the
// column, never the value (review-29 S3: any logged-in user reads the audit).
func TestConvert(t *testing.T) {
	const secret = "s3cr3t-value"
	ok := func(engine, kind string, v any) any {
		t.Helper()
		got, err := Convert(engine, kind, 1, "c", v)
		if err != nil {
			t.Errorf("Convert(%s, %s, %v): %v", engine, kind, v, err)
		}
		return got
	}
	// a bigint above 2^53 keeps every digit (the body is decoded with UseNumber; review-29 S5)
	for _, e := range []string{Postgres, SQLServer} {
		if got := ok(e, "int", json.Number("9007199254740993")); got != int64(9007199254740993) {
			t.Errorf("%s int 9007199254740993 = %#v, want int64 9007199254740993", e, got)
		}
		if got := ok(e, "dec", json.Number("12.3456789012")); got == nil {
			t.Errorf("%s dec: nil", e)
		} else if _, isFloat := got.(float64); isFloat {
			t.Errorf("%s dec 12.3456789012 = %#v: a float64 rounds a decimal", e, got)
		}
		for _, kind := range []string{"int", "dec", "time", "day", "text", "bool"} {
			if got, err := Convert(e, kind, 1, "c", nil); err != nil || got != nil {
				t.Errorf("%s %s null = %#v, %v; want nil (NULL)", e, kind, got, err)
			}
		}
		if got := ok(e, "bool", true); got != true {
			t.Errorf("%s bool true = %#v", e, got)
		}
		if got := ok(e, "text", "a\x00b"); got != "ab" {
			t.Errorf("%s text with a NUL = %#v, want %q (dropped and counted, as the export does)", e, got, "ab")
		}
		// a text column's number is written as its text (gridwriters.ts sqlScript: 'a number's value written as text')
		if got := ok(e, "text", json.Number("7.50")); got != "7.50" {
			t.Errorf("%s text 7.50 = %#v, want %q", e, got, "7.50")
		}
		if got, ok2 := ok(e, "time", "2026-11-17T02:10:00-08:00").(time.Time); !ok2 || !got.Equal(time.Date(2026, 11, 17, 10, 10, 0, 0, time.UTC)) {
			t.Errorf("%s time = %#v, want 2026-11-17 10:10 UTC", e, got)
		}
		if got, ok2 := ok(e, "day", "2026-11-17").(time.Time); !ok2 || got.Year() != 2026 || got.Month() != 11 || got.Day() != 17 {
			t.Errorf("%s day = %#v, want 2026-11-17", e, got)
		}
		// refusals: the row and the column named, the value never
		for _, c := range []struct {
			kind string
			v    any
		}{
			{"int", json.Number("1.5")},
			{"int", secret},
			{"dec", secret},
			{"time", secret},
			{"day", secret},
			{"bool", secret},
			{"bool", json.Number("1")},
		} {
			_, err := Convert(e, c.kind, 7, "total", c.v)
			if err == nil {
				t.Errorf("%s %s %#v: converted, want refused", e, c.kind, c.v)
				continue
			}
			if msg := err.Error(); !strings.Contains(msg, "row 7") || !strings.Contains(msg, "total") || strings.Contains(msg, secret) {
				t.Errorf("%s %s: refusal %q - want 'row 7' and 'total' named, the value never", e, c.kind, msg)
			}
		}
	}
	// SQL Server's DECIMAL(38,10): an 11th decimal place or a 29th integer digit refused, never rounded (review-29 N5)
	for _, v := range []string{"1.12345678901", "12345678901234567890123456789"} {
		if _, err := Convert(SQLServer, "dec", 3, "price", json.Number(v)); err == nil || !strings.Contains(err.Error(), "row 3") {
			t.Errorf("sqlserver dec %s: %v, want refused naming row 3", v, err)
		}
	}
	if got := ok(SQLServer, "dec", json.Number("1234567890123456789012345678.1234567890")); got == nil {
		t.Errorf("sqlserver dec at DECIMAL(38,10)'s edge: nil")
	}
	if got := ok(Postgres, "dec", json.Number("1.12345678901234567890")); got == nil {
		t.Errorf("postgres dec with 20 places: nil (numeric has no scale cap)")
	}
}
