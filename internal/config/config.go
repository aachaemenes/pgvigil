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
	// UI shapes the web UI's tree: the tag keys it groups by and the order of their values.
	UI UI `yaml:"ui"`
	// DBADash lists DBADash repositories (SQL Server databases) pgvigil reads with a read-only login: their SQL
	// Server instances and the statuses of DBADash's own Summary. Empty (the default) = the door is off. pgvigil
	// collects nothing from SQL Server itself.
	DBADash []DBADashRepo `yaml:"dbadash"`
	// Flags carries command-line choices; never read from the file.
	Flags Flags `yaml:"-"`
}

// Repository is the pgvigil database that holds the collected data.
type Repository struct {
	DSNRaw string `yaml:"dsn"`
}

// DSN resolves the repository connection string.
func (r Repository) DSN() string { return Resolve(r.DSNRaw) }

// The engines an instance can be.
const (
	EnginePostgres  = "postgres"
	EngineSQLServer = "sqlserver"
)

// Instance is one monitored PostgreSQL server (one endpoint; a writer and a
// reader of the same cluster are two instances).
type Instance struct {
	Name string `yaml:"name"`
	// DSNRaw is a libpq keyword/value or URL connection string, or env:/file: indirection.
	DSNRaw string `yaml:"dsn"`
	// Engine is the database engine: postgres (the default) or sqlserver. A sqlserver instance takes a go-mssqldb
	// connection string in dsn (sqlserver://login@host:1433?database=master or the ADO form); one that carries a
	// password must come through env: or file:. Only that engine's collections run on the instance.
	Engine string `yaml:"engine"`
	// Platform is auto (default), onprem, rds, aurora, azure, cloudsql or alloydb; on a sqlserver instance auto,
	// onprem, rds, azuresqldb or azuresqlmi.
	Platform string `yaml:"platform"`
	// Tags are plain words (prod) or key:value pairs (env:prod, team:billing), both in one list; a plain
	// word is the key "tag". The repository keeps them as written; 'pgvigil tag' overrides a key there.
	Tags      []string            `yaml:"tags"`
	Schedules map[string]Duration `yaml:"schedules"`
	// Disabled lists collections that never run on this instance.
	Disabled []string `yaml:"disabled"`
	// QueryText overrides the file-level query_text for this instance (full | normalized | none);
	// Validate fills it from the file-level value when empty.
	QueryText string `yaml:"query_text"`
	// AWS names the RDS / Aurora resource for the log reader (CloudWatch Logs); nil = no AWS door.
	AWS *AWS `yaml:"aws"`
	// ActionsDSNRaw is the actions door: the connection string of the login pgvigil_actions (GRANT
	// pg_signal_backend, never a superuser) the UI's Cancel and Terminate buttons use on this server.
	// Empty (the default) = no actions on this instance. Only the env:NAME and file:/path forms are
	// accepted: the password of a login that can stop sessions never sits in the file.
	ActionsDSNRaw string `yaml:"actions_dsn"`
	// Actions is the actions door's allow list: on SQL Server kill, job_start, job_stop; on PostgreSQL job_stop and
	// job_start (task 161: Stop a pg_cron / pgAgent run, pgAgent's Run now). An action not named here is off even with
	// an actions_dsn; empty (the default) = nothing. PostgreSQL's cancel and terminate need no list: its actions_dsn
	// alone turns them on.
	Actions []string `yaml:"actions"`
	// Backups tunes the backups collection's rules; nil = the defaults.
	Backups *Backups `yaml:"backups"`
	// ExplainAnalyze turns on the Plan page's EXPLAIN ANALYZE for this instance (it executes the statement: a
	// SELECT only, through explain_dsn, in a read-only transaction rolled back); false (the default) = off.
	ExplainAnalyze bool `yaml:"explain_analyze"`
	// HypoIndex turns on the suggested index's planner check (hypopg) for this instance; false (the default) = off.
	HypoIndex bool `yaml:"hypo_index"`
	// AuditText keeps the statement text and the parameters of the audit entries stored as rows for this instance
	// (PostgreSQL: pgaudit, docs/audit.md; SQL Server: SQL Server Audit, docs/sqlserver-audit.md). They can carry
	// data, so false (the default) keeps the class, the command and the object only; what is kept still passes the
	// instance's query_text policy.
	AuditText bool `yaml:"audit_text"`
	// ExplainDSNRaw is the login EXPLAIN ANALYZE runs as: SELECT grants only, never the actions login (a SELECT can
	// call pg_terminate_backend through pg_signal_backend); env:NAME or file:/path only, as actions_dsn.
	ExplainDSNRaw string `yaml:"explain_dsn"`
	// ExplainTimeout bounds one EXPLAIN ANALYZE (default 30s, at most 5m).
	ExplainTimeout Duration `yaml:"explain_timeout"`
	// PgBouncerDSNRaw is the pooler's admin console in front of this instance (dbname=pgbouncer, a stats_users
	// login: SHOW only); the pgbouncer collection reads SHOW POOLS, STATS, DATABASES and CONFIG through it. Empty
	// (the default) = no pooler: no collection, no Pooler tab, no finding.
	PgBouncerDSNRaw string `yaml:"pgbouncer"`
	// MSSQLThresholds sets the HA/DR, jobs and backups thresholds of a sqlserver instance (docs/sqlserver-hadr.md).
	MSSQLThresholds map[string]any `yaml:"mssql_thresholds"`
}

