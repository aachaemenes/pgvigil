package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// azureDBGovernanceCollector is mssql_azuredb_governance: an Azure SQL Database's tier and its limits, hourly (B2;
// DBA Dash's AzureDBResourceGovernance and AzureServiceObjectivesHistory collections).
//
// sys.dm_user_db_resource_governance (Microsoft Learn) is read whole, every column it has into one JSON object: its
// data is 'intended for internal consumption and ... subject to change', so the store compares DBA Dash's 54
// columns by name where present (AzureDBResourceGovernance_Upd) and a column Azure adds or drops breaks nothing.
// The database's edition, service objective and max size come from DATABASEPROPERTYEX; the pool's name from
// sys.database_service_objectives where the login may read it (dbManager, the database's creator or owner), else
// the instance's tag pool:<name>, else a sentence on the row.
type azureDBGovernanceCollector struct{}

func init() { Register(azureDBGovernanceCollector{}) }

func (azureDBGovernanceCollector) Name() string                   { return Prefix + "azuredb_governance" }
func (azureDBGovernanceCollector) DefaultInterval() time.Duration { return time.Hour }

// azdbLowTier: the service objectives on which Microsoft's DMV pages ask the server admin, the Entra admin or
// ##MS_ServerStateReader## in place of VIEW DATABASE STATE (detect.go's ViewServerState is that check there).
// sys.dm_user_db_resource_governance's Permissions (Microsoft Learn): on those tiers one of the three; on every
// other tier VIEW DATABASE STATE or ##MS_ServerStateReader##. A login of the role with no user in the database
// (##MS_DatabaseConnector##) holds VIEW SERVER STATE but not VIEW DATABASE STATE, so each tier decides on its own
// right: the server-level one alone on the low tiers, either one elsewhere.
func azdbLowTier(serviceObjective string) bool {
	switch strings.ToLower(serviceObjective) {
	case "basic", "s0", "s1", "elasticpool":
		return true
	}
	return false
}

func (azureDBGovernanceCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind != KindAzureDB:
		return false, "the tier's limits (sys.dm_user_db_resource_governance) are Azure SQL Database's"
	case azdbLowTier(info.ServiceObjective):
		if !info.ViewServerState {
			return false, "the login lacks ##MS_ServerStateReader## (Basic, S0, S1 and elastic pools): the tier's limits are not readable"
		}
	case !info.ViewDatabaseState && !info.ViewServerState:
		return false, "the login lacks VIEW DATABASE STATE: the tier's limits are not readable"
	}
	return true, ""
}

// azdbGovernanceSQL: the database's row of the view as one JSON object (NULL when the view gives none), and the
// database's own edition, service objective and max size.
const azdbGovernanceSQL = `SELECT
  (SELECT * FROM sys.dm_user_db_resource_governance WHERE database_id = DB_ID() FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER) AS gov,
  CAST(DATABASEPROPERTYEX(DB_NAME(), 'Edition') AS nvarchar(128)) AS edition,
  CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS nvarchar(128)) AS service_objective,
  CAST(DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes') AS bigint) AS max_size_bytes`

// azdbPoolNote is the row's sentence when neither the service objectives view nor a tag names the pool.
const azdbPoolNote = "the service objectives view answers dbManager, the database's creator or owner: the pool name comes from the tag pool:<name>"

func (azureDBGovernanceCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	gov, err := QueryRows(ctx, conn, azdbGovernanceSQL)
	if err != nil {
		return nil, fmt.Errorf("sys.dm_user_db_resource_governance: %w", err)
	}
	var obj []collect.Row
	if strings.EqualFold(info.ServiceObjective, "ElasticPool") {
		obj, _ = QueryRows(ctx, conn, poolNameSQL) // a login that may not read it gets no row: the tag, else the sentence
	}
	return azdbGovernance(gov, obj, info.PoolTag, info.ServiceObjective)
}

// azdbGovernance builds the run's row from the read: the view's object, the database's figures, the pool's name.
func azdbGovernance(gov, obj []collect.Row, tag, serviceObjective string) ([]collect.Row, error) {
	if len(gov) != 1 {
		return nil, fmt.Errorf("the governance read gave %d rows, want 1", len(gov))
	}
	g := gov[0]
	text, _ := g["gov"].(string)
	if text == "" {
		return []collect.Row{{"kind": "collector_error", "source": "sys.dm_user_db_resource_governance",
			"message": "the view gave no row for the database (database_id = DB_ID())"}}, nil
	}
	var view map[string]any
	if err := json.Unmarshal([]byte(text), &view); err != nil {
		return nil, fmt.Errorf("sys.dm_user_db_resource_governance as JSON: %w", err)
	}
	r := collect.Row{"kind": "governance", "gov": view, "edition": g["edition"], "service_objective": g["service_objective"],
		"max_size_bytes": g["max_size_bytes"], "pool": nil, "pool_from": nil, "pool_note": nil}
	if strings.EqualFold(serviceObjective, "ElasticPool") {
		var objectives string
		if len(obj) == 1 {
			objectives, _ = obj[0]["pool"].(string)
		}
		pool, from, stale, err := poolName(tag, objectives)
		switch {
		case err != nil:
			r["pool_note"] = azdbPoolNote
		default:
			r["pool"], r["pool_from"] = pool, from
			if stale != "" {
				r["pool_note"] = stale
			}
		}
	}
	return []collect.Row{r}, nil
}
