// Package logparse turns PostgreSQL server log entries into events: slow statements
// (log_min_duration_statement), lock waits (log_lock_waits), deadlocks and failed logins.
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
)

type entry struct {
	at                   time.Time
	key                  string
	client, user, dbname string
	pid                  int
	level, msg           string
	more                 []string // continuation lines and DETAIL / STATEMENT entries of the same pid
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
		return ev, false
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
