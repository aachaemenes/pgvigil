// Package dbadash is the DBADash door (task 55): it reads DBADash repositories named in the configuration's dbadash:
// list (a SQL Server database, a read-only login) and stores DBADash's instance list and the statuses of its Summary
// screen in the pgvigil repository. pgvigil collects nothing from SQL Server itself: every row comes from DBADash.
//
// What is read (SELECT only; docs/dbadash.md lists the columns):
//   - dbo.Instances: the active instances (IsActive = 1), Azure SQL databases (EngineEdition 5) left out;
//   - dbo.Summary: the cache DBADash's Summary screen reads through dbo.Summary_Get, its non-Azure rows (IsAzure = 0);
//   - dbo.CollectionDates: the newest SnapshotDate per instance (the last collection);
//   - dbo.DBVersionHistory: the repository's newest version.
//
// dbo.Summary_Get is never executed: when its cache is older than the SummaryCacheDurationSec setting it runs
// dbo.Summary_Upd, a write on the DBADash repository. The rows are as fresh as DBADash's own last refresh (the
// GUI's Summary screen, or the DBADash service's SummaryRefreshCron); refreshed_at says when that was.
// A column a DBADash version does not have is read as absent, never as an error.
package dbadash

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/mssqlopen" // the sqlserver driver (go-mssqldb, BSD-3) and its Entra / Kerberos sign-ins
)

// StatusKeys are dbo.Summary's status columns, in the column order of DBADash's Summary screen (0052's
// dbadash_checks() carries the same list with DBADash's header words).
var StatusKeys = []string{
	"MemoryDumpStatus", "CorruptionStatus", "LastGoodCheckDBStatus", "AlertStatus", "FullBackupStatus", "DiffBackupStatus",
	"LogBackupStatus", "DriveStatus", "JobStatus", "IsAgentRunningStatus", "LogShippingStatus", "MirroringStatus", "AGStatus",
	"LogFreeSpaceStatus", "FileFreeSpaceStatus", "PctMaxSizeStatus", "ElasticPoolStorageStatus", "QueryStoreStatus",
	"CustomCheckStatus", "CollectionErrorStatus", "SnapshotAgeStatus", "DBMailStatus", "IdentityStatus", "DatabaseStateStatus",
	"ServiceBrokerStatus", "UptimeStatus",
}

// DetailKeys are dbo.Summary's other columns pgvigil keeps: the counts, ages, dates and descriptions the Summary
// screen shows in a cell or its tooltip.
var DetailKeys = []string{
	"DetectedCorruptionDateUtc", "CollectionErrorCount", "SnapshotAgeMin", "SnapshotAgeMax", "sqlserver_start_time_utc",
	"sqlserver_uptime", "host_uptime", "MemoryDumpCount", "LastMemoryDumpUTC", "LastGoodCheckDBCriticalCount",
	"LastGoodCheckDBWarningCount", "LastGoodCheckDBHealthyCount", "LastGoodCheckDBNACount", "OldestLastGoodCheckDBTime",
	"DaysSinceLastGoodCheckDB", "LastAlert", "LastCritical", "TotalAlerts", "IsAgentRunning", "DBMailStatusDescription",
	"MaxIdentityPctUsed", "MinIdentityEstimatedDays", "OfflineSince", "LastFail", "ServiceBrokerStatusDescription",
}

// Instance is one DBADash instance with its Summary row (Statuses nil = no dbo.Summary row yet).
type Instance struct {
	InstanceID     int            `json:"instance_id"`
	Instance       string         `json:"instance"`
	ConnectionID   string         `json:"connection_id"`
	DisplayName    string         `json:"display_name"`
	ShowInSummary  *bool          `json:"show_in_summary,omitempty"`
	ProductVersion string         `json:"product_version,omitempty"`
	Edition        string         `json:"edition,omitempty"`
	PausedUntil    *time.Time     `json:"paused_until,omitempty"`
	LastCollection *time.Time     `json:"last_collection,omitempty"`
	RefreshedAt    *time.Time     `json:"refreshed_at,omitempty"`
	Statuses       map[string]int `json:"statuses,omitempty"`
	Details        map[string]any `json:"details,omitempty"`
}

// Payload is one read of one repository: import_dbadash's argument.
type Payload struct {
	Status      string     `json:"status"` // ok | not read
	Reason      string     `json:"reason,omitempty"`
	Version     string     `json:"version,omitempty"`
	RefreshedAt *time.Time `json:"refreshed_at,omitempty"`
	Instances   []Instance `json:"instances"`
}

// NotRead is the payload of a read that did not answer.
func NotRead(reason string) Payload {
	return Payload{Status: "not read", Reason: reason, Instances: []Instance{}}
}

// ReadTimeout bounds one read of one repository.
const ReadTimeout = 60 * time.Second

