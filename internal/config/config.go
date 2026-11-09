// Package config reads pgvigil.yaml.
//
// Secrets never sit in the file: a DSN (or any value) may be written as
// "env:NAME" (read from the environment) or "file:/path" (read from a file,
// trailing newline trimmed). A plain value is used as is.
package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config is the whole file.
type Config struct {
	Repository Repository `yaml:"repository"`
	Instances  []Instance `yaml:"instances"`
	// Schedules overrides the default interval of a collection for every instance,
	// e.g. activity: 30s. An instance's own Schedules override these.
	Schedules map[string]Duration `yaml:"schedules"`
	// QueryText says what statement text the repository may hold: full (default; credentials
	// always masked), normalized (every literal replaced by ?), none (no statement text at all,
	// only hashes and counters). An instance's own query_text overrides it.
	QueryText string `yaml:"query_text"`
	// Flags carries command-line choices; never read from the file.
	Flags Flags `yaml:"-"`
}

// Repository is the pgvigil database that holds the collected data.
type Repository struct {
	DSNRaw string `yaml:"dsn"`
}

// DSN resolves the repository connection string.
func (r Repository) DSN() string { return Resolve(r.DSNRaw) }

// Instance is one monitored PostgreSQL server (one endpoint; a writer and a
// reader of the same cluster are two instances).
type Instance struct {
	Name string `yaml:"name"`
	// DSNRaw is a libpq keyword/value or URL connection string, or env:/file: indirection.
	DSNRaw string `yaml:"dsn"`
	// Platform is auto (default), onprem, rds, aurora, azure, cloudsql or alloydb.
	Platform  string              `yaml:"platform"`
	Tags      []string            `yaml:"tags"`
	Schedules map[string]Duration `yaml:"schedules"`
	// Disabled lists collections that never run on this instance.
	Disabled []string `yaml:"disabled"`
	// QueryText overrides the file-level query_text for this instance (full | normalized | none);
	// Validate fills it from the file-level value when empty.
	QueryText string `yaml:"query_text"`
	// AWS names the RDS / Aurora resource for the log reader (CloudWatch Logs); nil = no AWS door.
	AWS *AWS `yaml:"aws"`
}

// AWS is an instance's door to its cloud side. Credentials come from the SDK's usual chain
// (environment, shared config profile incl. an `aws login` session, instance role); none are stored here.
type AWS struct {
	Region     string `yaml:"region"`
	Profile    string `yaml:"profile"`
	Cluster    string `yaml:"cluster"`     // Aurora: the DB cluster identifier
	DBInstance string `yaml:"db_instance"` // RDS: the DB instance identifier
	LogGroup   string `yaml:"log_group"`   // override; default /aws/rds/{cluster|instance}/<id>/postgresql
	// DMS names the replication tasks whose state rides on this instance (the tasks that feed it or read
	// from it); nil = the dms collection skips this instance.
	DMS *DMS `yaml:"dms"`
}

// DMS is the AWS DMS part of an instance's AWS door: which replication tasks to read and the latency
// threshold the overview check applies to them.
type DMS struct {
	// Tasks lists replication task identifiers (or ARNs); "*" = every task the profile sees in the region.
	Tasks []string `yaml:"tasks"`
	// LatencyWarnSecs is the CDC latency (source or target, seconds) above which the overview warns; 0 = 300.
	LatencyWarnSecs int `yaml:"latency_warn_secs"`
}

// LatencyWarn returns the configured threshold or its default.
func (d *DMS) LatencyWarn() int {
	if d == nil || d.LatencyWarnSecs <= 0 {
		return 300
	}
	return d.LatencyWarnSecs
}

// PostgresLogGroup is the CloudWatch log group RDS exports the postgresql log to.
func (a AWS) PostgresLogGroup() string {
	switch {
	case a.LogGroup != "":
		return a.LogGroup
	case a.Cluster != "":
		return "/aws/rds/cluster/" + a.Cluster + "/postgresql"
	case a.DBInstance != "":
		return "/aws/rds/instance/" + a.DBInstance + "/postgresql"
	}
	return ""
}

