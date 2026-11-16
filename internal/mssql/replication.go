package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// replicationCollector is mssql_replication: transactional, snapshot and merge replication.
//
//   - The PUBLISHER side, on every server: each published database (sys.databases), its log's reuse wait, the
//     distributor it names (sys.servers' distributor entry: this server or another one) and, with VIEW SERVER STATE,
//     the replicated transactions its log still holds for the log reader and how many it has read out (the
//     Databases counters 'Repl. Pending Xacts' and 'Repl. Trans. Rate'). A publisher whose distributor is another
//     server is judged from here even when that distributor is not monitored.
//   - The DISTRIBUTOR side, from each distribution database's own tables (MSpublications, MSdistribution_agents and
//     its history, MSlogreader_agents, MSsnapshot_agents and theirs, MSmerge_agents with MSmerge_sessions,
//     MSmerge_history and MSmerge_subscriptions) and its view MSdistribution_status for the commands not yet
//     delivered: per agent its last history row, since when it has been failing or retrying (the first row after its
//     last healthy one), the error text of MSrepl_errors, and for a subscription the entry time of the oldest
//     transaction still waiting for it (its latency while it delivers nothing). A merge agent is its subscription (one
//     per merge subscription, as a distribution agent is one per transactional subscription) and is read as one.
//     With msdb readable, each agent's SQL Server Agent job: running, stopped, disabled, not on this server (a pull
//     subscription's), and whether the agent runs continuously.
//
// Nothing is written: no tracer token, no call of a replication procedure. A server that is no distributor returns
// no distributor row; a publisher whose distributor is another server is read there.
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

// replPublishedSQL is the publisher side: one row per published database. The counters need VIEW SERVER STATE;
// without it they are NULL. 'Repl. Trans. Rate' is cumulative (a per-second counter's raw value): the import turns
// two reads into a rate.
func replPublishedSQL(counters bool) string {
	cnt := `CAST(NULL AS bigint) AS pending_xacts, CAST(NULL AS bigint) AS repl_trans_total`
	apply := ``
	if counters {
		cnt = `c.pending_xacts, c.repl_trans_total`
		apply = `
OUTER APPLY (SELECT CAST(MAX(CASE WHEN p.counter_name = N'Repl. Pending Xacts' THEN p.cntr_value END) AS bigint) AS pending_xacts,
                    CAST(MAX(CASE WHEN p.counter_name = N'Repl. Trans. Rate' THEN p.cntr_value END) AS bigint) AS repl_trans_total
               FROM sys.dm_os_performance_counters p
              WHERE p.object_name LIKE N'%:Databases%' AND p.instance_name = d.name
                AND p.counter_name IN (N'Repl. Pending Xacts', N'Repl. Trans. Rate')) c`
	}
	return `SELECT 'published_db' AS kind, CAST(d.name AS nvarchar(128)) AS database_name,
  CASE WHEN d.is_published = 1 AND d.is_merge_published = 1 THEN 'transactional or snapshot, merge'
       WHEN d.is_merge_published = 1 THEN 'merge' ELSE 'transactional or snapshot' END AS publication_type,
  CAST(d.log_reuse_wait_desc AS nvarchar(60)) AS log_reuse_wait,
  CAST(s.data_source AS nvarchar(256)) AS distributor,
  CASE WHEN s.data_source IS NULL THEN NULL WHEN UPPER(CAST(s.data_source AS nvarchar(256))) = UPPER(CAST(@@SERVERNAME AS nvarchar(256))) THEN 1 ELSE 0 END AS distributor_local,
  ` + cnt + `
FROM sys.databases d
OUTER APPLY (SELECT TOP (1) v.data_source FROM sys.servers v WHERE v.is_distributor = 1) s` + apply + `
WHERE (d.is_published = 1 OR d.is_merge_published = 1) AND d.state = 0
ORDER BY 2`
}

