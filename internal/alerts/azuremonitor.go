package alerts

// Azure Monitor Logs (task B24k, SQLWATCH's action 'Send to Azure Log Monitor'): a channel's azuremonitor: block
// writes each alert as a row of a Log Analytics custom table through the Logs Ingestion API - never the HTTP Data
// Collector API (a workspace key: Microsoft ended its support on 2026-09-14). The site makes, once: an app
// registration with a client secret, a custom table (<name>_CL), and a data collection rule (DCR) whose input stream
// takes the columns below, with the role Monitoring Metrics Publisher on the DCR for the app. docs/alerts.md holds the
// table's and the stream's JSON, the only statement of the columns sent.
//
//	azuremonitor: {endpoint: https://<the DCR's logs ingestion endpoint>, dcr_id: dcr-<32 hex>, stream: Custom-PgvigilAlerts,
//	               tenant: <tenant id>, client_id: <the app's id>, client_secret: env:PGVIGIL_AZ_SECRET, cloud: public}
//
// The token: client credentials at the cloud's Microsoft Entra host (public login.microsoftonline.com, usgov
// login.microsoftonline.us, china login.partner.microsoftonline.cn), scope the Monitor audience's .default as
// Microsoft's ingestion tutorial writes it (https://monitor.azure.com//.default; .us, .cn), kept until 5 minutes before
// it expires and fetched again once on a 401. The upload: POST {endpoint}/dataCollectionRules/{dcr_id}/streams/{stream}
// ?api-version=2023-01-01 with a JSON array; 204 is the tutorial's success (any 2xx is taken). A call carries under 1 MB
// (the service's limit, compressed or not): more rows go in several calls. A field over 64 KB is truncated by the
// service, so the detail is cut at 60,000 bytes here, on a character. A 429's short Retry-After is waited out
// (webhook.go); a 400 shows Azure's message. The secret comes through env: or file: only and is never logged or shown.

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// AzureMonitor is a channel's azuremonitor: block.
type AzureMonitor struct {
	Endpoint     string `yaml:"endpoint"`      // the DCR's logs ingestion endpoint (or a data collection endpoint)
	DCRID        string `yaml:"dcr_id"`        // the DCR's immutable id (dcr-...)
	Stream       string `yaml:"stream"`        // the DCR's input stream (Custom-...)
	Tenant       string `yaml:"tenant"`        // the directory (tenant) id
	ClientID     string `yaml:"client_id"`     // the app registration's id
	ClientSecret string `yaml:"client_secret"` // env: or file:
	Cloud        string `yaml:"cloud"`         // public (default) | usgov | china
	LoginURL     string `yaml:"login_url"`     // tests only: a loopback token endpoint's base (plain http on loopback)
}

// azCloud is a cloud's sign-in host and Monitor audience (Microsoft's national-cloud and ingestion pages).
type azCloud struct{ login, audience string }

var azClouds = map[string]azCloud{
	"public": {"https://login.microsoftonline.com", "https://monitor.azure.com"},
	"usgov":  {"https://login.microsoftonline.us", "https://monitor.azure.us"},
	"china":  {"https://login.partner.microsoftonline.cn", "https://monitor.azure.cn"},
}

const (
	azAPIVersion = "2023-01-01" // the ingestion tutorial's
	azMaxCall    = 900 << 10    // a call's body under the service's 1 MB
	azMaxDetail  = 60000        // bytes of a detail (the service truncates a field over 64 KB)
	azTokenSlack = 5 * time.Minute
)

var (
	azGUIDRE   = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
	azDCRRE    = regexp.MustCompile(`^dcr-[0-9a-f]{32}$`)
	azStreamRE = regexp.MustCompile(`^Custom-[A-Za-z0-9_]{1,200}$`)
)

type azureSender struct {
	ingest  *url.URL // the upload's full address
	token   *url.URL // the token endpoint
	scope   string
	client  string
	secret  string
	http    *http.Client
	mu      sync.Mutex
	bearer  string
	expires time.Time
}

