package mssqlopen

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
)

// azRefreshBefore: a cached az token is used until this long before its expiry (a connect started on it still signs
// in), then az is asked again.
const azRefreshBefore = 5 * time.Minute

// azNow is the clock the cache reads (a row moves it).
var azNow = time.Now

// cachedCredential keeps the az CLI's tokens (azidentity's AzureCLICredential caches none: every GetToken would start
// az, and the collector connects for every collection): one token per tenant and scope until azRefreshBefore its
// expiry, one fetch at a time, a failed fetch keeping nothing. A failure is a SignInError.
type cachedCredential struct {
	inner azcore.TokenCredential
	mu    sync.Mutex
	toks  map[string]azcore.AccessToken
}

func newCachedCredential(inner azcore.TokenCredential) *cachedCredential {
	return &cachedCredential{inner: inner, toks: map[string]azcore.AccessToken{}}
}

func (c *cachedCredential) GetToken(ctx context.Context, opts policy.TokenRequestOptions) (azcore.AccessToken, error) {
	key := opts.TenantID + "|" + strings.Join(opts.Scopes, " ")
	c.mu.Lock()
	defer c.mu.Unlock()
	if tok, ok := c.toks[key]; ok && azNow().Add(azRefreshBefore).Before(tok.ExpiresOn) {
		return tok, nil
	}
	delete(c.toks, key)
	tok, err := c.inner.GetToken(ctx, opts)
	if err != nil {
		return azcore.AccessToken{}, &SignInError{Account: azAccount(), err: err}
	}
	c.toks[key] = tok
	return tok, nil
}

// SignInError is an az sign-in that gave no token: the server was never asked, so it is the sign-in's failure (the
// heartbeat counts it as one, never as the server unreachable), named with the account that must sign in.
type SignInError struct {
	Account string
	err     error
}

// mailLike is a user principal name or an e-mail address in az's own words: masked in what pgvigil stores and shows.
var mailLike = regexp.MustCompile(`[^\s'"<>()]+@[^\s'"<>()]+`)

func (e *SignInError) Error() string {
	first := strings.TrimSpace(strings.SplitN(e.err.Error(), "\n", 2)[0])
	if len(first) > 200 {
		first = first[:200] + "..."
	}
	return "the az sign-in of " + e.Account + " gave no token: run 'az login' as that account (az: " + mailLike.ReplaceAllString(first, "<an account>") + ")"
}

func (e *SignInError) Unwrap() error { return e.err }

// SignInFailure marks the error as the sign-in's, not the server's (collect.AuthFailure reads it).
func (e *SignInError) SignInFailure() bool { return true }

// azAccount is the OS account this process runs as (whose az sign-in the flow reads), in words.
func azAccount() string {
	if name, err := processAccount(); err == nil && name != "" {
		return name
	}
	return "the account pgvigil runs as"
}

// IsSignInFailure says whether err is an az sign-in that gave no token.
func IsSignInFailure(err error) bool {
	var s *SignInError
	return errors.As(err, &s)
}