// replFailing is the part of an agent's statement that says since when it has been failing or retrying and why.
// The agent was last healthy at its newest idle or succeeded row (runstatus 4 or 2: it had caught up, or it was
// stopped cleanly). It is failing when a retry or failure row (5 or 6) is newer than that, and - for an agent with a
// delivery position (seqno: the distribution agent and the log reader) - no row after the newest failure carries a
// position past the one it had then: between a job's retries a failing distribution agent writes 'in progress' rows
// (runstatus 3) that deliver nothing. since = its first retry or failure row after the last healthy one and, for an
// agent with a position, at or after the time it first reached the position it is stuck at (a busy agent that
// never idles may have retried hours ago, then delivered: that older retry is not this failure). The error is
// MSrepl_errors' row of the newest failure's error id (SQL Server's generic 'agent failed' row, 14151, whose text
// carries the cause), its code taken from the cause's own row: one that follows within 5 s and whose text is part
// of that row's text (20598: the row was not found at the subscriber) - never another agent's error of that second.
func replFailing(d, hist string, seqno bool) string {
	h := d + `.dbo.` + hist
	moved, reach, pos := `0`, `'19000101'`, ``
	if seqno {
		pos = `
OUTER APPLY (SELECT MAX(q.xact_seqno) AS seqno FROM ` + h + ` q WHERE lf.time IS NOT NULL AND q.agent_id = a.id AND q.time <= lf.time) lp
OUTER APPLY (SELECT MIN(r.time) AS at FROM ` + h + ` r WHERE lp.seqno IS NOT NULL AND r.agent_id = a.id AND r.xact_seqno >= lp.seqno) rp`
		moved = `CASE WHEN EXISTS (SELECT 1 FROM ` + h + ` p WHERE p.agent_id = a.id AND p.time > lf.time AND p.xact_seqno > lp.seqno) THEN 1 ELSE 0 END`
		reach = `ISNULL(rp.at, '19000101')`
	}
	return `
OUTER APPLY (SELECT MAX(y.time) AS ok_at FROM ` + h + ` y WHERE y.agent_id = a.id AND y.runstatus IN (2, 4)) ok
OUTER APPLY (SELECT TOP (1) z.time, z.error_id FROM ` + h + ` z
              WHERE z.agent_id = a.id AND z.runstatus IN (5, 6) AND z.time > ISNULL(ok.ok_at, '19000101') ORDER BY z.time DESC, z.timestamp DESC) lf` + pos + `
OUTER APPLY (SELECT CASE WHEN lf.time IS NULL THEN 0 WHEN ` + moved + ` = 1 THEN 0 ELSE 1 END AS failing) fl
OUTER APPLY (SELECT MIN(z.time) AS since, MAX(z.error_id) AS error_id FROM ` + h + ` z
              WHERE fl.failing = 1 AND z.agent_id = a.id AND z.runstatus IN (5, 6) AND z.time > ISNULL(ok.ok_at, '19000101')
                AND z.time >= ` + reach + `) f
OUTER APPLY (SELECT TOP (1) e0.id, e0.time, CAST(e0.error_code AS nvarchar(128)) AS error_code,
                    CAST(LEFT(CAST(e0.error_text AS nvarchar(max)), 1000) AS nvarchar(1000)) AS error_text
               FROM ` + d + `.dbo.MSrepl_errors e0
              WHERE fl.failing = 1 AND e0.id = COALESCE(NULLIF(lf.error_id, 0), NULLIF(f.error_id, 0))
              ORDER BY CASE WHEN ISNULL(e0.error_code, N'') IN (N'', N'0') THEN 1 ELSE 0 END, e0.time DESC) e
OUTER APPLY (SELECT TOP (1) CAST(c2.error_code AS nvarchar(128)) AS error_code FROM ` + d + `.dbo.MSrepl_errors c2
              WHERE c2.id > e.id AND c2.id <= e.id + 5 AND c2.time >= e.time AND c2.time < DATEADD(second, 5, e.time)
                AND ISNULL(c2.error_code, N'') NOT IN (N'', N'0') AND c2.error_code <> e.error_code
                AND LEN(CAST(c2.error_text AS nvarchar(max))) >= 10
                AND CHARINDEX(CAST(LEFT(CAST(c2.error_text AS nvarchar(max)), 200) AS nvarchar(200)), e.error_text) > 0
              ORDER BY c2.id, c2.time) cz`
}

// the failing columns of replFailing, in the statement's order
func replFailingCols() string {
	return utcText("f.since") + ` AS failing_since_utc, COALESCE(cz.error_code, NULLIF(e.error_code, N'')) AS error_code, e.error_text`
}

// replServersSQL asks whether a distribution database keeps its own map of server ids (MSreplservers: srvid,
// srvname). Where it does, the publisher_id and subscriber_id of its tables are ids of that map, NOT of the
// distributor's sys.servers (read on a lab with a remote distributor: publisher_id 1 is the publisher there and
// sys.servers' 1 is repl_distributor). Where it does not, they are sys.servers ids, as before.
func replServersSQL(db string) string {
	return `SELECT CASE WHEN OBJECT_ID(` + literal(quoteName(db)+".dbo.MSreplservers") + `) IS NULL THEN 0 ELSE 1 END AS mapped`
}

// replServers is what a statement joins to name a server id: the distribution database's own map, or sys.servers.
func replServers(d string, mapped bool) string {
	if mapped {
		return `(SELECT CAST(rs.srvid AS int) AS server_id, CAST(rs.srvname AS nvarchar(128)) AS name FROM ` + d + `.dbo.MSreplservers rs)`
	}
	return `master.sys.servers`
}

// replPublicationsSQL, replSubscriptionsSQL and replAgentsSQL read one distribution database (SQL Server 2016 SP1
// and later; the tables are unchanged since 2005), naming the servers through sys.servers; the collector uses their
// ...For forms with the distribution database's own map where it has one (replServersSQL). runstatus: 1 start,
// 2 succeed, 3 in progress, 4 idle, 5 retry, 6 fail.
func replPublicationsSQL(db string) string  { return replPublicationsFor(db, false) }
func replSubscriptionsSQL(db string) string { return replSubscriptionsFor(db, false) }
func replAgentsSQL(db string) string        { return replAgentsFor(db, false) }

