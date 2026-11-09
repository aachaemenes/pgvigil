package collect

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/logparse"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// serverlogCollector reads the on-prem server log (the stderr files of the logging collector) for the same
// events as the CloudWatch reader: slow statements, lock waits, deadlocks and failed logins. It lists the log
// directory with pg_ls_logdir() (pg_monitor) and reads the files through one of two doors the client's DBA
// opens for the monitoring login (the opt-in):
//
//   - the narrow door (preferred): a superuser-owned SECURITY DEFINER function pgvigil_read_log(text, bigint,
//     bigint) in any schema of the monitored database that serves only the names pg_ls_logdir() lists
//     (serverlogDoorSQL is its text);
//   - the wide door: GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean).
//     It opens every file under the data directory (pg_hba.conf, server.key, the pg_authid heap with the
//     password hashes) as well as an absolute log_directory (PostgreSQL 18, proof-slow.sh sections A, H, I).
//
// pg_read_server_files alone opens neither (the function stays superuser-only). With no door the run is
// skipped with that reason. Each run reads from the stored cursor minus
// the CloudWatch reader's overlap: the files written since then, each from the first line at or after that
// time (a binary search over the file), so a re-read event is dropped by the repository's event key. Every
// line is rewritten from the server's log_line_prefix into the RDS prefix and classified by internal/logparse.
type serverlogCollector struct{}

func init() { Register(serverlogCollector{}) }

const (
	serverlogChunk    = 4 << 20  // bytes per pg_read_binary_file call
	serverlogMaxBytes = 64 << 20 // per run; the rest is read on the next run
	serverlogProbe    = 64 << 10 // bytes read per binary-search probe
)

// serverlogReadFn names the function the wide door grants, as has_function_privilege takes it.
const serverlogReadFn = "pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)"

// serverlogDoorSQL is the narrow door the client's DBA creates as a superuser in the monitored database (the
// schema is free; the reader finds it by name, argument types, owner and SECURITY DEFINER).
const serverlogDoorSQL = `CREATE FUNCTION public.pgvigil_read_log(p_name text, p_offset bigint, p_length bigint) RETURNS bytea
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT pg_read_binary_file(current_setting('log_directory') || '/' || p_name, p_offset, p_length, true)
   WHERE p_name IN (SELECT name FROM pg_ls_logdir())
$$;
REVOKE ALL ON FUNCTION public.pgvigil_read_log(text, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pgvigil_read_log(text, bigint, bigint) TO <login>;`

// serverlogDoorFind returns the narrow door the login may run, schema-qualified, or NULL.
const serverlogDoorFind = `
SELECT format('%I.%I', n.nspname, p.proname)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_roles r ON r.oid = p.proowner
 WHERE p.proname = 'pgvigil_read_log' AND p.prosecdef AND r.rolsuper
   AND p.proargtypes = '25 20 20'::oidvector AND p.prorettype = 'bytea'::regtype
   AND has_function_privilege(p.oid, 'EXECUTE')
 ORDER BY n.nspname
 LIMIT 1`

func (serverlogCollector) Name() string                   { return "serverlog" }
func (serverlogCollector) DefaultInterval() time.Duration { return time.Minute }
func (serverlogCollector) Applies(info platform.Info) (bool, string) {
	if info.Kind == platform.OnPrem {
		return true, ""
	}
	return false, "the server-log file reader covers on-prem servers; RDS and Aurora are read from CloudWatch (the logs collection)"
}

func (serverlogCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("serverlog needs its cursor: %w", ErrSkip)
}

// logFile is one entry of pg_ls_logdir().
type logFile struct {
	Name     string
	Size     int64
	Modified time.Time
}

// logDir is the door to the log directory: the server in production, a recorded set in tests.
type logDir interface {
	List(ctx context.Context) ([]logFile, error)
	// Read returns up to n bytes of a file from off; nil, nil when the file is gone (rotated away).
	Read(ctx context.Context, name string, off, n int64) ([]byte, error)
}

// pgLogDir reads through the monitored connection.
type pgLogDir struct {
	conn *pgx.Conn
	dir  string // log_directory: relative to the data directory or absolute
	door string // the narrow door, schema-qualified and quoted from the catalog; "" = the wide door
}

