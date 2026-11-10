package alerts

import (
	"bufio"
	"context"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

func msg(alerts ...Alert) Message {
	return Message{Channel: "t", SentAt: time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC), Alerts: alerts}
}

var crit = Alert{Event: "firing", FindingKey: "0123456789abcdef", Instance: "erp01", Severity: "critical", Source: "pgvigil host",
	Setting: "disk free under 10 %", Value: "/: 4.0 % free", Detail: "the volume fills", Suggested: "grow it"}

func TestParse(t *testing.T) {
	t.Setenv("PGV_TEST_HOOK", "https://hooks.example.org/workflows/abc?sig=secret")
	good := `
repository: {dsn: env:X}
alerts:
  - name: mail
    kind: smtp
    smtp: {host: 127.0.0.1, port: 2525, tls: none, from: a@example.org, to: [b@example.org]}
  - name: teams
    kind: webhook
    min_severity: critical
    tags: [env:prod, Prod]
    quiet_hours: "22:00-06:30"
    timezone: America/Chicago
    repeat: disabled
    recovery: false
    webhook: {url: env:PGV_TEST_HOOK, format: teams}
  - name: drop
    kind: file
    file: {dir: /tmp}
`
	st, err := Parse([]byte(good))
	if err != nil {
		t.Fatal(err)
	}
	chs := st.Channels
	if len(chs) != 3 {
		t.Fatalf("channels %d", len(chs))
	}
	if chs[0].MinSeverity != "warning" || chs[0].RepeatEvery() != DefaultRepeat || !chs[0].SendsRecovery() || chs[0].ClearAfterEvery() != DefaultClearAfter {
		t.Errorf("defaults: %+v", chs[0])
	}
	if chs[1].RepeatEvery() != 0 || chs[1].SendsRecovery() || chs[1].Tags[0] != "env:prod" || chs[1].Tags[1] != "Prod" {
		t.Errorf("teams: repeat %s recovery %v tags %v", chs[1].RepeatEvery(), chs[1].SendsRecovery(), chs[1].Tags)
	}
	if d := chs[1].Destination(); d != "https://hooks.example.org (teams)" {
		t.Errorf("the webhook's destination shows its path or token: %q", d)
	}
	if d := chs[0].Destination(); d != "smtp://127.0.0.1:2525 to b@example.org" {
		t.Errorf("smtp destination %q", d)
	}
	none, err := Parse([]byte("repository: {dsn: env:X}\n"))
	if err != nil || len(none.Channels) != 0 || none.DSN() != "" {
		t.Errorf("no alerts block: %v %v", none, err)
	}
	t.Setenv("PGV_TEST_ADSN", "host=x user=pgvigil_alerts")
	ds, err := Parse([]byte("alerts_dsn: env:PGV_TEST_ADSN\nalerts: [{name: a, kind: file, clear_after: 0, file: {dir: /tmp}}]\n"))
	if err != nil || ds.DSN() != "host=x user=pgvigil_alerts" || ds.Channels[0].ClearAfterEvery() != 0 {
		t.Errorf("alerts_dsn and clear_after 0: %+v %v", ds, err)
	}
	if _, err := Parse([]byte("alerts_dsn: env:PGV_TEST_UNSET_ADSN\n")); err == nil {
		t.Error("an alerts_dsn whose variable is unset was accepted")
	}
}

