package engines

import (
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
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

// TestPageSettingsThresholdsCheck (ST5b): serve's judgement of a page instance's thresholds and paused intervals - a
// SQL Server instance's only, each name one of mssql.ThresholdRows' (its own words), paused only for a collection of
// the engine whose schedule is off (Merge's round trip of a stored row is TestMergedPageThresholdRows, in
// scripts/st5b-wiring.patch: it needs PageInstance.SettingsRaw, a field of scripts/st5-wiring.patch).
func TestPageSettingsThresholdsCheck(t *testing.T) {
	for _, c := range []struct{ engine, raw, want string }{
		{config.EngineSQLServer, `{"thresholds": {"redo_queue_kb": 1, "backup_exclude": ["Sales%"]}}`, ""},
		{config.EngineSQLServer, `{"schedules": {"mssql_jobs": 0}, "paused": {"mssql_jobs": 600}}`, ""},
		{config.EnginePostgres, `{"thresholds": {"redo_queue_kb": 1}}`, "thresholds are a SQL Server instance's (mssql_thresholds); this instance is postgres"},
		{config.EngineSQLServer, `{"thresholds": {"nope": 1}}`, `mssql threshold "nope" is not known; known: `},
		{config.EngineSQLServer, `{"paused": {"mssql_jobs": 600}}`, "paused mssql_jobs: its schedule is not off"},
		{config.EngineSQLServer, `{"schedules": {"activity": 0}, "paused": {"activity": 600}}`, `"activity" is a postgres collection and the instance's engine is sqlserver`},
	} {
		ps, err := config.ParsePageSettings([]byte(c.raw))
		if err != nil {
			t.Errorf("%s: %v", c.raw, err)
			continue
		}
		got := ""
		if err := CheckPageSettings(c.engine, ps); err != nil {
			got = err.Error()
		}
		if c.want == "" && got != "" || c.want != "" && !strings.HasPrefix(got, c.want) {
			t.Errorf("%s %s: %q, want %q", c.engine, c.raw, got, c.want)
		}
	}
}

// TestThresholdCatalogue (ST5b): the panel's thresholds are mssql.HADRThresholds' with their defaults, then
// backup_exclude - the same names, in the same order, as 0266's c_known list (a change of one without the other fails
// here: TestAdminInstanceThresholdsOnAStore names the SQL side's list).
func TestThresholdCatalogue(t *testing.T) {
	var names []string
	for _, e := range ThresholdCatalogue() {
		names = append(names, e.Name)
		if e.Name != "backup_exclude" && e.Default != mssql.HADRThresholds[e.Name] {
			t.Errorf("%s: default %v, want %v", e.Name, e.Default, mssql.HADRThresholds[e.Name])
		}
	}
	want := "diff_backup_hours,full_backup_hours,job_failed_hours,job_long_factor,job_long_min_seconds,log_backup_minutes,log_send_queue_kb,new_database_hours,nul_backup_days,redo_queue_kb,repl_undistributed_commands,backup_exclude"
	if got := strings.Join(names, ","); got != want {
		t.Errorf("the catalogue: %s\nwant %s", got, want)
	}
}
