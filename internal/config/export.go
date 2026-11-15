package config

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Export is the `export:` section: the repository's read-only export to Parquet (`pgvigil export`,
// docs/parquet-export.md). Absent = off: nothing in pgvigil exports anything, and the verb says how to turn it on.
type Export struct {
	// Name is the folder under the destination's prefix and part of every file name: lower case, a letter first.
	Name string `yaml:"name"`
	// DSNRaw is the export's own login on the repository: IN ROLE pgvigil_reader (or pgvigil_exporter) alone. A
	// login that could write is refused. env:NAME or file:/path.
	DSNRaw string `yaml:"dsn"`
	// StateDir holds the lock, the files being built and the count of a table's failed reads; never the data kept.
	StateDir    string            `yaml:"state_dir"`
	Destination ExportDestination `yaml:"destination"`
	// SettleMinutes: a window is first exported this long after it ends (default 20).
	SettleMinutes *int `yaml:"settle_minutes"`
	// MaxWindowAgeHours: a run looks this far back for windows without a manifest (default 48).
	MaxWindowAgeHours int `yaml:"max_window_age_hours"`
	// MaxWindowsPerRun: at most this many windows a run (default 12); the rest are named as due.
	MaxWindowsPerRun int `yaml:"max_windows_per_run"`
	// FinalAfterHours: a window is exported again, as final, once it is this old (default 24): rows stored after
	// its first pass under a time inside it.
	FinalAfterHours int `yaml:"final_after_hours"`
	// SnapshotMaxBytes: a whole-table export (a state or a dimension table) over it is left out and named
	// (default 256MB).
	SnapshotMaxBytes ByteSize `yaml:"snapshot_max_bytes"`
	// StatementTimeout of the reading session (default 120s).
	StatementTimeout Duration `yaml:"statement_timeout"`
	// Carry: text (statement, plan and log text) and audit (action logs, audit trails, logins, roles, grants).
	// Each is off unless named: what leaves the repository cannot be called back.
	Carry  []string `yaml:"carry"`
	Tables struct {
		Exclude []string `yaml:"exclude"`
	} `yaml:"tables"`
}

// ExportDestination is where the files go: a folder, an S3 bucket (or an S3-compatible store by its endpoint), or
// an Azure Blob container. No credential is written here: S3 uses the AWS default chain, Blob a connection string
// or SAS URL by env: / file:, or the default credential.
type ExportDestination struct {
	Type string `yaml:"type"` // folder | s3 | azure_blob
	Path string `yaml:"path"` // folder

	Bucket   string `yaml:"bucket"` // s3
	Prefix   string `yaml:"prefix"` // s3, azure_blob
	Region   string `yaml:"region"`
	Endpoint string `yaml:"endpoint"`
	Profile  string `yaml:"profile"`

	AccountURL          string `yaml:"account_url"` // azure_blob
	Container           string `yaml:"container"`
	ConnectionStringRaw string `yaml:"connection_string"`
	SASURLRaw           string `yaml:"sas_url"`
}

// DSN resolves the export login's connection string.
func (e *Export) DSN() string { return Resolve(strings.TrimSpace(e.DSNRaw)) }

// ConnectionString and SASURL resolve the Blob secrets.
func (d ExportDestination) ConnectionString() string {
	return Resolve(strings.TrimSpace(d.ConnectionStringRaw))
}
func (d ExportDestination) SASURL() string { return Resolve(strings.TrimSpace(d.SASURLRaw)) }

// Settle, MaxAge, FinalAfter, PerRun, MaxBytes and Timeout are the knobs with their defaults.
func (e *Export) Settle() time.Duration {
	if e.SettleMinutes == nil {
		return 20 * time.Minute
	}
	return time.Duration(*e.SettleMinutes) * time.Minute
}
func (e *Export) MaxAge() time.Duration {
	return time.Duration(orDefault(e.MaxWindowAgeHours, 48)) * time.Hour
}
func (e *Export) FinalAfter() time.Duration {
	return time.Duration(orDefault(e.FinalAfterHours, 24)) * time.Hour
}
func (e *Export) PerRun() int { return orDefault(e.MaxWindowsPerRun, 12) }
func (e *Export) MaxBytes() int64 {
	if e.SnapshotMaxBytes.set {
		return e.SnapshotMaxBytes.N
	}
	return 256 << 20
}
func (e *Export) Timeout() time.Duration {
	if e.StatementTimeout.Duration > 0 {
		return e.StatementTimeout.Duration
	}
	return 120 * time.Second
}

