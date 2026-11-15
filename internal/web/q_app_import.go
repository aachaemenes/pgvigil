package web

// Task 312: the applications inventory's file round trip (migration 0146; docs/applications.md, 'The inventory file').
//
//	GET  /api/applications/inventory       the rows of pgvigil.app_inventory() for the page's Inventory grid
//	GET  /api/applications/inventory.csv   the same rows as CSV (UTF-8 with BOM, a formula guard), an attachment
//	POST /api/admin/applications/import    the raw file as the body (CSV, JSON or .xlsx, 5 MB at most): ?dry=1 the
//	                                       preview, else ?digest=<the preview's>&force=<ticked item ids>; ?source=<name>
//
// Go only parses; pgvigil.import_app_file plans, digests and writes (one SQL planner: the 312 pass, answer 3). The
// .xlsx is read with the standard library alone (archive/zip, encoding/xml: the lead's condition on F3). Contacts are
// never in the file either way (F1, A14): a contact-like column of an imported file is listed as not read.

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

const (
	importBodyLimit = 5 << 20          // the file
	importMaxRows   = 20000            // its lines
	xlsxPartLimit   = 64 << 20         // one decompressed part of an .xlsx
	xlsxMaxEntries  = 4000             // the parts of an .xlsx
	xlsxMaxStrings  = 400000           // its shared strings
	xlsxMaxSheets   = 32               // the sheets a workbook may list (review B, M3)
	xlsxUnpacked    = 128 << 20        // all its parts unpacked (review B, M3)
	xlsxMaxCols     = 64               // the cells of a row read (the file has 14 columns; review B, M2)
	unreadMax       = 40               // the names of columns not read, listed (review B, M1)
	importTimeout   = "120s"           // the planner's own statement timeout (the audit pool's is 5 s)
	importReadTime  = 60 * time.Second // the body's read and parse, before the work's budget starts
)

// invColumns are the file's columns in order; the last four are the export's alone (read back and ignored).
var invColumns = []string{"level", "instance", "engine", "database", "application", "environment", "tier", "description",
	"cmdb_url", "not_an_application", "inherited_from", "absent_since", "source", "set_at"}

var invExportOnly = map[string]bool{"inherited_from": true, "absent_since": true, "source": true, "set_at": true}

// invRow is one line of an imported file as the planner takes it (every cell text; Why a refusal of the parser's).
type invRow struct {
	Line        int    `json:"line"`
	Why         string `json:"why,omitempty"`
	Level       string `json:"level"`
	Instance    string `json:"instance"`
	Engine      string `json:"engine"`
	Database    string `json:"database"`
	Application string `json:"application"`
	Environment string `json:"environment"`
	Tier        string `json:"tier"`
	Description string `json:"description"`
	CmdbURL     string `json:"cmdb_url"`
	NotAnApp    string `json:"not_an_application"`
}

func (r *invRow) set(col, v string) {
	switch col {
	case "level":
		r.Level = v
	case "instance":
		r.Instance = v
	case "engine":
		r.Engine = v
	case "database":
		r.Database = v
	case "application":
		r.Application = v
	case "environment":
		r.Environment = v
	case "tier":
		r.Tier = v
	case "description":
		r.Description = v
	case "cmdb_url":
		r.CmdbURL = v
	case "not_an_application":
		r.NotAnApp = v
	}
}

// invFile is a parsed file: its kind, its lines, the columns not read (unknown, or a contact's: never imported).
type invFile struct {
	Kind   string
	Rows   []invRow
	Unread []string
}

// normCol: a header cell as a column key ('Not an application' and 'not-an-application' are not_an_application).
func normCol(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = strings.NewReplacer(" ", "_", "-", "_").Replace(s)
	switch s {
	case "server", "instance_name":
		return "instance"
	case "database_name", "db":
		return "database"
	case "app", "application_name":
		return "application"
	case "cmdb", "cmdb_link", "cmdb_url":
		return "cmdb_url"
	}
	return s
}

func isHeader(cells []string) bool {
	var inst, app bool
	for _, c := range cells {
		switch normCol(c) {
		case "instance":
			inst = true
		case "application":
			app = true
		}
	}
	return inst && app
}

