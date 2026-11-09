package collect

// The job report's schedule arithmetic (task 38): pg_cron's schedule strings parsed by our own code (no
// module), the next run after a time and the scheduled runs before it. pg_cron's cron.job has no next-run
// column, so the jobs collection adds two values to each pg_cron job row: next_run (the first scheduled
// time after the read) and prior_due (the scheduled time before the latest one); the repository's job
// report calls a job missed when no run started at or after prior_due, two scheduled runs without one.
// pgAgent computes its own next run (pga_job.jobnextrun, from pga_schedule), which the collection already
// reads; its rows are left as they are.
//
// The grammar is pg_cron's (its entry parser comes from Vixie cron):
//   - five fields: minute 0-59, hour 0-23, day of month 1-31, month 1-12 or jan-dec, day of week 0-7 or
//     sun-sat (0 and 7 are Sunday); each a comma list of *, n, n-m, each with an optional /step
//     (n/step = n-max/step); '$' in the day of month is the month's last day (pg_cron 1.5+)
//   - when both day fields are restricted (neither starts with '*') a day matches either one; when one
//     starts with '*' both must match (Vixie's rule)
//   - the named shortcuts @yearly @annually @monthly @weekly @daily @midnight @hourly, and @reboot (no
//     scheduled time: runs at server start only)
//   - 'N seconds' (1-59, pg_cron 1.5+): every N seconds, no fixed phase
// The times are in pg_cron's cron.timezone (GMT unless set; CronTimezone reads it).

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// CronSpec is one parsed pg_cron schedule.
type CronSpec struct {
	minute, hour, dom, month, dow uint64 // bit n set = value n matches
	domStar, dowStar              bool   // the field starts with '*' (Vixie's day rule)
	lastDOM                       bool   // '$' in the day of month
	every                         time.Duration
	reboot                        bool
}

var cronShortcuts = map[string]string{
	"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
	"@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *",
}

var cronSeconds = regexp.MustCompile(`^(\d+)\s*seconds?$`)

var cronMonths = []string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
var cronDays = []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}

// ParseCron parses a pg_cron schedule string.
func ParseCron(expr string) (*CronSpec, error) {
	e := strings.ToLower(strings.TrimSpace(expr))
	if e == "@reboot" {
		return &CronSpec{reboot: true}, nil
	}
	if m := cronSeconds.FindStringSubmatch(e); m != nil {
		n, _ := strconv.Atoi(m[1])
		if n < 1 || n > 59 {
			return nil, fmt.Errorf("%q: seconds must be 1 to 59", expr)
		}
		return &CronSpec{every: time.Duration(n) * time.Second}, nil
	}
	if s, ok := cronShortcuts[e]; ok {
		e = s
	}
	f := strings.Fields(e)
	if len(f) != 5 {
		return nil, fmt.Errorf("%q: want five fields (minute hour day-of-month month day-of-week), a @shortcut or 'N seconds'", expr)
	}
	s := &CronSpec{domStar: strings.HasPrefix(f[2], "*"), dowStar: strings.HasPrefix(f[4], "*")}
	var err error
	if s.minute, err = cronField(f[0], 0, 59, nil); err != nil {
		return nil, fmt.Errorf("%q minute: %w", expr, err)
	}
	if s.hour, err = cronField(f[1], 0, 23, nil); err != nil {
		return nil, fmt.Errorf("%q hour: %w", expr, err)
	}
	dom := f[2]
	if items := strings.Split(dom, ","); containsStr(items, "$") {
		s.lastDOM = true
		dom = strings.Join(removeStr(items, "$"), ",")
	}
	if dom != "" {
		if s.dom, err = cronField(dom, 1, 31, nil); err != nil {
			return nil, fmt.Errorf("%q day of month: %w", expr, err)
		}
	}
	if s.month, err = cronField(f[3], 1, 12, cronMonths); err != nil {
		return nil, fmt.Errorf("%q month: %w", expr, err)
	}
	if s.dow, err = cronField(f[4], 0, 7, cronDays); err != nil {
		return nil, fmt.Errorf("%q day of week: %w", expr, err)
	}
	if s.dow&(1<<7) != 0 { // 7 is Sunday too
		s.dow |= 1
	}
	if s.minute == 0 || s.hour == 0 || (s.dom == 0 && !s.lastDOM) || s.month == 0 {
		return nil, fmt.Errorf("%q: a field matches nothing", expr)
	}
	return s, nil
}

