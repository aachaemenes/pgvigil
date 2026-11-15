package reportmail

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

const dailyWhole = `
repository:
  dsn: env:X
reports:
  daily_checks:
    enabled: true
    at: 07:00
    tz: America/Los_Angeles
    to: [DBA@Example.org, second@example.org]
    as: Alice
    channel: mail
`

// the block through the real loader: absent, whole, off, and each way it is refused, the refusal naming the key
func TestParseDailyChecks(t *testing.T) {
	d, err := ParseDailyChecks([]byte(dailyWhole))
	if err != nil || d == nil || !d.On() {
		t.Fatalf("the whole block: %+v, %v", d, err)
	}
	// an unquoted 07:00 is the text 07:00 (YAML 1.2 has no base-60 numbers), and it is the cron line 0 7
	if line, err := d.Cron(); d.At != "07:00" || err != nil || line != "0 7 * * *" {
		t.Errorf("at: %q, the line %q, %v", d.At, line, err)
	}
	if d.TZ != "America/Los_Angeles" || d.As != "Alice" || d.Channel != "mail" || len(d.To) != 2 {
		t.Errorf("the block's fields: %+v", d)
	}

	for _, c := range []struct{ name, yaml string }{
		{"no reports block", "repository:\n  dsn: env:X\n"},
		{"an empty reports block", "reports:\n"},
		{"reports with no daily_checks", "reports: {}\n"},
	} {
		if d, err := ParseDailyChecks([]byte(c.yaml)); d != nil || err != nil {
			t.Errorf("%s: want absent, got %+v, %v", c.name, d, err)
		}
	}

	off, err := ParseDailyChecks([]byte("reports:\n  daily_checks:\n    enabled: false\n"))
	if err != nil || off == nil || off.On() {
		t.Errorf("an off block with nothing else: %+v, %v", off, err)
	}
	// an off block keeps its other keys unchecked for the day it is turned on again
	if off, err := ParseDailyChecks([]byte("reports:\n  daily_checks:\n    enabled: false\n    at: 7:05\n    to: [a@example.org]\n")); err != nil || off == nil || off.On() {
		t.Errorf("an off block with keys: %+v, %v", off, err)
	}
	if d, err := ParseDailyChecks([]byte(strings.Replace(dailyWhole, "at: 07:00", "at: 7:05", 1))); err != nil || d.At != "7:05" {
		t.Errorf("at: 7:05: %+v, %v", d, err)
	} else if line, _ := d.Cron(); line != "5 7 * * *" {
		t.Errorf("at: 7:05 is the line %q", line)
	}

	many := make([]string, 51)
	for i := range many {
		many[i] = fmt.Sprintf("u%d@example.org", i)
	}
	drop := func(key string) string {
		var out []string
		for _, l := range strings.Split(dailyWhole, "\n") {
			if !strings.HasPrefix(strings.TrimSpace(l), key+":") {
				out = append(out, l)
			}
		}
		return strings.Join(out, "\n")
	}
	for _, c := range []struct{ name, yaml, want string }{
		{"a typo of the block's name", strings.Replace(dailyWhole, "daily_checks:", "daily_check:", 1), "daily_check"},
		{"a typo of enabled", strings.Replace(dailyWhole, "enabled: true", "enable: true", 1), "enable"},
		{"an unknown key in the block", dailyWhole + "    only_failing: true\n", "only_failing"},
		{"reports as a list", "reports: [a]\n", "block of keys"},
		{"no enabled", drop("enabled"), "enabled is required"},
		{"no at", drop("at"), "at is required"},
		{"no tz", drop("tz"), "tz is required"},
		{"no to", drop("to"), "to is required"},
		{"no as", drop("as"), "as is required"},
		{"no channel", drop("channel"), "channel is required"},
		{"a bad hour", strings.Replace(dailyWhole, "at: 07:00", "at: 25:00", 1), "at:"},
		{"a bad zone", strings.Replace(dailyWhole, "America/Los_Angeles", "Mars/Olympus", 1), "tz:"},
		{"a bad address", strings.Replace(dailyWhole, "DBA@Example.org", "nobody", 1), "to: address 1 of the list is not one mail address"},
		{"a bad second address", strings.Replace(dailyWhole, "second@example.org", "second@", 1), "to: address 2 of the list"},
		{"51 addresses", strings.Replace(dailyWhole, "[DBA@Example.org, second@example.org]", "["+strings.Join(many, ", ")+"]", 1), "at most 50"},
		{"an application contact's route", strings.Replace(dailyWhole, "channel: mail", "channel: contact-7", 1), "application contact"},
	} {
		d, err := ParseDailyChecks([]byte(c.yaml))
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want an error naming %q, got %+v, %v", c.name, c.want, d, err)
		}
		// a value the person wrote is never in the refusal (the hour and the zone are settings, shown in the report anyway)
		for _, no := range []string{"nobody", "second@", "contact-7", "Mars/Olympus"} {
			if err != nil && strings.Contains(err.Error(), no) && !strings.Contains(c.name, "zone") {
				t.Errorf("%s: the refusal holds the value %q: %v", c.name, no, err)
			}
		}
	}
}

