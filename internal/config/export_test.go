package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func loadExport(t *testing.T, section string) (*Config, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte("repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n"+section), 0o600); err != nil {
		t.Fatal(err)
	}
	return Load(p)
}

const exportOK = "export:\n  name: prod-repo\n  dsn: env:PGVIGIL_EXPORT_DSN\n  state_dir: /var/lib/pgvigil/export\n  destination: {type: folder, path: /srv/x}\n"

// Absent = off; a minimal section takes every default; each knob is read.
func TestExportSection(t *testing.T) {
	c, err := loadExport(t, "")
	if err != nil || c.Export != nil {
		t.Fatalf("no section: %v, %v", c.Export, err)
	}
	if c, err = loadExport(t, exportOK); err != nil {
		t.Fatal(err)
	}
	e := c.Export
	if e.Settle() != 20*time.Minute || e.MaxAge() != 48*time.Hour || e.FinalAfter() != 24*time.Hour || e.PerRun() != 12 ||
		e.MaxBytes() != 256<<20 || e.Timeout() != 120*time.Second || len(e.Carry) != 0 {
		t.Errorf("defaults: settle %v, age %v, final %v, per run %d, bytes %d, timeout %v, carry %v", e.Settle(), e.MaxAge(), e.FinalAfter(), e.PerRun(), e.MaxBytes(), e.Timeout(), e.Carry)
	}
	c, err = loadExport(t, exportOK+"  settle_minutes: 0\n  max_window_age_hours: 6\n  max_windows_per_run: 2\n  final_after_hours: 2\n  snapshot_max_bytes: 1GB\n  statement_timeout: 5s\n  carry: [text, audit]\n  tables: {exclude: [host_sample]}\n")
	if err != nil {
		t.Fatal(err)
	}
	e = c.Export
	if c2, err := loadExport(t, strings.Replace(exportOK, "{type: folder, path: /srv/x}", "{type: azure_blob, container: c, connection_string: 'dpapi:blob'}", 1)); err != nil || c2.Export.Destination.Type != "azure_blob" {
		t.Errorf("a sealed blob secret is a way in: %v", err)
	}
	if e.Settle() != 0 || e.MaxAge() != 6*time.Hour || e.PerRun() != 2 || e.FinalAfter() != 2*time.Hour || e.MaxBytes() != 1<<30 ||
		e.Timeout() != 5*time.Second || len(e.Carry) != 2 || len(e.Tables.Exclude) != 1 {
		t.Errorf("knobs: settle %v, age %v, per run %d, final %v, bytes %d, timeout %v, carry %v, exclude %v", e.Settle(), e.MaxAge(), e.PerRun(), e.FinalAfter(), e.MaxBytes(), e.Timeout(), e.Carry, e.Tables.Exclude)
	}
}

// What the section refuses, each with words that name the key.
func TestExportSectionRefusals(t *testing.T) {
	with := func(old, repl string) string { return strings.Replace(exportOK, old, repl, 1) }
	for name, c := range map[string]struct{ section, word string }{
		"an upper-case name":              {with("name: prod-repo", "name: Prod"), "export.name"},
		"a name with the separator":       {with("name: prod-repo", "name: a__b"), "export.name"},
		"a name that ends in _":           {with("name: prod-repo", "name: prod_"), "export.name"},
		"a key the section does not know": {exportOK + "  tables: {exlude: [host_sample]}\n", "exlude"},
		"another unknown key":             {exportOK + "  carrry: [text]\n", "carrry"},
		"an account_url with a query":     {with("{type: folder, path: /srv/x}", "{type: azure_blob, container: c, account_url: 'https://a.blob.core.windows.net/?sv=1&sig=x'}"), "account_url"},
		"two ways into blob":              {with("{type: folder, path: /srv/x}", "{type: azure_blob, container: c, account_url: 'https://a.blob.core.windows.net', sas_url: env:S}"), "exactly one way in"},
		"a negative statement_timeout":    {exportOK + "  statement_timeout: -5s\n", "statement_timeout"},
		"a size past any disk":            {exportOK + "  snapshot_max_bytes: 9999999999999TB\n", "256MB"},
		"a dsn written in the file":       {with("dsn: env:PGVIGIL_EXPORT_DSN", "dsn: host=h user=u password=p"), "export.dsn"},
		"a dsn url in the file":           {with("dsn: env:PGVIGIL_EXPORT_DSN", "dsn: postgres://u@h/db"), "export.dsn"},
		"no dsn":                          {with("  dsn: env:PGVIGIL_EXPORT_DSN\n", ""), "export.dsn"},
		"no state_dir":                    {with("  state_dir: /var/lib/pgvigil/export\n", ""), "export.state_dir"},
		"an unknown destination":          {with("type: folder", "type: ftp"), "export.destination.type"},
		"a folder without its path":       {with("{type: folder, path: /srv/x}", "{type: folder}"), "path"},
		"s3 without its bucket":           {with("{type: folder, path: /srv/x}", "{type: s3, prefix: p}"), "bucket"},
		"blob without a way in":           {with("{type: folder, path: /srv/x}", "{type: azure_blob, container: c}"), "connection_string"},
		"a blob secret in the file":       {with("{type: folder, path: /srv/x}", "{type: azure_blob, container: c, connection_string: AccountKey=abc}"), "env:NAME"},
		"an unknown carry":                {exportOK + "  carry: [all]\n", "export.carry"},
		"a negative settle":               {exportOK + "  settle_minutes: -1\n", "settle_minutes"},
		"a size that is not one":          {exportOK + "  snapshot_max_bytes: lots\n", "256MB"},
	} {
		if _, err := loadExport(t, c.section); err == nil || !strings.Contains(err.Error(), c.word) {
			t.Errorf("%s: %v (want an error naming %s)", name, err, c.word)
		}
	}
}
