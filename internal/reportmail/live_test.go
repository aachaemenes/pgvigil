package reportmail

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/mail"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

// TestLiveSMTP mails one report through a real relay: skipped unless
//
//	PGVIGIL_LIVE_SMTP  a file holding an alerts: list of one smtp channel (its login through env: or file:)
//	PGVIGIL_LIVE_EML   a report mail the proof's sink saved (its HTML and workbook are mailed again)
//	PGVIGIL_LIVE_TO    the one address to mail
//
// The subject says it is a test. The message is built by Build and mailed by the channel's own relay code
// (alerts.Channel.Mail: STARTTLS, the login), as the sender mails a queued report.
func TestLiveSMTP(t *testing.T) {
	cfg, eml, to := os.Getenv("PGVIGIL_LIVE_SMTP"), os.Getenv("PGVIGIL_LIVE_EML"), os.Getenv("PGVIGIL_LIVE_TO")
	if cfg == "" || eml == "" || to == "" {
		t.Skip("PGVIGIL_LIVE_SMTP, PGVIGIL_LIVE_EML and PGVIGIL_LIVE_TO are not all set: no live send")
	}
	st, err := alerts.LoadFile(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Channels) != 1 || st.Channels[0].Kind != "smtp" {
		t.Fatal("PGVIGIL_LIVE_SMTP holds one smtp channel")
	}
	ch := &st.Channels[0]
	raw, err := os.ReadFile(eml)
	if err != nil {
		t.Fatal(err)
	}
	html, xlsx, name, err := partsOf(raw)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	msg, err := Build(Mail{From: ch.MailFrom(), To: []string{to}, Subject: "[test] pgvigil report mail: a live test through the lab relay (demo data, no client data)",
		HTML: html, XLSX: xlsx, XLSXName: name, At: now, ID: now.Unix()})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if err := ch.Mail(ctx, []string{to}, msg); err != nil {
		t.Fatalf("the relay refused: %v", err)
	}
	t.Logf("mailed %d bytes (HTML %d, workbook %d) to %s through %s", len(msg), len(html), len(xlsx), to, ch.Destination())
}

// partsOf reads a report mail back: its HTML part, its workbook and the workbook's name
func partsOf(raw []byte) (html string, xlsx []byte, name string, err error) {
	m, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return "", nil, "", err
	}
	var walk func(ct string, body io.Reader) error
	walk = func(ct string, body io.Reader) error {
		mt, params, err := mime.ParseMediaType(ct)
		if err != nil {
			return err
		}
		if !strings.HasPrefix(mt, "multipart/") {
			return nil
		}
		mr := multipart.NewReader(body, params["boundary"])
		for {
			p, err := mr.NextPart()
			if errors.Is(err, io.EOF) {
				return nil
			}
			if err != nil {
				return err
			}
			pct := p.Header.Get("Content-Type")
			if strings.HasPrefix(pct, "multipart/") {
				if err := walk(pct, p); err != nil {
					return err
				}
				continue
			}
			b, err := io.ReadAll(p)
			if err != nil {
				return err
			}
			if strings.EqualFold(p.Header.Get("Content-Transfer-Encoding"), "base64") {
				if b, err = decode64(b); err != nil {
					return err
				}
			}
			switch {
			case strings.HasPrefix(pct, "text/html"):
				html = string(b)
			case strings.HasPrefix(pct, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"):
				xlsx, name = b, p.FileName()
			}
		}
	}
	if err := walk(m.Header.Get("Content-Type"), m.Body); err != nil {
		return "", nil, "", err
	}
	if html == "" {
		return "", nil, "", errors.New("no HTML part in the mail")
	}
	return html, xlsx, name, nil
}

// decode64 reads a base64 part back (its CRLF line breaks dropped)
func decode64(b []byte) ([]byte, error) {
	return base64.StdEncoding.DecodeString(strings.NewReplacer("\r", "", "\n", "").Replace(string(b)))
}