// parseInventory reads a file by what it holds (never by its name): an .xlsx (a zip), JSON, or CSV.
func parseInventory(body []byte) (*invFile, error) {
	switch {
	case len(bytes.TrimSpace(body)) == 0:
		return nil, errors.New("the file is empty")
	case bytes.HasPrefix(body, []byte("PK\x03\x04")):
		return parseXLSX(body)
	case bytes.HasPrefix(body, []byte{0xD0, 0xCF, 0x11, 0xE0}):
		return nil, errors.New("an .xls file (Excel 97-2003) is not read: save the sheet as .xlsx or as CSV UTF-8")
	case bytes.HasPrefix(body, []byte{0xFF, 0xFE}) || bytes.HasPrefix(body, []byte{0xFE, 0xFF}):
		return nil, errors.New("the file is UTF-16 text: save it as CSV UTF-8")
	case !utf8.Valid(body):
		return nil, errors.New("the file is not UTF-8 text: save it as CSV UTF-8 (or as .xlsx)")
	}
	text := strings.TrimPrefix(string(body), "\ufeff")
	if t := strings.TrimSpace(text); strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[") {
		return parseJSONInventory(t)
	}
	return parseCSVInventory(text)
}

// fromRecords turns a header and its records into lines; every cell's line ends made LF.
func fromRecords(kind string, header []string, recs [][]string, lines []int, whys []string) (*invFile, error) {
	cols := make([]string, len(header))
	f := &invFile{Kind: kind}
	seen := map[string]bool{}
	first := map[string]string{} // a known column's header cell: a second cell naming it is refused (review B, M4)
	for i, h := range header {
		c := normCol(h)
		cols[i] = c
		known := slicesContains(invColumns, c)
		if known {
			if prev, dup := first[c]; dup {
				return nil, fmt.Errorf("the header names the column %s twice (%q and %q): keep one of them", c, prev, strings.TrimSpace(h))
			}
			first[c] = strings.TrimSpace(h)
		}
		if (!known || c == "") && strings.TrimSpace(h) != "" && !seen[c] {
			seen[c] = true
			f.Unread = append(f.Unread, strings.TrimSpace(h))
		}
		if known && invExportOnly[c] {
			cols[i] = "" // read back and ignored
		}
	}
	f.Unread = capUnread(f.Unread)
	for n, rec := range recs {
		empty := true
		for _, c := range rec {
			if strings.TrimSpace(c) != "" {
				empty = false
				break
			}
		}
		if empty && (whys == nil || whys[n] == "") { // a blank line that carries a reason is a refused line (review B, m4)
			continue
		}
		if len(f.Rows) >= importMaxRows {
			return nil, fmt.Errorf("more than %d lines: at most %d in one file (split it)", importMaxRows, importMaxRows)
		}
		row := invRow{Line: lines[n]}
		if whys != nil {
			row.Why = whys[n]
		}
		for i, v := range rec {
			if i >= len(cols) || cols[i] == "" || !slicesContains(invColumns, cols[i]) {
				continue
			}
			v = strings.ReplaceAll(v, "\r\n", "\n")
			if strings.ContainsRune(v, 0) {
				row.Why = "a cell holds a NUL character: this line is not read"
				v = strings.ReplaceAll(v, "\x00", "")
			}
			row.set(cols[i], v)
		}
		f.Rows = append(f.Rows, row)
	}
	return f, nil
}

// capUnread: the names of the columns not read, at most unreadMax of them and a count of the rest
func capUnread(u []string) []string {
	if len(u) <= unreadMax {
		return u
	}
	return append(u[:unreadMax:unreadMax], fmt.Sprintf("and %d more", len(u)-unreadMax))
}

// csvGuardUndo: the export writes one more ' before a cell that starts with = + - @ TAB CR (or with 's before one); the
// import takes one off - exact both ways (the 312 pass, answer 4), on CSV only.
var csvGuardUndo = regexp.MustCompile(`^'+[=+\-@\t\r]`)

func undoGuard(v string) string {
	if csvGuardUndo.MatchString(v) {
		return v[1:]
	}
	return v
}

var csvGuard = regexp.MustCompile(`^'*[=+\-@\t\r]`)

func guardCell(v string) string {
	if csvGuard.MatchString(v) {
		return "'" + v
	}
	return v
}

