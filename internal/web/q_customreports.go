package web

// Custom reports (task 170; DBA Dash's custom reports): the DBA's own SQL, or a procedure, saved as a report with its
// parameters, its column formats, its colour rules (ok / warn / crit by a column's value) and a folder of the tree
// shared by every user, and run on the repository (the store) or, read-only, on a chosen monitored instance or on the
// instances of a tag. The screen draws the result in pgvigil's grid (its menus, the export, the grid tools) and applies
// the formats and the colour rules there (customreports.ts), so a mailed page and an exported workbook carry the
// colours the window shows.
//
//	GET  /api/customreports                  the folders, the live reports (their definitions), the latest 200 log rows,
//	                                         and whether saving and running are on here (and why not)
//	GET  /api/customreports?report=N         one report with its 100 latest log rows
//	POST /api/customreports                  {op: add | edit | delete | move | folder_add | folder_rename | folder_delete, ...}
//	POST /api/customreports/run              {report_id, target: fleet | tag | instance, instance_id, tag, from, to, params}
//
// Every write and every run is behind the UI login and the X-Pgvigil header and goes through the actions door's audit
// login (pgvigil.import_custom_report, import_custom_report_run: 0106); without that door nothing is saved or run, and
// the page says why. A run is written to the audit after it ends and before the answer: a run whose audit row cannot be
// written answers an error and withholds its rows. Nothing is run when the audit login may not write the run's row.
//
// How a run stays read-only, per engine:
//   - the store: a connection of its own on the serve login (the UI's read-only reader), a READ ONLY transaction rolled
//     back, the report's timeout as statement_timeout and a 2 s lock_timeout set inside it; refused when the serve login
//     is a superuser or holds pg_execute_server_program, pg_write_server_files or pg_read_server_files (READ ONLY does
//     not stop COPY ... TO PROGRAM); the extended protocol takes one statement only.
//   - a PostgreSQL instance: the same, on a connection of its own through the instance's monitoring login, with
//     default_transaction_read_only on as well.
//   - a SQL Server instance: a connection of its own through the instance's read login, LOCK_TIMEOUT 2000 and
//     DEADLOCK_PRIORITY LOW, the report inside a transaction that is rolled back, the report's timeout on the request;
//     refused when the login is a member of sysadmin. SQL Server has no read-only session: what keeps a report from
//     writing is the login's own rights (docs/sqlserver.md: VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY
//     DATABASE and no more); the rollback undoes what a write-capable login did inside the transaction, never a COMMIT
//     the report itself sends.
//
// A report's parameters are named @name in its SQL on both engines (pgx's named arguments on PostgreSQL, sp_executesql's
// on SQL Server); every run also passes @from and @to (the page's time range, timestamptz / datetimeoffset) and, on the
// store, @instance_ids (int[]: the instances the run was asked for: one, a tag's, or every active one).
// A procedure report calls its procedure with the parameters given, by name: EXEC [schema].[name] @p = @p on SQL
// Server, SELECT * FROM schema.name(p => @p) on PostgreSQL and the store.

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	mssqldb "github.com/microsoft/go-mssqldb"
)

// ---- definitions ------------------------------------------------------------------------------------------------

type reportParam struct {
	Name     string  `json:"name"`
	Type     string  `json:"type"` // text | int | number | bool | timestamp | date
	Label    string  `json:"label,omitempty"`
	Default  *string `json:"default,omitempty"`
	Required bool    `json:"required,omitempty"`
}

type reportColumn struct {
	Set      int    `json:"set"`
	Column   string `json:"column"`
	Label    string `json:"label,omitempty"`
	Format   string `json:"format,omitempty"` // see reportFormats
	Decimals *int   `json:"decimals,omitempty"`
	Hidden   bool   `json:"hidden,omitempty"`
}

type reportRule struct {
	Set           int    `json:"set"`
	Column        string `json:"column"`         // the cell the rule colours
	Eval          string `json:"eval,omitempty"` // the column whose value is judged; "" = the cell's own
	Cond          string `json:"cond"`           // see reportConds
	Value1        string `json:"value1,omitempty"`
	Value2        string `json:"value2,omitempty"`
	Status        string `json:"status"` // ok | warn | crit
	CaseSensitive bool   `json:"case_sensitive,omitempty"`
}

type reportDef struct {
	ID          int64          `json:"report_id"`
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Folder      string         `json:"folder"`
	Engine      string         `json:"engine"` // store | postgres | sqlserver
	Kind        string         `json:"kind"`   // sql | procedure
	Body        string         `json:"body"`
	Params      []reportParam  `json:"params"`
	Columns     []reportColumn `json:"columns"`
	Rules       []reportRule   `json:"rules"`
	TimeoutSecs int            `json:"timeout_secs"`
	MaxRows     int            `json:"max_rows"`
	Version     int            `json:"version"`
}

