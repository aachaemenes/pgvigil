package web

import "net/http"

// The Index locks tab of a SQL Server instance (task 130; Darling's FinOps, Locking & Contention): where sessions
// waited for locks over the window, per index, from the differences of sys.dm_db_index_operational_stats between
// two reads (mssql_indexlocks, every five minutes; 0084).
//
//	GET /api/mssql/indexlocks?instance=N[&from=&to=][&db=<database id>][&part=...]
//	  state       the mssql_indexlocks collection's last run
//	  reads       the reads of the window that took differences: how many, the seconds they cover
//	  databases   the databases with an index that had a lock wait or an escalation in the window (the page's filter),
//	              each under one name
//	  totals      the window's sums over every index (db= one database's), whatever the grid's limit
//	  indexes     one row per index (db= keeps one database's): row lock waits and their ms, page lock waits
//	              and their ms, the average of each, the lock escalation attempts and the escalations. The most
//	              lock wait first; 2,000 at most.
//	  series      the window in about 120 steps (five minutes at least): lock wait ms per second (row and page) and
//	              escalations over all indexes (db= keeps one database's)
//
// The counters are waits that ENDED on the index: where sessions collided. They name no holder; the head of a
// chain and its statement are on the Running queries and Blocked reports pages.

const sqlMSSQLIndexLockReads = `
SELECT count(*) AS reads, coalesce(sum(r.interval_secs), 0)::float8 AS covered_secs, min(r.snapshot_at) AS first_read, max(r.snapshot_at) AS last_read
  FROM pgvigil.mssql_indexlock_read r
 WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3`

// indexLockDBNames: one name per database of the window, for the filter list, the grid and the chart alike: the
// newest name read, else 'database <id>'. $1 instance, $2 and $3 the window.
const indexLockDBNames = `
  SELECT DISTINCT ON (s.database_id) s.database_id, coalesce(s.database_name, 'database ' || s.database_id) AS database
    FROM pgvigil.mssql_indexlock_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   ORDER BY s.database_id, (s.database_name IS NULL), s.snapshot_at DESC`

const sqlMSSQLIndexLockDatabases = `
WITH dbn AS (` + indexLockDBNames + `)
SELECT n.database_id, n.database, count(DISTINCT (s.object_id, s.index_id)) AS indexes,
       sum(s.row_lock_wait_ms + s.page_lock_wait_ms)::bigint AS lock_wait_ms
  FROM pgvigil.mssql_indexlock_sample s
  JOIN dbn n ON n.database_id = s.database_id
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY n.database_id, n.database
 ORDER BY n.database, n.database_id`

// sqlMSSQLIndexLocks: $4 the database's id, NULL = every database. An index whose names were read in one interval
// and not in another keeps them: max() skips the NULL.
const sqlMSSQLIndexLocks = `
WITH dbn AS (` + indexLockDBNames + `), x AS (
  SELECT s.database_id, s.object_id, s.index_id,
         max(s.schema_name) AS schema_name, max(s.table_name) AS table_name, max(s.index_name) AS index_name, max(s.index_type) AS index_type,
         sum(s.row_lock_waits)::bigint AS row_lock_waits, sum(s.row_lock_wait_ms)::bigint AS row_lock_wait_ms,
         sum(s.page_lock_waits)::bigint AS page_lock_waits, sum(s.page_lock_wait_ms)::bigint AS page_lock_wait_ms,
         sum(s.escalation_attempts)::bigint AS escalation_attempts, sum(s.escalations)::bigint AS escalations,
         count(*) AS intervals, max(s.snapshot_at) AS last_seen
    FROM pgvigil.mssql_indexlock_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)
   GROUP BY s.database_id, s.object_id, s.index_id
)
SELECT x.database_id, x.object_id, x.index_id, n.database, x.schema_name, coalesce(x.table_name, 'object ' || x.object_id) AS table_name,
       coalesce(x.index_name, CASE WHEN x.index_type = 'HEAP' OR x.index_id = 0 THEN '(heap)' ELSE 'index ' || x.index_id END) AS index_name,
       x.table_name IS NOT NULL AS named, x.index_type,
       x.row_lock_waits, x.row_lock_wait_ms, round(x.row_lock_wait_ms::numeric / nullif(x.row_lock_waits, 0), 1) AS avg_row_lock_wait_ms,
       x.page_lock_waits, x.page_lock_wait_ms, round(x.page_lock_wait_ms::numeric / nullif(x.page_lock_waits, 0), 1) AS avg_page_lock_wait_ms,
       x.row_lock_wait_ms + x.page_lock_wait_ms AS lock_wait_ms,
       x.escalation_attempts, x.escalations, x.intervals, x.last_seen
  FROM x JOIN dbn n ON n.database_id = x.database_id
 ORDER BY x.row_lock_wait_ms + x.page_lock_wait_ms DESC, x.escalations DESC, n.database, x.table_name NULLS LAST, x.index_id
 LIMIT 2000`