// replProbeError: a failed merge-tables probe as a collector_error row. Its source is never '<database>' alone nor
// '<database>.dbo.<table>': import_mssql_replication keeps a kind's last rows for those, and the reads that did work
// would then sit beside stale rows (TestReplicationProbeErrorKeepsNothing; part T's T6 imports this source).
func replProbeError(name string, err error) collect.Row {
	return collect.Row{"kind": "collector_error", "source": name + " (merge tables check)", "message": err.Error()}
}

// replMergeTablesSQL asks whether a distribution database has the four merge tables the merge arm reads (has_merge =
// 1): the subscriptions statement carries its merge arm only then, so a database without them still reads its
// transactional subscriptions. (Never the alias 'merge': MERGE is a T-SQL keyword, Msg 156.) has_sub_names = 1 where
// MSmerge_subscriptions names its subscriber (the column subscriber, beside subscriber_id): SQL Server 2022 leaves both
// subscriber ids NULL for a merge subscription and keeps the name (read on a Windows lab; Microsoft's page lists no
// such column, so it is read only where it is there).
func replMergeTablesSQL(db string) string {
	n := func(t string) string { return `OBJECT_ID(` + literal(quoteName(db)+".dbo."+t) + `)` }
	return `SELECT CASE WHEN ` + n("MSmerge_agents") + ` IS NULL OR ` + n("MSmerge_sessions") + ` IS NULL OR ` + n("MSmerge_history") +
		` IS NULL OR ` + n("MSmerge_subscriptions") + ` IS NULL THEN 0 ELSE 1 END AS has_merge,
  CASE WHEN COL_LENGTH(` + literal(quoteName(db)+".dbo.MSmerge_subscriptions") + `, 'subscriber') IS NULL THEN 0 ELSE 1 END AS has_sub_names`
}

func replPublicationsFor(db string, mapped bool) string {
	d := quoteName(db)
	return `SELECT 'publication' AS kind, ` + literal(db) + ` AS distribution_db,
  CAST(srv.name AS nvarchar(128)) AS publisher, CAST(p.publisher_db AS nvarchar(128)) AS publisher_db,
  CAST(p.publication AS nvarchar(128)) AS publication,
  CASE p.publication_type WHEN 0 THEN 'transactional' WHEN 1 THEN 'snapshot' WHEN 2 THEN 'merge' ELSE CAST(p.publication_type AS varchar(12)) END AS publication_type,
  -- publication type 2's articles (merge's) are kept in its publication database (sysmergearticles), never at the
  -- distributor: NULL, not 0
  CASE WHEN p.publication_type <> 2 THEN
    (SELECT COUNT(*) FROM ` + d + `.dbo.MSarticles a WHERE a.publisher_id = p.publisher_id AND a.publisher_db = p.publisher_db AND a.publication_id = p.publication_id) END AS articles
FROM ` + d + `.dbo.MSpublications p
LEFT JOIN ` + replServers(d, mapped) + ` srv ON srv.server_id = p.publisher_id
ORDER BY 3, 4, 5`
}

// replSubscriptionsSQL: one row per distribution agent (a subscription), and per merge agent (replMergeSubscriptions;
// replSubscriptionsOf without it where the database lacks the merge tables). oldest_pending_utc is the entry time of the
// oldest transaction past the agent's last delivered one (the newest xact_seqno of its history, as
// MSdistribution_status counts) that holds a command of an article it subscribes to; read only while commands wait.
// oldest_pending_age_s is its age on the distributor's own clock (no skew against the collector's).
// The reads of MSrepl_transactions and MSrepl_commands take no shared locks (READUNCOMMITTED, as
// MSdistribution_status itself reads them): the log reader and the cleanup job write there all the time.
func replSubscriptionsFor(db string, mapped bool) string {
	return replSubscriptionsOf(db, mapped, true)
}

func replSubscriptionsOf(db string, mapped, merge bool) string {
	return replSubscriptionsWith(db, mapped, merge, false)
}

