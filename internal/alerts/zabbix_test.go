package alerts

import (
	"bytes"
	"compress/zlib"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// task B24k: the Zabbix kind against a loopback server speaking the sender protocol (zabbix_sender's appendix: the
// ZBXD header, 'sender data', 'processed: N; failed: M') and a loopback stub of history.push.

type zbxStub struct {
	mu       sync.Mutex
	got      []map[string]any
	info     string // the answer's info; "" = all processed
	response string // "" = success
	compress bool
}

func (st *zbxStub) serve(t *testing.T, ln net.Listener) {
	t.Helper()
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			defer func() { _ = c.Close() }()
			raw, err := zbxRead(c)
			if err != nil {
				return
			}
			var req map[string]any
			if json.Unmarshal(raw, &req) != nil {
				return
			}
			st.mu.Lock()
			st.got = append(st.got, req)
			info, resp, comp := st.info, st.response, st.compress
			st.mu.Unlock()
			n := len(req["data"].([]any))
			if info == "" {
				info = fmt.Sprintf("processed: %d; failed: 0; total: %d; seconds spent: 0.000055", n, n)
			}
			if resp == "" {
				resp = "success"
			}
			body, _ := json.Marshal(map[string]any{"response": resp, "info": info})
			if !comp {
				_, _ = c.Write(zbxFrame(body))
				return
			}
			var z bytes.Buffer
			zw := zlib.NewWriter(&z)
			_, _ = zw.Write(body)
			_ = zw.Close()
			var b bytes.Buffer
			b.WriteString("ZBXD")
			b.WriteByte(0x03)
			_ = binary.Write(&b, binary.LittleEndian, uint32(z.Len()))
			_ = binary.Write(&b, binary.LittleEndian, uint32(len(body)))
			b.Write(z.Bytes())
			_, _ = c.Write(b.Bytes())
		}(c)
	}
}

// set changes the stub's answer under its lock (the server goroutine reads it there).
func (st *zbxStub) set(info, response string, compress bool) {
	st.mu.Lock()
	st.info, st.response, st.compress = info, response, compress
	st.mu.Unlock()
}

func (st *zbxStub) requests() []map[string]any {
	st.mu.Lock()
	defer st.mu.Unlock()
	return append([]map[string]any(nil), st.got...)
}

func zabbixFor(t *testing.T, z Zabbix) *zabbixSender {
	t.Helper()
	s, err := z.build()
	if err != nil {
		t.Fatal(err)
	}
	return s.(*zabbixSender)
}

func TestZabbixRefuses(t *testing.T) {
	t.Setenv("PGV_TEST_ZBX_TOKEN", "c0ffee")
	dir := t.TempDir()
	ca := filepath.Join(dir, "ca.pem")
	_ = os.WriteFile(ca, []byte("not a certificate"), 0o600)
	for name, z := range map[string]Zabbix{
		"plain off loopback":   {Server: "zabbix.example.org", Host: "pgvigil"},
		"half the TLS files":   {Server: "zabbix.example.org", Host: "pgvigil", TLSCA: ca},
		"a bad host name":      {Server: "127.0.0.1", Host: "pg/vigil"},
		"no server":            {Host: "pgvigil"},
		"api with plain http":  {Mode: "api", URL: "http://zabbix.example.org/zabbix", Token: "env:PGV_TEST_ZBX_TOKEN", Host: "pgvigil"},
		"api with an inline":   {Mode: "api", URL: "https://zabbix.example.org/zabbix", Token: "c0ffee", Host: "pgvigil"},
		"api with a server":    {Mode: "api", URL: "https://zabbix.example.org", Token: "env:PGV_TEST_ZBX_TOKEN", Host: "pgvigil", Server: "x"},
		"a mode":               {Mode: "trapper", Server: "127.0.0.1", Host: "pgvigil"},
		"issuer without TLS":   {Server: "127.0.0.1", Host: "pgvigil", TLSServerIssuer: "CN=x"},
		"sender with a token":  {Server: "127.0.0.1", Host: "pgvigil", Token: "env:PGV_TEST_ZBX_TOKEN"},
		"a key on two lines":   {Server: "127.0.0.1", Host: "pgvigil", Key: "a\nb"},
		"a CA that is not PEM": {Server: "zabbix.example.org", Host: "pgvigil", TLSCA: ca, TLSCert: ca, TLSKey: ca},
	} {
		if _, err := z.build(); err == nil {
			t.Errorf("%s: built", name)
		}
	}
	// the admin's opt-in to plain text off loopback is taken and named in the destination
	s := zabbixFor(t, Zabbix{Server: "zabbix.example.org", Host: "pgvigil", AllowPlain: true})
	if d := s.destination(); !strings.Contains(d, "PLAIN by allow_plain") || !strings.Contains(d, "zabbix.example.org:10051") {
		t.Errorf("destination %q", d)
	}
	ch := Channel{Name: "z", Kind: "zabbix", Zabbix: &Zabbix{Server: "zabbix.example.org", Host: "pgvigil", AllowPlain: true}}
	if err := ch.validate(); err != nil || !ch.PlainByOptIn() {
		t.Errorf("validate %v, PlainByOptIn %v", err, ch.PlainByOptIn())
	}
}

