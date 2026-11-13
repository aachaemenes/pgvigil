package discover

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// GCPOptions names the projects to read (required: listing every project would need the Resource Manager API) and one
// credential:
//   - KeyJSON: a service account key (the JSON file's content), signed into a token here;
//   - Metadata: the account of the Compute Engine / GKE host this runs on (its access scopes must allow the APIs);
//   - Token: an access token (gcloud auth print-access-token), for a one-off read.
//
// The account needs a list-only role (docs/discovery.md: cloudsql.instances.list + .get, alloydb.instances.list,
// resourcemanager.projects.get); a project whose API is not enabled is noted, not failed.
type GCPOptions struct {
	Projects []string
	KeyJSON  string
	Metadata bool
	Token    string
	// the endpoints (tests stand their own in)
	SQLAdmin, AlloyDB, Meta, CRM string
	HTTP                         *http.Client
	// callWait bounds each list call (gcpCallWait when 0; tests shorten it)
	callWait time.Duration
}

func (o GCPOptions) client() *http.Client {
	if o.HTTP != nil {
		return o.HTTP
	}
	return &http.Client{Timeout: 60 * time.Second}
}

// gcpCallWait is how long one list call (one page) may take; an API host that does not answer within it is noted
// and not called again for the read's other projects.
const gcpCallWait = 20 * time.Second

func gcpToken(ctx context.Context, o GCPOptions) (string, error) {
	switch {
	case o.Token != "":
		return strings.TrimSpace(o.Token), nil
	case o.KeyJSON != "":
		var k struct {
			Email    string `json:"client_email"`
			Key      string `json:"private_key"`
			TokenURI string `json:"token_uri"`
		}
		if err := json.Unmarshal([]byte(o.KeyJSON), &k); err != nil || k.Email == "" || k.Key == "" {
			return "", errors.New("the service account key is not a key file's JSON (client_email, private_key)")
		}
		if k.TokenURI == "" {
			k.TokenURI = "https://oauth2.googleapis.com/token"
		}
		blk, _ := pem.Decode([]byte(k.Key))
		if blk == nil {
			return "", errors.New("the service account key's private_key is not PEM")
		}
		pk, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
		if err != nil {
			return "", errors.New("the service account key's private_key is not a PKCS#8 key")
		}
		rk, ok := pk.(*rsa.PrivateKey)
		if !ok {
			return "", errors.New("the service account key is not an RSA key")
		}
		now := time.Now()
		enc := func(v any) string { b, _ := json.Marshal(v); return base64.RawURLEncoding.EncodeToString(b) }
		unsigned := enc(map[string]string{"alg": "RS256", "typ": "JWT"}) + "." + enc(map[string]any{
			"iss": k.Email, "scope": "https://www.googleapis.com/auth/cloud-platform", "aud": k.TokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()})
		sum := sha256.Sum256([]byte(unsigned))
		sig, err := rsa.SignPKCS1v15(rand.Reader, rk, crypto.SHA256, sum[:])
		if err != nil {
			return "", err
		}
		form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {unsigned + "." + base64.RawURLEncoding.EncodeToString(sig)}}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, k.TokenURI, strings.NewReader(form.Encode()))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		return tokenFrom(o.client(), req, "the service account's sign-in")
	case o.Metadata:
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, orDefault(o.Meta, "http://metadata.google.internal")+"/computeMetadata/v1/instance/service-accounts/default/token", nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("Metadata-Flavor", "Google")
		return tokenFrom(o.client(), req, "the metadata server")
	}
	return "", errors.New("no GCP credential: a service account key, the metadata server's account, or a token")
}

