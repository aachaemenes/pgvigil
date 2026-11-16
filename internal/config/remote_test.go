package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// loadRaw writes body as the whole file (no repository: line of its own) and loads it.
func loadRaw(t *testing.T, body string) (*Config, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return Load(p)
}

const remoteOK = "remote:\n  site: site1\n  collector: jump01\n  outbox: /var/lib/pgvigil/outbox\n  state_dir: /var/lib/pgvigil/state\n" +
	"instances:\n  - name: 'HOST\\INST'\n    engine: sqlserver\n    dsn: env:SQL_DSN\n  - name: pg1\n    dsn: env:PG_DSN\n"

// A remote: block and no repository: is a remote collector; each knob takes its default, its statement text is
// hashed unless the file says none.
func TestRemoteCollectorBlock(t *testing.T) {
	c, err := loadRaw(t, remoteOK)
	if err != nil {
		t.Fatal(err)
	}
	r := c.Remote
	if r == nil || r.Site != "site1" || r.Collector != "jump01" || r.Interval.Duration != 5*time.Minute || r.KeepDays != 7 || r.MaxMB != 2048 || r.Sign || r.Push != nil {
		t.Fatalf("defaults: %+v", r)
	}
	if c.QueryText != "hash" || c.Instances[0].QueryText != "hash" || c.Instances[1].QueryText != "hash" {
		t.Errorf("query_text: %q, %q, %q (want hash)", c.QueryText, c.Instances[0].QueryText, c.Instances[1].QueryText)
	}
	c, err = loadRaw(t, strings.Replace(remoteOK, "  state_dir:", "  interval: 1m\n  keep_days: 2\n  max_mb: 64\n  sign: true\n"+
		"  push: {type: azure_blob, account_url: 'https://acct.blob.core.windows.net', container: drop, prefix: bundles}\n  state_dir:", 1)+"query_text: none\n")
	if err != nil {
		t.Fatal(err)
	}
	r = c.Remote
	if r.Interval.Duration != time.Minute || r.KeepDays != 2 || r.MaxMB != 64 || !r.Sign || r.Push == nil || r.Push.Container != "drop" || c.Instances[0].QueryText != "none" {
		t.Errorf("knobs: %+v, query_text %q", r, c.Instances[0].QueryText)
	}
	if c, err = loadRaw(t, remoteOK+"  - name: pg2\n    dsn: env:PG2\n    query_text: none\n"); err != nil || c.Instances[2].QueryText != "none" || c.Instances[0].QueryText != "hash" {
		t.Errorf("an instance's own none: %v", err)
	}
}

// Each refusal names what is wrong; nothing a remote collector cannot do is taken silently.
func TestRemoteCollectorRefusals(t *testing.T) {
	sasInline := "  push: {type: azure_blob, container: drop, sas_url: 'https://a.blob.core.windows.net/drop?sv=x&sig=y'}\n"
	for _, c := range []struct{ name, body, want string }{
		{"a repository too", "repository:\n  dsn: env:R\n" + remoteOK, "a remote collector has no repository"},
		{"remote_sites too", remoteOK + "remote_sites:\n  - name: s\n    drop: {type: folder, path: /d}\n    collectors: [{name: c}]\n", "remote_sites"},
		{"an export too", remoteOK + "export:\n  name: x\n  dsn: env:E\n  state_dir: /e\n  destination: {type: folder, path: /x}\n", "export"},
		{"a dbadash door too", remoteOK + "dbadash:\n  - name: d\n    dsn: env:D\n", "dbadash"},
		{"full text", remoteOK + "query_text: full\n", "no statement text leaves a remote collector"},
		{"normalized text", remoteOK + "query_text: normalized\n", "no statement text leaves a remote collector"},
		{"an instance's full text", strings.Replace(remoteOK, "    dsn: env:PG_DSN\n", "    dsn: env:PG_DSN\n    query_text: full\n", 1), "no statement text leaves a remote collector"},
		{"a site that is no name", strings.Replace(remoteOK, "site: site1", "site: Site 1", 1), "remote.site"},
		{"no site", strings.Replace(remoteOK, "  site: site1\n", "", 1), "remote.site"},
		{"a collector that is no name", strings.Replace(remoteOK, "collector: jump01", "collector: jump/01", 1), "remote.collector"},
		{"no outbox", strings.Replace(remoteOK, "  outbox: /var/lib/pgvigil/outbox\n", "", 1), "remote.outbox"},
		{"a relative outbox", strings.Replace(remoteOK, "outbox: /var/lib/pgvigil/outbox", "outbox: outbox", 1), "remote.outbox"},
		{"no state_dir", strings.Replace(remoteOK, "  state_dir: /var/lib/pgvigil/state\n", "", 1), "remote.state_dir"},
		{"the outbox inside the state folder", strings.Replace(remoteOK, "outbox: /var/lib/pgvigil/outbox", "outbox: /var/lib/pgvigil/state/out", 1), "apart"},
		{"one folder for both", strings.Replace(remoteOK, "outbox: /var/lib/pgvigil/outbox", "outbox: /var/lib/pgvigil/state", 1), "apart"},
		{"30 seconds", strings.Replace(remoteOK, "  outbox:", "  interval: 30s\n  outbox:", 1), "remote.interval"},
		{"two hours", strings.Replace(remoteOK, "  outbox:", "  interval: 2h\n  outbox:", 1), "remote.interval"},
		{"keep_days 0 written as -1", strings.Replace(remoteOK, "  outbox:", "  keep_days: -1\n  outbox:", 1), "remote.keep_days"},
		{"max_mb under 64", strings.Replace(remoteOK, "  outbox:", "  max_mb: 10\n  outbox:", 1), "remote.max_mb"},
		{"an s3 push", strings.Replace(remoteOK, "  outbox:", "  push: {type: s3, bucket: b}\n  outbox:", 1), "azure_blob"},
		{"a push without a container", strings.Replace(remoteOK, "  outbox:", "  push: {type: azure_blob, account_url: 'https://a.blob.core.windows.net'}\n  outbox:", 1), "container"},
		{"a push with two ways in", strings.Replace(remoteOK, "  outbox:", "  push: {type: azure_blob, container: d, account_url: 'https://a', sas_url: env:SAS}\n  outbox:", 1), "exactly one way in"},
		{"a SAS written in the file", strings.Replace(remoteOK, "  outbox:", sasInline+"  outbox:", 1), "env:NAME or file:/path"},
		// the hub refuses a container drop without its prefix (ingest.OpenDrop): the push names the same folder
		{"a push without its prefix", strings.Replace(remoteOK, "  outbox:", "  push: {type: azure_blob, container: d, sas_url: env:SAS}\n  outbox:", 1), "prefix"},
		{"an unknown key", strings.Replace(remoteOK, "  outbox:", "  outbx: /x\n  outbox:", 1), "outbx"},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadRaw(t, c.body)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want an error with %q", err, c.want)
			}
		})
	}
}

