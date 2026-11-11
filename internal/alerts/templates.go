package alerts

import (
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Templates is a channel's templates: block: a subject (a message's headline: the SMTP Subject, the first line of a
// chat post, Opsgenie's message) and a line (each alert's line) per event. An event without its own template uses the
// built-in text; escalated falls back to firing's template. Placeholders are {name} from tplFields; an unknown one is
// a configuration error, so a typing slip never sends "{instnace}" to a pager.
//
//	templates:
//	  subject: {firing: "{severity}: {setting} on {instance}", resolved: "OK: {setting} on {instance}"}
//	  line:    {firing: "{instance} {setting} = {value} (since {first_sent})", repeat: "still open: {instance} {setting}"}
type Templates struct {
	Subject map[string]string `yaml:"subject"`
	Line    map[string]string `yaml:"line"`
}

// tplEvents are the events a template may name.
var tplEvents = map[string]bool{"firing": true, "escalated": true, "repeat": true, "resolved": true}

// tplFields are the placeholders, each with what it holds (docs/alerts.md lists the same).
var tplFields = map[string]string{
	"event":      "firing, escalated, repeat or resolved",
	"severity":   "info, warning or critical",
	"instance":   "the instance's name",
	"source":     "the finding's source",
	"setting":    "the finding's setting or check",
	"value":      "the finding's value",
	"detail":     "the finding's detail sentence",
	"suggested":  "the suggested value",
	"first_sent": "when this channel first sent the alert (UTC, RFC 3339; empty on the first send)",
	"finding_at": "when the finding was read (UTC, RFC 3339)",
	"sends":      "this channel's earlier sends of the alert",
	"url":        "the address of the alert's page (empty without alerts_base_url)",
	"channel":    "the channel's name",
	"count":      "the alerts in the message (subject only)",
	"summary":    "the built-in headline, e.g. 'pgvigil: 2 new (1 critical)' (subject only)",
}

var tplRef = regexp.MustCompile(`\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// tplMax bounds one template (a subject or a line is short; the line is cut at maxLine anyway).
const tplMax = 1000

type compiled struct {
	subject, line map[string]string
}

// compile checks the block; nil block = nil (the built-in texts).
func (t *Templates) compile() (*compiled, error) {
	if t == nil {
		return nil, nil
	}
	out := &compiled{subject: map[string]string{}, line: map[string]string{}}
	for what, m := range map[string]map[string]string{"subject": t.Subject, "line": t.Line} {
		for ev, text := range m {
			if !tplEvents[ev] {
				return nil, fmt.Errorf("templates.%s.%s: the events are firing, escalated, repeat and resolved", what, ev)
			}
			if strings.TrimSpace(text) == "" {
				return nil, fmt.Errorf("templates.%s.%s is empty (leave it out for the built-in text)", what, ev)
			}
			if len(text) > tplMax {
				return nil, fmt.Errorf("templates.%s.%s is over %d bytes", what, ev, tplMax)
			}
			if strings.ContainsAny(text, "\r\n") && what == "subject" {
				return nil, fmt.Errorf("templates.subject.%s holds a line break (a subject is one line)", ev)
			}
			for _, m := range tplRef.FindAllStringSubmatch(text, -1) {
				if _, ok := tplFields[m[1]]; !ok {
					return nil, fmt.Errorf("templates.%s.%s: unknown placeholder {%s} (known: %s)", what, ev, m[1], strings.Join(tplNames(), ", "))
				}
				if what == "line" && (m[1] == "count" || m[1] == "summary") {
					return nil, fmt.Errorf("templates.line.%s: {%s} belongs to a subject, not a line", ev, m[1])
				}
			}
			if what == "subject" {
				out.subject[ev] = text
			} else {
				out.line[ev] = strings.ReplaceAll(text, "\r", "")
			}
		}
	}
	if len(out.subject)+len(out.line) == 0 {
		return nil, nil
	}
	return out, nil
}

func tplNames() []string {
	n := make([]string, 0, len(tplFields))
	for k := range tplFields {
		n = append(n, k)
	}
	sort.Strings(n)
	return n
}

// words is what alert_channels records of the templates: the events and parts set ("subject firing, line resolved"),
// never the text (it may name a team's escalation contact).
func (c *compiled) words() string {
	if c == nil {
		return ""
	}
	var w []string
	for _, ev := range []string{"firing", "escalated", "repeat", "resolved"} {
		if _, ok := c.subject[ev]; ok {
			w = append(w, "subject "+ev)
		}
		if _, ok := c.line[ev]; ok {
			w = append(w, "line "+ev)
		}
	}
	return strings.Join(w, ", ")
}

// pick returns the template of an event (escalated falls back to firing; cleared to resolved).
func pick(m map[string]string, ev string) (string, bool) {
	if t, ok := m[ev]; ok {
		return t, true
	}
	switch ev {
	case "escalated":
		t, ok := m["firing"]
		return t, ok
	case "cleared":
		t, ok := m["resolved"]
		return t, ok
	}
	return "", false
}

func stamp(t *time.Time) string {
	if t == nil {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// fill replaces every known placeholder of text with its value; a subject is kept on one line.
func fill(text string, a Alert, channel string, extra map[string]string) string {
	vals := map[string]string{"event": a.Event, "severity": a.Severity, "instance": a.Instance, "source": a.Source,
		"setting": a.Setting, "value": a.Value, "detail": a.Detail, "suggested": a.Suggested,
		"first_sent": stamp(a.FirstSentAt), "finding_at": stamp(a.FindingAt), "sends": strconv.Itoa(a.SentBefore),
		"url": a.URL, "channel": channel}
	for k, v := range extra {
		vals[k] = v
	}
	return tplRef.ReplaceAllStringFunc(text, func(m string) string {
		if v, ok := vals[m[1:len(m)-1]]; ok {
			return v
		}
		return m
	})
}

// link is the address of an alert's page: alerts_base_url + #/alert?k=<finding key>&t=<unix seconds of the alert's
// first send, or of now on a first send>; "" without a base address or a finding key.
func (c *Channel) link(a Alert, now time.Time) string {
	if c.base == "" || a.FindingKey == "" {
		return ""
	}
	at := now
	if a.FirstSentAt != nil {
		at = *a.FirstSentAt
	}
	q := url.Values{}
	q.Set("k", a.FindingKey)
	q.Set("t", strconv.FormatInt(at.Unix(), 10))
	return c.base + "/#/alert?" + q.Encode()
}

// decorate gives an owed alert its page address and the channel's line template.
func (c *Channel) decorate(a Alert, now time.Time) Alert {
	a.URL = c.link(a, now)
	if c.tpl != nil {
		if t, ok := pick(c.tpl.line, a.Event); ok {
			a.text = fill(t, a, c.Name, nil)
		}
	}
	return a
}

// subject fills the channel's subject template for one message: the template of the message's leading event (any
// firing or escalated alert, else any repeat, else the recoveries) from the first alert of that event; "" = none set
// (the built-in summary).
func (c *Channel) subject(batch []Alert) string {
	if c.tpl == nil || len(c.tpl.subject) == 0 || len(batch) == 0 {
		return ""
	}
	lead := func(evs ...string) (Alert, bool) {
		for _, a := range batch {
			for _, e := range evs {
				if a.Event == e {
					return a, true
				}
			}
		}
		return Alert{}, false
	}
	var a Alert
	var ok bool
	for _, evs := range [][]string{{"escalated", "firing"}, {"repeat"}, {"resolved", "cleared"}} {
		if a, ok = lead(evs...); ok {
			break
		}
	}
	if !ok {
		return ""
	}
	t, has := pick(c.tpl.subject, a.Event)
	if !has {
		return ""
	}
	built := Message{Alerts: batch}.Summary()
	s := fill(t, a, c.Name, map[string]string{"count": strconv.Itoa(len(batch)), "summary": built})
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > maxLine {
		s = capLine(s)
	}
	return s
}