// DBADashRepo is one DBADash repository of the dbadash: list.
type DBADashRepo struct {
	// Name is the tree folder's name ("DBADash: <name>") and the repository's key in pgvigil; it must be unique.
	Name string `yaml:"name"`
	// DSNRaw is a go-mssqldb connection string to the DBADash repository database (sqlserver://login@host:1433?database=DBADashDB
	// or the ADO form "server=...;database=...;user id=..."), or env:NAME / file:/path. A string that carries a password must
	// come through env: or file:, never inline in the file.
	DSNRaw string `yaml:"dsn"`
	// Interval is how often it is read (default 5m; at least 1m).
	Interval Duration `yaml:"interval"`
}

// DefaultDBADashInterval is the read cadence of a DBADash repository.
const DefaultDBADashInterval = 5 * time.Minute

// DSN resolves the connection string; "" = an unset variable or an unreadable file.
func (d DBADashRepo) DSN() string { return Resolve(strings.TrimSpace(d.DSNRaw)) }

// Every returns the read interval.
func (d DBADashRepo) Every() time.Duration {
	if d.Interval.Duration <= 0 {
		return DefaultDBADashInterval
	}
	return d.Interval.Duration
}

// inlinePassword says whether an inline connection string carries a password: a URL's user:password@ or a password /
// pwd query key, or an ADO or ODBC segment whose key (trimmed, any case: the driver trims it so) is password or pwd.
func inlinePassword(v string) bool {
	l := strings.ToLower(strings.TrimSpace(v))
	if i := strings.Index(l, "://"); i >= 0 {
		rest := l[i+3:]
		// the authority ends at the first '/' or '?'; its userinfo is the text before its LAST '@' (a password may
		// hold '@' or '='), and a ':' there starts a password
		auth := rest
		if e := strings.IndexAny(rest, "/?"); e >= 0 {
			auth = rest[:e]
		}
		if at := strings.LastIndexByte(auth, '@'); at >= 0 {
			if strings.Contains(auth[:at], ":") {
				return true
			}
		} else if at := strings.IndexByte(rest, '@'); at >= 0 && strings.Contains(rest[:at], ":") {
			// no '@' in the authority: a raw password holding '/' or '?' cut it short (sa:pa/ss@host). The text
			// before the first '@' is then userinfo unless its first '=' follows a '?': that is an '@' inside a
			// query value (host:1433?user+id=a@corp.com)
			seg := rest[:at]
			eq, qm := strings.IndexByte(seg, '='), strings.IndexByte(seg, '?')
			if eq < 0 || qm < 0 || qm > eq {
				return true
			}
		}
		if q := strings.IndexByte(rest, '?'); q >= 0 {
			for _, kv := range strings.FieldsFunc(rest[q+1:], func(r rune) bool { return r == '&' || r == ';' }) {
				k, _, _ := strings.Cut(kv, "=")
				if k = strings.TrimSpace(k); k == "password" || k == "pwd" {
					return true
				}
			}
		}
		return false
	}
	l = strings.TrimPrefix(l, "odbc:")
	for _, seg := range strings.Split(l, ";") {
		k, _, ok := strings.Cut(seg, "=")
		if k = strings.TrimSpace(k); ok && (k == "password" || k == "pwd") {
			return true
		}
	}
	return false
}