func (d pgLogDir) List(ctx context.Context) ([]logFile, error) {
	rows, err := d.conn.Query(ctx, `SELECT name, size, modification FROM pg_ls_logdir()`)
	if err != nil {
		return nil, fmt.Errorf("pg_ls_logdir: %w", err)
	}
	defer rows.Close()
	var out []logFile
	for rows.Next() {
		var f logFile
		if err := rows.Scan(&f.Name, &f.Size, &f.Modified); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func (d pgLogDir) Read(ctx context.Context, name string, off, n int64) ([]byte, error) {
	var b []byte
	var err error
	if d.door != "" { // the name comes from the catalog through format('%I.%I'), never from input
		err = d.conn.QueryRow(ctx, `SELECT `+d.door+`($1, $2, $3)`, name, off, n).Scan(&b)
	} else {
		err = d.conn.QueryRow(ctx, `SELECT pg_read_binary_file($1, $2, $3, true)`, strings.TrimRight(d.dir, "/")+"/"+name, off, n).Scan(&b)
	}
	if err != nil {
		return nil, fmt.Errorf("pg_read_binary_file %s: %w", name, err)
	}
	return b, nil
}

// serverlogSettings is what the reader needs from the server before it reads.
type serverlogSettings struct {
	Collector, Destination, Directory, Prefix, TimeZone string
	Door                                                string // the narrow door, "" when there is none
	CanList, CanRead                                    bool   // CanRead: the wide door
}

// check returns the reason the reader cannot run on these settings, or "".
func (s serverlogSettings) check() string {
	switch {
	case s.Collector != "on":
		return "logging_collector is off: the server log is not in files the server can list"
	case !hasDest(s.Destination, "stderr"):
		return fmt.Sprintf("log_destination is %q: the reader reads the stderr files (csvlog and jsonlog not so far)", s.Destination)
	case !s.CanList:
		return "the monitoring login may not run pg_ls_logdir() (GRANT pg_monitor TO <login>)"
	case s.Door == "" && !s.CanRead:
		return "the monitoring login may not read the log files: the client DBA's opt-in is the function pgvigil_read_log " +
			"(SECURITY DEFINER, serves only the log files; its text is in the README), or the wide door GRANT EXECUTE ON FUNCTION " +
			serverlogReadFn + " TO <login>, which also opens every file under the data directory (pg_hba.conf, server.key, " +
			"pg_authid's password hashes); pg_read_server_files alone opens neither"
	}
	return ""
}

func hasDest(dest, want string) bool {
	for _, d := range strings.Split(dest, ",") {
		if strings.TrimSpace(d) == want {
			return true
		}
	}
	return false
}

func (serverlogCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, _ config.Instance, cursor CursorFunc) ([]Row, error) {
	var s serverlogSettings
	err := conn.QueryRow(ctx, `
SELECT current_setting('logging_collector'), current_setting('log_destination'), current_setting('log_directory'),
       current_setting('log_line_prefix'), current_setting('log_timezone'),
       has_function_privilege('pg_catalog.pg_ls_logdir()', 'EXECUTE'),
       has_function_privilege($1, 'EXECUTE'), coalesce((`+serverlogDoorFind+`), '')`, serverlogReadFn).
		Scan(&s.Collector, &s.Destination, &s.Directory, &s.Prefix, &s.TimeZone, &s.CanList, &s.CanRead, &s.Door)
	if err != nil {
		return nil, fmt.Errorf("serverlog settings: %w", err)
	}
	if why := s.check(); why != "" {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	lp, err := compilePrefix(s.Prefix)
	if err != nil {
		return nil, fmt.Errorf("%v: %w", err, ErrSkip)
	}
	z, err := serverZone(ctx, conn, s.TimeZone)
	if err != nil {
		return nil, err
	}
	source := "serverlog:" + s.Directory
	from := time.Now().Add(-logsFirstRead)
	if t, ok, err := cursor(ctx, source); err != nil {
		return nil, err
	} else if ok {
		from = t.Add(-logsOverlap)
	}
	return serverlogRows(ctx, pgLogDir{conn: conn, dir: s.Directory, door: s.Door}, lp, z, source, from, serverlogMaxBytes)
}

// serverlogRows reads the stderr files written since from, oldest first, up to maxBytes, and returns the event
// rows plus one cursor row. The cursor is the time of the newest line read (the files are written one after
// the other, so there is no slower stream to wait for); a run that hit maxBytes puts it one overlap past its
// last line, so the next run starts at that line instead of re-reading the same bytes for ever. A single line
// longer than maxBytes is not read: the cursor goes past it to the next line (a stated limit: its event is lost).
// Lines whose time zone cannot be read are dropped, and a collector_error row says so (the run ends 'partial').
func serverlogRows(ctx context.Context, dir logDir, lp *linePrefix, z *logZone, source string, from time.Time, maxBytes int64) ([]Row, error) {
	files, err := dir.List(ctx)
	if err != nil {
		return nil, err
	}
	sort.Slice(files, func(i, j int) bool {
		if !files[i].Modified.Equal(files[j].Modified) {
			return files[i].Modified.Before(files[j].Modified)
		}
		return files[i].Name < files[j].Name
	})
	var rows []Row
	var last, skipTo time.Time
	budget, full := maxBytes, false
	z.misses = 0
	for _, f := range files {
		if strings.HasSuffix(f.Name, ".csv") || strings.HasSuffix(f.Name, ".json") || f.Modified.Add(time.Second).Before(from) || f.Size == 0 {
			// pg_ls_logdir's modification has whole seconds: a file closed in from's own second is read
			continue
		}
		if budget <= 0 {
			full = true
			break
		}
		start, err := seekTime(ctx, dir, lp, z, f, from)
		if err != nil {
			return nil, err
		}
		if start >= f.Size {
			continue
		}
		end := f.Size
		if end-start > budget {
			end, full = start+budget, true
		}
		buf, err := readRange(ctx, dir, f.Name, start, end)
		if err != nil {
			return nil, err
		}
		budget -= int64(len(buf))
		if i := bytes.LastIndexByte(buf, '\n'); i >= 0 { // a line still being written is read next run
			buf = buf[:i+1]
		} else {
			buf = nil
		}
		text, newest := lp.rewrite(strings.ToValidUTF8(string(buf), "�"), z)
		if newest.After(last) {
			last = newest
		}
		if full && !newest.After(from) && end < f.Size { // no progress: one line longer than the budget, go past it
			_, t, ok, err := nextLine(ctx, dir, lp, z, f, end)
			if err != nil {
				return nil, err
			}
			if ok {
				skipTo = t
			}
		}
		parsed, _ := logparse.ParseIn(strings.NewReader(text), time.UTC) // rewrite writes UTC times
		for _, p := range parsed {
			sum := md5.Sum([]byte(string(p.Kind) + "\x00" + f.Name + "\x00" + p.Key))
			rows = append(rows, Row{
				"kind": "event", "kind_of": string(p.Kind), "at": p.At.UTC(), "pid": p.PID, "client": p.Client,
				"usename": p.User, "datname": p.Database, "duration_ms": nilIfZero(p.DurationMS),
				"statement": nilIfEmpty(maskText(p.Statement)), "detail": nilIfEmpty(maskText(p.Detail)),
				"source": source + ":" + f.Name, "event_key": hex.EncodeToString(sum[:]),
			})
		}
		if full {
			break
		}
	}
	readTo := from
	switch {
	case full && !skipTo.IsZero(): // past a line longer than the budget: the next run starts at the line after it
		readTo = skipTo.Add(logsOverlap)
	case full && !last.IsZero():
		readTo = last.Add(logsOverlap)
	case last.After(from):
		readTo = last
	}
	if z.misses > 0 {
		rows = append(rows, Row{"kind": "collector_error", "source": "serverlog", "message": fmt.Sprintf(
			"%d log lines skipped: their time zone is neither one the collector can load (log_timezone %q) nor an abbreviation of pg_timezone_abbrevs", z.misses, z.name)})
	}
	rows = append(rows, Row{"kind": "cursor", "source": source, "read_to": readTo.UTC()})
	return rows, nil
}

// readRange reads [start, end) of a file in chunks; a file gone mid-read returns what was read.
func readRange(ctx context.Context, dir logDir, name string, start, end int64) ([]byte, error) {
	var out []byte
	for off := start; off < end; {
		n := min(int64(serverlogChunk), end-off)
		b, err := dir.Read(ctx, name, off, n)
		if err != nil {
			return nil, err
		}
		if len(b) == 0 {
			break
		}
		out = append(out, b...)
		off += int64(len(b))
	}
	return out, nil
}

// seekTime returns the offset of the first line of f written at or after from (f.Size when there is none): a
// binary search over the file (a log file is written in time order) to within a probe, then a walk forward
// line by line. The walk reads past a line written before from however long it is, so a line longer than the
// run's budget is never the start of the next read.
func seekTime(ctx context.Context, dir logDir, lp *linePrefix, z *logZone, f logFile, from time.Time) (int64, error) {
	lo, hi := int64(0), f.Size
	for hi-lo > serverlogProbe {
		mid := lo + (hi-lo)/2
		_, t, ok, err := nextLine(ctx, dir, lp, z, f, mid)
		if err != nil {
			return 0, err
		}
		if ok && t.Before(from) {
			lo = mid // the first line after mid is older: so is every line before it
		} else {
			hi = mid
		}
	}
	for off := lo; off < f.Size; {
		start, t, ok, err := nextLine(ctx, dir, lp, z, f, off)
		if err != nil || !ok {
			return f.Size, err
		}
		if !t.Before(from) {
			return start, nil
		}
		off = start + 1
	}
	return f.Size, nil
}

// nextLine finds the first line with a prefix that starts at or after off (at off itself only when off is 0 or
// follows a newline the caller knows of: off 0), reading forward a probe at a time; false when the file ends
// first. A line is matched on its first probe's worth of text, which holds its prefix.
func nextLine(ctx context.Context, dir logDir, lp *linePrefix, z *logZone, f logFile, off int64) (int64, time.Time, bool, error) {
	atStart := off == 0
	for off < f.Size {
		b, err := dir.Read(ctx, f.Name, off, serverlogProbe)
		if err != nil || len(b) == 0 {
			return 0, time.Time{}, false, err
		}
		i := 0
		if !atStart {
			j := bytes.IndexByte(b, '\n')
			if j < 0 { // the whole probe is inside one line
				off += int64(len(b))
				continue
			}
			i = j + 1
		}
		atStart = false
		cut := false
		for i < len(b) {
			e := bytes.IndexByte(b[i:], '\n')
			if e < 0 && i > 0 { // a line cut by the probe's end: read it again from its start
				off, atStart, cut = off+int64(i), true, true
				break
			}
			line := b[i:]
			if e >= 0 {
				line = b[i : i+e]
			}
			if m := lp.re.FindStringSubmatch(strings.TrimRight(string(line), "\r")); m != nil {
				if t, ok := lp.timeOf(m, z); ok {
					return off + int64(i), t, true, nil
				}
			}
			if e < 0 {
				break
			}
			i += e + 1
		}
		if !cut {
			off += int64(len(b))
		}
	}
	return 0, time.Time{}, false, nil
}

// logZone reads the times of the log: the server's log_timezone where the collector can load it (a zone
// abbreviation of the line picks the side of a DST change), else the server's pg_timezone_abbrevs.
type logZone struct {
	name    string
	loc     *time.Location // nil when log_timezone is not a zone the collector can load ("localtime", a POSIX rule)
	abbrevs map[string]int // abbreviation -> UTC offset in seconds
	misses  int            // lines whose time could not be read, this run
}

func serverZone(ctx context.Context, conn *pgx.Conn, name string) (*logZone, error) {
	z := &logZone{name: name, abbrevs: map[string]int{}}
	if l, err := time.LoadLocation(name); err == nil {
		z.loc = l
	}
	rows, err := conn.Query(ctx, `SELECT abbrev, extract(epoch FROM utc_offset)::int FROM pg_timezone_abbrevs`)
	if err != nil {
		return nil, fmt.Errorf("pg_timezone_abbrevs: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var a string
		var off int
		if err := rows.Scan(&a, &off); err != nil {
			return nil, err
		}
		z.abbrevs[a] = off
	}
	return z, rows.Err()
}

// parse reads a time text (no zone) written in the zone abbreviation abbr.
func (z *logZone) parse(layout, text, abbr string) (time.Time, bool) {
	if abbr == "UTC" || abbr == "GMT" {
		t, err := time.ParseInLocation(layout, text, time.UTC)
		return t, err == nil
	}
	if m := zoneOffsetRE.FindStringSubmatch(abbr); m != nil {
		h, _ := strconv.Atoi(m[2])
		mi, _ := strconv.Atoi(m[3])
		off := h*3600 + mi*60
		if m[1] == "-" {
			off = -off
		}
		t, err := time.ParseInLocation(layout, text, time.FixedZone(abbr, off))
		return t, err == nil
	}
	if z.loc != nil {
		t, err := time.ParseInLocation(layout, text, z.loc)
		if err != nil {
			return time.Time{}, false
		}
		if n, _ := t.Zone(); n == abbr {
			return t, true
		}
		for _, d := range []time.Duration{-time.Hour, time.Hour} { // the repeated hour of a DST change
			if u := t.Add(d); u.Format(layout) == text {
				if n, _ := u.Zone(); n == abbr {
					return u, true
				}
			}
		}
		if _, ok := z.abbrevs[abbr]; !ok {
			return t, true // an abbreviation neither knows: the zone's own reading
		}
	}
	if off, ok := z.abbrevs[abbr]; ok {
		t, err := time.ParseInLocation(layout, text, time.FixedZone(abbr, off))
		return t, err == nil
	}
	z.misses++
	return time.Time{}, false
}

// fixedZone is a logZone of one location (tests).
func fixedZone(loc *time.Location) *logZone {
	return &logZone{name: loc.String(), loc: loc, abbrevs: map[string]int{}}
}

// linePrefix matches a server's log_line_prefix and rewrites its lines into the RDS prefix
// '%t:%r:%u@%d:[%p]:' that logparse reads.
type linePrefix struct {
	re                                 *regexp.Regexp
	tm, epoch, pid, user, db, rem, hst int // submatch indexes; 0 = not in the prefix
	level, msg                         int
}

// logLevels are the severities a stderr line carries after its prefix.
const logLevels = `DEBUG[1-5]?|INFO|NOTICE|WARNING|ERROR|LOG|FATAL|PANIC|DETAIL|HINT|QUERY|CONTEXT|LOCATION|STATEMENT`

var errPrefix = errors.New("log_line_prefix")

// compilePrefix turns a log_line_prefix into a matcher. It needs a time (%m, %t or %n) and the pid (%p):
// without them the lines of one entry cannot be put together or placed in time, and the reader says so.
func compilePrefix(p string) (*linePrefix, error) {
	lp := &linePrefix{}
	var b strings.Builder
	b.WriteString("^")
	group, optional := 0, false
	capture := func(dst *int, pat string) {
		if *dst != 0 { // a repeated escape matches again without capturing
			b.WriteString("(?:" + pat + ")")
			return
		}
		group++
		*dst = group
		b.WriteString("(" + pat + ")")
	}
	for i := 0; i < len(p); i++ {
		if p[i] != '%' || i+1 >= len(p) {
			b.WriteString(regexp.QuoteMeta(p[i : i+1]))
			continue
		}
		i++
		padded := false
		for i < len(p) && (p[i] == '-' || p[i] >= '0' && p[i] <= '9') { // padding: %-10u
			i, padded = i+1, true
		}
		if i >= len(p) {
			break
		}
		if padded { // the value is padded with spaces on one side
			b.WriteString(` *`)
		}
		const stamp = `\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}`
		switch p[i] {
		case 'm':
			capture(&lp.tm, stamp+`\.\d{3} \S+`)
		case 't':
			capture(&lp.tm, stamp+` \S+`)
		case 'n':
			capture(&lp.epoch, `\d+\.\d+`)
		case 'p':
			capture(&lp.pid, `\d+`)
		case 'u':
			capture(&lp.user, `.*?`)
		case 'd':
			capture(&lp.db, `.*?`)
		case 'r':
			capture(&lp.rem, `\[local\]|\S*?\(\d+\)|`)
		case 'h':
			capture(&lp.hst, `\S*`)
		case 's':
			b.WriteString(stamp + ` \S+`)
		case 'P', 'l', 'x':
			b.WriteString(`\d*`)
		case 'Q':
			b.WriteString(`-?\d*`)
		case 'c':
			b.WriteString(`[0-9a-f]*\.?[0-9a-f]*`)
		case 'e':
			b.WriteString(`[0-9A-Z]{5}`)
		case 'v', 'L':
			b.WriteString(`\S*`)
		case 'q':
			if !optional { // the rest is printed only by session processes
				b.WriteString("(?:")
				optional = true
			}
		case '%':
			b.WriteString("%")
		default: // %a, %b, %i and any escape a later release adds
			b.WriteString(`.*?`)
		}
		if padded {
			b.WriteString(` *`)
		}
	}
	if optional {
		b.WriteString(")?")
	}
	group += 2
	lp.level, lp.msg = group-1, group
	b.WriteString(`(` + logLevels + `):\s+(.*)$`)
	if lp.tm == 0 && lp.epoch == 0 {
		return nil, fmt.Errorf("%w %q has no time (%%m, %%t or %%n): the reader cannot place its lines", errPrefix, p)
	}
	if lp.pid == 0 {
		return nil, fmt.Errorf("%w %q has no %%p: the reader cannot join an entry's lines", errPrefix, p)
	}
	re, err := regexp.Compile(b.String())
	if err != nil {
		return nil, fmt.Errorf("%w %q: %v", errPrefix, p, err)
	}
	lp.re = re
	return lp, nil
}

func sub(m []string, i int) string {
	if i == 0 || i >= len(m) {
		return ""
	}
	return strings.TrimSpace(m[i])
}

// timeOf reads a matched line's time: %m / %t through the zone (logZone.parse), %n as Unix seconds.
func (lp *linePrefix) timeOf(m []string, z *logZone) (time.Time, bool) {
	if lp.tm != 0 {
		v := sub(m, lp.tm)
		sp := strings.LastIndexByte(v, ' ')
		if sp < 0 {
			return time.Time{}, false
		}
		layout := "2006-01-02 15:04:05"
		if strings.Contains(v[:sp], ".") {
			layout += ".000"
		}
		return z.parse(layout, v[:sp], v[sp+1:])
	}
	f, err := strconv.ParseFloat(sub(m, lp.epoch), 64)
	if err != nil {
		return time.Time{}, false
	}
	sec := int64(f)
	return time.Unix(sec, int64((f-float64(sec))*1e9)).UTC(), true
}

var zoneOffsetRE = regexp.MustCompile(`^([+-])(\d{2})(\d{2})?$`)


// rewrite turns the lines of a stderr log into the RDS prefix shape with the time in UTC (so logparse reads
// it without the server's zone, and a re-read line keeps its key), keeping the tab-led continuation lines and
// dropping lines that match neither and lines whose time zone it cannot read (with their continuation lines;
// logZone counts them); it returns the text and the newest line time it read.
func (lp *linePrefix) rewrite(text string, z *logZone) (string, time.Time) {
	var b strings.Builder
	var newest time.Time
	skipping := false
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.HasPrefix(line, "\t") {
			if skipping {
				continue
			}
			b.WriteString(line)
			b.WriteByte('\n')
			continue
		}
		m := lp.re.FindStringSubmatch(line)
		if m == nil {
			skipping = true
			continue
		}
		t, ok := lp.timeOf(m, z)
		if !ok {
			skipping = true
			continue
		}
		skipping = false
		if t.After(newest) {
			newest = t
		}
		stamp := t.UTC().Format("2006-01-02 15:04:05.000")
		client := sub(m, lp.rem)
		if client == "" && lp.hst != 0 && sub(m, lp.hst) != "" && sub(m, lp.hst) != "[local]" {
			client = sub(m, lp.hst) + "(0)" // %h without %r: the host, no port
		}
		user := strings.NewReplacer(":", "_", "@", "_").Replace(sub(m, lp.user))
		db := strings.ReplaceAll(sub(m, lp.db), ":", "_")
		fmt.Fprintf(&b, "%s UTC:%s:%s@%s:[%s]:%s:  %s\n", stamp, client, user, db, sub(m, lp.pid), m[lp.level], m[lp.msg])
	}
	return b.String(), newest
}
