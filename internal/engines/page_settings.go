package engines

import (
	"fmt"
	"sort"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// The page's side of an instance's schedules (Admin > Instances' Settings, the ServiceConfig takes' ST5a): which
// collections an instance added in the page may be given an interval, and the judgement of what the panel sends.
// pgvigil.yaml's check (cmd/pgvigil checkCollectionNames) and the page's share CheckCollection.

// RunningPlans is the collection the running plans box controls on a page instance (task 406): the panel never
// sets it.
const RunningPlans = "mssql_running_plans"

// CheckCollection says why a collection cannot be named for an instance of the engine ("" = PostgreSQL): no
// collection has the name, or it is another engine's.
func CheckCollection(engine, name string) error {
	if engine == "" {
		engine = config.EnginePostgres
	}
	e, ok := EngineOf(name)
	if !ok {
		return fmt.Errorf("unknown collection %q", name)
	}
	if e != engine {
		return fmt.Errorf("%q is a %s collection and the instance's engine is %s", name, e, engine)
	}
	return nil
}

// PageCollection is one collection as the panel lists it for an instance added in the page.
type PageCollection struct {
	Name    string
	Default time.Duration // the collection's own (0 = opt-in: it runs only on an instance that names it)
	Box     bool          // the running plans box controls it (not the panel)
	Never   string        // why it never runs on an instance added in the page ("" = it may)
}

// pageGate: whether the collection runs on a page instance of the engine given the interval d
func pageGate(engine, name string, d time.Duration) (bool, string) {
	in := config.Instance{Name: "page", Engine: engine, Platform: "auto", Schedules: map[string]config.Duration{name: {Duration: d}}}
	return Gated(in, name)
}

// PageCatalogue lists the collections of the engine as the panel shows them, sorted by name.
func PageCatalogue(engine string) []PageCollection {
	var out []PageCollection
	for _, s := range Specs(engine) {
		c := PageCollection{Name: s.Name, Default: s.Default, Box: s.Name == RunningPlans}
		// a collection that is still off with an interval of its own needs what a page instance never has (an aws:,
		// pgbouncer: or backups: block of pgvigil.yaml)
		if skip, why := pageGate(engine, s.Name, time.Hour); skip {
			c.Never = why
		}
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// CheckPageSettings judges a page instance's settings before serve stores them, in the panel's words: each collection
// is one of the instance's engine, not the running plans box's, and may run on an instance added in the page; each
// interval is off (0) or from config.PageScheduleFloor to config.PageScheduleCeiling. The shape (whole seconds,
// query_text's three words) is config.ParsePageSettings' and 0263's.
func CheckPageSettings(engine string, ps config.PageSettings) error {
	names := make([]string, 0, len(ps.Schedules))
	for n := range ps.Schedules {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		d := ps.Schedules[n]
		if err := CheckCollection(engine, n); err != nil {
			return err
		}
		switch {
		case n == RunningPlans:
			return fmt.Errorf("%s is the running plans box's: tick or clear the box on the instance's row", n)
		case d == 0:
			continue // off: nothing more to judge
		case d < config.PageScheduleFloor:
			return fmt.Errorf("%s every %s: an interval set here is a minute or more", n, d)
		case d > config.PageScheduleCeiling:
			return fmt.Errorf("%s every %s: an interval set here is 30 days or less", n, d)
		}
		if skip, why := pageGate(engine, n, d); skip {
			return fmt.Errorf("%s never runs on an instance added here: %s", n, why)
		}
	}
	// ST5b: a paused collection's own interval (kept for Resume) is the engine's and its schedule is off
	paused := make([]string, 0, len(ps.Paused))
	for n := range ps.Paused {
		paused = append(paused, n)
	}
	sort.Strings(paused)
	for _, n := range paused {
		if err := CheckCollection(engine, n); err != nil {
			return err
		}
		if d, ok := ps.Schedules[n]; !ok || d != 0 {
			return fmt.Errorf("paused %s: its schedule is not off", n)
		}
	}
	// ST5b: thresholds are a SQL Server instance's, judged by the collector's own rule (mssql.ThresholdRows' words)
	if len(ps.Thresholds) > 0 {
		if engine != config.EngineSQLServer {
			return fmt.Errorf("thresholds are a SQL Server instance's (mssql_thresholds); this instance is %s", engine)
		}
		if _, err := mssql.ThresholdRows(ps.Thresholds); err != nil {
			return err
		}
	}
	return nil
}

// ThresholdEntry is one threshold as the panel lists it: its name and the collector's default (backup_exclude: a list
// of LIKE patterns, no default).
type ThresholdEntry struct {
	Name     string
	Default  float64
	Patterns bool
}

// ThresholdCatalogue lists a SQL Server instance's thresholds from mssql.HADRThresholds itself, sorted, then
// backup_exclude.
func ThresholdCatalogue() []ThresholdEntry {
	out := make([]ThresholdEntry, 0, len(mssql.HADRThresholds)+1)
	for n, d := range mssql.HADRThresholds {
		out = append(out, ThresholdEntry{Name: n, Default: d})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return append(out, ThresholdEntry{Name: "backup_exclude", Patterns: true})
}
