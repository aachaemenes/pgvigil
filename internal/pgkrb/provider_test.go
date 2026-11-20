package pgkrb

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/jcmturner/gokrb5/v8/client"
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

// TestProviderReloadPGAUTH (PGAUTH M3; found writing the review brief): a long-running collector outlives a ticket. A
// credential cache cannot be renewed by the client (gokrb5's NewFromCCache has no renewal and no way to log in again),
// so the client read from it is reused only while the file is the version it was read from - the host's kinit -k
// writes a new one - and a client whose sign-in failed and no longer holds is replaced, so the next sign-in rebuilds
// it from the files (a keytab replaced after its key was rotated at the KDC; pgauth3 B2's failed).
func TestProviderReloadPGAUTH(t *testing.T) {
	t1 := time.Date(2026, 11, 19, 7, 0, 0, 0, time.UTC)
	v1 := ccVersion{mod: t1, size: 1024, file: 7}
	p := &provider{id: config.KerberosIdentity{CCache: "/var/lib/pgvigil/krb5cc"}, cl: new(client.Client), cc: v1}
	if !p.cachedFor(v1) {
		t.Error("the same cache file version: the client is not reused")
	}
	if p.cachedFor(ccVersion{mod: t1.Add(time.Second), size: 1024, file: 7}) {
		t.Error("a newer cache file: the old client is reused")
	}
	p.affirm = func(*client.Client) error { return errors.New("the TGT has ended") }
	p.destroy = func(*client.Client) {}
	p.failed(p.cl)
	if p.cl != nil || p.cachedFor(v1) {
		t.Error("a failed client whose sign-in no longer holds was kept")
	}
}

// TestFailedKeepsAGoodClientPGAUTH3 (pgauth3 B2): one server's failed sign-in (no principal for its name, a KDC down
// for an uncached name) keeps the client while its own sign-in holds - its TGT and its tickets for every other server
// stay; a client that no longer holds is destroyed (its renewal stopped: no leak) and forgotten; a failure of a client
// that is no longer the kept one touches nothing.
func TestFailedKeepsAGoodClientPGAUTH3(t *testing.T) {
	a, b := new(client.Client), new(client.Client)
	var destroyed []*client.Client
	good := true
	p := &provider{cl: a,
		affirm: func(*client.Client) error {
			if good {
				return nil
			}
			return errors.New("the TGT has ended and the KDC does not answer")
		},
		destroy: func(cl *client.Client) { destroyed = append(destroyed, cl) }}
	p.failed(a)
	if p.cl != a || len(destroyed) != 0 {
		t.Errorf("a client whose sign-in holds: kept %v, destroyed %d; want kept, none destroyed", p.cl == a, len(destroyed))
	}
	p.cl = b
	good = false
	p.failed(a)
	if p.cl != b || len(destroyed) != 0 {
		t.Errorf("a failure of a client no longer kept: the kept one replaced %v, destroyed %d; want untouched", p.cl != b, len(destroyed))
	}
	p.failed(b)
	if p.cl != nil || len(destroyed) != 1 || destroyed[0] != b {
		t.Errorf("a kept client that no longer holds: kept %v, destroyed %v; want forgotten and destroyed", p.cl != nil, destroyed)
	}
}

// TestRebuildPausePGAUTH3 (pgauth3 B2 c): a rebuild that fails is answered for rebuildPause - never a fresh sign-in at
// the KDC per collection (a keytab whose key was rotated at the KDC and not yet here) - and tried again after it.
func TestRebuildPausePGAUTH3(t *testing.T) {
	now := time.Date(2026, 11, 20, 8, 0, 0, 0, time.UTC)
	calls := 0
	p := &provider{id: config.KerberosIdentity{Keytab: "/etc/pgvigil/pgvigil.keytab", Principal: "pgvigil@PGV.TEST"},
		now:  func() time.Time { return now },
		sign: func() (*client.Client, error) { calls++; return nil, errors.New("KDC_ERR_PREAUTH_FAILED") }}
	if _, err := p.client(); err == nil || calls != 1 {
		t.Fatalf("the first rebuild: %v, %d call(s)", err, calls)
	}
	now = now.Add(rebuildPause / 2)
	if _, err := p.client(); err == nil || calls != 1 {
		t.Errorf("inside the pause: %v, %d call(s); want the last error and no new sign-in", err, calls)
	}
	now = now.Add(rebuildPause)
	if _, err := p.client(); err == nil || calls != 2 {
		t.Errorf("after the pause: %v, %d call(s); want a new sign-in", err, calls)
	}
}