// replSubscriptionsWith: names = MSmerge_subscriptions has its subscriber column (replMergeTablesSQL's has_sub_names).
func replSubscriptionsWith(db string, mapped, merge, names bool) string {
	d := quoteName(db)
	mergeArm := ``
	if merge {
		mergeArm = `
UNION ALL` + replMergeSubscriptions(db, mapped, names)
	}
	return `SELECT 'subscription' AS kind, ` + literal(db) + ` AS distribution_db, a.id AS agent_id,
  CAST(srv.name AS nvarchar(128)) AS publisher, CAST(a.publisher_db AS nvarchar(128)) AS publisher_db,
  CAST(a.publication AS nvarchar(128)) AS publication,
  CAST(sub.name AS nvarchar(128)) AS subscriber, CAST(a.subscriber_db AS nvarchar(128)) AS subscriber_db,
  CASE a.subscription_type WHEN 0 THEN 'push' WHEN 1 THEN 'pull' WHEN 2 THEN 'anonymous' ELSE CAST(a.subscription_type AS varchar(12)) END AS subscription_type,
  CASE ss.st WHEN 2 THEN 'active' WHEN 1 THEN 'subscribed' WHEN 0 THEN 'inactive' END AS subscription_status,
  'distribution' AS agent_type, CAST(a.name AS nvarchar(200)) AS agent_name,
  h.runstatus, CAST(LEFT(h.comments, 1000) AS nvarchar(1000)) AS status_text,
  ` + utcText("h.time") + ` AS last_run_utc, ` + utcText("h.start_time") + ` AS session_start_utc,
  h.delivery_latency AS latency_ms, h.delivery_rate AS delivery_rate,
  u.undistributed,
  CASE WHEN h.delivery_rate > 0 THEN u.undistributed / h.delivery_rate END AS est_catchup_s,
  ` + utcText("old.entry_time") + ` AS oldest_pending_utc,
  CASE WHEN old.entry_time IS NOT NULL THEN DATEDIFF(second, old.entry_time, GETDATE()) END AS oldest_pending_age_s,
  ` + replFailingCols() + `, CAST(NULL AS int) AS failing_untimed
FROM ` + d + `.dbo.MSdistribution_agents a
LEFT JOIN ` + replServers(d, mapped) + ` srv ON srv.server_id = a.publisher_id
LEFT JOIN ` + replServers(d, mapped) + ` sub ON sub.server_id = a.subscriber_id
OUTER APPLY (SELECT TOP (1) x.runstatus, x.comments, x.time, x.start_time, x.delivery_latency, x.delivery_rate, x.error_id
               FROM ` + d + `.dbo.MSdistribution_history x WHERE x.agent_id = a.id ORDER BY x.time DESC, x.timestamp DESC) h
OUTER APPLY (SELECT SUM(CAST(s.UndelivCmdsInDistDB AS bigint)) AS undistributed
               FROM ` + d + `.dbo.MSdistribution_status s WHERE s.agent_id = a.id) u
OUTER APPLY (SELECT MAX(s.status) AS st FROM ` + d + `.dbo.MSsubscriptions s WHERE s.agent_id = a.id) ss
OUTER APPLY (SELECT ISNULL(MAX(x.xact_seqno), 0x0) AS seqno FROM ` + d + `.dbo.MSdistribution_history x WHERE x.agent_id = a.id) pos
OUTER APPLY (SELECT TOP (1) t.entry_time FROM ` + d + `.dbo.MSrepl_transactions t WITH (READUNCOMMITTED)
              WHERE u.undistributed > 0 AND t.publisher_database_id = a.publisher_database_id AND t.xact_seqno > pos.seqno
                AND EXISTS (SELECT 1 FROM ` + d + `.dbo.MSrepl_commands c WITH (READUNCOMMITTED)
                              JOIN ` + d + `.dbo.MSsubscriptions s ON s.publisher_database_id = c.publisher_database_id AND s.article_id = c.article_id
                             WHERE c.publisher_database_id = t.publisher_database_id AND c.xact_seqno = t.xact_seqno AND s.agent_id = a.id)
              ORDER BY t.xact_seqno) old` + replFailing(d, "MSdistribution_history", true) + `
WHERE a.subscriber_db <> N'virtual'` + mergeArm + `
ORDER BY 4, 5, 6, 7, 8`
}

// mergeRecoveryHoldMin: a merge session in progress that wrote an error row counts as recovered inside itself once its
// newest row is clean and its newest error is this many minutes old (the lead 2026-11-15: long enough that a failing
// attempt writing clean rows between errors 60 s apart, as on the Windows lab, never reads recovered; short enough
// that one transient error of a long-running continuous agent clears soon: with reads 5 minutes apart two reads still
// see it failing and the third clears).
const mergeRecoveryHoldMin = 10

