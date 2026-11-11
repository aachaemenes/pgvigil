package web

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
)

// The fleet Table size page (task 132; DBA Dash's Table Size at the root of the tree). Route, wired in Handler:
//
//	GET /api/tablesize?[from=&to=][&top=20|50|100|500][&order=size|growth][&instances=<id>,<id>,...] -> s.TableSize
//
// tables: pgvigil.table_size_fleet over the window: the tables of every active PostgreSQL instance at its newest
// table read of the window, the largest (or the fastest growing) first, with the growth since the read at the
// window's start. meta: how many PostgreSQL instances there are and how many have a table read in the window, the
// newest read, and the SQL Server instances the page does not cover (the repository holds no table sizes of one).
// instances= narrows both parts to those instances (a tag folder of the tree): the top rows and the counts are then
// the folder's own.

// tableSizeTops are the row counts the page offers (DBA Dash's Top box).
var tableSizeTops = map[int]bool{20: true, 50: true, 100: true, 500: true}

// $5: the instances asked for, NULL = every one
const sqlTableSizeMeta = `
WITH i AS (
  SELECT x.instance_id, coalesce(x.engine, 'postgres') AS engine
    FROM pgvigil.instances x
   WHERE x.is_active AND ($5::int[] IS NULL OR x.instance_id = ANY ($5::int[]))
)
SELECT (SELECT count(*) FROM i WHERE i.engine = 'postgres') AS pg_instances,
       (SELECT count(*) FROM i
         WHERE i.engine = 'postgres'
           AND EXISTS (SELECT 1 FROM pgvigil.table_sizes s
                        WHERE s.instance_id = i.instance_id AND s.snapshot_at > $1 AND s.snapshot_at <= $2)) AS instances_read,
       (SELECT max(t.snapshot_at) FROM pgvigil.tables t JOIN i USING (instance_id) WHERE t.snapshot_at <= $2) AS newest_read,
       (SELECT count(*) FROM i WHERE i.engine = 'sqlserver') AS mssql_instances,
       $3::int AS top, $4::text AS "order", $1::timestamptz AS from_at, $2::timestamptz AS to_at,
       $5::int[] IS NOT NULL AS narrowed`

// tableSizeMaxInstances is the most instance ids one request may name.
const tableSizeMaxInstances = 2000

// TableSize serves the fleet's largest tables with their growth over the window.
func (s *Server) TableSize(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	top := 100
	if v := q.Get("top"); v != "" {
		if top, err = strconv.Atoi(v); err != nil || !tableSizeTops[top] {
			writeErr(w, http.StatusBadRequest, errors.New("top must be 20, 50, 100 or 500"))
			return
		}
	}
	order := q.Get("order")
	switch order {
	case "":
		order = "size"
	case "size", "growth":
	default:
		writeErr(w, http.StatusBadRequest, errors.New("order must be size or growth"))
		return
	}
	// the folder's instances: a list of ids, or none for the fleet (an empty folder asks with instances=0: no row)
	var ids []int32
	if v := q.Get("instances"); v != "" {
		for _, f := range strings.Split(v, ",") {
			n, err := strconv.ParseInt(strings.TrimSpace(f), 10, 32)
			if err != nil || n < 0 || len(ids) >= tableSizeMaxInstances {
				writeErr(w, http.StatusBadRequest, errors.New("instances must be instance ids separated by commas (2,000 at most)"))
				return
			}
			ids = append(ids, int32(n))
		}
	}
	s.multi(w, r, []part{
		{"tables", `SELECT * FROM pgvigil.table_size_fleet($1, $2, $3, $4, $5)`, []any{from, to, top, order, ids}},
		{"meta", sqlTableSizeMeta, []any{from, to, top, order, ids}},
	})
}
