package alerts

// Zabbix (task B24k, SQLWATCH's action 'Send Alert to ZABBIX'): a channel's zabbix: block sends each message's alerts
// as values of one item of one Zabbix host, a trapper item (or an HTTP agent item with trapping on), in one of two modes:
//
//   - sender (the default): Zabbix's sender protocol to the server or a proxy (port 10051): the header 'ZBXD', the
//     flags byte 0x01 and the data length (little-endian, 4 bytes, then 4 reserved), then
//     {"request":"sender data","data":[{"host","key","value","clock","ns"}, ...]}; the server answers
//     {"response":"success","info":"processed: N; failed: M; total: T; seconds spent: S"}. The send succeeded only when
//     every value was processed. A failed value comes back as a count only: the reason (the item missing, not a
//     trapper item, the host not monitored, this machine not in the item's Allowed hosts) is in the Zabbix server's log.
//     To any server off loopback the connection is TLS with certificates (tls_ca, tls_cert, tls_key: the files of the
//     host's certificate, as zabbix_sender's --tls-connect cert). With tls_server_issuer or tls_server_subject set, the
//     server's certificate is checked as Zabbix checks one: its chain to tls_ca and those strings, no host name (Zabbix
//     reads no Subject Alternative Name); with neither, its chain and the server's name. The strings are written as
//     Zabbix's 'Using certificates' page writes them (RFC 4514, the lowest level first: 'CN=Zabbix server,OU=
//     Development group,O=Zabbix SIA,DC=zabbix,DC=com') and compared exactly [the page read as a reader's summary,
//     2026-11-15]. Go's crypto/tls has no PSK: a site on PSK uses mode api. Plain text goes to a loopback
//     server only, or under allow_plain: true (an admin's opt-in, named on the channel, logged at start and shown in the
//     destination). [unverified: the TLS handshake opens the connection, before the header: the container proof reads it]
//   - api: the HTTP API's history.push (POST <url>/api_jsonrpc.php, an API token in 'Authorization: Bearer'), https
//     (plain only to loopback or under allow_plain), into the same item. Zabbix's own words for a failed value come back
//     in the result's per-value error (a value's entry with an "error"). [assumed from the API reference: Zabbix 7.0+]
//
// The value is the alert as a JSON object (event, severity, instance, source, setting, value, detail, the alert's page,
// the finding key, the time), for an item of type text.
//
//	zabbix: {server: zabbix.example.org, host: pgvigil, key: pgvigil.alert, tls_ca: /etc/pgvigil/zbx-ca.pem,
//	         tls_cert: /etc/pgvigil/zbx-pgvigil.crt, tls_key: /etc/pgvigil/zbx-pgvigil.key}
//	zabbix: {mode: api, url: https://zabbix.example.org/zabbix, token: env:PGVIGIL_ZBX_TOKEN, host: pgvigil}

