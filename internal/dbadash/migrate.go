package dbadash

// Moving servers from DBA Dash on Admin > Instances (task 206): what serve reads of a configured repository for the
// page, by the repository's name only - its dsn never leaves this package (SetRepositories holds it).

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// ImportOn says whether a configured repository lets serve run the history import (dbadash: - import: true); ok is
// false when the configuration does not name it.
func ImportOn(repo string) (on, ok bool) {
	r, ok := repository(repo)
	return r.Import, ok
}

var (
	serveModeMu sync.RWMutex
	serveMode   func(name string) string
)

// SetQueryText gives the serve process the query_text mode of each pgvigil instance (ConfigTextMode of its
// configuration) for the history import it runs (ImportFrom); without it that import stores under full, the
// credential mask alone. serve calls it beside SetRepositories.
func SetQueryText(f func(name string) string) {
	serveModeMu.Lock()
	serveMode = f
	serveModeMu.Unlock()
}

// withServeMode is opt with serve's query_text modes when its caller gave none.
func withServeMode(opt ImportOptions) ImportOptions {
	if opt.QueryText == nil {
		serveModeMu.RLock()
		opt.QueryText = serveMode
		serveModeMu.RUnlock()
	}
	return opt
}

// ImportFrom runs Import from a configured repository by its name: serve's way (the page's Count and Import), into
// opt.Store (required: serve's own pool), under serve's query_text modes (SetQueryText) when opt names none.
func ImportFrom(ctx context.Context, log *slog.Logger, repo string, opt ImportOptions) ([]ImportCount, error) {
	opt = withServeMode(opt)
	r, ok := repository(repo)
	if !ok {
		return nil, endRun(ctx, log, opt, ErrNoRepository)
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

// agentsSQL is every DBA Dash service with the active instances it collects (4.24.1: dbo.DBADashAgent L1-4,
// dbo.Instances' CollectAgentID), Azure SQL databases included: a service that collects one is never all moved. A
// service with no active instance (each removed in DBA Dash's GUI after its move: Instance_Del sets IsActive = 0) is
// listed with none.
const agentsSQL = `
SELECT A.DBADashAgentID, A.AgentHostName, A.AgentServiceName, I.InstanceID, I.Instance
  FROM dbo.DBADashAgent A LEFT JOIN dbo.Instances I ON I.CollectAgentID = A.DBADashAgentID AND I.IsActive = 1
 ORDER BY A.DBADashAgentID, I.InstanceID`

// agentsKeep is how long a read of a repository's services answers the page (its list polls every 5 s while an import
// runs; each read is a login on DBA Dash's repository server, an audit event there).
const agentsKeep = time.Minute

var agentsRead = struct {
	sync.Mutex
	at  map[string]time.Time
	got map[string][]Agent
}{at: map[string]time.Time{}, got: map[string][]Agent{}}

// Agents is the repository's DBA Dash services, read through the door's read login at most once a minute (a failed
// read is never kept).
func Agents(ctx context.Context, repo string) ([]Agent, error) {
	agentsRead.Lock()
	if at, ok := agentsRead.at[repo]; ok && time.Since(at) < agentsKeep {
		got := agentsRead.got[repo]
		agentsRead.Unlock()
		return got, nil
	}
	agentsRead.Unlock()
	got, err := readAgents(ctx, repo)
	if err == nil {
		agentsRead.Lock()
		agentsRead.at[repo], agentsRead.got[repo] = time.Now(), got
		agentsRead.Unlock()
	}
	return got, err
}

// readAgents reads the repository's DBA Dash services now.
func readAgents(ctx context.Context, repo string) ([]Agent, error) {
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
		var id int
		var iid sql.NullInt64
		var host, svc string
		var inst sql.NullString
		if err := rows.Scan(&id, &host, &svc, &iid, &inst); err != nil {
			return nil, fmt.Errorf("dbo.DBADashAgent: %w", err)
		}
		if len(out) == 0 || out[len(out)-1].ID != id {
			out = append(out, Agent{ID: id, Host: host, Service: svc, Instances: []AgentInstance{}})
		}
		if iid.Valid {
			a := &out[len(out)-1]
			a.Instances = append(a.Instances, AgentInstance{ID: int(iid.Int64), Server: strings.TrimSpace(inst.String)})
		}
	}
	return out, rows.Err()
}
