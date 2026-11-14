package web

import (
	"archive/zip"
	"bytes"
	"fmt"
	"strings"
	"testing"
)

// Task 312: the inventory file's parsers (the standard library alone) - rows the planner takes, refusals in words.

func mustParse(t *testing.T, b []byte) *invFile {
	t.Helper()
	f, err := parseInventory(b)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return f
}

// The bar's own CSV (a BOM, its mark and 'read' lines above the header, CRLF), a description holding CRLF and a quote,
// the formula guard undone exactly once, columns in another order, an unknown column listed as not read, the export's
// own columns ignored; a semicolon file reads the same; a bare quote mid-field is taken as written.
func TestImportCSVForms(t *testing.T) {
	csvText := "\ufeff\"sample of 2026-11-14\"\r\n\"read 2026-11-14 10:00\"\r\n" +
		"application,instance,level,database,Owner e-mail,description,source\r\n" +
		"Billing,pg-1,database,sales,boss@example.org,\"two\r\nlines \"\"quoted\"\"\",entered\r\n" +
		"'=SUM(1),pg-1,server,,,''=x,\r\n" +
		"Plain,pg-2,,hr,,'abc,\r\n"
	f := mustParse(t, []byte(csvText))
	if f.Kind != "csv" || len(f.Rows) != 3 {
		t.Fatalf("kind %s, %d rows: %+v", f.Kind, len(f.Rows), f.Rows)
	}
	r := f.Rows[0]
	if r.Application != "Billing" || r.Instance != "pg-1" || r.Level != "database" || r.Database != "sales" || r.Description != "two\nlines \"quoted\"" {
		t.Errorf("row 1: %+v", r)
	}
	if r.Line != 4 {
		t.Errorf("row 1 is on line %d, want 4", r.Line)
	}
	if f.Rows[1].Application != "=SUM(1)" || f.Rows[1].Description != "'=x" {
		t.Errorf("the guard undone once: application %q, description %q", f.Rows[1].Application, f.Rows[1].Description)
	}
	if f.Rows[2].Description != "'abc" {
		t.Errorf("a ' before a plain text is the text's own: %q", f.Rows[2].Description)
	}
	if len(f.Unread) != 1 || f.Unread[0] != "Owner e-mail" {
		t.Errorf("columns not read: %v, want [Owner e-mail] (source is the export's own, ignored)", f.Unread)
	}
	semi := strings.NewReplacer(",", ";").Replace("instance,application,database\r\npg-1,Billing,sales\r\n")
	if f := mustParse(t, []byte(semi)); len(f.Rows) != 1 || f.Rows[0].Database != "sales" || f.Rows[0].Application != "Billing" {
		t.Errorf("a semicolon file: %+v", f.Rows)
	}
	if f := mustParse(t, []byte("instance,application,description\npg-1,Billing,say \"hi\" now\n")); f.Rows[0].Description != `say "hi" now` {
		t.Errorf("a bare quote: %q", f.Rows[0].Description)
	}
	if _, err := parseInventory([]byte("instance\tapplication\npg-1\tBilling\n")); err == nil || !strings.Contains(err.Error(), "tab-separated") {
		t.Errorf("a tab-separated file: %v", err)
	}
	if _, err := parseInventory([]byte("server,app\npg-1,Billing\n")); err != nil {
		t.Errorf("server / app are instance / application: %v", err)
	}
	if _, err := parseInventory([]byte("host,team\nx,y\n")); err == nil || !strings.Contains(err.Error(), "no header") {
		t.Errorf("no header: %v", err)
	}
}

// The CSV the route writes reads back cell for cell: the guard adds one ' and the import takes one off.
func TestImportCSVRoundTrip(t *testing.T) {
	vals := []string{"=SUM(1)", "'=x", "''+y", "-name", "+1", "@a", "\tx", "plain", "'plain", "a,b", "line1\nline2", "2024", ""}
	tb := &table{Columns: invColumns}
	for _, v := range vals {
		row := make([]any, len(invColumns))
		for i := range row {
			row[i] = ""
		}
		row[0], row[1], row[3], row[4], row[7] = "database", "pg-1", v, "App", v
		tb.Rows = append(tb.Rows, row)
	}
	var b bytes.Buffer
	if err := writeInventoryCSV(&b, tb); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(b.String(), "\ufefflevel,instance,engine,database,application") {
		t.Fatalf("the CSV's start: %q", b.String()[:60])
	}
	if !strings.Contains(b.String(), "'=SUM(1)") || !strings.Contains(b.String(), "'''+y") {
		t.Errorf("the guard: %s", b.String())
	}
	f := mustParse(t, b.Bytes())
	n := 0
	for _, v := range vals {
		if v == "" {
			continue // an empty database and description: a line still (level database), read as blank
		}
		r := f.Rows[n]
		if r.Database != v || r.Description != v {
			t.Errorf("%q came back as database %q, description %q", v, r.Database, r.Description)
		}
		n++
	}
}

