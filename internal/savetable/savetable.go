// Package savetable holds the checks of Save Table's write door (task 7b): the identifiers, the one quoted form of
// the target, the system targets a table is never written into, the column kinds with their conversions, the body's
// limits and the gates from the instance's door on. The route (internal/web/savetable.go) holds the HTTP side, the
// connections and the writes; everything here runs without a server, so each gate has its unit row.
package savetable

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf16"

	"github.com/aachaemenes/pgvigil/internal/mssqlread"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// The two engines, as pgvigil.instances.engine names them.
const (
	Postgres  = "postgres"
	SQLServer = "sqlserver"
)

// Schema is the one schema a table is written into, fixed: the door login's own (review-29 B2; the lead 11-17 02:17).
const Schema = "pgvigil_saved"

// Target is one table to create: the database, the schema and the table, each checked by CheckName first.
type Target struct {
	Database, Schema, Table string
}

// Display is the target as the words name it (unquoted, dotted).
func (t Target) Display() string { return t.Database + "." + t.Schema + "." + t.Table }

// CheckName refuses an identifier with words naming the field and the reason; nil = it is quoted, never refused for
// its characters. A control character, an invisible character (invisibleRune) and the line and paragraph separators
// are refused: they would make the audit's name read as another (review-29 N2). PostgreSQL counts 63 bytes in UTF-8,
// SQL Server 128 UTF-16 code units (review-29 N1); a SQL Server name ending in a space is refused (SQL Server drops a
// delimited name's trailing spaces, so the bulk copy's column match would fail: review-31 NIT 8).
func CheckName(engine, field, name string) error {
	if name == "" {
		return fmt.Errorf("%s: the name is empty", field)
	}
	for _, r := range name {
		switch {
		case unicode.Is(unicode.Cc, r):
			return fmt.Errorf("%s: the name holds a control character (U+%04X)", field, r)
		case invisibleRune(r):
			return fmt.Errorf("%s: the name holds an invisible character (U+%04X): it would read as another name", field, r)
		}
	}
	if engine == SQLServer && strings.HasSuffix(name, " ") {
		return fmt.Errorf("%s: the name ends with a space: SQL Server drops a name's trailing spaces", field)
	}
	switch engine {
	case Postgres:
		if n := len(name); n > 63 {
			return fmt.Errorf("%s: the name is %d bytes: PostgreSQL allows 63", field, n)
		}
	case SQLServer:
		if n := len(utf16.Encode([]rune(name))); n > 128 {
			return fmt.Errorf("%s: the name is %d UTF-16 units: SQL Server allows 128", field, n)
		}
		if field == "table" && strings.HasPrefix(name, "#") {
			return errors.New("table: a name starting with # is a temporary table in tempdb that vanishes when the connection closes")
		}
	default:
		return fmt.Errorf("%s: unknown engine %q", field, engine)
	}
	return nil
}

// invisibleRune says whether r draws nothing or reads as a space it is not: a format character (zero-width spaces,
// direction overrides, the byte-order mark), the line and paragraph separators, a space other than U+0020, private
// use, the combining grapheme joiner, the variation selectors, the Hangul fillers and the braille blank (review-31
// NIT 9).
func invisibleRune(r rune) bool {
	switch {
	case unicode.Is(unicode.Cf, r), unicode.Is(unicode.Co, r), r == ' ', r == ' ':
		return true
	case unicode.Is(unicode.Zs, r) && r != ' ':
		return true
	case r == '͏', r >= '︀' && r <= '️', r >= '\U000e0100' && r <= '\U000e01ef':
		return true
	case r == 'ᅟ', r == 'ᅠ', r == 'ㅤ', r == 'ﾠ', r == '⠀':
		return true
	}
	return false
}

// pgSystemColumns are PostgreSQL's system column names: a table's own column cannot take one (42701).
var pgSystemColumns = map[string]bool{"xmin": true, "xmax": true, "cmin": true, "cmax": true, "ctid": true, "tableoid": true}