func TestParseRefuses(t *testing.T) {
	t.Setenv("PGV_TEST_EMPTY", "")
	cases := map[string]string{
		"inline webhook url":     `{name: a, kind: webhook, webhook: {url: "https://x.example.org/t"}}`,
		"empty env":              `{name: a, kind: webhook, webhook: {url: env:PGV_TEST_EMPTY}}`,
		"plain smtp off host":    `{name: a, kind: smtp, smtp: {host: relay.example.org, tls: none, from: a@b.c, to: [d@e.f]}}`,
		"inline smtp password":   `{name: a, kind: smtp, smtp: {host: relay.example.org, username: u, password: pw, from: a@b.c, to: [d@e.f]}}`,
		"login over plain smtp":  `{name: a, kind: smtp, smtp: {host: 127.0.0.1, tls: none, username: u, password: env:HOME, from: a@b.c, to: [d@e.f]}}`,
		"no recipient":           `{name: a, kind: smtp, smtp: {host: relay.example.org, from: a@b.c}}`,
		"two blocks":             `{name: a, kind: file, file: {dir: /tmp}, smtp: {host: x}}`,
		"kind mismatch":          `{name: a, kind: smtp, file: {dir: /tmp}}`,
		"relative dir":           `{name: a, kind: file, file: {dir: spool}}`,
		"bad severity":           `{name: a, kind: file, min_severity: high, file: {dir: /tmp}}`,
		"bad name":               `{name: "A b", kind: file, file: {dir: /tmp}}`,
		"repeat too short":       `{name: a, kind: file, repeat: 1m, file: {dir: /tmp}}`,
		"bad quiet hours":        `{name: a, kind: file, quiet_hours: "22-6", file: {dir: /tmp}}`,
		"bad timezone":           `{name: a, kind: file, timezone: Mars/Base, file: {dir: /tmp}}`,
		"bad tag":                `{name: a, kind: file, tags: ["Env:"], file: {dir: /tmp}}`,
		"bad webhook format":     `{name: a, kind: webhook, webhook: {url: env:HOME, format: xml}}`,
		"empty instance":         `{name: a, kind: file, instances: [""], file: {dir: /tmp}}`,
		"negative clear_after":   `{name: a, kind: file, clear_after: -1m, file: {dir: /tmp}}`,
		"http webhook off host":  `{name: a, kind: webhook, webhook: {url: env:PGV_TEST_HTTP}}`,
		"unknown kind":           `{name: a, kind: pager, file: {dir: /tmp}}`,
		"duplicate channel name": `{name: a, kind: file, file: {dir: /tmp}}, {name: a, kind: file, file: {dir: /tmp}}`,
	}
	t.Setenv("PGV_TEST_HTTP", "http://hooks.example.org/x")
	for name, c := range cases {
		if _, err := Parse([]byte("alerts: [" + c + "]")); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestQuiet(t *testing.T) {
	st, err := Parse([]byte(`alerts: [{name: a, kind: file, quiet_hours: "22:00-06:30", timezone: America/Chicago, file: {dir: /tmp}}]`))
	if err != nil {
		t.Fatal(err)
	}
	c := &st.Channels[0]
	chi, _ := time.LoadLocation("America/Chicago")
	for _, tc := range []struct {
		h, m  int
		quiet bool
	}{{21, 59, false}, {22, 0, true}, {2, 0, true}, {6, 29, true}, {6, 30, false}, {12, 0, false}} {
		at := time.Date(2026, 11, 10, tc.h, tc.m, 0, 0, chi).UTC()
		if got := c.Quiet(at); got != tc.quiet {
			t.Errorf("%02d:%02d Chicago: quiet %v, want %v", tc.h, tc.m, got, tc.quiet)
		}
	}
	day, _ := Parse([]byte(`alerts: [{name: a, kind: file, quiet_hours: "09:00-17:00", file: {dir: /tmp}}]`))
	if !day.Channels[0].Quiet(time.Date(2026, 1, 1, 9, 0, 0, 0, time.UTC)) || day.Channels[0].Quiet(time.Date(2026, 1, 1, 17, 0, 0, 0, time.UTC)) {
		t.Error("a same-day window, UTC by default")
	}
}

func TestBatches(t *testing.T) {
	a := make([]Alert, 120)
	if b := batches(a, false); len(b) != (120+maxPerMessage-1)/maxPerMessage || len(b[len(b)-1]) != 120-(len(b)-1)*maxPerMessage {
		t.Errorf("120 alerts in messages of %d: %d", maxPerMessage, len(b))
	}
	if b := batches(a[:3], true); len(b) != 3 {
		t.Errorf("per alert: %d", len(b))
	}
	if b := batches(nil, false); len(b) != 0 {
		t.Errorf("nothing owed: %d", len(b))
	}
}

func TestSummary(t *testing.T) {
	m := msg(crit, Alert{Event: "repeat", Severity: "warning"}, Alert{Event: "resolved", Severity: "critical"})
	if s := m.Summary(); s != "pgvigil: 1 new, 1 still open, 1 resolved (1 critical)" {
		t.Errorf("summary %q", s)
	}
	if l := crit.Line(); !strings.HasPrefix(l, "[FIRING CRITICAL] erp01: pgvigil host disk free under 10 % = /: 4.0 % free") {
		t.Errorf("line %q", l)
	}
}

// ---- webhook ------------------------------------------------------------------------------------------------------

func webhookFor(t *testing.T, url, format string) sender {
	t.Helper()
	t.Setenv("PGV_TEST_URL", url)
	s, err := (&Webhook{URL: "env:PGV_TEST_URL", Format: format}).build()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestWebhookFormats(t *testing.T) {
	var mu sync.Mutex
	var got []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var v map[string]any
		b, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(b, &v); err != nil || r.Header.Get("Content-Type") != "application/json" {
			http.Error(w, "bad", 400)
			return
		}
		mu.Lock()
		got = append(got, v)
		mu.Unlock()
	}))
	defer srv.Close()
	for _, f := range []string{"json", "slack", "teams"} {
		if err := webhookFor(t, srv.URL+"/hook/token", f).send(context.Background(), msg(crit)); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
	}
	if len(got) != 3 {
		t.Fatalf("posts %d", len(got))
	}
	if a, ok := got[0]["alerts"].([]any); !ok || len(a) != 1 || got[0]["source"] != "pgvigil" {
		t.Errorf("json body %v", got[0])
	}
	if !strings.Contains(got[1]["text"].(string), "[FIRING CRITICAL] erp01") {
		t.Errorf("slack body %v", got[1])
	}
	if got[2]["type"] != "message" || len(got[2]["attachments"].([]any)) != 1 {
		t.Errorf("teams body %v", got[2])
	}
}

