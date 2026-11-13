package mssqlopen

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/microsoft/go-mssqldb/msdsn"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// resetCredentials empties the process's credentials and puts the real constructor back when the test ends.
func resetCredentials(t *testing.T) {
	t.Helper()
	reset := func() {
		credMu.Lock()
		creds = map[identity]azcore.TokenCredential{}
		credMu.Unlock()
		newCredential = makeCredential
	}
	reset()
	t.Cleanup(reset)
}

// Each auth's string, as config.BuildDSN writes it, opens the way it needs: SQL logins and Windows (Kerberos)
// through the plain driver, Entra through the federated-authentication connector - never the plain driver, which
// would send an application's secret as a SQL password.
func TestConnectorChosenPerAuth(t *testing.T) {
	for _, c := range []struct {
		conn config.Conn
		fed  bool
	}{
		{config.Conn{Auth: "sql", Login: "mon", Password: "x"}, false},
		{config.Conn{Auth: "windows", Login: "svc@CORP.EXAMPLE.COM"}, false},
		{config.Conn{Auth: "entra", Login: "app-id", Password: "s3cret"}, true},
		{config.Conn{Auth: "entra-identity"}, true},
		{config.Conn{Auth: "entra-identity", Login: "6a1b2c3d-0000-4000-8000-000000000001"}, true},
	} {
		c.conn.Engine, c.conn.Host = config.EngineSQLServer, "srv1.database.windows.net"
		dsn, err := config.BuildDSN(c.conn)
		if err != nil {
			t.Fatalf("%s: %v", c.conn.Auth, err)
		}
		got, err := connector(dsn)
		if err != nil {
			t.Fatalf("%s: %v", c.conn.Auth, err)
		}
		if (got != nil) != c.fed {
			t.Errorf("auth %s (%s): the federated connector chosen = %v, want %v", c.conn.Auth, dsn, got != nil, c.fed)
		}
		db, err := Open(dsn)
		if err != nil {
			t.Fatalf("%s: Open: %v", c.conn.Auth, err)
		}
		_ = db.Close()
	}
}

// A string this package cannot sign in with is refused at the open, in words that say why.
func TestRefusals(t *testing.T) {
	for _, c := range []struct{ dsn, word string }{
		{"sqlserver://h?fedauth=ActiveDirectoryDefault", "not one pgvigil opens"},
		{"sqlserver://h?fedauth=ActiveDirectoryPassword&applicationclientid=x", "not one pgvigil opens"},
		{"sqlserver://id:pw@h?fedauth=ActiveDirectoryManagedIdentity", "no secret"},
		{"sqlserver://h?fedauth=ActiveDirectoryMSI&user+id=a&resource+id=%2Fsubscriptions%2Fs", "not both"},
		{"sqlserver://app@h?fedauth=ActiveDirectoryServicePrincipal", "its secret"},
		{"sqlserver://app:pw@h?fedauth=ActiveDirectoryServicePrincipal&clientcertpath=%2Fk.pem", "certificate"},
		{"sqlserver://h?fedauth=ActiveDirectoryManagedIdentity&authenticator=krb5", "authenticator together"},
	} {
		_, err := Open(c.dsn)
		if err == nil || !strings.Contains(err.Error(), c.word) {
			t.Errorf("%s: got %v, want a refusal with %q", c.dsn, err, c.word)
		}
	}
}

// fakeCred counts its token requests.
type fakeCred struct{ asked *atomic.Int32 }

func (f fakeCred) GetToken(context.Context, policy.TokenRequestOptions) (azcore.AccessToken, error) {
	f.asked.Add(1)
	return azcore.AccessToken{Token: "t", ExpiresOn: time.Now().Add(time.Hour)}, nil
}

// One credential per identity for the process: N runs, each opening its own sql.DB, share it; another identity, or
// a service principal in another tenant, gets its own.
func TestOneCredentialPerIdentity(t *testing.T) {
	resetCredentials(t)
	var made, asked atomic.Int32
	var keys []identity
	newCredential = func(k identity, _ string) (azcore.TokenCredential, error) {
		made.Add(1)
		keys = append(keys, k)
		return fakeCred{&asked}, nil
	}
	ask := func(dsn, sts string) {
		t.Helper()
		cfg, err := msdsn.Parse(dsn)
		if err != nil {
			t.Fatal(err)
		}
		_, provide, err := tokenProvider(cfg, cfg.Parameters["fedauth"])
		if err != nil {
			t.Fatal(err)
		}
		if _, err := provide(context.Background(), "https://database.windows.net/", sts); err != nil {
			t.Fatal(err)
		}
	}
	const sts = "https://login.microsoftonline.com/tenant-a"
	for range 5 {
		ask("sqlserver://srv1.database.windows.net?fedauth=ActiveDirectoryManagedIdentity", sts)
	}
	if made.Load() != 1 || asked.Load() != 5 {
		t.Fatalf("5 connects of one managed identity made %d credential(s) and asked %d token(s), want 1 and 5", made.Load(), asked.Load())
	}
	ask("sqlserver://6a1b2c3d@srv2.database.windows.net?fedauth=ActiveDirectoryManagedIdentity", sts) // a user-assigned one
	ask("sqlserver://app:s1@srv1.database.windows.net?fedauth=ActiveDirectoryServicePrincipal", sts)
	ask("sqlserver://app:s1@srv3.database.windows.net?fedauth=ActiveDirectoryServicePrincipal", sts) // same identity, another server
	ask("sqlserver://app:s1@srv4.database.windows.net?fedauth=ActiveDirectoryServicePrincipal", "https://login.microsoftonline.com/tenant-b")
	ask("sqlserver://app:s2@srv1.database.windows.net?fedauth=ActiveDirectoryServicePrincipal", sts) // a new secret
	if made.Load() != 5 {
		t.Fatalf("credentials made %d, want 5 (system, user-assigned, app in tenant-a, app in tenant-b, app's new secret): %+v", made.Load(), keys)
	}
	if keys[2].tenant != "tenant-a" || keys[3].tenant != "tenant-b" {
		t.Fatalf("the service principal's tenant is not the server's: %+v", keys)
	}
}

