package config

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
	"gopkg.in/yaml.v3"
)

// Remote is the remote: block (docs/remote-collector.md). With it and no repository: block, `pgvigil run` is a
// remote collector: it reads its instances as any collector does and writes each instance's interval as a bundle
// into its outbox folder (and, with push:, into an Azure Blob container) for a hub to ingest; it has no repository,
// no web page, no alerts and no request queue, and writes nothing but its outbox and its state folder.
type Remote struct {
	// Site and Collector name the bundles (and, on the hub, the instances: <site>/<name>).
	Site      string `yaml:"site"`
	Collector string `yaml:"collector"`
	// Interval is how long a bundle covers: 5m by default, 1m to 60m.
	Interval Duration `yaml:"interval"`
	// Outbox is the folder the bundles are written into; StateDir keeps how far each source was read, the bundle
	// seq and the lock. Two folders apart, both absolute.
	Outbox   string `yaml:"outbox"`
	StateDir string `yaml:"state_dir"`
	// KeepDays is how long a bundle stays in the outbox after it was pushed (or, without push:, after it was
	// written): 7 by default. MaxMB caps the outbox (2048 by default): past it the oldest bundle goes first.
	KeepDays int `yaml:"keep_days"`
	MaxMB    int `yaml:"max_mb"`
	// Sign signs each bundle's manifest with the collector's Ed25519 key (`pgvigil remote init`); off by default.
	Sign bool `yaml:"sign"`
	// Push writes each finished bundle straight into an Azure Blob container (type azure_blob, with a credential that
	// may only write there); absent = the outbox only, moved by the site's own tool.
	Push *ExportDestination `yaml:"push"`
}

// RemoteSite is one entry of remote_sites: on a hub - a site's drop and the collectors that write it.
type RemoteSite struct {
	Name string `yaml:"name"`
	// Drop is where the site's bundles land: a folder, an S3 bucket (GCS through its S3 endpoint) or an Azure Blob
	// container, read with a read-only credential (env: / file:, or the default chain).
	Drop ExportDestination `yaml:"drop"`
	// Tags are put on every instance of the site.
	Tags []string `yaml:"tags"`
	// ExpectedEvery is how often a bundle arrives (the interval for a direct push, the copy's cadence otherwise):
	// 5m by default; the silence finding and the late marks are counted in it.
	ExpectedEvery Duration `yaml:"expected_every"`
	// GapWait is how long a missing seq is waited for before ingest goes on: three ExpectedEvery by default.
	GapWait Duration `yaml:"gap_wait"`
	// Collectors are the site's remote collectors; a bundle of another is set aside.
	Collectors []RemoteCollector `yaml:"collectors"`
}

// RemoteCollector is one collector of a site, with the public keys its signed bundles are checked by.
type RemoteCollector struct {
	Name string `yaml:"name"`
	// Keys: 'ed25519:<base64 of the 32-byte public key>' as `pgvigil remote init` prints it; empty = unsigned.
	Keys []string `yaml:"keys"`
}

// UnmarshalYAML reads the block with every key checked: a mistyped key is an error, never a silence.
func (r *Remote) UnmarshalYAML(n *yaml.Node) error {
	type plain Remote
	return strictYAML(n, (*plain)(r), "remote")
}

// UnmarshalYAML reads a site with every key checked.
func (s *RemoteSite) UnmarshalYAML(n *yaml.Node) error {
	type plain RemoteSite
	return strictYAML(n, (*plain)(s), "remote_sites")
}

func strictYAML(n *yaml.Node, into any, where string) error {
	b, err := yaml.Marshal(n)
	if err != nil {
		return err
	}
	d := yaml.NewDecoder(bytes.NewReader(b))
	d.KnownFields(true)
	if err := d.Decode(into); err != nil {
		return fmt.Errorf("%s: %w", where, err)
	}
	return nil
}