// CheckColumns refuses an empty column list, a repeated name (case-insensitively on SQL Server), a PostgreSQL system
// column's name (review-31 NIT 10) and any name CheckName refuses.
func CheckColumns(engine string, names []string) error {
	if len(names) == 0 {
		return errors.New("the grid has no column to write")
	}
	seen := map[string]int{}
	for i, n := range names {
		field := fmt.Sprintf("column %d", i+1)
		if err := CheckName(engine, field, n); err != nil {
			return err
		}
		if engine == Postgres && pgSystemColumns[n] {
			return fmt.Errorf("%s: %q is a PostgreSQL system column name: a table's own column cannot take it", field, n)
		}
		k := n
		if engine == SQLServer {
			k = strings.ToLower(n)
		}
		if j, ok := seen[k]; ok {
			return fmt.Errorf("%s: %q names column %d twice (SQL Server's names are case-insensitive)", field, n, j)
		}
		seen[k] = i + 1
	}
	return nil
}

// QuoteIdent quotes one name: PostgreSQL in double quotes with '"' doubled (pgx's Identifier, quote_ident's rule),
// SQL Server in brackets with ']' doubled (QUOTENAME's rule, mssqlread.QuoteName).
func QuoteIdent(engine, name string) string {
	if engine == SQLServer {
		return mssqlread.QuoteName(name)
	}
	return pgx.Identifier{name}.Sanitize()
}

// Quoted is the ONE quoted form of the target, used everywhere - the CREATE, the bulk copy and the existence read
// (bound, never spliced): PostgreSQL "schema"."table" (the connection names the database; pgx's CopyFrom takes the
// same pgx.Identifier), SQL Server [database].[schema].[table] (go-mssqldb's CopyIn splits it only outside brackets).
func Quoted(engine string, t Target) string {
	if engine == SQLServer {
		return QuoteIdent(engine, t.Database) + "." + QuoteIdent(engine, t.Schema) + "." + QuoteIdent(engine, t.Table)
	}
	return pgx.Identifier{t.Schema, t.Table}.Sanitize()
}

// Database is what the monitoring read knows of one database.
type Database struct {
	Name          string
	ID            int  // SQL Server database_id
	IsTemplate    bool // PostgreSQL datistemplate
	IsDistributor bool // SQL Server is_distributor
}

// RefuseDatabase is the words that refuse a system or template database as a target, or "" when it may take a table
// (review-29 S2: model and template1 copy a table into every database made later).
func RefuseDatabase(engine string, d Database) string {
	switch engine {
	case SQLServer:
		if d.ID >= 1 && d.ID <= 4 {
			return fmt.Sprintf("the database %s is a system database: pgvigil never writes a table there", d.Name)
		}
		for _, s := range []string{"master", "tempdb", "model", "msdb"} {
			if strings.EqualFold(d.Name, s) {
				return fmt.Sprintf("the database %s is a system database: pgvigil never writes a table there", d.Name)
			}
		}
		if d.IsDistributor {
			return fmt.Sprintf("the database %s is a replication distribution database: pgvigil never writes a table there", d.Name)
		}
		if strings.EqualFold(d.Name, "rdsadmin") {
			return fmt.Sprintf("the database %s is Amazon RDS's own: pgvigil never writes a table there", d.Name)
		}
	case Postgres:
		if d.IsTemplate || d.Name == "template0" || d.Name == "template1" {
			return fmt.Sprintf("the database %s is a template: every database made from it later would copy the table", d.Name)
		}
		switch d.Name {
		case "cloudsqladmin", "rdsadmin", "azure_maintenance", "azure_sys":
			return fmt.Sprintf("the database %s is the cloud provider's own: pgvigil never writes a table there", d.Name)
		}
	}
	return ""
}

// kinds: the browser's closed list (gridwriters.ts sqlType's choices, 'day' among them: review-29 N3) and each
// engine's type for it.
var kinds = map[string][2]string{
	"int":  {"bigint", "BIGINT"},
	"dec":  {"numeric", "DECIMAL(38,10)"},
	"time": {"timestamptz", "DATETIMEOFFSET"},
	"day":  {"date", "DATE"},
	"text": {"text", "NVARCHAR(MAX)"},
	"bool": {"boolean", "BIT"},
}

