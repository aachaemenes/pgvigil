package web

// GET /api/vacuum/trend?instance=<id>&from=&to= - autovacuum over time (parity set 2, the sweep's L48: coroot's
// autovacuum workers against autovacuum_max_workers, dead tuples by table, autovacuum pressure). Everything is read
// from what the collector already stores (vacuum_sample, vacuum_state, table_sizes, tables); scripts/proof-pmrows.sh
// pins the answer and grades it against its own reading of those rows.
//   workers:  a point per minute sample the window holds (a vacuum_sample row of any kind - a minute with nothing
//             running stores no row), n its autovacuum workers (distinct pids with is_auto), max autovacuum_max_workers
//             as last read (its history is not kept: the words say so)
//   dead:     the 5 tables with the most dead tuples at the window's newest table_sizes read, named schema.table, a
//             point per read
//   pressure: per table_sizes read, the tables whose dead tuples are over autovacuum's trigger (vacuum_threshold +
//             vacuum_scale_factor x n_live_tup, capped by vacuum_max_threshold unless -1) with the instance's settings
//             as last read; a table's own autovacuum settings are not read (the words say so)

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

const sqlVacuumTrendWorkers = `
SELECT snapshot_at, count(DISTINCT pid) FILTER (WHERE is_auto) AS n
  FROM pgvigil.vacuum_sample
 WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3
 GROUP BY snapshot_at
 ORDER BY snapshot_at`

const sqlVacuumTrendSettings = `
SELECT snapshot_at, max_workers, vacuum_threshold, vacuum_scale_factor, vacuum_max_threshold
  FROM pgvigil.vacuum_state
 WHERE instance_id = $1`

const sqlVacuumTrendDead = `
WITH newest AS (
  SELECT max(snapshot_at) AS at FROM pgvigil.table_sizes WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3
), top AS (
  SELECT s.dbid, s.relid, t.schema_name || '.' || t.table_name AS name, s.n_dead_tup
    FROM pgvigil.table_sizes s
    JOIN newest n ON s.snapshot_at = n.at
    JOIN pgvigil.tables t ON t.instance_id = s.instance_id AND t.dbid = s.dbid AND t.relid = s.relid
   WHERE s.instance_id = $1
   ORDER BY s.n_dead_tup DESC NULLS LAST, name
   LIMIT 5
)
SELECT top.name, s.snapshot_at, s.n_dead_tup
  FROM top
  JOIN pgvigil.table_sizes s ON s.instance_id = $1 AND s.dbid = top.dbid AND s.relid = top.relid
                             AND s.snapshot_at >= $2 AND s.snapshot_at < $3
 ORDER BY top.n_dead_tup DESC NULLS LAST, top.name, s.snapshot_at`

// the trigger as autovacuum computes it from the instance's settings (vacuum_max_threshold: PG18+, -1 = no cap)
const sqlVacuumTrendPressure = `
SELECT s.snapshot_at,
       count(*) FILTER (WHERE s.n_dead_tup > least(v.vacuum_threshold + v.vacuum_scale_factor * s.n_live_tup,
                        CASE WHEN v.vacuum_max_threshold IS NULL OR v.vacuum_max_threshold = -1 THEN 'Infinity'::float8
                             ELSE v.vacuum_max_threshold END)) AS n
  FROM pgvigil.table_sizes s
  JOIN pgvigil.vacuum_state v ON v.instance_id = s.instance_id
 WHERE s.instance_id = $1 AND s.snapshot_at >= $2 AND s.snapshot_at < $3
   AND v.vacuum_threshold IS NOT NULL AND v.vacuum_scale_factor IS NOT NULL
 GROUP BY s.snapshot_at
 ORDER BY s.snapshot_at`

