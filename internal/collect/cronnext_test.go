package collect

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func mustUTC(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// cronCase: the schedule, the time after which, the expected next run (RFC 3339, UTC; "" = none).
type cronCase struct{ expr, after, next string }

var cronCases = []cronCase{
	// minute boundary: strictly after, the seconds dropped
	{"* * * * *", "2026-11-09T14:59:30Z", "2026-11-09T15:00:00Z"},
	{"* * * * *", "2026-11-09T15:00:00Z", "2026-11-09T15:01:00Z"},
	{"*/15 * * * *", "2026-11-09T14:45:00Z", "2026-11-09T15:00:00Z"},
	{"5-59/20 * * * *", "2026-11-09T14:46:00Z", "2026-11-09T15:05:00Z"},
	// hour boundary
	{"30 * * * *", "2026-11-09T23:31:00Z", "2026-11-10T00:30:00Z"},
	{"0 9-17/4 * * *", "2026-11-09T13:00:00Z", "2026-11-09T17:00:00Z"},
	// day boundary
	{"0 3 * * *", "2026-11-09T03:00:00Z", "2026-11-10T03:00:00Z"},
	{"@daily", "2026-12-31T23:59:59Z", "2027-01-01T00:00:00Z"},
	// month boundary and the month's last day
	{"0 0 31 * *", "2026-11-09T00:00:00Z", "2026-12-31T00:00:00Z"},
	{"0 0 $ * *", "2027-02-01T00:00:00Z", "2027-02-28T00:00:00Z"},
	{"0 0 $ * *", "2028-02-01T00:00:00Z", "2028-02-29T00:00:00Z"},
	{"@monthly", "2026-11-30T12:00:00Z", "2026-12-01T00:00:00Z"},
	{"0 12 1 jan,jul *", "2026-11-09T00:00:00Z", "2027-01-01T12:00:00Z"},
	// year and leap day
	{"@yearly", "2026-11-09T00:00:00Z", "2027-01-01T00:00:00Z"},
	{"0 0 29 2 *", "2026-03-01T00:00:00Z", "2028-02-29T00:00:00Z"},
	// day of week: names, 7 = Sunday, Vixie's either-day rule
	{"@weekly", "2026-11-09T00:00:00Z", "2026-11-15T00:00:00Z"},
	{"0 6 * * 7", "2026-11-09T00:00:00Z", "2026-11-15T06:00:00Z"},
	{"0 6 * * mon-fri", "2026-11-13T07:00:00Z", "2026-11-16T06:00:00Z"},
	{"0 0 1 * mon", "2026-11-09T00:00:00Z", "2026-11-16T00:00:00Z"},    // the 1st OR a Monday
	{"0 0 1,15 * mon", "2026-11-09T00:00:00Z", "2026-11-15T00:00:00Z"}, // both restricted: the 15th before Monday the 16th
	{"0 0 */10 * mon", "2026-11-09T00:00:00Z", "2026-12-21T00:00:00Z"}, // '*/10' starts with '*': both must match
	{"0 0 * 12 mon", "2026-11-09T00:00:00Z", "2026-12-07T00:00:00Z"},   // day of month '*': Mondays only
	// the other forms
	{"30 seconds", "2026-11-09T14:00:10Z", "2026-11-09T14:00:40Z"},
	{"@reboot", "2026-11-09T14:00:00Z", ""},
	{"@restart", "2026-11-09T14:00:00Z", ""},
	// pg_cron reads five fields and ignores the rest
	{"0 0 12 * * *", "2026-11-09T00:00:00Z", "2026-11-12T00:00:00Z"},
}

func checkCron(t *testing.T, c cronCase, loc *time.Location) {
	t.Helper()
	s, err := ParseCron(c.expr)
	if err != nil {
		t.Errorf("%q: %v", c.expr, err)
		return
	}
	got := s.Next(mustUTC(t, c.after), loc)
	want := ""
	if !got.IsZero() {
		want = got.UTC().Format(time.RFC3339)
	}
	if want != c.next {
		t.Errorf("%q after %s: next %q, want %q", c.expr, c.after, want, c.next)
	}
}

func TestCronNext(t *testing.T) {
	for _, c := range cronCases {
		checkCron(t, c, time.UTC)
	}
}

// TestCronProofCases runs the cases proof-jobs-report.sh writes in its header (PGVIGIL_CRON_CASES: one per
// line, "expr|after|next"); skipped without it.
func TestCronProofCases(t *testing.T) {
	v := os.Getenv("PGVIGIL_CRON_CASES")
	if v == "" {
		t.Skip("PGVIGIL_CRON_CASES not set")
	}
	n := 0
	for _, line := range strings.Split(v, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		p := strings.Split(line, "|")
		if len(p) != 3 {
			t.Fatalf("bad case line %q", line)
		}
		checkCron(t, cronCase{strings.TrimSpace(p[0]), strings.TrimSpace(p[1]), strings.TrimSpace(p[2])}, time.UTC)
		n++
	}
	t.Logf("%d proof cases checked", n)
}

func TestCronPrevAndPriorDue(t *testing.T) {
	cases := []struct{ expr, at, prev, prior string }{
		{"*/15 * * * *", "2026-11-09T15:07:00Z", "2026-11-09T15:00:00Z", "2026-11-09T14:45:00Z"},
		{"*/15 * * * *", "2026-11-09T15:00:00Z", "2026-11-09T15:00:00Z", "2026-11-09T14:45:00Z"},
		{"0 3 * * *", "2026-11-09T02:00:00Z", "2026-11-08T03:00:00Z", "2026-11-07T03:00:00Z"},
		{"0 0 1 * *", "2026-03-15T00:00:00Z", "2026-03-01T00:00:00Z", "2026-02-01T00:00:00Z"},
		{"0 0 $ * *", "2026-03-15T00:00:00Z", "2026-02-28T00:00:00Z", "2026-01-31T00:00:00Z"},
		{"0 6 * * mon-fri", "2026-11-09T05:00:00Z", "2026-11-06T06:00:00Z", "2026-11-05T06:00:00Z"},
		{"@yearly", "2026-11-09T00:00:00Z", "2026-01-01T00:00:00Z", "2025-01-01T00:00:00Z"},
	}
	for _, c := range cases {
		s, err := ParseCron(c.expr)
		if err != nil {
			t.Fatal(err)
		}
		at := mustUTC(t, c.at)
		if got := s.Prev(at, time.UTC).Format(time.RFC3339); got != c.prev {
			t.Errorf("%q prev at %s = %s, want %s", c.expr, c.at, got, c.prev)
		}
		if got := s.PriorDue(at, time.UTC).Format(time.RFC3339); got != c.prior {
			t.Errorf("%q prior due at %s = %s, want %s", c.expr, c.at, got, c.prior)
		}
	}
}

func TestCronTimezone(t *testing.T) {
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skip("no tz database here")
	}
	s, _ := ParseCron("0 3 * * *")
	// 03:00 Los Angeles on 9 November 2026 (PST, UTC-8) = 11:00 UTC
	if got := s.Next(mustUTC(t, "2026-11-09T10:00:00Z"), la).UTC().Format(time.RFC3339); got != "2026-11-09T11:00:00Z" {
		t.Errorf("next in LA = %s", got)
	}
	// the day DST ends (1 November 2026): 01:30 happens twice, the schedule still fires and the search ends
	s2, _ := ParseCron("30 1 * * *")
	if got := s2.Next(mustUTC(t, "2026-11-01T07:00:00Z"), la); got.IsZero() || got.Hour() != 1 || got.Minute() != 30 {
		t.Errorf("DST-end next = %v", got)
	}
	// the day DST starts (8 March 2026): 02:30 does not exist, the search still ends
	s3, _ := ParseCron("30 2 * * *")
	if got := s3.Next(mustUTC(t, "2026-03-08T08:00:00Z"), la); got.IsZero() {
		t.Error("DST-start next is zero")
	}
}

