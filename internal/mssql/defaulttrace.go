package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_defaulttrace: the default trace, read forward from a cursor.
//
// SQL Server writes the default trace by itself (five files of 20 MB in its log directory, the oldest deleted at
// rollover) unless someone switched it off. The reader takes from it what a DBA asks the trace: which file grew or
// shrank by itself and how long that took (event classes 92 to 95), which DBCC command ran and who ran it (116), and
// which object was created, dropped or altered (46, 47, 164: the committed event, outside tempdb, statistics and
// security expressions left out). pgvigil's own DBCC calls are left out by the program name.
//
// The cursor is the time and the sequence number of the last event read, and the trace file that was current when
// the read ended: the next read opens that file and the ones after it, not all five. When that file has been rolled
// away the set is read from its oldest file, by the same time.
//
// Needs ALTER TRACE (sys.traces and sys.fn_trace_gettable are refused without it): a login without it is the state
// "no right", never a failure. Not on Azure SQL Database (no default trace).
//
// The ideas of what to read are those of the checks other tools make on the default trace (sp_Blitz's checks 150,
// 151, 199 and 203 to 210, sp_PerfCheck's 5001 to 5003, dbatools' Get-DbaSchemaChangeHistory); the statements are
// pgvigil's own.

type defaultTraceCollector struct{}

func init() { Register(defaultTraceCollector{}) }

func (defaultTraceCollector) Name() string                   { return Prefix + "defaulttrace" }
func (defaultTraceCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

func (defaultTraceCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database (it has no default trace)"
	}
	return true, ""
}

// Run is not the collection's path: RunOnce sends a BatchCollector to RunBatches.
func (defaultTraceCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_defaulttrace reads from a cursor: it runs through the batch path (RunBatches)")
}

// defaultTraceBatch is the most events one batch reads past the cursor.
var defaultTraceBatch = envInt("PGVIGIL_MSSQL_TRACE_BATCH", 2000)

// defaultTraceFirstRead is how far back the first read of an instance goes.
const defaultTraceFirstRead = 7 * 24 * time.Hour

// defaultTraceGateSQL: may the login read the trace, is the trace switched on, and the server's clock.
const defaultTraceGateSQL = `SELECT CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE'), 0) AS int) AS can_read,
  CAST(ISNULL((SELECT TOP (1) CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'default trace enabled'), 0) AS int) AS enabled,
  CONVERT(varchar(23), GETDATE(), 126) AS local_now, DATEDIFF(minute, GETUTCDATE(), GETDATE()) AS off_min`

const defaultTracePathSQL = `SELECT TOP (1) CAST(path AS nvarchar(260)) FROM sys.traces WHERE is_default = 1 AND path IS NOT NULL`

// defaultTraceOldestSQL: the first event of the file set, which is its oldest (the function reads the files in order).
const defaultTraceOldestSQL = `SELECT TOP (1) CONVERT(varchar(23), StartTime, 126) FROM sys.fn_trace_gettable(@p1, DEFAULT) WHERE StartTime IS NOT NULL`

// defaultTraceReadSQL reads at most @p4 events past the cursor: @p1 the file to start at, @p2 the cursor's time as
// the server's local time (ISO 8601), @p3 its sequence number. TextData is the DBCC command's text.
const defaultTraceReadSQL = `DECLARE @s datetime = CONVERT(datetime, @p2, 126);
SELECT TOP (@p4) CAST(t.EventClass AS int) AS event_class, CONVERT(varchar(23), t.StartTime, 126) AS local_at,
  CAST(ISNULL(t.EventSequence, 0) AS bigint) AS seq, CAST(t.Duration AS bigint) AS duration_us, CAST(t.IntegerData AS bigint) AS pages,
  CAST(t.DatabaseName AS nvarchar(128)) AS database_name, CAST(t.FileName AS nvarchar(260)) AS file_name,
  CAST(COALESCE(t.SessionLoginName, t.LoginName) AS nvarchar(128)) AS login_name, CAST(t.HostName AS nvarchar(128)) AS host_name,
  CAST(t.ApplicationName AS nvarchar(256)) AS program_name, CAST(t.SPID AS int) AS session_id,
  CAST(t.ObjectName AS nvarchar(256)) AS object_name, CAST(v.subclass_name AS nvarchar(128)) AS object_type,
  CAST(t.TextData AS nvarchar(4000)) AS text_data
FROM sys.fn_trace_gettable(@p1, DEFAULT) t
LEFT JOIN sys.trace_subclass_values v ON v.trace_event_id = t.EventClass AND v.trace_column_id = 28 AND v.subclass_value = t.ObjectType
WHERE (t.StartTime > @s OR (t.StartTime = @s AND ISNULL(t.EventSequence, 0) > @p3))
  AND (t.EventClass IN (92, 93, 94, 95)
       OR (t.EventClass = 116 AND ISNULL(t.ApplicationName, N'') <> N'pgvigil')
       OR (t.EventClass IN (46, 47, 164) AND t.EventSubClass = 1 AND ISNULL(t.DatabaseID, 0) <> 2
           AND ISNULL(t.ObjectType, 0) NOT IN (21587, 17747)))
ORDER BY t.StartTime, t.EventSequence`

