// Package mssqlopen opens a go-mssqldb connection string for every reader of a SQL Server in pgvigil (the collector,
// the actions door, the custom reports, the DBA Dash import and door).
//
// A string without fedauth (a SQL login, Windows authentication) opens the "sqlserver" driver exactly as before. A
// string with fedauth=ActiveDirectoryServicePrincipal (auth entra) or ActiveDirectoryManagedIdentity (auth
// entra-identity) opens through go-mssqldb's federated-authentication connector with a token provider of this
// package: ONE azidentity credential per identity for the life of the process, so the token cache answers every
// later connect until the token nears its expiry (a service principal's cache is its credential's own; a managed
// identity's is MSAL's, one for the process). Without this package the plain driver
// ignores fedauth and sends the application id and its secret as a SQL login (only go-mssqldb's azuread connector
// reads fedauth, and it builds a new credential, so a new token request, for every connect: go-mssqldb v1.11.2
// azuread/configuration.go).
//
// The Kerberos provider (integratedauth/krb5) is registered here: a string with authenticator=krb5 signs in with a
// keytab or a credential cache (config.BuildDSN writes it for auth windows on a collector that is not Windows).
package mssqlopen

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"sync"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	mssql "github.com/microsoft/go-mssqldb"
	_ "github.com/microsoft/go-mssqldb/integratedauth/krb5" // registers authenticator=krb5
	"github.com/microsoft/go-mssqldb/msdsn"
)

// The two fedauth values pgvigil opens (each with its synonym in go-mssqldb).
const (
	ServicePrincipal = "ActiveDirectoryServicePrincipal" // auth entra: the application id and its secret
	ManagedIdentity  = "ActiveDirectoryManagedIdentity"  // auth entra-identity: the host's own Azure identity, no secret
)

// Open returns a *sql.DB for a go-mssqldb connection string (URL or key=value form).
func Open(dsn string) (*sql.DB, error) {
	c, err := connector(dsn)
	if err != nil {
		return nil, err
	}
	if c == nil {
		return sql.Open("sqlserver", dsn)
	}
	return sql.OpenDB(c), nil
}

// connector is the federated-authentication connector a string with fedauth needs, the Kerberos one an old auth
// windows string needs off Windows, nil for any other string.
func connector(dsn string) (driver.Connector, error) {
	cfg, err := msdsn.Parse(dsn)
	if err != nil {
		return nil, err
	}
	fa := strings.TrimSpace(cfg.Parameters["fedauth"])
	if fa == "" {
		if kerberosByDefault(cfg, runtime.GOOS) {
			// a string with no login, no password and no sign-in named: auth windows as written before Kerberos was
			// added off Windows (a page row edited only in its tags keeps its old file). go-mssqldb's default there
			// is NTLM, which without DOMAIN\user falls back to a SQL login with an empty user name and always
			// fails; Kerberos is what auth windows means off Windows now.
			cfg.Parameters["authenticator"] = "krb5"
			return mssql.NewConnectorConfig(cfg), nil
		}
		return nil, nil
	}
	workflow, provide, err := tokenProvider(cfg, fa)
	if err != nil {
		return nil, err
	}
	return mssql.NewActiveDirectoryTokenConnector(cfg, workflow, provide)
}

// kerberosByDefault says whether a string off Windows names no sign-in at all (see connector).
func kerberosByDefault(cfg msdsn.Config, goos string) bool {
	_, named := cfg.Parameters["authenticator"]
	return goos != "windows" && !named && strings.TrimSpace(cfg.User) == "" && cfg.Password == ""
}

// tokenAudiences are the Azure SQL resources a token may be asked for: the server names the audience in its login
// answer, and a token for any other resource (Key Vault, ARM) must never go to a SQL endpoint.
var tokenAudiences = []string{"https://database.windows.net", "https://database.usgovcloudapi.net", "https://database.chinacloudapi.cn"}

// sqlAudience says whether the server's SPN is an Azure SQL resource (with or without a closing '/' or '/.default').
func sqlAudience(spn string) bool {
	a := strings.TrimSuffix(strings.TrimSuffix(strings.TrimSpace(spn), "/.default"), "/")
	for _, ok := range tokenAudiences {
		if strings.EqualFold(a, ok) {
			return true
		}
	}
	return false
}

// identity names one Entra identity; its credential is made once per process and kept.
type identity struct {
	flow       string   // ServicePrincipal or ManagedIdentity
	clientID   string   // the application id, or a user-assigned identity's client id ("" = the system-assigned one)
	resourceID string   // a user-assigned identity's resource id (managed identity only)
	tenant     string   // the service principal's tenant: named in the string, else the one the server names
	secret     [32]byte // the secret's SHA-256: another secret of the same application is another credential
}

var (
	credMu sync.Mutex
	creds  = map[identity]azcore.TokenCredential{}
	// newCredential makes an identity's credential (a test replaces it); secret is the service principal's.
	newCredential = makeCredential
)

