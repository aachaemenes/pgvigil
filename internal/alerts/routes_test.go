package alerts

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

// A configured channel never takes a route's name: 'contact-<id>' is the derived channels'.
func TestRouteNameRefused(t *testing.T) {
	_, err := Parse([]byte("repository: {dsn: env:X}\nalerts:\n  - {name: contact-7, kind: file, file: {dir: /tmp}}\n"))
	if err == nil || !strings.Contains(err.Error(), "contact-") {
		t.Fatalf("a configured channel named contact-7 was taken: %v", err)
	}
}

// derive: a route's channel is the base's built channel with to: the contact, scoped by the application's tag alone,
// the base's numbers kept; a route whose base is missing or not smtp, or whose address the parser refuses, sends
// nothing and says why without the address; the base itself is untouched.
func TestDeriveRoutes(t *testing.T) {
	st, err := Parse([]byte(`
repository: {dsn: env:X}
alerts:
  - {name: mail, kind: smtp, min_severity: critical, repeat: 5m, max_per_hour: 3, quiet_hours: "22:00-06:00", timezone: UTC,
     instances: [b1], tags: [env:prod], smtp: {host: 127.0.0.1, port: 2525, tls: none, from: a@example.org, to: [dba@example.org]}}
  - {name: drop, kind: file, file: {dir: /tmp}}
`))
	if err != nil {
		t.Fatal(err)
	}
	rs := []route{
		{ID: 7, ContactID: 3, Role: "support", App: "Billing: EU", Channel: "mail", Mail: "Ann@Example.org"},
		{ID: 8, ContactID: 4, Role: "support", App: "Billing", Channel: "mail", Mail: `bad"q@example.org`},
		{ID: 9, ContactID: 5, Role: "support", App: "Billing", Channel: "drop", Mail: "x@example.org"},
		{ID: 10, ContactID: 6, Role: "support", App: "Billing", Channel: "gone", Mail: "y@example.org"},
		{ID: 11, ContactID: 7, Role: "escalation", App: "Billing", Channel: "mail", Severity: "warning", Mail: "z@example.org"},
	}
	ds := derive(st.Channels, rs)
	if len(ds) != 5 {
		t.Fatalf("derived %d of 5", len(ds))
	}
	d := ds[0]
	if d.note != "" || d.ch.Name != "contact-7" || !reflect.DeepEqual(d.ch.Tags, []string{"application:Billing: EU"}) || d.ch.Instances != nil {
		t.Errorf("route 7: note %q name %q tags %v instances %v", d.note, d.ch.Name, d.ch.Tags, d.ch.Instances)
	}
	if d.ch.MinSeverity != "critical" || d.ch.RepeatEvery() != 5*time.Minute || d.ch.MaxPerHour != 3 || d.ch.ClearAfterEvery() != DefaultClearAfter {
		t.Errorf("route 7 does not hold the base's numbers: %s %s %d %s", d.ch.MinSeverity, d.ch.RepeatEvery(), d.ch.MaxPerHour, d.ch.ClearAfterEvery())
	}
	night := time.Date(2026, 11, 14, 23, 0, 0, 0, time.UTC)
	if !d.ch.Quiet(night) || d.ch.Quiet(night.Add(12*time.Hour)) {
		t.Errorf("route 7 does not keep the base's quiet hours")
	}
	rsend, ok := d.ch.sender.(*routeSender)
	if !ok || !reflect.DeepEqual(rsend.smtp.to, []string{"Ann@Example.org"}) {
		t.Fatalf("route 7's sender: %#v", d.ch.sender)
	}
	if dest := d.ch.Destination(); strings.Contains(strings.ToLower(dest), "ann@") || !strings.Contains(dest, "contact 3") {
		t.Errorf("route 7's destination text %q (no address; the contact's id)", dest)
	}
	base := st.Channels[0]
	if base.Name != "mail" || !reflect.DeepEqual(base.Tags, []string{"env:prod"}) || !reflect.DeepEqual(base.Instances, []string{"b1"}) ||
		base.Destination() != "smtp://127.0.0.1:2525 to dba@example.org" {
		t.Errorf("the base changed: %q %v %v %q", base.Name, base.Tags, base.Instances, base.Destination())
	}
	for i, want := range map[int]string{1: "refused by the mail parser", 2: "not an smtp channel", 3: "not configured"} {
		if !strings.Contains(ds[i].note, want) || strings.Contains(ds[i].note, "@") {
			t.Errorf("route %d's note %q (want %q, no address)", rs[i].ID, ds[i].note, want)
		}
	}
	if ds[4].note != "" || ds[4].ch.MinSeverity != "warning" {
		t.Errorf("route 11's own severity: %q %q", ds[4].note, ds[4].ch.MinSeverity)
	}
}

// scrub: a relay's error names the recipient in any case; the log gets the contact's id instead.
func TestRouteScrub(t *testing.T) {
	got := scrub("smtp: 550 5.1.1 <ANN@example.ORG>: recipient address rejected", "contact 3", "Ann@Example.org", "Ann@Example.org")
	if strings.Contains(strings.ToLower(got), "ann@") || !strings.Contains(got, "<contact 3>") {
		t.Errorf("scrubbed %q", got)
	}
}
