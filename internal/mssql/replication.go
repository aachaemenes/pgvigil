package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// replicationCollector is mssql_replication: transactional, snapshot and merge replication as the DISTRIBUTOR knows
// it, read from the distribution database's own tables (MSpublications, MSdistribution_agents and its history,
// MSlogreader_agents, MSsnapshot_agents and theirs, MSmerge_agents with MSmerge_sessions) and its view MSdistribution_status for the
// commands not yet delivered. Nothing is written: no tracer token, no call of a replication procedure. A server
// that is no distributor returns no row; a publisher whose distributor is another server is read there.
type replicationCollector struct{}

func init() { Register(replicationCollector{}) }

func (replicationCollector) Name() string                   { return Prefix + "replication" }
func (replicationCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (replicationCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "Azure SQL Database is never a distributor"
	}
	return true, ""
}

// Timeout: MSdistribution_status counts the undelivered commands per article from MSrepl_commands, which is large
// on a busy distributor.
func (replicationCollector) Timeout() time.Duration { return 2 * time.Minute }

// the distribution databases of the server and whether the login may enter each
const replDistributorsSQL = `SELECT CAST(name AS nvarchar(128)) AS name, CAST(ISNULL(HAS_DBACCESS(name), 0) AS int) AS has_access
FROM sys.databases WHERE is_distributor = 1 AND state = 0 ORDER BY name`

// quoteName is QUOTENAME for a database name pgvigil read from sys.databases.
func quoteName(name string) string { return "[" + strings.ReplaceAll(name, "]", "]]") + "]" }

// literal is an N” literal of a name.
func literal(s string) string { return "N'" + strings.ReplaceAll(s, "'", "''") + "'" }

// replPublicationsSQL, replSubscriptionsSQL and replAgentsSQL read one distribution database (SQL Server 2016 SP1
// and later; the tables are unchanged since 2005). runstatus: 1 start, 2 succeed, 3 in progress, 4 idle, 5 retry,
// 6 fail.
func replPublicationsSQL(db string) string {
	d := quoteName(db)
	return `SELECT 'publication' AS kind, ` + literal(db) + ` AS distribution_db,
  CAST(srv.name AS nvarchar(128)) AS publisher, CAST(p.publisher_db AS nvarchar(128)) AS publisher_db,
  CAST(p.publication AS nvarchar(128)) AS publication,
  CASE p.publication_type WHEN 0 THEN 'transactional' WHEN 1 THEN 'snapshot' WHEN 2 THEN 'merge' ELSE CAST(p.publication_type AS varchar(12)) END AS publication_type,
  (SELECT COUNT(*) FROM ` + d + `.dbo.MSarticles a WHERE a.publisher_id = p.publisher_id AND a.publisher_db = p.publisher_db AND a.publication_id = p.publication_id) AS articles
FROM ` + d + `.dbo.MSpublications p
LEFT JOIN master.sys.servers srv ON srv.server_id = p.publisher_id
ORDER BY 3, 4, 5`
}

func replSubscriptionsSQL(db string) string {
	d := quoteName(db)
	return `SELECT 'subscription' AS kind, ` + literal(db) + ` AS distribution_db,
  CAST(srv.name AS nvarchar(128)) AS publisher, CAST(a.publisher_db AS nvarchar(128)) AS publisher_db,
  CAST(a.publication AS nvarchar(128)) AS publication,
  CAST(sub.name AS nvarchar(128)) AS subscriber, CAST(a.subscriber_db AS nvarchar(128)) AS subscriber_db,
  CASE a.subscription_type WHEN 0 THEN 'push' WHEN 1 THEN 'pull' WHEN 2 THEN 'anonymous' ELSE CAST(a.subscription_type AS varchar(12)) END AS subscription_type,
  'distribution' AS agent_type, CAST(a.name AS nvarchar(200)) AS agent_name,
  h.runstatus, CAST(LEFT(h.comments, 1000) AS nvarchar(1000)) AS status_text,
  ` + utcText("h.time") + ` AS last_run_utc,
  h.delivery_latency AS latency_ms, h.delivery_rate AS delivery_rate,
  u.undistributed,
  CASE WHEN h.delivery_rate > 0 THEN u.undistributed / h.delivery_rate END AS est_catchup_s
FROM ` + d + `.dbo.MSdistribution_agents a
LEFT JOIN master.sys.servers srv ON srv.server_id = a.publisher_id
LEFT JOIN master.sys.servers sub ON sub.server_id = a.subscriber_id
OUTER APPLY (SELECT TOP (1) x.runstatus, x.comments, x.time, x.delivery_latency, x.delivery_rate
               FROM ` + d + `.dbo.MSdistribution_history x WHERE x.agent_id = a.id ORDER BY x.time DESC, x.timestamp DESC) h
OUTER APPLY (SELECT SUM(CAST(s.UndelivCmdsInDistDB AS bigint)) AS undistributed
               FROM ` + d + `.dbo.MSdistribution_status s WHERE s.agent_id = a.id) u
WHERE a.subscriber_db <> N'virtual'
ORDER BY 3, 4, 5, 6, 7`
}

