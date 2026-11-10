// Package logparse turns PostgreSQL server log entries into events: slow statements
// (log_min_duration_statement), lock waits (log_lock_waits), deadlocks, failed logins, the plans
// auto_explain writes, and the messages a damaged page, file or TOAST value leaves (corruption).
// It reads the RDS / Aurora prefix '%t:%r:%u@%d:[%p]:' and, for an entry that spans lines,
// takes the continuation lines (a leading tab, or DETAIL / HINT / CONTEXT / STATEMENT lines
// with the same prefix and pid) as part of the entry before it.
package logparse

import (
	"bufio"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Kind of event.
type Kind string

// The kinds of event Parse returns.
const (
	Slow     Kind = "slow"
	LockWait Kind = "lock_wait"
	Deadlock Kind = "deadlock"
	AuthFail Kind = "auth_fail"
	// Plan is an auto_explain entry ('duration: N ms  plan:'): DurationMS is the statement's time and
	// Statement the plan as logged (text, JSON, YAML or XML; the text format keeps its indentation).
	Plan Kind = "plan"
	// Corruption is a message that only a damaged page, file, TOAST value or transaction status raises:
	// Detail is the message with its DETAIL / CONTEXT lines, Statement the statement that met it.
	Corruption Kind = "corruption"
)

// Event is one parsed log entry of interest.
type Event struct {
	Kind       Kind
	At         time.Time
	Client     string
	User       string
	Database   string
	PID        int
	DurationMS float64 // slow: the statement's duration; lock_wait: the wait so far
	Statement  string  // slow / deadlock / lock_wait: the statement text where the log has it
	Detail     string  // deadlock: the DETAIL lines; lock_wait: the holders; auth_fail: the message
	// Key identifies the entry from its first line alone (time text, level, pid, message), so an entry
	// read once without its DETAIL / STATEMENT lines and again with them keeps one key.
	Key string
}

// prefix: 2026-11-09 12:00:00 UTC:10.0.0.1(54321):postgres@postgres:[1234]:LOG:  message
// %r is empty, [local] or host(port); the host may be IPv6, so it is matched up to its (port).
var prefixRE = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?) ([^\s:]+):(\[local\]|.*?\(\d+\)|):([^@:]*)@([^:]*):\[(\d+)\]:([A-Z]+):\s+(.*)$`)

var offsetRE = regexp.MustCompile(`^([+-])(\d{2})(\d{2})?$`)

var (
	durationRE = regexp.MustCompile(`^duration: ([0-9.]+) ms\s+(?:statement|execute [^:]*|parse [^:]*|bind [^:]*):\s?(.*)$`)
	lockWaitRE = regexp.MustCompile(`^process \d+ still waiting for .* after ([0-9.]+) ms`)
	planRE     = regexp.MustCompile(`^duration: ([0-9.]+) ms\s+plan:\s?(.*)$`)
)

// copyContextRE: COPY's error context names the table and the line (and column) and then quotes the row's data;
// the data is cut, the position kept.
var copyContextRE = regexp.MustCompile(`^(COPY \S+, line \d+(?:, column \S+)?): "`)

// splitContext sorts a corruption event's CONTEXT lines: a line that carries statement text goes to the statement
// WITHOUT its wrapper, so the query-text policy's normalizer sees plain SQL and masks its literals (PL/pgSQL's
// `SQL statement "..."`, postgres_fdw's `remote SQL command: ...`; dblink's `while executing ...` names only the
// connection and rides along); a COPY line keeps its position and loses the quoted row data; everything else (a
// block, a relation, a process, a PL/pgSQL function and line, `SQL function "f" statement N`) stays in the detail.
func splitContext(v string) (ctx, stmt []string) {
	for _, l := range strings.Split(v, "\n") {
		switch {
		case strings.HasPrefix(l, `SQL statement "`) && strings.HasSuffix(l, `"`) && len(l) > len(`SQL statement ""`):
			stmt = append(stmt, l[len(`SQL statement "`):len(l)-1])
		case strings.HasPrefix(l, "remote SQL command: "):
			stmt = append(stmt, strings.TrimPrefix(l, "remote SQL command: "))
		case strings.HasPrefix(l, "while executing "):
			stmt = append(stmt, l)
		default:
			if m := copyContextRE.FindStringSubmatch(l); m != nil {
				l = m[1]
			}
			ctx = append(ctx, l)
		}
	}
	return ctx, stmt
}