func TestCronParseErrors(t *testing.T) {
	for _, e := range []string{"", "* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8",
		"5-1 * * * *", "*/0 * * * *", "5/20 * * * *", "0 0 1,$ * *", "0 0 $/2 * *", "0 seconds", "60 seconds", "@sometimes", "a * * * *", "1,,2 * * * *"} {
		if _, err := ParseCron(e); err == nil {
			t.Errorf("%q parsed, want an error", e)
		}
	}
}

func TestAddCronTimes(t *testing.T) {
	now := mustUTC(t, "2026-11-09T15:07:00Z")
	set := time.Date(2030, 1, 1, 0, 0, 0, 0, time.UTC)
	rows := []Row{
		{"kind": "job", "scheduler": "pg_cron", "job_id": 1, "schedule": "*/15 * * * *"},
		{"kind": "job", "scheduler": "pg_cron", "job_id": 2, "schedule": "@reboot"},
		{"kind": "job", "scheduler": "pg_cron", "job_id": 3, "schedule": "not a schedule"},
		{"kind": "job", "scheduler": "pgagent", "job_id": 4, "schedule": "*/5 * * * *"},
		{"kind": "job", "scheduler": "pg_cron", "job_id": 5, "schedule": "0 3 * * *", "next_run": set},
		{"kind": "run", "scheduler": "pg_cron", "job_id": 1, "run_id": 9},
	}
	AddCronTimes(rows, now, CronSettings{Timezone: "GMT"})
	if rows[0]["next_run"] != mustUTC(t, "2026-11-09T15:15:00Z") || rows[0]["prior_due"] != mustUTC(t, "2026-11-09T14:45:00Z") {
		t.Errorf("job 1: %v", rows[0])
	}
	if rows[1]["schedule_note"] == nil || rows[1]["next_run"] != nil || rows[1]["prior_due"] != nil {
		t.Errorf("@reboot: %v", rows[1])
	}
	if n, _ := rows[2]["schedule_note"].(string); !strings.HasPrefix(n, "schedule not parsed") {
		t.Errorf("bad schedule: %v", rows[2])
	}
	if len(rows[3]) != 4 || len(rows[5]) != 4 {
		t.Errorf("pgAgent or run rows touched: %v %v", rows[3], rows[5])
	}
	if rows[4]["next_run"] != set || rows[4]["prior_due"] != mustUTC(t, "2026-11-08T03:00:00Z") {
		t.Errorf("job 5: %v", rows[4])
	}
	rows = []Row{{"kind": "job", "scheduler": "pg_cron", "job_id": 1, "schedule": "0 3 * * *"}}
	AddCronTimes(rows, now, CronSettings{Timezone: "Nowhere/Atlantis"})
	if rows[0]["prior_due"] != nil || rows[0]["next_run"] == nil || rows[0]["schedule_note"] == nil {
		t.Errorf("unknown tz: %v", rows[0])
	}
}

