package collect

import (
	"context"
	"fmt"
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
// read before (0103, 0144: import_rolechange): a promotion, a demotion, a timeline change (a standby that follows a new
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
// Patroni (patroni.go): on a self-managed server, when the instance's patroni: block names the REST API or a session
// named 'Patroni...' is connected (Patroni's own), its /cluster and each member's /patroni are read in the same run.
//
// Read only. A part the login cannot read (pg_control_* or pg_ls_waldir on a managed platform) is left empty.
type rolechangeCollector struct{}

func init() { Register(rolechangeCollector{}) }

func (rolechangeCollector) Name() string                         { return "rolechange" }
func (rolechangeCollector) DefaultInterval() time.Duration       { return time.Minute }
func (rolechangeCollector) Applies(platform.Info) (bool, string) { return true, "" }

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

func (r rolechangeCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	return r.RunInstance(ctx, conn, info, config.Instance{}, nil)
}

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
	seen, _ := r["patroni_session"].(bool)
	delete(r, "patroni_session")
	if !info.Kind.Managed() {
		out = append(out, patroniRows(ctx, in, seen)...)
	}
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
