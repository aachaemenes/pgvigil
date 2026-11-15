package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// failoverGroupsCollector is mssql_failover_groups (task 390a G2): an Azure SQL Database's logical server's failover
// groups, read from Azure Resource Manager - no T-SQL view shows a group (Microsoft: the geo-replication commands "only
// apply to active geo-replication and do not apply to failover groups"). List By Server (api-version 2025-01-01)
// gives each group's role, replication state, read-write failover policy and grace period, read-only policy and
// target, secondary type (Geo | Standby: a Standby secondary takes no reads), partner servers and databases. The
// server's failover operations of the last two hours are read from the Activity Log (a trial: Microsoft names the
// entry "Failover Azure SQL failover group"; it arrives 3-20 minutes late), each stored once, so an event can say
// planned (failover/action), forced (forceFailoverAllowDataLoss/action) or Microsoft-initiated when the log has it.
// The caller is never kept (it names a person).
//
// The door is the instance's azure: block; the token is mssqlopen.ARMToken's. One read a server an interval in this
// collector (the server's other databases say 'read by <instance>'); the import takes the server's own lock and refuses
// an older read. A refusal names Resource Manager's code and the right; a throttle (429) skips until its Retry-After.
type failoverGroupsCollector struct{}

func init() { Register(failoverGroupsCollector{}) }

