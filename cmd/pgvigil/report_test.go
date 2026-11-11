package main

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// The values the tests seed into a configuration: none of them may be in any file of a report.
const (
	seedRepoPass = "Rp-7f3a91c2-repo"
	seedInstPass = "Ip-55d0e8b4-inst"
	seedADOPass  = "Ap-0c9e2d17-ado"
	seedSMTPPass = "Sp-4b6a7f20-smtp"
	seedEnvPass  = "Ep-91aa3c5e-env"
	seedFlagPass = "Fp-2e7d6b83-flag"
	seedSlackURL = "https://hooks.slack.example/services/T0SEED/B0SEED/x9SEEDtokenSEED"
	seedTeamsURL = "https://prod-27.westus.logic.azure.example:443/workflows/abc123SEED/triggers/manual/paths/invoke?api-version=2016-06-01&sig=SEEDsigSEED99"
)

// seedLeaks is everything of the seeded configuration that names the site or opens a door.
var seedLeaks = []string{
	seedRepoPass, seedInstPass, seedADOPass, seedSMTPPass, seedEnvPass, seedFlagPass, seedSlackURL, seedTeamsURL,
	"T0SEED", "x9SEEDtokenSEED", "abc123SEED", "SEEDsigSEED99", "Commented-0ut-secret", "acme-secret-literal",
	"corp.example", "slack.example", "azure.example", "orders01", "erp01", "envhost", "pgvigil_owner", "monitor_login",
	"acme-prod", "billing", "prodsite7", "acme-orders-cluster", "oncall-slack", "stuck orders", "pgvigil_acme",
}

