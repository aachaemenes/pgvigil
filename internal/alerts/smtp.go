package alerts

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"os"
	"strconv"
	"strings"
	"time"
)

// SMTP is a channel's smtp: block. TLS is Go's crypto/tls (the FIPS-capable build's): starttls (the default) refuses
// a server that does not offer STARTTLS; implicit opens TLS first (port 465); none is plain SMTP and is accepted only
// to a loopback relay (a local MTA that forwards). The login is optional; its password comes through env: or file:.
type SMTP struct {
	Host     string   `yaml:"host"`
	Port     int      `yaml:"port"`
	TLS      string   `yaml:"tls"`
	CAFile   string   `yaml:"ca_file"` // a PEM bundle of the CA that signed the relay's certificate (an internal CA)
	Username string   `yaml:"username"`
	Password string   `yaml:"password"`
	From     string   `yaml:"from"`
	To       []string `yaml:"to"`
}

type smtpSender struct {
	host, addr string
	mode       string
	tlsCfg     *tls.Config
	user, pass string
	from       string
	to         []string
}

func (s *SMTP) build() (sender, error) {
	host := strings.TrimSpace(s.Host)
	if host == "" {
		return nil, errors.New("smtp.host is required")
	}
	mode := s.TLS
	if mode == "" {
		mode = "starttls"
	}
	port := s.Port
	if port == 0 {
		port = 587
		if mode == "implicit" {
			port = 465
		}
	}
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("smtp.port %d is out of range", port)
	}
	switch mode {
	case "starttls", "implicit":
	case "none":
		if !loopback(host) {
			return nil, fmt.Errorf("smtp.tls none is accepted only to a loopback relay (got host %q)", host)
		}
	default:
		return nil, fmt.Errorf("smtp.tls must be starttls, implicit or none (got %q)", mode)
	}
	from, err := mail.ParseAddress(s.From)
	if err != nil {
		return nil, fmt.Errorf("smtp.from: %w", err)
	}
	if len(s.To) == 0 {
		return nil, errors.New("smtp.to needs at least one address")
	}
	var to []string
	for _, a := range s.To {
		p, err := mail.ParseAddress(a)
		if err != nil {
			return nil, fmt.Errorf("smtp.to %q: %w", a, err)
		}
		to = append(to, p.Address)
	}
	out := &smtpSender{host: host, addr: net.JoinHostPort(host, strconv.Itoa(port)), mode: mode, from: from.Address, to: to}
	out.tlsCfg = &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
	if s.CAFile != "" {
		pem, err := os.ReadFile(s.CAFile)
		if err != nil {
			return nil, fmt.Errorf("smtp.ca_file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("smtp.ca_file %s holds no PEM certificate", s.CAFile)
		}
		out.tlsCfg.RootCAs = pool
	}
	if s.Username != "" || s.Password != "" {
		if mode == "none" {
			return nil, errors.New("smtp: a login is never sent over plain SMTP (tls none)")
		}
		out.user = s.Username
		if strings.HasPrefix(s.Username, "env:") || strings.HasPrefix(s.Username, "file:") {
			if out.user, err = secret("smtp.username", s.Username); err != nil {
				return nil, err
			}
		}
		if out.pass, err = secret("smtp.password", s.Password); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func (s *smtpSender) destination() string {
	return "smtp://" + s.addr + " to " + strings.Join(s.to, ", ")
}

func (s *smtpSender) perAlert() bool { return false }

func (s *smtpSender) send(ctx context.Context, m Message) error {
	d := net.Dialer{Timeout: 15 * time.Second}
	var conn net.Conn
	var err error
	if s.mode == "implicit" {
		td := tls.Dialer{NetDialer: &d, Config: s.tlsCfg}
		conn, err = td.DialContext(ctx, "tcp", s.addr)
	} else {
		conn, err = d.DialContext(ctx, "tcp", s.addr)
	}
	if err != nil {
		return err
	}
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	c, err := smtp.NewClient(conn, s.host)
	if err != nil {
		_ = conn.Close()
		return err
	}
	defer func() { _ = c.Close() }()
	if err := c.Hello("pgvigil"); err != nil {
		return err
	}
	if s.mode == "starttls" {
		if ok, _ := c.Extension("STARTTLS"); !ok {
			return refused("smtp %s does not offer STARTTLS: refused (tls: starttls never falls back to plain)", s.addr)
		}
		if err := c.StartTLS(s.tlsCfg); err != nil {
			return err
		}
	}
	if s.user != "" {
		if ok, _ := c.Extension("AUTH"); !ok {
			return fmt.Errorf("smtp %s offers no AUTH for the configured login", s.addr)
		}
		if err := c.Auth(smtp.PlainAuth("", s.user, s.pass, s.host)); err != nil {
			return err
		}
	}
	if err := c.Mail(s.from); err != nil {
		return err
	}
	for _, r := range s.to {
		if err := c.Rcpt(r); err != nil {
			return err
		}
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(s.body(m)); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}

func (s *smtpSender) body(m Message) []byte {
	var b bytes.Buffer
	hdr := func(k, v string) { b.WriteString(k + ": " + v + "\r\n") }
	hdr("From", s.from)
	hdr("To", strings.Join(s.to, ", "))
	hdr("Subject", mime.QEncoding.Encode("utf-8", m.Summary()))
	hdr("Date", m.SentAt.Format(time.RFC1123Z))
	hdr("MIME-Version", "1.0")
	hdr("Content-Type", "text/plain; charset=utf-8")
	hdr("Content-Transfer-Encoding", "8bit")
	hdr("X-Pgvigil-Channel", m.Channel)
	b.WriteString("\r\n")
	b.WriteString(m.Summary() + "\r\n\r\n")
	for _, a := range m.Alerts {
		b.WriteString(dotSafe(a.Line()) + "\r\n")
	}
	b.WriteString("\r\nSent by pgvigil's alert channel " + m.Channel + " at " + m.SentAt.Format(time.RFC3339) + ".\r\n")
	return b.Bytes()
}

// dotSafe keeps a line from breaking the message: no bare CR or LF inside it (the DATA writer dot-stuffs).
func dotSafe(s string) string {
	return strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ").Replace(s)
}