// parseCSVInventory: the header is the first record naming instance and application (the bar's export writes up to
// two lines above it); its line decides the separator - a comma, or a semicolon (Excel in a comma-decimal locale).
func parseCSVInventory(text string) (*invFile, error) {
	// the header line: the first of the file's first lines whose cells, split at a comma, a semicolon or a tab, name
	// instance and application (their other names too: server, app) - t-im-u2, a literal search missed them
	sep := rune(0)
	for i, l := range strings.SplitN(text, "\n", 40) {
		if i == 39 {
			break
		}
		for _, c := range []rune{',', ';', '\t'} {
			cells := strings.Split(strings.TrimRight(l, "\r"), string(c))
			for k := range cells {
				cells[k] = strings.Trim(cells[k], `" `)
			}
			if len(cells) > 1 && isHeader(cells) {
				sep = c
				break
			}
		}
		if sep != 0 {
			break
		}
	}
	switch sep {
	case 0:
		return nil, errors.New("no header line naming instance and application in the file's first lines")
	case '\t':
		return nil, errors.New("a tab-separated file is not read: save it as CSV UTF-8 (commas or semicolons)")
	}
	cr := csv.NewReader(strings.NewReader(text))
	cr.Comma = sep
	// a bad quote is refused with its line (review B, m2: with LazyQuotes a quote that ends a field early read the rest of
	// the file into one cell); the export and Excel write RFC 4180
	cr.FieldsPerRecord = -1
	var header []string
	var recs [][]string
	var lines []int
	for {
		rec, err := cr.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("the CSV could not be read: %v", err)
		}
		line, _ := cr.FieldPos(0)
		if header == nil {
			if isHeader(rec) {
				header = rec
			}
			continue
		}
		for i := range rec {
			rec[i] = undoGuard(rec[i])
		}
		recs, lines = append(recs, rec), append(lines, line)
	}
	if header == nil {
		return nil, errors.New("no header line naming instance and application")
	}
	return fromRecords("csv", header, recs, lines, nil)
}

// parseJSONInventory: {columns, rows} as the API writes a grid, or an array of objects.
func parseJSONInventory(t string) (*invFile, error) {
	dec := json.NewDecoder(strings.NewReader(t))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, fmt.Errorf("the JSON could not be read: %v", err)
	}
	cell := func(x any) (string, bool) {
		switch c := x.(type) {
		case nil:
			return "", true
		case string:
			return c, true
		case json.Number:
			return c.String(), true
		case bool:
			if c {
				return "yes", true
			}
			return "no", true
		}
		return "", false
	}
	var header []string
	var recs [][]string
	var whys []string
	switch d := v.(type) {
	case map[string]any:
		cs, ok1 := d["columns"].([]any)
		rs, ok2 := d["rows"].([]any)
		if !ok1 || !ok2 {
			return nil, errors.New("a JSON object needs columns and rows (as the API writes a grid)")
		}
		for _, c := range cs {
			s, _ := cell(c)
			header = append(header, s)
		}
		if len(rs) > importMaxRows {
			return nil, fmt.Errorf("more than %d lines: at most %d in one file (split it)", importMaxRows, importMaxRows)
		}
		for _, r := range rs {
			arr, isArr := r.([]any)
			if len(arr) > len(header) {
				arr = arr[:len(header)]
			}
			rec, why := make([]string, len(arr)), ""
			if !isArr {
				why = "a line is not a list of cells: not read"
			}
			for i, x := range arr {
				s, ok := cell(x)
				if !ok {
					why = "a cell is not a single value: this line is not read"
				}
				rec[i] = s
			}
			recs, whys = append(recs, rec), append(whys, why)
		}
	case []any:
		// the elements counted before any row is built, and a row holds the known columns alone: a key no column takes
		// is a name in the 'not read' list, never a cell (review B, M1: 100,000 keys times a million elements)
		if len(d) > importMaxRows {
			return nil, fmt.Errorf("more than %d lines: at most %d in one file (split it)", importMaxRows, importMaxRows)
		}
		idx := map[string]int{}
		unknown := map[string]bool{}
		for _, r := range d {
			obj, _ := r.(map[string]any)
			for k := range obj {
				if _, ok := idx[k]; ok || unknown[k] {
					continue
				}
				if !slicesContains(invColumns, normCol(k)) {
					unknown[k] = true
					continue
				}
				idx[k] = -1
			}
		}
		keys := make([]string, 0, len(idx))
		for k := range idx {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			idx[k] = len(header)
			header = append(header, k)
		}
		for _, r := range d {
			obj, isObj := r.(map[string]any)
			rec, why := make([]string, len(header)), ""
			if !isObj {
				why = "a line is not an object: not read"
			}
			for k, x := range obj {
				i, ok := idx[k]
				if !ok {
					continue
				}
				s, ok := cell(x)
				if !ok {
					why = "a cell is not a single value: this line is not read"
				}
				rec[i] = s
			}
			recs, whys = append(recs, rec), append(whys, why)
		}
		names := make([]string, 0, len(unknown))
		for k := range unknown {
			names = append(names, k)
		}
		sort.Strings(names)
		if !isHeader(header) {
			return nil, errors.New("the JSON names no instance and application columns")
		}
		lines := make([]int, len(recs))
		for i := range lines {
			lines[i] = i + 1
		}
		f, err := fromRecords("json", header, recs, lines, whys)
		if err != nil {
			return nil, err
		}
		f.Unread = capUnread(append(f.Unread, names...))
		return f, nil
	default:
		return nil, errors.New("the JSON is neither {columns, rows} nor an array of rows")
	}
	if !isHeader(header) {
		return nil, errors.New("the JSON names no instance and application columns")
	}
	lines := make([]int, len(recs))
	for i := range lines {
		lines[i] = i + 1
	}
	return fromRecords("json", header, recs, lines, whys)
}

