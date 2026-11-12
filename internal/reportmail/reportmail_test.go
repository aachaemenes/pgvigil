package reportmail

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/mail"
	"strings"
	"testing"
	"time"
)

func TestCronFor(t *testing.T) {
	for _, c := range []struct {
		cadence, at string
		days        []int
		line, want  string
		bad         bool
	}{
		{"daily", "07:00", nil, "", "0 7 * * *", false},
		{"daily", "7:05", nil, "", "5 7 * * *", false},
		{"daily", "00:00", nil, "", "0 0 * * *", false},
		{"weekly", "18:30", []int{5, 1, 1}, "", "30 18 * * 1,5", false},
		{"weekly", "18:30", nil, "", "", true},
		{"weekly", "18:30", []int{7}, "", "", true},
		{"daily", "24:00", nil, "", "", true},
		{"cron", "", nil, "  0  6 * *   1-5 ", "0 6 * * 1-5", false},
		{"cron", "", nil, "@DAILY", "0 0 * * *", false},
		{"hourly", "", nil, "", "", true},
	} {
		got, err := CronFor(c.cadence, c.at, c.days, c.line)
		if (err != nil) != c.bad || got != c.want {
			t.Errorf("CronFor(%q, %q, %v, %q) = %q, %v; want %q, bad %v", c.cadence, c.at, c.days, c.line, got, err, c.want, c.bad)
		}
	}
}

func TestCheckCronAndNext(t *testing.T) {
	from := time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		line, tz string
		bad      bool
	}{
		{"0 7 * * *", "America/Los_Angeles", false},
		{"*/15 * * * *", "UTC", false},
		{"*/5 * * * *", "UTC", true}, // under MinGap
		{"0,5 9 * * *", "UTC", true}, // two sends five minutes apart
		{"0 7 * * *", "Mars/Olympus", true},
		{"0 7 * * *", "", true},
		{"30 seconds", "UTC", true},
		{"@reboot", "UTC", true},
		{"0 7 31 2 *", "UTC", true}, // never
		{"0 7 * *", "UTC", true},
	} {
		err := CheckCron(c.line, c.tz, from)
		if (err != nil) != c.bad {
			t.Errorf("CheckCron(%q, %q) = %v; want bad %v", c.line, c.tz, err, c.bad)
		}
	}
	// 07:00 in Los Angeles on 2026-11-11 (PST, UTC-8) is 15:00 UTC; after it, the next day's
	n, err := NextSend("0 7 * * *", "America/Los_Angeles", from)
	if err != nil || !n.Equal(time.Date(2026, 11, 11, 15, 0, 0, 0, time.UTC)) {
		t.Fatalf("NextSend = %s, %v", n, err)
	}
	n2, _ := NextSend("0 7 * * *", "America/Los_Angeles", n)
	if !n2.Equal(time.Date(2026, 11, 12, 15, 0, 0, 0, time.UTC)) {
		t.Fatalf("NextSend after the first = %s", n2)
	}
	// across the spring change (2027-03-14 in the US): 07:00 PDT is 14:00 UTC
	n3, _ := NextSend("0 7 * * *", "America/Los_Angeles", time.Date(2027, 3, 14, 0, 0, 0, 0, time.UTC))
	if !n3.Equal(time.Date(2027, 3, 14, 14, 0, 0, 0, time.UTC)) {
		t.Fatalf("NextSend across DST = %s", n3)
	}
}

func TestRecipientsAndRoute(t *testing.T) {
	got, err := Recipients([]string{" DBA@Example.org ", "", "oncall@example.org", "dba@example.org"})
	if err != nil || strings.Join(got, ",") != "dba@example.org,oncall@example.org" {
		t.Fatalf("Recipients = %v, %v", got, err)
	}
	for _, bad := range [][]string{nil, {""}, {"not an address"}, {"a@b"}, {"a@b.org, c@d.org"}, {"x@y.org\r\nBcc: z@w.org"}} {
		if _, err := Recipients(bad); err == nil {
			t.Errorf("Recipients(%q) took it", bad)
		}
	}
	many := make([]string, MaxRecipients+1)
	for i := range many {
		many[i] = "u" + strings.Repeat("x", i) + "@example.org"
	}
	if _, err := Recipients(many); err == nil {
		t.Error("Recipients took more than the cap")
	}
	for _, ok := range []string{"#/summary", "#/backups?w=24h", "#/jobs?i=3&w=7d", "#/summary?tag=env:prod", "#/storage?from=2026-11-10T07:00:00.000Z&to=2026-11-11T07:00:00.000Z"} {
		if err := CheckRoute(ok); err != nil {
			t.Errorf("CheckRoute(%q) = %v", ok, err)
		}
	}
	for _, bad := range []string{"", "/summary", "#/", "#/x y", "#/a?b=<script>", "https://evil.example/#/summary", "#/summary?mailrender=00", "#/a?x=\"y\""} {
		if err := CheckRoute(bad); err == nil {
			t.Errorf("CheckRoute(%q) took it", bad)
		}
	}
}

