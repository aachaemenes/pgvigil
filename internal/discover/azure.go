package discover

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// AzureOptions names the subscriptions to read (none = every subscription the identity may read) and one credential:
//   - TenantID + ClientID + ClientSecret: a service principal (the client credentials grant);
//   - ManagedIdentity: the Azure VM's identity (the instance metadata endpoint; ClientID picks a user-assigned one);
//   - Token: an access token for the cloud's Resource Manager (az cloud set to that cloud first, then az account
//     get-access-token), for a one-off read: a token of another cloud's audience is refused by its Resource Manager.
//
// The identity needs a list-only role on the subscriptions (Resource Graph shows what the identity may read):
// docs/discovery.md. Cloud picks the Azure cloud: "" or "public" (management.azure.com), "usgov" (Azure Government)
// or "china" (Azure operated by 21Vianet) - its Resource Manager host, sign-in host and token audience; NOT PROVEN
// outside the public cloud (no lab). PrevScopes are the subscriptions the source's last complete read saw: with
// none named, one of them missing now is unseen (Resource Graph leaves a subscription out without a word).
type AzureOptions struct {
	Subscriptions                    []string
	TenantID, ClientID, ClientSecret string
	ManagedIdentity                  bool
	Token                            string
	Cloud                            string
	PrevScopes                       []string
	// the endpoints (tests stand their own in): Azure Resource Manager, the sign-in, the instance metadata
	ARM, Login, IMDS string
	HTTP             *http.Client
}

// azureQuery reads the three types with what the approve needs: the host, the Entra-only flag (an Azure SQL
// server's or a Managed Instance's administrators.azureADOnlyAuthentication, a flexible server's
// authConfig.passwordAuth) and a serverless database's auto-pause delay (minutes; -1 = off).
const azureQuery = `resources
| where type in~ ('microsoft.sql/servers/databases', 'microsoft.sql/managedinstances', 'microsoft.dbforpostgresql/flexibleservers')
| where not(type =~ 'microsoft.sql/servers/databases' and name =~ 'master')
| extend serverId = tostring(split(tolower(id), '/databases/')[0])
| join kind=leftouter (resources | where type =~ 'microsoft.sql/servers' | project serverId = tolower(id), serverFqdn = tostring(properties.fullyQualifiedDomainName), serverAadOnly = tobool(properties.administrators.azureADOnlyAuthentication)) on serverId
| project id, name, type, kind, location, subscriptionId, resourceGroup, tags, fqdn = iff(type =~ 'microsoft.sql/servers/databases', serverFqdn, tostring(properties.fullyQualifiedDomainName)),
  aadOnly = iff(type =~ 'microsoft.sql/servers/databases', serverAadOnly, tobool(properties.administrators.azureADOnlyAuthentication)),
  passwordAuth = tostring(properties.authConfig.passwordAuth), autoPauseDelay = toint(properties.autoPauseDelay), skuName = tostring(sku.name),
  databaseId = tostring(properties.databaseId), dnsZone = tostring(properties.dnsZone)
| order by id asc`

// azureSubsQuery reads the subscriptions the identity can see: Resource Graph answers only for those, silently,
// so a named one missing from this answer was not read.
const azureSubsQuery = `resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| project subscriptionId, state = tostring(properties.state)
| order by subscriptionId asc`

var azureSubID = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

func (o AzureOptions) client() *http.Client {
	if o.HTTP != nil {
		return o.HTTP
	}
	return &http.Client{Timeout: 60 * time.Second}
}

// azureCloud names a cloud's Resource Manager host, sign-in host and token audience (the resource a token is for).
func azureCloud(name string) (arm, login, audience string, err error) {
	switch strings.ToLower(name) {
	case "", "public":
		return "https://management.azure.com", "https://login.microsoftonline.com", "https://management.azure.com/", nil
	case "usgov":
		return "https://management.usgovcloudapi.net", "https://login.microsoftonline.us", "https://management.usgovcloudapi.net/", nil
	case "china":
		return "https://management.chinacloudapi.cn", "https://login.chinacloudapi.cn", "https://management.chinacloudapi.cn/", nil
	}
	return "", "", "", fmt.Errorf("the Azure cloud is public, usgov or china, not %q", name)
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return strings.TrimRight(v, "/")
}

