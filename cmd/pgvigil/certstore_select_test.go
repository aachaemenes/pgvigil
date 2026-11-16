package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"strings"
	"testing"
	"time"
)

// task B24n: the store selection's rules and refusals (PerformanceMonitor's DarlingTlsStore.Select), on self-signed
// certificates, with no store.

var selNow = time.Date(2026, 11, 15, 8, 0, 0, 0, time.UTC)

func selCert(t *testing.T, serial int64, cn string, dns []string, from, to time.Time, serverAuth, key bool) storeCert {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: cn}, DNSNames: dns,
		NotBefore: from, NotAfter: to, KeyUsage: x509.KeyUsageDigitalSignature}
	if serverAuth {
		tpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	} else {
		tpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	return newStoreCert(der, key, serial)
}

func TestNormalizeThumbprint(t *testing.T) {
	if got := normalizeThumbprint("\u200e3a 7f\u00a0c1\tb2\u200f"); got != "3A7FC1B2" {
		t.Fatalf("normalizeThumbprint %q", got)
	}
	// B24n review 8: every Unicode space goes, as PerformanceMonitor's char.IsWhiteSpace (em, narrow no-break and
	// ideographic spaces, vertical tab, form feed, no-break space)
	if got := normalizeThumbprint("3a\u20037f\u202fc1\u3000b2\v0d\f9e\u00a01f"); got != "3A7FC1B20D9E1F" {
		t.Fatalf("normalizeThumbprint with Unicode spaces %q", got)
	}
}

