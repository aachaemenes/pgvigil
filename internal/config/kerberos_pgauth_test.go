package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestKerberosBlockPGAUTH (PGAUTH M3, the lead's 23:35 form (a)): ONE Kerberos identity per collector process -
// pgvigil.yaml's 'kerberos:' block (a keytab with its principal, or a credential cache; krb5_conf) or, without the
// block, the service's environment (KRB5CCNAME: the cache names its principal). pgx takes one GSS provider for the
// whole process, so an instance's dsn names only its role and krbsrvname / krbspn. A keytab needs its principal and a
// principal its realm, refused in words; KRB5_KTNAME alone (SQL Server's Kerberos form reads it with each instance's
// own login) configures no PostgreSQL identity.
func TestKerberosBlockPGAUTH(t *testing.T) {
	for _, k := range []string{"KRB5_KTNAME", "KRB5CCNAME", "KRB5_CONFIG"} {
		t.Setenv(k, "")
	}
	load := func(block string) (*Config, error) {
		t.Helper()
		p := filepath.Join(t.TempDir(), "pgvigil.yaml")
		if err := os.WriteFile(p, []byte("repository:\n  dsn: host=x dbname=pgvigil\ninstances: []\n"+block), 0o600); err != nil {
			t.Fatal(err)
		}
		return Load(p)
	}
	c, err := load("kerberos:\n  keytab: /etc/pgvigil/pgvigil.keytab\n  principal: pgvigil@PGV.TEST\n")
	if err != nil {
		t.Fatal(err)
	}
	if id, ok := c.PGKerberos(); !ok || id.Keytab != "/etc/pgvigil/pgvigil.keytab" || id.Principal != "pgvigil@PGV.TEST" || id.CCache != "" || id.Krb5Conf != "/etc/krb5.conf" {
		t.Errorf("a keytab and its principal: %+v %v; want the keytab, the principal and /etc/krb5.conf", id, ok)
	}
	for _, c := range []struct{ block, words string }{
		{"kerberos:\n  keytab: /etc/pgvigil/pgvigil.keytab\n", "a keytab needs its principal"},
		{"kerberos:\n  keytab: /etc/pgvigil/pgvigil.keytab\n  principal: pgvigil\n", "needs its realm"},
		{"kerberos:\n  principal: pgvigil@PGV.TEST\n", "a keytab or a credential cache"},
	} {
		if _, err := load(c.block); err == nil || !strings.Contains(err.Error(), c.words) {
			t.Errorf("%q: %v, want an error saying %q", c.block, err, c.words)
		}
	}
	c, err = load("kerberos:\n  ccache: /var/lib/pgvigil/krb5cc\n  krb5_conf: /etc/pgvigil/krb5.conf\n")
	if err != nil {
		t.Fatal(err)
	}
	if id, ok := c.PGKerberos(); !ok || id.CCache != "/var/lib/pgvigil/krb5cc" || id.Principal != "" || id.Krb5Conf != "/etc/pgvigil/krb5.conf" {
		t.Errorf("a credential cache: %+v %v", id, ok)
	}
	c, err = load("")
	if err != nil {
		t.Fatal(err)
	}
	if id, ok := c.PGKerberos(); ok {
		t.Errorf("nothing set: %+v, want no identity", id)
	}
	t.Setenv("KRB5CCNAME", "FILE:/tmp/krb5cc_1000")
	t.Setenv("KRB5_CONFIG", "/etc/krb5-pgv.conf")
	if id, ok := c.PGKerberos(); !ok || id.CCache != "/tmp/krb5cc_1000" || id.Krb5Conf != "/etc/krb5-pgv.conf" {
		t.Errorf("KRB5CCNAME and KRB5_CONFIG: %+v %v; want the cache without FILE: and the config", id, ok)
	}
	t.Setenv("KRB5CCNAME", "")
	t.Setenv("KRB5_KTNAME", "/etc/krb5.keytab")
	if id, ok := c.PGKerberos(); ok {
		t.Errorf("KRB5_KTNAME alone: %+v, want no PostgreSQL identity (a keytab needs the block's principal)", id)
	}
}