var (
	reportParamTypes = map[string]bool{"text": true, "int": true, "number": true, "bool": true, "timestamp": true, "date": true}
	reportFormats    = map[string]bool{"": true, "text": true, "number": true, "int": true, "bytes": true, "kb": true, "mb": true,
		"secs": true, "ms": true, "pct": true, "time": true, "date": true}
	reportConds = map[string]bool{"eq": true, "ne": true, "gt": true, "gte": true, "lt": true, "lte": true, "between": true,
		"contains": true, "not_contains": true, "begins": true, "ends": true, "isnull": true, "notnull": true, "all": true}
	reportStatuses  = map[string]bool{"ok": true, "warn": true, "crit": true}
	reportParamName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,62}$`)
	reportProcName  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_$#]{0,127}(\.[A-Za-z_][A-Za-z0-9_$#]{0,127}){0,2}$`)
	reportBuiltins  = map[string]bool{"from": true, "to": true, "instance_ids": true}
	pgIdent         = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_$]{0,62}$`)
)

// validReport checks a definition before it is written; the message is the user's to read.
func validReport(d *reportDef) error {
	d.Name = strings.TrimSpace(d.Name)
	switch {
	case d.Name == "" || len([]rune(d.Name)) > 200:
		return errors.New("a report has a name of 1 to 200 characters")
	case strings.IndexFunc(d.Name, unicode.IsControl) >= 0:
		return errors.New("a report's name holds no control characters")
	case d.Engine != "store" && d.Engine != "postgres" && d.Engine != "sqlserver":
		return errors.New("engine must be store (the repository), postgres or sqlserver")
	case d.Kind != "sql" && d.Kind != "procedure":
		return errors.New("kind must be sql or procedure")
	case strings.TrimSpace(d.Body) == "":
		return errors.New("the report has no SQL (or procedure name)")
	case len(d.Body) > 200000:
		return errors.New("the report's SQL is at most 200000 characters")
	case d.Kind == "procedure" && !reportProcName.MatchString(strings.TrimSpace(d.Body)):
		return errors.New("a procedure report names its procedure as name, schema.name or database.schema.name (letters, digits, _ $ #)")
	case d.TimeoutSecs < 1 || d.TimeoutSecs > 60:
		return errors.New("timeout_secs is 1 to 60")
	case d.MaxRows < 1 || d.MaxRows > 50000:
		return errors.New("max_rows is 1 to 50000")
	case len(d.Params) > 30:
		return errors.New("a report has at most 30 parameters")
	case len(d.Columns) > 500 || len(d.Rules) > 500:
		return errors.New("a report has at most 500 column formats and 500 colour rules")
	}
	if d.Kind == "procedure" && d.Engine != "sqlserver" {
		parts := strings.Split(strings.TrimSpace(d.Body), ".")
		if len(parts) > 2 {
			return errors.New("a PostgreSQL function report names name or schema.name: a statement reaches one database")
		}
		for _, x := range parts {
			if !pgIdent.MatchString(x) {
				return fmt.Errorf("a PostgreSQL function name part is a letter or _ and up to 62 letters, digits, _ or $ (%q)", x)
			}
		}
	}
	seen := map[string]bool{}
	for i := range d.Params {
		p := &d.Params[i]
		p.Name = strings.TrimPrefix(strings.TrimSpace(p.Name), "@")
		k := strings.ToLower(p.Name)
		switch {
		case !reportParamName.MatchString(p.Name):
			return fmt.Errorf("parameter %q: a name is a letter or _ and up to 62 letters, digits or _", p.Name)
		case reportBuiltins[k]:
			return fmt.Errorf("parameter %q: from, to and instance_ids are passed to every run already", p.Name)
		case seen[k]:
			return fmt.Errorf("parameter %q is named twice", p.Name)
		case !reportParamTypes[p.Type]:
			return fmt.Errorf("parameter %q: type must be text, int, number, bool, timestamp or date", p.Name)
		case len(p.Label) > 200:
			return fmt.Errorf("parameter %q: a label is at most 200 characters", p.Name)
		}
		seen[k] = true
		if p.Default != nil && strings.TrimSpace(*p.Default) != "" {
			if _, err := paramValue(*p, p.Default); err != nil {
				return fmt.Errorf("parameter %q: its default %w", p.Name, err)
			}
		}
	}
	for _, c := range d.Columns {
		switch {
		case c.Set < 0 || c.Set > 49:
			return fmt.Errorf("column %q: set is the result set's number, 0 to 49", c.Column)
		case strings.TrimSpace(c.Column) == "" || len(c.Column) > 128:
			return errors.New("a column format names its column (1 to 128 characters)")
		case !reportFormats[c.Format]:
			return fmt.Errorf("column %q: format %q is not one of text, number, int, bytes, kb, mb, secs, ms, pct, time, date", c.Column, c.Format)
		case c.Decimals != nil && (*c.Decimals < 0 || *c.Decimals > 6):
			return fmt.Errorf("column %q: decimals is 0 to 6", c.Column)
		case len(c.Label) > 200:
			return fmt.Errorf("column %q: a label is at most 200 characters", c.Column)
		}
	}
	for i, x := range d.Rules {
		need1 := x.Cond != "isnull" && x.Cond != "notnull" && x.Cond != "all"
		switch {
		case x.Set < 0 || x.Set > 49:
			return fmt.Errorf("colour rule %d: set is the result set's number, 0 to 49", i+1)
		case strings.TrimSpace(x.Column) == "" || len(x.Column) > 128 || len(x.Eval) > 128:
			return fmt.Errorf("colour rule %d names the column it colours (1 to 128 characters)", i+1)
		case !reportConds[x.Cond]:
			return fmt.Errorf("colour rule %d: condition %q is not one of eq, ne, gt, gte, lt, lte, between, contains, not_contains, begins, ends, isnull, notnull, all", i+1, x.Cond)
		case !reportStatuses[x.Status]:
			return fmt.Errorf("colour rule %d: status must be ok, warn or crit", i+1)
		case need1 && x.Value1 == "":
			return fmt.Errorf("colour rule %d: %s needs a value", i+1, x.Cond)
		case x.Cond == "between" && x.Value2 == "":
			return fmt.Errorf("colour rule %d: between needs a second value", i+1)
		case len(x.Value1) > 400 || len(x.Value2) > 400:
			return fmt.Errorf("colour rule %d: a value is at most 400 characters", i+1)
		}
	}
	return nil
}

// paramValue turns a typed parameter's text into the value bound: nil = NULL (empty and not required).
func paramValue(p reportParam, raw *string) (any, error) {
	v := ""
	if raw != nil {
		v = strings.TrimSpace(*raw)
	}
	if v == "" && p.Default != nil {
		v = strings.TrimSpace(*p.Default)
	}
	if v == "" {
		if p.Required {
			return nil, errors.New("is required")
		}
		return nil, nil
	}
	switch p.Type {
	case "int":
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("%q is not a whole number", v)
		}
		return n, nil
	case "number":
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
			return nil, fmt.Errorf("%q is not a number", v)
		}
		return f, nil
	case "bool":
		switch strings.ToLower(v) {
		case "true", "1", "yes", "on":
			return true, nil
		case "false", "0", "no", "off":
			return false, nil
		}
		return nil, fmt.Errorf("%q is not true or false", v)
	case "timestamp":
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			return nil, fmt.Errorf("%q is not a time (RFC 3339: 2026-11-11T08:00:00Z)", v)
		}
		return t, nil
	case "date":
		t, err := time.Parse("2006-01-02", v)
		if err != nil {
			return nil, fmt.Errorf("%q is not a date (2026-11-11)", v)
		}
		return t, nil
	}
	if len(v) > 4000 {
		return nil, errors.New("is at most 4000 characters")
	}
	return v, nil
}

// procCall is the statement a procedure report sends: the parameters given a value, by name (one left empty takes the
// procedure's own default). PostgreSQL's names are written unquoted, so they fold to lower case as they do in a
// CREATE FUNCTION that did not quote them.
func procCall(engine, name string, params []reportParam, given map[string]any) string {
	parts := strings.Split(strings.TrimSpace(name), ".")
	var b strings.Builder
	if engine == "sqlserver" {
		for i, p := range parts {
			parts[i] = "[" + strings.ReplaceAll(p, "]", "]]") + "]"
		}
		b.WriteString("EXEC " + strings.Join(parts, "."))
		n := 0
		for _, p := range params {
			if given[p.Name] == nil {
				continue
			}
			if n > 0 {
				b.WriteString(",")
			}
			b.WriteString(" @" + p.Name + " = @" + p.Name)
			n++
		}
		return b.String()
	}
	b.WriteString("SELECT * FROM " + strings.Join(parts, ".") + "(")
	n := 0
	for _, p := range params {
		if given[p.Name] == nil {
			continue
		}
		if n > 0 {
			b.WriteString(", ")
		}
		b.WriteString(p.Name + " => @" + p.Name)
		n++
	}
	b.WriteString(")")
	return b.String()
}

// ---- results ----------------------------------------------------------------------------------------------------

// resultSet is one result set of a run as the page draws it: types says per column number, time or text.
type resultSet struct {
	Columns   []string `json:"columns"`
	Types     []string `json:"types"`
	Rows      [][]any  `json:"rows"`
	Truncated bool     `json:"truncated,omitempty"`
}

// instanceRun is one run on one instance (or the store).
type instanceRun struct {
	InstanceID int    `json:"instance_id,omitempty"`
	Instance   string `json:"instance"`
	Engine     string `json:"engine"`
	Outcome    string `json:"outcome"` // done | refused | failed
	Error      string `json:"error,omitempty"`
	// a community procedure looked at this server and said no in its own words (q_community.go declines): the
	// outcome stays failed (the statement reached the server), the page draws a note instead of an error box
	Declined   bool        `json:"declined,omitempty"`
	DurationMS int         `json:"duration_ms"`
	Rows       int         `json:"rows"`
	Sets       []resultSet `json:"sets"`
	Statement  string      `json:"-"`
}

const (
	maxCellBytes = 256 << 10 // a longer text value is cut (a plan, a long statement) and says so
	maxRunBytes  = 24 << 20  // the rows of one run kept at most; past it the set is truncated
	maxSets      = 50
)

// sizer counts the bytes a run keeps so one run cannot fill the server's memory.
type sizer struct{ n int }

func (z *sizer) cell(v any) any {
	if s, ok := v.(string); ok {
		if len(s) > maxCellBytes {
			s = s[:maxCellBytes] + " [cut at 256 KB]"
			v = s
		}
		z.n += len(s)
	} else {
		z.n += 16
	}
	return v
}

// pgCell turns a pgx value into what the JSON answer carries: a time as RFC 3339 (timestamp without a zone and date
// as the wall clock, no zone), a number as a number unless it would lose digits in a browser, bytes as \x hex, a uuid
// as its text, anything else as its text form.
func pgCell(v any, oid uint32) any {
	switch x := v.(type) {
	case nil, bool, string, float32, int16, int32, int8, uint8, uint16, uint32:
		return x
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return strconv.FormatFloat(x, 'g', -1, 64)
		}
		return x
	case int64:
		if x > 1<<53 || x < -(1<<53) {
			return strconv.FormatInt(x, 10)
		}
		return x
	case time.Time:
		switch oid {
		case pgtype.DateOID:
			return x.Format("2006-01-02")
		case pgtype.TimestampOID:
			return x.Format("2006-01-02 15:04:05.999999")
		}
		return x.UTC().Format(time.RFC3339Nano)
	case []byte:
		return `\x` + hex.EncodeToString(x)
	case [16]byte:
		return fmt.Sprintf("%x-%x-%x-%x-%x", x[0:4], x[4:6], x[6:8], x[8:10], x[10:16])
	case pgtype.Numeric:
		if !x.Valid {
			return nil
		}
		if f, err := x.Float64Value(); err == nil && f.Valid && !math.IsInf(f.Float64, 0) && !math.IsNaN(f.Float64) {
			if b, err := x.MarshalJSON(); err == nil && len(b) <= 16 {
				return f.Float64
			}
		}
		if b, err := x.MarshalJSON(); err == nil {
			return strings.Trim(string(b), `"`)
		}
		return nil
	case map[string]any, []any:
		return x
	case fmt.Stringer:
		return x.String()
	case driver.Valuer:
		if dv, err := x.Value(); err == nil {
			return pgCell(dv, oid)
		}
	}
	return fmt.Sprint(v)
}