func TestZabbixSender(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	st := &zbxStub{}
	go st.serve(t, ln)
	s := zabbixFor(t, Zabbix{Server: ln.Addr().String(), Host: "pgvigil", Key: "pgvigil.alert"})
	warn := crit
	warn.Severity, warn.FindingKey = "warning", "fedcba9876543210"
	at := time.Date(2026, 11, 15, 8, 0, 0, 123456789, time.UTC)
	if err := s.send(context.Background(), Message{SentAt: at, Alerts: []Alert{crit, warn}}); err != nil {
		t.Fatalf("send: %v", err)
	}
	got := st.requests()
	if len(got) != 1 || got[0]["request"] != "sender data" {
		t.Fatalf("requests %v", got)
	}
	data := got[0]["data"].([]any)
	if len(data) != 2 {
		t.Fatalf("%d values, want 2 in one request", len(data))
	}
	v0 := data[0].(map[string]any)
	if v0["host"] != "pgvigil" || v0["key"] != "pgvigil.alert" || v0["clock"].(float64) != float64(at.Unix()) {
		t.Errorf("value 0 %v", v0)
	}
	var val map[string]any
	if err := json.Unmarshal([]byte(v0["value"].(string)), &val); err != nil || val["severity"] != "critical" || val["instance"] != "erp01" || val["finding_key"] != crit.FindingKey {
		t.Errorf("value 0's value %v (%v)", v0["value"], err)
	}
	if data[1].(map[string]any)["ns"].(float64) <= v0["ns"].(float64) {
		t.Error("the values are not in order within the clock")
	}
	// a value Zabbix did not process is a failed send naming the counts and the possible causes
	st.set("processed: 1; failed: 1; total: 2; seconds spent: 0.0001", "", false)
	err = s.send(context.Background(), Message{SentAt: at, Alerts: []Alert{crit, warn}})
	if err == nil || !strings.Contains(err.Error(), "processed 1 of 2") || !strings.Contains(err.Error(), "Allowed hosts") {
		t.Errorf("a failed value: %v", err)
	}
	st.set("", "failed", false)
	if err := s.send(context.Background(), msg(crit)); err == nil || !strings.Contains(err.Error(), `"failed"`) {
		t.Errorf("response failed: %v", err)
	}
	st.set("no counts here", "", false)
	if err := s.send(context.Background(), msg(crit)); err == nil || !strings.Contains(err.Error(), "without its counts") {
		t.Errorf("an answer without counts: %v", err)
	}
	st.set("", "", true)
	if err := s.send(context.Background(), msg(crit)); err != nil {
		t.Errorf("a compressed answer: %v", err)
	}
}

// testCA makes a CA, a server certificate for 127.0.0.1 and a client certificate, as PEM files in dir.
func testCA(t *testing.T, dir string) (caFile, srvCert, srvKey, cliCert, cliKey string) {
	t.Helper()
	write := func(name, typ string, der []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	caKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	caTpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "proof CA", Organization: []string{"pgvigil test"}},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign}
	caDER, err := x509.CreateCertificate(rand.Reader, caTpl, caTpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caCert, _ := x509.ParseCertificate(caDER)
	leaf := func(serial int64, cn string, usage x509.ExtKeyUsage, server bool) (string, string) {
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		tpl := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: cn},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{usage},
			KeyUsage: x509.KeyUsageDigitalSignature}
		if server {
			tpl.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
		}
		der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &k.PublicKey, caKey)
		if err != nil {
			t.Fatal(err)
		}
		kd, _ := x509.MarshalECPrivateKey(k)
		return write(cn+".crt", "CERTIFICATE", der), write(cn+".key", "EC PRIVATE KEY", kd)
	}
	srvCert, srvKey = leaf(2, "zabbix-server", x509.ExtKeyUsageServerAuth, true)
	cliCert, cliKey = leaf(3, "pgvigil", x509.ExtKeyUsageClientAuth, false)
	return write("ca.pem", "CERTIFICATE", caDER), srvCert, srvKey, cliCert, cliKey
}