func TestWebhookRedirectRefused(t *testing.T) {
	var elsewhere bool
	other := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { elsewhere = true }))
	defer other.Close()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/stolen", http.StatusTemporaryRedirect)
	}))
	defer srv.Close()
	err := webhookFor(t, srv.URL+"/hook/secret-token", "json").send(context.Background(), msg(crit))
	var re *refusedError
	if !errors.As(err, &re) {
		t.Fatalf("a redirect: %v, want refused", err)
	}
	if elsewhere {
		t.Error("the redirect was followed")
	}
	if strings.Contains(err.Error(), "secret-token") {
		t.Errorf("the error shows the URL's token: %v", err)
	}
}

func TestWebhookErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "no", http.StatusServiceUnavailable) }))
	err := webhookFor(t, srv.URL+"/hook/secret-token", "json").send(context.Background(), msg(crit))
	if err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("503: %v", err)
	}
	srv.Close() // now nothing listens there
	err = webhookFor(t, srv.URL+"/hook/secret-token", "json").send(context.Background(), msg(crit))
	if err == nil || strings.Contains(err.Error(), "secret-token") {
		t.Errorf("unreachable: %v (an error, without the token)", err)
	}
}

func TestWebhookTLS(t *testing.T) {
	var hits int
	srv := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hits++ }))
	defer srv.Close()
	// without the CA the certificate is unknown: refused by crypto/tls
	if err := webhookFor(t, srv.URL+"/h", "json").send(context.Background(), msg(crit)); err == nil {
		t.Error("an unknown certificate was accepted")
	}
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw}), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGV_TEST_URL", srv.URL+"/h")
	s, err := (&Webhook{URL: "env:PGV_TEST_URL", CAFile: ca}).build()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.send(context.Background(), msg(crit)); err != nil {
		t.Errorf("with ca_file: %v", err)
	}
	if hits != 1 {
		t.Errorf("hits %d", hits)
	}
}

// ---- smtp ---------------------------------------------------------------------------------------------------------

// sink is a loopback SMTP server that records each message's DATA.
type sink struct {
	ln       net.Listener
	starttls bool
	mu       sync.Mutex
	msgs     []string
	rcpts    []string
}

func newSink(t *testing.T, starttls bool) *sink {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &sink{ln: ln, starttls: starttls}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.serve(c)
		}
	}()
	t.Cleanup(func() { _ = ln.Close() })
	return s
}

func (s *sink) serve(c net.Conn) {
	defer func() { _ = c.Close() }()
	r := bufio.NewReader(c)
	say := func(l string) { _, _ = io.WriteString(c, l+"\r\n") }
	say("220 sink")
	for {
		l, err := r.ReadString('\n')
		if err != nil {
			return
		}
		cmd := strings.ToUpper(strings.TrimSpace(l))
		switch {
		case strings.HasPrefix(cmd, "EHLO"):
			if s.starttls {
				say("250-sink")
				say("250 STARTTLS")
			} else {
				say("250 sink")
			}
		case strings.HasPrefix(cmd, "MAIL"):
			say("250 ok")
		case strings.HasPrefix(cmd, "RCPT"):
			s.mu.Lock()
			s.rcpts = append(s.rcpts, strings.TrimSpace(l))
			s.mu.Unlock()
			say("250 ok")
		case cmd == "DATA":
			say("354 go")
			var b strings.Builder
			for {
				dl, err := r.ReadString('\n')
				if err != nil {
					return
				}
				if dl == ".\r\n" {
					break
				}
				b.WriteString(dl)
			}
			s.mu.Lock()
			s.msgs = append(s.msgs, b.String())
			s.mu.Unlock()
			say("250 queued")
		case cmd == "QUIT":
			say("221 bye")
			return
		default:
			say("502 no")
		}
	}
}