// ColumnType is the engine's type for one of the browser's closed list of kinds (int, dec, time, day, text, bool).
func ColumnType(engine, kind string) (string, error) {
	t, ok := kinds[kind]
	if !ok {
		return "", fmt.Errorf("the kind %q is not one of int, dec, time, day, text, bool", kind)
	}
	if engine == SQLServer {
		return t[1], nil
	}
	return t[0], nil
}

// A dec cell's bounds before any arithmetic: its text's length and its exponent (review-31 S2).
const (
	maxDecText = 64
	maxDecExp  = 1000
)

// decimalText is a JSON number's exact decimal text (an exponent written out) and its count of decimal places.
func decimalText(s string) (string, int, bool) {
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return "", 0, false
	}
	places, ten := 0, big.NewRat(10, 1)
	for x := new(big.Rat).Set(r); !x.IsInt(); x.Mul(x, ten) {
		if places++; places > 1000 {
			return "", 0, false
		}
	}
	return r.FloatString(places), places, true
}

// Convert turns one decoded JSON cell (a json.Number, a string, a bool or nil) into the value the driver binds for
// kind. Its error names the row and the column, never the value (any logged-in user reads the audit: review-29 S3).
// A NUL in a text is dropped (one rule for both engines: PostgreSQL's text cannot hold one), as the export does.
func Convert(engine, kind string, row int, column string, v any) (any, error) {
	bad := func(why string) error {
		return fmt.Errorf("row %d, column %s: %s; nothing was written", row, column, why)
	}
	if v == nil {
		return nil, nil
	}
	switch kind {
	case "int":
		n, ok := v.(json.Number)
		if !ok {
			return nil, bad("the value is not a whole number")
		}
		i, err := strconv.ParseInt(string(n), 10, 64)
		if err != nil {
			return nil, bad("the value is not a whole number within bigint")
		}
		return i, nil
	case "dec":
		n, ok := v.(json.Number)
		if !ok {
			return nil, bad("the value is not a number")
		}
		// bounded before any arithmetic (review-31 S2: big.Rat takes an exponent up to 1e6 and writes every digit):
		// a browser's number is at most 24 characters
		if len(n) > maxDecText {
			return nil, bad(fmt.Sprintf("the number is over %d characters", maxDecText))
		}
		if e := strings.IndexAny(string(n), "eE"); e >= 0 {
			if x, err := strconv.Atoi(string(n[e+1:])); err != nil || x > maxDecExp || x < -maxDecExp {
				return nil, bad(fmt.Sprintf("the number's exponent is beyond %d", maxDecExp))
			}
		}
		text, places, ok := decimalText(string(n))
		if !ok {
			return nil, bad("the value is not a number")
		}
		if engine == SQLServer {
			// DECIMAL(38,10): 10 places and 28 digits before the point - more is refused, never rounded (review-29 N5)
			if places > 10 {
				return nil, bad("the number has more than 10 decimal places (DECIMAL(38,10) would round it)")
			}
			if whole := strings.TrimLeft(strings.SplitN(strings.TrimPrefix(text, "-"), ".", 2)[0], "0"); len(whole) > 28 {
				return nil, bad("the number has more than 28 digits before the point (DECIMAL(38,10))")
			}
			return text, nil // go-mssqldb's bulk copy takes a DECIMAL as its text
		}
		var num pgtype.Numeric
		if err := num.Scan(text); err != nil {
			return nil, bad("the value is not a number")
		}
		return num, nil
	case "time":
		s, ok := v.(string)
		if !ok {
			return nil, bad("the value is not a time")
		}
		t, err := time.Parse(time.RFC3339Nano, s)
		if err != nil {
			return nil, bad("the value is not a time with its offset (RFC 3339)")
		}
		// DATETIMEOFFSET starts at 0001-01-01 UTC; go-mssqldb would wrap an earlier day count (review-31 S7)
		if engine == SQLServer && t.UTC().Year() < 1 {
			return nil, bad("the time is before 0001-01-01 UTC, SQL Server's first day")
		}
		// microseconds on both engines: PostgreSQL's timestamptz holds no more, so one grid's two tables hold one value
		// (review-31 NIT 11)
		return t.Truncate(time.Microsecond), nil
	case "day":
		s, ok := v.(string)
		if !ok {
			return nil, bad("the value is not a date")
		}
		t, err := time.Parse("2006-01-02", s)
		if err != nil {
			return nil, bad("the value is not a date (YYYY-MM-DD)")
		}
		if engine == SQLServer && t.Year() < 1 {
			return nil, bad("the date is before 0001-01-01, SQL Server's first day")
		}
		return t, nil
	case "text":
		switch x := v.(type) {
		case string:
			return strings.ReplaceAll(x, "\x00", ""), nil
		case json.Number:
			return string(x), nil // a text column's number, written as its text (gridwriters.ts sqlScript)
		}
		return nil, bad("the value is not text")
	case "bool":
		if b, ok := v.(bool); ok {
			return b, nil
		}
		return nil, bad("the value is not true or false")
	}
	return nil, bad(fmt.Sprintf("the kind %q is not one of int, dec, time, day, text, bool", kind))
}