type vacTrendPoint struct {
	At  time.Time `json:"at"`
	N   int64     `json:"n"`
	Max *int32    `json:"max,omitempty"`
}
type vacTrendValue struct {
	At time.Time `json:"at"`
	V  *int64    `json:"v"`
}
type vacTrendTable struct {
	Table  string          `json:"table"`
	Points []vacTrendValue `json:"points"`
}
type vacTrend struct {
	Workers  []vacTrendPoint `json:"workers"`
	Dead     []vacTrendTable `json:"dead"`
	Pressure []vacTrendPoint `json:"pressure"`
	Words    []string        `json:"words"`
}

// VacuumTrend answers GET /api/vacuum/trend.
func (s *Server) VacuumTrend(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	v, err := s.vacuumTrend(r.Context(), id, from, to)
	s.reply(w, r, v, err)
}

func (s *Server) vacuumTrend(ctx context.Context, id int, from, to time.Time) (*vacTrend, error) {
	out := &vacTrend{Workers: []vacTrendPoint{}, Dead: []vacTrendTable{}, Pressure: []vacTrendPoint{}, Words: []string{}}
	// the settings as last read: autovacuum_max_workers for every worker point, the thresholds for the pressure
	var setAt *time.Time
	var maxW *int32
	var thr, sf, capT *float64
	err := s.pool.QueryRow(ctx, sqlVacuumTrendSettings, id).Scan(&setAt, &maxW, &thr, &sf, &capT)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		out.Words = append(out.Words, "No autovacuum settings are read for this instance yet: the workers are drawn without autovacuum_max_workers and there is no pressure line.")
	case err != nil:
		return nil, fmt.Errorf("vacuum settings: %w", err)
	case setAt != nil:
		out.Words = append(out.Words, fmt.Sprintf("autovacuum_max_workers as last read (%s): its history is not kept, so every point is drawn against the setting as it is now.", setAt.UTC().Format(time.RFC3339)))
	}
	rows, err := s.pool.Query(ctx, sqlVacuumTrendWorkers, id, from, to)
	if err != nil {
		return nil, fmt.Errorf("vacuum workers: %w", err)
	}
	for rows.Next() {
		p := vacTrendPoint{Max: maxW}
		if err := rows.Scan(&p.At, &p.N); err != nil {
			rows.Close()
			return nil, fmt.Errorf("vacuum workers: %w", err)
		}
		out.Workers = append(out.Workers, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("vacuum workers: %w", err)
	}
	out.Words = append(out.Words, "A minute with no vacuum running stores no row: such a minute has no point.")
	rows, err = s.pool.Query(ctx, sqlVacuumTrendDead, id, from, to)
	if err != nil {
		return nil, fmt.Errorf("dead tuples: %w", err)
	}
	for rows.Next() {
		var name string
		var p vacTrendValue
		if err := rows.Scan(&name, &p.At, &p.V); err != nil {
			rows.Close()
			return nil, fmt.Errorf("dead tuples: %w", err)
		}
		if n := len(out.Dead); n == 0 || out.Dead[n-1].Table != name {
			out.Dead = append(out.Dead, vacTrendTable{Table: name, Points: []vacTrendValue{}})
		}
		out.Dead[len(out.Dead)-1].Points = append(out.Dead[len(out.Dead)-1].Points, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("dead tuples: %w", err)
	}
	if thr != nil && sf != nil {
		rows, err = s.pool.Query(ctx, sqlVacuumTrendPressure, id, from, to)
		if err != nil {
			return nil, fmt.Errorf("autovacuum pressure: %w", err)
		}
		for rows.Next() {
			var p vacTrendPoint
			if err := rows.Scan(&p.At, &p.N); err != nil {
				rows.Close()
				return nil, fmt.Errorf("autovacuum pressure: %w", err)
			}
			out.Pressure = append(out.Pressure, p)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("autovacuum pressure: %w", err)
		}
		out.Words = append(out.Words, "The pressure line counts the tables whose dead tuples are past autovacuum's trigger with the instance's settings as last read; per-table settings (a table's own autovacuum_vacuum_threshold or scale factor) are not read.")
	}
	return out, nil
}