// gcpList GETs each page of a list call into items (the field named by key); a refusal answers its words. The
// warnings name what an answer said it left out: Cloud SQL's REGION_UNREACHABLE warnings, AlloyDB's unreachable
// locations. Each page gets wait to answer (errSilent when it does not).
func gcpList(ctx context.Context, o GCPOptions, tok, u, key string, wait time.Duration) ([]json.RawMessage, []string, error) {
	var out []json.RawMessage
	var warns []string
	next := ""
	for page := 0; ; page++ {
		if page == 100 {
			return nil, nil, errors.New("more than 100 pages")
		}
		pu := u
		if next != "" {
			pu += "?pageToken=" + url.QueryEscape(next)
		}
		b, status, err := gcpGet(ctx, o, tok, pu, wait)
		if err != nil {
			return nil, nil, err
		}
		if status != http.StatusOK {
			return nil, nil, fmt.Errorf("%d %s", status, apiMessage(b))
		}
		var r struct {
			Next     string `json:"nextPageToken"`
			Warnings []struct {
				Code, Message, Region string
			} `json:"warnings"`
			Unreachable []string `json:"unreachable"`
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(b, &raw); err != nil {
			return nil, nil, err
		}
		_ = json.Unmarshal(b, &r)
		var items []json.RawMessage
		if v, ok := raw[key]; ok {
			if err := json.Unmarshal(v, &items); err != nil {
				return nil, nil, err
			}
		}
		out = append(out, items...)
		for _, w := range r.Warnings {
			if w.Code == "REGION_UNREACHABLE" {
				warns = append(warns, w.Region+" not reachable (REGION_UNREACHABLE)")
			}
		}
		for _, l := range r.Unreachable {
			warns = append(warns, l[strings.LastIndex(l, "/")+1:]+" not reachable")
		}
		if next = r.Next; next == "" {
			break
		}
	}
	return out, warns, nil
}

// gcpGet is one GET under its own wait.
func gcpGet(ctx context.Context, o GCPOptions, tok, u string, wait time.Duration) ([]byte, int, error) {
	cctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := o.client().Do(req)
	if err != nil {
		if errors.Is(cctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
			return nil, 0, errSilent
		}
		return nil, 0, errors.New(scrubURL(err))
	}
	b, err := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	_ = res.Body.Close()
	if err != nil && errors.Is(cctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
		return nil, 0, errSilent
	}
	return b, res.StatusCode, err
}

// gcpProjectInMsg finds the project a SERVICE_DISABLED error names ("... in project 123456 before ...", or
// "projects/123456"): "" when it names none.
var gcpProjectInMsg = regexp.MustCompile(`(?:in project |projects/)([a-z0-9-]+)`)

// GCP lists each project's Cloud SQL instances (PostgreSQL and SQL Server; the private address first, the public one
// beside it, else the DNS name) and AlloyDB instances (private first); a read pool (Cloud SQL's or AlloyDB's: one
// address balanced over its nodes) is a note, never a proposal. An API the target project has not enabled (403
// SERVICE_DISABLED naming that project, by id or by the number Cloud Resource Manager gives) holds no server: it
// counts as read, with a note; one naming another project (the caller's own) is unseen. Any other refusal or
// silence is a note and its key prefix is unseen; the read fails when no project's API could be read at all.
func GCP(ctx context.Context, o GCPOptions) (Read, error) {
	if len(o.Projects) == 0 {
		return Read{}, errors.New("no GCP project named")
	}
	tok, err := gcpToken(ctx, o)
	if err != nil {
		return Read{}, err
	}
	wait := o.callWait
	if wait <= 0 {
		wait = gcpCallWait
	}
	var rd Read
	read := 0
	silentAPI := map[string]bool{}
	numbers := map[string]string{}
	crmSilent := false
	// isTarget: the project a SERVICE_DISABLED error names is p (its id, or its number by projects.get)
	isTarget := func(p, msg string) (bool, string) {
		m := gcpProjectInMsg.FindStringSubmatch(msg)
		if m == nil {
			return false, "the error names no project"
		}
		if m[1] == p {
			return true, ""
		}
		n, ok := numbers[p]
		if !ok && crmSilent {
			return false, "its project " + m[1] + " not matched to " + p + " (Cloud Resource Manager did not answer)"
		}
		if !ok {
			b, status, err := gcpGet(ctx, o, tok, orDefault(o.CRM, "https://cloudresourcemanager.googleapis.com")+"/v1/projects/"+url.PathEscape(p), wait)
			if errors.Is(err, errSilent) { // not asked again for the read's other projects
				crmSilent = true
			}
			var x struct {
				ProjectNumber string `json:"projectNumber"`
			}
			if err == nil && status == http.StatusOK && json.Unmarshal(b, &x) == nil {
				n = x.ProjectNumber
			}
			numbers[p] = n
		}
		if n == "" {
			return false, "its project " + m[1] + " not matched to " + p + " (resourcemanager.projects.get not answered)"
		}
		if n == m[1] {
			return true, ""
		}
		return false, "it names project " + m[1] + ", not " + p + " (" + n + ")"
	}
	list := func(p, what, base, u, key, prefix string) ([]json.RawMessage, bool) {
		if silentAPI[what] {
			rd.Notes = append(rd.Notes, fmt.Sprintf("%s %s: not read (the API did not answer for an earlier project)", p, what))
			rd.Unseen = append(rd.Unseen, prefix)
			return nil, false
		}
		items, warns, err := gcpList(ctx, o, tok, base+u, key, wait)
		switch {
		case errors.Is(err, errSilent):
			silentAPI[what] = true
			rd.Notes = append(rd.Notes, fmt.Sprintf("%s %s: not reachable (no answer within %s)", p, what, wait))
		case err != nil && strings.Contains(err.Error(), "SERVICE_DISABLED"):
			ok, why := isTarget(p, err.Error())
			if ok {
				rd.Notes = append(rd.Notes, fmt.Sprintf("%s %s: %v", p, what, err))
				read++
				return nil, true
			}
			rd.Notes = append(rd.Notes, fmt.Sprintf("%s %s: SERVICE_DISABLED, but %s: not seen", p, what, why))
		case err != nil:
			rd.Notes = append(rd.Notes, fmt.Sprintf("%s %s: %v", p, what, err))
		}
		if err != nil {
			rd.Unseen = append(rd.Unseen, prefix)
			return nil, false
		}
		read++
		for _, w := range warns {
			rd.Notes = append(rd.Notes, fmt.Sprintf("%s %s: %s", p, what, w))
		}
		if len(warns) > 0 { // the answer says it is partial: nothing of this API is marked gone
			rd.Unseen = append(rd.Unseen, prefix)
		}
		return items, true
	}
	for _, p := range o.Projects {
		pe := url.PathEscape(p)
		items, _ := list(p, "Cloud SQL", orDefault(o.SQLAdmin, "https://sqladmin.googleapis.com"), "/v1/projects/"+pe+"/instances", "items", "gcp:"+p+":sql:")
		for _, raw := range items {
			var x struct {
				Name, DatabaseVersion, Region, InstanceType, DNSName, SelfLink, CreateTime, MasterInstanceName string
				IPAddresses                                                                                    []struct{ Type, IPAddress string } `json:"ipAddresses"`
				Settings                                                                                       struct {
					UserLabels map[string]string `json:"userLabels"`
				} `json:"settings"`
			}
			if json.Unmarshal(raw, &x) != nil {
				continue
			}
			switch x.InstanceType {
			case "ON_PREMISES_INSTANCE": // the stand-in of an external primary, not a Cloud SQL server
				continue
			case "READ_POOL_INSTANCE":
				rd.Notes = append(rd.Notes, fmt.Sprintf("%s Cloud SQL %s: a read pool (one address balanced over its nodes): not proposed", p, x.Name))
				continue
			}
			eng, port := "", 0
			switch {
			case strings.HasPrefix(x.DatabaseVersion, "POSTGRES"):
				eng, port = config.EnginePostgres, 5432
			case strings.HasPrefix(x.DatabaseVersion, "SQLSERVER"):
				eng, port = config.EngineSQLServer, 1433
			default:
				continue
			}
			var private, public string
			for _, a := range x.IPAddresses {
				switch {
				case a.Type == "PRIVATE" && private == "":
					private = a.IPAddress
				case a.Type == "PRIMARY" && public == "":
					public = a.IPAddress
				}
			}
			host, alt := private, public
			if host == "" {
				host, alt = public, ""
			}
			if host == "" {
				host = strings.TrimSuffix(x.DNSName, ".") // a Private Service Connect instance has a DNS name, no address
			} else if x.DNSName != "" && alt == "" {
				alt = strings.TrimSuffix(x.DNSName, ".")
			}
			if host == "" {
				rd.Notes = append(rd.Notes, fmt.Sprintf("%s Cloud SQL %s: no IP address or DNS name (left out)", p, x.Name))
				continue
			}
			tags := []string{"cloud:gcp", "region:" + x.Region, "project:" + p}
			display := x.Name
			if x.InstanceType == "READ_REPLICA_INSTANCE" {
				tags = append(tags, "role:replica")
				if src := x.MasterInstanceName; src != "" {
					tags = append(tags, "source-instance:"+src[strings.LastIndex(src, ":")+1:])
				}
				display += " (replica)"
			}
			// the self link names the instance, not this server: with its create time a server made again under the
			// name is a new resource
			rid := x.SelfLink
			if x.CreateTime != "" {
				rid += "@" + x.CreateTime
			}
			rd.Proposals = append(rd.Proposals, config.Proposal{Server: "gcp:" + p + ":sql:" + x.Name, Engine: eng, Platform: "cloudsql", Host: host, AltHost: alt, Port: port, DisplayName: display,
				ResourceID: rid, Tags: sortedTags(tags...), CloudTags: x.Settings.UserLabels})
		}
		items, _ = list(p, "AlloyDB", orDefault(o.AlloyDB, "https://alloydb.googleapis.com"), "/v1/projects/"+pe+"/locations/-/clusters/-/instances", "instances", "gcp:"+p+":alloydb:")
		for _, raw := range items {
			var x struct {
				Name, UID, IPAddress, PublicIPAddress, InstanceType string
				Labels                                              map[string]string `json:"labels"`
			}
			if json.Unmarshal(raw, &x) != nil {
				continue
			}
			// projects/<project id or number>/locations/<l>/clusters/<c>/instances/<i>: the key names the project as the source does
			parts := strings.Split(x.Name, "/")
			if len(parts) != 8 || parts[2] != "locations" || parts[4] != "clusters" || parts[6] != "instances" {
				rd.Notes = append(rd.Notes, fmt.Sprintf("%s AlloyDB %s: not an instance's name (left out)", p, x.Name))
				continue
			}
			if x.InstanceType == "READ_POOL" {
				rd.Notes = append(rd.Notes, fmt.Sprintf("%s AlloyDB %s/%s: a read pool (one address balanced over its nodes): not proposed", p, parts[5], parts[7]))
				continue
			}
			host, alt := x.IPAddress, x.PublicIPAddress
			if host == "" {
				host, alt = x.PublicIPAddress, ""
			}
			if host == "" {
				rd.Notes = append(rd.Notes, fmt.Sprintf("%s AlloyDB %s: no IP address (left out)", p, x.Name))
				continue
			}
			tags := []string{"cloud:gcp", "region:" + parts[3], "project:" + p, "cluster:" + parts[5]}
			switch x.InstanceType {
			case "PRIMARY":
				tags = append(tags, "role:writer")
			case "SECONDARY":
				tags = append(tags, "role:secondary")
			}
			rd.Proposals = append(rd.Proposals, config.Proposal{Server: "gcp:" + p + ":alloydb:" + parts[3] + "/" + parts[5] + "/" + parts[7], Engine: config.EnginePostgres, Platform: "alloydb",
				Host: host, AltHost: alt, Port: 5432, DBName: "postgres", DisplayName: parts[5] + "/" + parts[7] + " (" + strings.ToLower(x.InstanceType) + ")",
				ResourceID: x.UID, Tags: sortedTags(tags...), CloudTags: x.Labels})
		}
	}
	rd.TagKeys = tagKeysOf(rd.Proposals)
	sort.Strings(rd.Unseen)
	sort.Slice(rd.Proposals, func(i, j int) bool { return rd.Proposals[i].Server < rd.Proposals[j].Server })
	if err := ctx.Err(); err != nil {
		return Read{Notes: rd.Notes}, fmt.Errorf("the GCP read was cut: %w", err)
	}
	if read == 0 {
		return Read{Notes: rd.Notes}, fmt.Errorf("no project could be read (%s)", strings.Join(rd.Notes, "; "))
	}
	return rd, nil
}
