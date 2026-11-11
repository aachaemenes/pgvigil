package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The fleet Table size page (task 132; DBA Dash's Table Size at the root of the tree). Route, wired in Handler:
//
//	GET /api/tablesize?[from=&to=][&top=20|50|100|500][&order=size|growth] -> s.TableSize
//
// tables: pgvigil.table_size_fleet over the window: the tables of every active PostgreSQL instance at its newest
// table read of the window, the largest (or the fastest growing) first, with the growth since the read at the
// window's start. meta: how many PostgreSQL instances there are and how many have a table read in the window, the
// newest read, and the SQL Server instances the page does not cover (the repository holds no table sizes of one).

// tableSizeTops are the row counts the page offers (DBA Dash's Top box).
var tableSizeTops = map[int]bool{20: true, 50: true, 100: true, 500: true}

const sqlTableSizeMeta = `
SELECT (SELECT count(*) FROM pgvigil.instances i WHERE i.is_active AND coalesce(i.engine, 'postgres') = 'postgres') AS pg_instances,
       (SELECT count(*) FROM pgvigil.instances i
         WHERE i.is_active AND coalesce(i.engine, 'postgres') = 'postgres'
           AND EXISTS (SELECT 1 FROM pgvigil.table_sizes s
                        WHERE s.instance_id = i.instance_id AND s.snapshot_at > $1 AND s.snapshot_at <= $2)) AS instances_read,
       (SELECT max(t.snapshot_at) FROM pgvigil.tables t JOIN pgvigil.instances i USING (instance_id)
         WHERE i.is_active AND t.snapshot_at <= $2) AS newest_read,
       (SELECT count(*) FROM pgvigil.instances i WHERE i.is_active AND i.engine = 'sqlserver') AS mssql_instances,
       $3::int AS top, $4::text AS "order", $1::timestamptz AS from_at, $2::timestamptz AS to_at`

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
	s.multi(w, r, []part{
		{"tables", `SELECT * FROM pgvigil.table_size_fleet($1, $2, $3, $4)`, []any{from, to, top, order}},
		{"meta", sqlTableSizeMeta, []any{from, to, top, order}},
	})
}