// NULs counts the NUL characters Convert drops from a text cell (the answer and the audit say how many).
func NULs(v any) int {
	if s, ok := v.(string); ok {
		return strings.Count(s, "\x00")
	}
	return 0
}

// The off words, the first switch that is off first (the lead 11-17 02:17).
const (
	OffSwitch = "off: an administrator turns on doors: save_table in pgvigil.yaml"
	OffList   = "off: this instance's actions: list does not name save_table"
	OffNoDSN  = "off: this instance has no actions_dsn"
	OffSchema = "off: the door login has no schema pgvigil_saved (docs/export.md has the two lines that make it)"
)

// Instance is what serve knows of the target from its config, before any connection.
type Instance struct {
	Name, Engine string
	Page         bool // added in Admin > Instances: a page door never acts
	Allowed      bool // its actions: list names save_table
	Configured   bool // actions_dsn is set in the config
	Resolved     bool // and resolved to a login (an unset variable or an unreadable file leaves it empty)
}

// OffWords is why Save Table is off on the instance, or "" when the config lets it on (the schema is read at Save).
func OffWords(on bool, in Instance) string {
	switch {
	case !on:
		return OffSwitch
	case in.Page:
		// internal/actions' PageOff in words of their own (that package builds on this one)
		return fmt.Sprintf("off: instance %s was added in Admin > Instances: actions run only on an instance of pgvigil.yaml (dsn, actions_dsn, actions:)", in.Name)
	case !in.Allowed:
		return OffList
	case !in.Configured:
		return OffNoDSN
	case !in.Resolved:
		return fmt.Sprintf("off: instance %s's actions_dsn has not resolved (an unset variable or an unreadable file)", in.Name)
	}
	return ""
}

// Confirm is the text the user types to save: the target's instance and database (review-29 S7: a confirmation names
// the target, never the user's own new text).
func Confirm(instance, database string) string { return instance + "/" + database }

// Col is one column of the body: its name and its kind from the closed list.
type Col struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// Body is POST /api/actions/save_table's request.
type Body struct {
	InstanceID int     `json:"instance_id"`
	Database   string  `json:"database"`
	Table      string  `json:"table"`
	From       string  `json:"from"` // "data" | "grid"
	Confirm    string  `json:"confirm"`
	Cols       []Col   `json:"cols"`
	Rows       [][]any `json:"rows"`
}

// Limits bound one body while it is decoded (review-29 S5).
type Limits struct{ Rows, Cells int }

// DefaultLimits: 100,000 rows and 2,000,000 cells.
var DefaultLimits = Limits{Rows: 100000, Cells: 2000000}

// MaxCols is each engine's column cap.
func MaxCols(engine string) int {
	if engine == SQLServer {
		return 1024
	}
	return 1600
}

