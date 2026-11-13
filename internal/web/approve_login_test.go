package web

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The approve's sign-in (C1's wiring and the join's review 3a / 3c): entra-identity never takes the source's or the
// proposal's SQL login or password, takes a user-assigned identity's client id typed at the approve or kept by an
// entra-identity source, and BuildDSN refuses a typed secret with it; a PostgreSQL proposal of an Entra source is
// approved only with a PostgreSQL login typed (its secret never becomes a password); a picked authentication with no
// login typed takes the source's login only when it is that kind, else the words say what is missing.
func TestApproveLogin(t *testing.T) {
	const client = "6f1c2e3a-0b4d-4e5f-8a9b-0c1d2e3f4a5b"
	sqlSrc := sourceCred{Login: "pgv_reader", Password: "s3cret"}
	for _, c := range []struct {
		name                                   string
		engine, srcAuth, typedAuth, typedLogin string
		typedPassword                          string
		cred                                   sourceCred
		proposalLogin                          string
		auth, login, password                  string
		dsnHas, dsnLacks                       []string
		dsnErr                                 string
		err                                    string
	}{
		{name: "sql source, nothing typed", engine: config.EngineSQLServer, srcAuth: "sql", cred: sqlSrc, proposalLogin: "admin1",
			auth: "sql", login: "pgv_reader", password: "s3cret", dsnHas: []string{"pgv_reader:s3cret@"}},
		{name: "sql source, entra-identity typed alone: the system-assigned identity", engine: config.EngineSQLServer, srcAuth: "sql", typedAuth: "entra-identity", cred: sqlSrc, proposalLogin: "admin1",
			auth: "entra-identity", dsnHas: []string{"fedauth=ActiveDirectoryManagedIdentity"}, dsnLacks: []string{"@", "pgv_reader", "s3cret", "admin1"}},
		{name: "sql source, entra-identity with a typed client id", engine: config.EngineSQLServer, srcAuth: "sql", typedAuth: "entra-identity", typedLogin: client,
			cred: sourceCred{Login: client}, proposalLogin: "admin1",
			auth: "entra-identity", login: client, dsnHas: []string{"fedauth=ActiveDirectoryManagedIdentity", client + "@"}, dsnLacks: []string{"s3cret", "admin1"}},
		{name: "entra-identity source keeps its client id", engine: config.EngineSQLServer, srcAuth: "entra-identity", cred: sourceCred{Login: client}, proposalLogin: "admin1",
			auth: "entra-identity", login: client, dsnHas: []string{"fedauth=ActiveDirectoryManagedIdentity", client + "@"}, dsnLacks: []string{"admin1"}},
		{name: "entra-identity source without a credential: never the proposal's login", engine: config.EngineSQLServer, srcAuth: "entra-identity", proposalLogin: "admin1",
			auth: "entra-identity", dsnHas: []string{"fedauth=ActiveDirectoryManagedIdentity"}, dsnLacks: []string{"@", "admin1"}},
		{name: "a typed password with entra-identity is refused by BuildDSN", engine: config.EngineSQLServer, srcAuth: "sql", typedAuth: "entra-identity", typedLogin: client, typedPassword: "x",
			cred: sourceCred{Login: client, Password: "x"},
			auth: "entra-identity", login: client, password: "x", dsnErr: "no secret is stored"},
		{name: "3a: entra-identity source, a PostgreSQL server, nothing typed: refused", engine: config.EnginePostgres, srcAuth: "entra-identity", proposalLogin: "pgadmin",
			err: "pgvigil signs in to PostgreSQL with a password login only: type a PostgreSQL login for srv1"},
		{name: "3a: entra source (a service principal), a PostgreSQL server, nothing typed: refused, the secret never a password", engine: config.EnginePostgres, srcAuth: "entra",
			cred: sourceCred{Login: client, Password: "spsecret"}, proposalLogin: "pgadmin", err: "type a PostgreSQL login for srv1"},
		{name: "3a: entra source, a PostgreSQL login typed: that login and password", engine: config.EnginePostgres, srcAuth: "entra", typedLogin: "pgreader", typedPassword: "pw1",
			cred: sourceCred{Login: client, Password: "spsecret"}, auth: "password", login: "pgreader", password: "pw1", dsnHas: []string{"user=pgreader"}, dsnLacks: []string{"spsecret", client}},
		{name: "3c: a SQL login picked, no login typed, the source a service principal: refused", engine: config.EngineSQLServer, srcAuth: "entra", typedAuth: "sql",
			cred: sourceCred{Login: client, Password: "spsecret"}, err: "a SQL login needs its name and password: the source signs in as entra"},
		{name: "3c: a service principal picked, no login typed, the source a SQL login: refused", engine: config.EngineSQLServer, srcAuth: "sql", typedAuth: "entra",
			cred: sqlSrc, err: "an Entra service principal needs its application (client) id and secret"},
		{name: "3c: a PostgreSQL login picked, no login typed, the source .pgpass: refused", engine: config.EnginePostgres, srcAuth: "pgpass", typedAuth: "password",
			cred: sourceCred{Login: "pguser"}, err: "a PostgreSQL login needs its password: the source holds none"},
		{name: "3c: Windows picked, no login typed, the source a SQL login: no secret of the source's", engine: config.EngineSQLServer, srcAuth: "sql", typedAuth: "windows",
			cred: sqlSrc, auth: "windows", dsnLacks: []string{"pgv_reader", "s3cret"}},
		{name: "3c: the source's own kind picked, no login typed: the source's login", engine: config.EngineSQLServer, srcAuth: "sql", typedAuth: "sql",
			cred: sqlSrc, auth: "sql", login: "pgv_reader", password: "s3cret", dsnHas: []string{"pgv_reader:s3cret@"}},
		{name: "entra source, nothing typed", engine: config.EngineSQLServer, srcAuth: "entra", cred: sourceCred{Login: client, Password: "spsecret"},
			auth: "entra", login: client, password: "spsecret", dsnHas: []string{"fedauth=ActiveDirectoryServicePrincipal"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			auth, login, pw, err := approveLogin(c.engine, c.srcAuth, c.typedAuth, c.typedLogin, c.typedPassword, c.cred, c.proposalLogin, "srv1")
			if c.err != "" {
				if err == nil || !strings.Contains(err.Error(), c.err) {
					t.Fatalf("approveLogin: %v (auth %q, login %q); want the words %q", err, auth, login, c.err)
				}
				return
			}
			if err != nil {
				t.Fatalf("approveLogin: %v", err)
			}
			if auth != c.auth || login != c.login || pw != c.password {
				t.Fatalf("approveLogin = %q, %q, %q; want %q, %q, %q", auth, login, pw, c.auth, c.login, c.password)
			}
			dsn, err := config.BuildDSN(config.Conn{Engine: c.engine, Auth: auth, Host: "srv1.database.windows.net", DBName: "db1", Login: login, Password: pw})
			if c.dsnErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.dsnErr) {
					t.Fatalf("BuildDSN: %v; want an error with %q", err, c.dsnErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("BuildDSN: %v", err)
			}
			for _, s := range c.dsnHas {
				if !strings.Contains(dsn, s) {
					t.Errorf("the DSN lacks %q", s)
				}
			}
			for _, s := range c.dsnLacks {
				if strings.Contains(dsn, s) {
					t.Errorf("the DSN holds %q", s)
				}
			}
		})
	}
}
