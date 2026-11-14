package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPageDoorRefusal(t *testing.T) {
	cases := []struct {
		engine, auth, options string
		want                  string // "" = opens; else a piece of the words
	}{
		// SQL Server: a typed login or a typed service principal, the listed options
		{EngineSQLServer, "sql", "", ""},
		{EngineSQLServer, "entra", "", ""},
		{EngineSQLServer, "sql", "encrypt=true&TrustServerCertificate=true&HostNameInCertificate=db.example&tlsmin=1.2", ""},
		{EngineSQLServer, "sql", "connection timeout=30&dial timeout=5&keepalive=30&ApplicationIntent=ReadOnly&MultiSubnetFailover=true&packet size=4096&database=Sales", ""},
		{EngineSQLServer, "sql", "server=other&host=other", ""}, // BuildDSN leaves them out
		// serve's own identity
		{EngineSQLServer, "windows", "", "this server's own identity (windows)"},
		{EngineSQLServer, "entra-identity", "", "this server's own identity (entra-identity)"},
		{EngineSQLServer, "sql", "krb5-keytabfile=/etc/krb5.keytab", "this server's own identity (krb5-keytabfile)"},
		{EngineSQLServer, "sql", "krb5-credcachefile=/tmp/krb5cc", "this server's own identity (krb5-credcachefile)"},
		{EngineSQLServer, "sql", "certificate=/etc/ssl/ca.pem", "this server's own identity (certificate)"},
		{EngineSQLServer, "sql", "ServerSPN=MSSQLSvc/x", "this server's own identity (serverspn)"},
		// outside the list
		{EngineSQLServer, "sql", "log=255", "driver option log is not one"},
		{EngineSQLServer, "sql", "failoverpartner=other", "driver option failoverpartner is not one"},
		{EngineSQLServer, "sql", "protocol=np", "driver option protocol is not one"},
		{EngineSQLServer, "sql", "app name=x", "driver option app name is not one"},
		{EngineSQLServer, "sql", "columnencryption=true", "driver option columnencryption is not one"},
		{EngineSQLServer, "kerberos", "", "authentication kerberos is not one"},
		// PostgreSQL: a typed password, the listed options
		{EnginePostgres, "password", "", ""},
		{EnginePostgres, "password", "sslmode=verify-full sslrootcert=system sslsni=1 sslnegotiation=direct channel_binding=require connect_timeout=10 target_session_attrs=read-only", ""},
		{EnginePostgres, "password", "host=other port=1 dbname=x hostaddr=1.2.3.4", ""}, // BuildDSN leaves them out
		{EnginePostgres, "pgpass", "", "this server's own identity (pgpass)"},
		{EnginePostgres, "password", "passfile=/root/.pgpass", "this server's own identity (passfile)"},
		{EnginePostgres, "password", "servicefile=/etc/pg_service.conf", "this server's own identity (servicefile)"},
		{EnginePostgres, "password", "service=prod", "this server's own identity (service)"},
		{EnginePostgres, "password", "sslkey=/k sslcert=/c", "this server's own identity (sslkey)"},
		{EnginePostgres, "password", "sslrootcert=/etc/ssl/ca.pem", "this server's own identity (sslrootcert)"},
		{EnginePostgres, "password", "krbsrvname=postgres", "this server's own identity (krbsrvname)"},
		{EnginePostgres, "password", "gssencmode=require", "this server's own identity (gssencmode)"},
		{EnginePostgres, "password", "options=-crole=admin", "driver option options is not one"},
		{EnginePostgres, "password", "search_path=x", "driver option search_path is not one"},
		{EnginePostgres, "password", "application_name=x", "driver option application_name is not one"},
		{EnginePostgres, "md5", "", "authentication md5 is not one"},
		{"mongodb", "password", "", "has no page door"},
	}
	for _, c := range cases {
		got := PageDoorRefusal("i1", c.engine, c.auth, c.options)
		if c.want == "" && got != "" || c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("PageDoorRefusal(%s, %s, %q) = %q, want %q", c.engine, c.auth, c.options, got, c.want)
		}
		if got != "" && !strings.Contains(got, "instance i1") {
			t.Errorf("%q does not name the instance", got)
		}
	}
}

