package cloudrepl

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

const (
	// gcpWindow: each run reads the last 15 minutes of Cloud Monitoring (three of the collection's intervals; the
	// import keeps one row per datapoint)
	gcpWindow = 15 * time.Minute
	// gcpScope: the one OAuth scope; what the identity may read is its IAM roles' (cloudsql.instances.get,
	// monitoring.timeSeries.list)
	gcpScope = "https://www.googleapis.com/auth/cloud-platform"
	// gcpMaxBody: no answer of either API this reader asks for comes near it
	gcpMaxBody = 8 << 20

	metricLag      = "cloudsql.googleapis.com/database/replication/replica_lag"
	metricState    = "cloudsql.googleapis.com/database/replication/state"
	metricByteLag  = "cloudsql.googleapis.com/database/postgresql/replication/replica_byte_lag"
	byteLagReplay  = "replay_location"
	callAdminGet   = "cloudsql.instances.get"
	callMonitoring = "monitoring.timeSeries.list"
	callOperations = "cloudsql operations.list"
)

// GCPReader is P2: Cloud SQL Admin (instances.get) for the topology and status, Cloud Monitoring (timeSeries.list)
// for each replica's lag, replication state and byte lag, over REST with an OAuth client. Build it once a process
// (NewGCPReader): its client holds the token and refreshes it.
type GCPReader struct {
	HTTP          *http.Client
	AdminURL      string // https://sqladmin.googleapis.com
	MonitoringURL string // https://monitoring.googleapis.com
	Now           func() time.Time
}

// NewGCPReader builds the reader from Application Default Credentials (GOOGLE_APPLICATION_CREDENTIALS, gcloud's application-default
// sign-in, the attached service account through the metadata server), or the file the gcp: block's credentials_file
// names - a service account key or a workload identity federation file, nothing else (the file is the host
// administrator's, read as such).
func NewGCPReader(credentialsFile string) (*GCPReader, error) {
	ctx := gcpTokenContext() // the token source keeps it for every refresh: never a run's context
	var creds *google.Credentials
	var err error
	if f := strings.TrimSpace(credentialsFile); f != "" {
		b, rerr := os.ReadFile(f)
		if rerr != nil {
			return nil, fmt.Errorf("the gcp: block's credentials_file: %w", rerr)
		}
		var head struct {
			Type string `json:"type"`
		}
		if jerr := json.Unmarshal(b, &head); jerr != nil {
			return nil, fmt.Errorf("the gcp: block's credentials_file %s is not a credentials JSON file: %v", f, jerr)
		}
		switch google.CredentialsType(head.Type) {
		case google.ServiceAccount, google.ExternalAccount:
			creds, err = google.CredentialsFromJSONWithType(ctx, b, google.CredentialsType(head.Type), gcpScope)
		default:
			return nil, fmt.Errorf("the gcp: block's credentials_file %s is of type %q: pgvigil takes a service account key (service_account) or a workload identity federation file (external_account)", f, head.Type)
		}
	} else {
		creds, err = google.FindDefaultCredentials(ctx, gcpScope)
	}
	if err != nil {
		return nil, fmt.Errorf("google credentials: %w", err)
	}
	client := oauth2.NewClient(ctx, creds.TokenSource)
	client.Timeout = 30 * time.Second
	return &GCPReader{HTTP: client, AdminURL: "https://sqladmin.googleapis.com", MonitoringURL: "https://monitoring.googleapis.com", Now: time.Now}, nil
}

// gcpTokenContext is the token source's context: a 30 s client for the token fetch itself (oauth2.Transport does not
// pass a request's context to it - a token endpoint that accepts and never answers would hang the run and, under the
// token source's lock, every later read on that credentials file)
func gcpTokenContext() context.Context {
	return context.WithValue(context.Background(), oauth2.HTTPClient, &http.Client{Timeout: 30 * time.Second})
}

// gcpInstance: the fields of a Cloud SQL Admin DatabaseInstance this reader uses
type gcpInstance struct {
	Name               string   `json:"name"`
	Project            string   `json:"project"`
	Region             string   `json:"region"`
	DatabaseVersion    string   `json:"databaseVersion"`
	State              string   `json:"state"`
	MasterInstanceName string   `json:"masterInstanceName"`
	ReplicaNames       []string `json:"replicaNames"`
}

// gcpRef: an instance as Cloud SQL names it - project:instance, or a bare name in the reader's project
func gcpRef(ref, project string) (proj, name string) {
	// split at the LAST colon: a domain-scoped project is 'example.com:proj'
	if i := strings.LastIndex(ref, ":"); i > 0 {
		return ref[:i], ref[i+1:]
	}
	return project, ref
}