// hash is a remote collector's value: a direct collector refuses it in words (its text would be stored whole by a
// policy that does not know it).
func TestHashIsARemoteSetting(t *testing.T) {
	for _, body := range []string{
		"repository:\n  dsn: env:R\nquery_text: hash\ninstances: []\n",
		"repository:\n  dsn: env:R\ninstances:\n  - name: pg1\n    dsn: env:PG\n    query_text: hash\n",
	} {
		if _, err := loadRaw(t, body); err == nil || !strings.Contains(err.Error(), "a remote collector's setting") {
			t.Errorf("%q: %v", body, err)
		}
	}
	if _, err := loadRaw(t, "instances: []\n"); err == nil || !strings.Contains(err.Error(), "repository.dsn is required") {
		t.Errorf("neither a repository nor a remote: block: %v", err)
	}
}

const sitesOK = "repository:\n  dsn: env:R\ninstances: []\nremote_sites:\n" +
	"  - name: site1\n    drop: {type: azure_blob, account_url: 'https://acct.blob.core.windows.net', container: drop}\n    tags: ['client:one']\n" +
	"    collectors:\n      - name: jump01\n        keys: ['ed25519:11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=']\n" +
	"  - name: site2\n    drop: {type: s3, bucket: b2, endpoint: 'https://storage.googleapis.com', region: auto}\n    expected_every: 1h\n    collectors: [{name: c1}, {name: c2}]\n" +
	"  - name: site3\n    drop: {type: folder, path: /srv/drops/site3}\n    expected_every: 24h\n    gap_wait: 48h\n    collectors: [{name: usb}]\n"

// The hub's remote_sites: each site's drop, tags, cadence and collectors; the gap wait is three cadences by default.
func TestRemoteSites(t *testing.T) {
	c, err := loadRaw(t, sitesOK)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.RemoteSites) != 3 {
		t.Fatalf("sites: %+v", c.RemoteSites)
	}
	s1, s2, s3 := c.RemoteSites[0], c.RemoteSites[1], c.RemoteSites[2]
	if s1.ExpectedEvery.Duration != 5*time.Minute || s1.GapWait.Duration != 15*time.Minute || len(s1.Collectors[0].Keys) != 1 || s1.Drop.Container != "drop" {
		t.Errorf("site1: %+v", s1)
	}
	if s2.ExpectedEvery.Duration != time.Hour || s2.GapWait.Duration != 3*time.Hour || len(s2.Collectors) != 2 || s2.Drop.Endpoint == "" {
		t.Errorf("site2: %+v", s2)
	}
	if s3.ExpectedEvery.Duration != 24*time.Hour || s3.GapWait.Duration != 48*time.Hour {
		t.Errorf("site3: %+v", s3)
	}
}

