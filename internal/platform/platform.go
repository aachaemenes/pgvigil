// Package platform tells which kind of PostgreSQL an instance is and which
// collections apply to it, the way a SQL Server monitor branches on
// EngineEdition and the rdsadmin database.
package platform

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// Kind is the hosting platform.
type Kind string

// The platforms pgvigil knows.
const (
	OnPrem   Kind = "onprem"
	RDS      Kind = "rds"
	Aurora   Kind = "aurora"
	Azure    Kind = "azure"
	CloudSQL Kind = "cloudsql"
	AlloyDB  Kind = "alloydb"
)

// Info is what one round of detection learns.
type Info struct {
	Kind             Kind
	ServerVersion    string // version() text
	ServerVersionNum int    // server_version_num, e.g. 160004
	IsReplica        bool   // pg_is_in_recovery()
	HasPgStatStmts   bool   // pg_stat_statements is installed in the connected database
	HasPgCron        bool
	HasPgAgent       bool
	HasPgStatIO      bool // server_version_num >= 160000
	HasCheckpointer  bool // server_version_num >= 170000 (pg_stat_checkpointer)
	HasWaitSampling  bool // pg_wait_sampling, or Azure's pgms_wait_sampling
	HasLogFdw        bool // log_fdw (RDS / Aurora)
}

// detectSQL fingerprints the platform from roles and functions that each
// managed service installs. Order matters: Aurora is also RDS; AlloyDB also
// carries Cloud SQL roles.
const detectSQL = `
SELECT
  CASE
    -- aurora_version() is internal (no pg_proc row); Aurora's own settings are the marker
    WHEN EXISTS (SELECT 1 FROM pg_settings WHERE name LIKE 'apg\_%' OR name LIKE 'aurora\_%') THEN 'aurora'
    WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rdsadmin') THEN 'rds'
    WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'azure_pg_admin') THEN 'azure'
    WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('alloydbsuperuser','alloydbadmin')) THEN 'alloydb'
    WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudsqladmin') THEN 'cloudsql'
    ELSE 'onprem'
  END AS platform,
  version() AS server_version,
  current_setting('server_version_num')::int AS server_version_num,
  pg_is_in_recovery() AS is_replica,
  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS has_pgss,
  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') AS has_pg_cron,
  EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgagent') AS has_pgagent,
  EXISTS (SELECT 1 FROM pg_extension WHERE extname IN ('pg_wait_sampling','pgms_wait_sampling')) AS has_wait_sampling,
  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'log_fdw') AS has_log_fdw`

// Detect runs the fingerprint query on an open connection.
func Detect(ctx context.Context, conn *pgx.Conn, forced string) (Info, error) {
	var in Info
	var kind string
	err := conn.QueryRow(ctx, detectSQL).Scan(&kind, &in.ServerVersion, &in.ServerVersionNum, &in.IsReplica,
		&in.HasPgStatStmts, &in.HasPgCron, &in.HasPgAgent, &in.HasWaitSampling, &in.HasLogFdw)
	if err != nil {
		return in, fmt.Errorf("platform detect: %w", err)
	}
	in.Kind = Kind(kind)
	if forced != "" && forced != "auto" {
		in.Kind = Kind(forced)
	}
	in.HasPgStatIO = in.ServerVersionNum >= 160000
	in.HasCheckpointer = in.ServerVersionNum >= 170000
	return in, nil
}

// Managed is true for every cloud service (no host access, no superuser).
func (k Kind) Managed() bool { return k != OnPrem }