// azureToken gets the access token for the cloud's Resource Manager by the options' one credential.
func azureToken(ctx context.Context, o AzureOptions) (string, error) {
	_, login, audience, err := azureCloud(o.Cloud)
	if err != nil {
		return "", err
	}
	switch {
	case o.Token != "":
		return strings.TrimSpace(o.Token), nil
	case o.TenantID != "" && o.ClientID != "" && o.ClientSecret != "":
		form := url.Values{"grant_type": {"client_credentials"}, "client_id": {o.ClientID}, "client_secret": {o.ClientSecret}, "scope": {audience + ".default"}}
		u := orDefault(o.Login, login) + "/" + url.PathEscape(o.TenantID) + "/oauth2/v2.0/token"
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, strings.NewReader(form.Encode()))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		return tokenFrom(o.client(), req, "the service principal's sign-in")
	case o.ManagedIdentity:
		q := url.Values{"api-version": {"2018-02-01"}, "resource": {audience}}
		if o.ClientID != "" {
			q.Set("client_id", o.ClientID)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, orDefault(o.IMDS, "http://169.254.169.254")+"/metadata/identity/oauth2/token?"+q.Encode(), nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("Metadata", "true")
		c := o.HTTP
		if c == nil { // the instance metadata endpoint refuses a proxied request: never through HTTP_PROXY
			t := http.DefaultTransport.(*http.Transport).Clone()
			t.Proxy = nil
			c = &http.Client{Timeout: 60 * time.Second, Transport: t}
		}
		return tokenFrom(c, req, "the managed identity")
	}
	return "", errors.New("no Azure credential: a service principal (tenant, client id, secret), the managed identity, or a token")
}

// tokenFrom posts a token request and reads access_token; an error names the endpoint's own error words, never
// the request (which carries the secret).
func tokenFrom(c *http.Client, req *http.Request, who string) (string, error) {
	res, err := c.Do(req)
	if err != nil {
		return "", fmt.Errorf("%s: %s", who, scrubURL(err))
	}
	defer func() { _ = res.Body.Close() }()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var t struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
		Description string `json:"error_description"`
	}
	_ = json.Unmarshal(b, &t)
	if res.StatusCode != http.StatusOK || t.AccessToken == "" {
		d := t.Description
		if i := strings.IndexAny(d, "\r\n"); i > 0 {
			d = d[:i]
		}
		return "", fmt.Errorf("%s answered %d %s %s", who, res.StatusCode, t.Error, d)
	}
	return t.AccessToken, nil
}

// scrubURL drops the URL an http error quotes (its query may hold a client id; a form body never appears there).
func scrubURL(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		return ue.Op + ": " + ue.Err.Error()
	}
	return err.Error()
}

// graphPage is one page of a Resource Graph query.
type graphPage struct {
	Data      json.RawMessage `json:"data"`
	SkipToken string          `json:"$skipToken"`
	Truncated string          `json:"resultTruncated"`
	// LimitHit is x-ms-tenant-subscription-limit-hit: the answer covers only the tenant's first subscriptions
	LimitHit bool `json:"-"`
}

