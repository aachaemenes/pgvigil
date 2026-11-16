package collect

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// ST6b: rule status - DBA Dash's custom check (dbo.DBADash_CustomCheck: Test, Context, Status 1-4, Info), the rows
// judge themselves. A SQL Server check's alone; no threshold, compare or value column beside it; each refusal by its
// words. Red on the base: 'rule must be value or rows'.
func TestCustomStatusRule(t *testing.T) {
	ms := config.Instance{Name: "sql01", Engine: config.EngineSQLServer}
	cs, _, err := ParseCustomChecks([]byte(`custom:
  - {name: dbadash_custom_check, procedure: dbo.DBADash_CustomCheck, rule: status, every: 1h}
  - {name: s2, engine: sqlserver, rule: Status, sql: "SELECT N'backup' AS Test, N'db1' AS Context, 1 AS Status, N'x' AS Info"}
`), []config.Instance{ms})
	if err != nil || len(cs) != 2 {
		t.Fatalf("parse: %v %d", err, len(cs))
	}
	for _, c := range cs {
		if c.Rule != "status" || c.EngineOf() != config.EngineSQLServer || c.Warning != nil || c.Critical != nil || c.Value != "" {
			t.Errorf("%s: rule %q engine %q warning %v critical %v value %q", c.Name, c.Rule, c.EngineOf(), c.Warning, c.Critical, c.Value)
		}
	}
	for _, bad := range []struct{ yaml, want string }{
		{`{name: p, sql: SELECT 1, rule: status}`, "rule status reads DBA Dash's custom check columns (Test, Context, Status, Info): a SQL Server check's"},
		{`{name: p, engine: postgres, sql: SELECT 1, rule: status}`, "a SQL Server check's"},
		{`{name: w, procedure: dbo.c, rule: status, warning: 1}`, "rule status takes no warning or critical: each row carries its own Status"},
		{`{name: k, procedure: dbo.c, rule: status, critical: 1}`, "rule status takes no warning or critical"},
		{`{name: c, procedure: dbo.c, rule: status, compare: ">="}`, "rule status takes no compare"},
		{`{name: v, procedure: dbo.c, rule: status, value: n}`, "rule status takes no value column"},
		{`{name: x, procedure: dbo.c, rule: state}`, "rule must be value, rows or status"},
	} {
		_, _, err := ParseCustomChecks([]byte("custom:\n  - "+bad.yaml+"\n"), []config.Instance{ms})
		if err == nil || !strings.Contains(err.Error(), bad.want) {
			t.Errorf("%s: %v, want %q", bad.yaml, err, bad.want)
		}
	}
}