// ---- .xlsx with the standard library: the workbook's sheets through its rels, shared and inline strings, cells by
// their reference (the house export leaves blank cells out), a formula cell refused, every part's size capped ----

type xlsxReader struct {
	zr       *zip.Reader
	unpacked int // the bytes unpacked so far: xlsxUnpacked for the whole file (review B, M3)
}

func (x *xlsxReader) part(name string) ([]byte, error) {
	name = strings.TrimPrefix(name, "/")
	for _, f := range x.zr.File {
		if strings.EqualFold(f.Name, name) {
			rc, err := f.Open()
			if err != nil {
				return nil, err
			}
			defer func() { _ = rc.Close() }()
			b, err := io.ReadAll(io.LimitReader(rc, xlsxPartLimit+1))
			if err != nil {
				return nil, err
			}
			if len(b) > xlsxPartLimit {
				return nil, fmt.Errorf("%s is over %d MB unpacked: not read", name, xlsxPartLimit>>20)
			}
			if x.unpacked += len(b); x.unpacked > xlsxUnpacked {
				return nil, fmt.Errorf("the workbook is over %d MB unpacked: not read", xlsxUnpacked>>20)
			}
			return b, nil
		}
	}
	return nil, nil
}

// xlsxUnescape: Excel writes a control character in a string as _xHHHH_ (and an underscore before one as _x005F_).
var xlsxEsc = regexp.MustCompile(`_x([0-9A-Fa-f]{4})_`)

func xlsxUnescape(s string) string {
	if !strings.Contains(s, "_x") {
		return s
	}
	return xlsxEsc.ReplaceAllStringFunc(s, func(m string) string {
		n, err := strconv.ParseUint(m[2:6], 16, 32)
		if err != nil {
			return m
		}
		return string(rune(n))
	})
}