func (c *Config) validateDBADash() error {
	names := map[string]bool{}
	for i := range c.DBADash {
		d := &c.DBADash[i]
		d.Name = strings.TrimSpace(d.Name)
		if d.Name == "" {
			return fmt.Errorf("dbadash[%d]: name is required", i)
		}
		if len(d.Name) > 100 || strings.ContainsAny(d.Name, "\t\r\n/") {
			return fmt.Errorf("dbadash %q: the name must be at most 100 characters, without '/' or a control character", d.Name)
		}
		if names[strings.ToLower(d.Name)] {
			return fmt.Errorf("dbadash %q is listed twice", d.Name)
		}
		names[strings.ToLower(d.Name)] = true
		v := strings.TrimSpace(d.DSNRaw)
		if v == "" {
			return fmt.Errorf("dbadash %q: dsn is required", d.Name)
		}
		if !strings.HasPrefix(v, "env:") && !strings.HasPrefix(v, "file:") && inlinePassword(v) {
			return fmt.Errorf("dbadash %q: a dsn with a password must be env:NAME or file:/path, never inline", d.Name)
		}
		if d.Interval.Duration != 0 && d.Interval.Duration < time.Minute {
			return fmt.Errorf("dbadash %q: interval must be at least 1m (got %s)", d.Name, d.Interval.Duration)
		}
	}
	return nil
}

// UI is the ui: block: the tree's folder levels and the order of the values in them.
type UI struct {
	// GroupBy lists tag keys, one folder level each, in order (e.g. [env, team]); empty = one folder per tag.
	GroupBy []string `yaml:"group_by"`
	// EnvOrder orders the values of every level: a listed value comes first, in the listed order (prod first);
	// the rest follow by name. Empty = DefaultEnvOrder.
	EnvOrder []string `yaml:"env_order"`
}

// DefaultEnvOrder puts production first and the lower environments after it.
var DefaultEnvOrder = []string{"prod", "production", "prd", "staging", "stage", "uat", "qa", "test", "dev", "development"}

// MaxGroupLevels caps the tree's folder levels.
const MaxGroupLevels = 4

// Tag is one key:value pair; a plain word is Key "tag".
type Tag struct {
	Key   string
	Value string
}

// String is the tag's one written form: the value alone for the key "tag", else key:value.
func (t Tag) String() string {
	if t.Key == "tag" {
		return t.Value
	}
	return t.Key + ":" + t.Value
}

// ValidTagKey says whether k may be a tag key: lower-case letters, digits, '_', '.', '-', 1..40 characters.
func ValidTagKey(k string) bool {
	if len(k) == 0 || len(k) > 40 {
		return false
	}
	for _, r := range k {
		ok := r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '.' || r == '-'
		if !ok {
			return false
		}
	}
	return true
}

// ParseTag reads "prod" (key tag) or "env:prod" (the first ':' splits); the key is lower-cased, both
// parts trimmed. The repository's view pgvigil.instance_tag_pairs (0032) splits the same way.
func ParseTag(s string) (Tag, error) {
	// a tab or a line break anywhere is refused before trimming: the repository's tag_split and the UI must
	// read the written tag the same way
	if strings.ContainsAny(s, "\t\r\n\v\f") {
		return Tag{}, fmt.Errorf("tag %q holds a tab or a line break", s)
	}
	s = strings.TrimSpace(s)
	t := Tag{Key: "tag", Value: s}
	if i := strings.IndexByte(s, ':'); i >= 0 {
		t = Tag{Key: strings.ToLower(strings.TrimSpace(s[:i])), Value: strings.TrimSpace(s[i+1:])}
	}
	switch {
	case t.Value == "":
		return t, fmt.Errorf("tag %q has no value", s)
	case !ValidTagKey(t.Key):
		return t, fmt.Errorf("tag %q: the key must be lower-case letters, digits, '_', '.' or '-' (1..40)", s)
	case t.Key == "tag" && strings.ContainsRune(t.Value, ':'):
		return t, fmt.Errorf("tag %q: a plain word cannot hold ':' (it would read back as a key:value pair)", s)
	case len(t.Value) > 100 || strings.ContainsAny(t.Value, ",\n\r\t"):
		return t, fmt.Errorf("tag %q: the value must be at most 100 characters, without a comma or a control character", s)
	}
	return t, nil
}