// Read connects with dsn and reads the repository; an error is the reason for 'not read'.
func Read(ctx context.Context, dsn string) (Payload, error) {
	if strings.TrimSpace(dsn) == "" {
		return Payload{}, errors.New("the dsn resolved to nothing (an unset env: variable or an unreadable file:)")
	}
	ctx, cancel := context.WithTimeout(ctx, ReadTimeout)
	defer cancel()
	db, err := mssqlopen.Open(withAppName(dsn))
	if err != nil {
		return Payload{}, fmt.Errorf("dsn: %w", err)
	}
	defer func() { _ = db.Close() }()
	db.SetMaxOpenConns(1)
	conn, err := db.Conn(ctx)
	if err != nil {
		return Payload{}, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close() }()
	return readConn(ctx, conn)
}

// withAppName names the session "pgvigil-dbadash" on the SQL Server side unless the dsn names one.
func withAppName(dsn string) string {
	l := strings.ToLower(dsn)
	if strings.Contains(l, "app name") || strings.Contains(l, "app+name") || strings.Contains(l, "app%20name") || strings.Contains(l, "application name") {
		return dsn
	}
	if strings.HasPrefix(l, "sqlserver://") {
		if strings.Contains(dsn, "?") {
			return dsn + "&app+name=pgvigil-dbadash"
		}
		return dsn + "?app+name=pgvigil-dbadash"
	}
	if strings.HasPrefix(l, "odbc:") {
		return dsn
	}
	return strings.TrimRight(dsn, "; ") + ";app name=pgvigil-dbadash"
}

func readConn(ctx context.Context, conn *sql.Conn) (Payload, error) {
	cols, err := columns(ctx, conn)
	if err != nil {
		return Payload{}, err
	}
	if len(cols["Instances"]) == 0 {
		return Payload{}, errors.New("no dbo.Instances visible to this login: not a source repository, or the login lacks SELECT on it")
	}
	p := Payload{Status: "ok", Instances: []Instance{}}
	if cols["DBVersionHistory"]["Version"] {
		var v sql.NullString
		if err := conn.QueryRowContext(ctx, `SELECT TOP (1) Version FROM dbo.DBVersionHistory ORDER BY DeployDate DESC`).Scan(&v); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return Payload{}, fmt.Errorf("dbo.DBVersionHistory: %w", err)
		}
		p.Version = v.String
	}
	insts, err := readInstances(ctx, conn, cols)
	if err != nil {
		return Payload{}, err
	}
	sums, err := readSummary(ctx, conn, cols["Summary"])
	if err != nil {
		return Payload{}, err
	}
	for i := range insts {
		if s, ok := sums[insts[i].InstanceID]; ok {
			insts[i].Statuses, insts[i].Details, insts[i].RefreshedAt = s.Statuses, s.Details, s.RefreshedAt
			if s.RefreshedAt != nil && (p.RefreshedAt == nil || s.RefreshedAt.After(*p.RefreshedAt)) {
				t := *s.RefreshedAt
				p.RefreshedAt = &t
			}
		}
	}
	p.Instances = insts
	return p, nil
}

