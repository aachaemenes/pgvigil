// Package savetable holds the checks of Save Table's write door (task 7b): the identifiers, the one quoted form of
// the target, the system targets a table is never written into, and the column types with their conversions. The
// route (internal/web/savetable.go) runs them before any connection is opened.
//
// RED STUB: every body below answers as if nothing were checked; task 7b's build replaces each one. The rows in
// savetable_test.go fail on it, each in its own words.
package savetable

import (
	"context"
	"io"
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

// CheckName refuses an identifier with words naming the field and the reason; nil = it is quoted, never refused for
// its characters.
func CheckName(engine, field, name string) error { return nil }

// CheckColumns refuses an empty column list, a repeated name (case-insensitively on SQL Server) and any name
// CheckName refuses.
func CheckColumns(engine string, names []string) error { return nil }

// QuoteIdent quotes one name: PostgreSQL in double quotes with '"' doubled, SQL Server in brackets with ']' doubled.
func QuoteIdent(engine, name string) string { return name }

// Quoted is the ONE quoted form of the target, used everywhere - the CREATE, the bulk copy and the existence read
// (bound, never spliced): PostgreSQL "schema"."table" (the connection names the database), SQL Server
// [database].[schema].[table].
func Quoted(engine string, t Target) string { return "" }

// Database is what the monitoring read knows of one database.
type Database struct {
	Name          string
	ID            int  // SQL Server database_id
	IsTemplate    bool // PostgreSQL datistemplate
	IsDistributor bool // SQL Server is_distributor
}

// RefuseDatabase is the words that refuse a system or template database as a target, or "" when it may take a table.
func RefuseDatabase(engine string, d Database) string { return "" }

// ColumnType is the engine's type for one of the browser's closed list of kinds (int, dec, time, day, text, bool).
func ColumnType(engine, kind string) (string, error) { return "", nil }

// Convert turns one decoded JSON cell (a json.Number, a string, a bool or nil) into the value the driver binds for
// kind. Its error names the row and the column, never the value (any logged-in user reads the audit).
func Convert(engine, kind string, row int, column string, v any) (any, error) { return v, nil }

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
func OffWords(on bool, in Instance) string { return "" }

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

// Decode reads a body with UseNumber, refusing - before the rest is read - more rows or cells than lim allows, more
// columns than the engine allows (SQL Server 1,024, PostgreSQL 1,600) or a row whose length is not the columns'.
func Decode(r io.Reader, engine string, lim Limits) (Body, error) { return Body{}, nil }

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
}

// Verdict is Check's answer: Outcome "" = every gate passed (write the started row, then the table); else
// "refused" or "failed" with its words. Row says whether the attempt writes an audit row.
type Verdict struct {
	Outcome, Words string
	Row            bool
	Target         string // the one quoted form, once the identifiers passed
}

// Check runs the gates from the instance's door on, in the design's order (5 the list and the login, 6 the typed
// confirmation '<instance>/<database>', 7 the identifiers, the database and the kinds, 8 the login checks and the
// schema on the writing connection, 9 the table's existence). open is called only once gates 5-7 pass.
func Check(ctx context.Context, in Instance, dbs []Database, b Body, open func(ctx context.Context) (mon, act Conn, err error)) Verdict {
	return Verdict{}
}