func TestRemoteSitesRefusals(t *testing.T) {
	base := "repository:\n  dsn: env:R\ninstances: []\nremote_sites:\n"
	site := func(body string) string { return base + "  - name: s1\n" + body }
	drop := "    drop: {type: folder, path: /d}\n"
	for _, c := range []struct{ name, body, want string }{
		{"a site that is no name", base + "  - name: S 1\n" + drop + "    collectors: [{name: c}]\n", "remote_sites[0].name"},
		{"a site twice", sitesOK + "  - name: site1\n" + drop + "    collectors: [{name: c}]\n", "listed twice"},
		{"no drop", site("    collectors: [{name: c}]\n"), "drop.type"},
		{"a folder without its path", site("    drop: {type: folder}\n    collectors: [{name: c}]\n"), "path"},
		{"an s3 drop without its bucket", site("    drop: {type: s3}\n    collectors: [{name: c}]\n"), "bucket"},
		{"a blob drop's key in the file", site("    drop: {type: azure_blob, container: d, connection_string: 'AccountKey=x'}\n    collectors: [{name: c}]\n"), "env:NAME or file:/path"},
		{"no collector", site(drop), "collectors"},
		{"a collector twice", site(drop + "    collectors: [{name: c}, {name: c}]\n"), "listed twice"},
		{"a collector that is no name", site(drop + "    collectors: [{name: C}]\n"), "collectors[0].name"},
		{"a key that is no ed25519 key", site(drop + "    collectors: [{name: c, keys: ['ed25519:AAAA']}]\n"), "ed25519"},
		{"a key of another kind", site(drop + "    collectors: [{name: c, keys: ['rsa:AAAA']}]\n"), "ed25519"},
		{"a cadence under a minute", site(drop + "    expected_every: 30s\n    collectors: [{name: c}]\n"), "expected_every"},
		{"a gap wait under the cadence", site(drop + "    expected_every: 1h\n    gap_wait: 10m\n    collectors: [{name: c}]\n"), "gap_wait"},
		{"a tag that is no tag", site(drop + "    tags: [\"a\\tb\"]\n    collectors: [{name: c}]\n"), "tab"},
		{"an unknown key", site(drop + "    colectors: [{name: c}]\n"), "colectors"},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, err := loadRaw(t, c.body)
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want an error with %q", err, c.want)
			}
		})
	}
}

// deploy/pgvigil-remote.yaml is the sample the remote archives carry (task 11, R15): a site that copies it and edits
// the names gets a remote collector's file the installer takes - it loads as one, with the docs' defaults.
func TestRemoteSampleLoads(t *testing.T) {
	c, err := Load(filepath.Join("..", "..", "deploy", "pgvigil-remote.yaml"))
	if err != nil {
		t.Fatalf("the sample does not load: %v", err)
	}
	r := c.Remote
	if r == nil || r.Site != "site-name" || r.Collector != "c1" || r.Interval.Duration != 5*time.Minute || r.KeepDays != 7 || r.MaxMB != 2048 || r.Sign || r.Push != nil {
		t.Fatalf("the sample's remote: block: %+v", r)
	}
	if r.Outbox != "/var/lib/pgvigil-remote/outbox" || r.StateDir != "/var/lib/pgvigil-remote/state" {
		t.Errorf("the sample's folders are not the installer's own: %q, %q", r.Outbox, r.StateDir)
	}
	if c.QueryText != "hash" || len(c.Instances) != 2 || c.Instances[0].QueryText != "hash" || c.Instances[1].QueryText != "hash" {
		t.Errorf("the sample's instances / query_text: %d instance(s), %q", len(c.Instances), c.QueryText)
	}
}

// ingest_dsn (OUTBOX H FOLD 1+2+3, B5 as the slice lead answered): a hub's ingest login beside remote_sites: (env: /
// file:); without remote_sites: it would read nothing - refused; a remote collector's file may not hold it
func TestIngestDSNKey(t *testing.T) {
	t.Setenv("R", "host=h dbname=r")
	t.Setenv("ING", "host=h dbname=r user=ingest1")
	cfg, err := loadRaw(t, sitesOK+"ingest_dsn: env:ING\n")
	if err != nil {
		t.Fatalf("a hub with remote_sites: and ingest_dsn: %v", err)
	}
	if got := cfg.IngestDSN(); got != "host=h dbname=r user=ingest1" {
		t.Errorf("IngestDSN: %q", got)
	}
	if _, err := loadRaw(t, "repository:\n  dsn: env:R\ninstances: []\ningest_dsn: env:ING\n"); err == nil || !strings.Contains(err.Error(), "ingest_dsn") || !strings.Contains(err.Error(), "remote_sites") {
		t.Errorf("ingest_dsn without remote_sites: %v, want it refused naming both", err)
	}
	if _, err := loadRaw(t, remoteOK+"ingest_dsn: env:ING\n"); err == nil || !strings.Contains(err.Error(), "ingest_dsn") {
		t.Errorf("a remote collector's file with ingest_dsn: %v, want it refused", err)
	}
}