// columns lists the columns of the four tables the door reads, as this login sees them (a table it cannot see has none).
func columns(ctx context.Context, conn *sql.Conn) (map[string]map[string]bool, error) {
	rows, err := conn.QueryContext(ctx, `
SELECT t.name, c.name
  FROM sys.tables t
  JOIN sys.schemas s ON s.schema_id = t.schema_id
  JOIN sys.columns c ON c.object_id = t.object_id
 WHERE s.name = N'dbo' AND t.name IN (N'Instances', N'Summary', N'CollectionDates', N'DBVersionHistory')`)
	if err != nil {
		return nil, fmt.Errorf("sys.columns: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := map[string]map[string]bool{}
	for rows.Next() {
		var t, c string
		if err := rows.Scan(&t, &c); err != nil {
			return nil, err
		}
		if out[t] == nil {
			out[t] = map[string]bool{}
		}
		out[t][c] = true
	}
	return out, rows.Err()
}

func readInstances(ctx context.Context, conn *sql.Conn, cols map[string]map[string]bool) ([]Instance, error) {
	ic := cols["Instances"]
	opt := func(col, expr string) string {
		if ic[col] {
			return expr
		}
		return "NULL"
	}
	display := "I.ConnectionID"
	if ic["Alias"] {
		display = "ISNULL(I.Alias, I.ConnectionID)"
	}
	last := "NULL"
	if cols["CollectionDates"]["SnapshotDate"] {
		last = "(SELECT MAX(C.SnapshotDate) FROM dbo.CollectionDates C WHERE C.InstanceID = I.InstanceID)"
	}
	where := "I.IsActive = 1"
	if ic["EngineEdition"] {
		where += " AND ISNULL(I.EngineEdition, 0) <> 5"
	}
	q := fmt.Sprintf(`
SELECT I.InstanceID, I.Instance, I.ConnectionID, %s, %s, %s, %s, %s, %s
  FROM dbo.Instances I
 WHERE %s
 ORDER BY I.InstanceID`, display, opt("ShowInSummary", "I.ShowInSummary"), opt("ProductVersion", "I.ProductVersion"),
		opt("Edition", "I.Edition"), opt("CollectionsPausedUntil", "I.CollectionsPausedUntil"), last, where)
	rows, err := conn.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("dbo.Instances: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []Instance{}
	for rows.Next() {
		var in Instance
		var conn, disp, ver, ed sql.NullString
		var show sql.NullBool
		var paused, lastAt sql.NullTime
		if err := rows.Scan(&in.InstanceID, &in.Instance, &conn, &disp, &show, &ver, &ed, &paused, &lastAt); err != nil {
			return nil, fmt.Errorf("dbo.Instances: %w", err)
		}
		in.ConnectionID, in.DisplayName, in.ProductVersion, in.Edition = conn.String, disp.String, ver.String, ed.String
		if show.Valid {
			b := show.Bool
			in.ShowInSummary = &b
		}
		in.PausedUntil, in.LastCollection = utcPtr(paused), utcPtr(lastAt)
		out = append(out, in)
	}
	return out, rows.Err()
}

type summaryRow struct {
	Statuses    map[string]int
	Details     map[string]any
	RefreshedAt *time.Time
}

func readSummary(ctx context.Context, conn *sql.Conn, sc map[string]bool) (map[int]summaryRow, error) {
	out := map[int]summaryRow{}
	if !sc["InstanceID"] {
		return out, nil // no dbo.Summary visible: the instances are listed without statuses
	}
	var sel []string
	for _, k := range StatusKeys {
		if sc[k] {
			sel = append(sel, "S."+k)
		}
	}
	for _, k := range DetailKeys {
		if sc[k] {
			sel = append(sel, "S."+k)
		}
	}
	refresh := "NULL"
	if sc["RefreshDate"] {
		refresh = "S.RefreshDate"
	}
	where := ""
	if sc["IsAzure"] {
		where = " WHERE S.IsAzure = 0"
	}
	q := "SELECT S.InstanceID, " + refresh
	if len(sel) > 0 {
		q += ", " + strings.Join(sel, ", ")
	}
	q += " FROM dbo.Summary S" + where
	rows, err := conn.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("dbo.Summary: %w", err)
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		vals := make([]any, 2+len(sel))
		ptrs := make([]any, len(vals))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, fmt.Errorf("dbo.Summary: %w", err)
		}
		id, ok := asInt(vals[0])
		if !ok {
			continue
		}
		r := summaryRow{Statuses: map[string]int{}, Details: map[string]any{}}
		if t, ok := vals[1].(time.Time); ok {
			u := asUTC(t)
			r.RefreshedAt = &u
		}
		for i, col := range sel {
			k := strings.TrimPrefix(col, "S.")
			v := vals[2+i]
			if isStatus(k) {
				if n, ok := asInt(v); ok {
					r.Statuses[k] = n
				}
				continue
			}
			if d := detailValue(v); d != nil {
				r.Details[k] = d
			}
		}
		out[id] = r
	}
	return out, rows.Err()
}

func isStatus(k string) bool {
	for _, s := range StatusKeys {
		if s == k {
			return true
		}
	}
	return false
}

func asInt(v any) (int, bool) {
	switch x := v.(type) {
	case int64:
		return int(x), true
	case int32:
		return int(x), true
	case int:
		return x, true
	case uint8:
		return int(x), true
	case int16:
		return int(x), true
	}
	return 0, false
}

// detailValue makes a Summary value storable as JSON: a date as "YYYY-MM-DD HH:MM:SS" (DBADash keeps UTC), a decimal as
// a number with at most two decimals, the rest as is; NULL is left out.
func detailValue(v any) any {
	switch x := v.(type) {
	case nil:
		return nil
	case time.Time:
		return asUTC(x).Format("2006-01-02 15:04:05")
	case []byte:
		return decimalText(string(x))
	case string:
		return x
	case float64:
		return x
	case bool:
		return x
	}
	if n, ok := asInt(v); ok {
		return n
	}
	return fmt.Sprint(v)
}

// decimalText rounds a decimal's text to two places (MaxIdentityPctUsed is DECIMAL(38,6)).
func decimalText(s string) any {
	r, ok := new(big.Rat).SetString(strings.TrimSpace(s))
	if !ok {
		return s
	}
	f, _ := r.Float64()
	return float64(int64(f*100+sign(f)*0.5)) / 100
}

func sign(f float64) float64 {
	if f < 0 {
		return -1
	}
	return 1
}

// asUTC reads a SQL Server date as UTC: DBADash stores its dates in UTC, and the driver hands a datetime or datetime2
// (no offset) back in time.UTC with its wall clock as stored; a datetimeoffset comes with its offset and is converted.
func asUTC(t time.Time) time.Time { return t.UTC() }

func utcPtr(t sql.NullTime) *time.Time {
	if !t.Valid {
		return nil
	}
	u := asUTC(t.Time)
	return &u
}
