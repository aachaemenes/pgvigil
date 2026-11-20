// Package pgkrb is pgvigil's GSS provider for PostgreSQL's gss sign-in (pg_hba 'gss': Kerberos, Active Directory),
// PGAUTH M3 (the lead's 23:35 form (a)): ONE Kerberos identity for the whole process - pgx takes one provider
// (pgconn.RegisterGSSProvider, a function with no per-connection argument) and asks it for each sign-in by the server's
// host and the service name, or by the SPN whole (krbspn). The identity is pgvigil.yaml's 'kerberos:' block or the
// service's environment (config.PGKerberos): a keytab with its principal, or a credential cache the host keeps fresh.
// It is built on gokrb5 v8 (already linked for SQL Server's Kerberos form): the SPNEGO token PostgreSQL's GSSAPI
// accepts, and the server's NegTokenResp read back.
package pgkrb

import (
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jcmturner/gokrb5/v8/client"
	krbconfig "github.com/jcmturner/gokrb5/v8/config"
	"github.com/jcmturner/gokrb5/v8/credentials"
	"github.com/jcmturner/gokrb5/v8/keytab"
	"github.com/jcmturner/gokrb5/v8/spnego"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// provider is the process's one identity: its client is made and signed in at the first gss sign-in and kept. From a
// keytab gokrb5 renews the ticket-granting ticket and logs in again by itself; a credential cache cannot be renewed by
// the client, so its client is kept only while the cache file is the version it was read from (the host's kinit -k
// writes a new one): its modification time, its size and its file (a rewrite inside the time resolution). A sign-in
// that fails keeps a client whose own sign-in still holds and replaces only one that does not (failed - pgauth3 B2: one
// server's failure never throws away the tickets every other server still uses, and a replaced keytab client is
// destroyed, its renewal stopped); a rebuild that fails is answered for rebuildPause before the files are read again.
// Every sign-in's exchange runs under the mutex (S5: gokrb5's own TGT refresh is not deduplicated).
type provider struct {
	id      config.KerberosIdentity
	mu      sync.Mutex
	cl      *client.Client
	cc      ccVersion // the credential cache file's version the client was read from
	lastErr error     // the last rebuild's failure, answered until lastAt + rebuildPause
	lastAt  time.Time
	now     func() time.Time               // the clock (a test's)
	affirm  func(*client.Client) error     // the client's AffirmLogin (a test's)
	destroy func(*client.Client)           // the client's Destroy (a test's)
	sign    func() (*client.Client, error) // signIn (a test's)
}

// affirmed is cl's AffirmLogin (no network while its TGT is valid)
func (p *provider) affirmed(cl *client.Client) error {
	if p.affirm != nil {
		return p.affirm(cl)
	}
	return cl.AffirmLogin()
}

// destroyed is cl's Destroy: its sessions' renewal stopped
func (p *provider) destroyed(cl *client.Client) {
	if p.destroy != nil {
		p.destroy(cl)
		return
	}
	cl.Destroy()
}

// rebuildPause: how long a failed rebuild's error is answered before the files and the KDC are tried again (pgauth3 B2
// (c): never a fresh sign-in at the KDC per collection while a keytab's key is rotated there and not yet here)
var rebuildPause = 30 * time.Second

// ccVersion is a credential cache file's version: kinit -k writes a new file and renames it over the cache, so the
// file's own number tells a rewrite inside the file system's time resolution (0 where the system gives none)
type ccVersion struct {
	mod  time.Time
	size int64
	file uint64
}

// versionOf is the version of the cache file st describes
func versionOf(st os.FileInfo) ccVersion {
	return ccVersion{mod: st.ModTime(), size: st.Size(), file: fileNumber(st)}
}

// cachedFor says whether the kept client was read from the cache file of this version
func (p *provider) cachedFor(v ccVersion) bool {
	return p.cl != nil && v.mod.Equal(p.cc.mod) && v.size == p.cc.size && v.file == p.cc.file
}

// failed is a sign-in's failure with the client cl, under p.mu (pgauth3 B2): a client that is no longer the kept one is
// left alone (d); a kept client whose sign-in still holds - AffirmLogin needs no network while its TGT is valid, and a
// keytab client whose TGT ended signs in again in place (gokrb5 stops the old renewal itself) - is kept, with its
// tickets for every other server (b); otherwise it is destroyed (its renewal goroutine stopped: a) and forgotten.
func (p *provider) failed(cl *client.Client) {
	if cl == nil || p.cl != cl {
		return
	}
	if err := p.affirmed(cl); err == nil {
		return
	}
	p.destroyed(cl)
	p.cl = nil
}

// clock is the provider's time
func (p *provider) clock() time.Time {
	if p.now != nil {
		return p.now()
	}
	return time.Now()
}

// Provider is the function pgconn.RegisterGSSProvider takes, for id.
func Provider(id config.KerberosIdentity) pgconn.NewGSSFunc {
	p := &provider{id: id}
	return func() (pgconn.GSS, error) { return &gss{p: p}, nil }
}

// Register makes id the process's GSS provider (pgx's one).
func Register(id config.KerberosIdentity) { pgconn.RegisterGSSProvider(Provider(id)) }

// who names the identity in an error
func (p *provider) who() string {
	if p.id.Principal != "" {
		return p.id.Principal
	}
	return "the credential cache's principal"
}

// stillGood says whether the kept client's sign-in holds without a new read (pgauth3 S6): a credential cache read
// in the middle of the host's rewrite (no file, no TGT in it yet) keeps the client its last read made while that one's
// ticket is valid
func (p *provider) stillGood() bool { return p.cl != nil && p.affirmed(p.cl) == nil }

// client is the signed-in client, made at the first call; under p.mu
func (p *provider) client() (*client.Client, error) {
	var v ccVersion
	if p.id.Keytab == "" {
		st, err := os.Stat(p.id.CCache)
		if err != nil {
			if p.stillGood() {
				return p.cl, nil
			}
			p.cl = nil
			return nil, fmt.Errorf("kerberos: the credential cache %s: %w", p.id.CCache, err)
		}
		if v = versionOf(st); !p.cachedFor(v) {
			cl, err := p.build(v)
			switch {
			case err == nil:
				return cl, nil
			case p.stillGood():
				return p.cl, nil // a read during the rewrite: the next sign-in reads the cache again
			}
			p.cl = nil
			return nil, err
		}
	}
	if p.cl != nil {
		return p.cl, nil
	}
	return p.build(v)
}

// build makes and signs in a new client from the files; a failure is answered for rebuildPause (pgauth3 B2 c), and a
// client made but not signed in is destroyed (a keytab client's renewal never outlives it)
func (p *provider) build(v ccVersion) (*client.Client, error) {
	if p.lastErr != nil && p.clock().Before(p.lastAt.Add(rebuildPause)) {
		return nil, p.lastErr
	}
	signIn := p.signIn
	if p.sign != nil {
		signIn = p.sign
	}
	cl, err := signIn()
	if err != nil {
		p.lastErr, p.lastAt = err, p.clock()
		return nil, err
	}
	if p.cl != nil && p.cl != cl {
		p.destroyed(p.cl)
	}
	p.lastErr = nil
	p.cl, p.cc = cl, v
	return cl, nil
}

// signIn reads the files and signs a new client in at the KDC (a credential cache needs no KDC while its TGT holds)
func (p *provider) signIn() (*client.Client, error) {
	cfg, err := krbconfig.Load(p.id.Krb5Conf)
	if err != nil {
		return nil, fmt.Errorf("kerberos: the configuration %s: %w", p.id.Krb5Conf, err)
	}
	var cl *client.Client
	if p.id.Keytab != "" {
		kt, err := keytab.Load(p.id.Keytab)
		if err != nil {
			return nil, fmt.Errorf("kerberos: the keytab %s: %w", p.id.Keytab, err)
		}
		user, realm, _ := strings.Cut(p.id.Principal, "@")
		cl = client.NewWithKeytab(user, realm, kt, cfg, client.DisablePAFXFAST(true), client.Logger(krbLog))
	} else {
		cc, err := credentials.LoadCCache(p.id.CCache)
		if err != nil {
			return nil, fmt.Errorf("kerberos: the credential cache %s: %w", p.id.CCache, err)
		}
		if cl, err = client.NewFromCCache(cc, cfg, client.DisablePAFXFAST(true), client.Logger(krbLog)); err != nil {
			return nil, fmt.Errorf("kerberos: the credential cache %s: %w", p.id.CCache, err)
		}
	}
	if err := cl.AffirmLogin(); err != nil {
		cl.Destroy()
		if p.id.Keytab == "" {
			// pgauth3 N3: a cache's ticket that ended is the host's kinit stopping, not the KDC refusing
			return nil, fmt.Errorf("kerberos: the credential cache %s holds no valid ticket for %s (has the host's kinit stopped?): %w", p.id.CCache, p.who(), err)
		}
		return nil, fmt.Errorf("kerberos: %s could not sign in at the KDC: %w", p.who(), err)
	}
	return cl, nil
}

// krbLog is gokrb5's own log (pgauth3 N5): a renewal that fails in the background says so on the collector's error
// stream before any sign-in fails; it names principals and errors, never a key
var krbLog = log.New(os.Stderr, "pgvigil kerberos: ", log.LstdFlags)

// spnFor is the service principal of a server: service/host, the host lower-cased as libpq through MIT asks for it
// (pgauth3 S2: DB1.example.com works in psql against postgres/db1.example.com); an alias is not followed - the
// registered name is the one to give (docs/postgres-signin.md)
func spnFor(host, service string) string { return service + "/" + strings.ToLower(host) }

// gss is one sign-in's exchange (pgconn.GSS)
type gss struct{ p *provider }

func (g *gss) GetInitToken(host, service string) ([]byte, error) {
	return g.GetInitTokenFromSPN(spnFor(host, service))
}

func (g *gss) GetInitTokenFromSPN(spn string) ([]byte, error) {
	g.p.mu.Lock()
	defer g.p.mu.Unlock() // pgauth3 S5: the exchange too, never two TGT refreshes at once
	cl, err := g.p.client()
	if err != nil {
		return nil, err
	}
	st, err := spnego.SPNEGOClient(cl, spn).InitSecContext()
	if err != nil {
		g.p.failed(cl)
		return nil, fmt.Errorf("kerberos: no service ticket for %s as %s: %w", spn, g.p.who(), err)
	}
	b, err := st.Marshal()
	if err != nil {
		return nil, fmt.Errorf("kerberos: the token for %s: %w", spn, err)
	}
	return b, nil
}

// Continue reads the server's answer: a NegTokenResp, accept-completed ends the exchange
func (g *gss) Continue(inToken []byte) (bool, []byte, error) {
	var t spnego.SPNEGOToken
	if err := t.Unmarshal(inToken); err != nil {
		return false, nil, fmt.Errorf("kerberos: the server's answer is not a SPNEGO token: %w", err)
	}
	if !t.Resp {
		return false, nil, errors.New("kerberos: the server's answer is not a SPNEGO response")
	}
	if st := t.NegTokenResp.State(); st != spnego.NegStateAcceptCompleted {
		return false, nil, fmt.Errorf("kerberos: the server did not accept the sign-in (SPNEGO state %d)", st)
	}
	return true, nil, nil
}

// errNoIdentity is a gss sign-in's answer when the process has no Kerberos identity
var errNoIdentity = errors.New("kerberos: the server signs this login in by gss (Kerberos), and pgvigil has no Kerberos identity: set pgvigil.yaml's kerberos: block (a keytab with its principal, or a credential cache) or KRB5CCNAME in the service's environment (docs/postgres-signin.md)")

// RegisterFor makes the process's GSS provider (pgx's one) the identity cfg names, or, with none, one that answers a gss
// server in pgvigil's words (pgx's own words name a module pgvigil does not use).
func RegisterFor(cfg *config.Config) {
	if id, ok := cfg.PGKerberos(); ok {
		Register(id)
		return
	}
	pgconn.RegisterGSSProvider(func() (pgconn.GSS, error) { return nil, errNoIdentity })
}
