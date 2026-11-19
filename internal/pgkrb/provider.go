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
// writes a new one). A sign-in that fails drops the client: the next one rebuilds it from the files (a keytab
// replaced after its key was rotated at the KDC).
type provider struct {
	id    config.KerberosIdentity
	mu    sync.Mutex
	cl    *client.Client
	ccMod time.Time // the credential cache file's modification time the client was read from
}

// cachedFor says whether the kept client was read from the cache file of this modification time
func (p *provider) cachedFor(mod time.Time) bool { return p.cl != nil && mod.Equal(p.ccMod) }

// drop forgets the client (a failed sign-in): the next sign-in builds a new one
func (p *provider) drop() {
	p.mu.Lock()
	p.cl = nil
	p.mu.Unlock()
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

// client is the signed-in client, made at the first call
func (p *provider) client() (*client.Client, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var mod time.Time
	if p.id.Keytab == "" {
		st, err := os.Stat(p.id.CCache)
		if err != nil {
			p.cl = nil
			return nil, fmt.Errorf("kerberos: the credential cache %s: %w", p.id.CCache, err)
		}
		if mod = st.ModTime(); !p.cachedFor(mod) {
			p.cl = nil
		}
	}
	if p.cl != nil {
		return p.cl, nil
	}
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
		cl = client.NewWithKeytab(user, realm, kt, cfg, client.DisablePAFXFAST(true))
	} else {
		cc, err := credentials.LoadCCache(p.id.CCache)
		if err != nil {
			return nil, fmt.Errorf("kerberos: the credential cache %s: %w", p.id.CCache, err)
		}
		if cl, err = client.NewFromCCache(cc, cfg, client.DisablePAFXFAST(true)); err != nil {
			return nil, fmt.Errorf("kerberos: the credential cache %s: %w", p.id.CCache, err)
		}
	}
	if err := cl.AffirmLogin(); err != nil {
		return nil, fmt.Errorf("kerberos: %s could not sign in at the KDC: %w", p.who(), err)
	}
	p.cl, p.ccMod = cl, mod
	return cl, nil
}

// spnFor is the service principal of a server: service/host
func spnFor(host, service string) string { return service + "/" + host }

// gss is one sign-in's exchange (pgconn.GSS)
type gss struct{ p *provider }

func (g *gss) GetInitToken(host, service string) ([]byte, error) {
	return g.GetInitTokenFromSPN(spnFor(host, service))
}

func (g *gss) GetInitTokenFromSPN(spn string) ([]byte, error) {
	cl, err := g.p.client()
	if err != nil {
		return nil, err
	}
	st, err := spnego.SPNEGOClient(cl, spn).InitSecContext()
	if err != nil {
		g.p.drop()
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
