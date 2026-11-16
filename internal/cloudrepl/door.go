package cloudrepl

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// Which names the door an instance's configuration opens for the provider replica read: "aws" (P1: the aws: block's
// replicas switch with its db_instance; off by default, decision Q8) or "gcp" (P2: a gcp: block), else "" and why.
func Which(in config.Instance) (provider, why string) {
	switch {
	case in.GCP != nil:
		return "gcp", ""
	case in.AWS != nil && in.AWS.Replicas && strings.TrimSpace(in.AWS.DBInstance) != "":
		return "aws", ""
	case in.AWS != nil:
		return "", "the aws: block's replicas switch is off (aws.replicas: true opens the provider replica door, P1)"
	}
	return "", "no aws: block with replicas: true and no gcp: block in the config: the provider replicas are not read"
}

// Door is the process's provider replica door for both engines' collections (cloud_replicas, mssql_cloud_replicas): an
// AWS reader per profile (its region clients and the run's listings shared by the instances of a run: the design fold
// 15), a Google reader per credentials file (its token), and a throttled door resting until its next interval.
type Door struct {
	NewAWS func(profile string) *AWSReader
	NewGCP func(credentialsFile string) (*GCPReader, error)
	Region func(ctx context.Context, profile string) (string, error) // the profile's region when the aws: block names none
	Now    func() time.Time

	mu    sync.Mutex
	aws   map[string]*AWSReader
	gcp   map[string]*GCPReader
	gcpAt map[string]time.Time // each reader's credentials file modification time at its build
	held  map[string]held
}

type held struct {
	until time.Time
	why   string
}

// Default is the door the collections use.
var Default = &Door{NewAWS: newAWSReader, NewGCP: NewGCPReader, Region: profileRegion, Now: time.Now}

// restFor: a throttled door rests this long (the collection runs every 5 minutes: the rest of this run and the
// run's other instances, never the next run)
const restFor = awsListAge

// Rows is one read of the instance's door as the import's rows: a 'read' row first (provider, resource_id = the
// instance's own, notes = the sentences of the calls refused or failed), then a 'resource' row per resource and a
// 'point' row per datapoint and a 'failover' row per phase of the instance's own provider failover (P3); a read with
// notes adds a collector_error row (the run is partial). A throttle is a read
// with its sentence and no call until the door's rest ends. A read that cannot start is an error on Google (no
// Application Default Credentials, a credentials file refused: NewGCPReader) - the collection fails and its 'collection
// failing' finding speaks; on AWS the SDK resolves its credentials at each call, so no credentials is a refused call:
// a note, a partial run and the 'cloud door failing' finding after 3 reads (390b review part a, finding 9).
func (d *Door) Rows(ctx context.Context, in config.Instance) ([]map[string]any, error) {
	provider, why := Which(in)
	var self, key string
	var read func() ([]Resource, []Point, []string, error)
	var failovers func() ([]Failover, error)
	// selfOf: the instance's own key once known (GCP: from the block; AWS: the listing's ARN or the caller identity's)
	selfOf := func() (string, error) { return self, nil }
	switch provider {
	case "aws":
		region := strings.TrimSpace(in.AWS.Region)
		if region == "" {
			r, err := d.Region(ctx, in.AWS.Profile)
			if err != nil {
				return nil, err
			}
			region = r
		}
		ident := strings.ToLower(strings.TrimSpace(in.AWS.DBInstance))
		key = "aws|" + in.AWS.Profile + "|" + region
		r := d.awsReader(in.AWS.Profile)
		read = func() ([]Resource, []Point, []string, error) { return r.Read(ctx, region, ident) }
		selfOf = func() (string, error) {
			s, err := r.selfID(ctx, region, ident)
			if err != nil {
				return "", fmt.Errorf("the provider replica read cannot name the instance's own resource (its ARN): %v", err)
			}
			return s, nil
		}
		failovers = func() ([]Failover, error) { return r.Failovers(ctx, region, ident, self) }
	case "gcp":
		self, key = in.GCP.ResourceID(), "gcp|"+in.GCP.CredentialsFile+"|"+strings.ToLower(in.GCP.Project)
		r, err := d.gcpReader(in.GCP.CredentialsFile)
		if err != nil {
			return nil, err
		}
		read = func() ([]Resource, []Point, []string, error) { return r.Read(ctx, in.GCP.Project, in.GCP.Instance) }
		failovers = func() ([]Failover, error) { return r.Failovers(ctx, in.GCP.Project, in.GCP.Instance) }
	default:
		return nil, errors.New(why)
	}
	if w, ok := d.resting(key); ok {
		var err error
		if self, err = selfOf(); err != nil {
			return nil, err
		}
		return noteRows(provider, self, []string{w}), nil
	}
	res, pts, notes, err := read()
	var th *Throttled
	if errors.As(err, &th) {
		w := th.Error()
		d.rest(key, w)
		if self, err = selfOf(); err != nil {
			return nil, err
		}
		return noteRows(provider, self, []string{w}), nil
	}
	if err != nil {
		return nil, err
	}
	if self, err = selfOf(); err != nil {
		return nil, err
	}
	// P3: the instance's own failover events under the same door; a refusal or a throttle is a note, the read stands
	fs, ferr := failovers()
	if errors.As(ferr, &th) {
		d.rest(key, th.Error())
		notes = append(notes, th.Error())
	} else if ferr != nil {
		notes = append(notes, ferr.Error())
	}
	rows := noteRows(provider, self, notes)
	head := rows[0]
	rows = rows[1:]
	for _, x := range res {
		ids := x.ReplicaIDs
		if ids == nil {
			ids = []string{}
		}
		rows = append(rows, map[string]any{"kind": "resource", "provider": x.Provider, "resource_id": x.ID, "engine": x.Engine,
			"region": x.Region, "role": x.Role, "source_id": x.SourceID, "replica_ids": ids, "cascaded": x.Cascaded,
			"status": x.Status, "repl_status": x.ReplStatus, "repl_note": x.ReplNote})
	}
	for _, p := range pts {
		rows = append(rows, map[string]any{"kind": "point", "provider": provider, "resource_id": p.ResourceID, "metric": p.Metric,
			"unit": p.Unit, "at": p.At.UTC().Format(time.RFC3339), "value": p.Value})
	}
	for _, f := range fs {
		rows = append(rows, map[string]any{"kind": "failover", "provider": provider, "resource_id": f.ResourceID, "at": f.At.UTC().Format(time.RFC3339),
			"phase": f.Phase, "message": f.Message, "source": f.Source, "event_id": f.ID})
	}
	return append([]map[string]any{head}, rows...), nil
}