// pgType is the page's type of a PostgreSQL column: number, time or text.
func pgType(oid uint32) string {
	switch oid {
	case pgtype.Int2OID, pgtype.Int4OID, pgtype.Int8OID, pgtype.Float4OID, pgtype.Float8OID, pgtype.NumericOID, pgtype.OIDOID:
		return "number"
	case pgtype.TimestamptzOID:
		return "time"
	}
	return "text"
}

// readPG reads one statement's rows (at most maxRows) into a set. At the cap (or the run's byte limit) it calls stop,
// which cancels the statement, so the server does not go on producing rows nobody reads; the set says it was cut.
func readPG(rows pgx.Rows, maxRows int, z *sizer, stop func()) (resultSet, error) {
	defer rows.Close()
	fds := rows.FieldDescriptions()
	set := resultSet{Columns: make([]string, len(fds)), Types: make([]string, len(fds)), Rows: [][]any{}}
	for i, f := range fds {
		set.Columns[i], set.Types[i] = f.Name, pgType(f.DataTypeOID)
	}
	for rows.Next() {
		if len(set.Rows) >= maxRows || z.n > maxRunBytes {
			set.Truncated = true
			stop()
			return set, nil // the cancel's own error is not the run's
		}
		vals, err := rows.Values()
		if err != nil {
			return set, err
		}
		for i, v := range vals {
			vals[i] = z.cell(pgCell(v, fds[i].DataTypeOID))
		}
		set.Rows = append(set.Rows, vals)
	}
	return set, rows.Err()
}