func gcpID(project, name string) string { return strings.ToLower(project + ":" + name) }

// Read is one instance's read: its own resource, its direct source and replicas (each by instances.get), each
// replica's replica_lag and replication state on its own resource and its replica_byte_lag (replay_location) on its
// source's. A refused instances.get of the instance itself still reads its own lag (it may be a replica) with the
// sentence as a note; a refused Monitoring call keeps the topology with its sentence; a throttle is *Throttled.
func (g *GCPReader) Read(ctx context.Context, project, instance string) ([]Resource, []Point, []string, error) {
	project, instance = strings.TrimSpace(project), strings.TrimSpace(instance)
	var notes []string
	mon := &gcpMon{g: g}
	self, err := g.get(ctx, project, instance)
	if err != nil {
		var th *Throttled
		var nf *gcpNotFound
		switch {
		case errors.As(err, &th):
			return nil, nil, nil, err
		case errors.As(err, &nf):
			return nil, nil, nil, fmt.Errorf("the Cloud SQL instance %s:%s is not found (the gcp: block's project and instance)", project, instance)
		}
		notes = append(notes, err.Error())
		pts, _, err := mon.replica(ctx, project, instance)
		if err != nil {
			return nil, nil, nil, err
		}
		return nil, pts, append(notes, mon.notes...), nil
	}
	res := []*Resource{gcpResource(self, project)}
	type link struct{ srcProject, src, project, name string }
	var links []link // replica <- direct source, each read once
	if self.MasterInstanceName != "" {
		sp, sn := gcpRef(self.MasterInstanceName, project)
		links = append(links, link{sp, sn, project, instance})
		if s, err := g.get(ctx, sp, sn); err == nil {
			res = append(res, gcpResource(s, sp))
		} else if errors.As(err, new(*Throttled)) {
			return nil, nil, nil, err
		} else {
			notes = append(notes, err.Error())
		}
	}
	for _, ref := range self.ReplicaNames {
		rp, rn := gcpRef(ref, project)
		links = append(links, link{project, instance, rp, rn})
		if x, err := g.get(ctx, rp, rn); err == nil {
			res = append(res, gcpResource(x, rp))
		} else if errors.As(err, new(*Throttled)) {
			return nil, nil, nil, err
		} else {
			notes = append(notes, err.Error())
		}
	}
	byID := map[string]*Resource{}
	for _, r := range res {
		byID[r.ID] = r
	}
	var pts []Point
	bySource := map[string]map[string]string{} // source id: its replicas, replica_name -> the replica's id
	srcOf := map[string][2]string{}            // source id: project, name
	for _, l := range links {
		p, state, err := mon.replica(ctx, l.project, l.name)
		if err != nil {
			return nil, nil, nil, err
		}
		pts = append(pts, p...)
		if r := byID[gcpID(l.project, l.name)]; r != nil && state != "" {
			r.ReplStatus = state
			if !strings.EqualFold(state, "Running") {
				r.ReplNote = "Cloud Monitoring's " + metricState + " reads " + state
			}
		}
		sid := gcpID(l.srcProject, l.src)
		if bySource[sid] == nil {
			bySource[sid] = map[string]string{}
		}
		bySource[sid][strings.ToLower(l.name)] = gcpID(l.project, l.name)
		srcOf[sid] = [2]string{l.srcProject, l.src}
	}
	for sid, replicas := range bySource {
		p, err := mon.byteLag(ctx, srcOf[sid][0], srcOf[sid][1], replicas)
		if err != nil {
			return nil, nil, nil, err
		}
		pts = append(pts, p...)
	}
	out := make([]Resource, len(res))
	for i, r := range res {
		out[i] = *r
	}
	return out, pts, append(notes, mon.notes...), nil
}

// gcpResource: one Cloud SQL instance's topology and status
func gcpResource(in gcpInstance, project string) *Resource {
	if in.Project != "" {
		project = in.Project
	}
	x := &Resource{Provider: "gcp", ID: gcpID(project, in.Name), Engine: in.DatabaseVersion, Region: in.Region, Status: in.State}
	if in.MasterInstanceName != "" {
		sp, sn := gcpRef(in.MasterInstanceName, project)
		x.SourceID = gcpID(sp, sn)
	}
	for _, ref := range in.ReplicaNames {
		rp, rn := gcpRef(ref, project)
		x.ReplicaIDs = append(x.ReplicaIDs, gcpID(rp, rn))
	}
	switch {
	case x.SourceID != "":
		x.Role, x.Cascaded = "replica", len(x.ReplicaIDs) > 0
	case len(x.ReplicaIDs) > 0:
		x.Role = "source"
	default:
		x.Role = "standalone"
	}
	return x
}