// Decode reads a body with UseNumber, refusing - before the rest is read - more rows or cells than lim allows, more
// columns than the engine allows (SQL Server 1,024, PostgreSQL 1,600) or a row whose length is not the columns'. The
// columns come before the rows (the page sends them so); an unknown field, a field given twice, a column with a
// field of its own and a cell that is a list or an object are refused. The columns are read one at a time and each
// row value by value, counted as it streams, so a refused body is never held whole (review-31 S1, S3).
func Decode(r io.Reader, engine string, lim Limits) (Body, error) {
	var b Body
	bad := func(err error) (Body, error) { return Body{}, fmt.Errorf("body: %w", err) }
	dec := json.NewDecoder(r)
	dec.UseNumber()
	dec.DisallowUnknownFields()
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return bad(errors.New("not a JSON object"))
	}
	cells, haveCols, seen := 0, false, map[string]bool{}
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return bad(err)
		}
		key, _ := t.(string)
		if seen[key] {
			return bad(fmt.Errorf("the field %q is given twice", key))
		}
		seen[key] = true
		switch key {
		case "instance_id":
			err = dec.Decode(&b.InstanceID)
		case "database":
			err = dec.Decode(&b.Database)
		case "table":
			err = dec.Decode(&b.Table)
		case "from":
			err = dec.Decode(&b.From)
		case "confirm":
			err = dec.Decode(&b.Confirm)
		case "cols":
			if t, err := dec.Token(); err != nil || t != json.Delim('[') {
				return bad(errors.New("cols is not a list"))
			}
			b.Cols = []Col{}
			for dec.More() {
				if len(b.Cols) >= MaxCols(engine) {
					name := "PostgreSQL"
					if engine == SQLServer {
						name = "SQL Server"
					}
					return bad(fmt.Errorf("over %d columns: %s allows %d", MaxCols(engine), name, MaxCols(engine)))
				}
				var c Col
				if err := dec.Decode(&c); err != nil {
					return bad(fmt.Errorf("column %d: %w", len(b.Cols)+1, err))
				}
				b.Cols = append(b.Cols, c)
			}
			_, err = dec.Token() // the columns' closing bracket
			haveCols = true
		case "rows":
			if !haveCols {
				return bad(errors.New("the columns must come before the rows"))
			}
			if t, err := dec.Token(); err != nil || t != json.Delim('[') {
				return bad(errors.New("rows is not a list"))
			}
			b.Rows = [][]any{}
			for dec.More() {
				if len(b.Rows) >= lim.Rows {
					return bad(fmt.Errorf("the grid is over %d rows: Script Data Table writes it as a file", lim.Rows))
				}
				row, err := decodeRow(dec, len(b.Rows)+1, len(b.Cols), &cells, lim.Cells)
				if err != nil {
					return bad(err)
				}
				b.Rows = append(b.Rows, row)
			}
			_, err = dec.Token() // the rows' closing bracket
		default:
			return bad(fmt.Errorf("an unknown field %q", key))
		}
		if err != nil {
			return bad(err)
		}
	}
	if _, err := dec.Token(); err != nil {
		return bad(err)
	}
	return b, nil
}

// decodeRow reads row n value by value: a value past ncols, a cell past the cells limit, or a cell that is a list or
// an object is refused at once (review-31 S3); a row shorter than the columns is refused at its end.
func decodeRow(dec *json.Decoder, n, ncols int, cells *int, maxCells int) ([]any, error) {
	if t, err := dec.Token(); err != nil || t != json.Delim('[') {
		return nil, fmt.Errorf("row %d is not a list", n)
	}
	row := make([]any, 0, ncols)
	for dec.More() {
		if len(row) >= ncols {
			return nil, fmt.Errorf("row %d holds more values than its %d columns", n, ncols)
		}
		if *cells++; *cells > maxCells {
			return nil, fmt.Errorf("the grid is over %d cells: Script Data Table writes it as a file", maxCells)
		}
		t, err := dec.Token()
		if err != nil {
			return nil, fmt.Errorf("row %d: %w", n, err)
		}
		if _, isDelim := t.(json.Delim); isDelim {
			return nil, fmt.Errorf("row %d, column %d: the value is a list or an object", n, len(row)+1)
		}
		row = append(row, t)
	}
	if _, err := dec.Token(); err != nil { // the row's closing bracket
		return nil, fmt.Errorf("row %d: %w", n, err)
	}
	if len(row) != ncols {
		return nil, fmt.Errorf("row %d holds %d values for %d columns", n, len(row), ncols)
	}
	return row, nil
}