import (
	"bytes"
	"compress/zlib"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/asn1"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

// Zabbix is a channel's zabbix: block.
type Zabbix struct {
	Mode   string `yaml:"mode"`   // sender (default) | api
	Server string `yaml:"server"` // sender: the server or proxy, host[:port] (default port 10051)
	URL    string `yaml:"url"`    // api: the frontend's address (api_jsonrpc.php is added)
	Token  string `yaml:"token"`  // api: an API token, env: or file:
	Host   string `yaml:"host"`   // the Zabbix host the item belongs to (its technical name)
	Key    string `yaml:"key"`    // the item's key (default pgvigil.alert)

	TLSCA            string `yaml:"tls_ca"`             // sender: the CA file that signed the server's certificate (api: optional, an internal CA)
	TLSCert          string `yaml:"tls_cert"`           // sender: this host's certificate file
	TLSKey           string `yaml:"tls_key"`            // sender: its private key file
	TLSServerIssuer  string `yaml:"tls_server_issuer"`  // sender: the server certificate's issuer, exactly (optional)
	TLSServerSubject string `yaml:"tls_server_subject"` // sender: the server certificate's subject, exactly (optional)
	AllowPlain       bool   `yaml:"allow_plain"`        // plain text to a server off loopback: an admin's opt-in
}

const (
	zbxPort       = "10051"
	zbxDefaultKey = "pgvigil.alert"
	zbxMaxAnswer  = 1 << 20 // the largest answer read
)

var (
	zbxNameRE = regexp.MustCompile(`^[0-9A-Za-z _.\-]{1,128}$`) // a host's technical name
	zbxInfoRE = regexp.MustCompile(`processed:\s*(\d+);\s*failed:\s*(\d+);\s*total:\s*(\d+)`)
)

type zabbixSender struct {
	mode       string
	addr       string // sender: host:port
	api        *url.URL
	token      string
	host, key  string
	tlsCfg     *tls.Config // nil = plain
	issuer     string
	subject    string
	plainOptIn bool
	client     *http.Client
}

func (z *Zabbix) build() (sender, error) {
	s := &zabbixSender{mode: strings.TrimSpace(z.Mode), host: strings.TrimSpace(z.Host), key: strings.TrimSpace(z.Key),
		issuer: strings.TrimSpace(z.TLSServerIssuer), subject: strings.TrimSpace(z.TLSServerSubject)}
	if s.mode == "" {
		s.mode = "sender"
	}
	if s.key == "" {
		s.key = zbxDefaultKey
	}
	if !zbxNameRE.MatchString(s.host) {
		return nil, fmt.Errorf("zabbix.host %q is not a Zabbix host's technical name (letters, digits, space, '.', '_', '-'; 1 to 128)", s.host)
	}
	if len(s.key) > 255 || strings.ContainsAny(s.key, "\r\n\x00") {
		return nil, errors.New("zabbix.key must be one line of at most 255 characters")
	}
	switch s.mode {
	case "sender":
		if z.URL != "" || z.Token != "" {
			return nil, errors.New("zabbix: url and token belong to mode api")
		}
		hp := strings.TrimSpace(z.Server)
		if hp == "" {
			return nil, errors.New("zabbix.server is required in mode sender (host or host:port)")
		}
		host, port, err := net.SplitHostPort(hp)
		if err != nil {
			host, port = hp, zbxPort
		}
		if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 || host == "" {
			return nil, fmt.Errorf("zabbix.server %q is not host[:port]", hp)
		}
		s.addr = net.JoinHostPort(host, port)
		tlsSet := z.TLSCA != "" || z.TLSCert != "" || z.TLSKey != ""
		switch {
		case tlsSet:
			if z.TLSCA == "" || z.TLSCert == "" || z.TLSKey == "" {
				return nil, errors.New("zabbix: tls_ca, tls_cert and tls_key go together (the certificate mode of zabbix_sender)")
			}
			pool, err := caPool("zabbix.tls_ca", z.TLSCA)
			if err != nil {
				return nil, err
			}
			pair, err := tls.LoadX509KeyPair(z.TLSCert, z.TLSKey)
			if err != nil {
				return nil, fmt.Errorf("zabbix.tls_cert / tls_key: %w", err)
			}
			s.tlsCfg = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, Certificates: []tls.Certificate{pair}, ServerName: host}
		case loopback(host):
		case z.AllowPlain:
			s.plainOptIn = true
		default:
			return nil, fmt.Errorf("zabbix.server %s is off loopback: set tls_ca, tls_cert and tls_key (certificate TLS), or allow_plain: true (an admin's opt-in to plain text), or use mode api over https", host)
		}
		if s.tlsCfg == nil && (s.issuer != "" || s.subject != "") {
			return nil, errors.New("zabbix: tls_server_issuer and tls_server_subject need certificate TLS")
		}
	case "api":
		if z.Server != "" || z.TLSCert != "" || z.TLSKey != "" || s.issuer != "" || s.subject != "" {
			return nil, errors.New("zabbix: server and the client certificate belong to mode sender")
		}
		tok, err := secret("zabbix.token", z.Token)
		if err != nil {
			return nil, err
		}
		s.token = strings.TrimSpace(tok)
		if s.token == "" || strings.ContainsAny(s.token, " \r\n") {
			return nil, errors.New("zabbix.token is not an API token")
		}
		u, err := url.Parse(strings.TrimSpace(z.URL))
		if err != nil || u.Host == "" {
			return nil, errors.New("zabbix.url is not an absolute URL (the frontend's address)")
		}
		switch {
		case u.Scheme == "https":
		case u.Scheme == "http" && loopback(u.Hostname()):
		case u.Scheme == "http" && z.AllowPlain:
			s.plainOptIn = true
		default:
			return nil, fmt.Errorf("zabbix.url must be https (plain http only to loopback, or with allow_plain: true; got %s)", hostOf(u))
		}
		if u.User != nil || u.RawQuery != "" {
			return nil, errors.New("zabbix.url must not carry a user:password or a query")
		}
		u.Path = strings.TrimSuffix(strings.TrimRight(u.Path, "/"), "/api_jsonrpc.php") + "/api_jsonrpc.php"
		s.api = u
		tcfg := &tls.Config{MinVersion: tls.VersionTLS12}
		if z.TLSCA != "" {
			pool, err := caPool("zabbix.tls_ca", z.TLSCA)
			if err != nil {
				return nil, err
			}
			tcfg.RootCAs = pool
		}
		s.client = &http.Client{
			Transport: &http.Transport{
				Proxy:               nil, // the configured destination only
				DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
				TLSClientConfig:     tcfg,
				TLSHandshakeTimeout: 15 * time.Second,
				ForceAttemptHTTP2:   true,
			},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	default:
		return nil, fmt.Errorf("zabbix.mode must be sender or api (got %q)", s.mode)
	}
	return s, nil
}

// caPool reads a PEM bundle of CA certificates.
func caPool(what, path string) (*x509.CertPool, error) {
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", what, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("%s %s holds no PEM certificate", what, path)
	}
	return pool, nil
}