func TestImportJSONForms(t *testing.T) {
	grid := `{"columns": ["instance", "application", "tier", "not_an_application", "description"], "rows": [["pg-1", "Billing", 2, false, "2024"], ["pg-1", {"x": 1}, 1, null, ""]]}`
	f := mustParse(t, []byte(grid))
	if f.Kind != "json" || len(f.Rows) != 2 || f.Rows[0].Tier != "2" || f.Rows[0].NotAnApp != "no" || f.Rows[0].Description != "2024" {
		t.Fatalf("grid: %+v", f.Rows)
	}
	if f.Rows[1].Why == "" {
		t.Error("an object as a cell: no refusal")
	}
	arr := `[{"instance": "pg-1", "application": "Billing", "email": "a@b.c"}, {"instance": "pg-2", "application": "HR"}]`
	f = mustParse(t, []byte(arr))
	if len(f.Rows) != 2 || f.Rows[1].Application != "HR" || len(f.Unread) != 1 || f.Unread[0] != "email" {
		t.Errorf("array: %+v, unread %v", f.Rows, f.Unread)
	}
	if _, err := parseInventory([]byte(`{"a": 1}`)); err == nil {
		t.Error("an object with no columns / rows was taken")
	}
}

// an .xlsx made here: two sheets (the first a page sheet with no header), shared strings with a rich run and an
// escaped CR, a blank cell left out (C2), a number, a boolean, an inline string, a formula row refused
func xlsxFixture(t *testing.T, sheetName string) []byte {
	t.Helper()
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	put := func(name, body string) {
		w, err := z.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	put("[Content_Types].xml", `<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>`)
	put("xl/workbook.xml", `<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Page" sheetId="1" r:id="rId1"/><sheet name="`+sheetName+`" sheetId="2" r:id="rId2"/></sheets></workbook>`)
	put("xl/_rels/workbook.xml.rels", `<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="x" Target="/xl/worksheets/sheet2.xml"/></Relationships>`)
	put("xl/sharedStrings.xml", `<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>instance</t></si><si><t>application</t></si><si><t>database</t></si><si><t>description</t></si><si><t>not_an_application</t></si><si><r><t>pg</t></r><r><t>-1</t></r></si><si><t>two_x000D_
lines</t></si></sst>`)
	put("xl/worksheets/sheet1.xml", `<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Applications</t></is></c></row></sheetData></worksheet>`)
	put("xl/worksheets/sheet2.xml", `<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>`+
		`<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c><c r="E1" t="s"><v>4</v></c></row>`+
		`<row r="2"><c r="A2" t="s"><v>5</v></c><c r="B2" t="inlineStr"><is><t>Billing</t></is></c><c r="D2"><v>2024</v></c><c r="E2" t="b"><v>0</v></c></row>`+
		`<row r="3"><c r="A3" t="s"><v>5</v></c><c r="B3" t="str"><f>CONCAT("a","b")</f><v>ab</v></c><c r="C3" t="inlineStr"><is><t>no</t></is></c><c r="D3" t="s"><v>6</v></c></row>`+
		`</sheetData></worksheet>`)
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestImportXLSX(t *testing.T) {
	for _, name := range []string{"Inventory", "Sheet two"} { // by its name, else by its header
		f := mustParse(t, xlsxFixture(t, name))
		if f.Kind != "xlsx" || len(f.Rows) != 2 {
			t.Fatalf("%s: kind %s, rows %+v", name, f.Kind, f.Rows)
		}
		r := f.Rows[0]
		if r.Line != 2 || r.Instance != "pg-1" || r.Application != "Billing" || r.Database != "" || r.Description != "2024" || r.NotAnApp != "no" || r.Why != "" {
			t.Errorf("%s row 2: %+v", name, r)
		}
		r = f.Rows[1]
		if r.Line != 3 || !strings.Contains(r.Why, "formula") || r.Database != "no" || r.Description != "two\r\nlines" && r.Description != "two\nlines" {
			t.Errorf("%s row 3: %+v", name, r)
		}
	}
}

func TestImportRefusals(t *testing.T) {
	big := strings.Builder{}
	big.WriteString("instance,application\n")
	for i := 0; i <= importMaxRows; i++ {
		fmt.Fprintf(&big, "pg-%d,App\n", i)
	}
	for _, c := range []struct {
		name string
		body []byte
		want string
	}{
		{"empty", []byte("  \n"), "empty"},
		{"xls", append([]byte{0xD0, 0xCF, 0x11, 0xE0}, []byte("rest")...), ".xls"},
		{"utf-16", []byte{0xFF, 0xFE, 'i', 0}, "UTF-16"},
		{"latin-1", []byte("instance,application\npg-1,Caf\xe9\n"), "not UTF-8"},
		{"a broken zip", []byte("PK\x03\x04 not a zip at all"), "not an .xlsx"},
		{"20001 lines", []byte(big.String()), "at most"},
	} {
		if _, err := parseInventory(c.body); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.name, err, c.want)
		}
	}
}