// DSN resolves the instance connection string.
func (i Instance) DSN() string { return Resolve(i.DSNRaw) }

// Flags are command-line values.
type Flags struct {
	Once     string
	Instance string
}

// Duration parses "30s", "1m", "1h" or "disabled" (zero) from YAML.
type Duration struct{ time.Duration }

// UnmarshalYAML implements yaml.Unmarshaler.
func (d *Duration) UnmarshalYAML(n *yaml.Node) error {
	s := strings.TrimSpace(n.Value)
	if s == "" || strings.EqualFold(s, "disabled") || s == "0" {
		d.Duration = 0
		return nil
	}
	v, err := time.ParseDuration(s)
	if err != nil {
		return fmt.Errorf("schedule %q: %w", s, err)
	}
	d.Duration = v
	return nil
}

// Load reads and validates the file.
func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	var c Config
	if err := yaml.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	return &c, nil
}

// Validate checks the shape, not connectivity. An empty instance list is valid
// (a host that only serves the UI); the collector commands require one.
func (c *Config) Validate() error {
	if strings.TrimSpace(c.Repository.DSNRaw) == "" {
		return fmt.Errorf("repository.dsn is required")
	}
	if c.QueryText == "" {
		c.QueryText = "full"
	}
	if !validQueryText(c.QueryText) {
		return fmt.Errorf("query_text must be full, normalized or none (got %q)", c.QueryText)
	}
	seen := map[string]bool{}
	for i := range c.Instances {
		in := &c.Instances[i]
		if strings.TrimSpace(in.Name) == "" {
			return fmt.Errorf("instances[%d]: name is required", i)
		}
		if seen[in.Name] {
			return fmt.Errorf("instance %q is listed twice", in.Name)
		}
		seen[in.Name] = true
		if strings.TrimSpace(in.DSNRaw) == "" {
			return fmt.Errorf("instance %q: dsn is required", in.Name)
		}
		if in.Platform == "" {
			in.Platform = "auto"
		}
		if in.QueryText == "" {
			in.QueryText = c.QueryText
		}
		if !validQueryText(in.QueryText) {
			return fmt.Errorf("instance %q: query_text must be full, normalized or none (got %q)", in.Name, in.QueryText)
		}
		switch in.Platform {
		case "auto", "onprem", "rds", "aurora", "azure", "cloudsql", "alloydb":
		default:
			return fmt.Errorf("instance %q: unknown platform %q", in.Name, in.Platform)
		}
		if in.AWS != nil && in.AWS.DMS != nil {
			for _, t := range in.AWS.DMS.Tasks {
				if strings.TrimSpace(t) == "" {
					return fmt.Errorf("instance %q: aws.dms.tasks holds an empty name", in.Name)
				}
			}
			if in.AWS.DMS.LatencyWarnSecs < 0 {
				return fmt.Errorf("instance %q: aws.dms.latency_warn_secs must be 0 or more", in.Name)
			}
		}
	}
	return nil
}

func validQueryText(v string) bool { return v == "full" || v == "normalized" || v == "none" }

// Resolve applies the env:/file: indirection.
func Resolve(v string) string {
	switch {
	case strings.HasPrefix(v, "env:"):
		return os.Getenv(strings.TrimPrefix(v, "env:"))
	case strings.HasPrefix(v, "file:"):
		b, err := os.ReadFile(strings.TrimPrefix(v, "file:"))
		if err != nil {
			return ""
		}
		return strings.TrimRight(string(b), "\r\n")
	default:
		return v
	}
}

// Interval returns the effective interval of a collection for an instance:
// the instance's override, then the global override, then the default; zero = disabled.
func (c *Config) Interval(in Instance, collection string, def time.Duration) time.Duration {
	for _, d := range in.Disabled {
		if d == collection {
			return 0
		}
	}
	if v, ok := in.Schedules[collection]; ok {
		return v.Duration
	}
	if v, ok := c.Schedules[collection]; ok {
		return v.Duration
	}
	return def
}
