package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// runCert writes a self-signed certificate and key for `pgvigil serve -tls-cert -tls-key`:
//
//	pgvigil cert [-hosts name1,name2,10.0.0.5] [-out dir] [-days 730]
//
// ECDSA P-256, the hosts as subject alternative names (default: this machine's name, localhost,
// 127.0.0.1). A browser warns about a self-signed certificate; a certificate from the organisation's
// CA goes in the same two flags.
func runCert(args []string) error {
	fs := flag.NewFlagSet("cert", flag.ContinueOnError)
	hosts := fs.String("hosts", "", "comma-separated DNS names and IP addresses the certificate is for (default: hostname, localhost, 127.0.0.1)")
	out := fs.String("out", ".", "directory for pgvigil.crt and pgvigil.key")
	days := fs.Int("days", 730, "validity in days")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *days < 1 || *days > 3650 {
		return errors.New("-days must be 1..3650")
	}
	var names []string
	if *hosts == "" {
		h, _ := os.Hostname()
		if h != "" {
			names = append(names, h)
		}
		names = append(names, "localhost", "127.0.0.1")
	} else {
		for _, h := range strings.Split(*hosts, ",") {
			if h = strings.TrimSpace(h); h != "" {
				names = append(names, h)
			}
		}
	}
	if len(names) == 0 {
		return errors.New("-hosts names nothing")
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: names[0], Organization: []string{"pgvigil"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Duration(*days) * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	for i, n := range names {
		dns, ip, err := certHost(n)
		if err != nil {
			return err
		}
		if ip != nil {
			tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
			names[i] = ip.String()
		} else {
			tmpl.DNSNames = append(tmpl.DNSNames, dns)
			names[i] = dns
		}
	}
	tmpl.Subject.CommonName = names[0]
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	crtPath := filepath.Join(*out, "pgvigil.crt")
	keyPath := filepath.Join(*out, "pgvigil.key")
	// both checked before either is written: a key written next to an old certificate is a mismatched pair
	for _, p := range []string{crtPath, keyPath} {
		if _, err := os.Stat(p); err == nil {
			return fmt.Errorf("%s exists; remove the pair first", p)
		}
	}
	if err := writeNew(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		return err
	}
	if err := writeNew(crtPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s and %s for %s, valid %d days\n", crtPath, keyPath, strings.Join(names, ", "), *days)
	fmt.Printf("serve with: pgvigil serve -config pgvigil.yaml -listen 0.0.0.0:8443 -tls-cert %s -tls-key %s\n", crtPath, keyPath)
	return nil
}

var hostnameRE = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9-]{0,62})?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,62})?)*$`)

// certHost reads one -hosts entry: an IP address (brackets allowed), or a host name. A port, a
// bracketed name or anything else a browser would never match is refused rather than written as a
// DNS entry the certificate can never satisfy.
func certHost(h string) (string, net.IP, error) {
	h = strings.TrimSpace(h)
	if strings.HasPrefix(h, "[") && strings.HasSuffix(h, "]") {
		h = h[1 : len(h)-1]
	}
	if ip := net.ParseIP(h); ip != nil {
		return "", ip, nil
	}
	if strings.Contains(h, ":") {
		return "", nil, fmt.Errorf("-hosts %q: a name takes no port, and an IPv6 address stands alone (no port)", h)
	}
	if len(h) > 253 || !hostnameRE.MatchString(h) {
		return "", nil, fmt.Errorf("-hosts %q: not a host name (letters, digits, hyphens and dots) or an IP address", h)
	}
	return strings.ToLower(h), nil, nil
}

// writeNew refuses to overwrite: a key in place is never replaced by accident.
func writeNew(path string, b []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("%s exists; remove it first", path)
		}
		return err
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}