func TestZabbixTLS(t *testing.T) {
	dir := t.TempDir()
	ca, sc, sk, cc, ck := testCA(t, dir)
	pair, err := tls.LoadX509KeyPair(sc, sk)
	if err != nil {
		t.Fatal(err)
	}
	pool, _ := caPool("ca", ca)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{pair}, ClientCAs: pool,
		ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	st := &zbxStub{}
	go st.serve(t, ln)
	z := Zabbix{Server: ln.Addr().String(), Host: "pgvigil", TLSCA: ca, TLSCert: cc, TLSKey: ck}
	s := zabbixFor(t, z)
	if !strings.HasSuffix(s.destination(), "(sender, tls)") {
		t.Errorf("destination %q", s.destination())
	}
	if err := s.send(context.Background(), msg(crit)); err != nil {
		t.Fatalf("a TLS send: %v", err)
	}
	z.TLSServerIssuer, z.TLSServerSubject = "CN=proof CA,O=pgvigil test", "CN=zabbix-server"
	if err := zabbixFor(t, z).send(context.Background(), msg(crit)); err != nil {
		t.Errorf("the issuer and subject as Go writes them: %v", err)
	}
	z.TLSServerSubject = "CN=another"
	if err := zabbixFor(t, z).send(context.Background(), msg(crit)); err == nil || !strings.Contains(err.Error(), "tls_server_subject") {
		t.Errorf("a wrong subject: %v", err)
	}
	if n := len(st.requests()); n != 2 {
		t.Errorf("%d requests reached the server, want 2 (the refused subject sends nothing)", n)
	}
	// a plain server: the TLS sender never sends the data in clear
	pl, _ := net.Listen("tcp", "127.0.0.1:0")
	defer func() { _ = pl.Close() }()
	plainSeen := make(chan []byte, 1)
	go func() {
		c, err := pl.Accept()
		if err != nil {
			return
		}
		b := make([]byte, 64)
		n, _ := c.Read(b)
		plainSeen <- b[:n]
		_ = c.Close()
	}()
	z = Zabbix{Server: pl.Addr().String(), Host: "pgvigil", TLSCA: ca, TLSCert: cc, TLSKey: ck}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := zabbixFor(t, z).send(ctx, msg(crit)); err == nil {
		t.Error("a TLS send to a plain server succeeded")
	}
	if b := <-plainSeen; bytes.Contains(b, []byte("ZBXD")) {
		t.Error("the sender wrote the protocol in clear to a TLS channel's server")
	}
}

