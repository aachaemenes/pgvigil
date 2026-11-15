package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/aachaemenes/pgvigil/internal/cloudrepl"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// cloudReplicasCollector is mssql_cloud_replicas (task 390b P1): an RDS for SQL Server instance's read replicas
// through RDS and CloudWatch (internal/cloudrepl) - the topology, each replica's status, its ReplicaLag - with no T-SQL
// statement. The door is the instance's aws: block with replicas: true (off by default; region, profile and
// db_instance are the block's keys on SQL Server: fold 3). RDS for SQL Server read replicas are Enterprise only: built,
// NOT PROVEN (no lab makes one). The import is import_cloud_replicas's (0151 part P: one row per resource).
type cloudReplicasCollector struct{}

func init() { Register(cloudReplicasCollector{}) }

func (cloudReplicasCollector) Name() string                   { return Prefix + "cloud_replicas" }
func (cloudReplicasCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

func (cloudReplicasCollector) Applies(info Info) (bool, string) {
	if info.Kind != KindRDS {
		return false, "the provider replicas of SQL Server are read for Amazon RDS for SQL Server"
	}
	return true, ""
}

func (cloudReplicasCollector) Configured(in config.Instance) (bool, string) {
	if p, why := cloudrepl.Which(in); p != "aws" {
		if why == "" {
			why = "the gcp: block is PostgreSQL's"
		}
		return false, why
	}
	return true, ""
}

func (cloudReplicasCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, fmt.Errorf("mssql_cloud_replicas reads the instance's aws: block: %w", collect.ErrSkip)
}

// cloudReplicasDoor is the process's door (a test stands its own in)
var cloudReplicasDoor = cloudrepl.Default

func (c cloudReplicasCollector) RunInstance(ctx context.Context, _ *sql.Conn, info Info, in config.Instance) ([]collect.Row, error) {
	if ok, why := c.Configured(in); !ok {
		return nil, fmt.Errorf("%s: %w", why, collect.ErrSkip)
	}
	if ok, why := c.Applies(info); !ok {
		return nil, fmt.Errorf("%s: %w", why, collect.ErrSkip)
	}
	rows, err := cloudReplicasDoor.Rows(ctx, in)
	if err != nil {
		return nil, err
	}
	out := make([]collect.Row, len(rows))
	for i, r := range rows {
		out[i] = r
	}
	return out, nil
}