// cronField parses one comma list into a bit set over lo..hi; names (index 0 = the first value) are the
// three-letter month or day names.
func cronField(field string, lo, hi int, names []string) (uint64, error) {
	var bits uint64
	val := func(v string) (int, error) {
		for i, n := range names {
			if v == n {
				return i + lo, nil
			}
		}
		n, err := strconv.Atoi(v)
		if err != nil || n < lo || n > hi {
			return 0, fmt.Errorf("%q is not a value in %d-%d", v, lo, hi)
		}
		return n, nil
	}
	for _, item := range strings.Split(field, ",") {
		if item == "" {
			return 0, errors.New("an empty list item")
		}
		rng, step := item, 1
		if i := strings.IndexByte(item, '/'); i >= 0 {
			rng = item[:i]
			n, err := strconv.Atoi(item[i+1:])
			if err != nil || n < 1 || n > hi {
				return 0, fmt.Errorf("step %q", item[i+1:])
			}
			step = n
		}
		a, b := lo, hi
		switch {
		case rng == "*":
		case strings.Contains(rng, "-"):
			p := strings.SplitN(rng, "-", 2)
			var err error
			if a, err = val(p[0]); err != nil {
				return 0, err
			}
			if b, err = val(p[1]); err != nil {
				return 0, err
			}
			if a > b {
				return 0, fmt.Errorf("range %q runs backwards", rng)
			}
		default:
			v, err := val(rng)
			if err != nil {
				return 0, err
			}
			a = v
			if step == 1 { // n alone; n/step runs to the maximum
				b = v
			}
		}
		for v := a; v <= b; v += step {
			bits |= 1 << uint(v)
		}
	}
	return bits, nil
}

