package export

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/parquet-go/parquet-go"
	"github.com/parquet-go/parquet-go/compress/zstd"
)

// The caps of a file: a row group is closed at maxGroupRows rows or maxGroupBytes of values, whichever comes first
// (a plan or a log line can be megabytes a row); a file at maxFileRows rows or maxFileBytes written.
const (
	maxGroupRows = 50_000
	maxFileRows  = 1_000_000
)

// the two byte lines are variables for the unit test that crosses them with small files
var (
	maxGroupBytes int64 = 64 << 20
	maxFileBytes  int64 = 256 << 20
)

type kind int

const (
	kBool kind = iota
	kInt32
	kInt64
	kFloat
	kDouble
	kDecimal
	kTimestampTZ
	kTimestamp
	kDate
	kString
	kBytes
	kJSON
	kList
)

// pcol is a column on its way out: how it is read from PostgreSQL and what it is in the file.
type pcol struct {
	Column
	kind        kind
	elem        kind   // kList: its elements
	prec, scale int    // kDecimal
	expr        string // the SELECT expression
	parquet     string // the manifest's parquet_type
	note        string // the manifest's note
	nulled      bool   // a value that has no Parquet form (infinity, NaN) was written as null
}

var (
	numericMod = regexp.MustCompile(`^numeric\((\d+),(\d+)\)$`)
	typeMod    = regexp.MustCompile(`^(character varying|character|timestamp|time)\(\d+\)(.*)$`)
)

// wholeFigures are the numeric columns that hold whole figures up to the bigint line and past it (an identity's or
// a sequence's last and largest value). A DOUBLE would merge neighbours there. They leave as text holding their
// exact digits: a DECIMAL(38, 0) is 16 bytes, and the writer orders 16-byte values unsigned, so the statistics of a
// column that holds a negative figure (an identity seeded below zero) would name the wrong minimum and maximum and
// a reader that trusts them would lose rows.
var wholeFigures = map[string]bool{
	"mssql_identity_column.last_value": true, "mssql_identity_column.max_value": true,
	"mssql_identity_column.anchor_value": true, "sequence_state.col_max": true,
}

// mapColumn gives a column its Parquet type. Every type of the repository's schema has a line; a type with none is
// carried as the text PostgreSQL prints, and the manifest says so - never dropped silently.
func mapColumn(table string, c Column) pcol {
	p := pcol{Column: c, expr: quoteIdent(c.Name)}
	if m := typeMod.FindStringSubmatch(c.Type); m != nil {
		c.Type = m[1] + m[2] // character varying(20), timestamp(3) with time zone: the type without its modifier
	}
	scalar := func(t string) (kind, string, bool) {
		switch t {
		case "boolean":
			return kBool, "BOOLEAN", true
		case "smallint", "integer":
			return kInt32, "INT32", true
		case "bigint", "oid", "xid":
			return kInt64, "INT64", true
		case "real":
			return kFloat, "FLOAT", true
		case "double precision":
			return kDouble, "DOUBLE", true
		case "text", "character varying", "character", "name", "uuid", "inet", "cidr", "pg_lsn", "\"char\"", "interval", "time without time zone", "time with time zone":
			return kString, "STRING", true
		}
		return 0, "", false
	}
	switch t := c.Type; {
	case t == "timestamp with time zone":
		p.kind, p.parquet = kTimestampTZ, "TIMESTAMP(MICROS, UTC)"
	case t == "timestamp without time zone":
		p.kind, p.parquet = kTimestamp, "TIMESTAMP(MICROS, local)"
	case t == "date":
		p.kind, p.parquet = kDate, "DATE"
	case t == "bytea":
		p.kind, p.parquet = kBytes, "BYTE_ARRAY"
	case t == "json" || t == "jsonb":
		p.kind, p.parquet, p.expr = kJSON, "JSON", p.expr+"::text"
	case t == "numeric" && wholeFigures[table+"."+c.Name]:
		p.kind, p.parquet, p.note, p.expr = kString, "STRING", "exact digits as text", "trunc("+p.expr+")::text"
	case t == "numeric":
		p.kind, p.parquet, p.expr = kDouble, "DOUBLE", p.expr+"::float8"
	case numericMod.MatchString(t):
		m := numericMod.FindStringSubmatch(t)
		p.prec, _ = strconv.Atoi(m[1])
		p.scale, _ = strconv.Atoi(m[2])
		if p.prec > 18 {
			// past 18 digits a DECIMAL is 16 bytes, whose statistics the writer cannot order (see wholeFigures)
			p.kind, p.parquet, p.note, p.expr = kString, "STRING", "exact digits as text", p.expr+"::text"
			break
		}
		p.kind, p.parquet, p.expr = kDecimal, fmt.Sprintf("DECIMAL(%d,%d)", p.prec, p.scale), p.expr+"::text"
	case strings.HasSuffix(t, "[]"):
		if k, name, ok := scalar(strings.TrimSuffix(t, "[]")); ok {
			p.kind, p.elem, p.parquet, p.expr = kList, k, "LIST<"+name+">", "to_jsonb("+p.expr+")::text"
			break
		}
		p.kind, p.parquet, p.note, p.expr = kString, "STRING", "as JSON text", "to_jsonb("+p.expr+")::text"
	default:
		if k, name, ok := scalar(t); ok {
			p.kind, p.parquet = k, name
			if k == kString && t != "text" && t != "character varying" && t != "character" && t != "name" {
				p.expr += "::text"
			}
			break
		}
		p.kind, p.parquet, p.note, p.expr = kString, "STRING", "as text", p.expr+"::text"
	}
	return p
}

func quoteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }

func leafNode(k kind, p *pcol) parquet.Node {
	switch k {
	case kBool:
		return parquet.Leaf(parquet.BooleanType)
	case kInt32:
		return parquet.Leaf(parquet.Int32Type)
	case kInt64:
		return parquet.Leaf(parquet.Int64Type)
	case kFloat:
		return parquet.Leaf(parquet.FloatType)
	case kDouble:
		return parquet.Leaf(parquet.DoubleType)
	case kDecimal:
		if p.prec > 9 {
			return parquet.Decimal(p.scale, p.prec, parquet.Int64Type) // the scale first
		}
		return parquet.Decimal(p.scale, p.prec, parquet.Int32Type)
	case kTimestampTZ:
		return parquet.TimestampAdjusted(parquet.Microsecond, true)
	case kTimestamp:
		return parquet.TimestampAdjusted(parquet.Microsecond, false)
	case kDate:
		return parquet.Date()
	case kBytes:
		return parquet.Leaf(parquet.ByteArrayType)
	case kJSON:
		return parquet.JSON()
	}
	return parquet.String()
}

// orderedGroup is a group whose fields keep the table's own column order (parquet.Group sorts them by name).
type orderedGroup struct {
	parquet.Group
	order []string
}

func (g orderedGroup) Fields() []parquet.Field {
	byName := map[string]parquet.Field{}
	for _, f := range g.Group.Fields() {
		byName[f.Name()] = f
	}
	out := make([]parquet.Field, len(g.order))
	for i, n := range g.order {
		out[i] = byName[n]
	}
	return out
}

// schemaOf builds the file's schema: every column OPTIONAL, in the table's own order; a list's elements OPTIONAL.
func schemaOf(table string, cols []pcol) *parquet.Schema {
	g := orderedGroup{Group: parquet.Group{}}
	for i := range cols {
		c := &cols[i]
		var n parquet.Node
		if c.kind == kList {
			n = parquet.List(parquet.Optional(leafNode(c.elem, c)))
		} else {
			n = leafNode(c.kind, c)
		}
		g.Group[c.Name] = parquet.Optional(n)
		g.order = append(g.order, c.Name)
	}
	return parquet.NewSchema(table, g)
}