// The real managed-identity credential against a stand-in for the host's identity endpoint (App Service's form,
// which azidentity takes from IDENTITY_ENDPOINT and IDENTITY_HEADER): five connects ask the endpoint ONCE. For a
// managed identity that holds even without this package's map (MSAL Go v1.8.0 keeps one token cache for the process,
// apps/managedidentity/managedidentity.go L174); the map is what keeps a service principal's token, whose cache is
// its credential's own - TestOneCredentialPerIdentity proves the map.
func TestManagedIdentityTokenCached(t *testing.T) {
	resetCredentials(t)
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.Header.Get("X-IDENTITY-HEADER") != "h" || !strings.HasPrefix(r.URL.Query().Get("resource"), "https://database.windows.net") {
			http.Error(w, "unexpected request "+r.URL.String(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprintf(w, `{"access_token":"tok-%d","expires_on":"%d","resource":"https://database.windows.net/","token_type":"Bearer"}`,
			hits.Load(), time.Now().Add(time.Hour).Unix())
	}))
	defer srv.Close()
	t.Setenv("IDENTITY_ENDPOINT", srv.URL)
	t.Setenv("IDENTITY_HEADER", "h")
	cfg, err := msdsn.Parse("sqlserver://srv1.database.windows.net?fedauth=ActiveDirectoryManagedIdentity")
	if err != nil {
		t.Fatal(err)
	}
	for i := range 5 {
		_, provide, err := tokenProvider(cfg, cfg.Parameters["fedauth"])
		if err != nil {
			t.Fatal(err)
		}
		tok, err := provide(context.Background(), "https://database.windows.net/", "https://login.microsoftonline.com/tenant-a")
		if err != nil {
			t.Fatalf("connect %d: %v", i+1, err)
		}
		if tok != "tok-1" {
			t.Fatalf("connect %d got token %q, want the first one, tok-1", i+1, tok)
		}
	}
	if hits.Load() != 1 {
		t.Fatalf("5 connects asked the identity endpoint %d times, want 1", hits.Load())
	}
}

// Every reader of a SQL Server opens through this package: a plain sql.Open of the driver elsewhere would ignore
// fedauth (an Entra secret sent as a SQL password) and Kerberos (the provider registered here).
func TestOneSQLServerOpener(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	var found []string
	err = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && (d.Name() == "node_modules" || d.Name() == ".git" || strings.HasPrefix(d.Name(), ".") && p != root) {
			return filepath.SkipDir
		}
		if d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") || filepath.Dir(p) == filepath.Join(root, "internal", "mssqlopen") {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		for _, drv := range []string{`"sqlserver"`, `"mssql"`, `"azuresql"`} {
			if strings.Contains(string(b), "sql.Open("+drv) {
				found = append(found, strings.TrimPrefix(p, root+string(filepath.Separator)))
			}
		}
		return nil
	})
	if err != nil && !errors.Is(err, filepath.SkipDir) {
		t.Fatal(err)
	}
	if len(found) > 0 {
		t.Fatalf("SQL Server opened outside internal/mssqlopen (use mssqlopen.Open): %v", found)
	}
}

// The connection strings docs/sqlserver-cloud.md shows for pgvigil.yaml ('Signing in without a stored password'), its
// placeholders filled in, sign in as that page says.
func TestDocumentedStrings(t *testing.T) {
	doc, err := os.ReadFile("../../docs/sqlserver-cloud.md")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		shown, filled, user, auth string
		fed                       bool
	}{
		{"`sqlserver://<server>.database.windows.net?database=<db>&fedauth=ActiveDirectoryManagedIdentity`",
			"sqlserver://srv1.database.windows.net?database=db1&fedauth=ActiveDirectoryManagedIdentity", "", "", true},
		{"`server=<host>;user id=<principal>;authenticator=krb5;krb5-keytabfile=/etc/pgvigil/pgvigil.keytab;krb5-configfile=/etc/krb5.conf;encrypt=true`",
			"server=sql01;user id=pgvigil-gmsa$@CORP.EXAMPLE.COM;authenticator=krb5;krb5-keytabfile=/etc/pgvigil/pgvigil.keytab;krb5-configfile=/etc/krb5.conf;encrypt=true",
			"pgvigil-gmsa$@CORP.EXAMPLE.COM", "krb5", false},
		{"`sqlserver://<host>?encrypt=true`", "sqlserver://sql01?encrypt=true", "", "", false},
	} {
		if !strings.Contains(string(doc), c.shown) {
			t.Errorf("docs/sqlserver-cloud.md no longer shows %s", c.shown)
			continue
		}
		cfg, err := msdsn.Parse(c.filled)
		if err != nil {
			t.Errorf("%s: %v", c.filled, err)
			continue
		}
		got, err := connector(c.filled)
		if err != nil {
			t.Errorf("%s: %v", c.filled, err)
			continue
		}
		if cfg.User != c.user || cfg.Password != "" || cfg.Parameters["authenticator"] != c.auth || (got != nil) != c.fed {
			t.Errorf("%s: user %q password set %v authenticator %q federated %v", c.filled, cfg.User, cfg.Password != "", cfg.Parameters["authenticator"], got != nil)
		}
	}
}