// the refusal a person reads: the key by its name in plain words, with the line it stands on in the file, and never
// the value (the support report prints the refusal); no Go type, no YAML tag, one line
func TestParseDailyChecksWords(t *testing.T) {
	for _, c := range []struct{ name, yaml, want string }{
		{"a typo of the block's name", strings.Replace(dailyWhole, "daily_checks:", "daily_check:", 1),
			"reports: daily_check is not a key of the block (line 5 of the file); its keys: daily_checks"},
		{"a typo of enabled", strings.Replace(dailyWhole, "enabled: true", "enable: true", 1),
			"reports.daily_checks: enable is not a key of the block (line 6 of the file); its keys: enabled, at, tz, to, as, channel"},
		{"an unknown key at the end", dailyWhole + "    only_failing: true\n", "reports.daily_checks: only_failing is not a key of the block (line 12 of the file)"},
		{"a key written twice", dailyWhole + "    at: 08:00\n", "reports.daily_checks: at is written twice (line 12 of the file)"},
		{"to as one string", strings.Replace(dailyWhole, "[DBA@Example.org, second@example.org]", "DBA@Example.org", 1),
			"reports.daily_checks: to is a list of mail addresses, as [dba@example.org] (line 9 of the file)"},
		{"enabled: maybe", strings.Replace(dailyWhole, "enabled: true", "enabled: maybe", 1), "reports.daily_checks: enabled is true or false (line 6 of the file)"},
		{"at as a list", strings.Replace(dailyWhole, "at: 07:00", "at: [7, 0]", 1), "reports.daily_checks: at is the hour of the daily mail, HH:MM (one value) (line 7 of the file)"},
		{"as as a block", strings.Replace(dailyWhole, "as: Alice", "as: {name: Alice}", 1), "reports.daily_checks: as is the name of a UI user (one value) (line 10 of the file)"},
		{"at: 0700", strings.Replace(dailyWhole, "at: 07:00", "at: 0700", 1), "reports.daily_checks: at: "},
		{"the block as a list", "reports:\n  daily_checks: [a]\n", "reports.daily_checks: is a block of keys (enabled, at, tz, to, as, channel) (line 2 of the file)"},
		{"reports as a list", "reports: [a]\n", "reports: is a block of keys (daily_checks) (line 1 of the file)"},
		{"an unknown key in a merged block", "base: &b {tz: UTC, colour: blue}\nreports:\n  daily_checks:\n    <<: *b\n    enabled: false\n",
			"reports.daily_checks: colour is not a key of the block (line 1 of the file)"},
	} {
		d, err := ParseDailyChecks([]byte(c.yaml))
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want an error holding %q, got %+v, %v", c.name, c.want, d, err)
			continue
		}
		for _, no := range []string{"yaml", "unmarshal", "reportmail.", "!!", "\n", "DBA@Example", "maybe", "Alice"} {
			if strings.Contains(err.Error(), no) {
				t.Errorf("%s: the refusal holds %q: %v", c.name, no, err)
			}
		}
	}

	// an alias reads as what it stands for, its anchor anywhere in the file (config.Load takes the same file); a merge
	// key brings its keys in, and a key of the block's own goes first
	const anchored = `
alerts:
  - name: mail
    kind: smtp
    smtp: {host: relay.example.org, to: &dba_list [dba@example.org, second@example.org]}
defaults: &daily
  tz: UTC
  channel: mail
reports:
  daily_checks:
    <<: *daily
    enabled: true
    at: 07:00
    tz: America/Los_Angeles
    to: *dba_list
    as: alice
`
	d, err := ParseDailyChecks([]byte(anchored))
	if err != nil || d == nil || !d.On() || len(d.To) != 2 || d.To[1] != "second@example.org" || d.TZ != "America/Los_Angeles" || d.Channel != "mail" {
		t.Errorf("an alias from another block and a merge key: %+v, %v", d, err)
	}
	if d, err := ParseDailyChecks([]byte("shared: &rep\n  daily_checks:\n    enabled: false\nreports: *rep\n")); err != nil || d == nil || d.On() {
		t.Errorf("reports: as an alias: %+v, %v", d, err)
	}
	// yes and no are a switch as everywhere in the file (YAML 1.1's words, read as the file's other switches read them)
	if d, err := ParseDailyChecks([]byte(strings.Replace(dailyWhole, "enabled: true", "enabled: yes", 1))); err != nil || d == nil || !d.On() {
		t.Errorf("enabled: yes: %+v, %v", d, err)
	}
	if d, err := ParseDailyChecks([]byte(strings.Replace(dailyWhole, "enabled: true", "enabled: no", 1))); err != nil || d == nil || d.On() {
		t.Errorf("enabled: no: %+v, %v", d, err)
	}
	// a key with nothing after it is a missing key, named as required
	if d, err := ParseDailyChecks([]byte(strings.Replace(dailyWhole, "channel: mail", "channel:", 1))); err == nil || !strings.Contains(err.Error(), "channel is required") {
		t.Errorf("channel: with nothing after it: %+v, %v", d, err)
	}
}

