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
	"strconv"
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
	var hist []deploy
	if cols["DBVersionHistory"]["Version"] {
		var err error
		if hist, err = readVersions(ctx, conn); err != nil {
			return Payload{}, err
		}
		if len(hist) > 0 {
			p.Version = hist[0].Version
		}
	}
	insts, err := readInstances(ctx, conn, cols)
	if err != nil {
		return Payload{}, err
	}
	// the run rows are read only where the login may SELECT them: a table it sees (VIEW DEFINITION) without that right
	// would fail the whole Summary read
	runs := false
	if cols["CollectionRunStatus"]["InstanceID"] {
		var can sql.NullInt64
		if err := conn.QueryRowContext(ctx, `SELECT HAS_PERMS_BY_NAME(N'dbo.CollectionRunStatus', N'OBJECT', N'SELECT')`).Scan(&can); err != nil {
			return Payload{}, fmt.Errorf("dbo.CollectionRunStatus' SELECT right: %w", err)
		}
		runs = can.Valid && can.Int64 == 1
	}
	sums, err := readSummary(ctx, conn, cols["Summary"], runs)
	if err != nil {
		return Payload{}, err
	}
	since := healthSince(hist)
	for id, s := range sums {
		healthDetail(s.Details, s.RefreshedAt, since, runs)
		sums[id] = s
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

// deploy is one row of dbo.DBVersionHistory: a DBA Dash version and when it was deployed (UTC: GETUTCDATE()).
type deploy struct {
	Version string
	At      time.Time
}

// readVersions reads dbo.DBVersionHistory, the newest deploy first.
func readVersions(ctx context.Context, conn *sql.Conn) ([]deploy, error) {
	rows, err := conn.QueryContext(ctx, `SELECT Version, DeployDate FROM dbo.DBVersionHistory ORDER BY DeployDate DESC`)
	if err != nil {
		return nil, fmt.Errorf("dbo.DBVersionHistory: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []deploy
	for rows.Next() {
		var v sql.NullString
		var at sql.NullTime
		if err := rows.Scan(&v, &at); err != nil {
			return nil, fmt.Errorf("dbo.DBVersionHistory: %w", err)
		}
		out = append(out, deploy{Version: v.String, At: asUTC(at.Time)})
	}
	return out, rows.Err()
}

// HealthVersion says whether a DBA Dash version is 4.25.0 or later, the release whose Summary_Upd counts collection
// health (0138's dbadash_health_version, the same rule: dot-separated digits compared part by part; anything else no).
func HealthVersion(v string) bool {
	parts := strings.Split(strings.TrimSpace(v), ".")
	want := []int{4, 25}
	nums := make([]int, len(parts))
	for i, s := range parts {
		if s == "" || len(s) > 9 || strings.Trim(s, "0123456789") != "" {
			return false
		}
		nums[i], _ = strconv.Atoi(s)
	}
	for i := 0; i < len(want); i++ {
		if i >= len(nums) {
			return false
		}
		if nums[i] != want[i] {
			return nums[i] > want[i]
		}
	}
	return true
}

// healthSince is when the repository became the DBA Dash release it is now, if that is 4.25.0 or later: the deploy of
// the oldest row in the newest unbroken run of such versions (nil: the repository is older, or has no history).
func healthSince(hist []deploy) *time.Time {
	var since *time.Time
	for i := range hist {
		if !HealthVersion(hist[i].Version) {
			break
		}
		t := hist[i].At
		since = &t
	}
	return since
}

// healthDetail sets the detail HealthKey of one Summary row to what DBA Dash's Summary_Upd used for its
// CollectionErrorCount when it last wrote the row: true (collections at warning or critical) only on a repository at
// 4.25.0 or later whose row was written after that deploy and whose instance has run rows; false (the errors of 24
// hours) for a row written before the deploy or an instance without runs; "unknown" (0138 shows the bare count) when the
// login may not read the run rows; none on an older repository. Not known even so: an instance's first run after its
// row was last written by 4.25.0 (the row says 24 h errors until DBA Dash's next refresh; docs/dbadash.md).
func healthDetail(d map[string]any, refreshed, since *time.Time, runs bool) {
	switch {
	case since == nil:
		delete(d, HealthKey)
	case refreshed == nil || refreshed.Before(*since):
		d[HealthKey] = false
	case !runs:
		d[HealthKey] = "unknown"
	default:
		if v, _ := d[HealthKey].(bool); !v {
			d[HealthKey] = false
		}
	}
}

// columns lists the columns of the five tables the door reads, as this login sees them (a table it cannot see has none).
func columns(ctx context.Context, conn *sql.Conn) (map[string]map[string]bool, error) {
	rows, err := conn.QueryContext(ctx, `
SELECT t.name, c.name
  FROM sys.tables t
  JOIN sys.schemas s ON s.schema_id = t.schema_id
  JOIN sys.columns c ON c.object_id = t.object_id
 WHERE s.name = N'dbo' AND t.name IN (N'Instances', N'Summary', N'CollectionDates', N'DBVersionHistory', N'CollectionRunStatus')`)
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

// HealthKey is the detail pgvigil adds to a Summary row of a repository at DBA Dash 4.25.0 or later (healthDetail): true
// when the instance has run rows in dbo.CollectionRunStatus (new in 4.25.0) and its row was written by 4.25.0 or later.
// DBA Dash's Summary_Upd (4.25.0 L279-280) then fills CollectionErrorStatus from the instance's collection health and
// CollectionErrorCount with its collections at warning or critical; without them (a service older than 4.25.0 collects
// it) both keep the errors of 24 hours. The door's words for that cell follow it (0138's dbadash_detail).
const HealthKey = "CollectionHealth"

func readSummary(ctx context.Context, conn *sql.Conn, sc map[string]bool, runStatus bool) (map[int]summaryRow, error) {
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
	if runStatus {
		sel = append(sel, "CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.CollectionRunStatus R WHERE R.InstanceID = S.InstanceID) THEN 1 ELSE 0 END AS bit) AS "+HealthKey)
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
			if strings.HasSuffix(col, " AS "+HealthKey) {
				k = HealthKey
			}
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
