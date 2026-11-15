package web

import "net/http"

// Azure SQL Database's geo-replication and failover groups (task 390a; 0151): DBA Dash reads none of this, so the
// block takes its availability group grid's shape (one row per link, its state coloured, the lag), on the instance's
// Availability tab. Data: mssql_georepl_read / _state / _sample / _events (mssql_georepl), mssql_failover_groups /
// _events (mssql_failover_groups, matched to the database by the logical server its read reached), the findings of
// mssql_georepl_findings, and the collections' last runs (collection_dates).

// the last read of the database and the collections' runs (why a block is empty)
const sqlGeoRead = `
SELECT g.snapshot_at, g.server_read, g.database_name, g.links,
       (SELECT d.status FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.collection = 'mssql_georepl') AS georepl_status,
       (SELECT d.note FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.collection = 'mssql_georepl') AS georepl_note,
       (SELECT d.status FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.collection = 'mssql_failover_groups') AS groups_status,
       (SELECT d.note FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.collection = 'mssql_failover_groups') AS groups_note
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.mssql_georepl_read g ON g.instance_id = i.instance_id
 WHERE i.instance_id = $1`

// one row per link with both ends: this database's row and, when the partner database is monitored too (an instance
// whose read reached that server and database), its link row by link_guid and its instance
const sqlGeoLinks = `
SELECT s.link_guid, s.role_desc, s.partner_server, s.partner_database, s.replication_state_desc, s.state_since,
       s.replication_lag_sec, round(s.unsent_s) AS unsent_s, s.ack_age_s, s.last_replication, s.last_commit,
       s.secondary_allow_connections_desc, s.server_read, s.snapshot_at,
       p.instance_id AS partner_instance_id, p.role_desc AS partner_role, p.last_commit AS partner_last_commit
  FROM pgvigil.mssql_georepl_state s
  LEFT JOIN pgvigil.mssql_georepl_state p ON p.link_guid = s.link_guid AND p.instance_id <> s.instance_id
 WHERE s.instance_id = $1
 ORDER BY s.partner_server, s.partner_database`

// the failover groups of the logical server this database's read reached, those that hold it first
const sqlGeoGroups = `
SELECT f.group_name, f.role, f.replication_state, f.secondary_type, f.rw_policy, f.grace_minutes, f.ro_policy, f.ro_target,
       f.partners, f.databases, f.snapshot_at, f.server_key,
       EXISTS (SELECT 1 FROM jsonb_array_elements_text(f.databases) d WHERE lower(d) = lower(g.database_name)) AS holds_database
  FROM pgvigil.mssql_georepl_read g
  JOIN pgvigil.mssql_failover_groups f ON split_part(f.server_key, '/', 3) = lower(g.server_read)
 WHERE g.instance_id = $1
 ORDER BY holds_database DESC, f.group_name`

// the window's samples (newest first, at most a day of minutes; the hours past a day are B2a-N2's shape)
const sqlGeoSeries = `
SELECT x.snapshot_at, x.link_guid, x.role, x.replication_state, x.replication_lag_sec, round(x.unsent_s) AS unsent_s, x.ack_age_s
  FROM pgvigil.mssql_georepl_sample x
 WHERE x.instance_id = $1 AND x.snapshot_at >= $2 AND x.snapshot_at < $3
 ORDER BY x.snapshot_at DESC
 LIMIT 1440`

// the window's events: the links' and the groups' (the groups' by the server the read reached)
const sqlGeoEvents = `
SELECT e.at, e.prev_read_at, 'link' AS what, e.kind, e.old_value, e.new_value, e.partner AS object
  FROM pgvigil.mssql_georepl_events e
 WHERE e.instance_id = $1 AND e.at >= $2 AND e.at < $3
UNION ALL
SELECT e.at, e.prev_read_at, 'failover group', e.kind, e.old_value, e.new_value, e.group_name
  FROM pgvigil.mssql_georepl_read g
  JOIN pgvigil.mssql_failover_group_events e ON split_part(e.server_key, '/', 3) = lower(g.server_read)
 WHERE g.instance_id = $1 AND e.at >= $2 AND e.at < $3
 ORDER BY 1 DESC
 LIMIT 500`

const sqlGeoFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail
  FROM pgvigil.mssql_georepl_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 ELSE 1 END, f.at DESC`

// MSSQLGeoRepl is GET /api/mssql/georepl?instance=N&from=&to=[&part=]: one Azure SQL Database's geo-replication links,
// its server's failover groups, the window's samples and events, and the findings.
func (s *Server) MSSQLGeoRepl(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"read", sqlGeoRead, []any{id}},
		{"links", sqlGeoLinks, []any{id}},
		{"groups", sqlGeoGroups, []any{id}},
		{"series", sqlGeoSeries, []any{id, from, to}},
		{"events", sqlGeoEvents, []any{id, from, to}},
		{"findings", sqlGeoFindings, []any{id}},
	})
}
