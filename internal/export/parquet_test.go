package export

import (
	"crypto/rand"
	"math/big"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/parquet-go/parquet-go"
)

func TestMapColumn(t *testing.T) {
	for _, c := range []struct{ table, name, pg, want, expr string }{
		{"t", "a", "boolean", "BOOLEAN", `"a"`},
		{"t", "a", "smallint", "INT32", `"a"`},
		{"t", "a", "bigint", "INT64", `"a"`},
		{"t", "a", "real", "FLOAT", `"a"`},
		{"t", "a", "double precision", "DOUBLE", `"a"`},
		{"t", "a", "numeric", "DOUBLE", `"a"::float8`},
		{"t", "a", "numeric(5,2)", "DECIMAL(5,2)", `"a"::text`},
		{"t", "a", "numeric(40,2)", "DOUBLE", `"a"::float8`},
		{"mssql_identity_column", "max_value", "numeric", "DECIMAL(38,0)", `trunc("max_value")::text`},
		{"t", "a", "timestamp with time zone", "TIMESTAMP(MICROS, UTC)", `"a"`},
		{"t", "a", "timestamp without time zone", "TIMESTAMP(MICROS, local)", `"a"`},
		{"t", "a", "date", "DATE", `"a"`},
		{"t", "a", "text", "STRING", `"a"`},
		{"t", "a", "pg_lsn", "STRING", `"a"::text`},
		{"t", "a", "bytea", "BYTE_ARRAY", `"a"`},
		{"t", "a", "jsonb", "JSON", `"a"::text`},
		{"t", "a", "text[]", "LIST<STRING>", `to_jsonb("a")::text`},
		{"t", "a", "integer[]", "LIST<INT32>", `to_jsonb("a")::text`},
		{"t", "a", "point", "STRING", `"a"::text`},
		{"t", "a", "point[]", "STRING", `to_jsonb("a")::text`},
	} {
		p := mapColumn(c.table, Column{Name: c.name, Type: c.pg})
		if p.parquet != c.want || p.expr != c.expr {
			t.Errorf("%s %s: %s read by %s; want %s read by %s", c.table, c.pg, p.parquet, p.expr, c.want, c.expr)
		}
	}
	if p := mapColumn("t", Column{Name: "a", Type: "point"}); p.note != "as text" {
		t.Errorf("a type with no line of its own says so: note %q", p.note)
	}
}

func TestUnscaled(t *testing.T) {
	for _, c := range []struct {
		in          string
		scale, prec int
		want        string
		ok          bool
	}{
		{"12.34", 2, 5, "1234", true}, {"-0.5", 2, 5, "-50", true}, {"7", 2, 5, "700", true}, {"0.8125", 4, 5, "8125", true},
		{"18446744073709551615", 0, 38, "18446744073709551615", true}, {"NaN", 2, 9, "", false}, {"Infinity", 0, 38, "", false},
		{"1234.5", 2, 5, "", false}, {"0", 0, 38, "0", true},
	} {
		u, ok := unscaled(c.in, c.scale, c.prec)
		if ok != c.ok || (ok && u.String() != c.want) {
			t.Errorf("unscaled(%q, %d, %d) = %v, %v; want %s, %v", c.in, c.scale, c.prec, u, ok, c.want, c.ok)
		}
	}
	if b := twosComplement(big.NewInt(-2), 2); b[0] != 0xff || b[1] != 0xfe {
		t.Errorf("twosComplement(-2, 2) = %x", b)
	}
	if b := twosComplement(big.NewInt(258), 4); b[2] != 1 || b[3] != 2 || b[0] != 0 {
		t.Errorf("twosComplement(258, 4) = %x", b)
	}
}

