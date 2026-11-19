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
	"strings"
	"sync"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jcmturner/gokrb5/v8/client"
	krbconfig "github.com/jcmturner/gokrb5/v8/config"
	"github.com/jcmturner/gokrb5/v8/credentials"
	"github.com/jcmturner/gokrb5/v8/keytab"
	"github.com/jcmturner/gokrb5/v8/spnego"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// provider is the process's one identity: its client is made and signed in at the first gss sign-in and kept (its
// ticket-granting ticket and service tickets are reused and renewed by gokrb5); a failure is kept for no one - the next
// sign-in tries again.
type provider struct {
	id config.KerberosIdentity
	mu sync.Mutex
	cl *client.Client
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
	p.cl = cl
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
