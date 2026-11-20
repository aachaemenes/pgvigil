package collect

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// ST6's red row, in the API the base has (yaml and AppliesTo only, so it builds there too): a check written for SQL
// Server runs on SQL Server instances and on no PostgreSQL instance; a check that names no engine is PostgreSQL's, as
// every file before ST6 means it. On the base the engine key is read into nothing and the check runs on PostgreSQL.
func TestCustomEngineTargets(t *testing.T) {
	pg := config.Instance{Name: "erp01", Engine: config.EnginePostgres, Tags: []string{"env:prod"}}
	pgBare := config.Instance{Name: "crm01", Tags: []string{"env:prod"}} // an instance whose engine was never set reads as PostgreSQL
	ms := config.Instance{Name: "sql01", Engine: config.EngineSQLServer, Tags: []string{"env:prod"}}
	ins := []config.Instance{pg, pgBare, ms}
	cs, _, err := ParseCustomChecks([]byte(`custom:
  - {name: ms_untargeted, engine: sqlserver, sql: SELECT 1 AS value}
  - {name: ms_tagged, engine: sqlserver, sql: SELECT 1 AS value, tags: [env:prod]}
  - {name: pg_untargeted, sql: SELECT 1 AS value}
  - {name: pg_tagged, sql: SELECT 1 AS value, tags: [env:prod]}
`), ins)
	if err != nil || len(cs) != 4 {
		t.Fatalf("parse: %v %d", err, len(cs))
	}
	for _, c := range cs[:2] {
		if c.AppliesTo(pg) || c.AppliesTo(pgBare) || !c.AppliesTo(ms) {
			t.Errorf("%s (engine sqlserver): on PostgreSQL %v / %v, on SQL Server %v; want false / false / true", c.Name, c.AppliesTo(pg), c.AppliesTo(pgBare), c.AppliesTo(ms))
		}
	}
	for _, c := range cs[2:] {
		if !c.AppliesTo(pg) || !c.AppliesTo(pgBare) || c.AppliesTo(ms) {
			t.Errorf("%s (no engine): on PostgreSQL %v / %v, on SQL Server %v; want true / true / false", c.Name, c.AppliesTo(pg), c.AppliesTo(pgBare), c.AppliesTo(ms))
		}
	}
	SetCustomChecks(cs, true)
	defer SetCustomChecks(nil, false)
	for _, c := range CustomFor(pg) {
		if strings.HasPrefix(c.Name, "ms_") {
			t.Errorf("the PostgreSQL collector would run %s on %s", c.Name, pg.Name)
		}
	}
}