func parseXLSX(body []byte) (*invFile, error) {
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		return nil, fmt.Errorf("the file is not an .xlsx workbook (%v)", err)
	}
	if len(zr.File) > xlsxMaxEntries {
		return nil, fmt.Errorf("the workbook holds %d parts: not read", len(zr.File))
	}
	x := &xlsxReader{zr: zr}
	wb, err := x.part("xl/workbook.xml")
	if err != nil || wb == nil {
		return nil, fmt.Errorf("the workbook has no xl/workbook.xml: not an .xlsx (%v)", err)
	}
	var book struct {
		Pr struct {
			Date1904 string `xml:"date1904,attr"`
		} `xml:"workbookPr"`
		Sheets []struct {
			Name string `xml:"name,attr"`
			RID  string `xml:"http://schemas.openxmlformats.org/officeDocument/2006/relationships id,attr"`
		} `xml:"sheets>sheet"`
	}
	if err := xml.Unmarshal(wb, &book); err != nil {
		return nil, fmt.Errorf("xl/workbook.xml could not be read: %v", err)
	}
	if len(book.Sheets) > xlsxMaxSheets {
		return nil, fmt.Errorf("the workbook lists %d sheets: at most %d are read (save the inventory's sheet alone)", len(book.Sheets), xlsxMaxSheets)
	}
	d1904 := book.Pr.Date1904 == "1" || strings.EqualFold(book.Pr.Date1904, "true") // a Mac workbook's day 0 is 1904-01-01 (review B, m7)
	relsB, err := x.part("xl/_rels/workbook.xml.rels")
	if err != nil || relsB == nil {
		return nil, fmt.Errorf("the workbook has no relationships part: not read (%v)", err)
	}
	var rels struct {
		R []struct {
			ID     string `xml:"Id,attr"`
			Target string `xml:"Target,attr"`
		} `xml:"Relationship"`
	}
	if err := xml.Unmarshal(relsB, &rels); err != nil {
		return nil, fmt.Errorf("the workbook's relationships could not be read: %v", err)
	}
	target := map[string]string{}
	for _, r := range rels.R {
		t := r.Target
		if strings.HasPrefix(t, "/") {
			t = strings.TrimPrefix(t, "/")
		} else {
			t = "xl/" + t
		}
		target[r.ID] = t
	}
	var sst []string
	if sb, err := x.part("xl/sharedStrings.xml"); err != nil {
		return nil, err
	} else if sb != nil {
		if sst, err = xlsxStrings(sb); err != nil {
			return nil, err
		}
	}
	dates := map[int]bool{}
	if st, err := x.part("xl/styles.xml"); err != nil {
		return nil, err
	} else if st != nil {
		dates = xlsxDateStyles(st)
	}
	// the sheet named Inventory, else the first whose header (in its first 20 rows) names instance and application
	order := make([]int, 0, len(book.Sheets))
	for i, s := range book.Sheets {
		if strings.EqualFold(strings.TrimSpace(s.Name), "inventory") {
			order = append([]int{i}, order...)
		} else {
			order = append(order, i)
		}
	}
	read := map[string]bool{} // each sheet part read once, however many sheets name it (review B, M3)
	for _, i := range order {
		tp := strings.ToLower(target[book.Sheets[i].RID])
		if read[tp] {
			continue
		}
		read[tp] = true
		sb, err := x.part(target[book.Sheets[i].RID])
		if err != nil {
			return nil, err
		}
		if sb == nil {
			continue
		}
		rows, err := xlsxRows(sb, sst, dates, d1904)
		if err != nil {
			return nil, fmt.Errorf("sheet %s: %v", book.Sheets[i].Name, err)
		}
		for h := 0; h < len(rows) && h < 20; h++ {
			if !isHeader(rows[h].cells) {
				continue
			}
			var recs [][]string
			var lines []int
			var whys []string
			for _, r := range rows[h+1:] {
				recs, lines, whys = append(recs, r.cells), append(lines, r.num), append(whys, r.why)
			}
			return fromRecords("xlsx", rows[h].cells, recs, lines, whys)
		}
	}
	return nil, errors.New("no sheet of the workbook has a header row naming instance and application (the inventory's sheet is named Inventory)")
}

func xlsxStrings(b []byte) ([]string, error) {
	d := xml.NewDecoder(bytes.NewReader(b))
	var out []string
	var cur strings.Builder
	in, inT, inPh := false, false, false
	for {
		tok, err := d.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("the shared strings could not be read: %v", err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			switch t.Name.Local {
			case "si":
				in = true
				cur.Reset()
			case "t":
				inT = in
			case "rPh":
				inPh = true // a phonetic run is not the cell's text
			}
		case xml.EndElement:
			switch t.Name.Local {
			case "si":
				in = false
				if len(out) >= xlsxMaxStrings {
					return nil, fmt.Errorf("over %d shared strings: not read", xlsxMaxStrings)
				}
				out = append(out, xlsxUnescape(cur.String()))
			case "t":
				inT = false
			case "rPh":
				inPh = false
			}
		case xml.CharData:
			if inT && !inPh {
				cur.Write(t)
			}
		}
	}
	return out, nil
}

type xlsxRow struct {
	num   int
	cells []string
	why   string
}

// colIndex: 'C7' -> 2; -1 when the reference holds no letters.
func colIndex(ref string) int {
	n := 0
	i := 0
	for ; i < len(ref) && ref[i] >= 'A' && ref[i] <= 'Z'; i++ {
		n = n*26 + int(ref[i]-'A'+1)
	}
	if i == 0 {
		return -1
	}
	return n - 1
}