func (a *AzureMonitor) build() (sender, error) {
	cloud := strings.TrimSpace(a.Cloud)
	if cloud == "" {
		cloud = "public"
	}
	c, ok := azClouds[cloud]
	if !ok {
		return nil, fmt.Errorf("azuremonitor.cloud must be public, usgov or china (got %q)", a.Cloud)
	}
	sec, err := secret("azuremonitor.client_secret", a.ClientSecret)
	if err != nil {
		return nil, err
	}
	tenant, cid := strings.TrimSpace(a.Tenant), strings.TrimSpace(a.ClientID)
	if !azGUIDRE.MatchString(tenant) {
		return nil, errors.New("azuremonitor.tenant is the directory (tenant) id, a GUID")
	}
	if !azGUIDRE.MatchString(cid) {
		return nil, errors.New("azuremonitor.client_id is the app registration's id, a GUID")
	}
	dcr, stream := strings.TrimSpace(a.DCRID), strings.TrimSpace(a.Stream)
	if !azDCRRE.MatchString(dcr) {
		return nil, errors.New("azuremonitor.dcr_id is the DCR's immutable id (dcr- and 32 hexadecimal digits)")
	}
	if !azStreamRE.MatchString(stream) {
		return nil, errors.New("azuremonitor.stream is the DCR's input stream (Custom- and letters, digits, '_')")
	}
	ep, err := url.Parse(strings.TrimSpace(a.Endpoint))
	if err != nil || ep.Host == "" {
		return nil, errors.New("azuremonitor.endpoint is not an absolute URL (the DCR's logs ingestion endpoint)")
	}
	if ep.Scheme != "https" && (ep.Scheme != "http" || !loopback(ep.Hostname())) {
		return nil, fmt.Errorf("azuremonitor.endpoint must be https (got %s)", hostOf(ep))
	}
	if ep.User != nil || ep.RawQuery != "" || strings.Trim(ep.Path, "/") != "" {
		return nil, errors.New("azuremonitor.endpoint is the endpoint's address only: no user:password, path or query")
	}
	login := c.login
	if a.LoginURL != "" {
		lu, err := url.Parse(a.LoginURL)
		if err != nil || lu.Scheme != "http" || !loopback(lu.Hostname()) {
			return nil, errors.New("azuremonitor.login_url is for tests: a plain http loopback address only")
		}
		login = strings.TrimRight(lu.String(), "/")
	}
	tok, _ := url.Parse(login + "/" + url.PathEscape(tenant) + "/oauth2/v2.0/token")
	ing := &url.URL{Scheme: ep.Scheme, Host: ep.Host, Path: "/dataCollectionRules/" + dcr + "/streams/" + stream,
		RawQuery: "api-version=" + azAPIVersion}
	return &azureSender{ingest: ing, token: tok, scope: c.audience + "//.default", client: cid, secret: strings.TrimSpace(sec),
		http: &http.Client{
			Transport: &http.Transport{
				Proxy:               nil, // the configured destinations only
				DialContext:         (&net.Dialer{Timeout: 15 * time.Second}).DialContext,
				TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
				TLSHandshakeTimeout: 15 * time.Second,
				ForceAttemptHTTP2:   true,
			},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}}, nil
}

func (s *azureSender) destination() string { return hostOf(s.ingest) + " (azure monitor logs)" }

// perAlert: a message's alerts go as the rows of one or more calls.
func (s *azureSender) perAlert() bool { return false }

// azRow is one alert as a row of the stream (docs/alerts.md names the columns and their types).
type azRow struct {
	TimeGenerated string `json:"TimeGenerated"`
	Event         string `json:"Event"`
	Severity      string `json:"Severity"`
	Instance      string `json:"Instance"`
	Source        string `json:"Source"`
	Check         string `json:"Check"`
	Value         string `json:"Value"`
	Detail        string `json:"Detail"`
	Link          string `json:"Link"`
	FindingKey    string `json:"FindingKey"`
}

// cutBytes cuts s to at most n bytes on a character's start.
func cutBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

func azRows(m Message) []azRow {
	out := make([]azRow, 0, len(m.Alerts))
	for _, a := range m.Alerts {
		out = append(out, azRow{TimeGenerated: m.SentAt.UTC().Format(time.RFC3339Nano), Event: a.Event, Severity: a.Severity,
			Instance: a.Instance, Source: a.Source, Check: a.Setting, Value: cutBytes(a.Value, azMaxDetail),
			Detail: cutBytes(a.Detail, azMaxDetail), Link: a.URL, FindingKey: a.FindingKey})
	}
	return out
}