// Conn is one login's connection on the chosen database: the monitoring login's, or the writing (actions) login's
// save-only connection (review-29 S9).
type Conn interface {
	// Server names the server the login reached (PostgreSQL pg_postmaster_start_time(); SQL Server @@SERVERNAME and
	// tempdb's create_date): two logins on one server read the same text
	Server(ctx context.Context) (string, error)
	// Login is the login's name and whether it is a superuser (PostgreSQL) or sysadmin / CONTROL SERVER (SQL Server)
	Login(ctx context.Context) (name string, super bool, err error)
	// Schema says whether pgvigil_saved exists in the database and whether this login owns it
	Schema(ctx context.Context) (exists, owned bool, err error)
	// Exists reads whether the target exists, the quoted form bound as a parameter (review-29 S1)
	Exists(ctx context.Context, quoted string) (bool, error)
	// Place reads where this connection is, as the server has it at the save (review-31 part A2)
	Place(ctx context.Context) (Place, error)
}

// Place is what a connection reads of the database it is in, at the save: Check asks the WRITING connection, so the
// answer is the server's own and not the store's last read (review-31 part A2 SF4, part A1 S4).
type Place struct {
	DB    Database // SQL Server: database_id and is_distributor; PostgreSQL: datistemplate (the name is the caller's)
	Owner bool     // SQL Server: the login is the database's owner (dbo) or a member of db_owner there
}

// Writer is the writing login's connection: the checks, then the write. On SQL Server the write runs as the login's own
// DATABASE USER (EXECUTE AS USER ... WITH NO REVERT, on a connection closed after the save): SQL Server runs a
// database's DDL trigger as the caller, and inside that switch the caller has its rights in this database and none of
// the login's on the server (review-31 part A2 SF1: a db_owner's trigger on CREATE_TABLE would otherwise run with the
// right to end sessions). PostgreSQL has no twin: only a superuser can create an event trigger. The write is CREATE TABLE (no IF NOT EXISTS: an 'already
// exists' error is the refusal, Exists') and the engine's bulk copy of the converted rows in ONE transaction, rolled
// back on any error (no half table). It answers the rows written.
type Writer interface {
	Conn
	Write(ctx context.Context, t Target, cols []Col, rows [][]any) (int64, error)
}

// ErrExists is what a Writer answers when the engine says 'already exists' (PostgreSQL 42P07, and 42710 for a
// same-named type; SQL Server Msg 2714): the race the existence read cannot close, refused in the same words
// (review-29 N4).
var ErrExists = errors.New("the table exists")

// ErrCommitUnknown is what a Writer wraps an error of the COMMIT itself in when the server did not answer it (the
// connection was cut, the deadline passed): the server may have committed (review-31 part A2 NIT 8).
var ErrCommitUnknown = errors.New("the commit's outcome is unknown")

// RefusedName stands in the audit row and the log for a name CheckName refused (review-31 part A2 SF3).
const RefusedName = "(a refused name)"

// AuditNames is the database and the target as the audit row and the log carry them: a name only once CheckName
// passed it, RefusedName otherwise - a NUL would fail the row's jsonb (no audit row at all), an invisible character
// would read as another name, an unbounded one would be written three times (review-31 part A2 SF3, part A1 S6).
func AuditNames(engine string, b Body) (datname, target string) {
	datname, target = RefusedName, RefusedName
	if CheckName(engine, "database", b.Database) != nil {
		return datname, target
	}
	datname = b.Database
	if CheckName(engine, "table", b.Table) == nil {
		target = Target{Database: b.Database, Schema: Schema, Table: b.Table}.Display()
	}
	return datname, target
}

// WriteWords is the end row's outcome, its words and the rows written, from what Write answered. An error of the
// commit itself (ErrCommitUnknown) never says 'nothing was kept': the server may have committed before the connection
// was cut, and the next attempt would then be refused as 'exists' (review-31 part A2 NIT 8).
func WriteWords(t Target, n int64, nuls int, err error) (outcome, detail string, rows int64) {
	outcome, detail = "done", fmt.Sprintf("Saved %d rows to %s", n, t.Display())
	switch {
	case errors.Is(err, ErrExists):
		return "refused", fmt.Sprintf("the table %s exists: pgvigil never overwrites a table", t.Display()), 0
	case errors.Is(err, ErrCommitUnknown):
		return "failed", fmt.Sprintf("the save of %s did not end cleanly - %v: the server may have kept the table; look for it before saving again", t.Display(), err), 0
	case err != nil:
		return "failed", fmt.Sprintf("the save of %s failed, nothing was kept (the transaction rolled back): %v", t.Display(), err), 0
	case nuls > 0:
		detail += fmt.Sprintf("; %d NUL character(s) dropped from text cells", nuls)
	}
	return outcome, detail, n
}