// corruptionRE are the messages of a damaged page, file, TOAST value or commit log, as PostgreSQL 12 to 18
// word them (bufmgr, md.c / smgr, the checksum check, detoast, heap vacuum's freeze checks, slru, multixact, the
// B-tree page checks). A missing file
// counts only under the data directory's relation and status paths: a missing file elsewhere (COPY's input,
// pg_hba.conf) is not damage.
var corruptionRE = []*regexp.Regexp{
	regexp.MustCompile(`^page verification failed, calculated checksum \d+ but expected \d+`),
	regexp.MustCompile(`^ignoring checksum failure in block \d+`),
	regexp.MustCompile(`^invalid page in block \d+ of relation `),
	// PostgreSQL 18's combined reads: one message for several damaged blocks of one read
	regexp.MustCompile(`^\d+ invalid pages among blocks \d+\.\.\d+ of relation `),
	regexp.MustCompile(`^(zeroing out \d+ invalid pages|ignoring \d+ checksum failures|zeroing \d+ page\(s\) and ignoring \d+ checksum failure\(s\)) among blocks `),
	regexp.MustCompile(`^index ".*" contains (unexpected zero page|corrupted page) at block \d+`),
	regexp.MustCompile(`^MultiXactId \d+ (has not been created yet|does no longer exist) -- apparent wraparound`),
	regexp.MustCompile(`^could not read blocks? \d+(\.\.\d+)? in file `),
	regexp.MustCompile(`^could not open file "(base|global|pg_tblspc|pg_xact|pg_multixact|pg_subtrans|pg_commit_ts)/`),
	regexp.MustCompile(`^could not access status of transaction \d+`),
	regexp.MustCompile(`^(unexpected|missing) chunk number \d+ .*for toast value \d+`),
	regexp.MustCompile(`^found (xmin|xmax|multixact|update xid) \d+ from before (relfrozenxid|relminmxid|xid cutoff|cutoff multixact)`),
	regexp.MustCompile(`^uncommitted xmin \d+ from before xid cutoff`),
}

// isCorruption says whether an entry is a corruption message. At LOG level only the checksum line counts:
// PostgreSQL 18 writes a LOG copy of each invalid-page, ignored-checksum and short-read message beside the
// ERROR / WARNING the backend raises (from an I/O worker, or the backend itself), and counting both would
// count one damaged read twice; 'page verification failed' is LOG-only there, WARNING before 18.
func isCorruption(level, msg string) bool {
	switch level {
	case "WARNING", "ERROR", "FATAL", "PANIC":
	case "LOG":
		if !strings.HasPrefix(msg, "page verification failed") {
			return false
		}
	default:
		return false
	}
	for _, re := range corruptionRE {
		if re.MatchString(msg) {
			return true
		}
	}
	return false
}

type entry struct {
	at                   time.Time
	key                  string
	client, user, dbname string
	pid                  int
	level, msg           string
	more                 []string // continuation lines and DETAIL / STATEMENT entries of the same pid
	raw                  []string // the continuation lines as written, less the leading tab (a plan's indentation)
}

// Parse reads log text written in UTC; see ParseIn.
func Parse(r io.Reader) ([]Event, error) { return ParseIn(r, time.UTC) }

// ParseIn reads log text and returns the events in order; lines it cannot read are skipped.
// loc is the server's log_timezone: %t prints only a zone abbreviation, so a time is read in loc
// unless its zone is UTC / GMT or a numeric offset (+03, -0530).
func ParseIn(r io.Reader, loc *time.Location) ([]Event, error) {
	if loc == nil {
		loc = time.UTC
	}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	var out []Event
	var cur *entry
	flush := func() {
		if cur != nil {
			if ev, ok := classify(cur); ok {
				out = append(out, ev)
			}
			cur = nil
		}
	}
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if strings.HasPrefix(line, "\t") {
			if cur != nil {
				cur.more = append(cur.more, strings.TrimSpace(line))
				cur.raw = append(cur.raw, strings.TrimPrefix(line, "\t"))
			}
			continue
		}
		m := prefixRE.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		pid, _ := strconv.Atoi(m[6])
		level := m[7]
		if cur != nil && pid == cur.pid && (level == "DETAIL" || level == "HINT" || level == "CONTEXT" || level == "STATEMENT" || level == "QUERY") {
			cur.more = append(cur.more, level+": "+m[8])
			continue
		}
		flush()
		layout := "2006-01-02 15:04:05"
		if len(m[1]) > 19 {
			layout += ".999999"
		}
		at, err := time.ParseInLocation(layout, m[1], zoneOf(m[2], loc))
		if err != nil {
			continue
		}
		cur = &entry{at: at, key: m[1] + " " + m[2] + "|" + level + "|" + m[6] + "|" + m[8],
			client: m[3], user: m[4], dbname: m[5], pid: pid, level: level, msg: m[8]}
	}
	flush()
	return out, sc.Err()
}

