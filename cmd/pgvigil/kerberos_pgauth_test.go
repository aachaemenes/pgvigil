package main

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// fakeGSSServer answers every connection's startup message with AuthenticationGSS (R, code 7), as a server whose
// pg_hba line for the login is 'gss' does, and then waits; its port.
func fakeGSSServer(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer func() { _ = c.Close() }()
				var hdr [4]byte
				if _, err := io.ReadFull(c, hdr[:]); err != nil {
					return
				}
				if _, err := io.CopyN(io.Discard, c, int64(binary.BigEndian.Uint32(hdr[:]))-4); err != nil {
					return
				}
				_, _ = c.Write([]byte{'R', 0, 0, 0, 8, 0, 0, 0, 7})
				time.Sleep(3 * time.Second)
			}(c)
		}
	}()
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	return port
}

// TestKerberosRegisteredPGAUTH (PGAUTH M3 task 3): loading the configuration registers the process's one GSS provider
// (pgx's rule): with a 'kerberos:' block a gss server's sign-in goes to pgvigil's provider (here it fails in its words
// naming the keytab: none is there), and without one it fails in pgvigil's words naming the block - never pgx's own
// 'no GSSAPI provider registered', which points at a module pgvigil does not use.
func TestKerberosRegisteredPGAUTH(t *testing.T) {
	for _, k := range []string{"KRB5_KTNAME", "KRB5CCNAME", "KRB5_CONFIG"} {
		t.Setenv(k, "")
	}
	port := fakeGSSServer(t)
	dir := t.TempDir()
	conf := filepath.Join(dir, "krb5.conf")
	if err := os.WriteFile(conf, []byte("[libdefaults]\n  default_realm = PGV.TEST\n[realms]\n  PGV.TEST = {\n    kdc = 127.0.0.1:1\n  }\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	signIn := func(block string) string {
		t.Helper()
		p := filepath.Join(t.TempDir(), "pgvigil.yaml")
		if err := os.WriteFile(p, []byte("repository:\n  dsn: host=127.0.0.1 dbname=pgvigil\ninstances: []\n"+block), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadConfigAt(p, false); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		c, err := pgx.Connect(ctx, "host=127.0.0.1 port="+port+" user=pgvigil dbname=postgres sslmode=disable connect_timeout=5")
		if err == nil {
			_ = c.Close(ctx)
			t.Fatal("the fake gss server let the sign-in through")
		}
		return err.Error()
	}
	missing := filepath.Join(dir, "missing.keytab")
	if got := signIn("kerberos:\n  keytab: " + missing + "\n  principal: pgvigil@PGV.TEST\n  krb5_conf: " + conf + "\n"); !strings.Contains(got, "kerberos: the keytab "+missing) ||
		strings.Contains(got, "no GSSAPI provider registered") {
		t.Errorf("with the block: %s; want pgvigil's provider's words naming the keytab", got)
	}
	if got := signIn(""); !strings.Contains(got, "pgvigil has no Kerberos identity") || !strings.Contains(got, "kerberos:") ||
		strings.Contains(got, "no GSSAPI provider registered") {
		t.Errorf("without the block: %s; want pgvigil's words naming the 'kerberos:' block", got)
	}
}
