package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_errorlog: the SQL Server error log, read forward from a date cursor.
//
// The log is read with the procedures the server ships, one call per log file, never one per search string: the
// lines come back oldest first from the cursor's time and are matched here, on the collector's side, so a line is
// kept once whatever it matched and the monitored server runs no search. The first read goes seven days back.
//
//   - master.dbo.xp_readerrorlog with a start time is the read (EXECUTE on it: sysadmin, or a grant).
//   - sys.sp_readerrorlog is the read when that is refused: it hands over the whole file and the lines before the
//     cursor are passed over here (securityadmin; SQL Server 2022 and later also VIEW SERVER STATE or VIEW ANY
//     ERROR LOG).
//   - rdsadmin.dbo.rds_read_error_log on Amazon RDS, with the same arguments.
//   - The archived files are listed with sys.sp_enumerrorlogs (securityadmin; 2022 and later as above). A login that
//     may not list them reads the current log only, and the reader's state says so.
//   - A login that may read neither is the state "no right": the run is ok and nothing is called failing.
//
// What is kept: a line that matches the match list and is not on the noise list, any error of severity 17 or
// higher, and a line that matches one of the instance's own strings. The server writes an error as two lines (the
// 'Error: n, Severity: s, State: t.' line and the message under it, same time, same process): they are stored as one
// row, the message with its number, severity and state.
//
// The match list and the noise list are those of sp_LogHunter (Darling Data, LLC; MIT), taken as data: the search
// strings of its @custom_message_only = 0 run less two that only repeat what SERVERPROPERTY says ('Microsoft SQL
// Server', 'Server name is'), and the line patterns it deletes after the search. The reader itself is pgvigil's own.
// The licence text stands in migration 0091's header and in docs/sqlserver-readers.md.
//
// Times: the log's dates are the server's local clock without a zone. The instant stored is the local time less the
// server's offset at the read (the house rule, mssql.go); the local time is stored beside it, and the row's key is
// made of the local time, so a line read twice is one row whatever the offset was at each read.

type errorLogCollector struct{}

func init() { Register(errorLogCollector{}) }

func (errorLogCollector) Name() string                   { return Prefix + "errorlog" }
func (errorLogCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

// Timeout: the first read of a busy server's seven days is long; a read that runs out of time goes on next run.
func (errorLogCollector) Timeout() time.Duration { return 2 * time.Minute }

func (errorLogCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database (it has no error log a login can read)"
	}
	return true, ""
}

// Run is not the collection's path: RunOnce sends a BatchCollector to RunBatches.
func (errorLogCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_errorlog reads from a cursor: it runs through the batch path (RunBatches)")
}

// The sources' names in pgvigil.mssql_cursor. The xe reader's own cursors are named after its sessions
// (system_health among them), so these never meet them.
const (
	errorLogSource       = "errorlog"
	errorLogSearchSource = "errorlog:search" // the instance's own search strings (migration 0091)
	defaultTraceSource   = "defaulttrace"
	sysHealthSource      = "syshealth"
)

// The states of a reader (pgvigil.mssql_reader_state).
const (
	readerRead    = "read"
	readerNoRight = "no right"
	readerOff     = "off"
	readerFailed  = "failed"
)

// errorLogFirstRead is how far back the first read of an instance goes.
const errorLogFirstRead = 7 * 24 * time.Hour

// errorLogBatchLines and errorLogBatchScan end a batch: so many kept lines, or so many lines passed over.
var (
	errorLogBatchLines = envInt("PGVIGIL_MSSQL_ERRORLOG_BATCH", 500)
	errorLogBatchScan  = 20000
)

// errorLogTextMax cuts one stored message (characters).
const errorLogTextMax = 4000

// The classes of a kept line, the gravest first: a line takes the first class one of its matches has.
var errorLogClassOrder = []string{"corruption", "memory", "io", "scheduler", "availability", "startup", "config", "general"}

// errorLogMatch is one string of the match list with the class of the lines it finds.
type errorLogMatch struct{ s, class string }