// CreateSQL is the CREATE TABLE of the target: every identifier quoted by QuoteIdent, every type from ColumnType's
// closed list; no value of the grid is ever in it.
func CreateSQL(engine string, t Target, cols []Col) (string, error) {
	var b strings.Builder
	b.WriteString("CREATE TABLE " + Quoted(engine, t) + " (")
	for i, c := range cols {
		typ, err := ColumnType(engine, c.Type)
		if err != nil {
			return "", err
		}
		if i > 0 {
			b.WriteString(", ")
		}
		b.WriteString(QuoteIdent(engine, c.Name) + " " + typ + " NULL")
	}
	b.WriteString(")")
	return b.String(), nil
}

// ConvertRows converts every cell (Convert) and counts the NUL characters dropped from text cells; the first cell
// that does not convert, or a row whose length is not the columns' (review-31 S1), refuses the whole grid, naming its
// row.
func ConvertRows(engine string, cols []Col, rows [][]any) ([][]any, int, error) {
	out, nuls := make([][]any, len(rows)), 0
	for i, r := range rows {
		if len(r) != len(cols) {
			return nil, 0, fmt.Errorf("row %d holds %d values for %d columns; nothing was written", i+1, len(r), len(cols))
		}
		o := make([]any, len(r))
		for j, v := range r {
			if cols[j].Type == "text" {
				nuls += NULs(v)
			}
			x, err := Convert(engine, cols[j].Type, i+1, cols[j].Name, v)
			if err != nil {
				return nil, 0, err
			}
			o[j] = x
		}
		out[i] = o
	}
	return out, nuls, nil
}

// Verdict is Check's answer: Outcome "" = every gate passed (write the started row, then the table); else
// "refused" or "failed" with its words. Row says whether the attempt writes an audit row.
type Verdict struct {
	Outcome, Words string
	Row            bool
	Target         string  // the one quoted form, once the identifiers passed
	Rows           [][]any // the converted rows, once every gate passed
	NULs           int     // the NUL characters dropped from text cells
}

