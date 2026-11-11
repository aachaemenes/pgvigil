package collect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// rolechangeCollector reads, every minute, what the server is in its cluster: its role (pg_is_in_recovery), its
// timeline, the cluster's system identifier (pg_control_system) and the postmaster's start. The repository keeps the
// newest values and writes a role-change row when the role, the timeline or the system identifier differs from the
// read before (0103: import_rolechange): a promotion, a demotion, a timeline change (a standby that follows a new
// primary), or another cluster answering under the instance's name.
//
// The time of a change: the newest timeline history file's modification time in pg_wal (pg_ls_waldir, a pg_monitor
// grant) when its timeline is the new one and it lies between the two reads on the server's own clock, else the
// postmaster's start when the server restarted between them, else the read that saw the change.
//
// The timeline: on a primary the current WAL file's (pg_walfile_name(pg_current_wal_lsn())); on a standby the WAL
// receiver's received_tli, else the last restart point's (pg_control_checkpoint), which can trail a switch until the
// next restart point.
//
// Patroni: when a session named 'Patroni...' is connected (Patroni's own connection) and the platform is not a
// managed one, GET http://<the dsn's host>:8008/cluster (Patroni's default REST port, 3 s) is read and each member
// stored (name, role, state, host, port, timeline, lag). No such session = no request.
//
// Read only. A part the login cannot read (pg_control_* or pg_ls_waldir on a managed platform) is left empty.
type rolechangeCollector struct{}

func init() { Register(rolechangeCollector{}) }

func (rolechangeCollector) Name() string                         { return "rolechange" }
func (rolechangeCollector) DefaultInterval() time.Duration       { return time.Minute }
func (rolechangeCollector) Applies(platform.Info) (bool, string) { return true, "" }

func (r rolechangeCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	return r.RunInstance(ctx, conn, info, config.Instance{}, nil)
}

// roleBaseSQL is readable by any login. The CASE keeps pg_walfile_name (an error in recovery) off a standby.
const roleBaseSQL = `
SELECT pg_is_in_recovery() AS is_replica, pg_postmaster_start_time() AS postmaster_start, now() AS server_now,
       nullif(current_setting('cluster_name'), '') AS cluster_name,
       CASE WHEN pg_is_in_recovery() THEN NULL
            ELSE ('x' || left(pg_walfile_name(pg_current_wal_lsn()), 8))::bit(32)::bigint END AS wal_timeline,
       (SELECT w.received_tli FROM pg_stat_wal_receiver w WHERE w.pid IS NOT NULL LIMIT 1) AS receiver_timeline,
       EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.application_name LIKE 'Patroni%') AS patroni_session`

// roleControlSQL: pg_control_system / pg_control_checkpoint (superuser or pg_monitor on most platforms).
const roleControlSQL = `
SELECT (pg_control_system()).system_identifier::text AS system_identifier, (pg_control_checkpoint()).timeline_id AS checkpoint_timeline`

// roleHistorySQL: the newest timeline history file in pg_wal (pg_ls_waldir: superuser or pg_monitor).
const roleHistorySQL = `
SELECT name, modification FROM pg_ls_waldir() WHERE name ~ '^[0-9A-F]{8}\.history$' ORDER BY name DESC LIMIT 1`

// patroniPort is Patroni's default REST port; patroniTimeout bounds the one request.
const (
	patroniPort    = "8008"
	patroniTimeout = 3 * time.Second
)

func (rolechangeCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	base, err := conn.Query(ctx, roleBaseSQL)
	if err != nil {
		return nil, fmt.Errorf("rolechange: %w", err)
	}
	rows, err := rowsToMaps(base)
	if err != nil || len(rows) != 1 {
		return nil, fmt.Errorf("rolechange: %v (%d rows)", err, len(rows))
	}
	r := rows[0]
	r["kind"] = "role"
	isReplica, _ := r["is_replica"].(bool)
	var sysID *string
	var ckTL *int64
	var ckTLraw *int32
	if err := conn.QueryRow(ctx, roleControlSQL).Scan(&sysID, &ckTLraw); err == nil {
		r["system_identifier"] = sysID
		if ckTLraw != nil {
			v := int64(*ckTLraw)
			ckTL = &v
		}
	}
	var histName *string
	var histAt *time.Time
	if err := conn.QueryRow(ctx, roleHistorySQL).Scan(&histName, &histAt); err == nil && histName != nil {
		r["history_file"] = *histName
		r["history_at"] = histAt.UTC()
		if tl, err := strconv.ParseInt(strings.TrimSuffix(*histName, ".history"), 16, 64); err == nil {
			r["history_timeline"] = tl
		}
	}
	tl, src := roleTimeline(isReplica, r["wal_timeline"], r["receiver_timeline"], ckTL)
	r["timeline_id"], r["timeline_source"] = tl, src
	delete(r, "wal_timeline")
	delete(r, "receiver_timeline")
	out := []Row{r}
	if p, _ := r["patroni_session"].(bool); p && info.Kind != platform.RDS && info.Kind != platform.Aurora && in.DSNRaw != "" {
		out = append(out, patroniRows(ctx, patroniURL(in.DSN()))...)
	}
	delete(r, "patroni_session")
	return out, nil
}

