package config

import (
	"errors"
	"os"
	"strings"
)

// Kerberos is pgvigil.yaml's 'kerberos:' block (PGAUTH M3; the lead's 23:35 form (a)): the ONE Kerberos identity the
// process signs in to PostgreSQL servers with (pg_hba's gss method). pgx takes one GSS provider for the whole process
// (pgconn.RegisterGSSProvider: no per-connection argument), so an instance's dsn names only its role and krbsrvname /
// krbspn; a site that needs a second principal runs a second collector (the same binary).
type Kerberos struct {
	Keytab    string `yaml:"keytab"`    // a keytab file; needs Principal
	CCache    string `yaml:"ccache"`    // a credential cache file the host keeps fresh (kinit -k); it names its principal
	Principal string `yaml:"principal"` // user@REALM: the keytab's principal
	Krb5Conf  string `yaml:"krb5_conf"` // krb5.conf; default KRB5_CONFIG, else /etc/krb5.conf
}

// KerberosIdentity is the process's resolved identity: the block's, else the service's environment.
type KerberosIdentity struct {
	Keytab, CCache, Principal, Krb5Conf string
}

// validateKerberos trims the block and refuses a shape that cannot sign in, in words.
func (c *Config) validateKerberos() error {
	k := &c.Kerberos
	k.Keytab, k.CCache, k.Principal, k.Krb5Conf = strings.TrimSpace(k.Keytab), strings.TrimSpace(k.CCache), strings.TrimSpace(k.Principal), strings.TrimSpace(k.Krb5Conf)
	switch {
	case k.Keytab != "" && k.Principal == "":
		return errors.New("kerberos: a keytab needs its principal (principal: user@REALM)")
	case k.Principal != "" && !validPrincipal(k.Principal):
		return errors.New("kerberos: the principal " + k.Principal + " needs its realm (user@REALM)")
	case k.Principal != "" && k.Keytab == "" && k.CCache == "":
		return errors.New("kerberos: the principal " + k.Principal + " needs a keytab or a credential cache (keytab: or ccache:)")
	}
	return nil
}

// validPrincipal: a name and a realm, user@REALM
func validPrincipal(p string) bool {
	u, r, ok := strings.Cut(p, "@")
	return ok && u != "" && r != "" && !strings.ContainsAny(p, " \t")
}

// PGKerberos is the identity PostgreSQL's gss sign-ins use, and whether there is one: the block's keytab (with its
// principal) or credential cache, else KRB5CCNAME (its FILE: prefix dropped). KRB5_KTNAME alone is no identity here:
// a keytab needs the block's principal (SQL Server's Kerberos form reads KRB5_KTNAME with each instance's own login).
func (c *Config) PGKerberos() (KerberosIdentity, bool) {
	conf := c.Kerberos.Krb5Conf
	if conf == "" {
		conf = os.Getenv("KRB5_CONFIG")
	}
	if conf == "" {
		conf = "/etc/krb5.conf"
	}
	switch {
	case c.Kerberos.Keytab != "":
		return KerberosIdentity{Keytab: c.Kerberos.Keytab, Principal: c.Kerberos.Principal, Krb5Conf: conf}, true
	case c.Kerberos.CCache != "":
		return KerberosIdentity{CCache: c.Kerberos.CCache, Principal: c.Kerberos.Principal, Krb5Conf: conf}, true
	}
	if cc := strings.TrimPrefix(os.Getenv("KRB5CCNAME"), "FILE:"); cc != "" {
		return KerberosIdentity{CCache: cc, Krb5Conf: conf}, true
	}
	return KerberosIdentity{}, false
}
