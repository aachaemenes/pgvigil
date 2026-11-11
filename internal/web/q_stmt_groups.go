package web

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

// Statements drilled (parity3 task 125; PMM QAN shots 20-21): a checkbox filter panel over database, user and client
// host with each value's share, and a GROUP BY switch over the same three (or by statement).
//
// GET /api/stmtgroups?instance=<id>&[from=&to=]&[group=query|db|user|client]&[db=<name>]...&[user=<name>]...
//     &[client=<host>]...&[limit=<n>] (Server.StmtGroups):
//   facets  each value of each dimension with its statements, calls, total time and share of the dimension's total,
//           over the rows the other two dimensions' ticks leave, and whether it is ticked (pgvigil.stmt_facets, 0078)
//   groups  the ticked rows grouped, each with its share of the filtered total and of the instance's whole total
//           (pgvigil.stmt_groups)
//   totals  the instance's whole total in the window, the filtered total, and the sampled share of the client split
// A repeated db / user / client parameter ticks several values; client=(not sampled) ticks the statements no running-
// queries sample saw. The route is the lead's line in web.go.

var stmtGroupKinds = map[string]bool{"query": true, "db": true, "user": true, "client": true}

// maxTicks bounds each dimension's ticked values; a value is a database, user or host name.
const (
	maxTicks    = 100
	maxTickName = 255
)

// tickList reads a repeated parameter: nil when absent (every value), else its distinct values.
func tickList(q map[string][]string, name string) ([]string, error) {
	vs, ok := q[name]
	if !ok || len(vs) == 0 {
		return nil, nil
	}
	if len(vs) > maxTicks {
		return nil, fmt.Errorf("%s: at most %d values", name, maxTicks)
	}
	seen := map[string]bool{}
	out := []string{}
	for _, v := range vs {
		if len(v) > maxTickName || strings.ContainsRune(v, 0) {
			return nil, fmt.Errorf("%s: a value is longer than %d characters or holds a NUL", name, maxTickName)
		}
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out, nil
}

// StmtGroups serves the Statements page's filter panel and its grouped grid.
func (s *Server) StmtGroups(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	group := q.Get("group")
	if group == "" {
		group = "query"
	}
	if !stmtGroupKinds[group] {
		writeErr(w, http.StatusBadRequest, errors.New("group must be query, db, user or client"))
		return
	}
	limit := 100
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > 1000 {
			writeErr(w, http.StatusBadRequest, errors.New("limit must be 1..1000"))
			return
		}
	}
	var ticks [3][]string
	for i, name := range []string{"db", "user", "client"} {
		if ticks[i], err = tickList(q, name); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
	}
	// a nil slice is SQL NULL (no tick: every value)
	arr := func(v []string) any {
		if v == nil {
			return nil
		}
		return v
	}
	dbs, users, clients := arr(ticks[0]), arr(ticks[1]), arr(ticks[2])
	s.multi(w, r, []part{
		{"facets", `SELECT * FROM pgvigil.stmt_facets($1, $2, $3, $4, $5, $6)`, []any{id, from, to, dbs, users, clients}},
		{"groups", `SELECT * FROM pgvigil.stmt_groups($1, $2, $3, $4, $5, $6, $7, $8)`, []any{id, from, to, group, dbs, users, clients, limit}},
		{"totals", `SELECT sum(r.total_ms) AS total_ms,
		                   sum(r.total_ms) FILTER (WHERE ($4::text[] IS NULL OR r.datname = ANY ($4))
		                                             AND ($5::text[] IS NULL OR r.usename = ANY ($5))
		                                             AND ($6::text[] IS NULL OR pgvigil.stmt_client_label(r.client) = ANY ($6))) AS filtered_ms,
		                   round((100 * sum(r.total_ms) FILTER (WHERE r.client IS NOT NULL) / nullif(sum(r.total_ms), 0))::numeric, 1) AS sampled_pct,
		                   count(DISTINCT r.queryid) AS statements
		              FROM pgvigil.stmt_window_rows($1, $2, $3) r`, []any{id, from, to, dbs, users, clients}},
	})
}
