package dbadash

// The DBADash pages (task 75): pgvigil's own pages over DBADash's stored procedures. Each page is ONE call of one
// DBADash procedure, made when the page is opened, through the repository's read login, with the parameters DBADash's
// GUI passes for one instance; every result set the procedure returns comes back as a grid (its columns in the
// procedure's order, its rows as the procedure returned them). pgvigil keeps nothing of a page: DBADash's repository
// is the store, as it is for DBADash's GUI.
//
// The procedures are the contract: they are named here for DBADash 4.24.1, the version proven (scripts/
// proof-dbadash-door.sh). A repository of another version is still read, and the reply says 'not proven on <v>';
// a procedure whose signature changed fails with SQL Server's own message, shown on the page.
//
// Read only: every procedure below is a dbo.*_Get that writes nothing (each was read in DBADash 4.24.1's source:
// no INSERT, UPDATE, DELETE or MERGE on a permanent table, no _Upd procedure called). dbo.Summary_Get is NOT among
// them: it runs dbo.Summary_Upd when its cache is old (the Summary page reads the dbo.Summary table instead, read.go).
// Four of them build their statement as dynamic SQL, which runs with the caller's own rights: the read login needs
// SELECT on the dbo schema beside EXECUTE on these procedures (docs/dbadash.md has the grants).

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// ProvenVersion is the DBADash version the pages and the import are proven on.
const ProvenVersion = "4.24.1"

// Proven says whether a repository's DBVersionHistory version is the proven one (4.24.1 or a build of it, 4.24.1.x).
func Proven(v string) bool {
	v = strings.TrimSpace(v)
	return v == ProvenVersion || strings.HasPrefix(v, ProvenVersion+".")
}

// PageDef is one page: its key in the URL, DBADash's own name for the screen, the procedure and how it is called.
type PageDef struct {
	Key       string `json:"key"`
	Title     string `json:"title"`
	Procedure string `json:"procedure"`
	// Window says the procedure takes the page's time range.
	Window bool `json:"window"`
	// Snapshot says the procedure takes one running-queries snapshot time (the sessions page; none = the latest).
	Snapshot bool `json:"snapshot,omitempty"`
	args     func(a PageArgs) []any
}

// PageArgs are a page call's inputs: the DBADash InstanceID, the time range (UTC) and, for the sessions page, the
// snapshot time (UTC; zero = the latest snapshot).
type PageArgs struct {
	InstanceID int
	From, To   time.Time
	Snapshot   time.Time
}

// idsRow is one row of DBADash's table type dbo.IDs (ID INT NOT NULL PRIMARY KEY).
type idsRow struct{ ID int32 }

func ids(id int) mssql.TVP { return mssql.TVP{TypeName: "dbo.IDs", Value: []idsRow{{ID: int32(id)}}} }

// every status the GUI's status filter offers, ticked: the grid of one instance as DBADash shows it with nothing
// filtered out
func allStatuses() []any {
	return []any{sql.Named("IncludeCritical", true), sql.Named("IncludeWarning", true), sql.Named("IncludeNA", true), sql.Named("IncludeOK", true)}
}

// utc2 sends a time as DBADash keeps its dates: UTC, no offset (a datetime2 parameter)
func utc2(t time.Time) mssql.DateTime1 { return mssql.DateTime1(t.UTC()) }