const page = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>t</title></head><body><table style="border-collapse:collapse"><tr><td style="background:#006638;color:#ffffff" data-status="ok">x one=1 onboarding</td></tr></table></body></html>`

func TestCheckBody(t *testing.T) {
	if err := CheckBody(page); err != nil {
		t.Fatalf("a grid's body refused: %v", err)
	}
	for _, bad := range []string{"", page + "<script>alert(1)</script>", strings.Replace(page, "<td ", `<td onclick="x()" `, 1),
		strings.Replace(page, "<title>", "<style>td{}</style><title>", 1), strings.Replace(page, "<td ", `<td><a href="javascript:x()">`, 1),
		strings.Replace(page, "<title>", `<meta http-equiv="refresh" content="0"><title>`, 1), "<p>" + strings.Repeat("x", MaxHTML) + "</p>",
		strings.Replace(page, "<table ", "<svg/onload=alert(1)><table ", 1), strings.Replace(page, "#006638", "#006638;background:url(http://x.example/p.gif)", 1),
		strings.Replace(page, "#006638", "&#106;avascript", 1), strings.Replace(page, "<td ", `<td title="x" `, 1), strings.Replace(page, "<td ", `<img src="http://x.example/p.gif"><td `, 1),
		strings.Replace(page, "</td>", "<", 1), strings.Replace(page, `style="border-collapse:collapse"`, `style='x'`, 1)} {
		if err := CheckBody(bad); err == nil {
			t.Errorf("CheckBody took %.60q", bad)
		}
	}
	if err := CheckWorkbook([]byte("PK\x03\x04rest")); err != nil {
		t.Errorf("a zip refused: %v", err)
	}
	if err := CheckWorkbook([]byte("%PDF")); err == nil {
		t.Error("a non-zip workbook taken")
	}
}

// TestBuild: the message parses as a mail, its HTML and its workbook come back byte for byte, every line is CRLF and
// at most 76 characters in the encoded parts, the subject is encoded.
func TestBuild(t *testing.T) {
	x := append([]byte("PK\x03\x04"), bytes.Repeat([]byte{0, 1, 2, 250}, 300)...)
	html := strings.Replace(page, "</table>", strings.Repeat(`<tr><td style="border:1px solid #c8ccd4">a row</td></tr>`, 200)+"</table>", 1)
	msg, err := Build(Mail{From: "pgvigil <alerts@example.org>", To: []string{"dba@example.org", "b@example.org"}, Subject: "Backups - last 24 hours (ünïcode)",
		HTML: html, XLSX: x, XLSXName: "fleet_Backups_20261110-0700_20261111-0700.xlsx", At: time.Date(2026, 11, 11, 7, 0, 0, 0, time.UTC), ID: 42})
	if err != nil {
		t.Fatal(err)
	}
	for i, l := range strings.Split(strings.TrimSuffix(string(msg), "\r\n"), "\r\n") {
		if strings.ContainsAny(l, "\r\n") {
			t.Fatalf("line %d holds a bare CR or LF", i)
		}
		if len(l) > 998 {
			t.Fatalf("line %d is %d bytes", i, len(l))
		}
	}
	m, err := mail.ReadMessage(bytes.NewReader(msg))
	if err != nil {
		t.Fatal(err)
	}
	dec := new(mime.WordDecoder)
	if s, _ := dec.DecodeHeader(m.Header.Get("Subject")); s != "Backups - last 24 hours (ünïcode)" {
		t.Fatalf("subject %q", s)
	}
	if m.Header.Get("To") != "dba@example.org, b@example.org" || !strings.Contains(m.Header.Get("Message-ID"), "pgvigil-report-42-") {
		t.Fatalf("headers %v", m.Header)
	}
	mt, params, err := mime.ParseMediaType(m.Header.Get("Content-Type"))
	if err != nil || mt != "multipart/mixed" {
		t.Fatalf("content type %q %v", mt, err)
	}
	mr := multipart.NewReader(m.Body, params["boundary"])
	alt, err := mr.NextPart()
	if err != nil {
		t.Fatal(err)
	}
	amt, ap, _ := mime.ParseMediaType(alt.Header.Get("Content-Type"))
	if amt != "multipart/alternative" {
		t.Fatalf("first part %q", amt)
	}
	ar := multipart.NewReader(alt, ap["boundary"])
	plain, _ := ar.NextPart()
	pt, _ := io.ReadAll(plain)
	if !strings.Contains(string(pt), "Backups") {
		t.Fatalf("plain part %q", pt)
	}
	hp, _ := ar.NextPart()
	if hp.Header.Get("Content-Type") != "text/html; charset=utf-8" {
		t.Fatalf("html part %q", hp.Header.Get("Content-Type"))
	}
	raw, _ := io.ReadAll(hp)
	got, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(string(raw), "\r\n", ""))
	if err != nil || string(got) != html {
		t.Fatalf("the html did not come back: %v", err)
	}
	for _, l := range strings.Split(strings.TrimSpace(string(raw)), "\r\n") {
		if len(l) > 76 {
			t.Fatalf("a base64 line of %d characters", len(l))
		}
	}
	att, err := mr.NextPart()
	if err != nil {
		t.Fatal(err)
	}
	if att.FileName() != "fleet_Backups_20261110-0700_20261111-0700.xlsx" {
		t.Fatalf("attachment %q", att.FileName())
	}
	raw, _ = io.ReadAll(att)
	got, _ = base64.StdEncoding.DecodeString(strings.ReplaceAll(string(raw), "\r\n", ""))
	if !bytes.Equal(got, x) {
		t.Fatal("the workbook did not come back")
	}
	// fifty long addresses and a long subject in another script: every header line folded under 998 octets (the
	// encoded words at most 76)
	var many []string
	for i := range MaxRecipients {
		many = append(many, fmt.Sprintf("%s%02d@example.org", strings.Repeat("r", 200), i))
	}
	long, err := Build(Mail{From: "a@example.org", To: many, Subject: strings.Repeat("Резервные копии ", 12), HTML: page})
	if err != nil {
		t.Fatal(err)
	}
	end := bytes.Index(long, []byte("\r\n\r\n"))
	if end < 0 {
		t.Fatal("the message has no end of its header")
	}
	head := string(long[:end])
	for _, l := range strings.Split(head, "\r\n") {
		if len(l) > 998 || (strings.Contains(l, "=?utf-8?") && len(l) > 90) {
			t.Fatalf("a header line of %d octets: %.80q", len(l), l)
		}
	}
	lm, _ := mail.ReadMessage(bytes.NewReader(long))
	if got, _ := lm.Header.AddressList("To"); len(got) != MaxRecipients {
		t.Fatalf("the folded To reads back as %d addresses", len(got))
	}
	if s, _ := dec.DecodeHeader(lm.Header.Get("Subject")); s != strings.TrimSpace(strings.Repeat("Резервные копии ", 12)) {
		t.Fatalf("the folded subject reads back as %q", s)
	}
	// refusals: a header injection, no subject, an active body
	for _, bad := range []Mail{
		{From: "a@example.org", To: []string{"b@example.org"}, Subject: "x\r\nBcc: c@example.org", HTML: page},
		{From: "a@example.org", To: []string{"b@example.org"}, Subject: " ", HTML: page},
		{From: "a@example.org", To: []string{"b@example.org"}, Subject: "x", HTML: page + "<script></script>"},
		{From: "not an address", To: []string{"b@example.org"}, Subject: "x", HTML: page},
	} {
		if _, err := Build(bad); err == nil {
			t.Errorf("Build took %+v", bad.Subject)
		}
	}
	// no workbook: the message is the alternative itself
	msg, err = Build(Mail{From: "a@example.org", To: []string{"b@example.org"}, Subject: "x", HTML: page})
	if err != nil {
		t.Fatal(err)
	}
	m, _ = mail.ReadMessage(bytes.NewReader(msg))
	if mt, _, _ := mime.ParseMediaType(m.Header.Get("Content-Type")); mt != "multipart/alternative" {
		t.Fatalf("without a workbook: %q", mt)
	}
}

func TestAttachName(t *testing.T) {
	for in, want := range map[string]string{"": "report.xlsx", "a b/c.xlsx": "a-b-c.xlsx", "db01_Jobs": "db01_Jobs.xlsx", "..x..": "x.xlsx"} {
		if got := attachName(in); got != want {
			t.Errorf("attachName(%q) = %q, want %q", in, got, want)
		}
	}
}
