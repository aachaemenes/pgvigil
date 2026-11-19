package main

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// TestExportNoSecretsL155 (the lead's 04:29 (1)): -no-secrets writes pgvigil.yaml with each inline secret masked -
// a connection string's password part in every form, a channel's webhook, a key or token - and the rest as written:
// hosts, users, every reference; a dpapi: reference is marked not portable. The notes name keys, never values.
func TestExportNoSecretsL155(t *testing.T) {
	in := `repository:
  dsn: host=repo user=pgvigil_collector password='repo secret' dbname=pgvigil
reports_dsn: postgres://rep:urlsecret@h:5432/pgvigil
instances:
  - name: pg1
    dsn: env:PG1_DSN
  - name: pg2
    dsn: 'dpapi:C:\ProgramData\pgvigil\secrets\pg2-ab12.dsn'
  - name: sql1
    engine: sqlserver
    dsn: sqlserver://h:1433?database=d&user+id=u&password=adosecret&encrypt=true
  - name: sql2
    engine: sqlserver
    dsn: Server=h2;User Id=u2;Password=semisecret;Database=d
alerts:
  channels:
    - name: ops
      kind: slack
      url: https://hooks.slack.com/services/T000/B000/slacksecret
    - name: pd
      kind: pagerduty
      routing_key: pdsecret
query_text: full
`
	out, notes, err := exportNoSecrets([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	for _, secret := range []string{"repo secret", "urlsecret", "adosecret", "semisecret", "slacksecret", "pdsecret"} {
		if strings.Contains(s, secret) || strings.Contains(strings.Join(notes, "\n"), secret) {
			t.Errorf("-no-secrets kept %q:\n%s\nnotes %q", secret, s, notes)
		}
	}
	for _, kept := range []string{"host=repo", "user=pgvigil_collector", "dbname=pgvigil", "rep:", "@h:5432/pgvigil", "env:PG1_DSN", `dpapi:C:\ProgramData\pgvigil\secrets\pg2-ab12.dsn`, "database=d", "encrypt=true", "Server=h2", "User Id=u2", "name: ops", "kind: pagerduty", "query_text: full", "not portable"} {
		if !strings.Contains(s, kept) {
			t.Errorf("-no-secrets lost %q:\n%s", kept, s)
		}
	}
	var doc map[string]any
	if err := yaml.Unmarshal(out, &doc); err != nil {
		t.Errorf("the masked file is not YAML: %v", err)
	}
	if len(notes) < 7 || !strings.Contains(strings.Join(notes, "\n"), "instances.[].dsn") {
		t.Errorf("the notes %q: want each masked key and the dpapi: reference by its key", notes)
	}
}