func (s *zabbixSender) destination() string {
	if s.mode == "api" {
		d := hostOf(s.api) + " (zabbix api)"
		if s.plainOptIn {
			d += " PLAIN by allow_plain"
		}
		return d
	}
	switch {
	case s.tlsCfg != nil:
		return "zabbix://" + s.addr + " (sender, tls)"
	case s.plainOptIn:
		return "zabbix://" + s.addr + " (sender) PLAIN by allow_plain"
	}
	return "zabbix://" + s.addr + " (sender, loopback)"
}

// PlainByOptIn says whether the channel sends plain text off loopback under allow_plain (the loop logs it at start).
func (c *Channel) PlainByOptIn() bool {
	z, ok := c.sender.(*zabbixSender)
	return ok && z.plainOptIn
}

// perAlert: a message's alerts go as the values of one request (at most maxPerMessage).
func (s *zabbixSender) perAlert() bool { return false }

// zbxValue is one alert as the item's value: a JSON object.
func zbxValue(a Alert) string {
	b, _ := json.Marshal(map[string]any{"event": a.Event, "severity": a.Severity, "instance": a.Instance,
		"source": a.Source, "setting": a.Setting, "value": a.Value, "detail": a.Detail, "url": a.URL,
		"finding_key": a.FindingKey, "line": a.Line()})
	return string(b)
}

type zbxItem struct {
	Host  string `json:"host"`
	Key   string `json:"key"`
	Value string `json:"value"`
	Clock int64  `json:"clock"`
	NS    int    `json:"ns"`
}

// zbxClock hands out the values' (clock, ns), strictly increasing across every Zabbix channel of this process: Zabbix
// keeps an item's history by (itemid, clock, ns), and every message of a pass carries the pass's time, so two
// messages (a batch past 25 alerts, a Send test and an alert, two channels into one item) would share a stamp
// [unverified: whether Zabbix drops the second value or fails the batch; part Z's two channels into one item read it].
var zbxClock struct {
	sync.Mutex
	last time.Time
}

// zbxStamp is at, or a nanosecond after the last stamp handed out when at is not later.
func zbxStamp(at time.Time) time.Time {
	zbxClock.Lock()
	defer zbxClock.Unlock()
	if !at.After(zbxClock.last) {
		at = zbxClock.last.Add(time.Nanosecond)
	}
	zbxClock.last = at
	return at
}

func (s *zabbixSender) items(m Message) []zbxItem {
	out := make([]zbxItem, 0, len(m.Alerts))
	for _, a := range m.Alerts {
		// the message's time, each value a nanosecond after the one before it (zbxStamp): Zabbix keeps them in order
		t := zbxStamp(m.SentAt)
		out = append(out, zbxItem{Host: s.host, Key: s.key, Value: zbxValue(a), Clock: t.Unix(), NS: t.Nanosecond()})
	}
	return out
}

