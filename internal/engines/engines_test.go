package engines

import (
	"context"
	"log/slog"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// No collection name belongs to two engines, every SQL Server one carries the prefix and no PostgreSQL one does.
func TestNamesAreOneEngineEach(t *testing.T) {
	seen := map[string]string{}
	for _, s := range AllSpecs() {
		if e, dup := seen[s.Name]; dup {
			t.Errorf("collection %q is registered for %s and %s", s.Name, e, s.Engine)
		}
		seen[s.Name] = s.Engine
		if got := strings.HasPrefix(s.Name, mssql.Prefix); got != (s.Engine == config.EngineSQLServer) {
			t.Errorf("collection %q of engine %s: prefix %q present = %v", s.Name, s.Engine, mssql.Prefix, got)
		}
		if e, ok := EngineOf(s.Name); !ok || e != s.Engine {
			t.Errorf("EngineOf(%q) = %q, %v; want %q", s.Name, e, ok, s.Engine)
		}
	}
	if len(Specs(config.EnginePostgres)) == 0 || len(Specs(config.EngineSQLServer)) == 0 {
		t.Fatal("an engine has no collection")
	}
	if len(Specs("oracle")) != 0 {
		t.Error("an unknown engine has collections")
	}
}

// A collection of the other engine is gated before any connection and a run of it is a skip with the reason: no
// repository and no server are touched (both are nil here).
func TestOtherEngineIsSkippedWithoutAConnection(t *testing.T) {
	pg := config.Instance{Name: "pg", Engine: config.EnginePostgres, DSNRaw: "host=nowhere"}
	ms := config.Instance{Name: "ms", Engine: config.EngineSQLServer, DSNRaw: "sqlserver://nowhere"}
	old := config.Instance{Name: "old", DSNRaw: "host=nowhere"} // built without Validate: PostgreSQL
	for _, c := range []struct {
		in   config.Instance
		name string
		want string
	}{
		{pg, "mssql_instance", "a sqlserver collection; the instance's engine is postgres"},
		{old, "mssql_instance", "a sqlserver collection; the instance's engine is postgres"},
		{ms, "databases", "a postgres collection; the instance's engine is sqlserver"},
	} {
		if skip, why := Gated(c.in, c.name); !skip || why != c.want {
			t.Errorf("Gated(%s, %s) = %v, %q", c.in.Name, c.name, skip, why)
		}
		res := RunOnce(context.Background(), slog.Default(), nil, c.in, c.name)
		if res.Err != nil || !strings.Contains(res.Note, c.want) || res.Rows != 0 {
			t.Errorf("RunOnce(%s, %s) = %+v", c.in.Name, c.name, res)
		}
	}
	if skip, _ := Gated(ms, "mssql_instance"); skip {
		t.Error("a SQL Server collection is gated on a SQL Server instance")
	}
	if skip, _ := Gated(pg, "databases"); skip {
		t.Error("databases is gated on a PostgreSQL instance")
	}
	if res := RunOnce(context.Background(), slog.Default(), nil, pg, "no_such"); res.Err == nil {
		t.Error("an unknown collection ran")
	}
}