func TestParseStoreName(t *testing.T) {
	for in, want := range map[string]string{"": `LocalMachine\My`, `localmachine\My`: `LocalMachine\My`, `CurrentUser\WebHosting`: `CurrentUser\WebHosting`} {
		l, n, err := parseStoreName(in)
		if err != nil || l+`\`+n != want {
			t.Errorf("%q: %s\\%s %v, want %s", in, l, n, err, want)
		}
	}
	for _, bad := range []string{"My", `Elsewhere\My`, `LocalMachine\\server\My`, `LocalMachine\a/b`, `LocalMachine\`} {
		if _, _, err := parseStoreName(bad); err == nil {
			t.Errorf("%q: taken", bad)
		}
	}
}

func TestDNSNameMatchesSAN(t *testing.T) {
	cases := []struct {
		san, host string
		want      bool
	}{
		{"pgvigil.corp.local", "PGVIGIL.corp.local.", true},
		{"*.corp.local", "pgvigil.corp.local", true},
		{"*.corp.local", "corp.local", false},
		{"*.corp.local", "a.pgvigil.corp.local", false},
		{"p*.corp.local", "pgvigil.corp.local", false},
		{"pgvigil.*.local", "pgvigil.corp.local", false},
		{"*", "pgvigil", false},
		{"*.", "x.", false},
		{"", "x", false},
	}
	for _, c := range cases {
		if got := dnsNameMatchesSAN(c.san, c.host); got != c.want {
			t.Errorf("%q vs %q: %v, want %v", c.san, c.host, got, c.want)
		}
	}
}

func TestSelectByThumbprint(t *testing.T) {
	day := 24 * time.Hour
	a := selCert(t, 1, "a", []string{"a.corp.local"}, selNow.Add(-day), selNow.Add(day), true, true)
	nokey := selCert(t, 2, "b", []string{"b.corp.local"}, selNow.Add(-day), selNow.Add(day), true, false)
	old := selCert(t, 3, "c", []string{"c.corp.local"}, selNow.Add(-3*day), selNow.Add(-day), true, true)
	cands := []storeCert{a, nokey, old}
	got, err := selectByThumbprint(cands, " "+strings.ToLower(a.thumbprint[:4])+" "+a.thumbprint[4:], `LocalMachine\My`, "-tls-thumbprint")
	if err != nil || got.ref != a.ref {
		t.Fatalf("by thumbprint: %v %v", got.ref, err)
	}
	for name, c := range map[string]struct {
		cands []storeCert
		tp    string
		says  string
	}{
		"none":     {cands, "00", "matches no certificate in the LocalMachine\\My store"},
		"two":      {append(cands, a), a.thumbprint, "matches 2 certificates"},
		"no key":   {cands, nokey.thumbprint, "no private key"},
		"unparsed": {[]storeCert{{thumbprint: "AB", hasKey: true}}, "ab", "does not parse"},
	} {
		if _, err := selectByThumbprint(c.cands, c.tp, `LocalMachine\My`, "-tls-thumbprint"); err == nil || !strings.Contains(err.Error(), c.says) {
			t.Errorf("%s: %v, want it to say %q", name, err, c.says)
		}
	}
	// a pin is chosen whatever its dates; its lifetime is refused after, with them
	pin, err := selectByThumbprint(cands, old.thumbprint, `LocalMachine\My`, "-tls-thumbprint")
	if err != nil {
		t.Fatal(err)
	}
	if err := lifetimeError(pin, selNow, "the certificate"); err == nil || !strings.Contains(err.Error(), "expired at 2026-11-14T08:00:00Z") {
		t.Errorf("an expired pin: %v", err)
	}
	early := selCert(t, 4, "d", nil, selNow.Add(day), selNow.Add(2*day), true, true)
	if err := lifetimeError(early, selNow, "the certificate"); err == nil || !strings.Contains(err.Error(), "not valid until") {
		t.Errorf("a pin not yet valid: %v", err)
	}
	if err := lifetimeError(a, selNow, "the certificate"); err != nil {
		t.Errorf("a valid pin: %v", err)
	}
}

func TestSelectBySubject(t *testing.T) {
	day := 24 * time.Hour
	name := "pgvigil.corp.local"
	older := selCert(t, 1, "older", []string{name}, selNow.Add(-10*day), selNow.Add(100*day), true, true)
	newer := selCert(t, 2, "newer", []string{"*.corp.local"}, selNow.Add(-2*day), selNow.Add(50*day), true, true)
	sameStartLonger := selCert(t, 3, "same-start", []string{name}, selNow.Add(-2*day), selNow.Add(90*day), true, true)
	cnOnly := selCert(t, 4, name, nil, selNow.Add(-day), selNow.Add(day), true, true) // the name in the CN only: never matched
	expired := selCert(t, 5, "expired", []string{name}, selNow.Add(-20*day), selNow.Add(-day), true, true)
	future := selCert(t, 6, "future", []string{name}, selNow.Add(day), selNow.Add(9*day), true, true)
	client := selCert(t, 7, "client", []string{name}, selNow.Add(-day), selNow.Add(day), false, true)
	keyless := selCert(t, 8, "keyless", []string{name}, selNow.Add(-day), selNow.Add(day), true, false)
	broken := storeCert{thumbprint: "FF", hasKey: true}
	got, err := selectBySubject([]storeCert{older, newer, sameStartLonger, cnOnly, expired, future, client, keyless, broken}, name, selNow, `LocalMachine\My`, "-tls-subject")
	if err != nil {
		t.Fatal(err)
	}
	var order []any
	for _, c := range got {
		order = append(order, c.ref)
	}
	// newest NotBefore first; the two of one NotBefore by the later NotAfter (3 before 2); then the older one
	if len(order) != 3 || order[0] != int64(3) || order[1] != int64(2) || order[2] != int64(1) {
		t.Fatalf("order %v, want [3 2 1]", order)
	}
	_, err = selectBySubject([]storeCert{expired, future, client, keyless, broken}, name, selNow, `LocalMachine\My`, "-tls-subject")
	if err == nil || !strings.Contains(err.Error(), "matches 4 certificate(s)") ||
		!strings.Contains(err.Error(), "(expired: 1, not yet valid: 1, no Server Authentication usage: 1, no private key: 1)") ||
		!strings.Contains(err.Error(), "1 certificate(s) in the LocalMachine\\My store could not be read") {
		t.Errorf("none servable: %v", err)
	}
	if _, err := selectBySubject([]storeCert{cnOnly}, name, selNow, `LocalMachine\My`, "-tls-subject"); err == nil || !strings.Contains(err.Error(), "dNSName") {
		t.Errorf("a name in the common name only: %v", err)
	}
}

func TestGrantRules(t *testing.T) {
	for _, s := range []string{"S-1-1-0", "S-1-5-32-545", "S-1-5-11", "S-1-5-80-0", "S-1-2-0", "S-1-15-2-1", "S-1-5-21-1-2-3-513", "S-1-5-21-1-2-3-515"} {
		if !isBroadPrincipal(s) {
			t.Errorf("%s: not broad", s)
		}
	}
	for _, s := range []string{"S-1-5-21-1-2-3-1001", "S-1-5-18", "S-1-5-80-1-2-3-4-5"} {
		if isBroadPrincipal(s) {
			t.Errorf("%s: broad", s)
		}
	}
	for _, c := range []struct {
		sid  string
		use  uint32
		want string
	}{
		{"S-1-5-21-1-2-3-1001", sidUser, ""},
		{"S-1-5-80-1-2-3-4-5", sidWellKnownGroup, ""}, // NT SERVICE\name
		{"S-1-5-20", sidWellKnownGroup, ""},
		{"S-1-5-21-1-2-3-1105", sidGroup, "is a group"},
		{"S-1-5-32-551", sidAlias, "is a group"},
		{"S-1-5-21-1-2-3-1106", sidComputer, "is a computer"},
		{"S-1-5-21-1-2-3-1107", 6, "is not a user or service account (kind 6)"},
	} {
		if got := refuseByKind(c.sid, c.use); got != c.want {
			t.Errorf("%s kind %d: %q, want %q", c.sid, c.use, got, c.want)
		}
	}
	u := "S-1-5-21-1-2-3-1001"
	for name, c := range map[string]struct {
		aces []aceView
		null bool
		want string
	}{
		"no entry":           {[]aceView{{allow: true, sid: "S-1-5-18", mask: genericAll}}, false, "add"},
		"read already":       {[]aceView{{allow: true, sid: u, mask: keyReadMask}}, false, "already"},
		"generic read":       {[]aceView{{allow: true, sid: u, mask: genericRead}}, false, "already"},
		"generic all":        {[]aceView{{allow: true, sid: u, mask: genericAll}}, false, "already"},
		"a partial read":     {[]aceView{{allow: true, sid: u, mask: 0x1}}, false, "add"},
		"a deny of read":     {[]aceView{{deny: true, sid: u, mask: 0x1}, {allow: true, sid: u, mask: keyReadMask}}, false, "deny"},
		"an inherit-only":    {[]aceView{{allow: true, sid: u, mask: keyReadMask, inheritOnly: true}}, false, "add"},
		"a NULL access list": {nil, true, "already"},
	} {
		if got := planGrant(c.aces, c.null, u); got != c.want {
			t.Errorf("%s: %q, want %q", name, got, c.want)
		}
	}
}
