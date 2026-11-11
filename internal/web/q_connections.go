package web

import (
	"errors"
	"math"
	"net/http"
	"strings"
)

// The connection sources and the tile wall (task 127; pghero's Connections, pgwatch's Health Check). Routes, wired in
// Handler:
//   GET /api/connections?instance=<id>[&from=..&to=..][&by=application,user,database,client][&chart=<dimension>]
//       -> s.Connections: one row per source over the window (pgvigil.conn_sources_window), the newest read's
//          total against max_connections, and the window's reads. With chart= (one of the four dimensions, task 132)
//          the reply gains series (pgvigil.conn_sources_series: per bucket and source the average connections per
//          read, the eight largest sources by name and the rest as one) and series_meta (the dimension, the bucket
//          width, the series cap).
//   GET /api/tiles?instance=<id>[&from=..&to=..] -> s.Tiles: the instance's tile wall (pgvigil.instance_tiles).

// connDims are the dimensions a source groups by, in the order the page shows them.
var connDims = []string{"application", "user", "database", "client"}

// connBy reads by=, a comma list of connDims; none = all four. An unknown name is refused.
func connBy(r *http.Request) ([]string, error) {
	v := r.URL.Query().Get("by")
	if v == "" {
		return connDims, nil
	}
	var out []string
	seen := map[string]bool{}
	for _, d := range strings.Split(v, ",") {
		d = strings.TrimSpace(d)
		ok := false
		for _, k := range connDims {
			ok = ok || d == k
		}
		if !ok {
			return nil, errors.New("by must name application, user, database or client")
		}
		if !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	return out, nil
}

// connSeriesTop is the number of sources the chart names; the rest are one series (the palette has eight colours and
// the ninth series takes the neutral).
const connSeriesTop = 8

// connStep is the chart's bucket width in seconds: about 300 buckets over the window, a whole number of minutes,
// never under the collection's one minute.
func connStep(windowSecs float64) int {
	step := int(math.Ceil(windowSecs/300/60)) * 60
	if step < 60 {
		step = 60
	}
	return step
}

// Connections is one instance's connection sources over the window.
func (s *Server) Connections(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	by, err := connBy(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	parts := []part{
		{"sources", `SELECT * FROM pgvigil.conn_sources_window($1, $2, $3, $4)`, []any{id, from, to, by}},
		{"meta", `
SELECT $4::text[] AS by,
       (SELECT count(DISTINCT c.snapshot_at) FROM pgvigil.conn_sources c
         WHERE c.instance_id = $1 AND c.snapshot_at > $2 AND c.snapshot_at <= $3) AS reads,
       (SELECT max(c.snapshot_at) FROM pgvigil.conn_sources c
         WHERE c.instance_id = $1 AND c.snapshot_at > $2 AND c.snapshot_at <= $3) AS last_read,
       (SELECT a.max_connections FROM pgvigil.activity_summary a
         WHERE a.instance_id = $1 AND a.snapshot_at <= $3 ORDER BY a.snapshot_at DESC LIMIT 1) AS max_connections`,
			[]any{id, from, to, by}},
	}
	if dim := r.URL.Query().Get("chart"); dim != "" {
		ok := false
		for _, k := range connDims {
			ok = ok || dim == k
		}
		if !ok {
			writeErr(w, http.StatusBadRequest, errors.New("chart must name application, user, database or client"))
			return
		}
		step := connStep(to.Sub(from).Seconds())
		parts = append(parts,
			part{"series", `
SELECT bucket AS snapshot_at, source, folded, conns, reads, peak, avg_conns, sources, rank
  FROM pgvigil.conn_sources_series($1, $2, $3, $4, $5, $6)`, []any{id, from, to, dim, step, connSeriesTop}},
			part{"series_meta", `SELECT $1::text AS dim, $2::int AS step_secs, $3::int AS top`, []any{dim, step, connSeriesTop}})
	}
	s.multi(w, r, parts)
}

// Tiles is one instance's tile wall at the end of the window.
func (s *Server) Tiles(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"tiles", `SELECT * FROM pgvigil.instance_tiles($1, $2, $3)`, []any{id, from, to}},
	})
}