func xlsxRows(b []byte, sst []string, dates map[int]bool, d1904 bool) ([]xlsxRow, error) {
	d := xml.NewDecoder(bytes.NewReader(b))
	var rows []xlsxRow
	var row *xlsxRow
	var ctype, cref string
	cstyle := -1
	var val, inl strings.Builder
	var inV, inIS, inT, hasF bool
	next := 0
	for {
		tok, err := d.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("the sheet could not be read: %v", err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			switch t.Name.Local {
			case "row":
				if len(rows) > importMaxRows+20 {
					return nil, fmt.Errorf("more than %d rows: at most %d lines in one file (split it)", importMaxRows, importMaxRows)
				}
				last := 0
				if len(rows) > 0 {
					last = rows[len(rows)-1].num
				}
				num := last + 1 // a row with no number is the next one
				for _, a := range t.Attr {
					if a.Name.Local == "r" {
						if n, err := strconv.Atoi(a.Value); err == nil {
							num = n
						}
					}
				}
				// a line is keyed by its number all the way to the planner: the rows go up (review A, M4)
				if num <= last {
					return nil, fmt.Errorf("row %d comes after row %d: a sheet's rows go up, each once (save the sheet again)", num, last)
				}
				rows = append(rows, xlsxRow{num: num})
				row, next = &rows[len(rows)-1], 0
			case "c":
				ctype, cref, hasF, cstyle = "", "", false, -1
				val.Reset()
				inl.Reset()
				for _, a := range t.Attr {
					switch a.Name.Local {
					case "t":
						ctype = a.Value
					case "r":
						cref = a.Value
					case "s":
						if n, err := strconv.Atoi(a.Value); err == nil {
							cstyle = n
						}
					}
				}
			case "v":
				inV = true
			case "is":
				inIS = true
			case "t":
				inT = inIS
			case "f":
				hasF = true
			}
		case xml.EndElement:
			switch t.Name.Local {
			case "v":
				inV = false
			case "is":
				inIS = false
			case "t":
				inT = false
			case "c":
				if row == nil {
					continue
				}
				i := colIndex(cref)
				if i < 0 {
					i = next
				}
				next = i + 1
				if i >= xlsxMaxCols { // the file has 14 columns: a cell far to the right is not read (review B, M2)
					continue
				}
				var s string
				switch ctype {
				case "s":
					k, err := strconv.Atoi(strings.TrimSpace(val.String()))
					if err != nil || k < 0 || k >= len(sst) {
						row.why = fmt.Sprintf("cell %s points at no shared string: this line is not read", cref)
					} else {
						s = sst[k]
					}
				case "inlineStr":
					s = xlsxUnescape(inl.String())
				case "b":
					s = map[string]string{"1": "yes", "0": "no"}[strings.TrimSpace(val.String())]
				case "e":
					row.why = fmt.Sprintf("cell %s holds an error value: this line is not read", cref)
				case "", "n":
					s = strings.TrimSpace(val.String())
					if dates[cstyle] && s != "" {
						s = xlsxSerialText(s, d1904) // a date cell (the house export writes a date-like text as one) reads as its date
					}
				default: // str, d
					s = xlsxUnescape(val.String())
				}
				if hasF {
					row.why = fmt.Sprintf("cell %s holds a formula: a file is read as values only, this line is not read", cref)
				}
				for len(row.cells) <= i {
					row.cells = append(row.cells, "")
				}
				row.cells[i] = s
			}
		case xml.CharData:
			if inV {
				val.Write(t)
			} else if inT {
				inl.Write(t)
			}
		}
	}
	return rows, nil
}

// ---- the routes ----

// appImportGate: the writes' door of 310 (appBody's checks) without its 64 KB JSON body.
func (s *Server) appImportGate(w http.ResponseWriter, r *http.Request) (string, bool) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return "", false
	}
	if why := s.applicationsOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return "", false
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return "", false
	}
	if why := s.appCanEdit(user); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return "", false
	}
	return user, true
}

// importOldStore is R14's words: a repository without 0146 answers in words, never with a SQL error.
const importOldStore = "the repository is older than this pgvigil (no inventory file functions, migration 0146): run 'pgvigil migrate' as the repository owner, then try again"

