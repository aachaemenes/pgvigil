package alerts

import (
	"strings"
	"testing"
	"time"
)

// task 403a: the window request, the rule request's new fields, the tag list and the digest message.

func TestWindowPayload(t *testing.T) {
	inst := func(id int) string {
		if id == 7 {
			return "erp01"
		}
		return ""
	}
	good := WindowRequest{Action: "digest", Scope: "fleet", Weekdays: []int{1, 2, 3, 4, 5}, Start: "22:00", End: "06:00", Zone: "America/Chicago"}
	pay, err := WindowPayload(good, inst)
	if err != nil {
		t.Fatalf("a good digest window: %v", err)
	}
	if pay["op"] != "add" || pay["severity_ceiling"] != "warning" || pay["zone"] != "America/Chicago" {
		t.Fatalf("payload %v: want op add, ceiling warning (the default), the zone", pay)
	}
	bad := map[string]WindowRequest{
		"action":           {Action: "pause", Scope: "fleet", Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC"},
		"weekday 8":        {Action: "mute", Scope: "fleet", Weekdays: []int{8}, Start: "01:00", End: "02:00", Zone: "UTC"},
		"no weekday":       {Action: "mute", Scope: "fleet", Start: "01:00", End: "02:00", Zone: "UTC"},
		"start = end":      {Action: "mute", Scope: "fleet", Weekdays: []int{1}, Start: "22:00", End: "22:00", Zone: "UTC"},
		"start not HH:MM":  {Action: "mute", Scope: "fleet", Weekdays: []int{1}, Start: "25:00", End: "02:00", Zone: "UTC"},
		"zone":             {Action: "mute", Scope: "fleet", Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "Mars/Base"},
		"no zone":          {Action: "mute", Scope: "fleet", Weekdays: []int{1}, Start: "01:00", End: "02:00"},
		"critical ceiling": {Action: "digest", SeverityCeiling: "critical", Scope: "fleet", Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC"},
		"ceiling on mute":  {Action: "mute", SeverityCeiling: "info", Scope: "fleet", Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC"},
		"no scope":         {Action: "mute", Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC"},
		"no instance":      {Action: "mute", Scope: "instance", InstanceID: 8, Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC"},
		"empty tag list":   {Action: "mute", Scope: "tags", ScopeTags: []string{" "}, Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC"},
		"until":            {Action: "mute", Scope: "fleet", Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC", Until: "tomorrow"},
		"edit without id":  {Op: "edit", Action: "mute", Scope: "fleet", Weekdays: []int{1}, Start: "01:00", End: "02:00", Zone: "UTC"},
	}
	for name, in := range bad {
		if _, err := WindowPayload(in, inst); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	pay, err = WindowPayload(WindowRequest{Action: "mute", Scope: "instance", InstanceID: 7, Weekdays: []int{7}, Start: "01:00", End: "02:00", Zone: "UTC"}, inst)
	if err != nil || pay["instance_name"] != "erp01" {
		t.Fatalf("an instance window: %v %v", pay, err)
	}
	pay, err = WindowPayload(WindowRequest{Action: "mute", FromRuleID: 3, Weekdays: []int{7}, Start: "01:00", End: "02:00", Zone: "UTC"}, inst)
	if err != nil || pay["from_rule_id"] != int64(3) || pay["scope"] != nil {
		t.Fatalf("a window from a rule's scope: %v %v", pay, err)
	}
	if pay, err := WindowPayload(WindowRequest{Op: "end", WindowID: 4}, inst); err != nil || len(pay) != 2 {
		t.Fatalf("end: %v %v", pay, err)
	}
}

func TestScopeTagList(t *testing.T) {
	got, err := ScopeTagList([]string{" Env:prod ", "", "app:billing"})
	if err != nil || strings.Join(got, ",") != "env:prod,app:billing" {
		t.Fatalf("got %v %v: want the written forms, the blank dropped", got, err)
	}
	many := make([]string, MaxScopeTags+1)
	for i := range many {
		many[i] = "k:" + strings.Repeat("v", i+1)
	}
	if _, err := ScopeTagList(many); err == nil {
		t.Fatal("more than MaxScopeTags accepted")
	}
}

func TestRulePayloadFamilies(t *testing.T) {
	w, c := 5.0, 3.0
	base := RuleRequest{Metric: "sessions.idle_in_txn", Warning: &w, Scope: "fleet"}
	for _, dir := range []string{"rises", "above", "below"} {
		in := base
		in.Dir = dir
		if _, err := RulePayload(in, "", nil); err != nil {
			t.Errorf("%s: %v", dir, err)
		}
	}
	in := base
	in.Dir = "above_baseline"
	if _, err := RulePayload(in, "", nil); err == nil {
		t.Error("a baseline rule without a zone accepted")
	}
	in.Zone = "America/Chicago"
	band := 1001.0
	in.BandPct = &band
	if _, err := RulePayload(in, "", nil); err == nil {
		t.Error("band 1001 accepted")
	}
	band = 20
	pay, err := RulePayload(in, "", nil)
	if err != nil || pay["zone"] != "America/Chicago" || pay["band_pct"] != 20.0 {
		t.Fatalf("a baseline rule: %v %v", pay, err)
	}
	in = base
	in.Dir, in.Critical = "rises", &c // critical 3 under warning 5 on a rising rule
	if _, err := RulePayload(in, "", nil); err == nil {
		t.Error("a rise rule with critical under warning accepted")
	}
	in = base
	in.Dir, in.Scope, in.ScopeTags = "above", "tags", []string{"env:prod", "env:stage"}
	no := true
	in.IgnoreFlapping = &no
	pay, err = RulePayload(in, "", nil)
	if err != nil || pay["ignore_flapping"] != true || len(pay["scope_tags"].([]string)) != 2 {
		t.Fatalf("a tags rule: %v %v", pay, err)
	}
	in.Dir = "sideways"
	if _, err := RulePayload(in, "", nil); err == nil {
		t.Error("op_dir sideways accepted")
	}
}

func TestDigestMessage(t *testing.T) {
	c := &Channel{Name: "dba-mail", loc: time.UTC}
	t0 := time.Date(2026, 11, 16, 6, 0, 0, 0, time.UTC)
	var gs []digestGroup
	for i := 0; i < maxDigestGroups+3; i++ {
		gs = append(gs, digestGroup{Instance: "erp01", Check: "alert rule: Sessions", Severity: "warning", Alerts: 2,
			First: t0, Last: t0.Add(time.Hour), Detail: "the newest detail"})
	}
	m := digestMessage(c, gs, t0.Add(-24*time.Hour), t0.Add(2*time.Hour))
	if len(m.Alerts) != maxDigestGroups+1 {
		t.Fatalf("%d lines: want %d groups and the '+N more' line", len(m.Alerts), maxDigestGroups)
	}
	if last := m.Alerts[len(m.Alerts)-1].Line(); !strings.Contains(last, "+3 more group(s)") {
		t.Fatalf("the last line %q", last)
	}
	if l := m.Alerts[0].Line(); !strings.Contains(l, "erp01 - alert rule: Sessions: 2 alert(s) held") || !strings.Contains(l, "newest: the newest detail") {
		t.Fatalf("a group's line %q", l)
	}
	if !strings.Contains(m.Summary(), "daily digest") || !strings.Contains(m.Summary(), "86 alert(s) held on dba-mail") {
		t.Fatalf("the subject %q", m.Summary())
	}
	for _, a := range m.Alerts {
		if a.Event != "digest" {
			t.Fatalf("event %q: every digest line is event 'digest'", a.Event)
		}
	}
}

func TestChannelDigestAndChecks(t *testing.T) {
	h := 24
	cfg := "repository: {dsn: env:X}\nalerts:\n  - {name: m, kind: file, digest_hour: %d, file: {dir: /tmp}}\n"
	if _, err := Parse([]byte(strings.Replace(cfg, "%d", "24", 1))); err == nil {
		t.Errorf("digest_hour %d accepted", h)
	}
	if _, err := Parse([]byte(strings.Replace(cfg, "%d", "8", 1))); err != nil {
		t.Errorf("digest_hour 8: %v", err)
	}
	pd := "repository: {dsn: env:X}\nalerts:\n  - {name: p, kind: pagerduty, digest_hour: 8, pagerduty: {routing_key: env:K}}\n"
	if _, err := Parse([]byte(pd)); err == nil || !strings.Contains(err.Error(), "digest_hour") {
		t.Errorf("a pagerduty digest: %v", err)
	}
	ck := "repository: {dsn: env:X}\nalerts:\n  - {name: m, kind: file, checks: [' Backups '], file: {dir: /tmp}}\n"
	cfgs, err := Parse([]byte(ck))
	if err != nil {
		t.Fatalf("checks: %v", err)
	}
	if got := cfgs.Channels[0].Checks; len(got) != 1 || got[0] != "backups" {
		t.Errorf("checks %v: want [backups]", got)
	}
}