// errorLogMatches is sp_LogHunter's list (see the notice above). The match is a substring match without regard to
// case, as xp_readerrorlog's own search is.
var errorLogMatches = []errorLogMatch{
	// its canaries (things a log always holds), less 'Microsoft SQL Server'
	{"detected", "startup"}, {"SQL Server has encountered", "io"},
	{"Warning: Enterprise Server/CAL license used for this instance", "config"},
	// its search strings, in its order, less 'Server name is'
	{"error", "general"}, {"corrupt", "corruption"}, {"insufficient", "general"}, {"DBCC CHECKDB", "general"},
	{"Attempt to fetch logical page", "corruption"}, {"Total Log Writer threads", "startup"},
	{"Wait for redo catchup for the database", "availability"}, {"Restart the server to resolve this problem", "startup"},
	{"running low", "general"}, {"unexpected", "general"}, {"fail", "general"}, {"contact", "general"}, {"incorrect", "general"},
	{"allocate", "general"}, {"allocation", "general"}, {"Timeout occurred", "general"}, {"memory manager", "memory"},
	{"operating system", "general"}, {"cannot obtain a LOCK resource", "memory"}, {"Server halted", "startup"},
	{"spawn", "scheduler"}, {"BobMgr", "general"}, {"Sort is retrying the read", "io"}, {"service", "general"},
	{"resumed", "availability"}, {"repair the database", "corruption"}, {"buffer", "general"}, {"I/O Completion Port", "general"},
	{"assert", "general"}, {"integrity", "corruption"}, {"latch", "general"}, {"SQL Server is exiting", "startup"},
	{"SQL Server is unable to run", "startup"}, {"suspect", "corruption"}, {"restore the database", "corruption"},
	{"checkpoint", "general"}, {"version store is full", "general"}, {"Setting database option", "config"},
	{"Perform a restore if necessary", "corruption"}, {"Autogrow of file", "io"}, {"Bringing down database", "startup"},
	{"hot add", "startup"}, {"Server shut down", "startup"}, {"stack", "general"}, {"inconsistency.", "corruption"},
	{"invalid", "general"}, {"time out occurred", "general"}, {"The transaction log for database", "general"},
	{"The virtual log file sequence", "general"}, {"Cannot accept virtual log file sequence", "general"},
	{"The transaction in database", "general"}, {"Shutting down", "startup"}, {"thread pool", "scheduler"}, {"debug", "general"},
	{"resolving", "availability"}, {"Cannot load the Query Store metadata", "general"}, {"Cannot acquire", "general"},
	{"SQL Server evaluation period has expired", "startup"}, {"terminat", "general"}, {"currently busy", "general"},
	{"SQL Server has been configured for lightweight pooling", "config"}, {"IOCP", "general"},
	{"Not enough memory for the configured number of locks", "memory"},
	{"The tempdb database data files are not configured with the same initial size and autogrowth settings", "config"},
	{"The SQL Server image", "startup"}, {"affinity", "config"}, {"SQL Server is starting", "startup"},
	{"Ignoring trace flag ", "config"}, {"20 physical cores", "config"}, {"No free space", "io"},
	{"Warning ******************", "startup"}, {"SQL Server should be restarted", "startup"}, {"Could not connect", "availability"},
	{"yielding", "scheduler"}, {"worker thread", "scheduler"}, {"A new connection was rejected", "general"},
	{"A significant part of sql server process memory has been paged out", "memory"}, {"Dispatcher", "general"},
	{"I/O requests taking longer than", "io"}, {"killed", "general"}, {"SQL Server could not start", "startup"},
	{"SQL Server cannot start", "startup"}, {"System Manufacturer:", "startup"}, {"columnstore", "general"},
	{"timed out", "general"}, {"inconsistent", "corruption"}, {"flushcache", "io"},
	{"Recovery for availability database", "availability"},
}