func (s *Server) hasImport(ctx context.Context) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.import_app_file(timestamp with time zone, jsonb)') IS NOT NULL
	   AND to_regprocedure('pgvigil.app_inventory()') IS NOT NULL`).Scan(&ok)
	return ok, err
}

// appBusy: a write that waited past the audit login's lock_timeout (55P03) for the applications' write lock - an import
// or a page write holding it - answered in words (review B, m3), here and in 310's appWrite
func appBusy(err error) error {
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "55P03" {
		return errors.New("the applications are being written now (an import, or a change on this page): nothing was written; try again when it has ended")
	}
	return nil
}

// importParamsBad: a NUL in the source, the digest or the ticks is refused in words, never sent to the store (review B,
// m5: jsonb refuses \u0000 with a SQL error)
func importParamsBad(q url.Values) error {
	for _, k := range []string{"source", "digest", "force"} {
		if strings.ContainsRune(q.Get(k), 0) {
			return fmt.Errorf("the request's %s holds a NUL character: refused", k)
		}
	}
	return nil
}

// AppImport is POST /api/admin/applications/import.
func (s *Server) AppImport(w http.ResponseWriter, r *http.Request) {
	// serve's WriteTimeout (75 s) would cut a long import's answer (t-im-g2 F13: curl 000 after 79 s): this route moves
	// its own write deadline past its work's, first of all (review B, m6: a deadline already passed is not moved); a
	// writer that cannot move it keeps the work inside the serve's 75 s
	budget := 130 * time.Second
	if err := http.NewResponseController(w).SetWriteDeadline(time.Now().Add(budget + 20*time.Second + importReadTime)); err != nil {
		budget = 70 * time.Second
	}
	user, ok := s.appImportGate(w, r)
	if !ok {
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, importBodyLimit+1))
	if err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("the file could not be read: %w", err))
		return
	}
	if len(raw) > importBodyLimit {
		writeErr(w, http.StatusRequestEntityTooLarge, fmt.Errorf("the file is over %d MB: split it", importBodyLimit>>20))
		return
	}
	f, err := parseInventory(raw)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx := r.Context()
	if have, err := s.hasImport(ctx); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	} else if !have {
		writeErr(w, http.StatusConflict, errors.New(importOldStore))
		return
	}
	q := r.URL.Query()
	if err := importParamsBad(q); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	force := []string{}
	for _, x := range strings.Split(q.Get("force"), ",") {
		if x = strings.TrimSpace(x); x != "" {
			force = append(force, x)
		}
	}
	pay := map[string]any{"ui_user": user, "client": clientIP(r), "source_name": q.Get("source"), "dry": q.Get("dry") != "0",
		"digest": q.Get("digest"), "force": force, "file_kind": f.Kind, "rows": f.Rows}
	b, _ := json.Marshal(pay)
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), budget)
	defer cancel()
	ans, err := s.importCall(wctx, b)
	if err != nil {
		var pe *pgconn.PgError
		switch {
		case errors.As(err, &pe) && pe.Code == "40P01":
			writeErr(w, http.StatusConflict, errors.New("the import met a deadlock with another write (the collector's database read) and was rolled back: nothing was written; import again"))
		case errors.As(err, &pe) && pe.Code == "57014":
			writeErr(w, http.StatusConflict, fmt.Errorf("the import took longer than %s and was rolled back: nothing was written; split the file", importTimeout))
		case errors.As(err, &pe) && pe.Code == "P0001":
			writeErr(w, http.StatusConflict, errors.New(pe.Message))
		case appBusy(err) != nil:
			writeErr(w, http.StatusConflict, appBusy(err))
		default:
			writeErr(w, http.StatusInternalServerError, err)
		}
		return
	}
	var out map[string]any
	if err := json.Unmarshal(ans, &out); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_app_file answered %q", ans))
		return
	}
	unread := f.Unread
	if unread == nil {
		unread = []string{}
	}
	out["file"] = map[string]any{"kind": f.Kind, "lines": len(f.Rows), "columns_not_read": unread}
	code := http.StatusOK
	if out["outcome"] == "refused" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(out)
}

// importCall runs the planner in a transaction of its own on the audit login, with its own statement timeout.
func (s *Server) importCall(ctx context.Context, payload []byte) ([]byte, error) {
	tx, err := s.actions.audit.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if _, err := tx.Exec(ctx, `SET LOCAL statement_timeout = '`+importTimeout+`'`); err != nil {
		return nil, err
	}
	var out []byte
	if err := tx.QueryRow(ctx, `SELECT pgvigil.import_app_file($1, $2::jsonb)::text`, time.Now(), string(payload)).Scan(&out); err != nil {
		return nil, err
	}
	return out, tx.Commit(ctx)
}

const sqlInventory = `SELECT level, instance, engine, database, application, environment, tier, description, cmdb_url,
       not_an_application, inherited_from, absent_since, source, set_at FROM pgvigil.app_inventory()`

// AppInventory is GET /api/applications/inventory: the round trip's rows as a grid.
func (s *Server) AppInventory(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if have, err := s.hasImport(ctx); err != nil {
		writeErr(w, http.StatusInternalServerError, err) // a store that cannot be read is no 409 (review B, m9)
		return
	} else if !have {
		writeErr(w, http.StatusConflict, errors.New(importOldStore))
		return
	}
	t, err := s.query(ctx, sqlInventory)
	s.reply(w, r, t, err)
}

// AppInventoryCSV is GET /api/applications/inventory.csv: the same rows as CSV (UTF-8 with BOM, LF line ends, every
// cell that starts with = + - @ TAB CR written with one more ' - undone by the import).
func (s *Server) AppInventoryCSV(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if have, err := s.hasImport(ctx); err != nil {
		writeErr(w, http.StatusInternalServerError, err) // a store that cannot be read is no 409 (review B, m9)
		return
	} else if !have {
		writeErr(w, http.StatusConflict, errors.New(importOldStore))
		return
	}
	t, err := s.query(ctx, sqlInventory)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="pgvigil-inventory-%s.csv"`, time.Now().UTC().Format("20060102-1504")))
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if err := writeInventoryCSV(w, t); err != nil {
		s.log.Warn("inventory csv write failed", "err", err)
	}
}

