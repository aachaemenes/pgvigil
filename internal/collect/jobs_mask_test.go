package collect

import (
	"strings"
	"testing"
)

// TestMaskJobText: every password form a job step, a connection string or a run's output is known to carry is
// masked, and the text around it is kept.
func TestMaskJobText(t *testing.T) {
	cases := []struct{ in, secret, keep string }{
		{`ALTER LOGIN x WITH PASSWORD = 'top''secret'`, "secret", "ALTER LOGIN x WITH PASSWORD = '<masked>'"},
		{`CREATE CREDENTIAL c WITH IDENTITY = 'u', SECRET = N'topsecret'`, "topsecret", "SECRET = '<masked>'"},
		{`EXEC sp_addlinkedsrvlogin @rmtsrvname = 'S', @rmtuser = 'u', @rmtpassword = N'topsecret'`, "topsecret", "@rmtuser = 'u'"},
		{`EXEC sp_addlogin @loginame = 'u', @passwd = 'topsecret'`, "topsecret", "@loginame = 'u'"},
		{`sqlcmd -S srv -U u -P topsecret -Q "SELECT 1"`, "topsecret", `-Q "SELECT 1"`},
		{`bcp db.dbo.t out f.dat -S srv -U u -Ptopsecret -c`, "topsecret", "-c"},
		{`Invoke-Thing -Server s -Password 'topsecret' -Force`, "topsecret", "-Force"},
		{`$p = ConvertTo-SecureString 'topsecret' -AsPlainText -Force`, "topsecret", "-AsPlainText"},
		{`net use \\h\s topsecret /user:dom\u`, "topsecret", "/user:dom"},
		{`dtexec /F pkg.dtsx /DE topsecret /REP E`, "topsecret", "/REP E"},
		{`Server=s;Database=d;User Id=u;Password=topsecret;`, "topsecret", "Database=d"},
		{`Data Source=s;Pwd = "top secret";Encrypt=yes`, "secret", "Encrypt=yes"},
		{`host=db1 user=agg password = topsecret dbname=app`, "topsecret", "dbname=app"},
		{`host=db1 password='top secret' dbname=app`, "secret", "dbname=app"},
		{`postgresql://agg:topsecret@db1/app`, "topsecret", "postgresql://agg:<masked>@db1/app"},
		{`ERROR:  password authentication failed for user "agg"`, "", `password authentication failed for user "agg"`},
	}
	for _, c := range cases {
		got := MaskJobText(c.in)
		if c.secret != "" && strings.Contains(got, c.secret) {
			t.Errorf("%q: the secret is still there: %q", c.in, got)
		}
		if !strings.Contains(got, c.keep) {
			t.Errorf("%q: %q lost %q", c.in, got, c.keep)
		}
	}
}

// TestMaskTree masks the strings of a decoded definition and nothing else.
func TestMaskTree(t *testing.T) {
	d := map[string]any{"name": "j", "steps": map[string]any{"s #1": map[string]any{"connection": "host=h password=pw1", "n": int64(3)}}}
	maskTree(d)
	got := d["steps"].(map[string]any)["s #1"].(map[string]any)
	if got["connection"] != "host=h password=<masked>" || got["n"] != int64(3) || d["name"] != "j" {
		t.Errorf("maskTree: %v", d)
	}
}