// traceKinds names the event classes the reader stores.
var traceKinds = map[int64]string{92: "data growth", 93: "log growth", 94: "data shrink", 95: "log shrink", 116: "dbcc",
	46: "ddl", 47: "ddl", 164: "ddl"}

var traceDDL = map[int64]string{46: "create", 47: "drop", 164: "alter"}

var (
	dbccName       = regexp.MustCompile(`^\s*DBCC\s+([A-Z_]+)`)
	dbccPlanHandle = regexp.MustCompile(`FREEPROCCACHE\s*\(\s*(0X|@)`)
	dbccSpace      = regexp.MustCompile(`\s+`)
)

// dbccCommand names the command of a DBCC event's text: the ones a DBA wants to know about by their own name (a
// FREEPROCCACHE with a plan handle evicts one plan and is told apart from the one that empties the cache; SQLPERF
// with CLEAR is the one that resets the wait or latch statistics), any other by its first word.
func dbccCommand(text string) string {
	u := strings.ToUpper(dbccSpace.ReplaceAllString(strings.TrimSpace(text), " "))
	switch {
	case strings.Contains(u, "FREEPROCCACHE"):
		if dbccPlanHandle.MatchString(u) {
			return "DBCC FREEPROCCACHE (plan handle)"
		}
		return "DBCC FREEPROCCACHE"
	case strings.Contains(u, "FREESYSTEMCACHE"):
		return "DBCC FREESYSTEMCACHE"
	case strings.Contains(u, "DROPCLEANBUFFERS"):
		return "DBCC DROPCLEANBUFFERS"
	case strings.Contains(u, "SHRINKDATABASE"):
		return "DBCC SHRINKDATABASE"
	case strings.Contains(u, "SHRINKFILE"):
		return "DBCC SHRINKFILE"
	case strings.Contains(u, "WRITEPAGE"):
		return "DBCC WRITEPAGE"
	case strings.Contains(u, "SQLPERF") && strings.Contains(u, "CLEAR"):
		return "DBCC SQLPERF (CLEAR)"
	}
	if m := dbccName.FindStringSubmatch(u); m != nil {
		return "DBCC " + m[1]
	}
	return "DBCC"
}

// traceBasePath turns the trace file written now (.../log_12.trc) into the name that reads the whole set
// (.../log.trc); the separator is the path's own (a server on Linux writes /).
func traceBasePath(current string) string {
	i := strings.LastIndexAny(current, `\/`)
	if i < 0 {
		return ""
	}
	return current[:i+1] + "log.trc"
}

// traceRow turns one row of the read into the payload's row. offset is the server's local time less UTC.
func traceRow(r collect.Row, offset time.Duration) (collect.Row, time.Time, int64, bool) {
	class, ok := asInt(r["event_class"])
	kind := traceKinds[class]
	local, _ := r["local_at"].(string)
	at, err := time.Parse("2006-01-02T15:04:05.999", local)
	if !ok || kind == "" || err != nil {
		return nil, time.Time{}, 0, false
	}
	seq, _ := asInt(r["seq"])
	spid, _ := asInt(r["session_id"])
	out := collect.Row{"kind": "trace", "trace_kind": kind, "event_class": class,
		"event_at": at.Add(-offset).UTC().Format(time.RFC3339Nano), "logged_local": localText(at),
		"event_key":     hash16(localText(at) + "|" + strconv.FormatInt(seq, 10) + "|" + strconv.FormatInt(class, 10) + "|" + strconv.FormatInt(spid, 10)),
		"database_name": r["database_name"], "login_name": r["login_name"], "host_name": r["host_name"],
		"program_name": r["program_name"], "session_id": r["session_id"]}
	switch kind {
	case "dbcc":
		text, _ := r["text_data"].(string)
		out["sub"], out["statement"] = dbccCommand(text), strOrNil(text)
	case "ddl":
		out["sub"], out["object_name"], out["object_type"] = traceDDL[class], r["object_name"], r["object_type"]
	default:
		out["file_name"], out["duration_us"], out["pages"] = r["file_name"], r["duration_us"], r["pages"]
	}
	return out, at, seq, true
}

