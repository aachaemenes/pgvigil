package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/cloudrepl"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// cloudReplicasCollector is cloud_replicas (task 390b P1 / P2): an RDS for PostgreSQL or Cloud SQL for PostgreSQL
// instance's read replicas through the provider's own API (internal/cloudrepl) - the topology, each replica's status
// and its lag - with no SQL statement: a replica pgvigil does not connect to still has its lag. The door is the
// instance's aws: block with replicas: true (P1, off by default) or its gcp: block (P2). The store keeps one row per
// resource whoever reads it (0151 part P).
type cloudReplicasCollector struct{}

func init() { Register(cloudReplicasCollector{}) }

func (cloudReplicasCollector) Name() string                   { return "cloud_replicas" }
func (cloudReplicasCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

func (cloudReplicasCollector) Applies(info platform.Info) (bool, string) {
	if info.Kind != platform.RDS && info.Kind != platform.CloudSQL {
		return false, "the provider replicas are read for RDS for PostgreSQL and Cloud SQL for PostgreSQL (Aurora's replicas are not this collection)"
	}
	return true, ""
}

// Configured: the run happens only where the configuration opens a door.
func (cloudReplicasCollector) Configured(in config.Instance) (bool, string) {
	if p, why := cloudrepl.Which(in); p == "" {
		return false, why
	}
	return true, ""
}

func (cloudReplicasCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("cloud_replicas needs the instance config: %w", ErrSkip)
}

// cloudReplicasDoor is the process's door (a test stands its own in)
var cloudReplicasDoor = cloudrepl.Default

func (c cloudReplicasCollector) RunInstance(ctx context.Context, _ *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	if ok, why := c.Configured(in); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	if ok, why := c.Applies(info); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	p, _ := cloudrepl.Which(in)
	if want := map[string]platform.Kind{"aws": platform.RDS, "gcp": platform.CloudSQL}[p]; info.Kind != want {
		return nil, fmt.Errorf("the %s: block's door reads a %s instance, and this one is %s: %w", p, want, info.Kind, ErrSkip)
	}
	rows, err := cloudReplicasDoor.Rows(ctx, in)
	if err != nil {
		return nil, err
	}
	out := make([]Row, len(rows))
	for i, r := range rows {
		out[i] = r
	}
	return out, nil
}