// replMergeSubscriptions is the merge arm of replSubscriptionsFor: one row per merge agent (MSmerge_agents), its
// newest session (MSmerge_sessions: runstatus 1 start, 2 succeed, 3 in progress, 4 idle, 5 retry, 6 fail; the time
// is its end, or its start while it runs) and that session's newest message (MSmerge_history), the subscription's
// type (MSmerge_subscriptions, matched to the agent's publication where the publication ids allow; by the subscriber's
// name where both subscriber ids are NULL and the table has the name: names). The distributor keeps no status for a
// merge subscription (MSmerge_subscriptions.status is no longer used: Microsoft's page; it lives in the publication
// database's sysmergesubscriptions) and no commands or latency for it (merge keeps its changes in the publication and
// subscription databases): those columns are NULL.
// Failing (read on a Windows lab: a continuous merge agent's healthy session stays 3, in progress, until its job
// stops; every start also writes a session of runstatus 1 and no duration): a session is healthy when it ended 2 / 4,
// or is in progress (3) with no error row in its own history or recovered inside itself (its newest row is clean and
// its newest error is mergeRecoveryHoldMin minutes old or more); it is failing when it is 5 / 6, or in progress
// otherwise. The agent is failing while a failing session is newer than its newest healthy one (the streak); since =
// the earliest MSrepl_errors time of the streak's error rows after its last recovery inside a session (an error row
// followed by a clean row and then the hold with no error), so a retry carries the first failure's time, a session
// healthy for hours before its first error starts the streak at that error, and a failure after a recovery inside a
// long session starts it again. A retry's first seconds, before its first error row, read healthy (the known limit:
// about 90 s on the lab, where a failing attempt wrote its first error row 90 s after its start).
// failing_untimed = 1: failing, and no error row of the streak names an MSrepl_errors row (no time at the distributor:
// the import takes the first read that saw it). The error = the newest MSmerge_history row of the streak that names an
// error id, its MSrepl_errors row with an error code first. MSmerge_history has no time of its own: its timestamp
// (rowversion) orders the rows, MSrepl_errors.time dates the errors.
func replMergeSubscriptions(db string, mapped, names bool) string {
	d := quoteName(db)
	hold := strconv.Itoa(mergeRecoveryHoldMin)
	subMatch := `m.subscriber_id = a.subscriber_id`
	if names {
		subMatch = `(m.subscriber_id = a.subscriber_id
                     OR (a.subscriber_id IS NULL AND m.subscriber_id IS NULL AND UPPER(m.subscriber) = UPPER(a.subscriber_name)))`
	}
	// errorRow: a history row of session x that names an error; healthy3: session x in progress counts as healthy (no
	// error row, or recovered inside itself: its newest row clean and its newest error the hold old or more)
	errorRow := func(x string) string {
		return `EXISTS (SELECT 1 FROM ` + d + `.dbo.MSmerge_history h0 WHERE h0.agent_id = ` + x + `.agent_id AND h0.session_id = ` + x + `.session_id AND ISNULL(h0.error_id, 0) <> 0)`
	}
	same := func(alias, x string) string {
		return alias + `.agent_id = ` + x + `.agent_id AND ` + alias + `.session_id = ` + x + `.session_id`
	}
	healthy3 := func(x string) string {
		return `(NOT ` + errorRow(x) + `
                    OR ((SELECT MAX(hc.timestamp) FROM ` + d + `.dbo.MSmerge_history hc WHERE ` + same("hc", x) + ` AND ISNULL(hc.error_id, 0) = 0)
                        > (SELECT MAX(he.timestamp) FROM ` + d + `.dbo.MSmerge_history he WHERE ` + same("he", x) + ` AND ISNULL(he.error_id, 0) <> 0)
                        AND ISNULL((SELECT MAX(e2.time) FROM ` + d + `.dbo.MSmerge_history he2 JOIN ` + d + `.dbo.MSrepl_errors e2 ON e2.id = he2.error_id
                                     WHERE ` + same("he2", x) + ` AND ISNULL(he2.error_id, 0) <> 0), '19000101') <= DATEADD(minute, -` + hold + `, GETDATE())))`
	}
	return `
SELECT 'subscription', ` + literal(db) + `, a.id,
  CAST(srv.name AS nvarchar(128)), CAST(a.publisher_db AS nvarchar(128)), CAST(a.publication AS nvarchar(128)),
  COALESCE(CAST(sub.name AS nvarchar(128)), CAST(a.subscriber_name AS nvarchar(128))), CAST(a.subscriber_db AS nvarchar(128)),
  CASE ms.subscription_type WHEN 0 THEN 'push' WHEN 1 THEN 'pull' WHEN 2 THEN 'anonymous' ELSE CAST(ms.subscription_type AS varchar(12)) END,
  CAST(NULL AS varchar(10)), 'merge', CAST(a.name AS nvarchar(200)),
  h.runstatus, CAST(LEFT(c.comments, 1000) AS nvarchar(1000)),
  ` + utcText("COALESCE(h.end_time, h.start_time)") + `, ` + utcText("h.start_time") + `,
  CAST(NULL AS int), h.delivery_rate, CAST(NULL AS bigint), CAST(NULL AS float), CAST(NULL AS varchar(33)), CAST(NULL AS int),
  ` + utcText("mt.since") + `, NULLIF(me.error_code, N''), me.error_text,
  CASE WHEN mf.first_id IS NOT NULL AND mt.since IS NULL THEN 1 END
FROM ` + d + `.dbo.MSmerge_agents a
LEFT JOIN ` + replServers(d, mapped) + ` srv ON srv.server_id = a.publisher_id
LEFT JOIN ` + replServers(d, mapped) + ` sub ON sub.server_id = a.subscriber_id
OUTER APPLY (SELECT TOP (1) m.subscription_type FROM ` + d + `.dbo.MSmerge_subscriptions m
               LEFT JOIN ` + d + `.dbo.MSpublications p ON p.publication_id = m.publication_id AND p.publisher_id = m.publisher_id AND p.publisher_db = m.publisher_db
              WHERE m.publisher_id = a.publisher_id AND m.publisher_db = a.publisher_db AND m.subscriber_db = a.subscriber_db
                AND ` + subMatch + `
              ORDER BY CASE WHEN p.publication = a.publication THEN 0 ELSE 1 END) ms
OUTER APPLY (SELECT TOP (1) x.session_id, x.runstatus, x.start_time, x.end_time, x.delivery_rate
               FROM ` + d + `.dbo.MSmerge_sessions x WHERE x.agent_id = a.id ORDER BY x.session_id DESC) h
OUTER APPLY (SELECT TOP (1) y.comments
               FROM ` + d + `.dbo.MSmerge_history y WHERE y.agent_id = a.id AND y.session_id = h.session_id ORDER BY y.timestamp DESC) c
-- the newest healthy session: the newest that ended 2 / 4, or a session in progress newer than it that counts as
-- healthy (the history is read only for those: review q10wa S1, a spool of the whole table otherwise)
OUTER APPLY (SELECT MAX(y.session_id) AS ok24 FROM ` + d + `.dbo.MSmerge_sessions y WHERE y.agent_id = a.id AND y.runstatus IN (2, 4)) m24
OUTER APPLY (SELECT MAX(y.session_id) AS ok3 FROM ` + d + `.dbo.MSmerge_sessions y
              WHERE y.agent_id = a.id AND y.runstatus = 3 AND y.session_id > ISNULL(m24.ok24, -2147483648) AND ` + healthy3("y") + `) m3
-- the streak: every session in progress newer than the newest healthy one is failing (else it would be that one)
OUTER APPLY (SELECT MIN(z.session_id) AS first_id FROM ` + d + `.dbo.MSmerge_sessions z
              WHERE z.agent_id = a.id AND z.runstatus IN (3, 5, 6) AND z.session_id > ISNULL(ISNULL(m3.ok3, m24.ok24), -2147483648)) mf
-- the last recovery inside a streak session: a timed error row followed in its session by a clean row before the
-- next error row, a later error row in the session (a recovery with none after it is a healthy session, never a
-- streak's), and every later error of the session the hold or more after it; the streak's errors count after it.
-- One ordered pass over the streak's history (review q10wc S1: nested EXISTS per error row spooled the whole table):
-- cl = the session's clean rows so far; over the error rows, the next one's cl and the later ones' earliest time
OUTER APPLY (SELECT MAX(w2.ts) AS cut
               FROM (SELECT w.ts, w.tmax, w.cl,
                            LEAD(w.ts) OVER (PARTITION BY w.session_id ORDER BY w.ts) AS next_ts,
                            LEAD(w.cl) OVER (PARTITION BY w.session_id ORDER BY w.ts) AS next_cl,
                            MIN(w.tmin) OVER (PARTITION BY w.session_id ORDER BY w.ts ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS later_tmin
                       FROM (SELECT r.session_id, r.timestamp AS ts, ISNULL(r.error_id, 0) AS eid, rt.tmin, rt.tmax,
                                    SUM(CASE WHEN ISNULL(r.error_id, 0) = 0 THEN 1 ELSE 0 END)
                                      OVER (PARTITION BY r.session_id ORDER BY r.timestamp ROWS UNBOUNDED PRECEDING) AS cl
                               FROM ` + d + `.dbo.MSmerge_history r
                               OUTER APPLY (SELECT MIN(er.time) AS tmin, MAX(er.time) AS tmax FROM ` + d + `.dbo.MSrepl_errors er
                                             WHERE ISNULL(r.error_id, 0) <> 0 AND er.id = r.error_id) rt
                              WHERE mf.first_id IS NOT NULL AND r.agent_id = a.id AND r.session_id >= mf.first_id) w
                      WHERE w.eid <> 0) w2
              WHERE w2.tmax IS NOT NULL AND w2.next_ts IS NOT NULL AND w2.next_cl > w2.cl
                AND (w2.later_tmin IS NULL OR w2.later_tmin >= DATEADD(minute, ` + hold + `, w2.tmax))) mc
OUTER APPLY (SELECT MIN(e1.time) AS since FROM ` + d + `.dbo.MSmerge_history y1 JOIN ` + d + `.dbo.MSrepl_errors e1 ON e1.id = y1.error_id
              WHERE mf.first_id IS NOT NULL AND y1.agent_id = a.id AND y1.session_id >= mf.first_id AND ISNULL(y1.error_id, 0) <> 0
                AND (mc.cut IS NULL OR y1.timestamp > mc.cut)) mt
OUTER APPLY (SELECT TOP (1) y.error_id FROM ` + d + `.dbo.MSmerge_history y
              WHERE mf.first_id IS NOT NULL AND y.agent_id = a.id AND y.session_id >= mf.first_id AND ISNULL(y.error_id, 0) <> 0
                AND (mc.cut IS NULL OR y.timestamp > mc.cut)
              ORDER BY y.session_id DESC, y.timestamp DESC) mh
OUTER APPLY (SELECT TOP (1) CAST(e0.error_code AS nvarchar(128)) AS error_code,
                    CAST(LEFT(CAST(e0.error_text AS nvarchar(max)), 1000) AS nvarchar(1000)) AS error_text
               FROM ` + d + `.dbo.MSrepl_errors e0 WHERE e0.id = mh.error_id
              ORDER BY CASE WHEN ISNULL(e0.error_code, N'') IN (N'', N'0') THEN 1 ELSE 0 END, e0.time DESC,
                       -- one stack's rows share their second: the engine's cause (18456, 2627) before replication's own
                       -- message (14000-14999, 20000-21999), then the code, so a read picks the same row every time
                       CASE WHEN TRY_CAST(e0.error_code AS int) BETWEEN 14000 AND 14999 OR TRY_CAST(e0.error_code AS int) BETWEEN 20000 AND 21999 THEN 1 ELSE 0 END,
                       e0.error_code) me`
}