// a keep's payload: what the store compares on is the same however the setting spells it
func TestKeptPayload(t *testing.T) {
	now := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	a := KeptRequest{At: "07:05", TZ: "UTC", As: "alice", Channel: "mail", To: []string{"a@example.org"}, AttachXLSX: true}
	b := KeptRequest{At: "7:05", TZ: "UTC", As: " Alice ", Channel: " mail ", To: []string{"A@Example.org", "a@example.org"}, AttachXLSX: true}
	pa, ka, err := a.Payload(now)
	if err != nil {
		t.Fatal(err)
	}
	pb, kb, err := b.Payload(now.Add(3 * time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if ka != kb {
		t.Errorf("the keys differ:\n%s\n%s", ka, kb)
	}
	if pa["cron"] != "5 7 * * *" || pb["cron"] != "5 7 * * *" || pb["as"] != "alice" || pb["channel"] != "mail" || fmt.Sprint(pb["recipients"]) != "[a@example.org]" {
		t.Errorf("the payloads: %v / %v", pa, pb)
	}
	if pa["kept_as"] != KeptDailyChecks || pa["attach_xlsx"] != true || pa["timezone"] != "UTC" {
		t.Errorf("the payload's fixed fields: %v", pa)
	}
	// the next send: tomorrow 07:05 UTC from noon, and it is not part of the key
	if next, err := time.Parse(time.RFC3339, fmt.Sprint(pa["next_at"])); err != nil || !next.Equal(time.Date(2026, 11, 16, 7, 5, 0, 0, time.UTC)) {
		t.Errorf("next_at %v, %v", pa["next_at"], err)
	}
	if strings.Contains(ka, "2026") {
		t.Errorf("the key holds a time: %s", ka)
	}
	c := a
	c.At = "08:05"
	if _, kc, _ := c.Payload(now); kc == ka {
		t.Error("another hour has the same key")
	}
	for _, bad := range []KeptRequest{
		{At: "", TZ: "UTC", As: "alice", Channel: "mail", To: []string{"a@example.org"}},
		{At: "07:05", TZ: "", As: "alice", Channel: "mail", To: []string{"a@example.org"}},
		{At: "07:05", TZ: "UTC", As: "", Channel: "mail", To: []string{"a@example.org"}},
		{At: "07:05", TZ: "UTC", As: "alice", Channel: "", To: []string{"a@example.org"}},
		{At: "07:05", TZ: "UTC", As: "alice", Channel: "mail"},
	} {
		if _, _, err := bad.Payload(now); err == nil {
			t.Errorf("%+v: no error", bad)
		}
	}
}

func TestAtOfCron(t *testing.T) {
	for line, want := range map[string]string{
		"5 7 * * *": "07:05", "0 0 * * *": "00:00", "59 23 * * *": "23:59", "0 7 * * 1-5": "", "*/15 * * * *": "", "0 24 * * *": "", "": "",
	} {
		if got := AtOfCron(line); got != want {
			t.Errorf("AtOfCron(%q) = %q, want %q", line, got, want)
		}
	}
}