func TestPageDSNRefusal(t *testing.T) {
	cases := []struct {
		engine, dsn string
		want        string
	}{
		// what BuildDSN writes for the allowed rows
		{EngineSQLServer, "sqlserver://reader:pw@db.example:1433?database=Sales&encrypt=true", ""},
		{EngineSQLServer, "sqlserver://app-id:secret@db.example?database=master&encrypt=true&fedauth=ActiveDirectoryServicePrincipal", ""},
		{EngineSQLServer, "sqlserver://reader:pw@db.example/INST?encrypt=strict&trustservercertificate=false&tlsmin=1.2", ""},
		{EngineSQLServer, "server=db.example;user id=reader;password=pw;database=Sales;encrypt=true", ""}, // an ADO string by hand
		// a credential file edited by hand: the string decides
		{EngineSQLServer, "sqlserver://db.example?encrypt=true", "no login and password"},
		{EngineSQLServer, "sqlserver://db.example?encrypt=true&authenticator=krb5", "own identity (authenticator)"},
		{EngineSQLServer, "sqlserver://x@db.example?fedauth=ActiveDirectoryManagedIdentity", "own identity (fedauth=ActiveDirectoryManagedIdentity)"},
		{EngineSQLServer, "sqlserver://reader:pw@db.example?log=255", "driver option log is not one"},
		{EngineSQLServer, "sqlserver://reader:pw@db.example?krb5-keytabfile=/k", "own identity (krb5-keytabfile)"},
		// go-mssqldb reads the query through url.URL.Query(): a malformed pair is dropped, the driver never sees it
		{EngineSQLServer, "sqlserver://reader:pw@db.example?encrypt=%zz", ""},
		{EngineSQLServer, "sqlserver://reader:pw@db.example?encrypt=true&encrypt=false", "does not read"},
		{EnginePostgres, "host=db.example port=5432 dbname=erp user=reader password=pw sslmode=require", ""},
		{EnginePostgres, "host=db.example dbname='my db' user='o\\'neil' password='p w' sslrootcert=system", ""},
		// a URL is never what BuildDSN writes: refused (net/url and pgx read a ';' or a '#' apart)
		{EnginePostgres, "postgres://reader:pw@db.example:5432/erp?sslmode=verify-full", "a URL"},
		{EnginePostgres, "postgres://reader:pw@h/erp?options=-c%20role%3Dadmin%20-c%20application_name%3Da;b", "a URL"},
		{EnginePostgres, "postgres://reader:pw@h/erp#?options=-c%20role%3Dadmin", "a URL"},
		{EnginePostgres, "postgres://u:p@/db", "a URL"},
		{EnginePostgres, "host=db.example dbname=erp user=reader", "no login and password"},
		{EnginePostgres, "host=db.example dbname=erp user=reader password=pw passfile=/p", "own identity (passfile)"},
		{EnginePostgres, "host=db.example dbname=erp user=reader password=pw sslrootcert=/ca.pem", "names a file on this server's host (sslrootcert)"},
		{EnginePostgres, "host=db.example dbname=erp user=reader password=pw statement_timeout=0", "driver option statement_timeout is not one"},
		{EnginePostgres, "postgres://reader:pw@db.example/erp?service=prod", "a URL"},
		// pgx splits at \r, \v and \f too, and its last key wins: a second key hidden behind one of them
		{EnginePostgres, "host=h user=u password=x\vpassword=", "does not read"},
		{EnginePostgres, "host=h\rservice=prod user=u password=p", "own identity (service)"},
		{EnginePostgres, "host=h user=u password=p sslmode=require\fpassfile=/p", "own identity (passfile)"},
		// a host pgx reads as this server's own socket: an empty list element, a path, an abstract socket, none at all
		{EnginePostgres, "host=h, user=u password=p", "this server's own socket"},
		{EnginePostgres, "host=/var/run/postgresql user=u password=p", "this server's own socket"},
		{EnginePostgres, "host=@pg user=u password=p", "this server's own socket"},
		{EnginePostgres, "user=u password=p dbname=erp", "this server's own socket"},
		// pgx's keywords are read as written: an upper-case key is a startup setting, not the allowed option
		{EnginePostgres, "host=h user=u password=p SSLMODE=disable", "driver option SSLMODE is not one"},
		{EnginePostgres, "host=db.example user=reader user=other password=pw", "does not read"},
		{EnginePostgres, "host=db.example password='unclosed", "does not read"},
		{EnginePostgres, "", "not readable on this host"},
	}
	for _, c := range cases {
		got := PageDSNRefusal("i1", c.engine, c.dsn)
		if c.want == "" && got != "" || c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("PageDSNRefusal(%s, %q) = %q, want %q", c.engine, c.dsn, got, c.want)
		}
	}
	// what BuildDSN writes from an allowed row opens; the same row with a refused option does not
	for _, c := range []Conn{
		{Engine: EngineSQLServer, Auth: "sql", Host: "db.example", Port: 1433, DBName: "Sales", Login: "reader", Password: "pw", Extra: "TrustServerCertificate=true"},
		{Engine: EngineSQLServer, Auth: "entra", Host: "db.example", Login: "app-id", Password: "secret"},
		{Engine: EnginePostgres, Auth: "password", Host: "db.example", Port: 5432, DBName: "erp", Login: "reader", Password: "p w'x", Extra: "sslmode=require"},
		// a control byte in a typed value is quoted, so the driver reads one value (never a second key)
		{Engine: EnginePostgres, Auth: "password", Host: "db.example", Login: "reader", Password: "x\vpassword="},
	} {
		dsn, err := BuildDSN(c)
		if err != nil {
			t.Fatalf("BuildDSN(%+v): %v", c, err)
		}
		if why := PageDSNRefusal("i1", c.Engine, dsn); why != "" {
			t.Errorf("BuildDSN's own string for %s %s refused: %s (%q)", c.Engine, c.Auth, why, dsn)
		}
	}
	// a form's host with an empty list element opens no door
	dsn, err := BuildDSN(Conn{Engine: EnginePostgres, Auth: "password", Host: "h,", Login: "reader", Password: "pw"})
	if err == nil {
		if why := PageDSNRefusal("i1", EnginePostgres, dsn); !strings.Contains(why, "this server's own socket") {
			t.Errorf("host 'h,': %q (%q)", why, dsn)
		}
	}
}

// the switch is pgvigil.yaml's alone and off unless it says so ('on' as the docs write it, YAML 1.1's word)
func TestDoorsSwitch(t *testing.T) {
	for _, c := range []struct {
		yaml string
		want bool
	}{
		{"", false},
		{"doors:\n  page_instance_reads: on\n", true},
		{"doors:\n  page_instance_reads: true\n", true},
		{"doors:\n  page_instance_reads: off\n", false},
		{"doors: {}\n", false},
	} {
		p := filepath.Join(t.TempDir(), "pgvigil.yaml")
		if err := os.WriteFile(p, []byte("repository:\n  dsn: host=r\n"+c.yaml), 0o600); err != nil {
			t.Fatal(err)
		}
		cfg, err := Load(p)
		if err != nil {
			t.Fatalf("%q: %v", c.yaml, err)
		}
		if cfg.Doors.PageInstanceReads != c.want {
			t.Errorf("%q: page_instance_reads %v, want %v", c.yaml, cfg.Doors.PageInstanceReads, c.want)
		}
	}
}
