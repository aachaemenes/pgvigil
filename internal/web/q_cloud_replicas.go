package web

import "net/http"

// The provider replicas of an RDS or Cloud SQL instance (task 390b; 0151 part P): the Replicas (provider) block on a
// PostgreSQL instance's Replication tab and an RDS for SQL Server instance's Availability tab. Data: cloud_replicas /
// _reads / _sample / _hour / _events / cloud_failover_events, read by the instance's cloud_replicas (or
// mssql_cloud_replicas) collection through the provider's API, the findings of cloud_replica_findings, and the
// collection's last run (collection_dates). A resource is one row whoever reads it: the block shows the instance's own
// resource, its replicas and its source as the current rows name them (cloud_replica_readers).

// the instance's read and the collection's last run (why the block is empty)
const sqlCloudReplicaRead = `
SELECT i.engine, i.platform, g.provider, g.resource_id, g.snapshot_at, g.resources, g.door_fails, g.door_error, g.door_since,
       g.instance_id IS NOT NULL AS has,
       (SELECT d.status FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.collection IN ('cloud_replicas', 'mssql_cloud_replicas')
         ORDER BY d.snapshot_at DESC LIMIT 1) AS run_status,
       (SELECT d.note FROM pgvigil.collection_dates d WHERE d.instance_id = i.instance_id AND d.collection IN ('cloud_replicas', 'mssql_cloud_replicas')
         ORDER BY d.snapshot_at DESC LIMIT 1) AS run_note
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.cloud_replica_reads g ON g.instance_id = i.instance_id
 WHERE i.instance_id = $1`

// the resources the instance's read covers, each with its newest lag and byte lag and whether it is monitored here
// (an instance whose own resource it is: the link to its page)
const sqlCloudReplicaResources = `
SELECT c.provider, c.resource_id, c.resource_id = g.resource_id AS self, c.role, c.source_id, c.replica_ids, c.cascaded, c.engine, c.region,
       c.status, c.repl_status, c.repl_note, c.repl_since, c.first_seen_at, c.snapshot_at,
       (SELECT x.value FROM pgvigil.cloud_replica_sample x WHERE x.provider = c.provider AND x.resource_id = c.resource_id AND x.metric = 'replica_lag'
         ORDER BY x.snapshot_at DESC LIMIT 1) AS lag_s,
       (SELECT x.snapshot_at FROM pgvigil.cloud_replica_sample x WHERE x.provider = c.provider AND x.resource_id = c.resource_id AND x.metric = 'replica_lag'
         ORDER BY x.snapshot_at DESC LIMIT 1) AS lag_at,
       (SELECT x.value FROM pgvigil.cloud_replica_sample x WHERE x.provider = c.provider AND x.resource_id = c.resource_id AND x.metric = 'replica_byte_lag'
         ORDER BY x.snapshot_at DESC LIMIT 1) AS byte_lag,
       (SELECT o.instance_id FROM pgvigil.cloud_replica_reads o JOIN pgvigil.instances oi ON oi.instance_id = o.instance_id AND oi.is_active
         WHERE o.provider = c.provider AND o.resource_id = c.resource_id ORDER BY o.snapshot_at DESC LIMIT 1) AS monitored_as
  FROM pgvigil.cloud_replica_reads g
  JOIN pgvigil.cloud_replica_readers r ON r.instance_id = g.instance_id
  JOIN pgvigil.cloud_replicas c ON c.provider = r.provider AND c.resource_id = r.resource_id
 WHERE g.instance_id = $1
 ORDER BY CASE c.role WHEN 'source' THEN 0 WHEN 'standalone' THEN 1 ELSE 2 END, c.resource_id`

// the window's series of those resources, newest first: a day or less their samples; longer the hours
// (cloud_replica_window: each row's maximum, a sample row its own value), so a chart reads 5 minutes to a year
const sqlCloudReplicaSeries = `
WITH ids AS (SELECT r.provider, array_agg(r.resource_id) AS ids FROM pgvigil.cloud_replica_readers r WHERE r.instance_id = $1 GROUP BY r.provider)
SELECT x.snapshot_at, x.resource_id, x.metric, x.value
  FROM ids JOIN pgvigil.cloud_replica_sample x ON x.provider = ids.provider AND x.resource_id = ANY (ids.ids)
 WHERE $3::timestamptz - $2::timestamptz <= interval '1 day' AND x.snapshot_at >= $2 AND x.snapshot_at < $3
UNION ALL
SELECT w.snapshot_at, w.resource_id, w.metric, w.max_value
  FROM ids CROSS JOIN LATERAL pgvigil.cloud_replica_window(ids.provider, ids.ids, $2, $3) w
 WHERE $3::timestamptz - $2::timestamptz > interval '1 day'
 ORDER BY 1 DESC
 LIMIT 40000`

// the window's events: the topology's and the instance's own provider failovers (P3)
const sqlCloudReplicaEvents = `
SELECT e.at, e.prev_read_at, e.resource_id, e.kind, e.subject, e.old_value, e.new_value
  FROM pgvigil.cloud_replica_events e
  JOIN pgvigil.cloud_replica_readers r ON r.provider = e.provider AND r.resource_id = e.resource_id AND r.instance_id = $1
 WHERE e.at >= $2 AND e.at < $3
UNION ALL
SELECT f.at, NULL, f.resource_id, 'failover ' || f.phase, f.source, NULL, f.message
  FROM pgvigil.cloud_failover_events f
  JOIN pgvigil.cloud_replica_reads g ON g.provider = f.provider AND g.resource_id = f.resource_id AND g.instance_id = $1
 WHERE f.at >= $2 AND f.at < $3
 ORDER BY 1 DESC
 LIMIT 500`

const sqlCloudReplicaFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail
  FROM pgvigil.cloud_replica_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 ELSE 1 END, f.at DESC`

// CloudReplicas is GET /api/cloud/replicas?instance=N&from=&to=[&part=]: an RDS or Cloud SQL instance's provider
// replicas (its own resource, its replicas, its source), the window's lag series and events, and the findings.
func (s *Server) CloudReplicas(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"read", sqlCloudReplicaRead, []any{id}},
		{"resources", sqlCloudReplicaResources, []any{id}},
		{"series", sqlCloudReplicaSeries, []any{id, from, to}},
		{"events", sqlCloudReplicaEvents, []any{id, from, to}},
		{"findings", sqlCloudReplicaFindings, []any{id}},
	})
}
