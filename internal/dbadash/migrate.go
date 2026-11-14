package dbadash

// Moving servers from DBA Dash on Admin > Instances (task 206): what serve reads of a configured repository for the
// page, by the repository's name only - its dsn never leaves this package (SetRepositories holds it).

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// ImportOn says whether a configured repository lets serve run the history import (dbadash: - import: true); ok is
// false when the configuration does not name it.
func ImportOn(repo string) (on, ok bool) {
	r, ok := repository(repo)
	return r.Import, ok
}

// ImportFrom runs Import from a configured repository by its name: serve's way (the page's Count and Import), into
// opt.Store (required: serve's own pool).
func ImportFrom(ctx context.Context, log *slog.Logger, repo string, opt ImportOptions) ([]ImportCount, error) {
	r, ok := repository(repo)
	if !ok {
		return nil, ErrNoRepository
	}
	if opt.Store == nil {
		return nil, fmt.Errorf("dbadash import from %s: no store", r.Name)
	}
	opt.Repository = r.Name
	return Import(ctx, log, r.DSN(), "", opt)
}

// Agent is one DBA Dash service (dbo.DBADashAgent) and the active instances of the repository it collects
// (dbo.Instances.CollectAgentID): the page says 'stop the DBA Dash service <Service> on <Host>' once each of them is
// moved and ready.
type Agent struct {
	ID        int             `json:"agent_id"`
	Host      string          `json:"host"`
	Service   string          `json:"service"`
	Instances []AgentInstance `json:"instances"`
}

// AgentInstance is one active instance a DBA Dash service collects: its InstanceID and Instance (@@SERVERNAME).
type AgentInstance struct {
	ID     int    `json:"dbadash_id"`
	Server string `json:"server"`
}

// agentsSQL is every active instance with the service that collects it (4.24.1: dbo.DBADashAgent L1-4, dbo.Instances'
// CollectAgentID), Azure SQL databases included: a service that collects one is never all moved.
const agentsSQL = `
SELECT A.DBADashAgentID, A.AgentHostName, A.AgentServiceName, I.InstanceID, I.Instance
  FROM dbo.Instances I JOIN dbo.DBADashAgent A ON A.DBADashAgentID = I.CollectAgentID
 WHERE I.IsActive = 1
 ORDER BY A.DBADashAgentID, I.InstanceID`

// Agents reads the repository's DBA Dash services now, through the door's read login.
func Agents(ctx context.Context, repo string) ([]Agent, error) {
	r, ok := repository(repo)
	if !ok {
		return nil, ErrNoRepository
	}
	dsn := r.DSN()
	if strings.TrimSpace(dsn) == "" {
		return nil, fmt.Errorf("the repository %s's dsn resolved to nothing", r.Name)
	}
	db, err := mssqlopen.Open(withAppName(dsn))
	if err != nil {
		return nil, fmt.Errorf("dbadash dsn: %w", err)
	}
	defer func() { _ = db.Close() }()
	db.SetMaxOpenConns(1)
	rows, err := db.QueryContext(ctx, agentsSQL)
	if err != nil {
		return nil, fmt.Errorf("dbo.DBADashAgent: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := []Agent{}
	for rows.Next() {
		var id, iid int
		var host, svc string
		var inst sql.NullString
		if err := rows.Scan(&id, &host, &svc, &iid, &inst); err != nil {
			return nil, fmt.Errorf("dbo.DBADashAgent: %w", err)
		}
		if len(out) == 0 || out[len(out)-1].ID != id {
			out = append(out, Agent{ID: id, Host: host, Service: svc, Instances: []AgentInstance{}})
		}
		a := &out[len(out)-1]
		a.Instances = append(a.Instances, AgentInstance{ID: iid, Server: strings.TrimSpace(inst.String)})
	}
	return out, rows.Err()
}
