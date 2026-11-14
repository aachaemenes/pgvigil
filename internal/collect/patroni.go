package collect

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The Patroni read of the rolechange collection (task 376; the repository side is migration 0144: import_rolechange
// hands the rows to import_patroni; pg_patroni_checks). It runs with the role read, every minute, on a self-managed
// server, so a server without Patroni costs nothing more than the role query's one EXISTS.
//
// The endpoint: the instance's patroni: block (url - another port or https -, ca_file, cert_file and key_file for a
// REST API that asks for a client certificate), else http://<the dsn's host>:8008 (Patroni's default; a socket
// directory means this machine), and the default only while a session whose application name starts with 'Patroni' is
// connected (Patroni's own: 'Patroni heartbeat', 'Patroni restapi'). Neither = no request and no rows.
//
// The reads, each a GET of at most 1 MB in 3 s, never a redirect, the endpoint's TLS settings on every one:
//   - <endpoint>/cluster: the scope, the pause flag, each member (name, role, state, host, port, timeline, lag, a
//     pending restart and its reason, api_url);
//   - every member's api_url (its /patroni), in parallel: what /cluster does not carry - when the member last reached
//     the DCS (dcs_last_seen), whether failsafe mode holds its leader up (failsafe_mode_is_active), its own view of
//     the pause and of a pending restart, its Patroni version and the cluster's system identifier. A member whose
//     own API does not answer keeps its /cluster row, with the message;
//   - when /cluster fails (Patroni answers it from the DCS: with the DCS down it does not), <endpoint>/patroni alone:
//     the endpoint's own member, so a DCS outage is still read (its dcs_last_seen ageing, failsafe mode), the other
//     members left as they were.
//
// A read that fails is a row (ok false and its message; a TLS endpoint asked over http, or the reverse, a certificate
// no CA in ca_file signed, a missing client certificate: each says so), never a collector error: the default endpoint
// is a guess. Read only.

// patroniPort is Patroni's default REST port; patroniTimeout bounds each request; patroniMaxBody bounds each answer.
const (
	patroniPort    = "8008"
	patroniTimeout = 3 * time.Second
	patroniMaxBody = 1 << 20
)

// patroniRows is the read for one instance: none when no patroni: block names an endpoint and no Patroni session is
// connected (sessionSeen, from the role query), else a 'patroni_read' row and its member rows.
func patroniRows(ctx context.Context, in config.Instance, sessionSeen bool) []Row {
	ep, err := patroniEndpointOf(in)
	if err != nil {
		// a patroni: block that cannot be used (config validation catches most): the read row says why
		return []Row{{"kind": "patroni_read", "url": ep.base + "/cluster", "configured": true, "ok": false, "message": err.Error()}}
	}
	if !ep.configured && (!sessionSeen || in.DSNRaw == "") {
		return nil
	}
	defer ep.client.CloseIdleConnections()
	return patroniRead(ctx, ep)
}

// patroniEndpoint is where the cluster is read and how.
type patroniEndpoint struct {
	base       string // scheme://host:port, no path
	configured bool   // from the patroni: block
	client     *http.Client
	// certAsked: an https endpoint read without a client certificate asked for one in its handshake (a REST API with
	// restapi.verify_client). Patroni's server then drops the connection, which the client sees as a broken pipe or a
	// reset before the TLS alert can be read: this flag is what says why.
	certAsked *atomic.Bool
}

// patroniEndpointOf builds the endpoint: the patroni: block when it names a url, else the default on the dsn's host.
func patroniEndpointOf(in config.Instance) (patroniEndpoint, error) {
	pc := in.Patroni
	if pc == nil || strings.TrimSpace(pc.URL) == "" {
		return patroniEndpoint{base: patroniDefaultBase(in.DSN()), client: patroniHTTP(nil)}, nil
	}
	base, err := patroniBase(pc.URL)
	ep := patroniEndpoint{base: base, configured: true}
	if err != nil {
		ep.base = strings.TrimSpace(pc.URL)
		return ep, err
	}
	tc, err := patroniTLS(pc.CAFile, pc.CertFile, pc.KeyFile)
	if err != nil {
		return ep, err
	}
	if strings.HasPrefix(base, "https://") {
		if tc == nil {
			tc = &tls.Config{MinVersion: tls.VersionTLS12}
		}
		if len(tc.Certificates) == 0 {
			asked := &atomic.Bool{}
			tc.GetClientCertificate = func(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
				asked.Store(true)
				return &tls.Certificate{}, nil // none: the handshake goes on, the server decides
			}
			ep.certAsked = asked
		}
	}
	ep.client = patroniHTTP(tc)
	return ep, nil
}

// patroniDefaultBase is http://<the dsn's host>:8008: a socket directory or no host = this machine.
func patroniDefaultBase(dsn string) string {
	host := "127.0.0.1"
	if c, err := pgx.ParseConfig(dsn); err == nil && c.Host != "" && !strings.HasPrefix(c.Host, "/") {
		host = c.Host
	}
	return "http://" + net.JoinHostPort(host, patroniPort)
}

// patroniBase checks a configured url (http or https, a host, a port or the scheme's) and drops a path the user may
// have copied with it (/cluster, /patroni, a trailing slash).
func patroniBase(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", fmt.Errorf("patroni.url: %v", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", fmt.Errorf("patroni.url %q: the scheme must be http or https", raw)
	}
	if u.Hostname() == "" {
		return "", fmt.Errorf("patroni.url %q names no host", raw)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("patroni.url %q: a scheme, a host and a port only", raw)
	}
	switch strings.TrimRight(u.Path, "/") {
	case "", "/cluster", "/patroni":
	default:
		return "", fmt.Errorf("patroni.url %q: a scheme, a host and a port only", raw)
	}
	return u.Scheme + "://" + u.Host, nil
}