// seedConfig is a configuration with a secret in every place one can sit: an inline keyword string, an inline URL,
// a file: and an env: indirection, two webhook addresses, an SMTP password, a comment, a custom check's statement.
func seedConfig(t *testing.T, dir string) string {
	t.Helper()
	ado := filepath.Join(dir, "erp.dsn")
	if err := os.WriteFile(ado, []byte("server=erp01.corp.example,1433;user id=monitor_login;password="+seedADOPass+";database=master\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGVIGIL_TEST_REPORT_ACTIONS", "postgres://envuser_x:"+seedEnvPass+"@envhost.corp.example:5432/envdb")
	text := `# repository: postgres://owner:Commented-0ut-secret@db/x   (a commented-out line)
repository:
  dsn: "host=127.0.0.1 port=1 user=pgvigil_owner password='` + seedRepoPass + `' dbname=pgvigil_acme"
query_text: normalized
schedules:
  activity: 30s
ui:
  group_by: [env, team]
  env_order: [acme-prod, acme-dev]
instances:
  - name: acme-orders-db01
    dsn: postgres://monitor_login:` + seedInstPass + `@orders01.corp.example:5432/orders?sslmode=require   # Commented-0ut-secret
    platform: aurora
    tags: [env:acme-prod, team:billing, env:prodsite7]
    disabled: [logs]
    actions_dsn: env:PGVIGIL_TEST_REPORT_ACTIONS
    aws:
      region: us-east-1
      cluster: acme-orders-cluster
  - name: acme-erp-sql01
    engine: sqlserver
    dsn: file:` + ado + `
    mssql_thresholds:
      backup_full_warn_hours: 30
alerts:
  - name: oncall-slack
    kind: webhook
    min_severity: critical
    webhook:
      url: ` + seedSlackURL + `
      format: slack
  - name: dba-teams
    kind: webhook
    webhook: {url: "` + seedTeamsURL + `", format: teams}
  - name: mail
    kind: smtp
    smtp: {host: smtp.corp.example, port: 587, tls: starttls, username: alerts@corp.example, password: ` + seedSMTPPass + `, from: pgvigil@corp.example, to: [dba@corp.example]}
custom:
  - name: stuck orders
    sql: select count(*) from orders where note = 'acme-secret-literal'
    every: 5m
`
	p := filepath.Join(dir, "pgvigil.yaml")
	if err := os.WriteFile(p, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func noLeak(t *testing.T, where, text string, more ...string) {
	t.Helper()
	for _, s := range append(append([]string{}, seedLeaks...), more...) {
		if strings.Contains(text, s) {
			t.Errorf("%s holds %q:\n%s", where, s, text)
		}
	}
}

// The masked configuration shows the settings and nothing else: every secret, name, address, tag, comment and
// statement of the file is gone, and what is left is still YAML.
func TestReportMasksTheConfig(t *testing.T) {
	dir := t.TempDir()
	raw, err := os.ReadFile(seedConfig(t, dir))
	if err != nil {
		t.Fatal(err)
	}
	m := newMasker(false)
	got := m.config(raw, nil)
	noLeak(t, "the masked config", got, "acme", dir)
	for _, want := range []string{
		"query_text: normalized", "activity: 30s", "group_by: [env, team]", "platform: aurora", "engine: sqlserver",
		"region: us-east-1", "backup_full_warn_hours: 30", "min_severity: critical", "format: slack", "format: teams",
		"port: 587", "tls: starttls", "every: 5m", "disabled: [logs]", "name: instance-1", "name: instance-2",
		"actions_dsn: env:PGVIGIL_TEST_REPORT_ACTIONS # set in the environment of this command",
		"dsn: file:<masked> # the file was read", "# an inline connection string, keyword form", "# an inline connection string, URL form",
		"env_order: [<masked>, <masked>]", "password: <masked>",
		// a tag is written env:prod: data, never read as an env: indirection (env:prodsite7 was shown, with a note, before the fix)
		"tags: [<masked>, <masked>, <masked>]",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("the masked config lacks %q:\n%s", want, got)
		}
	}
	var back map[string]any
	if err := yaml.Unmarshal([]byte(got), &back); err != nil {
		t.Fatalf("the masked config is not YAML: %v\n%s", err, got)
	}
	if n := len(back["instances"].([]any)); n != 2 {
		t.Errorf("instances in the masked config: %d, want 2", n)
	}
	if m.repoDSN == "" || !strings.Contains(m.repoDSN, seedRepoPass) {
		t.Errorf("the repository connection string was not taken from the file: %q", m.repoDSN)
	}
	// an unset variable says so; a key that is no plain name and a value of another shape under a kept key are masked
	odd := m.config([]byte("repository:\n  dsn: env:PGVIGIL_TEST_REPORT_UNSET\n\"postgres://u:KeyLeak-1234@h/d\": 1\ninstances: [{name: a, platform: \"postgres://u:ShapeLeak-1234@h/d\"}]\n"), nil)
	noLeak(t, "the odd config", odd, "KeyLeak-1234", "ShapeLeak-1234")
	for _, want := range []string{"env:PGVIGIL_TEST_REPORT_UNSET # NOT set in the environment of this command", "<masked-key>: <masked>", "platform: <masked>"} {
		if !strings.Contains(odd, want) {
			t.Errorf("the odd config lacks %q:\n%s", want, odd)
		}
	}
	// a value of the wrong type: the YAML reader quotes its first characters in its error, the check line does not
	dir2 := t.TempDir()
	typed := filepath.Join(dir2, "typed.yaml")
	if err := os.WriteFile(typed, []byte("repository: TypeLeak-12345678\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir2, "typed.zip")
	if err := runReportTo(context.Background(), []string{"-config", typed, "-out", out}, io.Discard); err != nil {
		t.Fatal(err)
	}
	typedCfg := readZip(t, out)["config.yaml"]
	noLeak(t, "the mistyped config", typedCfg, "TypeLea")
	if !strings.Contains(typedCfg, "# configuration check: ") || !strings.Contains(typedCfg, "cannot unmarshal") {
		t.Errorf("the mistyped config's check line: %s", typedCfg)
	}
	// a file that is not YAML is not copied in any form
	bad := m.config([]byte("repository:\n  dsn: [unclosed password=BadYaml-1234\n"), nil)
	noLeak(t, "the not-YAML note", bad, "BadYaml-1234")
	if !strings.Contains(bad, "not valid YAML and is not copied") {
		t.Errorf("the not-YAML note: %s", bad)
	}
}

// Error text keeps its words and loses the configuration's values, the instance names (written as their aliases) and
// whatever looks like a credential or an address, known or not.
func TestReportScrubsErrorText(t *testing.T) {
	dir := t.TempDir()
	raw, err := os.ReadFile(seedConfig(t, dir))
	if err != nil {
		t.Fatal(err)
	}
	m := newMasker(false)
	m.config(raw, nil)
	for _, c := range []struct{ in, want string }{
		{"failed to connect to `user=monitor_login database=orders`: 10.20.30.40:5432 (orders01.corp.example): server error: FATAL: password authentication failed for user \"monitor_login\"",
			"failed to connect to `user=<masked> database=<masked>`: <ip>:5432 (<masked>): server error: FATAL: password authentication failed for user \"<masked>\""},
		{`Post "` + seedSlackURL + `": dial tcp: lookup hooks.slack.example: no such host`,
			`Post "<masked>": dial tcp: lookup <masked>: no such host`},
		// the alias stands for the name as a word of its own; inside a longer word only the database's name (orders) goes
		{"instance acme-orders-db01: the statement timed out (acme-orders-db01x is another word)",
			"instance instance-1: the statement timed out (acme-<masked>-db01x is another word)"},
		// values the configuration does not hold
		{"cannot parse postgres://someone:hunter2hunter2@other.host.example/db", "cannot parse postgres://<masked>@other.host.example/db"},
		{"dial tcp 192.168.7.9:1433: connect: connection refused; password=abc12345 host=h9.example", "dial tcp <ip>:1433: connect: connection refused; password=<masked> host=<masked>"},
		{`the body {"token":"tok_live_12345","text":"x"} was refused by https://other.example/hooks/AAA/BBB?sig=CCC`, `the body {"token":<masked>,"text":"x"} was refused by https://other.example/<masked>`},
		{`database "postgres" does not exist on 127.0.0.1`, `database "postgres" does not exist on 127.0.0.1`},
		{"the env value " + seedEnvPass + " at envhost.corp.example and the file's " + seedADOPass, "the env value <masked> at <masked> and the file's <masked>"},
	} {
		if got := m.text(c.in); got != c.want {
			t.Errorf("text(%q)\n got %q\nwant %q", c.in, got, c.want)
		}
	}
	// with -names the instance names stay; the secrets go as before
	k := newMasker(true)
	k.config(raw, nil)
	// the name stays whole although the database's name (orders) is a part of it
	if got := k.text("instance acme-orders-db01: password " + seedInstPass + " in database orders"); got != "instance acme-orders-db01: password <masked> in database <masked>" {
		t.Errorf("-names: %q", got)
	}
}

// A connection string gives up its password and its host, user and database names in every form the drivers take.
func TestReportDSNParts(t *testing.T) {
	has := func(list []string, v string) bool {
		for _, s := range list {
			if s == v {
				return true
			}
		}
		return false
	}
	for _, c := range []struct {
		dsn             string
		secrets, idents []string
	}{
		{"postgres://u1name:p%40ss1word@h1.example:5432/d1name?sslmode=require", []string{"p%40ss1word", "p@ss1word"}, []string{"u1name", "h1.example", "d1name"}},
		{`host=h2.example user=u2name password='pa ss\'2' dbname=d2name`, []string{"pa ss'2"}, []string{"h2.example", "u2name", "d2name"}},
		{"server=tcp:h3.example,1433;User ID=u3name;Password=p3secret;Initial Catalog=d3name", []string{"p3secret"}, []string{"h3.example", "u3name", "d3name"}},
		{"sqlserver://u4name:p4secret@h4.example:1433?database=d4name&password=q4secret", []string{"p4secret", "q4secret"}, []string{"u4name", "h4.example", "d4name"}},
		{"sqlserver://u5name:p5/sec?ret@h5.example:1433?database=d5name", []string{"p5/sec?ret"}, []string{"u5name"}},
		{"https://hooks.example/services/AAA/BBB?sig=SSSS", []string{"services/AAA/BBB?sig=SSSS", "SSSS"}, []string{"hooks.example"}},
	} {
		sec, ids := dsnParts(c.dsn)
		for _, w := range c.secrets {
			if !has(sec, w) {
				t.Errorf("%s: secrets %q lack %q", c.dsn, sec, w)
			}
		}
		for _, w := range c.idents {
			if !has(ids, w) {
				t.Errorf("%s: idents %q lack %q", c.dsn, ids, w)
			}
		}
	}
}

func readZip(t *testing.T, path string) map[string]string {
	t.Helper()
	zr, err := zip.OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	out := map[string]string{}
	for _, f := range zr.File {
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatal(err)
		}
		out[f.Name] = string(b)
	}
	return out
}

// The whole command against a repository that does not answer: the zip is still written, for its owner alone, with
// the six files, this binary's version line and none of the seeded values; the names are on the terminal only; a
// second run never replaces the file.
func TestReportZip(t *testing.T) {
	dir := t.TempDir()
	cfg := seedConfig(t, dir)
	out := filepath.Join(dir, "r.zip")
	var stdout bytes.Buffer
	if err := runReportTo(context.Background(), []string{"-config", cfg, "-out", out}, &stdout); err != nil {
		t.Fatalf("report: %v", err)
	}
	files := readZip(t, out)
	for _, name := range []string{"README.txt", "version.txt", "config.yaml", "repository.txt", "instances.txt", "collection-errors.txt"} {
		if _, ok := files[name]; !ok {
			t.Errorf("the zip lacks %s (it holds %d files)", name, len(files))
		}
	}
	if len(files) != 6 {
		t.Errorf("files in the zip: %d, want 6", len(files))
	}
	for name, body := range files {
		noLeak(t, name, body, "acme", dir)
	}
	if !strings.HasPrefix(files["version.txt"], versionLine()+"\n") {
		t.Errorf("version.txt does not start with the version line %q:\n%s", versionLine(), files["version.txt"])
	}
	if !strings.Contains(files["repository.txt"], "repository: not read: no connection: ") {
		t.Errorf("repository.txt: %s", files["repository.txt"])
	}
	if !strings.Contains(files["config.yaml"], "# configuration check: ") || !strings.Contains(files["config.yaml"], "name: instance-1") {
		t.Errorf("config.yaml: %s", files["config.yaml"])
	}
	if !strings.Contains(files["README.txt"], supportAddress) {
		t.Errorf("README.txt does not name %s", supportAddress)
	}
	if runtime.GOOS != "windows" {
		st, err := os.Stat(out)
		if err != nil || st.Mode().Perm() != 0o600 {
			t.Errorf("the zip's mode: %v %v, want 0600", st.Mode().Perm(), err)
		}
	}
	said := stdout.String()
	for _, want := range []string{"wrote " + out + " (6 files, ", "instance-1 = acme-orders-db01", "instance-2 = acme-erp-sql01", "Nothing was sent.", supportAddress} {
		if !strings.Contains(said, want) {
			t.Errorf("the terminal lacks %q:\n%s", want, said)
		}
	}
	noLeak(t, "the terminal", said)

	// never replaced
	before, _ := os.ReadFile(out)
	err := runReportTo(context.Background(), []string{"-config", cfg, "-out", out}, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "exists already") {
		t.Errorf("a second run on the same file: %v, want the exists-already error", err)
	}
	if after, _ := os.ReadFile(out); !bytes.Equal(before, after) {
		t.Error("the second run changed the first zip")
	}

	// -names keeps the instance names (and nothing else); a -dsn on the command line is a secret like the file's
	named := filepath.Join(dir, "named.zip")
	stdout.Reset()
	if err := runReportTo(context.Background(), []string{"-config", cfg, "-out", named, "-names", "-dsn", "postgres://flaguser_x:" + seedFlagPass + "@127.0.0.1:1/flagdb_x"}, &stdout); err != nil {
		t.Fatalf("report -names: %v", err)
	}
	nf := readZip(t, named)
	if !strings.Contains(nf["config.yaml"], "name: acme-orders-db01") {
		t.Errorf("-names: config.yaml lacks the instance name:\n%s", nf["config.yaml"])
	}
	for name, body := range nf {
		noLeak(t, "-names "+name, body, "flaguser_x", "flagdb_x")
	}
	if strings.Contains(stdout.String(), "instance-1 =") {
		t.Errorf("-names printed a list of aliases:\n%s", stdout.String())
	}
}

// A configuration file that is not there still gives a report (the version, and why the rest is missing); a bad
// command line is a usage error and writes nothing.
func TestReportWithoutAConfigAndUsage(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "r.zip")
	if err := runReportTo(context.Background(), []string{"-config", filepath.Join(dir, "none.yaml"), "-out", out}, io.Discard); err != nil {
		t.Fatalf("report without a config: %v", err)
	}
	files := readZip(t, out)
	if !strings.Contains(files["config.yaml"], "the configuration file was not read: ") || strings.Contains(files["config.yaml"], dir) {
		t.Errorf("config.yaml: %s", files["config.yaml"])
	}
	if !strings.Contains(files["repository.txt"], "not read: no repository connection string") {
		t.Errorf("repository.txt: %s", files["repository.txt"])
	}
	if !strings.HasPrefix(files["version.txt"], versionLine()+"\n") {
		t.Errorf("version.txt: %s", files["version.txt"])
	}
	for _, args := range [][]string{{"-errors", "0"}, {"-errors", "5001"}, {"extra"}, {"-no-such-flag"}} {
		p := filepath.Join(dir, "usage.zip")
		err := runReportTo(context.Background(), append([]string{"-out", p}, args...), io.Discard)
		var ec interface{ ExitCode() int }
		if err == nil || !errors.As(err, &ec) || ec.ExitCode() != 2 {
			t.Errorf("%v: got %v, want a usage error with exit code 2", args, err)
		}
		if _, statErr := os.Stat(p); statErr == nil {
			t.Errorf("%v: a zip was written", args)
		}
	}
}
