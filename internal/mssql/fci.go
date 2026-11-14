package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// fciCollector is mssql_fci: a failover cluster instance's nodes (sys.dm_os_cluster_nodes: each node of the Windows
// cluster the instance may run on, its state, and which one owns the instance now) and the node the instance runs
// on (SERVERPROPERTY('ComputerNamePhysicalNetBIOS')). It is read only behind the clustered flag: a server whose
// SERVERPROPERTY('IsClustered') is not 1 returns no row, and nothing is stored. The repository keeps a change of the
// owning node as an event (a failover of the instance: it restarted on another node) and judges a node that is not
// up and an instance with no other node up to fail over to.
//
// NOT PROVEN on a real failover cluster instance: there is none in the labs (it needs a Windows failover cluster
// and shared storage). The statements are compiled and run by a non-clustered server in the tests, where they
// return the empty answer.
type fciCollector struct{}

func init() { Register(fciCollector{}) }

func (fciCollector) Name() string                   { return Prefix + "fci" }
func (fciCollector) DefaultInterval() time.Duration { return time.Minute }
func (fciCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind != KindServer:
		// RDS, Managed Instance, Cloud SQL and Azure SQL Database run their own failover; none is a cluster
		// instance the user owns
		return false, "a managed service runs its own failover: there is no failover cluster instance to read"
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE (sys.dm_os_cluster_nodes)"
	}
	return true, ""
}

// fciFlagSQL: the clustered flag; NULL on an engine that does not know it counts as not clustered.
const fciFlagSQL = `SELECT CAST(ISNULL(SERVERPROPERTY('IsClustered'), 0) AS int) AS is_clustered`

// fciNodesSQL: SQL Server 2014 and later (status, status_description and is_current_owner were added in 2014).
const fciNodesSQL = `SELECT 'node' AS kind, CAST(n.NodeName AS nvarchar(128)) AS node_name, n.status AS node_status,
  CAST(n.status_description AS nvarchar(60)) AS node_state, CAST(n.is_current_owner AS int) AS is_current_owner,
  CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(128)) AS physical_node,
  CAST(SERVERPROPERTY('MachineName') AS nvarchar(128)) AS virtual_name
FROM sys.dm_os_cluster_nodes n
ORDER BY n.NodeName`

func (fciCollector) Run(ctx context.Context, conn *sql.Conn, _ Info) ([]collect.Row, error) {
	flag, err := QueryRows(ctx, conn, fciFlagSQL)
	if err != nil {
		return nil, err
	}
	if !fciClustered(flag) {
		return noRows(), nil
	}
	rows, err := QueryRows(ctx, conn, fciNodesSQL)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return noRows(), nil
	}
	return rows, nil
}

// fciClustered reads the flag's one row: only the value 1 is a cluster instance.
func fciClustered(rows []collect.Row) bool {
	if len(rows) != 1 {
		return false
	}
	switch v := rows[0]["is_clustered"].(type) {
	case int64:
		return v == 1
	case int:
		return v == 1
	}
	return false
}