// get: Cloud SQL Admin instances.get
func (g *GCPReader) get(ctx context.Context, project, name string) (gcpInstance, error) {
	u := strings.TrimRight(g.AdminURL, "/") + "/v1/projects/" + url.PathEscape(project) + "/instances/" + url.PathEscape(name)
	var in gcpInstance
	err := g.call(ctx, callAdminGet, project, u, &in)
	return in, err
}

// gcpMon: one read's Monitoring calls - after the first refusal the read makes no more of them (the same identity,
// the same answer), its sentence kept once
type gcpMon struct {
	g     *GCPReader
	off   bool
	notes []string
}

// replica: a replica's replica_lag points and its newest replication state, on its own cloudsql_database resource
func (m *gcpMon) replica(ctx context.Context, project, name string) ([]Point, string, error) {
	id := gcpID(project, name)
	var pts []Point
	series, err := m.list(ctx, project, metricLag, id)
	if err != nil || series == nil {
		return nil, "", err
	}
	for _, s := range series {
		for _, p := range s.Points {
			// below 0 = 'replication is inactive' (Google's metrics page): the state says Stopped or Error, the lag is
			// not a number of seconds
			if v, ok := p.Value.number(); ok && v >= 0 {
				pts = append(pts, Point{ResourceID: id, Metric: "replica_lag", Unit: "s", At: p.Interval.EndTime.UTC(), Value: v})
			}
		}
	}
	series, err = m.list(ctx, project, metricState, id)
	if err != nil {
		return nil, "", err
	}
	var state string
	var at time.Time
	for _, s := range series {
		for _, p := range s.Points {
			if p.Value.BoolValue != nil && *p.Value.BoolValue && p.Interval.EndTime.After(at) {
				state, at = s.Metric.Labels["state"], p.Interval.EndTime
			}
		}
	}
	return pts, state, nil
}

// byteLag: the source's replica_byte_lag per replica_name (replay_location only), each point the replica's (replicas:
// replica_name -> the replica's id, a replica in another project named by its own)
func (m *gcpMon) byteLag(ctx context.Context, project, source string, replicas map[string]string) ([]Point, error) {
	series, err := m.list(ctx, project, metricByteLag, gcpID(project, source))
	if err != nil || series == nil {
		return nil, err
	}
	var pts []Point
	var unmatched []string
	for _, s := range series {
		if s.Metric.Labels["replica_lag_type"] != byteLagReplay {
			continue
		}
		// the label's form is not documented ('Name of the replica'): matched whole, then after its last ':'; a
		// series naming no replica of this read is said once
		label := strings.ToLower(s.Metric.Labels["replica_name"])
		id, ok := replicas[label]
		if !ok {
			if i := strings.LastIndex(label, ":"); i >= 0 {
				id, ok = replicas[label[i+1:]]
			}
		}
		if !ok {
			unmatched = append(unmatched, s.Metric.Labels["replica_name"])
			continue
		}
		for _, p := range s.Points {
			if v, ok := p.Value.number(); ok {
				pts = append(pts, Point{ResourceID: id, Metric: "replica_byte_lag", Unit: "bytes", At: p.Interval.EndTime.UTC(), Value: v})
			}
		}
	}
	if len(unmatched) > 0 {
		m.notes = append(m.notes, fmt.Sprintf("replica_byte_lag on %s names replicas this read does not hold (%s): their byte lag is not stored", gcpID(project, source), strings.Join(unmatched, ", ")))
	}
	return pts, nil
}

type gcpSeries struct {
	Metric struct {
		Labels map[string]string `json:"labels"`
	} `json:"metric"`
	Resource struct {
		Labels map[string]string `json:"labels"`
	} `json:"resource"`
	Points []struct {
		Interval struct {
			EndTime time.Time `json:"endTime"`
		} `json:"interval"`
		Value gcpValue `json:"value"`
	} `json:"points"`
}

type gcpValue struct {
	DoubleValue *float64        `json:"doubleValue"`
	Int64Value  json.RawMessage `json:"int64Value"` // a string in the REST answer ("4096")
	BoolValue   *bool           `json:"boolValue"`
}