func zoneOf(abbr string, loc *time.Location) *time.Location {
	if abbr == "UTC" || abbr == "GMT" {
		return time.UTC
	}
	if m := offsetRE.FindStringSubmatch(abbr); m != nil {
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

func classify(e *entry) (Event, bool) {
	ev := Event{At: e.at, Client: e.client, User: e.user, Database: e.dbname, PID: e.pid, Key: e.key}
	switch {
	case e.level == "LOG" && planRE.MatchString(e.msg):
		m := planRE.FindStringSubmatch(e.msg)
		ev.Kind, ev.DurationMS = Plan, atof(m[1])
		ev.Statement = strings.TrimRight(strings.Join(append([]string{m[2]}, e.raw...), "\n"), "\n ")
		ev.Statement = strings.TrimLeft(ev.Statement, "\n")
	case isCorruption(e.level, e.msg):
		// Detail keeps the server's own text (the message, its DETAIL / HINT, the CONTEXT lines that name a block,
		// a relation or a process); a CONTEXT line that quotes statement text (SQL statement "...", while executing
		// ...) and a QUERY line go to Statement with the STATEMENT, so the query_text policy governs every statement text.
		ev.Kind = Corruption
		d := []string{e.msg}
		for _, t := range []string{"DETAIL", "HINT"} {
			if v := tagged(e.more, t); v != "" {
				d = append(d, t+": "+v)
			}
		}
		var ctx, stmt []string
		if v := tagged(e.more, "CONTEXT"); v != "" {
			ctx, stmt = splitContext(v)
		}
		if len(ctx) > 0 {
			d = append(d, "CONTEXT: "+strings.Join(ctx, "\n"))
		}
		for _, t := range []string{"QUERY", "STATEMENT"} {
			if v := tagged(e.more, t); v != "" {
				stmt = append(stmt, v)
			}
		}
		ev.Detail, ev.Statement = strings.Join(d, "\n"), strings.Join(stmt, "\n")
	case e.level == "LOG" && strings.HasPrefix(e.msg, "duration: "):
		m := durationRE.FindStringSubmatch(e.msg)
		if m == nil {
			return ev, false // a bare duration line (log_duration) has no statement
		}
		ev.Kind, ev.DurationMS = Slow, atof(m[1])
		ev.Statement = strings.TrimSpace(strings.Join(append([]string{m[2]}, plain(e.more)...), "\n"))
	case e.level == "LOG" && lockWaitRE.MatchString(e.msg):
		ev.Kind, ev.DurationMS = LockWait, atof(lockWaitRE.FindStringSubmatch(e.msg)[1])
		ev.Detail, ev.Statement = tagged(e.more, "DETAIL"), tagged(e.more, "STATEMENT")
	case e.level == "ERROR" && strings.HasPrefix(e.msg, "deadlock detected"):
		ev.Kind = Deadlock
		ev.Detail, ev.Statement = tagged(e.more, "DETAIL"), tagged(e.more, "STATEMENT")
	case e.level == "FATAL" && (strings.Contains(e.msg, "authentication failed") || strings.HasPrefix(e.msg, "no pg_hba.conf entry") ||
		strings.Contains(e.msg, "does not exist") && strings.HasPrefix(e.msg, "role ")):
		ev.Kind, ev.Detail = AuthFail, e.msg
	default:
		// a message no rule above took: the pganalyze classes (classes_pganalyze.go), one event kind each. The detail
		// is the server's own message with its DETAIL and HINT lines (a temp file's path and size, a crash's signal,
		// a conflict's reason, the wraparound hint); a crash's "Failed process was running:" DETAIL is the statement,
		// so the query-text policy governs it; an autovacuum cancel's CONTEXT names the table.
		k, _, ok := ClassifyMore(e.level, e.msg)
		if !ok {
			return ev, false
		}
		ev.Kind = k
		d := []string{e.msg}
		stmt := tagged(e.more, "STATEMENT")
		if v := tagged(e.more, "DETAIL"); v != "" {
			if s, found := strings.CutPrefix(v, "Failed process was running: "); found {
				stmt = strings.TrimSpace(s + "\n" + stmt)
			} else {
				d = append(d, "DETAIL: "+v)
			}
		}
		if v := tagged(e.more, "HINT"); v != "" {
			d = append(d, "HINT: "+v)
		}
		if k == AutovacuumCancel {
			if v := tagged(e.more, "CONTEXT"); v != "" {
				d = append(d, "CONTEXT: "+v)
			}
		}
		ev.Detail, ev.Statement = strings.Join(d, "\n"), stmt
	}
	return ev, true
}

func atof(s string) float64 { f, _ := strconv.ParseFloat(s, 64); return f }

// plain returns continuation lines that are not tagged DETAIL/HINT/... entries.
func plain(more []string) []string {
	var out []string
	for _, l := range more {
		if !isTagged(l) {
			out = append(out, l)
		}
	}
	return out
}

// tagged returns the text of the lines tagged with tag, with the untagged lines that follow them.
func tagged(more []string, tag string) string {
	var out []string
	in := false
	for _, l := range more {
		switch {
		case strings.HasPrefix(l, tag+": "):
			in = true
			out = append(out, strings.TrimPrefix(l, tag+": "))
		case isTagged(l):
			in = false
		case in:
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}

func isTagged(l string) bool {
	for _, t := range []string{"DETAIL: ", "HINT: ", "CONTEXT: ", "STATEMENT: ", "QUERY: "} {
		if strings.HasPrefix(l, t) {
			return true
		}
	}
	return false
}