func containsStr(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

func removeStr(xs []string, s string) []string {
	out := xs[:0:0]
	for _, x := range xs {
		if x != s {
			out = append(out, x)
		}
	}
	return out
}

// dayMatches applies Vixie's rule: both day fields restricted = either matches; otherwise both.
func (s *CronSpec) dayMatches(t time.Time) bool {
	d := s.dom&(1<<uint(t.Day())) != 0
	if s.lastDOM && t.AddDate(0, 0, 1).Day() == 1 {
		d = true
	}
	w := s.dow&(1<<uint(t.Weekday())) != 0
	if s.domStar || s.dowStar {
		return d && w
	}
	return d || w
}

// cronLookYears bounds a search: every valid five-field schedule fires within four years (29 February).
const cronLookYears = 5

// Next is the first scheduled time strictly after t, in loc; the zero time for @reboot. The 'N seconds'
// form has no fixed phase: t plus N seconds.
func (s *CronSpec) Next(t time.Time, loc *time.Location) time.Time {
	if s.reboot {
		return time.Time{}
	}
	if s.every > 0 {
		return t.Add(s.every)
	}
	t = t.In(loc).Truncate(time.Minute).Add(time.Minute)
	limit := t.Year() + cronLookYears
	for t.Year() <= limit {
		y, mo, d := t.Date()
		switch {
		case s.month&(1<<uint(mo)) == 0:
			t = time.Date(y, mo+1, 1, 0, 0, 0, 0, loc)
		case !s.dayMatches(t):
			t = time.Date(y, mo, d+1, 0, 0, 0, 0, loc)
		case s.hour&(1<<uint(t.Hour())) == 0:
			n := time.Date(y, mo, d, t.Hour()+1, 0, 0, 0, loc)
			if !n.After(t) { // a repeated hour (DST ends): step on the absolute clock
				n = t.Truncate(time.Hour).Add(time.Hour)
			}
			t = n
		case s.minute&(1<<uint(t.Minute())) == 0:
			t = t.Add(time.Minute)
		default:
			return t
		}
	}
	return time.Time{}
}

// Prev is the latest scheduled time at or before t, in loc; the zero time for @reboot or none within the
// look-back. The 'N seconds' form: t itself.
func (s *CronSpec) Prev(t time.Time, loc *time.Location) time.Time {
	if s.reboot {
		return time.Time{}
	}
	if s.every > 0 {
		return t
	}
	t = t.In(loc).Truncate(time.Minute)
	limit := t.Year() - cronLookYears
	for t.Year() >= limit {
		y, mo, d := t.Date()
		switch {
		case s.month&(1<<uint(mo)) == 0:
			t = time.Date(y, mo, 1, 0, 0, 0, 0, loc).Add(-time.Minute)
		case !s.dayMatches(t):
			t = time.Date(y, mo, d, 0, 0, 0, 0, loc).Add(-time.Minute)
		case s.hour&(1<<uint(t.Hour())) == 0:
			t = time.Date(y, mo, d, t.Hour(), 0, 0, 0, loc).Add(-time.Minute)
		case s.minute&(1<<uint(t.Minute())) == 0:
			t = t.Add(-time.Minute)
		default:
			return t
		}
	}
	return time.Time{}
}

// PriorDue is the scheduled time before the latest one at or before t: a job with no run started at or
// after it has missed two scheduled runs. The 'N seconds' form: t minus two periods.
func (s *CronSpec) PriorDue(t time.Time, loc *time.Location) time.Time {
	if s.every > 0 {
		return t.Add(-2 * s.every)
	}
	last := s.Prev(t, loc)
	if last.IsZero() {
		return last
	}
	return s.Prev(last.Add(-time.Minute), loc)
}

// CronTimezone is pg_cron's cron.timezone on the connected server (GMT when the setting is not there:
// pg_cron before 1.5, or not loaded).
func CronTimezone(ctx context.Context, conn *pgx.Conn) string {
	var tz *string
	if err := conn.QueryRow(ctx, `SELECT current_setting('cron.timezone', true)`).Scan(&tz); err != nil || tz == nil || *tz == "" {
		return "GMT"
	}
	return *tz
}

// AddCronTimes adds next_run and prior_due to every pg_cron job row of a jobs read taken at now, in pg_cron's
// time zone tz; a schedule the parser does not take, @reboot, or an unknown time zone leaves a schedule_note
// instead (a job with a note is never called missed). A next_run the row already carries is kept.
func AddCronTimes(rows []Row, now time.Time, tz string) {
	loc, tzErr := time.LoadLocation(tz)
	if tzErr != nil {
		loc = time.UTC
	}
	for _, r := range rows {
		if r["kind"] != "job" || r["scheduler"] != "pg_cron" {
			continue
		}
		expr, _ := r["schedule"].(string)
		spec, err := ParseCron(expr)
		switch {
		case err != nil:
			r["schedule_note"] = "schedule not parsed: " + err.Error()
			continue
		case spec.reboot:
			r["schedule_note"] = "@reboot: runs at server start only"
			continue
		}
		if r["next_run"] == nil {
			if n := spec.Next(now, loc); !n.IsZero() {
				r["next_run"] = n.UTC()
			}
		}
		if tzErr != nil {
			r["schedule_note"] = fmt.Sprintf("cron.timezone %q is not known here: the times are UTC", tz)
			continue
		}
		if p := spec.PriorDue(now, loc); !p.IsZero() {
			r["prior_due"] = p.UTC()
		}
	}
}