func (s *zabbixSender) send(ctx context.Context, m Message) error {
	if len(m.Alerts) == 0 {
		return nil
	}
	if s.mode == "api" {
		return s.push(ctx, s.items(m))
	}
	return s.sendData(ctx, s.items(m))
}

// zbxFrame is the sender protocol's frame: 'ZBXD', the flags, the length and the reserved field (little-endian).
func zbxFrame(data []byte) []byte {
	var b bytes.Buffer
	b.WriteString("ZBXD")
	b.WriteByte(0x01)
	_ = binary.Write(&b, binary.LittleEndian, uint32(len(data)))
	_ = binary.Write(&b, binary.LittleEndian, uint32(0))
	b.Write(data)
	return b.Bytes()
}

// zbxRead reads one frame: plain, compressed (0x02: the reserved field holds the plain length) or large (0x04: 8-byte
// fields), at most zbxMaxAnswer bytes.
func zbxRead(r io.Reader) ([]byte, error) {
	head := make([]byte, 5)
	if _, err := io.ReadFull(r, head); err != nil {
		return nil, fmt.Errorf("no answer header: %w", err)
	}
	if string(head[:4]) != "ZBXD" || head[4]&0x01 == 0 {
		return nil, fmt.Errorf("the answer is not Zabbix's protocol (header % x)", head)
	}
	flags := head[4]
	var size, plain uint64
	if flags&0x04 != 0 {
		f := make([]byte, 16)
		if _, err := io.ReadFull(r, f); err != nil {
			return nil, err
		}
		size, plain = binary.LittleEndian.Uint64(f[:8]), binary.LittleEndian.Uint64(f[8:])
	} else {
		f := make([]byte, 8)
		if _, err := io.ReadFull(r, f); err != nil {
			return nil, err
		}
		size, plain = uint64(binary.LittleEndian.Uint32(f[:4])), uint64(binary.LittleEndian.Uint32(f[4:]))
	}
	if size > zbxMaxAnswer || plain > zbxMaxAnswer {
		return nil, fmt.Errorf("an answer of %d bytes: over the %d read", max(size, plain), zbxMaxAnswer)
	}
	data := make([]byte, size)
	if _, err := io.ReadFull(r, data); err != nil {
		return nil, fmt.Errorf("the answer cut short: %w", err)
	}
	if flags&0x02 != 0 {
		zr, err := zlib.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("the compressed answer: %w", err)
		}
		defer func() { _ = zr.Close() }()
		out, err := io.ReadAll(io.LimitReader(zr, int64(plain)+1))
		if err != nil || uint64(len(out)) != plain {
			return nil, fmt.Errorf("the compressed answer does not unpack to %d bytes", plain)
		}
		return out, nil
	}
	return data, nil
}

// zbxNameTypes are the attribute names a name is written with: OpenSSL's short names (Zabbix compares OpenSSL's
// string) for the components certificates carry; any other is its dotted OID, as RFC 4514 writes an unknown type
// [unverified: OpenSSL's names beyond CN, OU, O, DC (the page's examples); a refused pin prints the string read, so it
// can be copied from the error].
var zbxNameTypes = map[string]string{
	"2.5.4.3": "CN", "2.5.4.4": "SN", "2.5.4.5": "serialNumber", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST",
	"2.5.4.9": "street", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.12": "title", "2.5.4.17": "postalCode",
	"2.5.4.42": "GN", "2.5.4.43": "initials", "2.5.4.46": "dnQualifier",
	"0.9.2342.19200300.100.1.25": "DC", "0.9.2342.19200300.100.1.1": "UID", "1.2.840.113549.1.9.1": "emailAddress",
}

type zbxATV struct {
	Type  asn1.ObjectIdentifier
	Value asn1.RawValue
}

// zbxRDNSET is one relative name: a SET OF (encoding/asn1 reads a slice type named ...SET as a SET).
type zbxRDNSET []zbxATV