// patroniTLS is the client side of an https endpoint: the CA that signed the API's certificate (ca_file; empty = the
// system's roots) and a client certificate (cert_file and key_file, for restapi.verify_client). nil = nothing set.
func patroniTLS(caFile, certFile, keyFile string) (*tls.Config, error) {
	caFile, certFile, keyFile = strings.TrimSpace(caFile), strings.TrimSpace(certFile), strings.TrimSpace(keyFile)
	if caFile == "" && certFile == "" && keyFile == "" {
		return nil, nil
	}
	tc := &tls.Config{MinVersion: tls.VersionTLS12}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("patroni.ca_file: %v", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("patroni.ca_file %s holds no PEM certificate", caFile)
		}
		tc.RootCAs = pool
	}
	if certFile != "" || keyFile != "" {
		if certFile == "" || keyFile == "" {
			return nil, errors.New("patroni: cert_file and key_file go together")
		}
		c, err := tls.LoadX509KeyPair(certFile, keyFile)
		if err != nil {
			return nil, fmt.Errorf("patroni client certificate: %v", err)
		}
		tc.Certificates = []tls.Certificate{c}
	}
	return tc, nil
}

// patroniHTTP is a client for one run: 3 s per request, no redirect, the proxy from the environment as Go's default.
func patroniHTTP(tc *tls.Config) *http.Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	if tc != nil {
		tr.TLSClientConfig = tc
	}
	return &http.Client{Timeout: patroniTimeout, Transport: tr,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

// patroniMember is one member of GET /cluster; lag is a number of bytes or a word ('unknown').
type patroniMember struct {
	Name                 string          `json:"name"`
	Role                 string          `json:"role"`
	State                string          `json:"state"`
	Host                 string          `json:"host"`
	Port                 int             `json:"port"`
	Timeline             *int64          `json:"timeline"`
	Lag                  json.RawMessage `json:"lag"`
	APIURL               string          `json:"api_url"`
	PendingRestart       bool            `json:"pending_restart"`
	PendingRestartReason json.RawMessage `json:"pending_restart_reason"`
}

// patroniCluster is GET /cluster.
type patroniCluster struct {
	Scope   string          `json:"scope"`
	Pause   bool            `json:"pause"`
	Members []patroniMember `json:"members"`
}

// patroniStatus is a member's own GET /patroni (Patroni 4.1: dcs_last_seen in epoch seconds; pause, pending_restart,
// cluster_unlocked and failsafe_mode_is_active only when true).
type patroniStatus struct {
	State                string          `json:"state"`
	Role                 string          `json:"role"`
	Timeline             *int64          `json:"timeline"`
	DCSLastSeen          *float64        `json:"dcs_last_seen"`
	Pause                bool            `json:"pause"`
	PendingRestart       bool            `json:"pending_restart"`
	PendingRestartReason json.RawMessage `json:"pending_restart_reason"`
	FailsafeActive       bool            `json:"failsafe_mode_is_active"`
	ClusterUnlocked      bool            `json:"cluster_unlocked"`
	SystemID             string          `json:"database_system_identifier"`
	Patroni              struct {
		Version string `json:"version"`
		Scope   string `json:"scope"`
		Name    string `json:"name"`
	} `json:"patroni"`
}

// patroniRead reads the cluster: a 'patroni_read' row, then a 'patroni' row per member (or, when /cluster fails and the
// endpoint's own /patroni answers, the endpoint's member alone).
func patroniRead(ctx context.Context, ep patroniEndpoint) []Row {
	read := Row{"kind": "patroni_read", "url": ep.base + "/cluster", "configured": ep.configured, "ok": false}
	var cl patroniCluster
	cerr := patroniGet(ctx, ep.client, ep.base+"/cluster", &cl, false)
	if cerr == nil && len(cl.Members) == 0 {
		cerr = errors.New("the answer is not a Patroni cluster (no members)")
	}
	if cerr != nil {
		var st patroniStatus
		if serr := patroniGet(ctx, ep.client, ep.base+"/patroni", &st, true); serr != nil || st.Patroni.Name == "" {
			read["message"] = cerr.Error()
			// a TLS endpoint asked over http fails in more than one way (EOF, a reset, a 400 from the TLS side): the
			// port's own handshake says it
			if strings.HasPrefix(ep.base, "http://") && cerr.Error() != patroniTLSHint && patroniSpeaksTLS(ctx, ep.base) {
				read["message"] = patroniTLSHint
			}
			// an https endpoint that asked for a client certificate and then dropped the connection
			if ep.certAsked != nil && ep.certAsked.Load() && patroniDropped(cerr.Error()) {
				read["message"] = patroniCertHint
			}
			return []Row{read}
		}
		// Patroni answers but not for the cluster: its own member only
		read["ok"], read["cluster_ok"], read["message"] = true, false, "/cluster: "+cerr.Error()
		read["scope"], read["paused"], read["members"] = nilIfEmpty(st.Patroni.Scope), st.Pause, 1
		read["system_identifier"] = nilIfEmpty(st.SystemID)
		row := Row{"kind": "patroni", "scope": nilIfEmpty(st.Patroni.Scope), "member": st.Patroni.Name, "role": nilIfEmpty(st.Role),
			"state": nilIfEmpty(st.State), "timeline": st.Timeline, "api_url": ep.base + "/patroni", "self": true}
		patroniStatusInto(row, &st, nil)
		return []Row{read, row}
	}
	read["ok"], read["cluster_ok"], read["scope"], read["paused"], read["members"] = true, true, nilIfEmpty(cl.Scope), cl.Pause, len(cl.Members)
	var leader string
	for _, m := range cl.Members {
		if leader == "" && (m.Role == "leader" || m.Role == "standby_leader") {
			leader = m.Name
		}
	}
	read["leader"] = nilIfEmpty(leader)

	// every member's own /patroni, in parallel
	stats := make([]*patroniStatus, len(cl.Members))
	errs := make([]error, len(cl.Members))
	var wg sync.WaitGroup
	for i, m := range cl.Members {
		u, err := patroniMemberURL(m.APIURL)
		if err != nil {
			errs[i] = err
			continue
		}
		wg.Add(1)
		go func(i int, u, name string) {
			defer wg.Done()
			var st patroniStatus
			if err := patroniGet(ctx, ep.client, u, &st, true); err != nil {
				errs[i] = err
				return
			}
			// the answer must be the member's own: an api_url that reaches another Patroni (a connect_address of
			// 127.0.0.1, a wrong DCS entry) or any other JSON is not taken for it
			if st.Patroni.Name != name {
				errs[i] = fmt.Errorf("api_url answers for member %q", st.Patroni.Name)
				return
			}
			stats[i] = &st
		}(i, u, m.Name)
	}
	wg.Wait()

	out := []Row{read}
	for i, m := range cl.Members {
		if m.Name == "" {
			continue
		}
		row := Row{"kind": "patroni", "scope": nilIfEmpty(cl.Scope), "member": m.Name, "role": nilIfEmpty(m.Role), "state": nilIfEmpty(m.State),
			"host": nilIfEmpty(m.Host), "port": m.Port, "timeline": m.Timeline, "api_url": nilIfEmpty(m.APIURL),
			"pending_restart": m.PendingRestart}
		if r := patroniReason(m.PendingRestartReason); r != "" {
			row["pending_restart_reason"] = r
		}
		if n, err := strconv.ParseInt(strings.TrimSpace(string(m.Lag)), 10, 64); err == nil {
			row["lag_bytes"] = n
		} else if len(m.Lag) > 0 && string(m.Lag) != "null" {
			row["lag_text"] = strings.Trim(string(m.Lag), `"`)
		}
		patroniStatusInto(row, stats[i], errs[i])
		if stats[i] != nil && read["system_identifier"] == nil && stats[i].SystemID != "" {
			read["system_identifier"] = stats[i].SystemID
		}
		out = append(out, row)
	}
	return out
}

// patroniStatusInto adds a member's own /patroni to its row: what /cluster lacks, and a pending restart either names.
func patroniStatusInto(row Row, st *patroniStatus, err error) {
	if st == nil {
		row["api_ok"] = false
		if err != nil {
			row["api_message"] = err.Error()
		}
		return
	}
	row["api_ok"], row["paused"], row["failsafe_active"] = true, st.Pause, st.FailsafeActive
	row["version"] = nilIfEmpty(st.Patroni.Version)
	if st.DCSLastSeen != nil && *st.DCSLastSeen > 0 {
		sec := int64(*st.DCSLastSeen)
		row["dcs_last_seen"] = time.Unix(sec, 0).UTC()
	}
	if st.PendingRestart {
		row["pending_restart"] = true
		if _, ok := row["pending_restart_reason"]; !ok {
			if r := patroniReason(st.PendingRestartReason); r != "" {
				row["pending_restart_reason"] = r
			}
		}
	}
}

// patroniMemberURL is a member's api_url as the DCS holds it, rebuilt as http(s)://<host:port>/patroni: its scheme and
// address only, so no other path or query is asked.
func patroniMemberURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil {
		return "", fmt.Errorf("api_url %q is not an http(s) address", raw)
	}
	return u.Scheme + "://" + u.Host + "/patroni", nil
}