// msType is the page's type of a SQL Server column.
func msType(name string) string {
	switch strings.ToUpper(name) {
	case "INT", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY", "FLOAT", "REAL":
		return "number"
	case "DATETIMEOFFSET":
		return "time"
	}
	return "text"
}

// msCell turns a go-mssqldb value into the JSON answer's form (see pgCell); a datetime without an offset is the
// server's wall clock and stays one (no zone, never moved to the reader's).
func msCell(v any, typ string) any {
	t := strings.ToUpper(typ)
	switch x := v.(type) {
	case nil, bool, string, float32:
		return x
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return strconv.FormatFloat(x, 'g', -1, 64)
		}
		return x
	case int64:
		if x > 1<<53 || x < -(1<<53) {
			return strconv.FormatInt(x, 10)
		}
		return x
	case time.Time:
		switch t {
		case "DATE":
			return x.Format("2006-01-02")
		case "TIME":
			return x.Format("15:04:05.9999999")
		case "DATETIMEOFFSET":
			return x.UTC().Format(time.RFC3339Nano)
		}
		return x.Format("2006-01-02 15:04:05.999")
	case []byte:
		switch t {
		case "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY":
			s := string(x)
			if f, err := strconv.ParseFloat(s, 64); err == nil && len(strings.TrimLeft(strings.Replace(s, ".", "", 1), "-0")) <= 15 {
				return f
			}
			return s
		case "UNIQUEIDENTIFIER":
			var u mssqldb.UniqueIdentifier
			if err := u.Scan(x); err == nil {
				return u.String()
			}
		}
		return "0x" + strings.ToUpper(hex.EncodeToString(x))
	}
	return fmt.Sprint(v)
}

// readMS reads every result set of a SQL Server request (at most maxRows rows each, at most maxSets sets). At a cap it
// calls stop, which cancels the request (an attention: the server stops), and keeps what it read: a later result set
// of the batch is then not read, and the cut set says so.
func readMS(rows *sql.Rows, maxRows int, z *sizer, stop func()) ([]resultSet, error) {
	defer func() { _ = rows.Close() }()
	var sets []resultSet
	for {
		cts, err := rows.ColumnTypes()
		if err != nil {
			return sets, err
		}
		if len(cts) > 0 {
			if len(sets) >= maxSets {
				stop()
				return sets, nil
			}
			set := resultSet{Columns: make([]string, len(cts)), Types: make([]string, len(cts)), Rows: [][]any{}}
			for i, c := range cts {
				set.Columns[i], set.Types[i] = c.Name(), msType(c.DatabaseTypeName())
			}
			for rows.Next() {
				if len(set.Rows) >= maxRows || z.n > maxRunBytes {
					set.Truncated = true
					stop()
					return append(sets, set), nil // the cancel's own error is not the run's
				}
				vals := make([]any, len(cts))
				ptrs := make([]any, len(cts))
				for i := range vals {
					ptrs[i] = &vals[i]
				}
				if err := rows.Scan(ptrs...); err != nil {
					return append(sets, set), err
				}
				for i, v := range vals {
					vals[i] = z.cell(msCell(v, cts[i].DatabaseTypeName()))
				}
				set.Rows = append(set.Rows, vals)
			}
			if err := rows.Err(); err != nil {
				return append(sets, set), err
			}
			sets = append(sets, set)
		}
		if !rows.NextResultSet() {
			break
		}
	}
	return sets, rows.Err()
}

// ---- running ----------------------------------------------------------------------------------------------------

// pgRightsSQL reads what a read-only transaction does not stop (the custom checks' rule, internal/collect/custom.go).
const pgRightsSQL = `SELECT r.rolsuper,
       pg_has_role(current_user, 'pg_execute_server_program', 'MEMBER'),
       pg_has_role(current_user, 'pg_write_server_files', 'MEMBER'),
       pg_has_role(current_user, 'pg_read_server_files', 'MEMBER')
  FROM pg_roles r WHERE r.rolname = current_user`

func pgRefusal(ctx context.Context, tx pgx.Tx) (string, error) {
	var super, prog, write, read bool
	if err := tx.QueryRow(ctx, pgRightsSQL).Scan(&super, &prog, &write, &read); err != nil {
		return "", fmt.Errorf("reading the login's rights: %w", err)
	}
	var too []string
	for _, x := range []struct {
		on   bool
		name string
	}{{super, "superuser"}, {prog, "pg_execute_server_program"}, {write, "pg_write_server_files"}, {read, "pg_read_server_files"}} {
		if x.on {
			too = append(too, x.name)
		}
	}
	if len(too) == 0 {
		return "", nil
	}
	return "the login is " + strings.Join(too, ", ") + ": the DBA's own SQL runs only as a login without it (a read-only transaction does not stop COPY ... TO PROGRAM)", nil
}