// graph posts one page of a query; a 429 (the per-user quota) waits once for the quota's reset (5 s at most) and
// asks again.
func graph(ctx context.Context, o AzureOptions, tok, query string, skip string) (graphPage, error) {
	body := map[string]any{"query": query, "options": map[string]any{"$top": 1000, "resultFormat": "objectArray"}}
	if len(o.Subscriptions) > 0 {
		body["subscriptions"] = o.Subscriptions
	}
	if skip != "" {
		body["options"].(map[string]any)["$skipToken"] = skip
	}
	b, _ := json.Marshal(body)
	for try := 0; ; try++ {
		arm, _, _, err := azureCloud(o.Cloud)
		if err != nil {
			return graphPage{}, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, orDefault(o.ARM, arm)+"/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01", bytes.NewReader(b))
		if err != nil {
			return graphPage{}, err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		req.Header.Set("Content-Type", "application/json")
		res, err := o.client().Do(req)
		if err != nil {
			return graphPage{}, fmt.Errorf("the Resource Graph: %s", scrubURL(err))
		}
		rb, _ := io.ReadAll(io.LimitReader(res.Body, 32<<20))
		_ = res.Body.Close()
		if res.StatusCode == http.StatusTooManyRequests && try == 0 {
			select {
			case <-ctx.Done():
				return graphPage{}, ctx.Err()
			case <-time.After(quotaWait(res.Header.Get("x-ms-user-quota-resets-after"))):
			}
			continue
		}
		if res.StatusCode != http.StatusOK {
			return graphPage{}, fmt.Errorf("the Resource Graph answered %d: %s", res.StatusCode, apiMessage(rb))
		}
		var pg graphPage
		if err := json.Unmarshal(rb, &pg); err != nil {
			return graphPage{}, fmt.Errorf("the Resource Graph's answer: %w", err)
		}
		pg.LimitHit = strings.EqualFold(res.Header.Get("x-ms-tenant-subscription-limit-hit"), "true")
		return pg, nil
	}
}

// quotaWait reads x-ms-user-quota-resets-after (hh:mm:ss): 1 s when absent, 5 s at most.
func quotaWait(h string) time.Duration {
	d := time.Second
	if p := strings.Split(h, ":"); len(p) == 3 {
		hh, e1 := strconv.Atoi(p[0])
		mm, e2 := strconv.Atoi(p[1])
		ss, e3 := strconv.ParseFloat(p[2], 64)
		if e1 == nil && e2 == nil && e3 == nil {
			d = time.Duration(hh)*time.Hour + time.Duration(mm)*time.Minute + time.Duration(ss*float64(time.Second))
		}
	}
	return min(max(d, 100*time.Millisecond), 5*time.Second)
}

// Azure reads Resource Graph for Azure SQL Database (each user database), Managed Instance and PostgreSQL
// flexible server; a server without a name in DNS is noted and left out. A named subscription the identity cannot
// read fails the read (its servers would look gone); so does a read that sees no subscription at all, and one the
// tenant's subscription limit cut (x-ms-tenant-subscription-limit-hit). With none named, a subscription of the last
// complete read (PrevScopes) missing now is unseen: its servers are kept as they were.
func Azure(ctx context.Context, o AzureOptions) (Read, error) {
	for _, sub := range o.Subscriptions {
		if !azureSubID.MatchString(sub) {
			return Read{}, fmt.Errorf("%q is not a subscription id (a GUID)", sub)
		}
	}
	tok, err := azureToken(ctx, o)
	if err != nil {
		return Read{}, err
	}
	var rd Read
	var subs []struct{ SubscriptionID, State string }
	for page, skip := 0, ""; ; page++ { // every page: a subscription past the first 1000 is still seen
		if page == 100 {
			return Read{}, errors.New("more than 100 pages of subscriptions: name the subscriptions to read")
		}
		sp, err := graph(ctx, o, tok, azureSubsQuery, skip)
		if err != nil {
			return Read{}, err
		}
		if sp.LimitHit {
			return Read{}, errors.New("the Resource Graph answered for the tenant's first subscriptions only (x-ms-tenant-subscription-limit-hit): name the subscriptions to read")
		}
		var one []struct{ SubscriptionID, State string }
		if err := json.Unmarshal(sp.Data, &one); err != nil {
			return Read{}, fmt.Errorf("the Resource Graph's subscriptions: %w", err)
		}
		subs = append(subs, one...)
		if skip = sp.SkipToken; skip == "" {
			if strings.EqualFold(sp.Truncated, "true") {
				return Read{}, errors.New("the Resource Graph cut its list of subscriptions: name the subscriptions to read")
			}
			break
		}
	}
	seen := map[string]bool{}
	for _, x := range subs {
		seen[strings.ToLower(x.SubscriptionID)] = true
		if x.State != "" && !strings.EqualFold(x.State, "Enabled") {
			rd.Notes = append(rd.Notes, fmt.Sprintf("subscription %s: %s", x.SubscriptionID, x.State))
		}
	}
	partial := false
	var missing []string
	for _, sub := range o.Subscriptions {
		if l := strings.ToLower(sub); !seen[l] {
			// the key carries the subscription: its servers are kept as they were (Resource Graph leaves it out silently)
			missing = append(missing, sub)
			rd.Notes = append(rd.Notes, "subscription "+l+": named, not readable by these credentials (no list role, or no such subscription): its servers kept as they were")
			rd.Unseen = append(rd.Unseen, "azure:"+l+":")
			partial = true
		}
	}
	switch {
	case len(o.Subscriptions) > 0 && len(missing) == len(o.Subscriptions):
		return Read{Notes: rd.Notes}, fmt.Errorf("not readable by these credentials (no list role, or no such subscription): %s", strings.Join(missing, " "))
	case len(subs) == 0:
		return Read{Notes: rd.Notes}, errors.New("these credentials can read no subscription")
	}
	if len(o.Subscriptions) == 0 {
		for _, sub := range o.PrevScopes {
			if sub = strings.ToLower(sub); sub != "" && !seen[sub] {
				partial = true
				rd.Notes = append(rd.Notes, "subscription "+sub+": seen at the last complete read, not readable now (its servers kept as they were)")
				rd.Unseen = append(rd.Unseen, "azure:"+sub+":")
			}
		}
	}
	skip := ""
	for page := 0; ; page++ {
		if page == 100 {
			return Read{Notes: rd.Notes}, errors.New("more than 100 pages of servers: name the subscriptions to read")
		}
		pg, err := graph(ctx, o, tok, azureQuery, skip)
		if err != nil {
			return Read{Notes: rd.Notes}, err
		}
		if pg.LimitHit {
			return Read{Notes: rd.Notes}, errors.New("the Resource Graph answered for the tenant's first subscriptions only (x-ms-tenant-subscription-limit-hit): name the subscriptions to read")
		}
		var data []azureRow
		if err := json.Unmarshal(pg.Data, &data); err != nil {
			return Read{Notes: rd.Notes}, fmt.Errorf("the Resource Graph's answer: %w", err)
		}
		for _, x := range data {
			p, why := azureProposal(x)
			if why != "" {
				rd.Notes = append(rd.Notes, why)
				continue
			}
			rd.Proposals = append(rd.Proposals, p)
		}
		if skip = pg.SkipToken; skip == "" {
			if strings.EqualFold(pg.Truncated, "true") {
				return Read{Notes: rd.Notes}, errors.New("the Resource Graph cut its answer: name the subscriptions to read")
			}
			break
		}
	}
	// the subscriptions kept: those seen now, and on a partial read the earlier ones too (one missing stays unseen
	// until it is back; one granted meanwhile is kept at once)
	keep := map[string]bool{}
	for sub := range seen {
		keep[sub] = true
	}
	if partial {
		for _, sub := range o.PrevScopes {
			keep[strings.ToLower(sub)] = true
		}
		for _, sub := range missing {
			keep[strings.ToLower(sub)] = true
		}
	}
	for sub := range keep {
		if sub != "" {
			rd.Scopes = append(rd.Scopes, sub)
		}
	}
	sort.Strings(rd.Scopes)
	sort.Strings(rd.Unseen)
	sort.Slice(rd.Proposals, func(i, j int) bool { return rd.Proposals[i].Server < rd.Proposals[j].Server })
	rd.TagKeys = tagKeysOf(rd.Proposals)
	return rd, nil
}

// azureRow is one row of azureQuery.
type azureRow struct {
	ID, Name, Type, Kind, Location, SubscriptionID, ResourceGroup, FQDN, PasswordAuth, SkuName, DatabaseID, DNSZone string
	AadOnly                                                                                                         *bool
	AutoPauseDelay                                                                                                  *int
	Tags                                                                                                            map[string]string
}

// azureProposal maps one resource. The key carries the subscription (azure:<sub>:sql:<server>/<database>,
// azure:<sub>:mi:<name>, azure:<sub>:pg:<name>), so a subscription not seen holds its servers as they were; the
// resource id is kept beside it. An Entra-only server is proposed with its blocking note (a password or SQL login is
// refused at its approve); a serverless database says whether it pauses.
func azureProposal(x azureRow) (config.Proposal, string) {
	sub := strings.ToLower(x.SubscriptionID)
	tags := []string{"cloud:azure", "region:" + x.Location}
	if sub != "" {
		tags = append(tags, "subscription:"+sub)
	}
	if x.ResourceGroup != "" {
		tags = append(tags, "resource-group:"+strings.ToLower(x.ResourceGroup))
	}
	p := config.Proposal{Host: x.FQDN, Tags: sortedTags(tags...), CloudTags: x.Tags, ResourceID: strings.ToLower(x.ID)}
	if x.FQDN == "" {
		return p, fmt.Sprintf("%s: no host name in its properties (left out)", x.ID)
	}
	if sub == "" {
		return p, fmt.Sprintf("%s: no subscription id (left out)", x.ID)
	}
	switch strings.ToLower(x.Type) {
	case "microsoft.sql/servers/databases":
		server := path.Base(strings.SplitN(strings.ToLower(x.ID), "/databases/", 2)[0])
		if strings.Contains(strings.ToLower(x.Kind), "datawarehouse") {
			return p, server + "/" + x.Name + ": a dedicated SQL pool (left out)"
		}
		p.Server = "azure:" + sub + ":sql:" + server + "/" + strings.ToLower(x.Name)
		p.Engine, p.Port, p.DBName, p.DisplayName = config.EngineSQLServer, 1433, x.Name, server+"/"+x.Name
		if x.DatabaseID != "" { // the database's own GUID: a database made again under the name is a new one
			p.ResourceID = "databaseId:" + strings.ToLower(x.DatabaseID)
		}
		if strings.Contains(strings.ToLower(x.Kind), "serverless") || strings.HasPrefix(strings.ToUpper(x.SkuName), "GP_S_") {
			p.Serverless = "Azure SQL Database serverless"
			if x.AutoPauseDelay != nil && *x.AutoPauseDelay > 0 {
				p.AutoPause = true
				p.Serverless += fmt.Sprintf(", pauses after %d min idle", *x.AutoPauseDelay)
			} else {
				p.Serverless += ", auto-pause off"
			}
		}
	case "microsoft.sql/managedinstances":
		p.Server = "azure:" + sub + ":mi:" + strings.ToLower(x.Name)
		p.Engine, p.Port, p.DisplayName = config.EngineSQLServer, 1433, x.Name
		if x.DNSZone != "" { // the DNS zone a Managed Instance gets at its creation
			p.ResourceID = strings.ToLower(x.Name) + "@" + strings.ToLower(x.DNSZone)
		}
	case "microsoft.dbforpostgresql/flexibleservers":
		p.Server = "azure:" + sub + ":pg:" + strings.ToLower(x.Name)
		p.Engine, p.Port, p.DBName, p.DisplayName = config.EnginePostgres, 5432, "postgres", x.Name
	default:
		return p, x.ID + ": type " + x.Type + " (not read)"
	}
	switch {
	case p.Engine == config.EngineSQLServer && x.AadOnly != nil && *x.AadOnly:
		p.EntraOnly, p.Note = true, "Microsoft Entra-only authentication: a SQL login cannot sign in (approve with an Entra login)"
	case p.Engine == config.EnginePostgres && strings.EqualFold(x.PasswordAuth, "Disabled"):
		p.EntraOnly, p.Note = true, "password authentication is off: only Microsoft Entra sign-ins (approve with an Entra login)"
	}
	return p, ""
}

// apiMessage reads a cloud API's error words ({"error":{"code","message"}}, Google's and Azure's shape) without
// echoing a whole body.
func apiMessage(b []byte) string {
	var e struct {
		Error struct {
			Code    any    `json:"code"`
			Status  string `json:"status"`
			Message string `json:"message"`
			Details []struct {
				Reason  string `json:"reason"`
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"details"`
		} `json:"error"`
	}
	if json.Unmarshal(b, &e) == nil && e.Error.Message != "" {
		m := e.Error.Message
		if i := strings.IndexAny(m, "\r\n"); i > 0 {
			m = m[:i]
		}
		if len(m) > 300 {
			m = m[:300]
		}
		parts := []string{}
		if e.Error.Status != "" {
			parts = append(parts, e.Error.Status)
		} else if e.Error.Code != nil {
			parts = append(parts, fmt.Sprint(e.Error.Code))
		}
		for _, d := range e.Error.Details {
			switch {
			case d.Reason != "": // Google's shape
				parts = append(parts, d.Reason)
			case d.Code != "" || d.Message != "": // Azure's: the top message is often a support line, the reason is here
				dm := d.Message
				if i := strings.IndexAny(dm, "\r\n"); i > 0 {
					dm = dm[:i]
				}
				parts = append(parts, strings.TrimSpace(d.Code+" "+dm))
			}
		}
		out := strings.Join(append(parts, m), ": ")
		if len(out) > 600 {
			out = out[:600]
		}
		return out
	}
	if len(b) > 200 {
		b = b[:200]
	}
	return strings.TrimSpace(string(b))
}