func (failoverGroupsCollector) Name() string                   { return Prefix + "failover_groups" }
func (failoverGroupsCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (failoverGroupsCollector) Applies(info Info) (bool, string) {
	if info.Kind != KindAzureDB {
		return false, "failover groups (Azure Resource Manager) are read for Azure SQL Database"
	}
	return true, ""
}

func (failoverGroupsCollector) Configured(in config.Instance) (bool, string) {
	if in.Azure == nil {
		return false, "no azure: block in the config (subscription, resource_group, server): the failover groups are not read"
	}
	return true, ""
}

func (failoverGroupsCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, fmt.Errorf("mssql_failover_groups reads the instance's azure: block: %w", collect.ErrSkip)
}

func (c failoverGroupsCollector) RunInstance(ctx context.Context, _ *sql.Conn, _ Info, in config.Instance) ([]collect.Row, error) {
	if ok, why := c.Configured(in); !ok {
		return nil, fmt.Errorf("%s: %w", why, collect.ErrSkip)
	}
	key := in.Azure.ServerKey()
	if !fgGate.take(key, in.Name, time.Now(), c.DefaultInterval()) {
		return nil, fmt.Errorf("the server's failover groups were read by %s in this interval: %w", fgGate.by(key), collect.ErrSkip)
	}
	arm, _, err := azureARM(in.Azure.Cloud)
	if err != nil {
		return nil, err
	}
	d := fgDoor{arm: arm, http: &http.Client{Timeout: 30 * time.Second}, now: time.Now,
		token: func(ctx context.Context, dsn, aud string) (string, error) { return mssqlopen.ARMToken(ctx, dsn, aud) }}
	rows, err := d.read(ctx, in)
	var th throttled
	if asThrottled(err, &th) {
		fgGate.hold(key, time.Now().Add(th.after))
		return nil, fmt.Errorf("%s: %w", err.Error(), collect.ErrSkip)
	}
	return rows, err
}

// azureARM: a cloud's Resource Manager host and token audience (internal/discover's map)
func azureARM(cloud string) (host, audience string, err error) {
	switch strings.ToLower(strings.TrimSpace(cloud)) {
	case "", "public":
		return "https://management.azure.com", "https://management.azure.com/", nil
	case "usgov":
		return "https://management.usgovcloudapi.net", "https://management.usgovcloudapi.net/", nil
	case "china":
		return "https://management.chinacloudapi.cn", "https://management.chinacloudapi.cn/", nil
	}
	return "", "", fmt.Errorf("the Azure cloud is public, usgov or china, not %q", cloud)
}

// fgDoor is one read's Resource Manager: its host, its token, its HTTP client (tests stand their own in)
type fgDoor struct {
	arm   string
	token func(ctx context.Context, dsn, audience string) (string, error)
	http  *http.Client
	now   func() time.Time
}

type throttled struct{ after time.Duration }

func (t throttled) Error() string {
	return fmt.Sprintf("the Resource Manager throttled the read (429): the next read after %s", t.after.Round(time.Second))
}

func asThrottled(err error, t *throttled) bool { return errors.As(err, t) }

func (d fgDoor) read(ctx context.Context, in config.Instance) ([]collect.Row, error) {
	a := in.Azure
	_, audience, err := azureARM(a.Cloud)
	if err != nil {
		return nil, err
	}
	if d.arm == "" {
		return nil, fmt.Errorf("no Resource Manager host")
	}
	tok, err := d.token(ctx, in.DSN(), audience)
	if err != nil {
		return nil, fmt.Errorf("the Resource Manager token (the instance's Entra identity or azidentity's default chain): %w", err)
	}
	server := "/subscriptions/" + url.PathEscape(a.Subscription) + "/resourceGroups/" + url.PathEscape(a.ResourceGroup) +
		"/providers/Microsoft.Sql/servers/" + url.PathEscape(a.Server)
	rows := []collect.Row{{"kind": "read", "server_key": a.ServerKey(), "cloud": strings.ToLower(a.Cloud)}}
	next := d.arm + server + "/failoverGroups?api-version=2025-01-01"
	for page := 0; next != "" && page < 20; page++ {
		var body struct {
			Value []struct {
				Name       string `json:"name"`
				Properties struct {
					ReplicationRole  string `json:"replicationRole"`
					ReplicationState string `json:"replicationState"`
					SecondaryType    string `json:"secondaryType"`
					ReadWrite        struct {
						FailoverPolicy string   `json:"failoverPolicy"`
						Grace          *float64 `json:"failoverWithDataLossGracePeriodMinutes"`
					} `json:"readWriteEndpoint"`
					ReadOnly struct {
						FailoverPolicy string `json:"failoverPolicy"`
						TargetServer   string `json:"targetServer"`
					} `json:"readOnlyEndpoint"`
					Partners []struct {
						ID              string `json:"id"`
						Location        string `json:"location"`
						ReplicationRole string `json:"replicationRole"`
					} `json:"partnerServers"`
					Databases []string `json:"databases"`
				} `json:"properties"`
			} `json:"value"`
			NextLink string `json:"nextLink"`
		}
		if err := d.get(ctx, next, tok, &body, "Microsoft.Sql/servers/failoverGroups/read"); err != nil {
			return nil, err
		}
		for _, g := range body.Value {
			p := g.Properties
			partners := make([]map[string]string, 0, len(p.Partners))
			for _, x := range p.Partners {
				partners = append(partners, map[string]string{"server": lastSegment(x.ID), "location": x.Location, "role": x.ReplicationRole})
			}
			pj, _ := json.Marshal(partners)
			dbs := make([]string, 0, len(p.Databases))
			for _, x := range p.Databases {
				dbs = append(dbs, lastSegment(x))
			}
			dj, _ := json.Marshal(dbs)
			var grace any
			if p.ReadWrite.Grace != nil {
				grace = *p.ReadWrite.Grace
			}
			rows = append(rows, collect.Row{"kind": "group", "group_name": g.Name, "role": p.ReplicationRole,
				"replication_state": p.ReplicationState, "secondary_type": p.SecondaryType, "rw_policy": p.ReadWrite.FailoverPolicy,
				"grace_minutes": grace, "ro_policy": p.ReadOnly.FailoverPolicy, "ro_target": lastSegment(p.ReadOnly.TargetServer),
				"partners": string(pj), "databases": string(dj)})
		}
		next = body.NextLink
	}
	// the Activity Log (a trial): the server's failover operations of the last two hours; a refusal here is a note,
	// never the read's failure (the groups were read)
	ops, err := d.operations(ctx, tok, server)
	if err != nil {
		rows = append(rows, collect.Row{"kind": "collector_error", "source": "activity_log", "message": err.Error()})
	}
	return append(rows, ops...), nil
}

func (d fgDoor) operations(ctx context.Context, tok, server string) ([]collect.Row, error) {
	since := d.now().UTC().Add(-2 * time.Hour).Format(time.RFC3339)
	filter := fmt.Sprintf("eventTimestamp ge '%s' and resourceUri eq '%s'", since, server)
	u := d.arm + "/subscriptions/" + url.PathEscape(strings.Split(strings.TrimPrefix(server, "/subscriptions/"), "/")[0]) +
		"/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&$filter=" + url.QueryEscape(filter)
	var body struct {
		Value []struct {
			ID        string `json:"eventDataId"`
			At        string `json:"eventTimestamp"`
			Operation struct {
				Value string `json:"value"`
			} `json:"operationName"`
			Status struct {
				Value string `json:"value"`
			} `json:"status"`
			ResourceID string `json:"resourceId"`
		} `json:"value"`
	}
	if err := d.get(ctx, u, tok, &body, "Microsoft.Insights/eventtypes/values/read"); err != nil {
		return nil, err
	}
	var out []collect.Row
	for _, e := range body.Value {
		op := strings.ToLower(e.Operation.Value)
		kind := ""
		switch {
		case strings.HasSuffix(op, "/forcefailoverallowdataloss/action"):
			kind = "forced failover"
		case strings.HasSuffix(op, "/failover/action"):
			kind = "failover"
		default:
			continue
		}
		out = append(out, collect.Row{"kind": "operation", "event_id": e.ID, "at": e.At, "operation": kind,
			"status": e.Status.Value, "group_name": lastSegment(e.ResourceID)})
	}
	return out, nil
}

// get reads one Resource Manager answer; a refusal names its code and the right the read needs
func (d fgDoor) get(ctx context.Context, u, tok string, into any, right string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := d.http.Do(req)
	if err != nil {
		return fmt.Errorf("the Resource Manager call: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode == http.StatusTooManyRequests {
		after := 5 * time.Minute
		if s, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && s > 0 {
			after = time.Duration(s) * time.Second
		}
		return throttled{after: after}
	}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error struct{ Code, Message string } `json:"error"`
		}
		_ = json.Unmarshal(b, &e)
		return fmt.Errorf("the Resource Manager answered %d %s: %s (the identity needs %s on the server)", resp.StatusCode, e.Error.Code, e.Error.Message, right)
	}
	return json.Unmarshal(b, into)
}

func lastSegment(id string) string {
	id = strings.TrimRight(id, "/")
	if i := strings.LastIndex(id, "/"); i >= 0 {
		return id[i+1:]
	}
	return id
}

// fgGate lets one instance read a server per interval in this process (the server's other databases skip with its name)
var fgGate = &serverGate{last: map[string]gateEntry{}}

type gateEntry struct {
	at, until time.Time
	by        string
}

type serverGate struct {
	mu   sync.Mutex
	last map[string]gateEntry
}

func (g *serverGate) take(key, name string, now time.Time, every time.Duration) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	e, ok := g.last[key]
	if ok && e.by != name && (now.Sub(e.at) < every-10*time.Second || now.Before(e.until)) {
		return false
	}
	if ok && e.by == name && now.Before(e.until) {
		return false
	}
	g.last[key] = gateEntry{at: now, by: name}
	return true
}

func (g *serverGate) hold(key string, until time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	e := g.last[key]
	e.until = until
	g.last[key] = e
}

func (g *serverGate) by(key string) string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.last[key].by
}