// runPG runs one statement read-only on a PostgreSQL connection made from cfg (the store's or an instance's), and
// closes it: a session-level side effect (an advisory lock, a set_config) never outlives the run.
func runPG(ctx context.Context, cfg *pgx.ConnConfig, stmt string, args pgx.NamedArgs, timeout time.Duration, maxRows int) (sets []resultSet, refused string, err error) {
	cfg = cfg.Copy()
	cfg.ConnectTimeout = 10 * time.Second
	rp := cfg.RuntimeParams
	rp["application_name"] = "pgvigil-report"
	rp["default_transaction_read_only"] = "on"
	rp["statement_timeout"] = strconv.FormatInt(timeout.Milliseconds(), 10)
	rp["lock_timeout"] = "2000"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, "", fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(context.WithoutCancel(ctx)) }()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	// a query first: the transaction's snapshot is taken, so a SET TRANSACTION READ WRITE in the report is refused
	if why, err := pgRefusal(ctx, tx); err != nil || why != "" {
		return nil, why, err
	}
	qctx, qcancel := context.WithCancel(ctx)
	defer qcancel()
	rows, err := tx.Query(qctx, stmt, pgx.QueryExecModeDescribeExec, args)
	if err != nil {
		return nil, "", err
	}
	z := &sizer{}
	set, err := readPG(rows, maxRows, z, qcancel)
	if err != nil {
		return nil, "", err
	}
	return []resultSet{set}, "", nil
}

// mssqlApp names the session on the SQL Server side (the URL and the ADO forms; an odbc: string is left as it is).
func mssqlApp(dsn, app string) string {
	l := strings.ToLower(dsn)
	switch {
	case strings.HasPrefix(l, "odbc:"):
		return dsn
	case strings.HasPrefix(l, "sqlserver://"):
		if strings.Contains(l, "app+name=") || strings.Contains(l, "app%20name=") || strings.Contains(l, "app name=") {
			return dsn
		}
		if strings.Contains(dsn, "?") {
			return dsn + "&app+name=" + app
		}
		return dsn + "?app+name=" + app
	}
	if strings.Contains(l, "app name") || strings.Contains(l, "application name") {
		return dsn
	}
	return strings.TrimRight(dsn, "; ") + ";app name=" + app
}

// openMS opens one connection on the read login and refuses a sysadmin; the caller closes both.
func openMS(ctx context.Context, dsn, app string) (*sql.DB, *sql.Conn, string, error) {
	if strings.TrimSpace(dsn) == "" {
		return nil, nil, "", errors.New("the read login's dsn resolved to an empty string")
	}
	db, err := sql.Open("sqlserver", mssqlApp(dsn, app))
	if err != nil {
		return nil, nil, "", fmt.Errorf("dsn: %w", err)
	}
	db.SetMaxOpenConns(1)
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	conn, err := db.Conn(cctx)
	if err != nil {
		_ = db.Close()
		return nil, nil, "", fmt.Errorf("connect: %w", err)
	}
	if _, err := conn.ExecContext(cctx, "SET NOCOUNT ON; SET LOCK_TIMEOUT 2000; SET DEADLOCK_PRIORITY LOW;"); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, "", err
	}
	var sa int
	var login string
	if err := conn.QueryRowContext(cctx, "SELECT ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0), SUSER_SNAME()").Scan(&sa, &login); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, "", fmt.Errorf("reading the login's rights: %w", err)
	}
	if sa == 1 {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, fmt.Sprintf("the read login %s is a member of sysadmin: custom reports and community tools run only as a login without it (docs/sqlserver.md has the login: VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE)", login), nil
	}
	return db, conn, "", nil
}

// runMS runs one batch on the read login inside a transaction that is rolled back (rollback = true) or as it is.
func runMS(ctx context.Context, dsn, stmt string, args []any, timeout time.Duration, maxRows int, rollback bool) (sets []resultSet, refused string, err error) {
	db, conn, why, err := openMS(ctx, dsn, "pgvigil-report")
	if err != nil || why != "" {
		return nil, why, err
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	rctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	z := &sizer{}
	if !rollback {
		rows, err := conn.QueryContext(rctx, stmt, args...)
		if err != nil {
			return nil, "", err
		}
		sets, err = readMS(rows, maxRows, z, cancel)
		return sets, "", err
	}
	tx, err := conn.BeginTx(rctx, nil)
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(rctx, stmt, args...)
	if err != nil {
		return nil, "", err
	}
	sets, err = readMS(rows, maxRows, z, cancel)
	return sets, "", err
}

// ---- the routes -------------------------------------------------------------------------------------------------

// customReportsOff is why reports cannot be saved or run on this server; "" = they can.
func (s *Server) customReportsOff() string {
	if w := s.serverOff(); w != "" {
		return "Saving or running a report needs " + w + "."
	}
	return ""
}

// serverOff is what this server lacks for the pages that write and run under the UI login and through the actions
// door's audit login (Custom reports, Community tools, Report mail), as the words after '<the page's own action>
// needs ': "" when nothing is missing. Each page puts its own action before it.
func (s *Server) serverOff() string {
	switch {
	case s.auth == nil:
		return "a signed-in user: this server was started with -no-login"
	case s.actions == nil:
		return "the actions door: this server runs without one"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "the actions door's audit login, and it is off (" + s.actions.off + ")"
		}
		return "the actions door's audit login, and it is not connected"
	}
	return ""
}

const sqlCustomReportCols = `report_id, name, description, folder, engine, kind, body, params, columns, rules, timeout_secs,
       max_rows, version, created_by, created_at, updated_by, updated_at`

const sqlCustomReportList = `SELECT ` + sqlCustomReportCols + `
  FROM pgvigil.custom_reports WHERE deleted_at IS NULL ORDER BY folder, lower(name)`

const sqlCustomReportFolders = `
SELECT folder FROM pgvigil.custom_report_folders
 UNION SELECT folder FROM pgvigil.custom_reports WHERE deleted_at IS NULL AND folder <> ''
 ORDER BY 1`

const sqlCustomReportLog = `
SELECT log_id, at, ui_user, client, op, report_id, report_name, tool, instance_id, instance, outcome, detail, rows, duration_ms, statement
  FROM pgvigil.custom_report_log ORDER BY at DESC, log_id DESC LIMIT 200`

const sqlCustomReportOne = `SELECT ` + sqlCustomReportCols + ` FROM pgvigil.custom_reports WHERE report_id = $1 AND deleted_at IS NULL`