func smtpFor(t *testing.T, addr string, mode string) sender {
	t.Helper()
	host, port, _ := net.SplitHostPort(addr)
	p := 0
	for _, ch := range port {
		p = p*10 + int(ch-'0')
	}
	s, err := (&SMTP{Host: host, Port: p, TLS: mode, From: "pgvigil@example.org", To: []string{"dba@example.org", "Ops <ops@example.org>"}}).build()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSMTPPlainLoopback(t *testing.T) {
	sk := newSink(t, false)
	s := smtpFor(t, sk.ln.Addr().String(), "none")
	if err := s.send(context.Background(), msg(crit, Alert{Event: "resolved", Instance: "hr01", Severity: "warning", Source: "s", Setting: "x"})); err != nil {
		t.Fatal(err)
	}
	if len(sk.msgs) != 1 || len(sk.rcpts) != 2 {
		t.Fatalf("messages %d, recipients %d", len(sk.msgs), len(sk.rcpts))
	}
	m := sk.msgs[0]
	for _, want := range []string{"Subject: pgvigil: 1 new, 1 resolved (1 critical)", "[FIRING CRITICAL] erp01", "[RESOLVED] hr01", "X-Pgvigil-Channel: t"} {
		if !strings.Contains(m, want) {
			t.Errorf("message lacks %q:\n%s", want, m)
		}
	}
}

func TestSMTPStartTLSRequired(t *testing.T) {
	sk := newSink(t, false) // offers no STARTTLS
	err := smtpFor(t, sk.ln.Addr().String(), "starttls").send(context.Background(), msg(crit))
	var re *refusedError
	if !errors.As(err, &re) {
		t.Fatalf("a relay without STARTTLS: %v, want refused", err)
	}
	if len(sk.msgs) != 0 {
		t.Error("sent in plain text")
	}
}

func TestSMTPUnreachable(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	_ = ln.Close()
	if err := smtpFor(t, addr, "none").send(context.Background(), msg(crit)); err == nil {
		t.Error("nothing listens: no error")
	}
}

func TestLineCap(t *testing.T) {
	a := crit
	a.Detail = strings.Repeat("é", 2000) // two bytes a rune: the cut must not split one
	l := a.Line()
	if len(l) > maxLine || !strings.HasSuffix(l, " ...") || !utf8.ValidString(l) {
		t.Errorf("line of %d bytes, valid %v", len(l), utf8.ValidString(l))
	}
	if crit.Line() != crit.line() {
		t.Error("a short line was cut")
	}
	// a full message stays well under a webhook's payload limit
	var m []Alert
	for range maxPerMessage {
		m = append(m, a)
	}
	b, _ := (&webhookSender{format: "teams"}).payload(msg(m...))
	if len(b) > 24<<10 {
		t.Errorf("a full teams message is %d bytes", len(b))
	}
}

func TestDotSafe(t *testing.T) {
	if s := dotSafe("a\r\n.\r\nb\nc\rd"); strings.ContainsAny(s, "\r\n") {
		t.Errorf("%q", s)
	}
}

// ---- file drop ----------------------------------------------------------------------------------------------------

func TestFileDrop(t *testing.T) {
	dir := t.TempDir()
	s, err := (&FileDrop{Dir: dir}).build()
	if err != nil {
		t.Fatal(err)
	}
	if !s.perAlert() || s.destination() != "file:"+dir {
		t.Errorf("perAlert %v destination %q", s.perAlert(), s.destination())
	}
	if err := s.send(context.Background(), msg(crit)); err != nil {
		t.Fatal(err)
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 || !strings.HasPrefix(ents[0].Name(), "20261110T090000.000Z-firing-t-0123456789ab") {
		t.Fatalf("files %v", ents)
	}
	b, _ := os.ReadFile(filepath.Join(dir, ents[0].Name()))
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil || v["severity"] != "critical" || v["channel"] != "t" || v["source"] != "pgvigil" {
		t.Errorf("file %s: %v", b, err)
	}
	if fi, _ := ents[0].Info(); fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %v", fi.Mode().Perm())
	}
	gone, _ := (&FileDrop{Dir: filepath.Join(dir, "missing")}).build()
	if err := gone.send(context.Background(), msg(crit)); err == nil {
		t.Error("a missing directory: no error")
	}
}