// TagPairs returns the instance's tags as pairs (Validate has checked them).
func (i Instance) TagPairs() []Tag {
	out := make([]Tag, 0, len(i.Tags))
	for _, s := range i.Tags {
		if t, err := ParseTag(s); err == nil {
			out = append(out, t)
		}
	}
	return out
}

// ExplainDSN resolves the EXPLAIN ANALYZE login; "" = none configured (or an unset variable / unreadable file).
func (i Instance) ExplainDSN() string {
	if i.ExplainDSNRaw == "" {
		return ""
	}
	return Resolve(strings.TrimSpace(i.ExplainDSNRaw))
}

// PgBouncerDSN resolves the pooler's admin console; "" = none configured (or an unset variable / unreadable file).
func (i Instance) PgBouncerDSN() string {
	if strings.TrimSpace(i.PgBouncerDSNRaw) == "" {
		return ""
	}
	return Resolve(strings.TrimSpace(i.PgBouncerDSNRaw))
}

// ActionsDSN resolves the actions door; "" = none configured (or an unset variable / unreadable file).
func (i Instance) ActionsDSN() string {
	if i.ActionsDSNRaw == "" {
		return ""
	}
	return Resolve(strings.TrimSpace(i.ActionsDSNRaw))
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

// Backups is an instance's backups: block.
type Backups struct {
	// ArchiveWarnMinutes is the age of the last archived WAL file past which a finding is raised while WAL waits; 0 = 60.
	ArchiveWarnMinutes int `yaml:"archive_warn_minutes"`
}

// ArchiveWarn returns the archive-age threshold in minutes (60 when unset).
func (b *Backups) ArchiveWarn() int {
	if b == nil || b.ArchiveWarnMinutes <= 0 {
		return 60
	}
	return b.ArchiveWarnMinutes
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
	if len(c.UI.GroupBy) > MaxGroupLevels {
		return fmt.Errorf("ui.group_by: at most %d levels (got %d)", MaxGroupLevels, len(c.UI.GroupBy))
	}
	keys := map[string]bool{}
	for _, k := range c.UI.GroupBy {
		if !ValidTagKey(k) {
			return fmt.Errorf("ui.group_by: %q is not a tag key (lower-case letters, digits, '_', '.', '-')", k)
		}
		if keys[k] {
			return fmt.Errorf("ui.group_by: %q is listed twice", k)
		}
		keys[k] = true
	}
	for i, v := range c.UI.EnvOrder {
		if strings.TrimSpace(v) == "" {
			return fmt.Errorf("ui.env_order holds an empty value")
		}
		c.UI.EnvOrder[i] = strings.ToLower(strings.TrimSpace(v)) // the tree ranks lower-cased values
	}
	if len(c.UI.EnvOrder) == 0 {
		c.UI.EnvOrder = DefaultEnvOrder
	}
	if err := c.validateDBADash(); err != nil {
		return err
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
		if in.Engine == "" {
			in.Engine = EnginePostgres
		}
		switch in.Engine {
		case EnginePostgres:
			switch in.Platform {
			case "auto", "onprem", "rds", "aurora", "azure", "cloudsql", "alloydb":
			default:
				return fmt.Errorf("instance %q: unknown platform %q", in.Name, in.Platform)
			}
			// a PostgreSQL instance's cancel and terminate are on with its actions_dsn; its job actions (task 161) only
			// where actions: names them
			seenPG := map[string]bool{}
			for _, a := range in.Actions {
				switch a {
				case "job_stop", "job_start":
				default:
					return fmt.Errorf("instance %q: unknown action %q in actions: (a PostgreSQL instance's are job_stop and job_start; its cancel and terminate are on with its actions_dsn)", in.Name, a)
				}
				if seenPG[a] {
					return fmt.Errorf("instance %q: actions: names %s twice", in.Name, a)
				}
				seenPG[a] = true
			}
			if len(in.Actions) > 0 && strings.TrimSpace(in.ActionsDSNRaw) == "" {
				return fmt.Errorf("instance %q: actions: names %s but the instance has no actions_dsn", in.Name, strings.Join(in.Actions, ", "))
			}
		case EngineSQLServer:
			switch in.Platform {
			case "auto", "onprem", "rds", "azuresqldb", "azuresqlmi", "cloudsql":
			default:
				return fmt.Errorf("instance %q: unknown platform %q for engine sqlserver (auto, onprem, rds, azuresqldb, azuresqlmi, cloudsql)", in.Name, in.Platform)
			}
			if v := strings.TrimSpace(in.DSNRaw); !strings.HasPrefix(v, "env:") && !strings.HasPrefix(v, "file:") && inlinePassword(v) {
				return fmt.Errorf("instance %q: a sqlserver dsn that carries a password must come through env:NAME or file:/path", in.Name)
			}
			// the actions door: another login than the read one, through env: or file: (checked for both engines
			// below), and an allow list that names only what the door can do
			if a, d := strings.TrimSpace(in.ActionsDSNRaw), strings.TrimSpace(in.DSNRaw); a != "" && a == d {
				return fmt.Errorf("instance %q: actions_dsn is the instance's dsn: the actions login must be a login of its own, never the read login", in.Name)
			}
			seen := map[string]bool{}
			for _, a := range in.Actions {
				switch a {
				case "kill", "job_start", "job_stop":
				default:
					return fmt.Errorf("instance %q: unknown action %q in actions: (kill, job_start, job_stop)", in.Name, a)
				}
				if seen[a] {
					return fmt.Errorf("instance %q: actions: names %s twice", in.Name, a)
				}
				seen[a] = true
			}
			if len(in.Actions) > 0 && strings.TrimSpace(in.ActionsDSNRaw) == "" {
				return fmt.Errorf("instance %q: actions: names %s but the instance has no actions_dsn", in.Name, strings.Join(in.Actions, ", "))
			}
			// the doors below are PostgreSQL's
			switch {
			case strings.TrimSpace(in.ExplainDSNRaw) != "" || in.ExplainAnalyze || in.HypoIndex:
				return fmt.Errorf("instance %q: explain_dsn, explain_analyze and hypo_index are PostgreSQL's", in.Name)
			case strings.TrimSpace(in.PgBouncerDSNRaw) != "":
				return fmt.Errorf("instance %q: pgbouncer is PostgreSQL's", in.Name)
			case in.AWS != nil:
				return fmt.Errorf("instance %q: the aws: block is not available for engine sqlserver yet", in.Name)
			case in.Backups != nil:
				return fmt.Errorf("instance %q: the backups: block is PostgreSQL's", in.Name)
			}
		default:
			return fmt.Errorf("instance %q: unknown engine %q (postgres or sqlserver)", in.Name, in.Engine)
		}
		for _, s := range in.Tags {
			if _, err := ParseTag(s); err != nil {
				return fmt.Errorf("instance %q: %w", in.Name, err)
			}
		}
		if v := strings.TrimSpace(in.ActionsDSNRaw); v != "" && !strings.HasPrefix(v, "env:") && !strings.HasPrefix(v, "file:") {
			return fmt.Errorf("instance %q: actions_dsn must be env:NAME or file:/path, never an inline connection string", in.Name)
		}
		if in.Backups != nil && in.Backups.ArchiveWarnMinutes < 0 {
			return fmt.Errorf("instance %q: backups.archive_warn_minutes must be 0 or more", in.Name)
		}
		if v := strings.TrimSpace(in.ExplainDSNRaw); v != "" && !strings.HasPrefix(v, "env:") && !strings.HasPrefix(v, "file:") {
			return fmt.Errorf("instance %q: explain_dsn must be env:NAME or file:/path, never an inline connection string", in.Name)
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
	case strings.HasPrefix(v, "dpapi:"):
		// a credential Admin > Instances sealed on Windows (task 204, inventory_windows.go)
		s, err := ResolveDPAPI(strings.TrimPrefix(v, "dpapi:"))
		if err != nil {
			return ""
		}
		return s
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