const sqlCustomReportOneLog = `
SELECT log_id, at, ui_user, client, op, report_id, report_name, tool, instance_id, instance, outcome, detail, rows, duration_ms, statement
  FROM pgvigil.custom_report_log WHERE report_id = $1 ORDER BY at DESC, log_id DESC LIMIT 100`

// CustomReports is GET /api/customreports (the tree, the definitions and the log) or ?report=N (one report).
func (s *Server) CustomReports(w http.ResponseWriter, r *http.Request) {
	type onOff struct {
		Enabled bool   `json:"enabled"`
		Reason  string `json:"reason,omitempty"`
	}
	why := s.customReportsOff()
	state := onOff{Enabled: why == "", Reason: why}
	ctx := r.Context()
	if q := r.URL.Query().Get("report"); q != "" {
		id, err := strconv.ParseInt(q, 10, 64)
		if err != nil || id <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("report must be a report id"))
			return
		}
		one, err := s.query(ctx, sqlCustomReportOne, id)
		if err == nil && len(one.Rows) == 0 {
			writeErr(w, http.StatusNotFound, fmt.Errorf("no report %d", id))
			return
		}
		var log *table
		if err == nil {
			log, err = s.query(ctx, sqlCustomReportOneLog, id)
		}
		s.reply(w, r, struct {
			State  onOff  `json:"state"`
			Report *table `json:"report"`
			Log    *table `json:"log"`
		}{state, one, log}, err)
		return
	}
	reports, err := s.query(ctx, sqlCustomReportList)
	var folders, log *table
	if err == nil {
		folders, err = s.query(ctx, sqlCustomReportFolders)
	}
	if err == nil {
		log, err = s.query(ctx, sqlCustomReportLog)
	}
	s.reply(w, r, struct {
		State   onOff  `json:"state"`
		Folders *table `json:"folders"`
		Reports *table `json:"reports"`
		Log     *table `json:"log"`
	}{state, folders, reports, log}, err)
}

// reportGate is what every POST shares: the header, the door, the user. ok false = the reply is written.
func (s *Server) reportGate(w http.ResponseWriter, r *http.Request, limit int64) (user string, raw []byte, ok bool) {
	return s.gate(w, r, limit, s.customReportsOff)
}

// gate is reportGate with the page's own words for what the server lacks (off: "" = nothing).
func (s *Server) gate(w http.ResponseWriter, r *http.Request, limit int64, off func() string) (user string, raw []byte, ok bool) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return "", nil, false
	}
	if why := off(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return "", nil, false
	}
	if user = s.sessionUser(r); user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return "", nil, false
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil || int64(len(raw)) > limit {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: unreadable or over %d KB", limit>>10))
		return "", nil, false
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was done"))
		return "", nil, false
	}
	return user, raw, true
}

type reportWriteBody struct {
	reportDef
	Op        string `json:"op"`
	NewFolder string `json:"new_folder"`
	// absent = the default (30 s, 5000 rows); a value given is checked, 0 included (these shadow reportDef's ints)
	Timeout *int `json:"timeout_secs"`
	Rows    *int `json:"max_rows"`
}