// replAgentsSQL: the log reader and snapshot agents (a merge agent is read as its subscription: replMergeSubscriptions).
func replAgentsFor(db string, mapped bool) string {
	d := quoteName(db)
	return `SELECT 'agent' AS kind, ` + literal(db) + ` AS distribution_db, a.id AS agent_id, 'logreader' AS agent_type, CAST(a.name AS nvarchar(200)) AS agent_name,
  CAST(srv.name AS nvarchar(128)) AS publisher, CAST(a.publisher_db AS nvarchar(128)) AS publisher_db, CAST(NULL AS nvarchar(128)) AS publication,
  h.runstatus, CAST(LEFT(h.comments, 1000) AS nvarchar(1000)) AS status_text, ` + utcText("h.time") + ` AS last_run_utc,
  ` + utcText("h.start_time") + ` AS session_start_utc, h.delivery_latency AS latency_ms,
  ` + replFailingCols() + `
FROM ` + d + `.dbo.MSlogreader_agents a
LEFT JOIN ` + replServers(d, mapped) + ` srv ON srv.server_id = a.publisher_id
OUTER APPLY (SELECT TOP (1) x.runstatus, x.comments, x.time, x.start_time, x.delivery_latency, x.error_id
               FROM ` + d + `.dbo.MSlogreader_history x WHERE x.agent_id = a.id ORDER BY x.time DESC, x.timestamp DESC) h` + replFailing(d, "MSlogreader_history", true) + `
UNION ALL
SELECT 'agent', ` + literal(db) + `, a.id, 'snapshot', CAST(a.name AS nvarchar(200)),
  CAST(srv.name AS nvarchar(128)), CAST(a.publisher_db AS nvarchar(128)), CAST(a.publication AS nvarchar(128)),
  h.runstatus, CAST(LEFT(h.comments, 1000) AS nvarchar(1000)), ` + utcText("h.time") + `, ` + utcText("h.start_time") + `, CAST(NULL AS int),
  ` + replFailingCols() + `
FROM ` + d + `.dbo.MSsnapshot_agents a
LEFT JOIN ` + replServers(d, mapped) + ` srv ON srv.server_id = a.publisher_id
OUTER APPLY (SELECT TOP (1) x.runstatus, x.comments, x.time, x.start_time, x.error_id
               FROM ` + d + `.dbo.MSsnapshot_history x WHERE x.agent_id = a.id ORDER BY x.time DESC, x.timestamp DESC) h` + replFailing(d, "MSsnapshot_history", false) + `
ORDER BY 4, 5`
}