// The noise list: what sp_LogHunter deletes after its search (its LIKE patterns, here as lower-case prefixes, parts,
// whole lines and two patterns with a wildcard inside). Its 'Severity: 1[0-8]' pattern is the error line's own rule
// below: an error under severity 17 is kept only when its message matched.
var (
	errorLogNoisePrefixes = lowerAll([]string{
		"DBCC TRACEON 3604", "DBCC TRACEOFF 3604", "This instance of SQL Server has been using a process ID of",
		"Could not connect because the maximum number of '1' dedicated administrator connections already exists",
		"Login failed", "Backup(", "[INFO]", "[DISK_SPACE_TO_RESERVE_PROPERTY]",
		"[CFabricCommonUtils::GetFabricPropertyInternalWithRef]", "Parallel redo is shutdown for database",
		"Service Broker manager has started.", "Parallel redo is started for database", "Starting up database",
		"Buffer pool extension is already disabled", "The client was unable to reuse a session with", "SSPI",
		"Login succeeded for user",
	})
	errorLogNoiseParts = lowerAll([]string{
		"This is an informational message only. No user action is required.", "SPN", "query notification",
	})
	errorLogNoiseWhole = lowerAll([]string{
		"The Database Mirroring endpoint is in disabled or stopped state.",
		"The Service Broker endpoint is in disabled or stopped state.",
	})
	errorLogNoisePatterns = []*regexp.Regexp{
		regexp.MustCompile(`^checkdb for database .* finished without errors`),
		regexp.MustCompile(`^buffer pool: allocating .* bytes for .* hashpages\.$`),
	}
)

func lowerAll(in []string) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = strings.ToLower(s)
	}
	return out
}

// errorLogNoise says whether a line (lower case) is on the noise list.
func errorLogNoise(lower string) bool {
	for _, p := range errorLogNoisePrefixes {
		if strings.HasPrefix(lower, p) {
			return true
		}
	}
	for _, p := range errorLogNoiseParts {
		if strings.Contains(lower, p) {
			return true
		}
	}
	for _, p := range errorLogNoiseWhole {
		if lower == p {
			return true
		}
	}
	for _, re := range errorLogNoisePatterns {
		if re.MatchString(lower) {
			return true
		}
	}
	return false
}

// errorLogHeader is the line the server writes for an error: alone it is the first of two lines (the message
// follows under the same time and process); with text after the state it is the whole error in one line (the terse
// form, "Error: 802, Severity: 17, State: 2. (Params:). The error is printed in terse mode ..."). A severity of -1
// is the server's own (18052).
var errorLogHeader = regexp.MustCompile(`^Error: (\d{1,10}), Severity: (-?\d{1,3}), State: (\d{1,5})\.?(.*)$`)

// errorLogLone says whether a line is an error's first line, waiting for its message.
func errorLogLone(text string) bool {
	m := errorLogHeader.FindStringSubmatch(text)
	return m != nil && strings.TrimSpace(m[4]) == ""
}

// errorLogOverlap is how far before the cursor every read starts: the log is not always in time order (a server under
// memory pressure has written lines dated up to five minutes before the line above them, measured on SQL Server 2022),
// and xp_readerrorlog with a start time hands over the lines after the last line dated before it, so a read that
// started at the cursor would lose them. What is read again is stored once (the row's key and the import's rule).
const errorLogOverlap = 30 * time.Minute

// errorLogOffsetMark names, in the error log's cursor row, that its file_offset holds the server's offset from UTC
// (minutes) at the read that wrote it.
const errorLogOffsetMark = "offset"

// errorLogLine is one line as the server hands it over: at is the server's local clock, read as if it were UTC.
type errorLogLine struct {
	at      time.Time
	process string
	text    string
	archive int
}

// errorLogSearch is the instance's own search strings: lower-case for the match, as written for the row.
type errorLogSearch struct {
	lower, shown []string
	only         bool
}

// parseErrorLogSearch reads the row of 'errorlog:search': a JSON array of strings in the cursor's file name, and 1
// in its offset for "only these". Anything else is no string at all.
func parseErrorLogSearch(c Cursor) errorLogSearch {
	var out errorLogSearch
	if !c.Found || strings.TrimSpace(c.FileName) == "" {
		return out
	}
	var list []string
	if err := json.Unmarshal([]byte(c.FileName), &list); err != nil {
		return out
	}
	for _, s := range list {
		if s = strings.TrimSpace(s); s != "" && len(out.shown) < 50 {
			out.shown = append(out.shown, s)
			out.lower = append(out.lower, strings.ToLower(s))
		}
	}
	out.only = c.FileOffset == 1 && len(out.shown) > 0
	return out
}