// A file read back with the library's own reader: the columns in the order given (not name order), the row groups
// closed at maxGroupRows with no empty one at the end, the values and the nulls.
func TestFileWriter(t *testing.T) {
	dir := t.TempDir()
	cols := []pcol{
		mapColumn("t", Column{Name: "zeta", Type: "bigint"}),
		mapColumn("t", Column{Name: "alpha", Type: "text"}),
		mapColumn("t", Column{Name: "tags", Type: "text[]"}),
		mapColumn("t", Column{Name: "at", Type: "timestamp with time zone"}),
		mapColumn("t", Column{Name: "fig", Type: "numeric(5,2)"}),
	}
	fw := newFileWriter(dir, "t", "t__x", cols)
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	const n = 2*maxGroupRows + 1
	for i := 0; i < n; i++ {
		var tags, stamp, fig any = `["a",null,"c"]`, at, "12.34"
		switch i {
		case 1:
			tags, stamp, fig = nil, pgtype.Infinity, "NaN"
		case 2:
			tags = `[]`
		}
		if err := fw.add([]any{int64(i), "row", tags, stamp, fig}); err != nil {
			t.Fatal(err)
		}
	}
	files, err := fw.finish()
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].RowCount != n || files[0].Path != "t/t__x.parquet" {
		t.Fatalf("files %+v", files)
	}
	if cols[3].note != "infinite as null" || cols[4].note != "infinite as null" {
		t.Errorf("an infinite timestamp and a NaN decimal are said: %q, %q", cols[3].note, cols[4].note)
	}
	f, err := os.Open(files[0].local)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	st, _ := f.Stat()
	if st.Size() != files[0].ByteSize {
		t.Errorf("byte_size %d, the file %d", files[0].ByteSize, st.Size())
	}
	pf, err := parquet.OpenFile(f, st.Size())
	if err != nil {
		t.Fatal(err)
	}
	var order []string
	for _, c := range pf.Schema().Columns() {
		order = append(order, c[0])
	}
	if got := len(order); got != 5 || order[0] != "zeta" || order[1] != "alpha" || order[2] != "tags" || order[3] != "at" || order[4] != "fig" {
		t.Errorf("column order %v", order)
	}
	var groups []int64
	for _, g := range pf.RowGroups() {
		groups = append(groups, g.NumRows())
	}
	if len(groups) != 3 || groups[0] != maxGroupRows || groups[1] != maxGroupRows || groups[2] != 1 {
		t.Errorf("row groups %v, want [%d %d 1]", groups, maxGroupRows, maxGroupRows)
	}
	rows := make([]parquet.Row, 3)
	rr := pf.RowGroups()[0].Rows()
	defer rr.Close()
	if k, _ := rr.ReadRows(rows); k != 3 {
		t.Fatalf("read %d rows", k)
	}
	// row 0: zeta, alpha, three list values (the middle one null), at, fig
	if len(rows[0]) != 7 || rows[0][0].Int64() != 0 || rows[0][1].String() != "row" || rows[0][3].IsNull() == false || rows[0][2].String() != "a" || rows[0][5].Int64() != at.UnixMicro() || rows[0][6].Int32() != 1234 {
		t.Errorf("row 0: %v", rows[0])
	}
	// row 1: a null list, a null timestamp, a null decimal
	if len(rows[1]) != 5 || !rows[1][2].IsNull() || !rows[1][3].IsNull() || !rows[1][4].IsNull() || rows[1][2].DefinitionLevel() != 0 {
		t.Errorf("row 1: %v", rows[1])
	}
	// row 2: an empty list is not a null list
	if len(rows[2]) != 5 || rows[2][2].DefinitionLevel() != 1 {
		t.Errorf("row 2: %v", rows[2])
	}
}

// The byte lines, crossed with small files: a row group is closed once its values pass maxGroupBytes, a file once
// what is written passes maxFileBytes; the second file carries __p2, and no row is lost.
func TestFileSplitByBytes(t *testing.T) {
	defer func(g, f int64) { maxGroupBytes, maxFileBytes = g, f }(maxGroupBytes, maxFileBytes)
	maxGroupBytes, maxFileBytes = 64<<10, 256<<10
	cols := []pcol{mapColumn("t", Column{Name: "b", Type: "bytea"})}
	fw := newFileWriter(t.TempDir(), "t", "t__x", cols)
	const n = 200
	for i := 0; i < n; i++ {
		buf := make([]byte, 8<<10) // random: ZSTD cannot shrink it
		if _, err := rand.Read(buf); err != nil {
			t.Fatal(err)
		}
		if err := fw.add([]any{buf}); err != nil {
			t.Fatal(err)
		}
	}
	files, err := fw.finish()
	if err != nil {
		t.Fatal(err)
	}
	// 200 rows of 8 KiB = 1.6 MiB: a group about every 8 rows, a file about every 256 KiB
	if len(files) < 4 || len(files) > 8 {
		t.Fatalf("%d files, want 4 to 8", len(files))
	}
	var rows int64
	for i, f := range files {
		rows += f.RowCount
		if f.ByteSize > 400<<10 {
			t.Errorf("%s is %d bytes: a file is closed at the first group past %d", f.Path, f.ByteSize, maxFileBytes)
		}
		want := "t/t__x.parquet"
		if i > 0 {
			want = "t/t__x__p" + string(rune('1'+i)) + ".parquet"
		}
		if f.Path != want {
			t.Errorf("file %d is %s, want %s", i, f.Path, want)
		}
		fh, err := os.Open(f.local)
		if err != nil {
			t.Fatal(err)
		}
		pf, err := parquet.OpenFile(fh, f.ByteSize)
		if err != nil {
			t.Fatal(err)
		}
		if i < len(files)-1 && len(pf.RowGroups()) < 2 {
			t.Errorf("%s has %d row group(s): the byte line closes one about every 8 rows", f.Path, len(pf.RowGroups()))
		}
		for _, g := range pf.RowGroups() {
			if g.NumRows() == 0 || g.NumRows() > 10 {
				t.Errorf("%s: a row group of %d rows", f.Path, g.NumRows())
			}
		}
		fh.Close()
	}
	if rows != n {
		t.Errorf("%d rows in the files, %d written", rows, n)
	}
	if !strings.HasSuffix(files[len(files)-1].Path, ".parquet") {
		t.Error("the last file is closed")
	}
}