// OutputFile is one finished file of a table and window.
type OutputFile struct {
	Path     string `json:"path"` // under the repository's folder at the destination: <table>/<file>
	RowCount int64  `json:"row_count"`
	ByteSize int64  `json:"byte_size"`
	SHA256   string `json:"sha256"`
	local    string
}

// fileWriter writes one table's rows of one window into one or more Parquet files under dir. No file is made for
// no row.
type fileWriter struct {
	dir, table, base string // base: the file name without a part mark and without .parquet
	cols             []pcol
	schema           *parquet.Schema
	f                *os.File
	sum              hash.Hash
	n                *countWriter
	w                *parquet.Writer //nolint:staticcheck // SA1019: the schema writer the export was built and proven on; the generic writer is a change of its own
	batch            []parquet.Row
	fileRows         int64
	groupRows        int64
	groupBytes       int64
	done             []OutputFile
}

type countWriter struct {
	w io.Writer
	n int64
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

func newFileWriter(dir, table, base string, cols []pcol) *fileWriter {
	return &fileWriter{dir: dir, table: table, base: base, cols: cols, schema: schemaOf(table, cols)}
}

func (fw *fileWriter) open() error {
	name := fw.base + ".parquet"
	if n := len(fw.done); n > 0 {
		name = fmt.Sprintf("%s__p%d.parquet", fw.base, n+1)
	}
	f, err := os.Create(filepath.Join(fw.dir, name))
	if err != nil {
		return err
	}
	fw.f, fw.sum = f, sha256.New()
	fw.n = &countWriter{w: io.MultiWriter(f, fw.sum)}
	opts := []parquet.WriterOption{fw.schema, parquet.Compression(&zstd.Codec{Level: zstd.DefaultLevel}), parquet.CreatedBy("pgvigil", "export", "1")}
	// No statistics in the page headers of a text, bytes or JSON column: the writer would put the page's smallest and
	// largest value there whole, four times over - megabytes for a plan or a log line, and past the 16 MB a common
	// reader allows a page header. The row group's own minimum and maximum and the column index stay.
	for i := range fw.cols {
		c := &fw.cols[i]
		switch {
		case c.kind == kString || c.kind == kJSON || c.kind == kBytes:
			opts = append(opts, parquet.SkipPageStatistics(c.Name))
		case c.kind == kList && c.elem == kString:
			opts = append(opts, parquet.SkipPageStatistics(c.Name, "list", "element"))
		}
	}
	fw.w = parquet.NewWriter(fw.n, opts...)
	fw.fileRows, fw.groupRows, fw.groupBytes = 0, 0, 0
	return nil
}

// add writes one row (the values of fw.cols in order, as PostgreSQL sent them).
func (fw *fileWriter) add(vals []any) error {
	if fw.w == nil {
		if err := fw.open(); err != nil {
			return err
		}
	}
	row := make(parquet.Row, 0, len(vals)+2)
	size := 0
	for i := range fw.cols {
		var n int
		row, n = appendValue(row, &fw.cols[i], i, vals[i])
		size += n + 8
	}
	fw.batch = append(fw.batch, row)
	fw.fileRows++
	fw.groupRows++
	fw.groupBytes += int64(size)
	if len(fw.batch) >= 1024 || fw.groupRows >= maxGroupRows || fw.groupBytes >= maxGroupBytes || fw.fileRows >= maxFileRows {
		if err := fw.flushBatch(); err != nil {
			return err
		}
	}
	if fw.groupRows >= maxGroupRows || fw.groupBytes >= maxGroupBytes {
		if err := fw.w.Flush(); err != nil {
			return err
		}
		fw.groupRows, fw.groupBytes = 0, 0
		if fw.n.n >= maxFileBytes {
			return fw.closeFile()
		}
	}
	if fw.fileRows >= maxFileRows {
		return fw.closeFile()
	}
	return nil
}

func (fw *fileWriter) flushBatch() error {
	if len(fw.batch) == 0 {
		return nil
	}
	_, err := fw.w.WriteRows(fw.batch)
	fw.batch = fw.batch[:0]
	return err
}

func (fw *fileWriter) closeFile() error {
	if fw.w == nil {
		return nil
	}
	if err := fw.flushBatch(); err != nil {
		return err
	}
	if err := fw.w.Close(); err != nil {
		return err
	}
	name := filepath.Base(fw.f.Name())
	if err := fw.f.Close(); err != nil {
		return err
	}
	fw.done = append(fw.done, OutputFile{Path: fw.table + "/" + name, RowCount: fw.fileRows, ByteSize: fw.n.n,
		SHA256: hex.EncodeToString(fw.sum.Sum(nil)), local: filepath.Join(fw.dir, name)})
	fw.w, fw.f = nil, nil
	return nil
}

// finish closes the last file and returns every file written.
func (fw *fileWriter) finish() ([]OutputFile, error) {
	if err := fw.closeFile(); err != nil {
		return nil, err
	}
	return fw.done, nil
}

// abort drops what was written (a read that failed part way).
func (fw *fileWriter) abort() {
	if fw.f != nil {
		_ = fw.f.Close()
		_ = os.Remove(fw.f.Name())
	}
	for _, d := range fw.done {
		_ = os.Remove(d.local)
	}
	fw.w, fw.f, fw.done = nil, nil, nil
}

// appendValue appends a column's value (several for a list) with its levels: a top-level column is OPTIONAL
// (definition 0 = null, 1 = set); a list adds its repeated group (2) and its OPTIONAL element (3).
func appendValue(row parquet.Row, c *pcol, col int, v any) (parquet.Row, int) {
	if v == nil {
		return append(row, parquet.NullValue().Level(0, 0, col)), 0
	}
	if c.kind == kList {
		var elems []any
		s, ok := v.(string)
		if ok {
			d := json.NewDecoder(strings.NewReader(s))
			d.UseNumber() // a bigint element keeps every digit
			ok = d.Decode(&elems) == nil
		}
		if !ok {
			c.nulled, c.note = true, "a list that could not be read as null"
			return append(row, parquet.NullValue().Level(0, 0, col)), 0
		}
		if len(elems) == 0 {
			return append(row, parquet.NullValue().Level(0, 1, col)), 0
		}
		size := 0
		for i, e := range elems {
			rep := 1
			if i == 0 {
				rep = 0
			}
			pv, ok, n := listElement(c, e)
			if !ok {
				row = append(row, parquet.NullValue().Level(rep, 2, col))
				continue
			}
			row = append(row, pv.Level(rep, 3, col))
			size += n
		}
		return row, size
	}
	pv, ok, n := scalarValue(c, c.kind, v)
	if !ok {
		return append(row, parquet.NullValue().Level(0, 0, col)), 0
	}
	return append(row, pv.Level(0, 1, col)), n
}

// listElement turns one element of an array (read as JSON) into its value. An element that is itself an array
// (a second dimension) is carried as its JSON text in a list of strings and as null elsewhere.
func listElement(c *pcol, e any) (parquet.Value, bool, int) {
	switch x := e.(type) {
	case nil:
		return parquet.Value{}, false, 0
	case string:
		if c.elem == kString {
			return parquet.ByteArrayValue([]byte(x)), true, len(x)
		}
	case bool:
		if c.elem == kBool {
			return parquet.BooleanValue(x), true, 1
		}
	case json.Number:
		switch c.elem {
		case kInt32, kInt64:
			if n, err := x.Int64(); err == nil {
				if c.elem == kInt32 {
					return parquet.Int32Value(int32(n)), true, 4
				}
				return parquet.Int64Value(n), true, 8
			}
		case kFloat, kDouble:
			if f, err := x.Float64(); err == nil {
				if c.elem == kFloat {
					return parquet.FloatValue(float32(f)), true, 4
				}
				return parquet.DoubleValue(f), true, 8
			}
		}
	}
	if c.elem == kString {
		if b, err := json.Marshal(e); err == nil {
			c.note = "an element of a second dimension as JSON text"
			return parquet.ByteArrayValue(b), true, len(b)
		}
	}
	c.nulled, c.note = true, "an element with no form in the list as null"
	return parquet.Value{}, false, 0
}

// daysSinceEpoch is a date as Parquet's DATE: whole days since 1970-01-01, by the calendar and at any distance (a
// Duration between two times saturates at about 292 years).
func daysSinceEpoch(t time.Time) int64 {
	s := t.Unix()
	d := s / 86400
	if s%86400 < 0 {
		d--
	}
	return d
}

// scalarValue turns a value as pgx gives it into its Parquet value; ok false = written as null (and c says why).
func scalarValue(c *pcol, k kind, v any) (parquet.Value, bool, int) {
	infinite := func() (parquet.Value, bool, int) {
		c.nulled, c.note = true, "infinite as null"
		return parquet.Value{}, false, 0
	}
	switch k {
	case kBool:
		if x, ok := v.(bool); ok {
			return parquet.BooleanValue(x), true, 1
		}
	case kInt32:
		switch x := v.(type) {
		case int16:
			return parquet.Int32Value(int32(x)), true, 4
		case int32:
			return parquet.Int32Value(x), true, 4
		}
	case kInt64:
		switch x := v.(type) {
		case int64:
			return parquet.Int64Value(x), true, 8
		case uint32:
			return parquet.Int64Value(int64(x)), true, 8
		case int32:
			return parquet.Int64Value(int64(x)), true, 8
		}
	case kFloat:
		if x, ok := v.(float32); ok {
			return parquet.FloatValue(x), true, 4
		}
	case kDouble:
		if x, ok := v.(float64); ok {
			return parquet.DoubleValue(x), true, 8
		}
	case kTimestampTZ, kTimestamp:
		switch x := v.(type) {
		case time.Time:
			return parquet.Int64Value(x.UnixMicro()), true, 8
		case pgtype.InfinityModifier:
			return infinite()
		}
	case kDate:
		switch x := v.(type) {
		case time.Time:
			return parquet.Int32Value(int32(daysSinceEpoch(x))), true, 4
		case pgtype.InfinityModifier:
			return infinite()
		}
	case kBytes:
		if x, ok := v.([]byte); ok {
			return parquet.ByteArrayValue(x), true, len(x)
		}
	case kString, kJSON:
		switch x := v.(type) {
		case string:
			return parquet.ByteArrayValue([]byte(x)), true, len(x)
		case []byte:
			return parquet.ByteArrayValue(x), true, len(x)
		}
	case kDecimal:
		s, ok := v.(string)
		if !ok {
			break
		}
		u, ok := unscaled(s, c.scale, c.prec)
		if !ok {
			return infinite() // NaN, Infinity, or more digits than the column's precision holds
		}
		if c.prec > 9 {
			return parquet.Int64Value(u.Int64()), true, 8
		}
		return parquet.Int32Value(int32(u.Int64())), true, 4
	}
	c.nulled, c.note = true, fmt.Sprintf("a value of Go type %T as null", v)
	return parquet.Value{}, false, 0
}

// unscaled parses numeric text ('12.34', '-0.5', '18446744073709551615') into its unscaled integer at the scale;
// false for NaN, an infinity, or a figure of more than prec digits.
func unscaled(s string, scale, prec int) (*big.Int, bool) {
	s = strings.TrimSpace(s)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(strings.TrimPrefix(s, "-"), "+")
	whole, frac, _ := strings.Cut(s, ".")
	if whole == "" && frac == "" {
		return nil, false
	}
	for len(frac) < scale {
		frac += "0"
	}
	frac = frac[:scale]
	u, ok := new(big.Int).SetString(whole+frac, 10)
	if !ok || len(strings.TrimLeft(whole+frac, "0")) > prec {
		return nil, false
	}
	if neg {
		u.Neg(u)
	}
	return u, true
}