// errorLogVerdict is what the match decided for one line.
type errorLogVerdict struct {
	keep    bool
	matched []string
	custom  bool
	class   string
}

// judgeErrorLogLine decides whether a line is kept. severity is 0 for a line that is no error.
func judgeErrorLogLine(text string, severity int, search errorLogSearch) errorLogVerdict {
	lower := strings.ToLower(text)
	v := errorLogVerdict{class: "general"}
	for i, s := range search.lower {
		if strings.Contains(lower, s) {
			v.matched = append(v.matched, search.shown[i])
			v.custom = true
		}
	}
	rank := len(errorLogClassOrder) - 1
	shipped := false
	if !search.only {
		for _, m := range errorLogMatches {
			if !strings.Contains(lower, strings.ToLower(m.s)) {
				continue
			}
			shipped = true
			v.matched = append(v.matched, m.s)
			for i, c := range errorLogClassOrder {
				if c == m.class && i < rank {
					rank = i
				}
			}
		}
	}
	v.class = errorLogClassOrder[rank]
	// a CHECKDB that found nothing names 'DBCC CHECKDB' and 'error' and is the opposite of corruption
	if strings.Contains(lower, "found 0 errors and repaired 0 errors") {
		v.class = "general"
	}
	// the noise list takes a line the shipped list found; an error of severity 17 or higher and a line the
	// instance's own strings found are kept whatever it says
	v.keep = severity >= 17 || v.custom || (shipped && !errorLogNoise(lower))
	return v
}

// errorLogShred turns the lines of a read into rows: it joins an error's two lines, keys every candidate and keeps
// what the match keeps. offset is the server's local time less UTC.
type errorLogShred struct {
	search  errorLogSearch
	offset  time.Duration
	pending *errorLogLine // an 'Error: ...' line waiting for its message
	keySeen map[string]int
	scanned int64
	kept    int64     // the kept lines newer than the cursor (the overlap read again is not counted)
	after   time.Time // the cursor the read started from, as an instant (zero: the first read)
	newest  time.Time // the newest line passed over, as an instant
}

// localText is the server's local time as the log wrote it, to the millisecond.
func localText(t time.Time) string { return t.Format("2006-01-02T15:04:05.000") }

// key is the row's key: the local time, the process and the text, with a counter for the same line written twice at
// one instant. The counter runs over the whole read (the log is not always in time order, so the lines of one instant
// need not be together); a read starts half an hour before the cursor and so sees every line of an instant it saw
// before: the counter is the same each time.
func (s *errorLogShred) key(at time.Time, process, text string) string {
	if s.keySeen == nil {
		s.keySeen = map[string]int{}
	}
	h := hash16(localText(at) + "|" + process + "|" + text)
	n := s.keySeen[h]
	s.keySeen[h] = n + 1
	return h + "-" + strconv.Itoa(n)
}

// add takes the next line and returns the rows it completes (none, one, or a lone error line and the line itself).
func (s *errorLogShred) add(l errorLogLine) []collect.Row {
	s.scanned++
	if u := l.at.Add(-s.offset); u.After(s.newest) {
		s.newest = u
	}
	var out []collect.Row
	if p := s.pending; p != nil {
		s.pending = nil
		if l.at.Equal(p.at) && l.process == p.process && !errorLogHeader.MatchString(l.text) {
			if row := s.row(l, p); row != nil {
				out = append(out, row)
			}
			return out
		}
		if row := s.row(*p, nil); row != nil { // an error line without its message
			out = append(out, row)
		}
	}
	if errorLogLone(l.text) {
		s.pending = &l
		return out
	}
	if row := s.row(l, nil); row != nil {
		out = append(out, row)
	}
	return out
}

// flush returns the row of an error line still waiting for its message at the end of an archive (its message never
// comes). At the end of the current log the line is dropped instead (drop): the server may not have written its
// message yet, and the next read, which starts before the cursor, reads the two together.
func (s *errorLogShred) drop() { s.pending = nil }