// TestCacheReadDuringRewriteKeepsTheClientPGAUTH3 (pgauth3 S6): a credential cache gone for the moment of the host's
// rewrite keeps the client its last read made while that one's ticket is valid.
func TestCacheReadDuringRewriteKeepsTheClientPGAUTH3(t *testing.T) {
	a := new(client.Client)
	p := &provider{id: config.KerberosIdentity{CCache: filepath.Join(t.TempDir(), "gone")}, cl: a,
		affirm: func(*client.Client) error { return nil }}
	if cl, err := p.client(); err != nil || cl != a {
		t.Errorf("the cache file missing for a moment, the kept ticket valid: %v %v; want the kept client", cl == a, err)
	}
}

// TestSPNLowercasesTheHostPGAUTH3 (pgauth3 S2): the service principal's host is lower-cased as libpq through MIT asks
// for it.
func TestSPNLowercasesTheHostPGAUTH3(t *testing.T) {
	if got := spnFor("DB1.Example.com", "postgres"); got != "postgres/db1.example.com" {
		t.Errorf("spnFor = %q", got)
	}
}

// TestCacheVersionPGAUTH (the lead's 00:35): a credential cache's version is its modification time, its size and its
// file. kinit -k writes a new file and renames it over the cache, so a rewrite inside the file system's time
// resolution with the same size is still a new version: the client read from the old file is not reused.
func TestCacheVersionPGAUTH(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "krb5cc")
	if err := os.WriteFile(f, []byte("ticket-1"), 0o600); err != nil {
		t.Fatal(err)
	}
	st1, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	p := &provider{id: config.KerberosIdentity{CCache: f}, cl: new(client.Client), cc: versionOf(st1)}
	if !p.cachedFor(versionOf(st1)) {
		t.Error("the same cache file: the client is not reused")
	}
	if runtime.GOOS == "windows" {
		t.Skip("no inode in a Windows file's FileInfo: the version there is its time and size")
	}
	nf := filepath.Join(dir, "krb5cc.new")
	if err := os.WriteFile(nf, []byte("ticket-2"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(nf, st1.ModTime(), st1.ModTime()); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(nf, f); err != nil {
		t.Fatal(err)
	}
	st2, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	if !st2.ModTime().Equal(st1.ModTime()) || st2.Size() != st1.Size() {
		t.Fatalf("the rig: the new file's time %v and size %d, want %v and %d", st2.ModTime(), st2.Size(), st1.ModTime(), st1.Size())
	}
	if p.cachedFor(versionOf(st2)) {
		t.Error("a new cache file renamed over the old one, of the same time and size (a kinit inside one second): the old client is reused")
	}
}

// TestCacheRewrittenInPlacePGAUTH (pgauth3 N6: out of the Windows skip - it needs no inode): the same file rewritten in
// place to another size, its time unchanged, is a new version.
func TestCacheRewrittenInPlacePGAUTH(t *testing.T) {
	f := filepath.Join(t.TempDir(), "krb5cc")
	if err := os.WriteFile(f, []byte("ticket-2"), 0o600); err != nil {
		t.Fatal(err)
	}
	st2, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	p := &provider{id: config.KerberosIdentity{CCache: f}, cl: new(client.Client), cc: versionOf(st2)}
	if err := os.WriteFile(f, []byte("ticket-3-longer"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(f, st2.ModTime(), st2.ModTime()); err != nil {
		t.Fatal(err)
	}
	st3, err := os.Stat(f)
	if err != nil {
		t.Fatal(err)
	}
	if p.cachedFor(versionOf(st3)) {
		t.Error("the same file rewritten in place to another size, its time unchanged: the old client is reused")
	}
}
