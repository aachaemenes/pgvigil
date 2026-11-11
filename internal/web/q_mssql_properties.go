package web

import (
	"encoding/json"
	"net/http"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// The Properties tab of a SQL Server instance (task 130; DBA Dash's Info page) and what the Waits tab adds to its
// grid (DBA Dash's Waits: a wait's description and its rate per core).
//
//	GET /api/mssql/properties?instance=N[&part=...]   state (the mssql_properties collection's last run), properties
//	                                                   (one row per property as last read: group, label, value, note,
//	                                                   since when it has that value), changes (the values that differed
//	                                                   between two reads, newest first; 500 at most).
//	GET /api/mssql/waitinfo?instance=N[&from=&to=]    cores (the VISIBLE ONLINE schedulers of the newest mssql_cpu read
//	                                                   at or before the window's end), rates (per wait type of the
//	                                                   window: wait ms per second of the reads' covered time, and
//	                                                   that per scheduler), types (a wait type and what it means),
//	                                                   families (the start of a wait type's name and what such a wait
//	                                                   means, for a type without its own text).
//
// Both read only this slice's tables (0084), mssql_wait_sample, mssql_sched_sample and collection_dates.

const sqlMSSQLProperties = `
SELECT p.name, p.grp, p.label, p.value, p.note, p.ord, p.snapshot_at, p.since
  FROM pgvigil.mssql_property p
 WHERE p.instance_id = $1
 ORDER BY p.ord, p.name`

const sqlMSSQLPropertyChanges = `
SELECT c.changed_at, c.name, c.label, c.old_value, c.new_value
  FROM pgvigil.mssql_property_change c
 WHERE c.instance_id = $1
 ORDER BY c.changed_at DESC, c.change_id DESC
 LIMIT 500`

// MSSQLProperties is GET /api/mssql/properties?instance=N[&part=...]: the properties as last read; no window.
func (s *Server) MSSQLProperties(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_properties"}}},
		{"properties", sqlMSSQLProperties, []any{id}},
		{"changes", sqlMSSQLPropertyChanges, []any{id}},
	})
}

// sqlMSSQLWaitCores: the schedulers that run user work, as the newest mssql_cpu read at or before the window's end
// counted them (DBA Dash's Waits divides by the instance's scheduler count).
const sqlMSSQLWaitCores = `
SELECT s.schedulers, s.cpu_count, s.snapshot_at
  FROM pgvigil.mssql_sched_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at <= $3 AND $2::timestamptz < $3 AND s.schedulers > 0
 ORDER BY s.snapshot_at DESC
 LIMIT 1`

// sqlMSSQLWaitRates: per wait type of the window, its wait time over the seconds the window's reads cover (each
// read's own interval once: the Waits page's covered seconds) and that over the schedulers. No scheduler count
// (mssql_cpu never ran) leaves the per-core rate empty.
const sqlMSSQLWaitRates = `
WITH w AS (
  SELECT x.snapshot_at, x.wait_type, x.wait_ms, x.interval_secs
    FROM pgvigil.mssql_wait_sample x
   WHERE x.instance_id = $1 AND x.snapshot_at > $2 AND x.snapshot_at <= $3
), cover AS (
  SELECT coalesce(sum(r.interval_secs), 0)::float8 AS secs FROM (SELECT DISTINCT snapshot_at, interval_secs FROM w) r
), cores AS (
  SELECT (SELECT s.schedulers FROM pgvigil.mssql_sched_sample s
           WHERE s.instance_id = $1 AND s.snapshot_at <= $3 AND s.schedulers > 0
           ORDER BY s.snapshot_at DESC LIMIT 1) AS n
)
SELECT w.wait_type, sum(w.wait_ms)::bigint AS wait_ms, cover.secs AS covered_secs, cores.n AS schedulers,
       round((sum(w.wait_ms) / nullif(cover.secs, 0))::numeric, 3) AS ms_per_sec,
       round((sum(w.wait_ms) / nullif(cover.secs, 0) / cores.n)::numeric, 3) AS ms_per_sec_core
  FROM w CROSS JOIN cover CROSS JOIN cores
 GROUP BY w.wait_type, cover.secs, cores.n
 ORDER BY 2 DESC, 1
 LIMIT 2000`

// the descriptions ride to the repository as one jsonb argument each and come back as rows, like every other part
const (
	sqlMSSQLWaitTypes    = `SELECT t.key AS wait_type, t.value AS description FROM jsonb_each_text($1::jsonb) t ORDER BY t.key`
	sqlMSSQLWaitFamilies = `SELECT f.value->>'prefix' AS prefix, f.value->>'description' AS description
  FROM jsonb_array_elements($1::jsonb) WITH ORDINALITY f(value, n) ORDER BY f.n`
)

// waitInfoJSON is the collector package's wait descriptions as the two jsonb arguments.
func waitInfoJSON() (types, families string, err error) {
	t, err := json.Marshal(mssql.WaitDescriptions())
	if err != nil {
		return "", "", err
	}
	f, err := json.Marshal(mssql.WaitFamilies())
	if err != nil {
		return "", "", err
	}
	return string(t), string(f), nil
}

// MSSQLWaitInfo is GET /api/mssql/waitinfo?instance=N[&from=&to=][&part=...].
func (s *Server) MSSQLWaitInfo(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	types, families, err := waitInfoJSON()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	s.multiPart(w, r, []part{
		{"cores", sqlMSSQLWaitCores, []any{id, from, to}},
		{"rates", sqlMSSQLWaitRates, []any{id, from, to}},
		{"types", sqlMSSQLWaitTypes, []any{types}},
		{"families", sqlMSSQLWaitFamilies, []any{families}},
	})
}