// Pages are the pages in the order of task 75 (the Summary first: the task-55 read of dbo.Summary, not a procedure).
var Pages = []PageDef{
	{Key: "performance", Title: "Performance Summary", Procedure: "dbo.PerformanceSummary_Get", Window: true, args: func(a PageArgs) []any {
		return []any{sql.Named("InstanceIDs", fmt.Sprint(a.InstanceID)), sql.Named("FromDate", utc2(a.From)), sql.Named("ToDate", utc2(a.To)),
			sql.Named("ShowHidden", true)}
	}},
	{Key: "running", Title: "Running Queries", Procedure: "dbo.RunningQueriesSummary_Get", Window: true, args: func(a PageArgs) []any {
		return []any{sql.Named("InstanceID", a.InstanceID), sql.Named("FromDate", utc2(a.From)), sql.Named("ToDate", utc2(a.To)), sql.Named("MaxRows", 2000)}
	}},
	{Key: "sessions", Title: "Running Queries (snapshot)", Procedure: "dbo.RunningQueries_Get", Snapshot: true, args: func(a PageArgs) []any {
		out := []any{sql.Named("InstanceID", a.InstanceID)}
		if !a.Snapshot.IsZero() {
			s := mssql.DateTime1(a.Snapshot.UTC())
			out = append(out, sql.Named("SnapshotDateFrom", s), sql.Named("SnapshotDateTo", s))
		}
		return out
	}},
	{Key: "backups", Title: "Backups", Procedure: "dbo.BackupReport_Get", args: func(a PageArgs) []any {
		return append([]any{sql.Named("InstanceIDs", ids(a.InstanceID))}, append(allStatuses(), sql.Named("ShowHidden", true))...)
	}},
	{Key: "jobs", Title: "Agent Jobs", Procedure: "dbo.AgentJobsReport_Get", args: func(a PageArgs) []any {
		return append([]any{sql.Named("InstanceIDs", ids(a.InstanceID))}, append(allStatuses(), sql.Named("IncludeACK", true), sql.Named("ShowHidden", true))...)
	}},
	{Key: "drives", Title: "Drives", Procedure: "dbo.DrivesReport_Get", args: func(a PageArgs) []any {
		return append([]any{sql.Named("InstanceIDs", ids(a.InstanceID))}, append(allStatuses(), sql.Named("ShowHidden", true))...)
	}},
	{Key: "dbfiles", Title: "DB Space", Procedure: "dbo.DBFilesReport_Get", args: func(a PageArgs) []any {
		return append([]any{sql.Named("InstanceIDs", ids(a.InstanceID))}, append(allStatuses(), sql.Named("FilegroupLevel", true), sql.Named("ShowHidden", true))...)
	}},
	{Key: "configuration", Title: "Configuration", Procedure: "dbo.Configuration_Get", args: func(a PageArgs) []any {
		return []any{sql.Named("InstanceIDs", fmt.Sprint(a.InstanceID)), sql.Named("ShowHidden", true)}
	}},
	{Key: "alerts", Title: "SQL Agent Alerts", Procedure: "dbo.Alerts_Get", args: func(a PageArgs) []any {
		return []any{sql.Named("InstanceIDs", fmt.Sprint(a.InstanceID)), sql.Named("ShowHidden", true)}
	}},
}

// PageByKey finds a page; ok false for a key not in Pages.
func PageByKey(k string) (PageDef, bool) {
	for _, p := range Pages {
		if p.Key == k {
			return p, true
		}
	}
	return PageDef{}, false
}

// Procedures lists the procedures the pages call (the grants of docs/dbadash.md, the proof's).
func Procedures() []string {
	out := make([]string, 0, len(Pages))
	for _, p := range Pages {
		out = append(out, p.Procedure)
	}
	return out
}

// Column is one column of a result set: its name and SQL Server type.
type Column struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// ResultSet is one grid: the columns and the rows (a value per column: a number, a string, true / false or null).
type ResultSet struct {
	Columns   []Column `json:"columns"`
	Rows      [][]any  `json:"rows"`
	Truncated bool     `json:"truncated,omitempty"`
}

// PageReply is one page call.
type PageReply struct {
	Page      string      `json:"page"`
	Title     string      `json:"title"`
	Procedure string      `json:"procedure"`
	Version   string      `json:"version"`
	Proven    bool        `json:"proven"`
	Note      string      `json:"note,omitempty"`
	Results   []ResultSet `json:"results"`
	Millis    int64       `json:"ms"`
}

// MaxPageRows caps one result set (DBADash's own RunningQueriesSummary_Get stops at 2000).
const MaxPageRows = 5000

// PageTimeout bounds one page call.
const PageTimeout = 60 * time.Second

// ErrNoRepository is a page asked of a repository the configuration does not name.
var ErrNoRepository = errors.New("no DBADash repository of that name in the configuration")

var (
	reposMu sync.RWMutex
	repos   = map[string]config.DBADashRepo{}
)

// SetRepositories gives the serve process the configured repositories (the pages connect with their dsn). serve
// calls it once after it reads the configuration; an empty list leaves every page with ErrNoRepository.
func SetRepositories(list []config.DBADashRepo) {
	m := make(map[string]config.DBADashRepo, len(list))
	for _, r := range list {
		m[strings.ToLower(r.Name)] = r
	}
	reposMu.Lock()
	repos = m
	reposMu.Unlock()
}

// repository finds a configured repository by name (case-insensitive, the configuration's rule).
func repository(name string) (config.DBADashRepo, bool) {
	reposMu.RLock()
	defer reposMu.RUnlock()
	r, ok := repos[strings.ToLower(name)]
	return r, ok
}

// Page calls one page's procedure for one instance of a configured repository.
func Page(ctx context.Context, repo, page string, a PageArgs) (PageReply, error) {
	r, ok := repository(repo)
	if !ok {
		return PageReply{}, ErrNoRepository
	}
	return PageDSN(ctx, r.DSN(), page, a)
}

