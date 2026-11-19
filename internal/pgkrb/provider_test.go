package pgkrb

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jcmturner/gokrb5/v8/spnego"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestSPNPGAUTH (PGAUTH M3): pgx asks the provider for a token by the server's host and the service name
// (krbsrvname, 'postgres' by default) or by krbspn whole; the SPN is service/host.
func TestSPNPGAUTH(t *testing.T) {
	if got := spnFor("db1.pgv.test", "postgres"); got != "postgres/db1.pgv.test" {
		t.Errorf("spnFor = %q, want postgres/db1.pgv.test", got)
	}
}

// TestProviderWordsPGAUTH (PGAUTH M3): an identity that cannot sign in fails at the first gss sign-in in words naming
// what is wrong - the krb5.conf, the keytab, the credential cache - never a bare library error; the provider is made
// once for the process (pgx's one-provider rule) and each sign-in asks it.
func TestProviderWordsPGAUTH(t *testing.T) {
	dir := t.TempDir()
	conf := filepath.Join(dir, "krb5.conf")
	if err := os.WriteFile(conf, []byte("[libdefaults]\n  default_realm = PGV.TEST\n[realms]\n  PGV.TEST = {\n    kdc = 127.0.0.1:1\n  }\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	junk := filepath.Join(dir, "junk.keytab")
	if err := os.WriteFile(junk, []byte("not a keytab"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		id    config.KerberosIdentity
		words string
	}{
		{config.KerberosIdentity{Keytab: junk, Principal: "pgvigil@PGV.TEST", Krb5Conf: filepath.Join(dir, "missing.conf")}, "missing.conf"},
		{config.KerberosIdentity{Keytab: filepath.Join(dir, "missing.keytab"), Principal: "pgvigil@PGV.TEST", Krb5Conf: conf}, "the keytab " + filepath.Join(dir, "missing.keytab")},
		{config.KerberosIdentity{Keytab: junk, Principal: "pgvigil@PGV.TEST", Krb5Conf: conf}, "the keytab " + junk},
		{config.KerberosIdentity{CCache: filepath.Join(dir, "missing.cc"), Krb5Conf: conf}, "the credential cache " + filepath.Join(dir, "missing.cc")},
	} {
		g, err := Provider(c.id)()
		if err == nil {
			_, err = g.GetInitToken("db1.pgv.test", "postgres")
		}
		if err == nil || !strings.Contains(err.Error(), c.words) || !strings.HasPrefix(err.Error(), "kerberos: ") {
			t.Errorf("%+v: %v, want an error beginning 'kerberos: ' naming %q", c.id, err, c.words)
		}
	}
}

// TestContinuePGAUTH (PGAUTH M3): the server's answer to the first token is a SPNEGO NegTokenResp; accept-completed
// ends the exchange, a reject or a token that is not one fails in words.
func TestContinuePGAUTH(t *testing.T) {
	tok := func(state int) []byte {
		t.Helper()
		st := spnego.SPNEGOToken{Resp: true, NegTokenResp: spnego.NegTokenResp{NegState: 0}}
		if state != 0 {
			st.NegTokenResp.NegState = 2
		}
		b, err := st.Marshal()
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	g := &gss{}
	if done, out, err := g.Continue(tok(0)); err != nil || !done || out != nil {
		t.Errorf("accept-completed: done %v, out %v, err %v; want done, nothing to send", done, out, err)
	}
	if _, _, err := g.Continue(tok(2)); err == nil || !strings.Contains(err.Error(), "kerberos: ") {
		t.Errorf("a reject: %v, want an error in words", err)
	}
	if _, _, err := g.Continue([]byte("garbage")); err == nil || !strings.Contains(err.Error(), "kerberos: ") {
		t.Errorf("garbage: %v, want an error in words", err)
	}
}