func orDefault(v, def int) int {
	if v == 0 {
		return def
	}
	return v
}

// ByteSize parses "256MB", "1GB", "512KB" or a bare number of bytes.
type ByteSize struct {
	N   int64
	set bool
}

// UnmarshalYAML implements yaml.Unmarshaler.
func (b *ByteSize) UnmarshalYAML(n *yaml.Node) error {
	s := strings.ToUpper(strings.TrimSpace(n.Value))
	mult := int64(1)
	for _, u := range []struct {
		suffix string
		mult   int64
	}{{"KB", 1 << 10}, {"MB", 1 << 20}, {"GB", 1 << 30}, {"TB", 1 << 40}} {
		if strings.HasSuffix(s, u.suffix) {
			s, mult = strings.TrimSpace(strings.TrimSuffix(s, u.suffix)), u.mult
			break
		}
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v < 0 {
		return fmt.Errorf("a size like 256MB, 1GB or a number of bytes (got %q)", n.Value)
	}
	b.N, b.set = v*mult, true
	return nil
}

var exportName = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,30}$`)

func (e *Export) validate() error {
	if !exportName.MatchString(e.Name) {
		return fmt.Errorf("export.name: lower-case letters, digits, '_' and '-', a letter first, at most 31 characters (got %q)", e.Name)
	}
	if strings.TrimSpace(e.DSNRaw) == "" {
		return fmt.Errorf("export.dsn is required: the export's own login, IN ROLE pgvigil_reader alone (env:NAME or file:/path)")
	}
	if inlinePassword(e.DSNRaw) {
		return fmt.Errorf("export.dsn holds a password: name it by env:NAME or file:/path")
	}
	if strings.TrimSpace(e.StateDir) == "" {
		return fmt.Errorf("export.state_dir is required: a folder for the lock and the files being built")
	}
	d := e.Destination
	switch d.Type {
	case "folder":
		if strings.TrimSpace(d.Path) == "" {
			return fmt.Errorf("export.destination: a folder needs its path")
		}
	case "s3":
		if strings.TrimSpace(d.Bucket) == "" {
			return fmt.Errorf("export.destination: s3 needs its bucket")
		}
	case "azure_blob":
		if strings.TrimSpace(d.Container) == "" {
			return fmt.Errorf("export.destination: azure_blob needs its container")
		}
		if d.ConnectionStringRaw == "" && d.SASURLRaw == "" && strings.TrimSpace(d.AccountURL) == "" {
			return fmt.Errorf("export.destination: azure_blob needs connection_string, sas_url or account_url (the default credential)")
		}
		for _, v := range []string{d.ConnectionStringRaw, d.SASURLRaw} {
			if v != "" && !strings.HasPrefix(v, "env:") && !strings.HasPrefix(v, "file:") {
				return fmt.Errorf("export.destination: connection_string and sas_url are secrets: name them by env:NAME or file:/path")
			}
		}
	default:
		return fmt.Errorf("export.destination.type must be folder, s3 or azure_blob (got %q)", d.Type)
	}
	for _, c := range e.Carry {
		if c != "text" && c != "audit" {
			return fmt.Errorf("export.carry: text and audit are the two carries (got %q)", c)
		}
	}
	if e.SettleMinutes != nil && *e.SettleMinutes < 0 {
		return fmt.Errorf("export.settle_minutes must be 0 or more")
	}
	if e.MaxWindowAgeHours < 0 || e.MaxWindowsPerRun < 0 || e.FinalAfterHours < 0 {
		return fmt.Errorf("export: max_window_age_hours, max_windows_per_run and final_after_hours must be positive")
	}
	return nil
}