func cellText(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case time.Time:
		return x.UTC().Format("2006-01-02 15:04:05Z")
	case *time.Time:
		if x == nil {
			return ""
		}
		return x.UTC().Format("2006-01-02 15:04:05Z")
	}
	return fmt.Sprint(v)
}

func writeInventoryCSV(w io.Writer, t *table) error {
	if _, err := io.WriteString(w, "\ufeff"); err != nil {
		return err
	}
	// LF line ends: encoding/csv's UseCRLF drops every CR inside a quoted field (review B, m1), so a CR in a cell would not
	// come back; Excel and the import read LF files
	cw := csv.NewWriter(w)
	if err := cw.Write(t.Columns); err != nil {
		return err
	}
	for _, row := range t.Rows {
		rec := make([]string, len(row))
		for i, v := range row {
			rec[i] = guardCell(cellText(v))
		}
		if err := cw.Write(rec); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// xlsxDateStyles: the cell style indexes (cellXfs) whose number format is a date or a time - Excel's built-in ids and a
// custom format with a day, a year, an hour or seconds in it (quoted text, [colour] and escaped characters set aside).
func xlsxDateStyles(b []byte) map[int]bool {
	var st struct {
		NumFmts []struct {
			ID   int    `xml:"numFmtId,attr"`
			Code string `xml:"formatCode,attr"`
		} `xml:"numFmts>numFmt"`
		Xfs []struct {
			ID int `xml:"numFmtId,attr"`
		} `xml:"cellXfs>xf"`
	}
	out := map[int]bool{}
	if xml.Unmarshal(b, &st) != nil {
		return out
	}
	custom := map[int]bool{}
	strip := regexp.MustCompile(`"[^"]*"|\[[^\]]*\]|\\.`)
	for _, f := range st.NumFmts {
		c := strings.ToLower(strip.ReplaceAllString(f.Code, ""))
		custom[f.ID] = strings.ContainsAny(c, "ydh") || strings.Contains(c, "ss")
	}
	for i, x := range st.Xfs {
		id := x.ID
		out[i] = (id >= 14 && id <= 22) || (id >= 45 && id <= 47) || (id >= 27 && id <= 36) || (id >= 50 && id <= 58) || custom[id]
	}
	return out
}

// xlsxSerialText: an Excel serial day (the 1900 system, day 0 = 1899-12-30; a 1904 workbook's day 0 = 1904-01-01) as
// yyyy-MM-dd, with the time when it has one; a serial under 1 is a time alone, HH:MM:SS (review B, m7).
func xlsxSerialText(v string, d1904 bool) string {
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return v
	}
	if f >= 0 && f < 1 {
		return time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC).Add(time.Duration(f*86400*1000+0.5) * time.Millisecond).Truncate(time.Second).Format("15:04:05")
	}
	day0 := time.Date(1899, 12, 30, 0, 0, 0, 0, time.UTC)
	if d1904 {
		day0 = time.Date(1904, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	t := day0.Add(time.Duration(f*86400*1000+0.5) * time.Millisecond).Truncate(time.Second)
	if t.Hour() == 0 && t.Minute() == 0 && t.Second() == 0 {
		return t.Format("2006-01-02")
	}
	return t.Format("2006-01-02 15:04:05")
}