// noteRows: the read row, and a collector_error row when the read has notes
func noteRows(provider, self string, notes []string) []map[string]any {
	if notes == nil {
		notes = []string{}
	}
	rows := []map[string]any{{"kind": "read", "provider": provider, "resource_id": self, "notes": notes}}
	if len(notes) > 0 {
		rows = append(rows, map[string]any{"kind": "collector_error", "source": "cloud_replicas:" + provider, "message": strings.Join(notes, "; ")})
	}
	return rows
}

func (d *Door) resting(key string) (string, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	h, ok := d.held[key]
	if !ok || !d.Now().Before(h.until) {
		delete(d.held, key)
		return "", false
	}
	return h.why + " (the door rests until " + h.until.UTC().Format("15:04:05") + " UTC)", true
}

func (d *Door) rest(key, why string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.held == nil {
		d.held = map[string]held{}
	}
	d.held[key] = held{until: d.Now().Add(restFor), why: why}
}

func (d *Door) awsReader(profile string) *AWSReader {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.aws == nil {
		d.aws = map[string]*AWSReader{}
	}
	r, ok := d.aws[profile]
	if !ok {
		r = d.NewAWS(profile)
		d.aws[profile] = r
	}
	return r
}

// gcpReader: one reader per credentials file, built again when the file's modification time moves (a rotated key
// written over the same path: 390b review part a, finding 10); an error is not kept: the next run tries again
func (d *Door) gcpReader(file string) (*GCPReader, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.gcp == nil {
		d.gcp = map[string]*GCPReader{}
		d.gcpAt = map[string]time.Time{}
	}
	var mod time.Time
	if file != "" {
		if st, err := os.Stat(file); err == nil {
			mod = st.ModTime()
		}
	}
	if r, ok := d.gcp[file]; ok && d.gcpAt[file].Equal(mod) {
		return r, nil
	}
	r, err := d.NewGCP(file)
	if err != nil {
		return nil, err
	}
	d.gcp[file], d.gcpAt[file] = r, mod
	return r, nil
}

// loadAWS: the SDK's credential chain for a profile in a region (environment, the profile, `aws login`, the
// instance role), as the io and logs collections load it
func loadAWS(ctx context.Context, profile, region string) (aws.Config, error) {
	opts := []func(*awsconfig.LoadOptions) error{}
	if region != "" {
		opts = append(opts, awsconfig.WithRegion(region))
	}
	if profile != "" {
		opts = append(opts, awsconfig.WithSharedConfigProfile(profile))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return aws.Config{}, fmt.Errorf("aws config: %w", err)
	}
	return cfg, nil
}

// profileRegion: the region the profile (or the environment) names
func profileRegion(ctx context.Context, profile string) (string, error) {
	cfg, err := loadAWS(ctx, profile, "")
	if err != nil {
		return "", err
	}
	if cfg.Region == "" {
		return "", errors.New("the aws: block names no region and neither its profile nor the environment does (aws.region)")
	}
	return cfg.Region, nil
}

// newAWSReader: P1's clients for a profile, one RDS and one CloudWatch client per region, kept for the process
func newAWSReader(profile string) *AWSReader {
	var mu sync.Mutex
	cfgs := map[string]aws.Config{}
	cfgFor := func(ctx context.Context, region string) (aws.Config, error) {
		mu.Lock()
		defer mu.Unlock()
		if c, ok := cfgs[region]; ok {
			return c, nil
		}
		c, err := loadAWS(ctx, profile, region)
		if err == nil {
			cfgs[region] = c
		}
		return c, err
	}
	return &AWSReader{
		RDS: func(ctx context.Context, region string) (RDSAPI, error) {
			c, err := cfgFor(ctx, region)
			if err != nil {
				return nil, err
			}
			return rds.NewFromConfig(c), nil
		},
		CW: func(ctx context.Context, region string) (CWAPI, error) {
			c, err := cfgFor(ctx, region)
			if err != nil {
				return nil, err
			}
			return cloudwatch.NewFromConfig(c), nil
		},
		Events: func(ctx context.Context, region string) (RDSEventsAPI, error) {
			c, err := cfgFor(ctx, region)
			if err != nil {
				return nil, err
			}
			return rds.NewFromConfig(c), nil
		},
		// the credential's partition (its own ARN's second field) and account: no IAM right is needed for it
		Caller: func(ctx context.Context, region string) (string, string, error) {
			c, err := cfgFor(ctx, region)
			if err != nil {
				return "", "", err
			}
			out, err := sts.NewFromConfig(c).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
			if err != nil {
				return "", "", err
			}
			p := strings.Split(aws.ToString(out.Arn), ":")
			if len(p) < 5 {
				return "", "", fmt.Errorf("the caller's ARN %q has no partition", aws.ToString(out.Arn))
			}
			return p[1], aws.ToString(out.Account), nil
		},
		Now: time.Now,
	}
}