// sqlMSSQLIndexLockTotals: the window's sums over EVERY index ($4 one database's), whatever the grid's limit.
const sqlMSSQLIndexLockTotals = `
SELECT count(DISTINCT (s.database_id, s.object_id, s.index_id)) AS indexes,
       coalesce(sum(s.row_lock_waits), 0)::bigint AS row_lock_waits, coalesce(sum(s.row_lock_wait_ms), 0)::bigint AS row_lock_wait_ms,
       coalesce(sum(s.page_lock_waits), 0)::bigint AS page_lock_waits, coalesce(sum(s.page_lock_wait_ms), 0)::bigint AS page_lock_wait_ms,
       coalesce(sum(s.escalation_attempts), 0)::bigint AS escalation_attempts, coalesce(sum(s.escalations), 0)::bigint AS escalations
  FROM pgvigil.mssql_indexlock_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)`

// sqlMSSQLIndexLockSeries: the lock wait per step ($5 seconds) over the seconds the step's reads cover.
const sqlMSSQLIndexLockSeries = `
WITH secs AS (
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / $5) * $5) AS step, sum(r.interval_secs)::float8 AS secs
    FROM pgvigil.mssql_indexlock_read r
   WHERE r.instance_id = $1 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
   GROUP BY 1
), w AS (
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $5) * $5) AS step, sum(s.row_lock_wait_ms) AS row_ms,
         sum(s.page_lock_wait_ms) AS page_ms, sum(s.escalations) AS escalations
    FROM pgvigil.mssql_indexlock_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND ($4::int IS NULL OR s.database_id = $4)
   GROUP BY 1
)
SELECT c.step AS snapshot_at, round((coalesce(w.row_ms, 0) / c.secs)::numeric, 3) AS row_lock_ms_s,
       round((coalesce(w.page_ms, 0) / c.secs)::numeric, 3) AS page_lock_ms_s, coalesce(w.escalations, 0)::bigint AS escalations
  FROM secs c LEFT JOIN w ON w.step = c.step
 WHERE c.secs > 0
 ORDER BY 1`

// MSSQLIndexLocks is GET /api/mssql/indexlocks?instance=N[&from=&to=][&db=][&part=...].
func (s *Server) MSSQLIndexLocks(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	database, err := dbFilter(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_indexlocks"}}},
		{"reads", sqlMSSQLIndexLockReads, []any{id, from, to}},
		{"databases", sqlMSSQLIndexLockDatabases, []any{id, from, to}},
		{"totals", sqlMSSQLIndexLockTotals, []any{id, from, to, database}},
		{"indexes", sqlMSSQLIndexLocks, []any{id, from, to, database}},
		{"series", sqlMSSQLIndexLockSeries, []any{id, from, to, database, procStep(to.Sub(from).Seconds())}},
	})
}