// zbxName writes a certificate's DER name as Zabbix compares it: the relative names in reverse order (the lowest level
// first), the values of a multi-valued one joined by '+', a string value escaped (zbxEscape), any other value '#' and
// its DER in hex (RFC 4514 2.4).
func zbxName(der []byte) (string, error) {
	var seq []zbxRDNSET
	rest, err := asn1.Unmarshal(der, &seq)
	if err != nil {
		return "", err
	}
	if len(rest) > 0 {
		return "", errors.New("data after the name")
	}
	var b strings.Builder
	for i := len(seq) - 1; i >= 0; i-- {
		if i != len(seq)-1 {
			b.WriteByte(',')
		}
		for j, atv := range seq[i] {
			if j > 0 {
				b.WriteByte('+')
			}
			name := zbxNameTypes[atv.Type.String()]
			if name == "" {
				name = atv.Type.String()
			}
			b.WriteString(name)
			b.WriteByte('=')
			if v, ok := zbxString(atv.Value); ok {
				b.WriteString(zbxEscape(v))
			} else {
				b.WriteString("#" + hex.EncodeToString(atv.Value.FullBytes))
			}
		}
	}
	return b.String(), nil
}

// zbxString reads a name's string value (UTF-8 as it is: Zabbix's page says UTF-8 is supported); false for a value
// that is not one of the string types.
func zbxString(v asn1.RawValue) (string, bool) {
	if v.Class != asn1.ClassUniversal {
		return "", false
	}
	switch v.Tag {
	case asn1.TagUTF8String, asn1.TagPrintableString, asn1.TagIA5String, asn1.TagNumericString, 26: // 26: VisibleString
		return string(v.Bytes), true
	case asn1.TagT61String: // read as Latin-1, as OpenSSL converts it
		r := make([]rune, len(v.Bytes))
		for i, c := range v.Bytes {
			r[i] = rune(c)
		}
		return string(r), true
	case asn1.TagBMPString:
		if len(v.Bytes)%2 != 0 {
			return "", false
		}
		u := make([]uint16, len(v.Bytes)/2)
		for i := range u {
			u[i] = uint16(v.Bytes[2*i])<<8 | uint16(v.Bytes[2*i+1])
		}
		return string(utf16.Decode(u)), true
	}
	return "", false
}

