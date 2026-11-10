package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The Compare tab of the Statements page (task 57; DBADash's Object Execution Compare, pg_profile's differential
// report): GET /api/compare?instance=<id>&[from=&to=]&[limit=<n>] (Server.Compare) is the window's statements against
// the same window one day and seven days earlier (pgvigil.statement_compare, 0054), with the three windows and whether
// each baseline was read at all; GET /api/compare?instance=<id>&[from=&to=]&queryid=<id> is one statement's history over
// the window and the seven days before it (pgvigil.statement_history), the row the grid opens. No Summary column: the
// regressions reach the Findings through compare_findings.

// sqlCompareWindows: the window and its two baselines, each with 'ok' or 'no baseline'.
const sqlCompareWindows = `
SELECT w.label, w.f AS from_at, w.t AS to_at, pgvigil.statement_baseline($1, w.f, w.t) AS status
  FROM (VALUES ('window', $2::timestamptz, $3::timestamptz),
               ('1 day earlier', $2::timestamptz - interval '1 day', $3::timestamptz - interval '1 day'),
               ('7 days earlier', $2::timestamptz - interval '7 days', $3::timestamptz - interval '7 days')) w(label, f, t)`

const sqlCompareRows = `SELECT * FROM pgvigil.statement_compare($1, $2, $3, $4)`

const sqlCompareHistory = `SELECT * FROM pgvigil.statement_history($1, $2, $3, $4)`

// Compare serves the Compare tab of one instance, or one statement's history with ?queryid=.
func (s *Server) Compare(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	if v := q.Get("queryid"); v != "" {
		qid, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("queryid must be a pg_stat_statements queryid (a 64-bit integer)"))
			return
		}
		s.multi(w, r, []part{{"history", sqlCompareHistory, []any{id, qid, from, to}}})
		return
	}
	limit := 200
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > 1000 {
			writeErr(w, http.StatusBadRequest, errors.New("limit must be 1..1000"))
			return
		}
	}
	s.multi(w, r, []part{
		{"windows", sqlCompareWindows, []any{id, from, to}},
		{"rows", sqlCompareRows, []any{id, from, to, limit}},
	})
}
