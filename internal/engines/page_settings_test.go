package engines

import (
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The page's judgement of a page instance's settings (ST5a): a collection of the instance's engine, not the running
// plans box's, one that may run on an instance added in the page, an interval off or from a minute to 30 days; the
// catalogue the panel lists names the box's collection, the opt-in ones and the ones that never run there.
func TestPageSettingsCheck(t *testing.T) {
	m := time.Minute
	for _, c := range []struct {
		engine string
		sch    map[string]time.Duration
		want   string
	}{
		{config.EnginePostgres, map[string]time.Duration{"statements": m, "activity": 0, "amcheck": 6 * time.Hour}, ""},
		{config.EnginePostgres, map[string]time.Duration{"statements": 59 * time.Second}, "statements every 59s: an interval set here is a minute or more"},
		{config.EnginePostgres, map[string]time.Duration{"statements": 31 * 24 * time.Hour}, "statements every 744h0m0s: an interval set here is 30 days or less"},
		{config.EnginePostgres, map[string]time.Duration{"statements2": m}, `unknown collection "statements2"`},
		{config.EnginePostgres, map[string]time.Duration{"mssql_activity": m}, `"mssql_activity" is a sqlserver collection and the instance's engine is postgres`},
		{config.EngineSQLServer, map[string]time.Duration{"activity": m}, `"activity" is a postgres collection and the instance's engine is sqlserver`},
		{config.EngineSQLServer, map[string]time.Duration{RunningPlans: m}, "mssql_running_plans is the running plans box's: tick or clear the box on the instance's row"},
		{config.EngineSQLServer, map[string]time.Duration{RunningPlans: 0}, "mssql_running_plans is the running plans box's"},
		{config.EnginePostgres, map[string]time.Duration{"pgbouncer": m}, "pgbouncer never runs on an instance added here: no pgbouncer: DSN for this instance"},
		{config.EnginePostgres, map[string]time.Duration{"pgbouncer": 0}, ""},
	} {
		err := CheckPageSettings(c.engine, config.PageSettings{Schedules: c.sch})
		got := ""
		if err != nil {
			got = err.Error()
		}
		if c.want == "" && got != "" || c.want != "" && !strings.HasPrefix(got, c.want) {
			t.Errorf("%s %v: %q, want %q", c.engine, c.sch, got, c.want)
		}
	}
	by := func(engine string) map[string]PageCollection {
		out := map[string]PageCollection{}
		for _, c := range PageCatalogue(engine) {
			out[c.Name] = c
		}
		return out
	}
	pg, ms := by(config.EnginePostgres), by(config.EngineSQLServer)
	if c := pg["amcheck"]; c.Default != 0 || c.Never != "" {
		t.Errorf("amcheck: %+v (want opt-in: default 0, settable)", c)
	}
	if c := pg["pgbouncer"]; c.Never == "" {
		t.Errorf("pgbouncer: %+v (want never on a page instance: it needs a pgbouncer: DSN)", c)
	}
	if c := pg["statements"]; c.Default != 5*time.Minute || c.Never != "" || c.Box {
		t.Errorf("statements: %+v", c)
	}
	if c := ms[RunningPlans]; !c.Box {
		t.Errorf("%s: %+v (want the box's)", RunningPlans, c)
	}
	if _, ok := pg["mssql_activity"]; ok {
		t.Error("the PostgreSQL catalogue lists a SQL Server collection")
	}
}
