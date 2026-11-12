// Package reportmail mails a page of the UI (task 171): now, from the page itself, or on a schedule. The mail is the
// page's own grids: the web UI builds its HTML with the grid tools' renderer (web/src/gridtools.ts toHtml, the HTML
// copy with the colours) and its workbook with the export's (web/src/export.ts), from the grids on the screen, so the
// mail equals the window. A scheduled page is opened by the serve process in a headless Chromium-family browser, as
// the schedule's owner, and the same code builds the same mail (internal/web/q_reportmail.go). The mail waits in the
// repository (pgvigil.report_mail_sends, migration 0107) until the alert sender (pgvigil run) mails it through an smtp
// channel of the alerts: block (Pass, Run): the serve process never holds a channel's secret.
//
// This file: the limits, a schedule's cron line and its next send, a request's checks and the browser lookup.
package reportmail

import (
	"errors"
	"fmt"
	"net/mail"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The limits of one mail: its HTML body and its workbook (the repository's CHECKs say the same), the addresses.
const (
	MaxHTML       = 4 << 20
	MaxXLSX       = 8 << 20
	MaxRecipients = 50
	// MinGap is the least time between two sends of one schedule: a cron line that fires more often is refused.
	MinGap = 15 * time.Minute
)

// shortcuts are the cron line's @names, stored as the five fields they stand for (the repository keeps five fields).
var shortcuts = map[string]string{
	"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
	"@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *",
}

var hhmm = regexp.MustCompile(`^([01]?\d|2[0-3]):([0-5]\d)$`)

// CronFor is the cron line of a cadence: daily at HH:MM, weekly on the days (0 = Sunday ... 6) at HH:MM, or the cron
// line given (cadence cron; an @name becomes its five fields).
func CronFor(cadence, at string, days []int, line string) (string, error) {
	switch cadence {
	case "daily", "weekly":
		m := hhmm.FindStringSubmatch(strings.TrimSpace(at))
		if m == nil {
			return "", fmt.Errorf("the time %q is not HH:MM (00:00 to 23:59)", at)
		}
		h, mi := strings.TrimLeft(m[1], "0"), strings.TrimLeft(m[2], "0")
		if h == "" {
			h = "0"
		}
		if mi == "" {
			mi = "0"
		}
		if cadence == "daily" {
			return mi + " " + h + " * * *", nil
		}
		if len(days) == 0 {
			return "", errors.New("a weekly schedule needs at least one day")
		}
		seen := [7]bool{}
		for _, d := range days {
			if d < 0 || d > 6 {
				return "", fmt.Errorf("day %d is not 0 (Sunday) to 6 (Saturday)", d)
			}
			seen[d] = true
		}
		var ds []string
		for d, on := range seen {
			if on {
				ds = append(ds, fmt.Sprint(d))
			}
		}
		return mi + " " + h + " * * " + strings.Join(ds, ","), nil
	case "cron":
		l := strings.Join(strings.Fields(strings.ToLower(line)), " ")
		if s, ok := shortcuts[l]; ok {
			l = s
		}
		return l, nil
	}
	return "", fmt.Errorf("the cadence %q is not daily, weekly or cron", cadence)
}

// Zone is the time zone a schedule names (an IANA name or UTC; the zone database is embedded through collect).
func Zone(tz string) (*time.Location, error) {
	tz = strings.TrimSpace(tz)
	if tz == "" || strings.EqualFold(tz, "local") {
		return nil, errors.New("a schedule names its time zone (an IANA name such as America/Los_Angeles, or UTC)")
	}
	loc, err := time.LoadLocation(tz)
	if err != nil {
		return nil, fmt.Errorf("%q is not a time zone: %w", tz, err)
	}
	return loc, nil
}

// CheckCron says whether a cron line can be a schedule: five fields (pg_cron's grammar, collect.ParseCron), never
// '@reboot' or 'N seconds', and no two sends closer than MinGap over the next 200 sends.
func CheckCron(line, tz string, from time.Time) error {
	loc, err := Zone(tz)
	if err != nil {
		return err
	}
	f := strings.Fields(line)
	if len(f) != 5 {
		return fmt.Errorf("%q: a schedule's cron line has five fields (minute hour day-of-month month day-of-week)", line)
	}
	spec, err := collect.ParseCron(line)
	if err != nil {
		return err
	}
	prev := spec.Next(from, loc)
	if prev.IsZero() {
		return fmt.Errorf("%q never comes in the next years", line)
	}
	for range 200 {
		n := spec.Next(prev, loc)
		if n.IsZero() {
			break
		}
		if n.Sub(prev) < MinGap {
			return fmt.Errorf("%q sends at %s and again at %s: a schedule sends at most every %s", line,
				prev.Format("2006-01-02 15:04"), n.Format("15:04"), MinGap)
		}
		prev = n
	}
	return nil
}

// NextSend is the cron line's first time strictly after `after` in the zone.
func NextSend(line, tz string, after time.Time) (time.Time, error) {
	loc, err := Zone(tz)
	if err != nil {
		return time.Time{}, err
	}
	spec, err := collect.ParseCron(line)
	if err != nil {
		return time.Time{}, err
	}
	n := spec.Next(after, loc)
	if n.IsZero() {
		return time.Time{}, fmt.Errorf("%q has no next time", line)
	}
	return n.UTC(), nil
}

// Recipients parses a list of addresses (one address each, no display names kept), lower-cased, duplicates dropped.
func Recipients(in []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, raw := range in {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if strings.ContainsAny(raw, "\r\n,;") {
			return nil, fmt.Errorf("%q: one address per entry", raw)
		}
		a, err := mail.ParseAddress(raw)
		if err != nil {
			return nil, fmt.Errorf("%q is not a mail address", raw)
		}
		addr := strings.ToLower(a.Address)
		if at := strings.LastIndexByte(addr, '@'); at < 1 || !strings.Contains(addr[at:], ".") {
			return nil, fmt.Errorf("%q is not a mail address with a domain", raw)
		}
		if !seen[addr] {
			seen[addr] = true
			out = append(out, addr)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("at least one address is required")
	}
	if len(out) > MaxRecipients {
		return nil, fmt.Errorf("%d addresses: at most %d", len(out), MaxRecipients)
	}
	return out, nil
}

var route = regexp.MustCompile(`^#/[A-Za-z0-9_]+(\?[A-Za-z0-9_.~%=&:+,-]*)?$`)

// CheckRoute says whether s is the address of a page of the UI ('#/backups?w=24h'), the only thing a schedule may
// open; the render's own key is never part of it.
func CheckRoute(s string) error {
	if len(s) > 500 || !route.MatchString(s) {
		return fmt.Errorf("%q is not the address of a page of this UI (#/<tab>?...)", s)
	}
	if strings.Contains(s, "mailrender=") {
		return errors.New("the address carries a render key")
	}
	return nil
}

// The mail body is checked against what the UI's own builder writes (web/src/reportmail.ts mailHtml and gridtools.ts
// toHtml): an allowlist, never a blocklist. Tags: the document's and a table's; attributes: a style, a cell's
// data-status, the document's lang / charset / name / content and a table's role; no attribute carries a URL, an
// entity or a quote of the other kind, and a style carries no url(), no expression() and no escape. A cell's words
// are escaped by the builder (< > & " become entities), so a '<' in the body only ever opens a tag.
var (
	mailTags  = map[string]bool{"html": true, "head": true, "meta": true, "title": true, "body": true, "h2": true, "h3": true, "p": true, "table": true, "thead": true, "tbody": true, "tr": true, "th": true, "td": true}
	mailAttrs = map[string]bool{"style": true, "lang": true, "role": true, "charset": true, "name": true, "content": true, "data-status": true}
	tagRe     = regexp.MustCompile(`^<(/?)([a-z][a-z0-9]*)((?:\s+[a-z][a-z-]*="[^"<>&]*")*)\s*>`)
	attrRe    = regexp.MustCompile(`\s+([a-z][a-z-]*)="([^"<>&]*)"`)
	badStyle  = regexp.MustCompile(`(?i)url\s*\(|expression\s*\(|@import|\\|javascript|behavior\s*:|-moz-binding`)
)

// CheckBody says whether an HTML body can be mailed: under MaxHTML, and nothing in it but the tags and attributes a
// page's mail is built of (above).
func CheckBody(html string) error {
	if len(html) < 20 {
		return errors.New("the mail has no body: the page drew no grid")
	}
	if len(html) > MaxHTML {
		return fmt.Errorf("the page's grids make a mail body of %.1f MB, over the %d MB a mail carries: narrow the window or filter the grid", float64(len(html))/(1<<20), MaxHTML>>20)
	}
	rest := html
	if strings.HasPrefix(strings.ToLower(rest), "<!doctype html>") {
		rest = rest[len("<!doctype html>"):]
	}
	for {
		at := strings.IndexByte(rest, '<')
		if at < 0 {
			return nil
		}
		rest = rest[at:]
		m := tagRe.FindStringSubmatch(rest)
		if m == nil {
			end := min(len(rest), 40)
			return fmt.Errorf("the mail body holds %q: refused (a mail carries tables and inline styles only)", rest[:end])
		}
		if !mailTags[m[2]] {
			return fmt.Errorf("the mail body holds a <%s> element: refused (a mail carries tables and inline styles only)", m[2])
		}
		for _, a := range attrRe.FindAllStringSubmatch(m[3], -1) {
			if !mailAttrs[a[1]] {
				return fmt.Errorf("the mail body holds a %s attribute on <%s>: refused", a[1], m[2])
			}
			if a[1] == "style" && badStyle.MatchString(a[2]) {
				return fmt.Errorf("the mail body holds a style %q: refused", a[2])
			}
		}
		rest = rest[len(m[0]):]
	}
}

// CheckWorkbook says whether an attachment is a workbook: a zip under MaxXLSX.
func CheckWorkbook(b []byte) error {
	if len(b) > MaxXLSX {
		return fmt.Errorf("the workbook is %.1f MB, over the %d MB a mail carries", float64(len(b))/(1<<20), MaxXLSX>>20)
	}
	if len(b) < 4 || string(b[:4]) != "PK\x03\x04" {
		return errors.New("the workbook is not a zip (.xlsx)")
	}
	return nil
}

// browsers are the Chromium-family browsers a scheduled page is rendered in, the first found on PATH
var browsers = []string{"chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "microsoft-edge", "microsoft-edge-stable", "msedge", "chrome", "brave-browser"}

// FindBrowser is the browser a scheduled page is rendered in: PGVIGIL_BROWSER when set (a path), else the first of
// the Chromium family on PATH, else the usual install places on Windows and macOS; "" = none (a schedule's turn then
// fails with that reason and is alerted).
func FindBrowser() string {
	if p := strings.TrimSpace(os.Getenv("PGVIGIL_BROWSER")); p != "" {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
		return ""
	}
	for _, n := range browsers {
		if p, err := exec.LookPath(n); err == nil {
			return p
		}
	}
	var places []string
	switch runtime.GOOS {
	case "windows":
		for _, env := range []string{"ProgramFiles", "ProgramFiles(x86)", "LocalAppData"} {
			if d := os.Getenv(env); d != "" {
				places = append(places, filepath.Join(d, "Microsoft", "Edge", "Application", "msedge.exe"),
					filepath.Join(d, "Google", "Chrome", "Application", "chrome.exe"))
			}
		}
	case "darwin":
		places = []string{"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium",
			"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"}
	}
	for _, p := range places {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}
