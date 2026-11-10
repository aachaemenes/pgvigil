package collect

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// compareCollector is the baseline compare's clock (task 57): once an hour per instance it sends one state row, and
// the repository's import (pgvigil.import_compare, 0054) computes the instance's regressions of the last 24 hours
// against the same window one and seven days earlier into compare_findings_cache. Nothing is read on the monitored
// server: the compare reads the statements collection's deltas already in the repository, so a findings read never
// computes one. Its own collection (not a ride on another), so turning another collection off never silences it.
type compareCollector struct{}

func init() { Register(compareCollector{}) }

func (compareCollector) Name() string                   { return "compare" }
func (compareCollector) DefaultInterval() time.Duration { return time.Hour }
func (compareCollector) Applies(platform.Info) (bool, string) {
	return true, "" // an instance without statement deltas simply has no regression
}

func (compareCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return []Row{{"kind": "state", "status": "ok"}}, nil
}
