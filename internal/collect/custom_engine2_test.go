package collect

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// the engine, procedure: and database: keys: the defaults and each refusal by its words
func TestCustomEngineParse(t *testing.T) {
	pg := config.Instance{Name: "erp01", Engine: config.EnginePostgres}
	ms := config.Instance{Name: "sql01", Engine: config.EngineSQLServer}
	ins := []config.Instance{pg, ms}
	cs, _, err := ParseCustomChecks([]byte(`custom:
  - {name: a, sql: SELECT 1}
  - {name: b, engine: SQLServer, sql: "SELECT 1 AS value;", database: " Sales DB "}
  - {name: c, procedure: Utility.dbo.pgvigil_check_jobs}
  - {name: d, engine: sqlserver, procedure: pgvigil_check}
  - {name: e, engine: postgres, sql: SELECT 1}
`), ins)
	if err != nil || len(cs) != 5 {
		t.Fatalf("parse: %v %d", err, len(cs))
	}
	for i, want := range []string{"postgres", "sqlserver", "sqlserver", "sqlserver", "postgres"} {
		if cs[i].Engine != want || cs[i].EngineOf() != want {
			t.Errorf("%s: engine %q / %q, want %q", cs[i].Name, cs[i].Engine, cs[i].EngineOf(), want)
		}
	}
	if cs[1].SQL != "SELECT 1 AS value" || cs[1].Database != "Sales DB" || cs[2].Procedure != "Utility.dbo.pgvigil_check_jobs" || cs[2].SQL != "" {
		t.Errorf("trimming: %+v / %+v", cs[1], cs[2])
	}
	bad := map[string]struct{ yaml, want string }{
		"an unknown engine":       {"custom: [{name: a, engine: oracle, sql: SELECT 1}]", "engine must be postgres or sqlserver"},
		"a PostgreSQL procedure":  {"custom: [{name: a, engine: postgres, procedure: dbo.p}]", "procedure: is a SQL Server check's"},
		"both forms":              {"custom: [{name: a, engine: sqlserver, sql: SELECT 1, procedure: dbo.p}]", "give one of them"},
		"neither form":            {"custom: [{name: a, engine: sqlserver}]", "sql or procedure is required"},
		"four parts":              {"custom: [{name: a, procedure: srv.db.dbo.p}]", "procedure must be a name of 1 to 3 parts"},
		"a bracket":               {"custom: [{name: a, procedure: '[dbo].[p]'}]", "no bracket or quote"},
		"a statement in the name": {"custom: [{name: a, procedure: 'dbo.p; DROP TABLE x'}]", "procedure must be"},
		"a procedure's database":  {"custom: [{name: a, procedure: dbo.p, database: Sales}]", "database: is for a sql: check"},
		"a PostgreSQL database":   {"custom: [{name: a, sql: SELECT 1, database: app}]", "database: is a SQL Server check's"},
		"a bracket in a database": {"custom: [{name: a, engine: sqlserver, sql: SELECT 1, database: 'x]y'}]", "without a bracket"},
	}
	for k, c := range bad {
		if _, _, err := ParseCustomChecks([]byte(c.yaml), ins); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want an error with %q, got %v", k, c.want, err)
		}
	}
	// a check naming an instance of the other engine: a warning (it does not run there), never an error
	_, _, warns, err := ParseCustomChecksWarn([]byte("custom: [{name: a, sql: SELECT 1, instances: [sql01, erp01]}]"), ins)
	if err != nil || len(warns) != 1 || !strings.Contains(warns[0], `instance "sql01" is a SQL Server instance and the check is engine: postgres`) {
		t.Errorf("a PostgreSQL check naming a SQL Server instance: %v %v", err, warns)
	}
	_, _, warns, err = ParseCustomChecksWarn([]byte("custom: [{name: a, engine: sqlserver, sql: SELECT 1, instances: [erp01]}]"), ins)
	if err != nil || len(warns) != 2 || !strings.Contains(strings.Join(warns, "|"), `instance "erp01" is a PostgreSQL instance`) || !strings.Contains(strings.Join(warns, "|"), "match no instance of the file") {
		t.Errorf("a SQL Server check naming only a PostgreSQL instance: %v %v", err, warns)
	}
	// every procedure name the custom reports' pattern takes, and none it refuses
	for name, ok := range map[string]bool{"p": true, "dbo.p": true, "Utility.dbo.p_2$#": true, "_x": true, "1p": false, "a..b": false, "a.b.c.d": false, "a b": false, "a'b": false} {
		if CustomProcRE.MatchString(name) != ok {
			t.Errorf("procedure %q: matched %v, want %v", name, !ok, ok)
		}
	}
}
