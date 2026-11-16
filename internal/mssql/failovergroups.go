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
// target, secondary type (Geo | Standby: a Standby secondary takes no reads), partner servers and databases. Each
// group's failover operations of the last two hours are read from the Activity Log (a trial: Microsoft names the entry
// "Failover Azure SQL failover group"; it arrives 3-20 minutes late) on the GROUP's resource, on this server and on
// each partner (resourceUri is an exact match, and a planned failover is logged on the new primary's group: the
// review's finding 1), paged by nextLink; an operation is matched on the failover group's own prefix (a database's
// replicationLinks/failover/action is not one) and stored once per correlationId (its Started, Accepted and Succeeded
// events are one operation), so an event can say planned (failover/action), forced (forceFailoverAllowDataLoss/action),
// planned before forced (tryPlannedBeforeForcedFailover/action) or Microsoft-initiated when the log has it. A fixed
// two-hour window each read, not a high-water mark (the design fold 7's): the log is late by up to 20 minutes, the
// store keeps each operation once, and a read that failed loses nothing within the two hours. The caller is never
// kept (it names a person).
//
// The door is the instance's azure: block; the token is mssqlopen.ARMToken's. One read a server an interval in this
// process: the first database of the server to run takes it (the server's other databases say 'read by <instance>'),
// and a read that fails gives it back, so the next database's run reads it (an identity without the right never
// holds a server for good: the review's finding 4). A departure from the design fold 11 ('the lowest active
// instance_id'): first come, the slot given back on a failure; two collector processes each read, and the import's
// server lock and its newer-read rule keep one row. Three failed runs in a row are 0121's 'collection failing'
// (critical, the error's sentence): the fold 15's 'cloud door failing' for this door. The import takes the server's
// own lock and refuses an older read. A refusal names Resource Manager's code and the right; a throttle (429) skips
// until its Retry-After.
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
	arm, _, err := azureARM(in.Azure.Cloud)
	if err != nil {
		return nil, err
	}
	return c.runDoor(ctx, in, fgDoor{arm: arm, http: &http.Client{Timeout: 30 * time.Second}, now: time.Now, token: mssqlopen.ARMToken})
}

// runDoor: the server's slot for this interval, the read, and the slot given back when the read fails (a throttle
// keeps it until its Retry-After)
func (c failoverGroupsCollector) runDoor(ctx context.Context, in config.Instance, d fgDoor) ([]collect.Row, error) {
	key := in.Azure.ServerKey()
	if !fgGate.take(key, in.Name, time.Now(), c.DefaultInterval()) {
		return nil, fmt.Errorf("the server's failover groups were read by %s in this interval: %w", fgGate.by(key), collect.ErrSkip)
	}
	rows, err := d.read(ctx, in)
	var th throttled
	if asThrottled(err, &th) {
		fgGate.hold(key, time.Now().Add(th.after))
		return nil, fmt.Errorf("%s: %w", err.Error(), collect.ErrSkip)
	}
	if err != nil {
		fgGate.release(key, in.Name)
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
	var logOn []string // each group's resource on this server and on its partners: the Activity Log's reads
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
			logOn = append(logOn, server+"/failoverGroups/"+url.PathEscape(g.Name))
			for _, x := range p.Partners {
				if x.ID != "" {
					logOn = append(logOn, strings.TrimRight(x.ID, "/")+"/failoverGroups/"+url.PathEscape(g.Name))
				}
			}
		}
		next = body.NextLink
	}
	// the Activity Log (a trial): each group's failover operations of the last two hours, on its resource here and on
	// each partner's; a refusal here is a note, never the read's failure (the groups were read), and stops the log's
	// reads of this run
	for _, res := range logOn {
		ops, err := d.operations(ctx, tok, res)
		if err != nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": "activity_log", "message": err.Error()})
			break
		}
		rows = append(rows, ops...)
	}
	return rows, nil
}

// operations: one resource's failover group operations of the last two hours (resourceUri is an exact match: the
// group's own id), every page, each event a row with its operation's correlationId
func (d fgDoor) operations(ctx context.Context, tok, resource string) ([]collect.Row, error) {
	since := d.now().UTC().Add(-2 * time.Hour).Format(time.RFC3339)
	filter := fmt.Sprintf("eventTimestamp ge '%s' and resourceUri eq '%s'", since, resource)
	next := d.arm + "/subscriptions/" + url.PathEscape(strings.Split(strings.TrimPrefix(resource, "/subscriptions/"), "/")[0]) +
		"/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&$filter=" + url.QueryEscape(filter)
	var out []collect.Row
	for page := 0; next != "" && page < 20; page++ {
		var body struct {
			Value []struct {
				ID          string `json:"eventDataId"`
				Correlation string `json:"correlationId"`
				At          string `json:"eventTimestamp"`
				Operation   struct {
					Value string `json:"value"`
				} `json:"operationName"`
				Status struct {
					Value string `json:"value"`
				} `json:"status"`
				ResourceID string `json:"resourceId"`
			} `json:"value"`
			NextLink string `json:"nextLink"`
		}
		if err := d.get(ctx, next, tok, &body, "Microsoft.Insights/eventtypes/values/read"); err != nil {
			return nil, err
		}
		for _, e := range body.Value {
			op := strings.ToLower(e.Operation.Value)
			if !strings.HasPrefix(op, "microsoft.sql/servers/failovergroups/") {
				continue // a database's own replicationLinks/failover/action is not a group's
			}
			kind := ""
			switch {
			case strings.HasSuffix(op, "/forcefailoverallowdataloss/action"):
				kind = "forced failover"
			case strings.HasSuffix(op, "/tryplannedbeforeforcedfailover/action"):
				kind = "planned before forced failover"
			case strings.HasSuffix(op, "/failover/action"):
				kind = "failover"
			default:
				continue
			}
			corr := e.Correlation
			if corr == "" {
				corr = e.ID
			}
			out = append(out, collect.Row{"kind": "operation", "event_id": e.ID, "correlation_id": corr, "at": e.At, "operation": kind,
				"status": e.Status.Value, "group_name": lastSegment(e.ResourceID)})
		}
		next = body.NextLink
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

// release gives the server's slot back after a failed read by name (the next database of the server reads it now)
func (g *serverGate) release(key, name string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if e, ok := g.last[key]; ok && e.by == name && e.until.IsZero() {
		delete(g.last, key)
	}
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
