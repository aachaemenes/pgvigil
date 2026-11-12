package reportmail

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"mime/quotedprintable"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"
)

// Mail is one report mail as the sender builds it.
type Mail struct {
	From     string
	To       []string
	Subject  string
	HTML     string // the page's grids (the UI built it); a whole document
	Text     string // the plain alternative
	XLSX     []byte // the page's workbook, nil = none
	XLSXName string
	At       time.Time
	ID       int64 // the send's id (report_mail_sends.send_id): the Message-ID and X-Pgvigil-Report carry it
}

// Build is the message: multipart/mixed of a multipart/alternative (the plain text, the HTML) and the workbook,
// CRLF lines, every part base64 or quoted-printable so no line passes 76 characters. The headers are the caller's
// fields, checked: one line each, the addresses parsed.
func Build(m Mail) ([]byte, error) {
	from, err := mail.ParseAddress(m.From)
	if err != nil {
		return nil, fmt.Errorf("from %q: %w", m.From, err)
	}
	to, err := Recipients(m.To)
	if err != nil {
		return nil, err
	}
	subj := strings.TrimSpace(m.Subject)
	if subj == "" || utf8.RuneCountInString(subj) > 200 || strings.ContainsAny(subj, "\r\n") {
		return nil, errors.New("a subject of 1 to 200 characters on one line is required")
	}
	if err := CheckBody(m.HTML); err != nil {
		return nil, err
	}
	if m.XLSX != nil {
		if err := CheckWorkbook(m.XLSX); err != nil {
			return nil, err
		}
	}
	at := m.At
	if at.IsZero() {
		at = time.Now()
	}
	mixed, alt := boundary(), boundary()
	domain := from.Address[strings.LastIndexByte(from.Address, '@')+1:]
	var b bytes.Buffer
	hdr := func(k, v string) { b.WriteString(k + ": " + v + "\r\n") }
	hdr("From", from.String())
	// one address a line (RFC 5322 folding): fifty addresses never make a header line past 998 octets
	hdr("To", strings.Join(to, ",\r\n "))
	// an encoded subject is a run of encoded words of at most 75 characters each: one a line
	hdr("Subject", strings.ReplaceAll(mime.QEncoding.Encode("utf-8", subj), " =?", "\r\n =?"))
	hdr("Date", at.Format(time.RFC1123Z))
	hdr("Message-ID", fmt.Sprintf("<pgvigil-report-%d-%d@%s>", m.ID, at.Unix(), domain))
	hdr("MIME-Version", "1.0")
	hdr("X-Pgvigil-Report", fmt.Sprint(m.ID))
	hdr("Auto-Submitted", "auto-generated")
	if m.XLSX != nil {
		hdr("Content-Type", `multipart/mixed; boundary="`+mixed+`"`)
		b.WriteString("\r\n--" + mixed + "\r\n")
	}
	b.WriteString(`Content-Type: multipart/alternative; boundary="` + alt + `"` + "\r\n\r\n")
	b.WriteString("--" + alt + "\r\n")
	b.WriteString("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n")
	qp := quotedprintable.NewWriter(&b)
	text := m.Text
	if strings.TrimSpace(text) == "" {
		text = subj + "\n\nThis report is in the HTML part of this mail."
		if m.XLSX != nil {
			text += " The workbook is attached."
		}
	}
	if _, err := qp.Write([]byte(strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\n", "\r\n"))); err != nil {
		return nil, err
	}
	if err := qp.Close(); err != nil {
		return nil, err
	}
	b.WriteString("\r\n--" + alt + "\r\n")
	b.WriteString("Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n")
	wrap64(&b, []byte(m.HTML))
	b.WriteString("--" + alt + "--\r\n")
	if m.XLSX != nil {
		name := attachName(m.XLSXName)
		b.WriteString("\r\n--" + mixed + "\r\n")
		b.WriteString(`Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet; name="` + name + `"` + "\r\n")
		b.WriteString(`Content-Disposition: attachment; filename="` + name + `"` + "\r\n")
		b.WriteString("Content-Transfer-Encoding: base64\r\n\r\n")
		wrap64(&b, m.XLSX)
		b.WriteString("--" + mixed + "--\r\n")
	}
	return b.Bytes(), nil
}

// attachName keeps a file name to the characters every client shows: the UI's export names are of them already
func attachName(n string) string {
	var s strings.Builder
	for _, r := range n {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
			s.WriteRune(r)
		default:
			s.WriteByte('-')
		}
	}
	out := strings.Trim(s.String(), "-.")
	if out == "" {
		out = "report"
	}
	if len(out) > 120 {
		out = out[:120]
	}
	if !strings.HasSuffix(strings.ToLower(out), ".xlsx") {
		out += ".xlsx"
	}
	return out
}

func boundary() string {
	var r [12]byte
	_, _ = rand.Read(r[:])
	return "pgvigil-" + hex.EncodeToString(r[:])
}

// wrap64 writes b as base64 in lines of 76 characters, each ended with CRLF
func wrap64(w *bytes.Buffer, b []byte) {
	enc := base64.StdEncoding.EncodeToString(b)
	for len(enc) > 76 {
		w.WriteString(enc[:76] + "\r\n")
		enc = enc[76:]
	}
	if enc != "" {
		w.WriteString(enc + "\r\n")
	}
}
