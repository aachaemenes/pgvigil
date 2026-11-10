// Package engines is the one place that knows there is more than one engine: it names the collections of each,
// says which engine a collection belongs to, and sends a run to that engine's collector package. The scheduler and
// the command line go through it, so a collection of one engine never runs on an instance of another.
package engines

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Spec is one collection as the scheduler needs it.
type Spec struct {
	Name    string
	Engine  string
	Default time.Duration
}

// Specs lists the collections of one engine, sorted by name; an unknown engine has none.
func Specs(engine string) []Spec {
	var out []Spec
	switch engine {
	case config.EnginePostgres:
		for _, c := range collect.All() {
			out = append(out, Spec{c.Name(), engine, c.DefaultInterval()})
		}
	case config.EngineSQLServer:
		for _, c := range mssql.All() {
			out = append(out, Spec{c.Name(), engine, c.DefaultInterval()})
		}
	}
	return out
}

// AllSpecs lists every collection of every engine, sorted by name.
func AllSpecs() []Spec {
	out := append(Specs(config.EnginePostgres), Specs(config.EngineSQLServer)...)
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Names lists every collection of every engine, sorted.
func Names() []string {
	specs := AllSpecs()
	out := make([]string, len(specs))
	for i, s := range specs {
		out[i] = s.Name
	}
	return out
}

// EngineOf names the engine a collection belongs to, and false for a name no engine has.
func EngineOf(name string) (string, bool) {
	if _, ok := collect.Get(name); ok {
		return config.EnginePostgres, true
	}
	if _, ok := mssql.Get(name); ok {
		return config.EngineSQLServer, true
	}
	return "", false
}

// engineOfInstance is the instance's engine; an instance built without Validate (a test) is PostgreSQL.
func engineOfInstance(in config.Instance) string {
	if in.Engine == "" {
		return config.EnginePostgres
	}
	return in.Engine
}

// Gated reports whether a collection is off for an instance before any connection: it belongs to another engine,
// or the instance's config does not name its source.
func Gated(in config.Instance, name string) (skip bool, why string) {
	e, ok := EngineOf(name)
	if !ok {
		return true, "unknown collection"
	}
	if ie := engineOfInstance(in); e != ie {
		return true, fmt.Sprintf("a %s collection; the instance's engine is %s", e, ie)
	}
	if e == config.EnginePostgres {
		c, _ := collect.Get(name)
		return collect.Gated(c, in)
	}
	return false, ""
}

// RunOnce runs one collection against one instance through its engine's collector package.
func RunOnce(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string) collect.Result {
	e, ok := EngineOf(name)
	if !ok {
		return collect.Result{Err: fmt.Errorf("unknown collection %q; known: %v", name, Names())}
	}
	if ie := engineOfInstance(in); e != ie {
		return collect.Result{Note: fmt.Sprintf(" (skipped: a %s collection; the instance's engine is %s)", e, ie)}
	}
	if e == config.EngineSQLServer {
		return mssql.RunOnce(ctx, log, r, in, name)
	}
	return collect.RunOnce(ctx, log, r, in, name)
}
