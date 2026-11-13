package web

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The approve's sign-in (C1's wiring): entra-identity never takes the source's or the proposal's SQL login or
// password, takes a user-assigned identity's client id typed at the approve or kept by an entra-identity source, and
// BuildDSN refuses a typed secret with it; the other authentications are as before.
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
		{name: "entra-identity source, a PostgreSQL server: the .pgpass login", engine: config.EnginePostgres, srcAuth: "entra-identity", proposalLogin: "pgadmin",
			auth: "pgpass", login: "pgadmin", dsnHas: []string{"user=pgadmin"}, dsnLacks: []string{"password="}},
		{name: "entra source, nothing typed", engine: config.EngineSQLServer, srcAuth: "entra", cred: sourceCred{Login: client, Password: "spsecret"},
			auth: "entra", login: client, password: "spsecret", dsnHas: []string{"fedauth=ActiveDirectoryServicePrincipal"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			auth, login, pw := approveLogin(c.engine, c.srcAuth, c.typedAuth, c.typedLogin, c.typedPassword, c.cred, c.proposalLogin)
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
