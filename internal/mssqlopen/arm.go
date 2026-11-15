package mssqlopen

import (
	"context"
	"crypto/sha256"
	"errors"
	"strings"
	"sync"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/microsoft/go-mssqldb/msdsn"
)

// ARMToken returns an access token for Azure Resource Manager (audience: the cloud's Resource Manager, e.g.
// https://management.azure.com/) by the sign-in a SQL Server connection string names (task 390a, the failover group
// read): its Entra service principal (the tenant named, <application id>@<tenant>: Resource Manager names none) or
// its managed identity, through the process's one credential for that identity (the one its SQL tokens come from);
// a string that signs in with a SQL login or Windows has no Entra identity of its own, so azidentity's default chain
// answers (the environment, a workload identity, a managed identity, the Azure CLI's sign-in). Nothing is stored.
// Outside the public cloud the sign-in host is azidentity's AZURE_AUTHORITY_HOST (not proven: no lab).
func ARMToken(ctx context.Context, dsn, audience string) (string, error) {
	cred, err := armCredential(dsn)
	if err != nil {
		return "", err
	}
	tok, err := cred.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{strings.TrimSuffix(audience, "/") + "/.default"}})
	if err != nil {
		return "", err
	}
	return tok.Token, nil
}

var (
	defaultMu   sync.Mutex
	defaultCred azcore.TokenCredential
)

func armCredential(dsn string) (azcore.TokenCredential, error) {
	cfg, err := msdsn.Parse(dsn)
	if err != nil {
		return nil, err
	}
	fa := strings.TrimSpace(cfg.Parameters["fedauth"])
	switch {
	case strings.EqualFold(fa, ServicePrincipal) || strings.EqualFold(fa, "ActiveDirectoryApplication"):
		client, tenant := splitTenant(strings.TrimSpace(cfg.User))
		if client == "" || cfg.Password == "" {
			return nil, errors.New("an Entra service principal needs its application id (user id) and its secret (password)")
		}
		if tenant == "" {
			return nil, errors.New("the failover group read needs the service principal's tenant: write the user id as <application id>@<tenant>")
		}
		return credentialFor(identity{flow: ServicePrincipal, clientID: client, tenant: tenant, secret: sha256.Sum256([]byte(cfg.Password))}, cfg.Password)
	case strings.EqualFold(fa, ManagedIdentity) || strings.EqualFold(fa, "ActiveDirectoryMSI"):
		return credentialFor(identity{flow: ManagedIdentity, clientID: strings.TrimSpace(cfg.User), resourceID: strings.TrimSpace(cfg.Parameters["resource id"])}, "")
	}
	defaultMu.Lock()
	defer defaultMu.Unlock()
	if defaultCred == nil {
		c, err := azidentity.NewDefaultAzureCredential(nil)
		if err != nil {
			return nil, err
		}
		defaultCred = c
	}
	return defaultCred, nil
}