// patroniReason is pending_restart_reason ({"max_connections": {"old_value": "100", "new_value": "120"}}) as
// 'max_connections 100 -> 120', the settings in name order.
func patroniReason(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var m map[string]struct {
		Old any `json:"old_value"`
		New any `json:"new_value"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return ""
	}
	names := make([]string, 0, len(m))
	for k := range m {
		names = append(names, k)
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, k := range names {
		parts = append(parts, fmt.Sprintf("%s %v -> %v", k, m[k].Old, m[k].New))
	}
	return strings.Join(parts, ", ")
}

// patroniGet GETs one JSON answer into v. A member's /patroni answers 503 for a member that is not running: its body
// is still the member's state, so anyStatus takes any status that carries a JSON object.
func patroniGet(ctx context.Context, c *http.Client, u string, v any, anyStatus bool) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.Do(req)
	if err != nil {
		return errors.New(patroniErrText(err))
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, patroniMaxBody))
	if err != nil {
		return errors.New(patroniErrText(err))
	}
	if resp.StatusCode != http.StatusOK && !anyStatus {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	if err := json.Unmarshal(body, v); err != nil {
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		return errors.New("the answer is not Patroni's JSON")
	}
	return nil
}

// patroniErrText is a request's failure in a line that says what to change: a TLS endpoint asked over http, a plain
// endpoint asked over https, a certificate no configured CA signed, a client certificate asked for, a timeout.
func patroniErrText(err error) string {
	s := err.Error()
	var ua x509.UnknownAuthorityError
	var hn x509.HostnameError
	var ne net.Error
	switch {
	case strings.Contains(s, "malformed HTTP response") && strings.Contains(s, `\x15\x03`):
		return patroniTLSHint
	case strings.Contains(s, "server gave HTTP response to HTTPS client"):
		return "the endpoint answers plain HTTP: name it http:// in the instance's patroni.url"
	case errors.As(err, &ua):
		return "the endpoint's certificate is signed by a CA the collector does not trust: name it in patroni.ca_file"
	case errors.As(err, &hn):
		return "the endpoint's certificate does not name this host: " + hn.Error()
	case strings.Contains(s, "certificate required") || strings.Contains(s, "bad certificate"):
		return patroniCertHint
	case errors.As(err, &ne) && ne.Timeout():
		return "no answer in " + patroniTimeout.String()
	}
	if i := strings.LastIndex(s, ": "); i >= 0 && i+2 < len(s) {
		return s[i+2:]
	}
	return s
}

// patroniTLSHint is the message for a TLS endpoint asked over http.
const patroniTLSHint = "the endpoint answers in TLS: name it https:// in the instance's patroni.url"

// patroniSpeaksTLS: does the host and port of an http:// endpoint answer a TLS handshake. Only the handshake is made
// (no request is sent), with the usual checks: a certificate this machine does not trust still means TLS is spoken.
func patroniSpeaksTLS(ctx context.Context, base string) bool {
	u, err := url.Parse(base)
	if err != nil || u.Scheme != "http" || u.Hostname() == "" {
		return false
	}
	addr := u.Host
	if u.Port() == "" {
		addr = net.JoinHostPort(u.Hostname(), "80")
	}
	d := &tls.Dialer{NetDialer: &net.Dialer{Timeout: patroniTimeout}, Config: &tls.Config{MinVersion: tls.VersionTLS12}}
	c, err := d.DialContext(ctx, "tcp", addr)
	if err == nil {
		_ = c.Close()
		return true
	}
	var cv *tls.CertificateVerificationError
	return errors.As(err, &cv)
}

// patroniCertHint is the message for an endpoint that asks for a client certificate none was configured for.
const patroniCertHint = "the endpoint asks for a client certificate: name it in patroni.cert_file and patroni.key_file"

// patroniDropped: a failure that is the server ending the connection (what a REST API with verify_client does to a
// client without a certificate), as patroniErrText words it.
func patroniDropped(msg string) bool {
	switch msg {
	case "broken pipe", "connection reset by peer", "EOF", "unexpected EOF", patroniCertHint:
		return true
	}
	return strings.Contains(msg, "handshake failure")
}
