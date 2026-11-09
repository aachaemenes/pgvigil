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
// directory with pg_ls_logdir() (pg_monitor) and reads the files with pg_read_binary_file(), which is
// superuser-only until the client's DBA grants it to the monitoring login (the opt-in):
//
//	GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO <login>;
//
// That grant alone reads the log directory, inside the data directory or not (PostgreSQL 18, proof-slow.sh);
// pg_read_server_files alone does not (the function stays superuser-only). Without it the run is skipped
// with that reason. Each run reads from the stored cursor minus
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

// serverlogReadFn names the function the opt-in grants, as has_function_privilege takes it.
const serverlogReadFn = "pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)"

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
	err := d.conn.QueryRow(ctx, `SELECT pg_read_binary_file($1, $2, $3, true)`, strings.TrimRight(d.dir, "/")+"/"+name, off, n).Scan(&b)
	if err != nil {
		return nil, fmt.Errorf("pg_read_binary_file %s: %w", name, err)
	}
	return b, nil
}

// serverlogSettings is what the reader needs from the server before it reads.
type serverlogSettings struct {
	Collector, Destination, Directory, Prefix, TimeZone string
	CanList, CanRead                                    bool
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
	case !s.CanRead:
		return "the monitoring login may not read the log files (the client DBA's opt-in: GRANT EXECUTE ON FUNCTION " +
			serverlogReadFn + " TO <login>; pg_read_server_files alone is not enough)"
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
       has_function_privilege($1, 'EXECUTE')`, serverlogReadFn).
		Scan(&s.Collector, &s.Destination, &s.Directory, &s.Prefix, &s.TimeZone, &s.CanList, &s.CanRead)
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
	loc := time.UTC
	if l, err := time.LoadLocation(s.TimeZone); err == nil {
		loc = l
	}
	source := "serverlog:" + s.Directory
	from := time.Now().Add(-logsFirstRead)
	if t, ok, err := cursor(ctx, source); err != nil {
		return nil, err
	} else if ok {
		from = t.Add(-logsOverlap)
	}
	return serverlogRows(ctx, pgLogDir{conn: conn, dir: s.Directory}, lp, loc, source, from, serverlogMaxBytes)
}

// serverlogRows reads the stderr files written since from, oldest first, up to maxBytes, and returns the event
// rows plus one cursor row. The cursor is the time of the newest line read (the files are written one after
// the other, so there is no slower stream to wait for); a run that hit maxBytes puts it one overlap past its
// last line, so the next run starts at that line instead of re-reading the same bytes for ever.
func serverlogRows(ctx context.Context, dir logDir, lp *linePrefix, loc *time.Location, source string, from time.Time, maxBytes int64) ([]Row, error) {
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
	var last time.Time
	budget, full := maxBytes, false
	for _, f := range files {
		if strings.HasSuffix(f.Name, ".csv") || strings.HasSuffix(f.Name, ".json") || f.Modified.Before(from) || f.Size == 0 {
			continue
		}
		if budget <= 0 {
			full = true
			break
		}
		start, err := seekTime(ctx, dir, lp, loc, f, from)
		if err != nil {
			return nil, err
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
		if start > 0 { // the probe landed inside a line: its tail is not an entry
			if i := bytes.IndexByte(buf, '\n'); i >= 0 {
				buf = buf[i+1:]
			} else {
				buf = nil
			}
		}
		if i := bytes.LastIndexByte(buf, '\n'); i >= 0 { // a line still being written is read next run
			buf = buf[:i+1]
		} else {
			buf = nil
		}
		text, newest := lp.rewrite(strings.ToValidUTF8(string(buf), "�"), loc)
		if newest.After(last) {
			last = newest
		}
		parsed, _ := logparse.ParseIn(strings.NewReader(text), loc)
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
	case full && !last.IsZero():
		readTo = last.Add(logsOverlap)
	case last.After(from):
		readTo = last
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

// seekTime returns an offset at or before the first line of f written at or after from: a binary search
// over probes of the file (a log file is written in time order). The offset may fall inside a line.
func seekTime(ctx context.Context, dir logDir, lp *linePrefix, loc *time.Location, f logFile, from time.Time) (int64, error) {
	lo, hi := int64(0), f.Size
	for hi-lo > serverlogProbe {
		mid := lo + (hi-lo)/2
		t, ok, err := probeTime(ctx, dir, lp, loc, f.Name, mid)
		if err != nil {
			return 0, err
		}
		if ok && t.Before(from) {
			lo = mid
		} else {
			hi = mid // a probe with no readable line keeps the earlier half: read more, never less
		}
	}
	return lo, nil
}

// probeTime is the time of the first whole line with a prefix at or after off.
func probeTime(ctx context.Context, dir logDir, lp *linePrefix, loc *time.Location, name string, off int64) (time.Time, bool, error) {
	b, err := dir.Read(ctx, name, off, serverlogProbe)
	if err != nil || b == nil {
		return time.Time{}, false, err
	}
	if i := bytes.IndexByte(b, '\n'); i >= 0 {
		b = b[i+1:]
	}
	for _, line := range strings.Split(string(b), "\n") {
		if m := lp.re.FindStringSubmatch(line); m != nil {
			if t, ok := lp.timeOf(m, loc); ok {
				return t, true, nil
			}
		}
	}
	return time.Time{}, false, nil
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

// timeOf reads a matched line's time: %m / %t in loc unless the zone is UTC, GMT or a numeric offset (as
// logparse reads it), %n as Unix seconds.
func (lp *linePrefix) timeOf(m []string, loc *time.Location) (time.Time, bool) {
	if lp.tm != 0 {
		v := sub(m, lp.tm)
		sp := strings.LastIndexByte(v, ' ')
		if sp < 0 {
			return time.Time{}, false
		}
		layout := "2006-01-02 15:04:05"
		if strings.Contains(v[:sp], ".") {
			layout += ".999999"
		}
		t, err := time.ParseInLocation(layout, v[:sp], zoneFor(v[sp+1:], loc))
		return t, err == nil
	}
	f, err := strconv.ParseFloat(sub(m, lp.epoch), 64)
	if err != nil {
		return time.Time{}, false
	}
	sec := int64(f)
	return time.Unix(sec, int64((f-float64(sec))*1e9)).UTC(), true
}

var zoneOffsetRE = regexp.MustCompile(`^([+-])(\d{2})(\d{2})?$`)

func zoneFor(abbr string, loc *time.Location) *time.Location {
	if abbr == "UTC" || abbr == "GMT" {
		return time.UTC
	}
	if m := zoneOffsetRE.FindStringSubmatch(abbr); m != nil {
		h, _ := strconv.Atoi(m[2])
		mi, _ := strconv.Atoi(m[3])
		off := h*3600 + mi*60
		if m[1] == "-" {
			off = -off
		}
		return time.FixedZone(abbr, off)
	}
	return loc
}

// rewrite turns the lines of a stderr log into the RDS prefix shape, keeping the tab-led continuation lines
// and dropping lines that match neither; it returns the text and the newest line time it read.
func (lp *linePrefix) rewrite(text string, loc *time.Location) (string, time.Time) {
	var b strings.Builder
	var newest time.Time
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.HasPrefix(line, "\t") {
			b.WriteString(line)
			b.WriteByte('\n')
			continue
		}
		m := lp.re.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		t, ok := lp.timeOf(m, loc)
		if !ok {
			continue
		}
		if t.After(newest) {
			newest = t
		}
		stamp, zone := t.UTC().Format("2006-01-02 15:04:05.000"), "UTC"
		if lp.tm != 0 { // keep the server's own text: logparse keys an entry by it, so a re-read keeps one key
			v := sub(m, lp.tm)
			sp := strings.LastIndexByte(v, ' ')
			stamp, zone = v[:sp], v[sp+1:]
		}
		client := sub(m, lp.rem)
		if client == "" && lp.hst != 0 && sub(m, lp.hst) != "" && sub(m, lp.hst) != "[local]" {
			client = sub(m, lp.hst) + "(0)" // %h without %r: the host, no port
		}
		user := strings.NewReplacer(":", "_", "@", "_").Replace(sub(m, lp.user))
		db := strings.ReplaceAll(sub(m, lp.db), ":", "_")
		fmt.Fprintf(&b, "%s %s:%s:%s@%s:[%s]:%s:  %s\n", stamp, zone, client, user, db, sub(m, lp.pid), m[lp.level], m[lp.msg])
	}
	return b.String(), newest
}