func replAgentsSQL(db string) string {
	d := quoteName(db)
	return `SELECT 'agent' AS kind, ` + literal(db) + ` AS distribution_db, 'logreader' AS agent_type, CAST(a.name AS nvarchar(200)) AS agent_name,
  CAST(srv.name AS nvarchar(128)) AS publisher, CAST(a.publisher_db AS nvarchar(128)) AS publisher_db, CAST(NULL AS nvarchar(128)) AS publication,
  h.runstatus, CAST(LEFT(h.comments, 1000) AS nvarchar(1000)) AS status_text, ` + utcText("h.time") + ` AS last_run_utc,
  h.delivery_latency AS latency_ms
FROM ` + d + `.dbo.MSlogreader_agents a
LEFT JOIN master.sys.servers srv ON srv.server_id = a.publisher_id
OUTER APPLY (SELECT TOP (1) x.runstatus, x.comments, x.time, x.delivery_latency
               FROM ` + d + `.dbo.MSlogreader_history x WHERE x.agent_id = a.id ORDER BY x.time DESC, x.timestamp DESC) h
UNION ALL
SELECT 'agent', ` + literal(db) + `, 'snapshot', CAST(a.name AS nvarchar(200)),
  CAST(srv.name AS nvarchar(128)), CAST(a.publisher_db AS nvarchar(128)), CAST(a.publication AS nvarchar(128)),
  h.runstatus, CAST(LEFT(h.comments, 1000) AS nvarchar(1000)), ` + utcText("h.time") + `, CAST(NULL AS int)
FROM ` + d + `.dbo.MSsnapshot_agents a
LEFT JOIN master.sys.servers srv ON srv.server_id = a.publisher_id
OUTER APPLY (SELECT TOP (1) x.runstatus, x.comments, x.time
               FROM ` + d + `.dbo.MSsnapshot_history x WHERE x.agent_id = a.id ORDER BY x.time DESC, x.timestamp DESC) h
UNION ALL
SELECT 'agent', ` + literal(db) + `, 'merge', CAST(a.name AS nvarchar(200)),
  CAST(srv.name AS nvarchar(128)), CAST(a.publisher_db AS nvarchar(128)), CAST(a.publication AS nvarchar(128)),
  h.runstatus, CAST(LEFT(c.comments, 1000) AS nvarchar(1000)), ` + utcText("COALESCE(h.end_time, h.start_time)") + `, CAST(NULL AS int)
FROM ` + d + `.dbo.MSmerge_agents a
LEFT JOIN master.sys.servers srv ON srv.server_id = a.publisher_id
OUTER APPLY (SELECT TOP (1) x.session_id, x.runstatus, x.start_time, x.end_time
               FROM ` + d + `.dbo.MSmerge_sessions x WHERE x.agent_id = a.id ORDER BY x.session_id DESC) h
OUTER APPLY (SELECT TOP (1) y.comments
               FROM ` + d + `.dbo.MSmerge_history y WHERE y.agent_id = a.id AND y.session_id = h.session_id ORDER BY y.timestamp DESC) c
ORDER BY 3, 4`
}

func (replicationCollector) Run(ctx context.Context, conn *sql.Conn, _ Info) ([]collect.Row, error) {
	dist, err := QueryRows(ctx, conn, replDistributorsSQL)
	if err != nil {
		return nil, err
	}
	rows := noRows()
	for _, d := range dist {
		name, _ := d["name"].(string)
		if access, _ := d["has_access"].(int64); access != 1 {
			rows = append(rows, replNoAccess(name))
			continue
		}
		for _, q := range []struct{ what, text string }{
			{"MSpublications", replPublicationsSQL(name)},
			{"MSdistribution_agents", replSubscriptionsSQL(name)},
			{"MSlogreader_agents", replAgentsSQL(name)},
		} {
			part, err := QueryRows(ctx, conn, q.text)
			if err != nil {
				if ctx.Err() != nil {
					return nil, err
				}
				rows = append(rows, collect.Row{"kind": "collector_error", "source": name + ".dbo." + q.what, "message": err.Error()})
				continue
			}
			rows = append(rows, part...)
		}
	}
	return rows, nil
}

// replNoAccess is the partial note of a distribution database the login cannot enter: it names the right.
func replNoAccess(db string) collect.Row {
	return collect.Row{"kind": "collector_error", "source": db,
		"message": fmt.Sprintf("the login has no user in the distribution database %s: replication was not read; the missing right is a user there with db_datareader", db)}
}