// azCalls packs the rows into JSON arrays of at most azMaxCall bytes each (a row is always sent, alone if need be).
func azCalls(rows []azRow) [][]byte {
	var out [][]byte
	var cur []json.RawMessage
	size := 2
	flush := func() {
		if len(cur) > 0 {
			b, _ := json.Marshal(cur)
			out = append(out, b)
		}
		cur, size = nil, 2
	}
	for _, r := range rows {
		b, _ := json.Marshal(r)
		if len(cur) > 0 && size+len(b)+1 > azMaxCall {
			flush()
		}
		cur = append(cur, b)
		size += len(b) + 1
	}
	flush()
	return out
}

func (s *azureSender) send(ctx context.Context, m Message) error {
	for _, body := range azCalls(azRows(m)) {
		if err := s.upload(ctx, body); err != nil {
			return err
		}
	}
	return nil
}

func (s *azureSender) upload(ctx context.Context, body []byte) error {
	for try := 0; ; try++ {
		tok, err := s.bearerToken(ctx, try > 0)
		if err != nil {
			return err
		}
		resp, _, err := postRetrying(ctx, s.http, func() (*http.Request, error) {
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.ingest.String(), bytes.NewReader(body))
			if err != nil {
				return nil, err
			}
			req.Header.Set("Authorization", "Bearer "+tok)
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("User-Agent", "pgvigil-alerts")
			return req, nil
		})
		if err != nil {
			var ue *url.Error
			if errors.As(err, &ue) {
				return fmt.Errorf("post %s: %w", hostOf(s.ingest), ue.Err)
			}
			return err
		}
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		_ = resp.Body.Close()
		switch {
		case resp.StatusCode >= 200 && resp.StatusCode < 300:
			return nil
		case resp.StatusCode == http.StatusUnauthorized && try == 0:
			continue // the token is fetched again, once
		case resp.StatusCode >= 300 && resp.StatusCode < 400:
			return refused("%s answered %d with a redirect: not followed (the send goes to the configured URL only)", hostOf(s.ingest), resp.StatusCode)
		}
		return fmt.Errorf("%s answered %s: %s", hostOf(s.ingest), resp.Status, azWords(raw))
	}
}

// azWords is Azure's message in an error body: the ingestion's {"error":{"code","message"}}, or the token endpoint's
// {"error":"<code>","error_description":"..."}; else the body's first line. Each hide (the client secret) is replaced
// before the words are cut, so no part of it survives a cut through it (B24k review 8).
func azWords(raw []byte, hide ...string) string {
	capLine := func(t string) string {
		for _, h := range hide {
			if h != "" {
				t = strings.ReplaceAll(t, h, "[secret]")
			}
		}
		return capLine(t)
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(raw, &top) == nil {
		var obj struct{ Code, Message string }
		var code, desc string
		if e, ok := top["error"]; ok {
			if json.Unmarshal(e, &obj) == nil && obj.Message != "" {
				return capLine(strings.TrimSpace(obj.Code + " " + obj.Message))
			}
			_ = json.Unmarshal(e, &code)
		}
		if d, ok := top["error_description"]; ok && json.Unmarshal(d, &desc) == nil && desc != "" {
			return capLine(strings.TrimSpace(code + " " + desc))
		}
	}
	line, _, _ := strings.Cut(strings.TrimSpace(string(raw)), "\n")
	if line == "" {
		return "no error text"
	}
	return capLine(line)
}

// bearerToken is the cached token, fetched when absent, within azTokenSlack of its expiry, or when fresh is asked.
func (s *azureSender) bearerToken(ctx context.Context, fresh bool) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !fresh && s.bearer != "" && time.Now().Add(azTokenSlack).Before(s.expires) {
		return s.bearer, nil
	}
	form := url.Values{"client_id": {s.client}, "client_secret": {s.secret}, "scope": {s.scope}, "grant_type": {"client_credentials"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.token.String(), strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.http.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			return "", fmt.Errorf("token %s: %w", hostOf(s.token), ue.Err)
		}
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("token %s answered %s: %s", hostOf(s.token), resp.Status, azWords(raw, s.secret))
	}
	var t struct {
		Type    string `json:"token_type"`
		Expires int    `json:"expires_in"`
		Access  string `json:"access_token"`
	}
	if err := json.Unmarshal(raw, &t); err != nil || t.Access == "" || !strings.EqualFold(t.Type, "bearer") || t.Expires <= 0 {
		return "", fmt.Errorf("token %s answered no bearer token", hostOf(s.token))
	}
	s.bearer, s.expires = t.Access, time.Now().Add(time.Duration(t.Expires)*time.Second)
	return s.bearer, nil
}