// zbxEscape escapes a value as RFC 4514 2.4 and Zabbix's page list it: the double quote, plus, comma, semicolon, the
// angle brackets and the backslash anywhere, a space or '#' first, a space last, each with a backslash before it; a
// control character as a backslash and its two hex digits.
func zbxEscape(v string) string {
	var b strings.Builder
	for i := 0; i < len(v); i++ {
		c := v[i]
		switch {
		case strings.IndexByte(`\"+,;<>`, c) >= 0, (c == ' ' || c == '#') && i == 0, c == ' ' && i == len(v)-1:
			b.WriteByte('\\')
			b.WriteByte(c)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, "\\%02X", c)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// zbxCauses is what a value Zabbix did not process may mean; the server's log has the reason.
const zbxCauses = "the item is missing, is not a trapper item (or an HTTP agent item with trapping on), or is disabled; the host is not monitored; or this machine is not in the item's Allowed hosts - the Zabbix server's log says which"

func (s *zabbixSender) sendData(ctx context.Context, items []zbxItem) error {
	body, _ := json.Marshal(map[string]any{"request": "sender data", "data": items})
	d := &net.Dialer{Timeout: 15 * time.Second}
	var conn net.Conn
	var err error
	if s.tlsCfg != nil {
		cfg := s.tlsCfg.Clone()
		if s.issuer != "" || s.subject != "" {
			// a pinned issuer or subject: the certificate is checked as Zabbix checks one - its chain to tls_ca and
			// the pinned strings, never a host name. crypto/tls's own check (the name with the chain) is off, and
			// VerifyConnection, which runs on every connection whatever InsecureSkipVerify says, does the rest.
			roots := cfg.RootCAs
			cfg.InsecureSkipVerify = true
			cfg.VerifyConnection = func(cs tls.ConnectionState) error {
				if len(cs.PeerCertificates) == 0 {
					return errors.New("the server sent no certificate")
				}
				c := cs.PeerCertificates[0]
				inter := x509.NewCertPool()
				for _, ic := range cs.PeerCertificates[1:] {
					inter.AddCert(ic)
				}
				if _, err := c.Verify(x509.VerifyOptions{Roots: roots, Intermediates: inter,
					KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
					return fmt.Errorf("the server certificate does not chain to tls_ca: %w", err)
				}
				if s.issuer != "" {
					if got, err := zbxName(c.RawIssuer); err != nil || got != s.issuer {
						return fmt.Errorf("the server certificate's issuer %q is not tls_server_issuer", got)
					}
				}
				if s.subject != "" {
					if got, err := zbxName(c.RawSubject); err != nil || got != s.subject {
						return fmt.Errorf("the server certificate's subject %q is not tls_server_subject", got)
					}
				}
				return nil
			}
		}
		conn, err = (&tls.Dialer{NetDialer: d, Config: cfg}).DialContext(ctx, "tcp", s.addr)
	} else {
		conn, err = d.DialContext(ctx, "tcp", s.addr)
	}
	if err != nil {
		return fmt.Errorf("zabbix %s: %w", s.addr, err)
	}
	defer func() { _ = conn.Close() }()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	if _, err := conn.Write(zbxFrame(body)); err != nil {
		return fmt.Errorf("zabbix %s: write: %w", s.addr, err)
	}
	raw, err := zbxRead(conn)
	if err != nil {
		return fmt.Errorf("zabbix %s: %w", s.addr, err)
	}
	var ans struct {
		Response string `json:"response"`
		Info     string `json:"info"`
	}
	if err := json.Unmarshal(raw, &ans); err != nil {
		return fmt.Errorf("zabbix %s answered no JSON: %q", s.addr, capLine(string(raw)))
	}
	if ans.Response != "success" {
		return fmt.Errorf("zabbix %s answered %q: %s", s.addr, ans.Response, capLine(ans.Info))
	}
	mm := zbxInfoRE.FindStringSubmatch(ans.Info)
	if mm == nil {
		return fmt.Errorf("zabbix %s answered success without its counts: %q", s.addr, capLine(ans.Info))
	}
	processed, _ := strconv.Atoi(mm[1])
	failed, _ := strconv.Atoi(mm[2])
	if processed != len(items) {
		return fmt.Errorf("zabbix %s processed %d of %d value(s) (failed %d) for host %q, key %q: %s", s.addr, processed, len(items), failed, s.host, s.key, zbxCauses)
	}
	return nil
}

// push is mode api: history.push with the values; every value must come back without an error.
func (s *zabbixSender) push(ctx context.Context, items []zbxItem) error {
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": "history.push", "params": items, "id": 1})
	resp, _, err := postRetrying(ctx, s.client, func() (*http.Request, error) {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.api.String(), bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json-rpc")
		req.Header.Set("Authorization", "Bearer "+s.token)
		req.Header.Set("User-Agent", "pgvigil-alerts")
		return req, nil
	})
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			return fmt.Errorf("post %s: %w", hostOf(s.api), ue.Err)
		}
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, zbxMaxAnswer))
	switch {
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return refused("%s answered %d with a redirect: not followed (the send goes to the configured URL only)", hostOf(s.api), resp.StatusCode)
	case resp.StatusCode != http.StatusOK:
		return fmt.Errorf("%s answered %s", hostOf(s.api), resp.Status)
	}
	var ans struct {
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
			Data    string `json:"data"`
		} `json:"error"`
		Result *struct {
			Response string `json:"response"`
			Data     []struct {
				ItemID string `json:"itemid"`
				Error  string `json:"error"`
			} `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &ans); err != nil {
		return fmt.Errorf("%s answered no JSON-RPC: %q", hostOf(s.api), capLine(s.scrub(string(raw))))
	}
	if ans.Error != nil {
		return fmt.Errorf("%s: history.push refused (%d): %s %s", hostOf(s.api), ans.Error.Code, s.scrub(ans.Error.Message), s.scrub(ans.Error.Data))
	}
	if ans.Result == nil || len(ans.Result.Data) != len(items) {
		return fmt.Errorf("%s: history.push answered no result per value", hostOf(s.api))
	}
	var bad []string
	for i, d := range ans.Result.Data {
		if d.Error != "" {
			bad = append(bad, fmt.Sprintf("value %d: %s", i+1, s.scrub(d.Error)))
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("%s: history.push refused %d of %d value(s) for host %q, key %q: %s", hostOf(s.api), len(bad), len(items), s.host, s.key, capLine(strings.Join(bad, "; ")))
	}
	return nil
}

// scrub takes the API token out of a text Zabbix sent back.
func (s *zabbixSender) scrub(t string) string {
	if s.token != "" {
		t = strings.ReplaceAll(t, s.token, "[token]")
	}
	return t
}
