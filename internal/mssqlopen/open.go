// Package mssqlopen opens a go-mssqldb connection string for every reader of a SQL Server in pgvigil (the collector,
// the actions door, the custom reports, the DBA Dash import and door).
//
// A string without fedauth (a SQL login, Windows authentication) opens the "sqlserver" driver exactly as before. A
// string with fedauth=ActiveDirectoryServicePrincipal (auth entra), ActiveDirectoryManagedIdentity (auth
// entra-identity) or ActiveDirectoryAzCli (the az CLI's sign-in, RELNOTES L173) opens through go-mssqldb's federated-authentication connector with a token provider of this
// package: ONE azidentity credential per identity for the life of the process, so the token cache answers every
// later connect until the token nears its expiry (a service principal's cache is its credential's own; a managed
// identity's is MSAL's, one for the process; the az sign-in's is this package's own, azcache.go: azidentity caches
// none for it). Without this package the plain driver
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
	"os/user"
	"regexp"
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
	// AzCli is the az CLI's sign-in of the account the process runs as (RELNOTES L173, the connection string's fedauth
	// as pgvigil.yaml writes it): no login and no secret in the string; a person's serve, the Windows app, a one-off collect
	AzCli = "ActiveDirectoryAzCli"
)

// Open returns a *sql.DB for a go-mssqldb connection string (URL or key=value form).
func Open(dsn string) (*sql.DB, error) {
	c, err := connector(dsn, nil)
	if err != nil {
		return nil, err
	}
	if c == nil {
		return sql.Open("sqlserver", dsn)
	}
	return sql.OpenDB(c), nil
}

// OpenDialer is Open with the connector's network dialer set (the collector's connect, task 201 DONE-2: a deadline
// on the dial, the TLS handshake and the login reply). The connector is the one Open would use - the federated one for
// fedauth, the Kerberos one for an old auth windows string off Windows, else the driver's own for the string - so a
// dialer never changes how an instance signs in.
func OpenDialer(dsn string, d mssql.Dialer) (*sql.DB, error) {
	h, _ := d.(Holder)
	c, err := connector(dsn, h)
	if err != nil {
		return nil, err
	}
	mc, err := withDialer(c, dsn, d)
	if err != nil {
		return nil, err
	}
	return sql.OpenDB(mc), nil
}

// OpenDialerCredentials is OpenDialer for a string whose login and password come from elsewhere (task B24e: AWS
// Secrets Manager): the string is parsed, the user (when set) and the password put on the parsed config, and the
// same sign-in decisions made on it; the secret never enters a string. A string with fedauth= is refused (an Entra
// sign-in takes no SQL password).
func OpenDialerCredentials(dsn, user, password string, d mssql.Dialer) (*sql.DB, error) {
	cfg, err := msdsn.Parse(dsn)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(cfg.Parameters["fedauth"]) != "" {
		return nil, errors.New("a password from AWS Secrets Manager is a SQL login's: not with fedauth=")
	}
	if user != "" {
		cfg.User = user
	}
	cfg.Password = password
	h, _ := d.(Holder)
	c, err := connectorConfig(cfg, h, true)
	if err != nil {
		return nil, err
	}
	mc, ok := c.(*mssql.Connector)
	if !ok {
		return nil, fmt.Errorf("mssqlopen: a %T takes no dialer", c)
	}
	mc.Dialer = d
	return sql.OpenDB(mc), nil
}

// Holder is a dialer whose connect deadline can be paused: the token provider holds it while it fetches an Entra token
// in the middle of the login, so the time the identity provider takes is not counted as the server's (the collector's
// deadline dialer). Hold returns the release, which restores the time that was left.
type Holder interface{ Hold() (release func()) }

// withDialer sets d on c (connector's result), or on the driver's own connector for dsn when c is nil.
func withDialer(c driver.Connector, dsn string, d mssql.Dialer) (*mssql.Connector, error) {
	if c == nil {
		mc, err := mssql.NewConnector(dsn)
		if err != nil {
			return nil, err
		}
		mc.Dialer = d
		return mc, nil
	}
	mc, ok := c.(*mssql.Connector)
	if !ok {
		return nil, fmt.Errorf("mssqlopen: a %T takes no dialer", c)
	}
	mc.Dialer = d
	return mc, nil
}

// gmsa is the configuration's gmsa: (task 206; the design's rule: the Windows sign-in only as a gMSA named in the
// configuration, never the machine account). With it set, a string that signs in as this process's own Windows
// account opens on Windows only when the process runs as that gMSA: a virtual account (the service's default, NT
// SERVICE\pgvigil) or a system account reaches the server as the machine account DOMAIN\HOST$, and serve, run and the
// import are separate processes, each checked here.
var gmsa struct {
	sync.Mutex
	name string
}