// roleTimeline picks the server's timeline and says where it came from: the WAL file on a primary, the receiver on a
// streaming standby, the last restart point otherwise.
func roleTimeline(isReplica bool, wal, recv any, ck *int64) (any, string) {
	num := func(v any) (int64, bool) {
		switch x := v.(type) {
		case int64:
			return x, true
		case int32:
			return int64(x), true
		case uint32:
			return int64(x), true
		}
		return 0, false
	}
	if !isReplica {
		if v, ok := num(wal); ok {
			return v, "wal file"
		}
	} else if v, ok := num(recv); ok && v > 0 {
		return v, "wal receiver"
	}
	if ck != nil {
		return *ck, "checkpoint"
	}
	return nil, ""
}

// patroniURL is the cluster endpoint on the dsn's host: a socket directory or no host = this machine.
func patroniURL(dsn string) string {
	host := "127.0.0.1"
	if c, err := pgx.ParseConfig(dsn); err == nil && c.Host != "" && !strings.HasPrefix(c.Host, "/") {
		host = c.Host
	}
	return "http://" + net.JoinHostPort(host, patroniPort) + "/cluster"
}

// patroniMember is one member of GET /cluster; lag is a number of bytes or a word ('unknown').
type patroniMember struct {
	Name     string          `json:"name"`
	Role     string          `json:"role"`
	State    string          `json:"state"`
	Host     string          `json:"host"`
	Port     int             `json:"port"`
	Timeline *int64          `json:"timeline"`
	Lag      json.RawMessage `json:"lag"`
	APIURL   string          `json:"api_url"`
}

var patroniClient = &http.Client{Timeout: patroniTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

// patroniRows reads the cluster from Patroni's REST API: a 'patroni_read' row (ok, the message on a failure) and a
// 'patroni' row per member. A failure is not a collector error: the endpoint is a guess at its default port.
func patroniRows(ctx context.Context, url string) []Row {
	read := Row{"kind": "patroni_read", "url": url, "ok": false}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		read["message"] = err.Error()
		return []Row{read}
	}
	resp, err := patroniClient.Do(req)
	if err != nil {
		read["message"] = shortErr(err)
		return []Row{read}
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil || resp.StatusCode != http.StatusOK {
		read["message"] = fmt.Sprintf("HTTP %d %v", resp.StatusCode, err)
		return []Row{read}
	}
	var c struct {
		Scope   string          `json:"scope"`
		Members []patroniMember `json:"members"`
	}
	if err := json.Unmarshal(body, &c); err != nil || len(c.Members) == 0 {
		read["message"] = "the answer is not a Patroni cluster (no members)"
		return []Row{read}
	}
	read["ok"], read["scope"], read["members"] = true, nilIfEmpty(c.Scope), len(c.Members)
	out := []Row{read}
	for _, m := range c.Members {
		if m.Name == "" {
			continue
		}
		row := Row{"kind": "patroni", "scope": nilIfEmpty(c.Scope), "member": m.Name, "role": nilIfEmpty(m.Role), "state": nilIfEmpty(m.State),
			"host": nilIfEmpty(m.Host), "port": m.Port, "timeline": m.Timeline, "api_url": nilIfEmpty(m.APIURL)}
		if n, err := strconv.ParseInt(strings.TrimSpace(string(m.Lag)), 10, 64); err == nil {
			row["lag_bytes"] = n
		} else if len(m.Lag) > 0 {
			row["lag_text"] = strings.Trim(string(m.Lag), `"`)
		}
		out = append(out, row)
	}
	return out
}

// shortErr is an error's last part (a refused or timed-out connection names the address once).
func shortErr(err error) string {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "no answer in " + patroniTimeout.String()
	}
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i >= 0 && i+2 < len(s) {
		return s[i+2:]
	}
	return s
}