func TestZabbixAPI(t *testing.T) {
	const token = "0424bd59b807674191e7d77572075f33"
	var mu sync.Mutex
	var bodies []map[string]any
	answer := ""
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/zabbix/api_jsonrpc.php" || r.Header.Get("Authorization") != "Bearer "+token || r.Header.Get("Content-Type") != "application/json-rpc" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		raw, _ := io.ReadAll(r.Body)
		var b map[string]any
		_ = json.Unmarshal(raw, &b)
		mu.Lock()
		bodies = append(bodies, b)
		a := answer
		mu.Unlock()
		if a == "" {
			n := len(b["params"].([]any))
			data := make([]map[string]any, n)
			for i := range data {
				data[i] = map[string]any{"itemid": "42"}
			}
			out, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "result": map[string]any{"response": "success", "data": data}, "id": 1})
			a = string(out)
		}
		_, _ = w.Write([]byte(a))
	}))
	defer srv.Close()
	t.Setenv("PGV_TEST_ZBX_TOKEN", token)
	s := zabbixFor(t, Zabbix{Mode: "api", URL: srv.URL + "/zabbix/", Token: "env:PGV_TEST_ZBX_TOKEN", Host: "pgvigil"})
	if d := s.destination(); strings.Contains(d, token) || !strings.Contains(d, "(zabbix api)") {
		t.Errorf("destination %q", d)
	}
	warn := crit
	warn.Severity = "warning"
	if err := s.send(context.Background(), msg(crit, warn)); err != nil {
		t.Fatalf("history.push: %v", err)
	}
	mu.Lock()
	b0 := append([]map[string]any(nil), bodies...)
	mu.Unlock()
	if len(b0) != 1 || b0[0]["method"] != "history.push" || len(b0[0]["params"].([]any)) != 2 {
		t.Fatalf("bodies %v", b0)
	}
	p0 := b0[0]["params"].([]any)[0].(map[string]any)
	if p0["host"] != "pgvigil" || p0["key"] != "pgvigil.alert" || p0["value"] == "" {
		t.Errorf("param 0 %v", p0)
	}
	setAnswer := func(a string) { mu.Lock(); answer = a; mu.Unlock() }
	setAnswer(`{"jsonrpc":"2.0","result":{"response":"success","data":[{"itemid":"42"},{"error":"Item is disabled."}]},"id":1}`)
	if err := s.send(context.Background(), msg(crit, warn)); err == nil || !strings.Contains(err.Error(), "Item is disabled.") || !strings.Contains(err.Error(), "1 of 2") {
		t.Errorf("a refused value: %v", err)
	}
	setAnswer(`{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params.","data":"Not authorised: ` + token + `"},"id":1}`)
	err := s.send(context.Background(), msg(crit))
	if err == nil || !strings.Contains(err.Error(), "Invalid params.") || strings.Contains(err.Error(), token) {
		t.Errorf("a JSON-RPC error (the token scrubbed): %v", err)
	}
}

// B24k review 5: a name is written as Zabbix compares it (its 'Using certificates' page: RFC 4514, the lowest level
// first, the special characters escaped with a backslash), not as Go's pkix.Name writes it.
func TestZabbixName(t *testing.T) {
	cn, ou, o := asn1.ObjectIdentifier{2, 5, 4, 3}, asn1.ObjectIdentifier{2, 5, 4, 11}, asn1.ObjectIdentifier{2, 5, 4, 10}
	dc := asn1.ObjectIdentifier{0, 9, 2342, 19200300, 100, 1, 25}
	for _, c := range []struct {
		seq  pkix.RDNSequence
		want string
	}{
		{pkix.RDNSequence{ // the page's example, as the certificate holds it (top level first)
			{{Type: dc, Value: "com"}}, {{Type: dc, Value: "zabbix"}}, {{Type: o, Value: "Zabbix SIA"}},
			{{Type: ou, Value: "Development group"}}, {{Type: cn, Value: "Zabbix server"}}},
			"CN=Zabbix server,OU=Development group,O=Zabbix SIA,DC=zabbix,DC=com"},
		{pkix.RDNSequence{ // the page's escapes and a type with no name
			{{Type: o, Value: " Example SIA "}}, {{Type: ou, Value: `Development group "5"`}},
			{{Type: asn1.ObjectIdentifier{1, 2, 3, 4}, Value: "#x"}}, {{Type: cn, Value: "a,b+c;d<e>f\\g"}}},
			`CN=a\,b\+c\;d\<e\>f\\g,1.2.3.4=\#x,OU=Development group \"5\",O=\ Example SIA\ `},
		{pkix.RDNSequence{{{Type: asn1.ObjectIdentifier{1, 2, 3, 5}, Value: 7}}}, "1.2.3.5=#020107"}, // not a string: its DER
		{pkix.RDNSequence{{{Type: cn, Value: "Zabbix \u00dcnicode"}}}, "CN=Zabbix \u00dcnicode"},     // UTF-8 as it is
	} {
		der, err := asn1.Marshal(c.seq)
		if err != nil {
			t.Fatal(err)
		}
		if got, err := zbxName(der); err != nil || got != c.want {
			t.Errorf("zbxName: %q %v, want %q", got, err, c.want)
		}
	}
	if _, err := zbxName([]byte{0x30, 0x03, 0x01}); err == nil {
		t.Error("a broken name: no error")
	}
}