// RequireGMSA is called by each command that connects to SQL Server, right after it reads the configuration.
func RequireGMSA(name string) {
	gmsa.Lock()
	gmsa.name = strings.TrimSpace(name)
	gmsa.Unlock()
}

// processAccount is the account this process runs as, DOMAIN\name on Windows (a variable: the tests replace it).
var processAccount = func() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	return u.Username, nil
}

// gmsaRefusal is why a string may not open under gmsa: ("" = it may): only a string that names no login, no password,
// no fedauth and no authenticator but winsspi (the process's own account, through SSPI) on Windows is checked.
func gmsaRefusal(cfg msdsn.Config, goos string) string {
	gmsa.Lock()
	want := gmsa.name
	gmsa.Unlock()
	if want == "" || goos != "windows" || strings.TrimSpace(cfg.User) != "" || cfg.Password != "" || strings.TrimSpace(cfg.Parameters["fedauth"]) != "" {
		return ""
	}
	if a, named := cfg.Parameters["authenticator"]; named && !strings.EqualFold(strings.TrimSpace(a), "winsspi") {
		return ""
	}
	who, err := processAccount()
	if err != nil {
		return fmt.Sprintf("the account this process runs as could not be read (%v): a Windows sign-in opens only as the gMSA %s (gmsa:)", err, want)
	}
	if !strings.EqualFold(who, want) {
		return fmt.Sprintf("this process runs as %q, not as the gMSA %s the configuration names (gmsa:): its Windows sign-in would reach the server as another account (a virtual or system account signs in as the machine account DOMAIN\\HOST$); run it as the gMSA", who, want)
	}
	return ""
}

// connector is the federated-authentication connector a string with fedauth needs, the Kerberos one an old auth
// windows string needs off Windows, nil for any other string; an error for a Windows sign-in gmsa: refuses. A
// federated connector's token provider holds h (when not nil) while it fetches the token.
func connector(dsn string, h Holder) (driver.Connector, error) {
	cfg, err := msdsn.Parse(dsn)
	if err != nil {
		return nil, err
	}
	return connectorConfig(cfg, h, false)
}

// connectorConfig is connector's decisions on a parsed string; own = the config was changed after the parse (a
// password from AWS Secrets Manager, task B24e), so the driver's own connector is made from the config, never from a
// string that would carry the secret
func connectorConfig(cfg msdsn.Config, h Holder, own bool) (driver.Connector, error) {
	if why := gmsaRefusal(cfg, runtime.GOOS); why != "" {
		return nil, errors.New(why)
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
		if own {
			return mssql.NewConnectorConfig(cfg), nil
		}
		return nil, nil
	}
	workflow, provide, err := tokenProvider(cfg, fa, h)
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

// tenantName is a tenant id or domain as az takes it: letters, digits, '.' and '-'.
var tenantName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]{0,99}$`)

// identity names one Entra identity; its credential is made once per process and kept.
type identity struct {
	flow       string   // ServicePrincipal, ManagedIdentity or AzCli
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
// the driver calls for a token at each connect; h (when not nil) is held while the token is fetched.
func tokenProvider(cfg msdsn.Config, fedauth string, h Holder) (byte, func(ctx context.Context, serverSPN, stsURL string) (string, error), error) {
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
	case strings.EqualFold(fedauth, AzCli):
		if cfg.Password != "" || strings.TrimSpace(cfg.User) != "" {
			return 0, nil, errors.New("the az sign-in names its own account (az login, as the account this process runs as): the connection string holds no login and no password")
		}
		id = identity{flow: AzCli}
		workflow = mssql.FedAuthADALWorkflowPassword
	default:
		return 0, nil, fmt.Errorf("fedauth %s is not one pgvigil opens: %s (auth entra), %s (auth entra-identity) or %s (the az sign-in)", fedauth, ServicePrincipal, ManagedIdentity, AzCli)
	}
	provide := func(ctx context.Context, serverSPN, stsURL string) (string, error) {
		if h != nil {
			defer h.Hold()()
		}
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
		opts := policy.TokenRequestOptions{Scopes: []string{scope}}
		if key.flow == AzCli {
			// the server names its tenant in the STS URL; az is asked for that tenant's token when the name has a
			// tenant id's characters only (it reaches az's command line), else for the sign-in's own tenant
			if tn := stsURL[strings.LastIndex(stsURL, "/")+1:]; tenantName.MatchString(tn) {
				opts.TenantID = tn
			}
		}
		tok, err := cred.GetToken(ctx, opts)
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
	switch key.flow {
	case ServicePrincipal:
		return azidentity.NewClientSecretCredential(key.tenant, key.clientID, secret, nil)
	case AzCli:
		c, err := azidentity.NewAzureCLICredential(nil)
		if err != nil {
			return nil, err
		}
		return newCachedCredential(c), nil
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