func (s *errorLogShred) flush() []collect.Row {
	p := s.pending
	s.pending = nil
	if p == nil {
		return nil
	}
	if row := s.row(*p, nil); row != nil {
		return []collect.Row{row}
	}
	return nil
}

// row builds the row of a line, with the error line above it when there is one, or nil when it is not kept.
func (s *errorLogShred) row(l errorLogLine, header *errorLogLine) collect.Row {
	var number, severity, state any
	sev := 0
	src := l.text
	if header != nil {
		src = header.text
	}
	if m := errorLogHeader.FindStringSubmatch(src); m != nil {
		n, _ := strconv.ParseInt(m[1], 10, 64)
		sv, _ := strconv.Atoi(m[2])
		st, _ := strconv.Atoi(m[3])
		number, severity, state, sev = n, sv, st, sv
	}
	keyText := l.text
	if header != nil {
		keyText = header.text + "\n" + l.text
	}
	key := s.key(l.at, l.process, keyText) // every candidate takes its place in the count, kept or not
	v := judgeErrorLogLine(l.text, sev, s.search)
	// an error's own line under severity 17 (a first line whose message never came, the terse form) is what
	// sp_LogHunter's 'Severity: 1[0-8]' pattern takes out; a line the instance's own strings found stays
	if header == nil && errorLogHeader.MatchString(l.text) && sev < 17 && !v.custom {
		return nil
	}
	if !v.keep {
		return nil
	}
	inst := l.at.Add(-s.offset)
	if s.after.IsZero() || inst.After(s.after) {
		s.kept++
	}
	text := l.text
	if r := []rune(text); len(r) > errorLogTextMax {
		text = string(r[:errorLogTextMax]) + " ..."
	}
	return collect.Row{"kind": "line", "log_at": inst.UTC().Format(time.RFC3339Nano), "line_key": key,
		"logged_local": localText(l.at), "process": strOrNil(l.process), "error_number": number, "severity": severity,
		"error_state": state, "class": v.class, "matched": v.matched, "custom": v.custom, "archive": l.archive, "message": text}
}

// mssqlErrNumber is the server's error number of an error (0: not a server error).
func mssqlErrNumber(err error) int32 {
	var me mssqldb.Error
	if errors.As(err, &me) {
		return me.Number
	}
	return 0
}

// noRightError says whether the server refused a call for lack of a right: 229 (EXECUTE denied on an object), 15003
// (only members of a role), 27219 (the caller does not have permissions), 8189 (no permission to run a function),
// 297 and 300 (a server permission denied), 15247 (user does not have permission).
func noRightError(err error) bool {
	switch mssqlErrNumber(err) {
	case 229, 15003, 27219, 8189, 297, 300, 15247:
		return true
	}
	return false
}

// errorLogClockSQL: the server's local clock and its offset from UTC in minutes, from one reading of the clock
// (GETDATE and GETUTCDATE are two readings, which a minute's turn can split).
const errorLogClockSQL = `DECLARE @n datetimeoffset = SYSDATETIMEOFFSET();
SELECT CONVERT(varchar(23), CAST(@n AS datetime2(3)), 126) AS local_now, DATEPART(TZOFFSET, @n) AS off_min`

// The reads of one log file. @p1 is the archive (0: the current log), @p2 the start as local time text (ISO 8601).
const (
	errorLogXpSQL = `DECLARE @a int = @p1, @s datetime = CONVERT(datetime, @p2, 126);
EXEC master.dbo.xp_readerrorlog @a, 1, NULL, NULL, @s, NULL, N'asc';`
	// Amazon RDS documents the index and the type only: the whole file comes back and the start is applied here
	errorLogRdsSQL = `DECLARE @a int = @p1;
EXEC rdsadmin.dbo.rds_read_error_log @index = @a, @type = 1;`
	errorLogSpSQL = `DECLARE @a int = @p1;
EXEC sys.sp_readerrorlog @a, 1;`
)

