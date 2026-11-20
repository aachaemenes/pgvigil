package engines

import (
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// NotRun is one collection that will not run on an instance, and why (N59: Admin > Instances' Test lists them, as
// DBA Dash's add-connection review notes what it will not collect).
type NotRun struct {
	Name string `json:"name"`
	Why  string `json:"why"`
}

// NotRunning lists the collections of the instance's engine that will not run on it, by the scheduler's own rule
// (sched.go: cfg.Interval - the instance's disabled: list, its and the file's schedules: <name>: disabled, a default
// of none - then the config gates) and then the engine's Applies on the detected server (pg for PostgreSQL, ms for
// SQL Server; nil = not detected: only the configuration's reasons). cfg nil = the defaults (a page instance's form).
func NotRunning(cfg *config.Config, in config.Instance, pg *platform.Info, ms *mssql.Info) (out []NotRun, total int) {
	if cfg == nil {
		cfg = &config.Config{}
	}
	engine := in.Engine
	if engine == "" {
		engine = config.EnginePostgres
	}
	for _, s := range Specs(engine) {
		total++
		if why := offBy(cfg, in, s); why != "" {
			out = append(out, NotRun{s.Name, why})
			continue
		}
		if skip, why := Gated(in, s.Name); skip {
			out = append(out, NotRun{s.Name, why})
			continue
		}
		switch engine {
		case config.EngineSQLServer:
			c, ok := mssql.Get(s.Name)
			if !ok {
				continue
			}
			// RunOnce's order: the detected server's Applies, then the configuration's door (390a's mssql.Configurer:
			// the azure: block), which needs no detection
			if ms != nil {
				if ok, why := c.Applies(*ms); !ok {
					out = append(out, NotRun{s.Name, why})
					continue
				}
			}
			if cf, ok := c.(mssql.Configurer); ok {
				if ok, why := cf.Configured(in); !ok {
					out = append(out, NotRun{s.Name, why})
				}
			}
		default:
			c, ok := collect.Get(s.Name)
			if !ok || pg == nil {
				continue
			}
			if ok, why := c.Applies(*pg); !ok {
				out = append(out, NotRun{s.Name, why})
			}
		}
	}
	return out, total
}

// offBy names the setting that switches a collection off, or "" when it runs at some interval
func offBy(cfg *config.Config, in config.Instance, s Spec) string {
	if cfg.Interval(in, s.Name, s.Default) > 0 {
		return ""
	}
	for _, d := range in.Disabled {
		if d == s.Name {
			return "switched off: the instance's disabled: list"
		}
	}
	if v, ok := in.Schedules[s.Name]; ok && v.Duration <= 0 {
		return "switched off: the instance's schedules: " + s.Name + ": disabled"
	}
	if v, ok := cfg.Schedules[s.Name]; ok && v.Duration <= 0 {
		return "switched off: the configuration's schedules: " + s.Name + ": disabled"
	}
	if s.Default <= time.Duration(0) {
		return "off by default (schedules: " + s.Name + ": <interval> turns it on)"
	}
	return "switched off by the page's defaults"
}