func (v gcpValue) number() (float64, bool) {
	if v.DoubleValue != nil {
		return *v.DoubleValue, true
	}
	if len(v.Int64Value) > 0 {
		f, err := strconv.ParseFloat(strings.Trim(string(v.Int64Value), `"`), 64)
		return f, err == nil
	}
	return 0, false
}

// list: timeSeries.list of one metric on one cloudsql_database over the window, every page; nil, nil = Monitoring is
// off for this read (refused earlier)
func (m *gcpMon) list(ctx context.Context, project, metric, databaseID string) ([]gcpSeries, error) {
	if m.off {
		return nil, nil
	}
	end := m.g.Now().UTC().Truncate(time.Minute)
	q := url.Values{}
	q.Set("filter", fmt.Sprintf(`metric.type = %q AND resource.type = "cloudsql_database" AND resource.labels.database_id = %q`, metric, databaseID))
	q.Set("interval.startTime", end.Add(-gcpWindow).Format(time.RFC3339))
	q.Set("interval.endTime", end.Format(time.RFC3339))
	base := strings.TrimRight(m.g.MonitoringURL, "/") + "/v3/projects/" + url.PathEscape(project) + "/timeSeries"
	var out []gcpSeries
	for page := 0; page < 50; page++ {
		var res struct {
			TimeSeries    []gcpSeries `json:"timeSeries"`
			NextPageToken string      `json:"nextPageToken"`
		}
		if err := m.g.call(ctx, callMonitoring, project, base+"?"+q.Encode(), &res); err != nil {
			if errors.As(err, new(*Throttled)) {
				return nil, err
			}
			m.off, m.notes = true, append(m.notes, err.Error())
			return nil, nil
		}
		out = append(out, res.TimeSeries...)
		if res.NextPageToken == "" {
			break
		}
		q.Set("pageToken", res.NextPageToken)
	}
	if out == nil {
		out = []gcpSeries{}
	}
	return out, nil
}

// gcpNotFound: instances.get's 404
type gcpNotFound struct{ msg string }

func (e *gcpNotFound) Error() string { return e.msg }

// call: one GET, its JSON into out; a refusal in words (the call, the project, the status and Google's message, the
// right), a 429 or RESOURCE_EXHAUSTED *Throttled
func (g *GCPReader) call(ctx context.Context, call, project, u string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := g.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("%s in project %s: %w", call, project, err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, gcpMaxBody))
	if err != nil {
		return fmt.Errorf("%s in project %s: %w", call, project, err)
	}
	if resp.StatusCode == http.StatusOK {
		if err := json.NewDecoder(bytes.NewReader(body)).Decode(out); err != nil {
			return fmt.Errorf("%s in project %s: the answer is not the expected JSON: %v", call, project, err)
		}
		return nil
	}
	var ge struct {
		Error struct {
			Message string `json:"message"`
			Status  string `json:"status"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &ge) // a body that is not Google's error JSON leaves the status alone
	code := strconv.Itoa(resp.StatusCode)
	if ge.Error.Status != "" {
		code += " " + ge.Error.Status
	}
	msg := ge.Error.Message
	if msg == "" {
		msg = http.StatusText(resp.StatusCode)
	}
	switch {
	case resp.StatusCode == http.StatusTooManyRequests || ge.Error.Status == "RESOURCE_EXHAUSTED":
		return &Throttled{Door: call + " in project " + project, Code: code, Message: msg}
	case resp.StatusCode == http.StatusNotFound && call == callAdminGet:
		return &gcpNotFound{msg: fmt.Sprintf("%s in project %s: not found (%s)", call, project, msg)}
	case resp.StatusCode == http.StatusUnauthorized:
		// the credential itself: never worded as a missing right
		return fmt.Errorf("%s in project %s refused (%s: %s): the sign-in was refused or has expired", call, project, code, msg)
	case resp.StatusCode == http.StatusForbidden:
		return fmt.Errorf("%s in project %s refused (%s: %s): the identity needs %s", call, project, code, msg, gcpNeeds(call))
	}
	return fmt.Errorf("%s in project %s failed (%s: %s)", call, project, code, msg)
}

// gcpNeeds: the right a call needs, in words (Google's IAM permissions table, read 2026-11-15)
func gcpNeeds(call string) string {
	switch call {
	case callMonitoring:
		return "monitoring.timeSeries.list (roles/monitoring.viewer)"
	case callOperations:
		return "cloudsql.instances.get and cloudsql.instances.list (Google's table names both for operations.list; roles/cloudsql.viewer)"
	}
	return "cloudsql.instances.get (roles/cloudsql.viewer)"
}
