// Package savetable holds the checks of Save Table's write door (task 7b): the identifiers, the one quoted form of
// the target, the system targets a table is never written into, and the column types with their conversions. The
// route (internal/web/savetable.go) runs them before any connection is opened.
//
// RED STUB: every body below answers as if nothing were checked; task 7b's build replaces each one. The rows in
// savetable_test.go fail on it, each in its own words.
package savetable

// The two engines, as pgvigil.instances.engine names them.
const (
	Postgres  = "postgres"
	SQLServer = "sqlserver"
)

// Schema is the one schema a table is written into: the door login's own (design B2 rec; 'ASK LEAD: PGRID 7B FOLD').
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