// validateRemote checks a remote collector's file: the block's values with their defaults, nothing that needs a
// repository, and statement text hashed or dropped.
func (c *Config) validateRemote() error {
	r := c.Remote
	if strings.TrimSpace(c.Repository.DSNRaw) != "" {
		return fmt.Errorf("remote: a remote collector has no repository: remove repository: (a hub) or remote: (a remote collector)")
	}
	for _, k := range []struct {
		key string
		set bool
	}{{"remote_sites", len(c.RemoteSites) > 0}, {"ingest_dsn", c.IngestDSNRaw != ""}, {"export", c.Export != nil}, {"dbadash", len(c.DBADash) > 0}, {"reports_dsn", c.ReportsDSNRaw != ""}} {
		if k.set {
			return fmt.Errorf("remote: %s: needs a repository, and a remote collector has none", k.key)
		}
	}
	if !format.ValidName(r.Site) {
		return fmt.Errorf("remote.site %q: lower-case letters, digits, '_', '.', '-', a letter or a digit first, at most 63", r.Site)
	}
	if !format.ValidName(r.Collector) {
		return fmt.Errorf("remote.collector %q: lower-case letters, digits, '_', '.', '-', a letter or a digit first, at most 63", r.Collector)
	}
	for _, f := range []struct{ key, path string }{{"remote.outbox", r.Outbox}, {"remote.state_dir", r.StateDir}} {
		if strings.TrimSpace(f.path) == "" || !filepath.IsAbs(f.path) {
			return fmt.Errorf("%s: an absolute folder is required (got %q)", f.key, f.path)
		}
	}
	if inside(r.Outbox, r.StateDir) || inside(r.StateDir, r.Outbox) {
		return fmt.Errorf("remote.outbox and remote.state_dir must be two folders apart, neither inside the other")
	}
	if r.Interval.Duration == 0 {
		r.Interval.Duration = 5 * time.Minute
	}
	if r.Interval.Duration < time.Minute || r.Interval.Duration > time.Hour {
		return fmt.Errorf("remote.interval must be 1m to 60m (got %s)", r.Interval.Duration)
	}
	if r.KeepDays == 0 {
		r.KeepDays = 7
	}
	if r.KeepDays < 1 || r.KeepDays > 365 {
		return fmt.Errorf("remote.keep_days must be 1 to 365 (got %d)", r.KeepDays)
	}
	if r.MaxMB == 0 {
		r.MaxMB = 2048
	}
	if r.MaxMB < 64 {
		return fmt.Errorf("remote.max_mb must be 64 or more (got %d)", r.MaxMB)
	}
	if r.Push != nil {
		if r.Push.Type != "azure_blob" {
			return fmt.Errorf("remote.push: azure_blob is the one push in this release (got %q); for a folder, an S3 or a GCS bucket the site moves the outbox with its own tool", r.Push.Type)
		}
		if err := checkDestination("remote.push", *r.Push); err != nil {
			return err
		}
	}
	if c.QueryText == "" {
		c.QueryText = "hash"
	}
	return nil
}

// inside says whether folder a is b or lies inside it.
func inside(a, b string) bool {
	a, b = filepath.Clean(a), filepath.Clean(b)
	return a == b || strings.HasPrefix(a, strings.TrimSuffix(b, string(filepath.Separator))+string(filepath.Separator))
}

// checkQueryText holds a query_text value to the kind of collector the file makes: a remote collector stores hash or
// none (no statement text leaves it), a direct one full, normalized or none.
func (c *Config) checkQueryText(v, where string) error {
	if c.Remote != nil {
		if v != "hash" && v != "none" {
			return fmt.Errorf("%squery_text must be hash or none on a remote collector (got %q): no statement text leaves a remote collector", where, v)
		}
		return nil
	}
	if v == "hash" {
		return fmt.Errorf("%squery_text hash is a remote collector's setting (a remote: block); here full, normalized or none", where)
	}
	if !validQueryText(v) {
		return fmt.Errorf("%squery_text must be full, normalized or none (got %q)", where, v)
	}
	return nil
}

// IngestDSN is ingest's login (ingest_dsn: resolved from env: / file:): a login in pgvigil_ingest, checked at start by
// ingest.CheckIngestLogin. Empty = remote_sites: is not read (pgvigil run says so; pgvigil ingest refuses).
func (c Config) IngestDSN() string { return Resolve(strings.TrimSpace(c.IngestDSNRaw)) }

