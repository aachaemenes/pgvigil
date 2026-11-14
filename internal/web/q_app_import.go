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
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

const (
	importBodyLimit = 5 << 20  // the file
	importMaxRows   = 20000    // its lines
	xlsxPartLimit   = 64 << 20 // one decompressed part of an .xlsx
	xlsxMaxEntries  = 4000     // the parts of an .xlsx
	xlsxMaxStrings  = 400000   // its shared strings
	importTimeout   = "120s"   // the planner's own statement timeout (the audit pool's is 5 s)
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
	for i, h := range header {
		c := normCol(h)
		cols[i] = c
		known := slicesContains(invColumns, c)
		if (!known || c == "") && strings.TrimSpace(h) != "" && !seen[c] {
			seen[c] = true
			f.Unread = append(f.Unread, strings.TrimSpace(h))
		}
		if known && invExportOnly[c] {
			cols[i] = "" // read back and ignored
		}
	}
	for n, rec := range recs {
		empty := true
		for _, c := range rec {
			if strings.TrimSpace(c) != "" {
				empty = false
				break
			}
		}
		if empty {
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
	var hdr string
	for i, l := range strings.SplitN(text, "\n", 40) {
		if i == 39 {
			break
		}
		lo := strings.ToLower(l)
		if strings.Contains(lo, "instance") && strings.Contains(lo, "application") {
			hdr = l
			break
		}
	}
	if hdr == "" {
		return nil, errors.New("no header line naming instance and application in the file's first lines")
	}
	commas, semis, tabs := strings.Count(hdr, ","), strings.Count(hdr, ";"), strings.Count(hdr, "\t")
	if tabs > commas && tabs > semis {
		return nil, errors.New("a tab-separated file is not read: save it as CSV UTF-8 (commas or semicolons)")
	}
	cr := csv.NewReader(strings.NewReader(text))
	cr.Comma = ','
	if semis > commas {
		cr.Comma = ';'
	}
	cr.LazyQuotes, cr.FieldsPerRecord = true, -1
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
		for _, r := range rs {
			arr, _ := r.([]any)
			rec, why := make([]string, len(arr)), ""
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
		idx := map[string]int{}
		for _, r := range d {
			obj, _ := r.(map[string]any)
			keys := make([]string, 0, len(obj))
			for k := range obj {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				if _, ok := idx[k]; !ok {
					idx[k] = len(header)
					header = append(header, k)
				}
			}
		}
		for _, r := range d {
			obj, _ := r.(map[string]any)
			rec, why := make([]string, len(header)), ""
			if obj == nil {
				why = "a line is not an object: not read"
			}
			for k, x := range obj {
				s, ok := cell(x)
				if !ok {
					why = "a cell is not a single value: this line is not read"
				}
				rec[idx[k]] = s
			}
			recs, whys = append(recs, rec), append(whys, why)
		}
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
	zr *zip.Reader
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
		Sheets []struct {
			Name string `xml:"name,attr"`
			RID  string `xml:"http://schemas.openxmlformats.org/officeDocument/2006/relationships id,attr"`
		} `xml:"sheets>sheet"`
	}
	if err := xml.Unmarshal(wb, &book); err != nil {
		return nil, fmt.Errorf("xl/workbook.xml could not be read: %v", err)
	}
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
	// the sheet named Inventory, else the first whose header (in its first 20 rows) names instance and application
	order := make([]int, 0, len(book.Sheets))
	for i, s := range book.Sheets {
		if strings.EqualFold(strings.TrimSpace(s.Name), "inventory") {
			order = append([]int{i}, order...)
		} else {
			order = append(order, i)
		}
	}
	for _, i := range order {
		sb, err := x.part(target[book.Sheets[i].RID])
		if err != nil {
			return nil, err
		}
		if sb == nil {
			continue
		}
		rows, err := xlsxRows(sb, sst)
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

func xlsxRows(b []byte, sst []string) ([]xlsxRow, error) {
	d := xml.NewDecoder(bytes.NewReader(b))
	var rows []xlsxRow
	var row *xlsxRow
	var ctype, cref string
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
				num := len(rows) + 1
				for _, a := range t.Attr {
					if a.Name.Local == "r" {
						if n, err := strconv.Atoi(a.Value); err == nil {
							num = n
						}
					}
				}
				rows = append(rows, xlsxRow{num: num})
				row, next = &rows[len(rows)-1], 0
			case "c":
				ctype, cref, hasF = "", "", false
				val.Reset()
				inl.Reset()
				for _, a := range t.Attr {
					switch a.Name.Local {
					case "t":
						ctype = a.Value
					case "r":
						cref = a.Value
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
				if i > 16383 {
					continue
				}
				next = i + 1
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
				default: // n, str, d
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

// AppImport is POST /api/admin/applications/import.
func (s *Server) AppImport(w http.ResponseWriter, r *http.Request) {
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
	force := []string{}
	for _, x := range strings.Split(q.Get("force"), ",") {
		if x = strings.TrimSpace(x); x != "" {
			force = append(force, x)
		}
	}
	pay := map[string]any{"ui_user": user, "client": clientIP(r), "source_name": q.Get("source"), "dry": q.Get("dry") != "0",
		"digest": q.Get("digest"), "force": force, "file_kind": f.Kind, "rows": f.Rows}
	b, _ := json.Marshal(pay)
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 130*time.Second)
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
	if have, err := s.hasImport(ctx); err != nil || !have {
		if err == nil {
			err = errors.New(importOldStore)
		}
		writeErr(w, http.StatusConflict, err)
		return
	}
	t, err := s.query(ctx, sqlInventory)
	s.reply(w, r, t, err)
}

// AppInventoryCSV is GET /api/applications/inventory.csv: the same rows as CSV (UTF-8 with BOM, CRLF, every cell that
// starts with = + - @ TAB CR written with one more ' - undone by the import).
func (s *Server) AppInventoryCSV(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	if have, err := s.hasImport(ctx); err != nil || !have {
		if err == nil {
			err = errors.New(importOldStore)
		}
		writeErr(w, http.StatusConflict, err)
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
	cw := csv.NewWriter(w)
	cw.UseCRLF = true
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