// replJobsSQL: each agent's SQL Server Agent job on this server (msdb). job_state: running (its newest activity row
// has a start and no stop), stopped, disabled, 'not here' (no job on this server: a pull subscription's agent runs
// at the subscriber), 'Agent stopped' (SQL Server Agent itself is not running; read with VIEW SERVER STATE only).
// continuous: the job step runs the agent with -Continuous (it is meant to run all the time).
func replJobsSQL(db string, serverState bool) string {
	d := quoteName(db)
	svc, svcApply := `CAST(NULL AS nvarchar(60))`, ``
	if serverState {
		svc = `svc.status_desc`
		svcApply = `
OUTER APPLY (SELECT TOP (1) CAST(v.status_desc AS nvarchar(60)) AS status_desc FROM sys.dm_server_services v WHERE v.servicename LIKE N'SQL Server Agent%') svc`
	}
	return `SELECT 'agent_job' AS kind, ` + literal(db) + ` AS distribution_db, a.agent_type, CAST(a.name AS nvarchar(200)) AS agent_name,
  CASE WHEN j.job_id IS NULL THEN 'not here'
       WHEN ` + svc + ` IS NOT NULL AND ` + svc + ` <> N'Running' THEN 'Agent stopped'
       WHEN act.start_execution_date IS NOT NULL AND act.stop_execution_date IS NULL THEN 'running'
       WHEN j.enabled = 0 THEN 'disabled'
       ELSE 'stopped' END AS job_state,
  CASE WHEN j.job_id IS NULL THEN NULL WHEN st.command LIKE N'%-Continuous%' THEN 1 ELSE 0 END AS continuous,
  ` + utcText("act.stop_execution_date") + ` AS job_stopped_utc
FROM (SELECT name, job_id, 'distribution' AS agent_type FROM ` + d + `.dbo.MSdistribution_agents WHERE subscriber_db <> N'virtual'
      UNION ALL SELECT name, job_id, 'logreader' FROM ` + d + `.dbo.MSlogreader_agents
      UNION ALL SELECT name, job_id, 'snapshot' FROM ` + d + `.dbo.MSsnapshot_agents
      UNION ALL SELECT name, job_id, 'merge' FROM ` + d + `.dbo.MSmerge_agents) a
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = CAST(a.job_id AS uniqueidentifier)
OUTER APPLY (SELECT TOP (1) x.start_execution_date, x.stop_execution_date FROM msdb.dbo.sysjobactivity x
              WHERE x.job_id = j.job_id ORDER BY x.session_id DESC) act
OUTER APPLY (SELECT TOP (1) s.command FROM msdb.dbo.sysjobsteps s
              WHERE s.job_id = j.job_id AND s.subsystem IN (N'Distribution', N'LogReader', N'Snapshot', N'Merge') ORDER BY s.step_id) st` + svcApply + `
ORDER BY 3, 4`
}