// validateRemoteSites checks a hub's remote_sites: each site's name, drop, tags, cadence and collectors; ingest_dsn
// without remote_sites: is refused (it would read nothing).
func (c *Config) validateRemoteSites() error {
	if strings.TrimSpace(c.IngestDSNRaw) != "" && len(c.RemoteSites) == 0 {
		return fmt.Errorf("ingest_dsn: set without remote_sites: - ingest reads the sites remote_sites: lists (docs/remote-collector.md)")
	}
	seen := map[string]bool{}
	for i := range c.RemoteSites {
		s := &c.RemoteSites[i]
		where := fmt.Sprintf("remote_sites[%d]", i)
		if !format.ValidName(s.Name) {
			return fmt.Errorf("%s.name %q: lower-case letters, digits, '_', '.', '-', a letter or a digit first, at most 63", where, s.Name)
		}
		if seen[s.Name] {
			return fmt.Errorf("remote_sites: site %q is listed twice", s.Name)
		}
		seen[s.Name] = true
		if err := checkDestination(where+".drop", s.Drop); err != nil {
			return err
		}
		for _, t := range s.Tags {
			if _, err := ParseTag(t); err != nil {
				return fmt.Errorf("%s.tags: %w", where, err)
			}
		}
		if s.ExpectedEvery.Duration == 0 {
			s.ExpectedEvery.Duration = 5 * time.Minute
		}
		if s.ExpectedEvery.Duration < time.Minute || s.ExpectedEvery.Duration > 7*24*time.Hour {
			return fmt.Errorf("%s.expected_every must be 1m to 168h (got %s)", where, s.ExpectedEvery.Duration)
		}
		if s.GapWait.Duration == 0 {
			s.GapWait.Duration = 3 * s.ExpectedEvery.Duration
		}
		if s.GapWait.Duration < s.ExpectedEvery.Duration {
			return fmt.Errorf("%s.gap_wait (%s) must be at least expected_every (%s)", where, s.GapWait.Duration, s.ExpectedEvery.Duration)
		}
		if len(s.Collectors) == 0 {
			return fmt.Errorf("%s.collectors: list the site's collectors (at least one)", where)
		}
		names := map[string]bool{}
		for j, rc := range s.Collectors {
			if !format.ValidName(rc.Name) {
				return fmt.Errorf("%s.collectors[%d].name %q: lower-case letters, digits, '_', '.', '-', a letter or a digit first, at most 63", where, j, rc.Name)
			}
			if names[rc.Name] {
				return fmt.Errorf("%s.collectors: collector %q is listed twice", where, rc.Name)
			}
			names[rc.Name] = true
			for _, k := range rc.Keys {
				if _, err := Ed25519Key(k); err != nil {
					return fmt.Errorf("%s.collectors[%d].keys: %w", where, j, err)
				}
			}
		}
	}
	return nil
}

// Ed25519Key reads a public key as `pgvigil remote init` prints it: 'ed25519:<standard base64 of 32 bytes>'.
func Ed25519Key(s string) ([]byte, error) {
	b64, ok := strings.CutPrefix(strings.TrimSpace(s), "ed25519:")
	if !ok {
		return nil, fmt.Errorf("%q is not ed25519:<base64 of the 32-byte public key>", s)
	}
	k, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(k) != 32 {
		return nil, fmt.Errorf("%q is not ed25519:<base64 of the 32-byte public key>", s)
	}
	return k, nil
}

// checkDestination holds a destination block to its type's needs: a folder its path, s3 its bucket, azure_blob its
// container and exactly one way in, every secret named by env: / file: / dpapi:, never written in the file.
func checkDestination(where string, d ExportDestination) error {
	switch d.Type {
	case "folder":
		if strings.TrimSpace(d.Path) == "" {
			return fmt.Errorf("%s: a folder needs its path", where)
		}
	case "s3":
		if strings.TrimSpace(d.Bucket) == "" {
			return fmt.Errorf("%s: s3 needs its bucket", where)
		}
	case "azure_blob":
		if strings.TrimSpace(d.Container) == "" {
			return fmt.Errorf("%s: azure_blob needs its container", where)
		}
		ways := 0
		for _, v := range []string{d.ConnectionStringRaw, d.SASURLRaw, d.AccountURL} {
			if strings.TrimSpace(v) != "" {
				ways++
			}
		}
		if ways != 1 {
			return fmt.Errorf("%s: azure_blob takes exactly one way in: connection_string, sas_url or account_url (the default credential)", where)
		}
		for _, v := range []string{d.ConnectionStringRaw, d.SASURLRaw} {
			if v != "" && !strings.HasPrefix(v, "env:") && !strings.HasPrefix(v, "file:") && !strings.HasPrefix(v, "dpapi:") {
				return fmt.Errorf("%s: connection_string and sas_url are secrets: name them by env:NAME or file:/path", where)
			}
		}
		if strings.Contains(d.AccountURL, "?") {
			return fmt.Errorf("%s: account_url carries a query: a SAS URL is a secret, name it by sas_url: env:NAME", where)
		}
	default:
		return fmt.Errorf("%s.type must be folder, s3 or azure_blob (got %q)", where, d.Type)
	}
	return nil
}