// Check runs the gates from the instance's door on, in the design's order (5 the list and the login, 6 the typed
// confirmation '<instance>/<database>', 7 the identifiers, the database and the kinds, 8 the login checks and the
// schema on the writing connection, 9 the table's existence). open is called only once gates 5-7 pass. Every
// refusal here writes an audit row (review-29 N8); the gates before it (the header, the role, the switch, the body,
// the instance lookup) write none, as every existing action.
func Check(ctx context.Context, in Instance, dbs []Database, b Body, open func(ctx context.Context) (mon, act Conn, err error)) Verdict {
	refuse := func(w string) Verdict { return Verdict{Outcome: "refused", Words: w, Row: true} }
	fail := func(w string) Verdict { return Verdict{Outcome: "failed", Words: w, Row: true} }
	// 5. the instance's list and its actions login
	if w := OffWords(true, in); w != "" {
		return refuse(w)
	}
	// 6. the typed confirmation names the target - the database's name checked first, so these words never carry a
	// refused name raw (review-31 part A2 SF3: a NUL, an invisible character, megabytes of name)
	if err := CheckName(in.Engine, "database", b.Database); err != nil {
		return refuse(err.Error())
	}
	if want := Confirm(in.Name, b.Database); strings.TrimSpace(b.Confirm) != want {
		return refuse(fmt.Sprintf("the typed confirmation is not %s: nothing was written", want))
	}
	// 7. the identifiers first (a refused name never reaches the words raw: review-31 S6), the database, the kinds
	if err := CheckName(in.Engine, "table", b.Table); err != nil {
		return refuse(err.Error())
	}
	var db *Database
	for i := range dbs {
		if dbs[i].Name == b.Database {
			db = &dbs[i]
			break
		}
	}
	if db == nil {
		return refuse(fmt.Sprintf("database: %s is not a database of instance %s as its last read lists them", b.Database, in.Name))
	}
	if w := RefuseDatabase(in.Engine, *db); w != "" {
		return refuse(w)
	}
	names := make([]string, len(b.Cols))
	for i, c := range b.Cols {
		names[i] = c.Name
	}
	if err := CheckColumns(in.Engine, names); err != nil {
		return refuse(err.Error())
	}
	for i, c := range b.Cols {
		if _, err := ColumnType(in.Engine, c.Type); err != nil {
			return refuse(fmt.Sprintf("column %d (%s): %v", i+1, c.Name, err))
		}
	}
	rows, nuls, err := ConvertRows(in.Engine, b.Cols, b.Rows)
	if err != nil {
		return refuse(err.Error())
	}
	t := Target{Database: b.Database, Schema: Schema, Table: b.Table}
	quoted := Quoted(in.Engine, t)
	// 8. the two logins on the chosen database: one server, a login of its own, no superuser; the schema its own
	mon, act, err := open(ctx)
	if err != nil {
		return fail(fmt.Sprintf("the actions login could not connect to %s: %v; nothing was written", b.Database, err))
	}
	monServer, err := mon.Server(ctx)
	if err != nil {
		return fail(fmt.Sprintf("the server check failed: %v; nothing was written", err))
	}
	actServer, err := act.Server(ctx)
	if err != nil {
		return fail(fmt.Sprintf("the actions login's server check failed: %v; nothing was written", err))
	}
	if monServer != actServer {
		return refuse(fmt.Sprintf("actions_dsn reaches another server than the instance's dsn (%s vs %s): nothing was written", actServer, monServer))
	}
	monLogin, _, err := mon.Login(ctx)
	if err != nil {
		return fail(fmt.Sprintf("the login check failed: %v; nothing was written", err))
	}
	actLogin, super, err := act.Login(ctx)
	if err != nil {
		return fail(fmt.Sprintf("the actions login's own check failed: %v; nothing was written", err))
	}
	if actLogin == monLogin || in.Engine == SQLServer && strings.EqualFold(actLogin, monLogin) {
		return refuse(fmt.Sprintf("actions_dsn connects as the read login (%s): the actions login must be a login of its own", actLogin))
	}
	if super {
		if in.Engine == SQLServer {
			return refuse(fmt.Sprintf("the actions login %s is sysadmin or holds CONTROL SERVER: pgvigil refuses it", actLogin))
		}
		return refuse(fmt.Sprintf("the actions login %s is a superuser: pgvigil refuses it", actLogin))
	}
	// what the database IS, read on the WRITING connection at the save: the store's last read may be stale, and it
	// never says whether a database is a distributor's (review-31 part A2 SF4, part A1 S4)
	place, err := act.Place(ctx)
	if err != nil {
		return fail(fmt.Sprintf("the database check on the writing connection failed: %v; nothing was written", err))
	}
	if w := RefuseDatabase(in.Engine, Database{Name: b.Database, ID: place.DB.ID, IsTemplate: place.DB.IsTemplate, IsDistributor: place.DB.IsDistributor}); w != "" {
		return refuse(w)
	}
	if place.Owner {
		return refuse(fmt.Sprintf("the actions login %s owns the database %s or is a member of db_owner there: pgvigil refuses it (the door login owns the schema pgvigil_saved and nothing else)", actLogin, b.Database))
	}
	exists, owned, err := act.Schema(ctx)
	if err != nil {
		return fail(fmt.Sprintf("the schema check failed: %v; nothing was written", err))
	}
	if !exists {
		return refuse(OffSchema)
	}
	if !owned {
		return refuse(fmt.Sprintf("off: the schema pgvigil_saved in %s is owned by another login: pgvigil writes only into the door login's own schema (docs/export.md has the two lines that make it)", b.Database))
	}
	// 9. never an overwrite
	there, err := act.Exists(ctx, quoted)
	if err != nil {
		return fail(fmt.Sprintf("the existence read failed: %v; nothing was written", err))
	}
	if there {
		return refuse(fmt.Sprintf("the table %s exists: pgvigil never overwrites a table", t.Display()))
	}
	return Verdict{Row: true, Target: quoted, Rows: rows, NULs: nuls}
}