// tokenProvider checks the string's Entra settings and returns the workflow the login announces and the provider
// the driver calls for a token at each connect.
func tokenProvider(cfg msdsn.Config, fedauth string) (byte, func(ctx context.Context, serverSPN, stsURL string) (string, error), error) {
	if _, ok := cfg.Parameters["authenticator"]; ok {
		return 0, nil, errors.New("fedauth and authenticator together: an Entra sign-in takes no Windows authenticator")
	}
	var (
		id       identity
		secret   string
		workflow byte
	)
	switch {
	case strings.EqualFold(fedauth, ManagedIdentity) || strings.EqualFold(fedauth, "ActiveDirectoryMSI"):
		if cfg.Password != "" {
			return 0, nil, errors.New("a managed identity has no secret: the connection string must hold no password")
		}
		id = identity{flow: ManagedIdentity, clientID: strings.TrimSpace(cfg.User), resourceID: strings.TrimSpace(cfg.Parameters["resource id"])}
		if id.clientID != "" && id.resourceID != "" {
			return 0, nil, errors.New("a user-assigned identity is named by its client id (user id) or its resource id, not both")
		}
		workflow = mssql.FedAuthADALWorkflowMSI
	case strings.EqualFold(fedauth, ServicePrincipal) || strings.EqualFold(fedauth, "ActiveDirectoryApplication"):
		client, tenant := splitTenant(strings.TrimSpace(cfg.User))
		if client == "" || cfg.Password == "" {
			return 0, nil, errors.New("an Entra service principal needs its application id (user id) and its secret (password)")
		}
		if cfg.Parameters["clientcertpath"] != "" {
			return 0, nil, errors.New("an Entra service principal signs in with its secret here: a certificate (clientcertpath) is not supported")
		}
		id = identity{flow: ServicePrincipal, clientID: client, tenant: tenant, secret: sha256.Sum256([]byte(cfg.Password))}
		secret = cfg.Password
		workflow = mssql.FedAuthADALWorkflowPassword
	default:
		return 0, nil, fmt.Errorf("fedauth %s is not one pgvigil opens: %s (auth entra) or %s (auth entra-identity)", fedauth, ServicePrincipal, ManagedIdentity)
	}
	provide := func(ctx context.Context, serverSPN, stsURL string) (string, error) {
		if !sqlAudience(serverSPN) {
			return "", fmt.Errorf("the server asked for a token for %q, which is not an Azure SQL resource (%s): refused", serverSPN, strings.Join(tokenAudiences, ", "))
		}
		key := id
		if key.flow == ServicePrincipal && key.tenant == "" {
			// the server names its tenant in the STS URL (https://login.microsoftonline.com/<tenant>); only the tenant
			// is taken from it, as go-mssqldb's azuread does: the secret goes to azidentity's own authority
			// (AZURE_AUTHORITY_HOST, else the public cloud), never to a host a server names
			key.tenant = stsURL[strings.LastIndex(stsURL, "/")+1:]
		}
		cred, err := credentialFor(key, secret)
		if err != nil {
			return "", err
		}
		scope := serverSPN
		if !strings.HasSuffix(scope, "/.default") {
			scope += "/.default"
		}
		tok, err := cred.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{scope}})
		if err != nil {
			forget(key) // a tenant the server named that the identity is not in: not kept (the map stays bounded)
			return "", err
		}
		return tok.Token, nil
	}
	return workflow, provide, nil
}

// credentialFor returns the process's credential for an identity, made at its first use.
func credentialFor(key identity, secret string) (azcore.TokenCredential, error) {
	credMu.Lock()
	defer credMu.Unlock()
	if c, ok := creds[key]; ok {
		return c, nil
	}
	c, err := newCredential(key, secret)
	if err != nil {
		return nil, err
	}
	creds[key] = c
	return c, nil
}

// forget drops an identity's credential (its token request failed).
func forget(key identity) {
	credMu.Lock()
	delete(creds, key)
	credMu.Unlock()
}

// makeCredential is azidentity's credential for an identity.
func makeCredential(key identity, secret string) (azcore.TokenCredential, error) {
	if key.flow == ServicePrincipal {
		return azidentity.NewClientSecretCredential(key.tenant, key.clientID, secret, nil)
	}
	var o *azidentity.ManagedIdentityCredentialOptions
	switch {
	case key.resourceID != "":
		o = &azidentity.ManagedIdentityCredentialOptions{ID: azidentity.ResourceID(key.resourceID)}
	case key.clientID != "":
		o = &azidentity.ManagedIdentityCredentialOptions{ID: azidentity.ClientID(key.clientID)}
	}
	return azidentity.NewManagedIdentityCredential(o)
}

// splitTenant reads "application-id@tenant" (go-mssqldb's form); a string without a tenant leaves it to the server.
func splitTenant(user string) (client, tenant string) {
	at := strings.IndexRune(user, '@')
	if at < 1 || at >= len(user)-1 {
		return user, ""
	}
	return user[:at], user[at+1:]
}