// serverClock reads the server's local now and its offset from UTC.
func serverClock(ctx context.Context, conn *sql.Conn) (localNow time.Time, offset time.Duration, err error) {
	var now string
	var off int64
	if err := conn.QueryRowContext(ctx, errorLogClockSQL).Scan(&now, &off); err != nil {
		return time.Time{}, 0, fmt.Errorf("the server's clock: %w", err)
	}
	t, err := time.Parse("2006-01-02T15:04:05.999", now)
	if err != nil {
		return time.Time{}, 0, fmt.Errorf("the server's clock %q: %w", now, err)
	}
	return t, time.Duration(off) * time.Minute, nil
}

// errorLogStart is where a read starts (the server's local clock) and the cursor's instant the read's count of new
// lines is made from. The first read goes errorLogFirstRead back. After it: the cursor's instant moved back to the
// local clock by the offset of the read that wrote it or by today's, whichever is earlier (after a clock set forward
// the stored offset gives the time the lines were written in; after a clock set back today's reads the hour again),
// less errorLogOverlap.
func errorLogStart(cur Cursor, localNow time.Time, offset time.Duration) (start, after time.Time) {
	if !cur.Found || cur.LastEventAt.IsZero() {
		return localNow.Add(-errorLogFirstRead), time.Time{}
	}
	at := cur.LastEventAt.UTC()
	start = at.Add(offset)
	if cur.FileName == errorLogOffsetMark {
		if s := at.Add(time.Duration(cur.FileOffset) * time.Minute); s.Before(start) {
			start = s
		}
	}
	return start.Add(-errorLogOverlap), at
}

// errorLogArchive is one row of sp_enumerrorlogs.
type errorLogArchive struct {
	n    int
	last time.Time // the file's last write, local, to the minute; zero when the date could not be read
}