func TestCronMatchDomAndDow(t *testing.T) {
	s, _ := ParseCron("0 0 1,15 * mon")
	after := mustUTC(t, "2026-11-16T01:00:00Z")
	if got := s.Next(after, time.UTC).Format(time.RFC3339); got != "2026-11-23T00:00:00Z" { // Vixie: the 1st, the 15th or a Monday
		t.Errorf("either-day next = %s", got)
	}
	s.matchBoth = true // cron.match_dom_and_dow on: a 1st or 15th that is a Monday
	if got := s.Next(after, time.UTC).Format(time.RFC3339); got != "2027-02-01T00:00:00Z" {
		t.Errorf("both-days next = %s", got)
	}
	if got := s.Prev(after, time.UTC).Format(time.RFC3339); got != "2026-06-15T00:00:00Z" {
		t.Errorf("both-days prev = %s", got)
	}
	rows := []Row{{"kind": "job", "scheduler": "pg_cron", "job_id": 1, "schedule": "0 0 1,15 * mon"}}
	AddCronTimes(rows, after, CronSettings{Timezone: "GMT", DomAndDow: true})
	if rows[0]["next_run"] != mustUTC(t, "2027-02-01T00:00:00Z") {
		t.Errorf("AddCronTimes with the setting: %v", rows[0])
	}
}

func TestAddCronTimesSettingsUnread(t *testing.T) {
	rows := []Row{{"kind": "job", "scheduler": "pg_cron", "job_id": 1, "schedule": "0 3 * * *"}}
	AddCronTimes(rows, mustUTC(t, "2026-11-09T15:07:00Z"), CronSettings{Timezone: "GMT", Err: errors.New("permission denied")})
	if n, _ := rows[0]["schedule_note"].(string); !strings.Contains(n, "not read") || rows[0]["prior_due"] != nil || rows[0]["next_run"] != nil {
		t.Errorf("unread settings: %v", rows[0])
	}
}

// TestCronTzdataEmbedded: the zone names pg_cron uses load without a system zone database (Windows).
func TestCronTzdataEmbedded(t *testing.T) {
	for _, z := range []string{"GMT", "America/New_York", "Asia/Kolkata"} {
		if _, err := time.LoadLocation(z); err != nil {
			t.Errorf("%s: %v", z, err)
		}
	}
}