// PageDSN calls one page's procedure through dsn (Page's work; the proof calls it with the dsn it built).
func PageDSN(ctx context.Context, dsn, page string, a PageArgs) (PageReply, error) {
	def, ok := PageByKey(page)
	if !ok {
		return PageReply{}, fmt.Errorf("unknown DBADash page %q", page)
	}
	if a.InstanceID <= 0 {
		return PageReply{}, errors.New("a page needs a DBADash InstanceID")
	}
	if def.Window && (a.From.IsZero() || a.To.IsZero() || !a.From.Before(a.To)) {
		return PageReply{}, errors.New("the page needs a time range (from before to)")
	}
	if strings.TrimSpace(dsn) == "" {
		return PageReply{}, errors.New("the dsn resolved to nothing (an unset env: variable or an unreadable file:)")
	}
	ctx, cancel := context.WithTimeout(ctx, PageTimeout)
	defer cancel()
	db, err := sql.Open("sqlserver", withAppName(dsn))
	if err != nil {
		return PageReply{}, fmt.Errorf("dsn: %w", err)
	}
	defer func() { _ = db.Close() }()
	db.SetMaxOpenConns(1)
	conn, err := db.Conn(ctx)
	if err != nil {
		return PageReply{}, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close() }()
	out := PageReply{Page: def.Key, Title: def.Title, Procedure: def.Procedure, Results: []ResultSet{}}
	if err := conn.QueryRowContext(ctx, `SELECT TOP (1) Version FROM dbo.DBVersionHistory ORDER BY DeployDate DESC`).Scan(&out.Version); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return PageReply{}, fmt.Errorf("dbo.DBVersionHistory: %w", err)
	}
	out.Proven = Proven(out.Version)
	if !out.Proven {
		out.Note = fmt.Sprintf("not proven on DBADash %s: the pages are proven on %s", orNone(out.Version), ProvenVersion)
	}
	start := time.Now()
	rs, err := callProc(ctx, conn, def.Procedure, def.args(a))
	out.Millis = time.Since(start).Milliseconds()
	if err != nil {
		return out, fmt.Errorf("%s: %w", def.Procedure, err)
	}
	out.Results = rs
	return out, nil
}

func orNone(v string) string {
	if strings.TrimSpace(v) == "" {
		return "(no version row)"
	}
	return v
}

// callProc runs a procedure by its name (an RPC call: go-mssqldb sends a bare procedure name with named arguments as
// one) and reads every result set it returns.
func callProc(ctx context.Context, conn *sql.Conn, proc string, args []any) ([]ResultSet, error) {
	rows, err := conn.QueryContext(ctx, proc, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := []ResultSet{}
	for {
		rs, err := readSet(rows)
		if err != nil {
			return nil, err
		}
		if rs != nil {
			out = append(out, *rs)
		}
		if !rows.NextResultSet() {
			break
		}
	}
	return out, rows.Err()
}

// readSet reads the current result set; nil when it has no columns (a statement that returned no rows set).
func readSet(rows *sql.Rows) (*ResultSet, error) {
	cts, err := rows.ColumnTypes()
	if err != nil {
		return nil, err
	}
	if len(cts) == 0 {
		for rows.Next() {
		}
		return nil, nil
	}
	rs := &ResultSet{Columns: make([]Column, len(cts)), Rows: [][]any{}}
	for i, c := range cts {
		rs.Columns[i] = Column{Name: c.Name(), Type: strings.ToUpper(c.DatabaseTypeName())}
	}
	for rows.Next() {
		vals := make([]any, len(cts))
		ptrs := make([]any, len(cts))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		if len(rs.Rows) >= MaxPageRows {
			rs.Truncated = true
			continue
		}
		row := make([]any, len(vals))
		for i, v := range vals {
			row[i] = cellValue(rs.Columns[i].Type, v)
		}
		rs.Rows = append(rs.Rows, row)
	}
	return rs, rows.Err()
}

// cellValue makes a SQL Server value a JSON value without losing it: a decimal or money as its exact text, a date as
// "YYYY-MM-DD HH:MM:SS.fffffff" trimmed to its precision (DBADash keeps UTC: the wall clock as stored), a
// uniqueidentifier in its usual form, binary as 0x hex, the rest as the driver reads it.
func cellValue(typ string, v any) any {
	switch x := v.(type) {
	case nil:
		return nil
	case time.Time:
		if typ == "DATETIMEOFFSET" {
			return x.Format("2006-01-02 15:04:05.9999999 -07:00")
		}
		if typ == "DATE" {
			return x.Format("2006-01-02")
		}
		if typ == "TIME" {
			return x.Format("15:04:05.9999999")
		}
		return x.Format("2006-01-02 15:04:05.9999999")
	case []byte:
		switch typ {
		case "UNIQUEIDENTIFIER":
			var u mssql.UniqueIdentifier
			if err := u.Scan(x); err == nil {
				return u.String()
			}
		case "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY":
			return string(x)
		}
		return "0x" + strings.ToUpper(hex.EncodeToString(x))
	}
	return v
}