// CustomReportWrite is POST /api/customreports: a save, a move, a delete or a folder change.
func (s *Server) CustomReportWrite(w http.ResponseWriter, r *http.Request) {
	user, raw, ok := s.reportGate(w, r, 256<<10)
	if !ok {
		return
	}
	var in reportWriteBody
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	switch in.Op {
	case "add", "edit":
		if in.Params == nil {
			in.Params = []reportParam{}
		}
		if in.Columns == nil {
			in.Columns = []reportColumn{}
		}
		if in.Rules == nil {
			in.Rules = []reportRule{}
		}
		in.TimeoutSecs, in.MaxRows = 30, 5000
		if in.Timeout != nil {
			in.TimeoutSecs = *in.Timeout
		}
		if in.Rows != nil {
			in.MaxRows = *in.Rows
		}
		if err := validReport(&in.reportDef); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
	case "delete", "move", "folder_add", "folder_rename", "folder_delete":
	default:
		writeErr(w, http.StatusBadRequest, errors.New("op must be add, edit, delete, move, folder_add, folder_rename or folder_delete"))
		return
	}
	pay := map[string]any{"op": in.Op, "ui_user": user, "client": clientIP(r), "folder": in.Folder, "new_folder": in.NewFolder}
	if in.Op != "add" {
		pay["report_id"] = in.ID
	}
	if in.Op == "add" || in.Op == "edit" {
		pay["name"], pay["description"], pay["engine"], pay["kind"] = in.Name, in.Description, in.Engine, in.Kind
		pay["body"], pay["params"], pay["columns"], pay["rules"] = in.Body, in.Params, in.Columns, in.Rules
		pay["timeout_secs"], pay["max_rows"], pay["version"] = in.TimeoutSecs, in.MaxRows, in.Version
		if in.Kind == "procedure" {
			pay["body"] = strings.TrimSpace(in.Body)
		}
	}
	b, _ := json.Marshal(pay)
	wctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer cancel()
	var out []byte
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_custom_report($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("custom report: not written", "op", in.Op, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res struct {
		Outcome  string `json:"outcome"`
		Detail   string `json:"detail"`
		ReportID *int64 `json:"report_id"`
		Version  *int   `json:"version"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_custom_report answered %q", out))
		return
	}
	s.log.Info("custom report: write", "op", in.Op, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "report_id": res.ReportID, "version": res.Version}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(o)
}

type reportRunBody struct {
	ReportID   int64              `json:"report_id"`
	Target     string             `json:"target"` // fleet | tag | instance
	InstanceID int                `json:"instance_id"`
	Tag        string             `json:"tag"`
	From       string             `json:"from"`
	To         string             `json:"to"`
	Params     map[string]*string `json:"params"`
}

// runTarget is one instance a run goes to.
type runTarget struct {
	id           int
	name, engine string
}

const sqlRunTargets = `
SELECT i.instance_id, i.name, i.engine
  FROM pgvigil.instances i LEFT JOIN pgvigil.instance_tags_merged m USING (instance_id)
 WHERE i.is_active AND ($1 = 'fleet' OR ($1 = 'instance' AND i.instance_id = $2) OR ($1 = 'tag' AND $3 = ANY (m.tags)))
 ORDER BY i.name`

const maxRunTargets = 20

// runWindow is a run's @from and @to: the body's, or the last hour; at most 31 days.
func runWindow(from, to string) (time.Time, time.Time, error) {
	t1, f1 := time.Now(), time.Now().Add(-time.Hour)
	var err error
	if to != "" {
		if t1, err = time.Parse(time.RFC3339, to); err != nil {
			return f1, t1, errors.New("to is not an RFC 3339 time")
		}
	}
	if from != "" {
		if f1, err = time.Parse(time.RFC3339, from); err != nil {
			return f1, t1, errors.New("from is not an RFC 3339 time")
		}
	} else {
		f1 = t1.Add(-time.Hour)
	}
	if !f1.Before(t1) || t1.Sub(f1) > maxWindow {
		return f1, t1, errors.New("from is before to and the window is at most 31 days")
	}
	return f1, t1, nil
}

// loadReport reads one live report's definition.
func (s *Server) loadReport(ctx context.Context, id int64) (*reportDef, error) {
	var d reportDef
	var params, cols, rules []byte
	var cb, ub string
	var ca, ua time.Time
	var desc *string
	err := s.pool.QueryRow(ctx, sqlCustomReportOne, id).Scan(&d.ID, &d.Name, &desc, &d.Folder, &d.Engine, &d.Kind, &d.Body,
		&params, &cols, &rules, &d.TimeoutSecs, &d.MaxRows, &d.Version, &cb, &ca, &ub, &ua)
	if err != nil {
		return nil, err
	}
	if desc != nil {
		d.Description = *desc
	}
	// a stored definition this server cannot read is not run with the part it cannot read (its parameters as NULL)
	for _, x := range []struct {
		raw  []byte
		into any
		what string
	}{{params, &d.Params, "parameters"}, {cols, &d.Columns, "column formats"}, {rules, &d.Rules, "colour rules"}} {
		if err := json.Unmarshal(x.raw, x.into); err != nil {
			return nil, fmt.Errorf("report %d: its stored %s cannot be read (%v): save it again", id, x.what, err)
		}
	}
	return &d, nil
}

// mayAudit says whether the audit login may write a run's row (0106 migrated, the grant there).
func (s *Server) mayAudit(ctx context.Context) error {
	var may bool
	if err := s.actions.audit.QueryRow(ctx, `SELECT coalesce(has_function_privilege(to_regprocedure('pgvigil.import_custom_report_run(timestamptz, jsonb)'), 'EXECUTE'), false)`).Scan(&may); err != nil {
		return fmt.Errorf("the run's audit cannot be written (%v): nothing was run", err)
	}
	if !may {
		return errors.New("the run's audit cannot be written: the repository has no pgvigil.import_custom_report_run the audit login may call (run 'pgvigil migrate': 0106); nothing was run")
	}
	return nil
}

// The serve's write timeout is 75 s: a run has runBudget, and its audit rows and the answer the rest.
const (
	runBudget   = 62 * time.Second
	auditBudget = 8 * time.Second
)

// auditRun writes one run's row; the run's rows are withheld when it fails. ctx bounds it: the caller's audit budget,
// never the run's own context (it may be spent).
func (s *Server) auditRun(ctx context.Context, row map[string]any) error {
	b, err := json.Marshal(row)
	if err != nil {
		return err
	}
	var id int64
	return s.actions.audit.QueryRow(ctx, `SELECT pgvigil.import_custom_report_run($1, $2::jsonb)`, time.Now(), string(b)).Scan(&id)
}

// refuseRun answers a run refused before anything was sent (a parameter value, the target, a parameter that writes),
// with its audit row: outcome refused, the reason as its detail.
func (s *Server) refuseRun(w http.ResponseWriter, r *http.Request, row map[string]any, why error) {
	row["outcome"], row["detail"] = "refused", why.Error()
	actx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
	defer cancel()
	if err := s.auditRun(actx, row); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%v; the refusal's audit row could not be written: %v", why, err))
		return
	}
	writeErr(w, http.StatusBadRequest, why)
}

// pgDoorDSN is a PostgreSQL instance's monitoring login, "" = none configured here.
func (s *Server) pgDoorDSN(name string) string {
	if s.actions == nil {
		return ""
	}
	return s.actions.doors[name].Monitor
}

// msDoorDSN is a SQL Server instance's read login, "" = none configured here.
func (s *Server) msDoorDSN(name string) string { return s.mssqlDoor().doors[name].Monitor }

// CustomReportRun is POST /api/customreports/run.
func (s *Server) CustomReportRun(w http.ResponseWriter, r *http.Request) {
	user, raw, ok := s.reportGate(w, r, 64<<10)
	if !ok {
		return
	}
	var in reportRunBody
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), runBudget)
	defer cancel()
	if err := s.mayAudit(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err)
		return
	}
	d, err := s.loadReport(ctx, in.ReportID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no report %d", in.ReportID))
		return
	} else if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	refuse := func(err error) {
		s.refuseRun(w, r, map[string]any{"op": "run", "ui_user": user, "client": clientIP(r), "report_id": d.ID, "report_name": d.Name,
			"params": map[string]any{"values": in.Params, "target": in.Target, "tag": in.Tag, "instance_id": in.InstanceID}}, err)
	}
	from, to, err := runWindow(in.From, in.To)
	if err != nil {
		refuse(err)
		return
	}
	// every declared parameter is bound (NULL when empty): a SQL report may name each one; a procedure report passes
	// only those with a value (procCall)
	given := map[string]any{}
	for _, p := range d.Params {
		v, err := paramValue(p, in.Params[p.Name])
		if err != nil {
			refuse(fmt.Errorf("parameter %s %w", p.Name, err))
			return
		}
		given[p.Name] = v
	}
	switch in.Target {
	case "fleet", "tag", "instance":
	default:
		refuse(errors.New("target must be fleet, tag or instance"))
		return
	}
	if in.Target == "fleet" && d.Engine != "store" {
		refuse(fmt.Errorf("a %s report runs on one instance or on a tag's instances, not on the fleet", d.Engine))
		return
	}
	trows, err := s.pool.Query(ctx, sqlRunTargets, in.Target, in.InstanceID, in.Tag)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	targets, err := pgx.CollectRows(trows, func(row pgx.CollectableRow) (runTarget, error) {
		var t runTarget
		return t, row.Scan(&t.id, &t.name, &t.engine)
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	if len(targets) == 0 {
		refuse(errors.New("the target names no active instance"))
		return
	}
	timeout := time.Duration(d.TimeoutSecs) * time.Second
	stmt := d.Body
	if d.Kind == "procedure" {
		stmt = procCall(d.Engine, d.Body, d.Params, given)
	}
	var runs []instanceRun
	ids := make([]int32, 0, len(targets))
	for _, t := range targets {
		ids = append(ids, int32(t.id))
	}
	if d.Engine == "store" {
		args := pgx.NamedArgs{"from": from, "to": to, "instance_ids": ids}
		for k, v := range given {
			args[k] = v
		}
		run := instanceRun{Instance: "store", Engine: "store", Statement: stmt}
		if in.Target == "instance" {
			run.InstanceID = targets[0].id
		}
		t0 := time.Now()
		sets, why, err := runPG(ctx, s.pool.Config().ConnConfig, stmt, args, timeout, d.MaxRows)
		run.finish(t0, sets, why, err)
		runs = append(runs, run)
	} else {
		var mine []runTarget
		var skipped []string
		for _, t := range targets {
			if t.engine == d.Engine {
				mine = append(mine, t)
			} else {
				skipped = append(skipped, t.name)
			}
		}
		if len(mine) == 0 {
			refuse(fmt.Errorf("the target holds no %s instance (it holds %s)", d.Engine, strings.Join(skipped, ", ")))
			return
		}
		if len(mine) > maxRunTargets {
			refuse(fmt.Errorf("the tag holds %d %s instances: a run goes to at most %d", len(mine), d.Engine, maxRunTargets))
			return
		}
		runs = make([]instanceRun, len(mine))
		var wg sync.WaitGroup
		sem := make(chan struct{}, 4)
		for i, t := range mine {
			wg.Add(1)
			go func(i int, t runTarget) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				runs[i] = s.runOnInstance(ctx, d, t, stmt, given, from, to, timeout)
			}(i, t)
		}
		wg.Wait()
	}
	actx, acancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
	defer acancel()
	for _, run := range runs {
		row := map[string]any{"op": "run", "ui_user": user, "client": clientIP(r), "report_id": d.ID, "report_name": d.Name,
			"instance": run.Instance, "outcome": run.Outcome, "detail": run.Error, "rows": run.Rows, "duration_ms": run.DurationMS,
			"statement": run.Statement, "params": map[string]any{"values": in.Params, "from": from, "to": to, "target": in.Target, "tag": in.Tag}}
		if run.InstanceID > 0 {
			row["instance_id"] = run.InstanceID
		}
		if err := s.auditRun(actx, row); err != nil {
			s.log.Error("custom report: the run's audit row was not written", "report", d.ID, "instance", run.Instance, "user", user, "err", err)
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the run's audit row could not be written (%v): its rows are withheld", err))
			return
		}
	}
	s.log.Info("custom report: run", "report", d.ID, "user", user, "target", in.Target, "runs", len(runs))
	s.reply(w, r, struct {
		ReportID int64         `json:"report_id"`
		RanAt    time.Time     `json:"ran_at"`
		From     time.Time     `json:"from"`
		To       time.Time     `json:"to"`
		Runs     []instanceRun `json:"runs"`
	}{d.ID, time.Now().UTC(), from.UTC(), to.UTC(), runs}, nil)
}

// finish fills a run's outcome from what its runner returned.
func (run *instanceRun) finish(t0 time.Time, sets []resultSet, why string, err error) {
	run.DurationMS = int(time.Since(t0).Milliseconds())
	run.Sets = sets
	if run.Sets == nil {
		run.Sets = []resultSet{}
	}
	for _, s := range run.Sets {
		run.Rows += len(s.Rows)
	}
	switch {
	case why != "":
		run.Outcome, run.Error = "refused", why
	case err != nil:
		run.Outcome, run.Error = "failed", err.Error()
	default:
		run.Outcome = "done"
	}
}

// runOnInstance runs a report on one monitored instance through its own login.
func (s *Server) runOnInstance(ctx context.Context, d *reportDef, t runTarget, stmt string, given map[string]any, from, to time.Time, timeout time.Duration) instanceRun {
	run := instanceRun{InstanceID: t.id, Instance: t.name, Engine: t.engine, Statement: stmt}
	t0 := time.Now()
	if t.engine == "sqlserver" {
		dsn := s.msDoorDSN(t.name)
		if dsn == "" {
			run.finish(t0, nil, "instance "+t.name+" has no read login configured on this server", nil)
			return run
		}
		args := []any{sql.Named("from", from), sql.Named("to", to)}
		for _, p := range d.Params {
			if v := given[p.Name]; v != nil || d.Kind == "sql" {
				args = append(args, sql.Named(p.Name, v))
			}
		}
		sets, why, err := runMS(ctx, dsn, stmt, args, timeout, d.MaxRows, true)
		run.finish(t0, sets, why, err)
		return run
	}
	dsn := s.pgDoorDSN(t.name)
	if dsn == "" {
		run.finish(t0, nil, "instance "+t.name+" has no monitoring login configured on this server", nil)
		return run
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		run.finish(t0, nil, "", errors.New("the monitoring dsn does not parse"))
		return run
	}
	args := pgx.NamedArgs{"from": from, "to": to}
	for k, v := range given {
		args[k] = v
	}
	sets, why, err := runPG(ctx, cfg, stmt, args, timeout, d.MaxRows)
	run.finish(t0, sets, why, err)
	return run
}