// RunBatches reads the trace past its cursor in batches, each stored with the cursor moved.
func (defaultTraceCollector) RunBatches(ctx context.Context, conn *sql.Conn, _ Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	var canRead, enabled, offMin int64
	var now string
	if err := conn.QueryRowContext(ctx, defaultTraceGateSQL).Scan(&canRead, &enabled, &now, &offMin); err != nil {
		return fmt.Errorf("the default trace's settings: %w", err)
	}
	localNow, err := time.Parse("2006-01-02T15:04:05.999", now)
	if err != nil {
		return fmt.Errorf("the server's clock %q: %w", now, err)
	}
	offset := time.Duration(offMin) * time.Minute
	if enabled == 0 {
		return emit([]collect.Row{readerStateRow(defaultTraceSource, readerOff,
			"the default trace is switched off (sp_configure 'default trace enabled' is 0): file growths, shrinks, DBCC commands and DDL are not recorded on this server")})
	}
	if canRead == 0 {
		return emit([]collect.Row{readerStateRow(defaultTraceSource, readerNoRight,
			"the login lacks ALTER TRACE: sys.traces and sys.fn_trace_gettable are refused without it")})
	}
	failed := func(what string, err error) error {
		return emit([]collect.Row{readerStateRow(defaultTraceSource, readerFailed, fmt.Sprintf("%s: %v", what, err)),
			{"kind": "collector_error", "source": "default trace", "message": err.Error()}})
	}
	var path sql.NullString
	switch err := conn.QueryRowContext(ctx, defaultTracePathSQL).Scan(&path); {
	case errors.Is(err, sql.ErrNoRows) || (err == nil && strings.TrimSpace(path.String) == ""):
		return emit([]collect.Row{readerStateRow(defaultTraceSource, readerOff,
			"the default trace is enabled and no default trace is running (sys.traces lists none): a restart of the server starts it")})
	case err != nil && noRightError(err):
		return emit([]collect.Row{readerStateRow(defaultTraceSource, readerNoRight, "the login may not read sys.traces: "+err.Error())})
	case err != nil:
		return failed("the default trace's file could not be found", err)
	}
	base := traceBasePath(path.String)
	if base == "" {
		return failed("the default trace's file has an unexpected name", errors.New(path.String))
	}
	cur, err := cursor(ctx, defaultTraceSource)
	if err != nil {
		return err
	}
	startAt, startSeq, file := localNow.Add(-defaultTraceFirstRead), int64(0), base
	if cur.Found && !cur.LastEventAt.IsZero() {
		startAt, startSeq = cur.LastEventAt.UTC().Add(offset), cur.LastSeq
		if cur.FileName != "" {
			file = cur.FileName
		}
	}
	state := readerStateRow(defaultTraceSource, readerRead, "")
	var notes []string
	var scanned int64
	newest := cur.LastEventAt
	for {
		rows, err := QueryRows(ctx, conn, defaultTraceReadSQL, file, localText(startAt), startSeq, defaultTraceBatch)
		if err != nil && file != base && ctx.Err() == nil {
			// the file the cursor names was rolled away: the whole set, by the same time
			notes = append(notes, fmt.Sprintf("the cursor's file %s could not be read (%v): the trace was read again from its oldest file, by event time", file, err))
			file = base
			continue
		}
		if err != nil && noRightError(err) {
			return emit([]collect.Row{readerStateRow(defaultTraceSource, readerNoRight, "the login may not read the default trace: "+err.Error())})
		}
		if err != nil {
			return failed("the default trace could not be read", err)
		}
		if len(rows) == 0 {
			break
		}
		batch := make([]collect.Row, 0, len(rows)+1)
		for _, r := range rows {
			row, at, seq, ok := traceRow(r, offset)
			if !ok {
				continue
			}
			batch = append(batch, row)
			startAt, startSeq = at, seq
		}
		scanned += int64(len(rows))
		if len(batch) == 0 {
			// rows the reader cannot place would be read again for ever: the cursor stays and the state says so
			notes = append(notes, fmt.Sprintf("%d event(s) past the cursor could not be read as events: the cursor was not moved", len(rows)))
			break
		}
		newest = startAt.Add(-offset)
		caughtUp := len(rows) < defaultTraceBatch
		// a read that reached the end leaves the file written now as the next read's start
		next := Cursor{FileName: file, LastEventAt: newest, LastSeq: startSeq}
		if caughtUp {
			next.FileName = path.String
		}
		batch = append(batch, next.Row(defaultTraceSource))
		if err := emit(batch); err != nil {
			return fmt.Errorf("import a batch of the default trace: %w", err)
		}
		if caughtUp {
			break
		}
		if time.Now().After(opt.Deadline) {
			notes = append(notes, "the run's time was up before the trace was read to its end: the next run goes on from the cursor")
			break
		}
	}
	var oldest sql.NullString
	if err := conn.QueryRowContext(ctx, defaultTraceOldestSQL, base).Scan(&oldest); err == nil && oldest.Valid {
		if t, perr := time.Parse("2006-01-02T15:04:05.999", oldest.String); perr == nil {
			state["oldest_at"] = instantText(t.Add(-offset))
		}
	} else if err != nil && !errors.Is(err, sql.ErrNoRows) {
		notes = append(notes, fmt.Sprintf("the trace's oldest event was not read (%v)", err))
	}
	state["scanned"], state["stored"], state["newest_at"] = scanned, scanned, instantText(newest)
	state["note"] = strOrNil(strings.Join(notes, "; "))
	return emit([]collect.Row{state})
}