// B24k review 4: with a pinned subject the server's certificate is checked as Zabbix checks one - its chain to tls_ca
// and the pin, no host name - so a certificate with no Subject Alternative Name works; with no pin the name is checked.
func TestZabbixPinWithoutSAN(t *testing.T) {
	dir := t.TempDir()
	write := func(name, typ string, der []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: typ, Bytes: der}), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	ca := func(name string) (*x509.Certificate, *ecdsa.PrivateKey, string) {
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: name},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
			KeyUsage: x509.KeyUsageCertSign}
		der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
		if err != nil {
			t.Fatal(err)
		}
		c, _ := x509.ParseCertificate(der)
		return c, k, write(name+".pem", "CERTIFICATE", der)
	}
	leaf := func(caCert *x509.Certificate, caKey *ecdsa.PrivateKey, serial int64, cn string, usage x509.ExtKeyUsage) (string, string) {
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		tpl := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: cn}, // no SAN at all
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{usage},
			KeyUsage: x509.KeyUsageDigitalSignature}
		der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &k.PublicKey, caKey)
		if err != nil {
			t.Fatal(err)
		}
		kd, _ := x509.MarshalECPrivateKey(k)
		return write(cn+".crt", "CERTIFICATE", der), write(cn+".key", "EC PRIVATE KEY", kd)
	}
	caCert, caKey, caFile := ca("zabbix CA")
	otherCert, otherKey, _ := ca("another CA")
	cc, ck := leaf(caCert, caKey, 3, "pgvigil", x509.ExtKeyUsageClientAuth)
	pool, _ := caPool("ca", caFile)
	listen := func(crt, key string) net.Listener {
		pair, err := tls.LoadX509KeyPair(crt, key)
		if err != nil {
			t.Fatal(err)
		}
		ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{pair}, ClientCAs: pool,
			ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS12})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = ln.Close() })
		go (&zbxStub{}).serve(t, ln)
		return ln
	}
	sc, sk := leaf(caCert, caKey, 2, "zabbix-nosan", x509.ExtKeyUsageServerAuth)
	ln := listen(sc, sk)
	z := Zabbix{Server: ln.Addr().String(), Host: "pgvigil", TLSCA: caFile, TLSCert: cc, TLSKey: ck}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := zabbixFor(t, z).send(ctx, msg(crit)); err == nil {
		t.Error("no pin, a certificate without the server's name: sent (the name must be checked)")
	}
	z.TLSServerSubject = "CN=zabbix-nosan"
	if err := zabbixFor(t, z).send(ctx, msg(crit)); err != nil {
		t.Errorf("the subject pinned, a certificate without a SAN: %v", err)
	}
	z.TLSServerSubject, z.TLSServerIssuer = "", "CN=zabbix CA"
	if err := zabbixFor(t, z).send(ctx, msg(crit)); err != nil {
		t.Errorf("the issuer pinned, a certificate without a SAN: %v", err)
	}
	// the pin never stands in for the chain: the same subject from another CA is refused
	oc, okey := leaf(otherCert, otherKey, 4, "zabbix-other", x509.ExtKeyUsageServerAuth)
	ln2 := listen(oc, okey)
	z = Zabbix{Server: ln2.Addr().String(), Host: "pgvigil", TLSCA: caFile, TLSCert: cc, TLSKey: ck, TLSServerSubject: "CN=zabbix-other"}
	if err := zabbixFor(t, z).send(ctx, msg(crit)); err == nil || !strings.Contains(err.Error(), "does not chain to tls_ca") {
		t.Errorf("a pinned subject from another CA: %v", err)
	}
}

// B24k review 2: every value's (clock, ns) is new, across messages and channels of one pass (Zabbix keys an item's
// history by them).
func TestZabbixStamps(t *testing.T) {
	a := zabbixFor(t, Zabbix{Server: "127.0.0.1:10051", Host: "pgvigil"})
	b := zabbixFor(t, Zabbix{Server: "127.0.0.1:10052", Host: "pgvigil"})
	m := msg(crit, crit, crit)
	var all []zbxItem
	all = append(all, a.items(m)...)
	all = append(all, b.items(m)...)
	all = append(all, a.items(m)...)
	for i := 1; i < len(all); i++ {
		p, c := all[i-1], all[i]
		if c.Clock < p.Clock || (c.Clock == p.Clock && c.NS <= p.NS) {
			t.Fatalf("value %d (%d, %d) is not after value %d (%d, %d)", i, c.Clock, c.NS, i-1, p.Clock, p.NS)
		}
	}
	if all[0].Clock != m.SentAt.Unix() {
		t.Errorf("clock %d, want the message's %d", all[0].Clock, m.SentAt.Unix())
	}
}