// replMsdbTables are the msdb tables replJobsSQL reads; each is asked for with msdbReadable first.
var replMsdbTables = []string{"sysjobs", "sysjobactivity", "sysjobsteps"}

func (replicationCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows := noRows()
	// the publisher side first: a server that publishes to another server's distributor has no distribution database
	pub, err := QueryRows(ctx, conn, replPublishedSQL(info.ViewServerState))
	if err != nil {
		if ctx.Err() != nil {
			return nil, err
		}
		rows = append(rows, collect.Row{"kind": "collector_error", "source": "published databases", "message": err.Error()})
	} else {
		rows = append(rows, pub...)
	}
	dist, err := QueryRows(ctx, conn, replDistributorsSQL)
	if err != nil {
		return nil, err
	}
	// the agents' jobs: read when msdb's three tables are readable, else said once per distribution database
	jobsWhy := ""
	if len(dist) > 0 {
		if !info.MsdbAccess {
			jobsWhy = "the login has no access to msdb (a user there with db_datareader): the agents' jobs (running, stopped) were not read"
		} else {
			for _, t := range replMsdbTables {
				if err := msdbReadable(ctx, conn, t); err != nil {
					if ctx.Err() != nil {
						return nil, ctx.Err()
					}
					jobsWhy = strings.TrimSuffix(err.Error(), ": "+collect.ErrSkip.Error()) + ": the agents' jobs (running, stopped) were not read"
					break
				}
			}
		}
	}
	for _, d := range dist {
		name, _ := d["name"].(string)
		if access, _ := d["has_access"].(int64); access != 1 {
			rows = append(rows, replNoAccess(name))
			continue
		}
		// a failed probe is said (a source that keeps no rows: the import keeps a kind's last rows only for
		// '<database>.dbo.<table>' or '<database>' alone) and the merge arm stays on: where the merge tables really are
		// missing, the subscriptions read then fails under its own source and its last rows are kept
		hasMerge, hasNames := true, false
		if m, err := QueryRows(ctx, conn, replMergeTablesSQL(name)); err != nil {
			if ctx.Err() != nil {
				return nil, err
			}
			rows = append(rows, replProbeError(name, err))
		} else if len(m) == 1 {
			v, _ := m[0]["has_merge"].(int64)
			hasMerge = v == 1
			n, _ := m[0]["has_sub_names"].(int64)
			hasNames = n == 1
		}
		mapped := false
		if m, err := QueryRows(ctx, conn, replServersSQL(name)); err != nil {
			if ctx.Err() != nil {
				return nil, err
			}
			rows = append(rows, collect.Row{"kind": "collector_error", "source": name, "message": "the server map (MSreplservers): " + err.Error()})
			continue
		} else if len(m) == 1 {
			v, _ := m[0]["mapped"].(int64)
			mapped = v == 1
		}
		reads := []struct{ what, text string }{
			{"MSpublications", replPublicationsFor(name, mapped)},
			{"MSdistribution_agents", replSubscriptionsWith(name, mapped, hasMerge, hasNames)},
			{"MSlogreader_agents", replAgentsFor(name, mapped)},
		}
		if jobsWhy == "" {
			reads = append(reads, struct{ what, text string }{"msdb jobs", replJobsSQL(name, info.ViewServerState)})
		} else {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": name + ".msdb", "message": jobsWhy})
		}
		for _, q := range reads {
			part, err := QueryRows(ctx, conn, q.text)
			if err != nil {
				if ctx.Err() != nil {
					return nil, err
				}
				src := name + ".dbo." + q.what
				if q.what == "msdb jobs" {
					src = name + ".msdb"
				}
				rows = append(rows, collect.Row{"kind": "collector_error", "source": src, "message": err.Error()})
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
		"message": fmt.Sprintf("the login cannot enter the distribution database %s: replication was not read; the missing right is a user there with db_datareader (or the database sits on a secondary replica that takes no connections: read it on the primary)", db)}
}
