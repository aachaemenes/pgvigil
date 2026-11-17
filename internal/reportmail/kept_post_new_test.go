package reportmail

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// B20-4: the Daily checks mail also posts its counts through webhook channels - the block's post: list (each a
// webhook channel of the same file's alerts: block), the keep's post_channels, the post's text and the numbers a page
// sends back (checked before they are queued).
const postAlerts = `alerts:
  - {name: mail, kind: smtp, smtp: {host: 127.0.0.1, port: 25, from: a@b.org, to: [a@b.org]}}
  - {name: hook, kind: webhook, webhook: {url: env:X, format: json}}
  - {name: chat, kind: webhook, webhook: {url: env:Y, format: slack}}
`

func postBlock(post string) []byte {
	return []byte(postAlerts + "reports:\n  daily_checks:\n    enabled: true\n    at: 07:00\n    tz: UTC\n    to: [dba@example.org]\n    as: dba\n    channel: mail\n" + post)
}

func TestDailyChecksPostList(t *testing.T) {
	d, err := ParseDailyChecks(postBlock("    post: [hook, chat]\n"))
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(d.Post) != "[hook chat]" || fmt.Sprint(d.Request().Post) != "[hook chat]" {
		t.Errorf("post %v, the request's %v", d.Post, d.Request().Post)
	}
	// whether a changed list is a change is the repository's compare (0273; the proof's K19c): no key here says it
	pay, _, err := d.Request().Payload(time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(pay["post_channels"]) != "[hook chat]" {
		t.Errorf("the payload's post_channels %v", pay["post_channels"])
	}
	if d, err := ParseDailyChecks(postBlock("")); err != nil || len(d.Post) != 0 {
		t.Errorf("no post: %v %v", d, err)
	}
	for _, c := range []struct{ post, want string }{
		{"    post: [mail]\n", "reports.daily_checks: post: mail is not a webhook channel of alerts:"},
		{"    post: [hook, nope]\n", "reports.daily_checks: post: nope is not a webhook channel of alerts:"},
		{"    post: hook\n", "reports.daily_checks: post is a list of webhook channel names of the alerts: block, as [team-chat] (line 13 of the file)"},
		// review-26 go2 S2: an entry that is no channel name (a webhook's URL pasted for its channel) is named by its
		// place, never printed - serve's log and the support report carry the refusal; N1: an empty name the same
		{"    post: ['https://hooks.example/T0/secret']\n", "reports.daily_checks: post: entry 1 of the list is not a webhook channel of alerts:"},
		{"    post: [hook, https://hooks.example/T0/secret]\n", "reports.daily_checks: post: entry 2 of the list is not a webhook channel of alerts:"},
		{"    post: [hook, \"\"]\n", "reports.daily_checks: post: entry 2 of the list is not a webhook channel of alerts:"},
		{"    post: [Team Chat]\n", "reports.daily_checks: post: entry 1 of the list is not a webhook channel of alerts:"},
	} {
		if _, err := ParseDailyChecks(postBlock(c.post)); err == nil || err.Error() != c.want {
			t.Errorf("post %q: %v, want %q", strings.TrimSpace(c.post), err, c.want)
		}
	}
	// review-26 go2 N1: an alias reads as the list it stands for; a channel that takes its kind through a merge key
	// is a webhook channel
	alias := "instances:\n  - {name: pg1, dsn: env:D, tags: &hooks [hook, chat]}\n" + string(postBlock("    post: *hooks\n"))
	if d, err := ParseDailyChecks([]byte(alias)); err != nil || fmt.Sprint(d.Post) != "[hook chat]" {
		t.Errorf("post: *hooks: %v %v", d, err)
	}
	merged := "alerts:\n  - &h {name: hook, kind: webhook, webhook: {url: env:X, format: json}}\n  - {<<: *h, name: hook2}\n" +
		"  - {name: mail, kind: smtp, smtp: {host: 127.0.0.1, port: 25, from: a@b.org, to: [a@b.org]}}\n" +
		"reports:\n  daily_checks:\n    enabled: true\n    at: 07:00\n    tz: UTC\n    to: [dba@example.org]\n    as: dba\n    channel: mail\n    post: [hook2]\n"
	if d, err := ParseDailyChecks([]byte(merged)); err != nil || fmt.Sprint(d.Post) != "[hook2]" {
		t.Errorf("a channel with a merge key: %v %v", d, err)
	}
	// an off block is checked for enabled alone: its post list may stay for the day it is turned on again
	if _, err := ParseDailyChecks([]byte(postAlerts + "reports:\n  daily_checks:\n    enabled: false\n    post: [mail]\n")); err != nil {
		t.Errorf("an off block with post: [mail]: %v", err)
	}
}

func TestDailyPostText(t *testing.T) {
	p := DailyPost{Instances: 12, Critical: 3, Warnings: 4, Worst: []DailyWorst{{"sql01", 2, 0}, {"pg02", 1, 4}, {"pg03", 0, 1}}}
	got := p.Post("2026-11-16")
	if got.Kind != "daily checks" || got.Route != DailyChecksRoute || got.Title != "Daily checks 2026-11-16: 3 critical, 4 warnings on 12 instances" {
		t.Errorf("post %+v", got)
	}
	if strings.Join(got.Lines, "|") != "1. sql01: 2 critical|2. pg02: 1 critical, 4 warnings|3. pg03: 1 warning" {
		t.Errorf("lines %q", got.Lines)
	}
	if got.Fields["critical"] != 3 || got.Fields["warnings"] != 4 || got.Fields["instances"] != 12 || len(got.Fields["worst"].([]DailyWorst)) != 3 {
		t.Errorf("fields %v", got.Fields)
	}
	if z := (DailyPost{Instances: 5}).Post("2026-11-16"); z.Title != "Daily checks 2026-11-16: all checks pass on 5 instances" || len(z.Lines) != 0 {
		t.Errorf("a green day %+v", z)
	}
	// review-26 go1 N3: the day in Fields; a nil Worst is [] in the json, never null
	z := (DailyPost{Instances: 5}).Post("2026-11-16")
	if b, _ := json.Marshal(z.Fields); z.Fields["day"] != "2026-11-16" || !strings.Contains(string(b), `"worst":[]`) {
		t.Errorf("fields %s", b)
	}
	if one := (DailyPost{Instances: 1, Critical: 1, Worst: []DailyWorst{{"a", 1, 0}}}).Post("2026-11-16"); one.Title != "Daily checks 2026-11-16: 1 critical, 0 warnings on 1 instance" {
		t.Errorf("one instance %q", one.Title)
	}
}

func TestCheckDailyPost(t *testing.T) {
	ok := `{"instances": 12, "critical": 3, "warnings": 4, "worst": [{"name": "sql01", "critical": 2, "warnings": 0}, {"name": "` + strings.Repeat("é", 200) + `", "warnings": 1}]}`
	var p DailyPost
	if err := json.Unmarshal([]byte(ok), &p); err != nil || p.Check() != nil {
		t.Fatalf("a good post: %v %v", err, p.Check())
	}
	for _, c := range []struct{ body, want string }{
		{`{"instances": -1}`, "the post's counts are not counts"},
		{`{"instances": 2, "critical": 1, "worst": [{"name": "a"}, {"name": "b"}, {"name": "c"}, {"name": "d"}]}`, "the post names 4 instances: at most 3"},
		{`{"instances": 2, "critical": 1, "worst": [{"name": "` + strings.Repeat("x", 201) + `"}]}`, "the post's instance 1 has a name over 200 characters"},
		{`{"instances": 2, "critical": 1, "worst": [{"name": ""}]}`, "the post's instance 1 has no name"},
		{`{"instances": 2, "critical": 1, "worst": [{"name": "   ", "critical": 1}]}`, "the post's instance 1 has no name"},
		{`{"instances": 2, "critical": 1, "worst": [{"name": "a", "critical": -1}]}`, "the post's counts are not counts"},
		// review-26 go1 N2: a worst instance with no failing check, a name over two lines
		{`{"instances": 2, "critical": 1, "worst": [{"name": "a", "critical": 0, "warnings": 0}]}`, "the post's instance 1 has no failing check"},
		{`{"instances": 2, "critical": 1, "worst": [{"name": "a\nb", "critical": 1}]}`, "the post's instance 1 has a name with a line break or a tab"},
	} {
		var p DailyPost
		if err := json.Unmarshal([]byte(c.body), &p); err != nil {
			t.Fatal(err)
		}
		if err := p.Check(); err == nil || err.Error() != c.want {
			t.Errorf("%.60s: %v, want %q", c.body, err, c.want)
		}
	}
}