// parseArchiveDate reads sp_enumerrorlogs' date ("11/10/2026  01:22").
func parseArchiveDate(s string) time.Time {
	s = strings.Join(strings.Fields(s), " ")
	for _, layout := range []string{"01/02/2006 15:04", "01/02/2006 15:04:05", "2006-01-02 15:04", "2006-01-02 15:04:05"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

// errorLogArchivesFor picks the files a read from start (local) needs, oldest first: the current log always, and an
// archive unless it ended before start. sp_enumerrorlogs gives a file's last write cut to the minute, so a file
// ended up to a minute later than it says (sp_LogHunter's one minute of grace).
func errorLogArchivesFor(all []errorLogArchive, start time.Time) []int {
	seen := map[int]bool{0: true}
	out := []int{0}
	for _, a := range all {
		if a.n <= 0 || seen[a.n] {
			continue
		}
		if !a.last.IsZero() && a.last.Add(time.Minute).Before(start) {
			continue
		}
		seen[a.n] = true
		out = append(out, a.n)
	}
	// the highest number is the oldest file
	for i := 0; i < len(out); i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j] > out[i] {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

func listErrorLogArchives(ctx context.Context, conn *sql.Conn) ([]errorLogArchive, error) {
	rows, err := QueryRows(ctx, conn, `EXEC sys.sp_enumerrorlogs;`)
	if err != nil {
		return nil, err
	}
	var out []errorLogArchive
	for _, r := range rows {
		n, ok := asInt(r["Archive #"])
		if !ok {
			continue
		}
		a := errorLogArchive{n: int(n)}
		if d, ok := r["Date"].(string); ok {
			a.last = parseArchiveDate(d)
		}
		out = append(out, a)
	}
	return out, nil
}

// readerStateRow is the state row of one reader for one read.
func readerStateRow(reader, state, note string) collect.Row {
	return collect.Row{"kind": "state", "reader": reader, "state": state, "note": strOrNil(note)}
}

func instantText(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}

// errorLogNoRightNote is what the state says when no read of the log is allowed.
const errorLogNoRightNote = "the login may not read the error log: it needs EXECUTE on master.dbo.xp_readerrorlog, or the securityadmin role " +
	"(SQL Server 2022 and later: VIEW SERVER STATE or VIEW ANY ERROR LOG is enough) for sys.sp_readerrorlog"

// errorLogCurrentOnlyNote is what the state says when the archives cannot be listed.
const errorLogCurrentOnlyNote = "the login may not list the archived error logs (sys.sp_enumerrorlogs: securityadmin; SQL Server 2022 and later " +
	"also VIEW SERVER STATE or VIEW ANY ERROR LOG): the current log only is read, and lines written between the last read and a " +
	"cycle of the log are not seen"

// RunBatches reads the log files the cursor's time needs, oldest first, and stores the kept lines batch by batch,
// each batch with the cursor moved to the last line it passed over.
func (errorLogCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	localNow, offset, err := serverClock(ctx, conn)
	if err != nil {
		return err
	}
	cur, err := cursor(ctx, errorLogSource)
	if err != nil {
		return err
	}
	searchCur, err := cursor(ctx, errorLogSearchSource)
	if err != nil {
		return err
	}
	search := parseErrorLogSearch(searchCur)
	start, after := errorLogStart(cur, localNow, offset)
	state := readerStateRow(errorLogSource, readerRead, "")
	state["search_count"], state["search_only"] = len(search.shown), search.only
	var notes []string

	// which files: the archives where the login may list them, else the current log
	files, scope := []int{0}, "all archives"
	switch {
	case info.Kind == KindRDS:
		scope = "current log only"
		notes = append(notes, "Amazon RDS: the current log only is read (rdsadmin.dbo.rds_read_error_log)")
	default:
		all, err := listErrorLogArchives(ctx, conn)
		switch {
		case err == nil:
			files = errorLogArchivesFor(all, start)
		case noRightError(err):
			scope = "current log only"
			notes = append(notes, errorLogCurrentOnlyNote)
		default:
			scope = "current log only"
			notes = append(notes, fmt.Sprintf("the archived error logs could not be listed (%v): the current log only is read", err))
		}
	}
	state["scope"] = scope

	sh := &errorLogShred{search: search, offset: offset, after: after}
	nowInstant := localNow.Add(-offset)
	var batch []collect.Row
	sinceEmit := 0
	send := func() error {
		rows := batch
		if !sh.newest.IsZero() {
			// never past the server's now: after a clock set back, the hour read again carries instants an hour ahead
			newest := sh.newest
			if newest.After(nowInstant) {
				newest = nowInstant
			}
			rows = append(rows, Cursor{FileName: errorLogOffsetMark, FileOffset: int64(offset / time.Minute), LastEventAt: newest}.Row(errorLogSource))
		}
		batch, sinceEmit = nil, 0
		if len(rows) == 0 {
			return nil
		}
		if err := emit(rows); err != nil {
			return fmt.Errorf("import a batch of the error log: %w", err)
		}
		return nil
	}
	timeUp := false
	var importErr error // a batch the repository refused: the run's error, never a file's
	take := func(l errorLogLine) error {
		batch = append(batch, sh.add(l)...)
		sinceEmit++
		// a batch never ends between an error's two lines
		if sh.pending == nil && (len(batch) >= errorLogBatchLines || sinceEmit >= errorLogBatchScan) {
			if err := send(); err != nil {
				importErr = err
				return err
			}
		}
		return nil
	}
	// the run's time is looked at on every line the server sends, those passed over too
	stop := func() bool {
		if !timeUp && time.Now().After(opt.Deadline) {
			timeUp = true
		}
		return timeUp
	}

	noRight := false
	for _, n := range files {
		if timeUp {
			break
		}
		err := readErrorLogFile(ctx, conn, info, n, start, take, stop)
		if importErr != nil {
			return importErr
		}
		// an error line without its message: at the end of an archive the message never comes; at the end of the
		// current log, after a fault or when the time is up, the next read takes the two together
		if err == nil && n > 0 && !timeUp {
			batch = append(batch, sh.flush()...)
		} else {
			sh.drop()
		}
		switch {
		case err == nil:
		case errors.Is(err, errErrorLogNoRight):
			noRight = true
		case n > 0 && ctx.Err() == nil:
			// an archive that went away between the listing and the read (a cycle of the log), or one the server
			// cannot open: the others are still read
			notes = append(notes, fmt.Sprintf("archive %d could not be read (%v)", n, err))
		default:
			if serr := send(); serr != nil {
				return serr
			}
			st := readerStateRow(errorLogSource, readerFailed, fmt.Sprintf("the error log could not be read: %v", err))
			st["scope"], st["scanned"], st["stored"] = scope, sh.scanned, sh.kept
			return emit([]collect.Row{st, {"kind": "collector_error", "source": "error log", "message": err.Error()}})
		}
		if noRight {
			break
		}
	}
	if noRight && sh.scanned == 0 {
		st := readerStateRow(errorLogSource, readerNoRight, errorLogNoRightNote)
		st["search_count"], st["search_only"] = len(search.shown), search.only
		return emit([]collect.Row{st})
	}
	sh.drop()
	if timeUp {
		notes = append(notes, "the run's time was up before the log was read to its end: the next run goes on from the cursor"+
			" (without EXECUTE on xp_readerrorlog every read hands over the whole file and passes over what is before the cursor)")
	}
	state["scanned"], state["stored"], state["newest_at"] = sh.scanned, sh.kept, instantText(sh.newest)
	if sh.newest.IsZero() && cur.Found {
		state["newest_at"] = instantText(cur.LastEventAt)
	}
	state["note"] = strOrNil(strings.Join(notes, "; "))
	batch = append(batch, state)
	return send()
}

// errErrorLogNoRight: neither read of a log file is allowed to the login.
var errErrorLogNoRight = errors.New("no right to read the error log")

// readErrorLogFile reads one log file from start (local) and hands its lines over oldest first. stop ends the read
// early (the run's time is up).
func readErrorLogFile(ctx context.Context, conn *sql.Conn, info Info, archive int, start time.Time,
	take func(errorLogLine) error, stop func() bool) error {
	if info.Kind == KindRDS {
		_, err := scanErrorLog(ctx, conn, errorLogRdsSQL, archive, start, take, stop, archive)
		if err != nil && noRightError(err) {
			return errErrorLogNoRight
		}
		return err
	}
	n, err := scanErrorLog(ctx, conn, errorLogXpSQL, archive, time.Time{}, take, stop, archive, localText(start))
	if err == nil || n > 0 || !noRightError(err) {
		return err
	}
	// EXECUTE on the extended procedure is refused: the system procedure hands over the whole file, and the lines
	// before the start are passed over here
	n, err = scanErrorLog(ctx, conn, errorLogSpSQL, archive, start, take, stop, archive)
	if err != nil && n == 0 && noRightError(err) {
		return errErrorLogNoRight
	}
	return err
}

// scanErrorLog runs one read and hands over its lines; from (when set) leaves out the lines before it. It returns
// how many lines the server sent.
func scanErrorLog(ctx context.Context, conn *sql.Conn, query string, archive int, from time.Time,
	take func(errorLogLine) error, stop func() bool, args ...any) (int, error) {
	rs, err := conn.QueryContext(ctx, query, args...)
	if err != nil {
		return 0, err
	}
	defer func() { _ = rs.Close() }()
	n := 0
	var last time.Time
	for rs.Next() {
		var at sql.NullTime
		var process, text sql.NullString
		if err := rs.Scan(&at, &process, &text); err != nil {
			return n, err
		}
		n++
		// a line without a date continues the one above it
		t := last
		if at.Valid {
			t = time.Date(at.Time.Year(), at.Time.Month(), at.Time.Day(), at.Time.Hour(), at.Time.Minute(), at.Time.Second(),
				at.Time.Nanosecond()/int(time.Millisecond)*int(time.Millisecond), time.UTC)
			last = t
		}
		if t.IsZero() || (!from.IsZero() && t.Before(from)) {
			if stop() {
				return n, nil
			}
			continue
		}
		if err := take(errorLogLine{at: t, process: strings.TrimSpace(process.String), text: strings.TrimRight(text.String, " \r\n\t"), archive: archive}); err != nil {
			return n, err
		}
		if stop() {
			return n, nil
		}
	}
	return n, rs.Err()
}
