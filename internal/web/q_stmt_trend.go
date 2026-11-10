package web

import (
	"errors"
	"math"
	"net/http"
	"regexp"
	"strconv"
)

// A statement's trend under its row (parity2 task 121; Darling 13.8 shot 92's History): one row's figures per
// interval over the window, opened by a click on the Statements and Slow queries grids.
//
// GET /api/stmttrend?instance=<id>&[from=&to=]&(queryid=<n>[&db=<name>] | shape=<key>[&min=<ms>]) (Server.StmtTrend):
//   queryid  a pg_stat_statements row (statements_delta): calls, rows, total and mean time per interval, and the
//            longest run of the same shape the server log recorded in the interval (pgvigil.stmt_trend, 0076)
//   shape    a slow-event shape of either engine (the slow capture on SQL Server, the server log on PostgreSQL):
//            events, failed, mean and longest duration, rows and mean CPU per interval (pgvigil.slow_trend)
//   meta     the interval in seconds and which source answered
//
// The interval is the window over about 72 points, a whole minute, at least one minute. The route is the lead's
// line in web.go.

// a shape key: md5 hex on PostgreSQL (0025), 16 hex digits of a SHA-256 on SQL Server (the XE shredder's hash16)
var trendShapeRE = regexp.MustCompile(`^(?:[0-9a-f]{16}|[0-9a-f]{32})$`)

// trendSecs: the window cut to about 72 intervals of whole minutes, at least one.
func trendSecs(spanSecs float64) int {
	m := math.Ceil(spanSecs / 72 / 60)
	return int(max(1, m)) * 60
}

// StmtTrend serves one statement's trend.
func (s *Server) StmtTrend(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	secs := trendSecs(to.Sub(from).Seconds())
	qid, shape := q.Get("queryid"), q.Get("shape")
	switch {
	case qid != "" && shape != "":
		writeErr(w, http.StatusBadRequest, errors.New("queryid and shape do not go together"))
	case qid != "":
		n, err := strconv.ParseInt(qid, 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("queryid must be a pg_stat_statements queryid (a 64-bit integer)"))
			return
		}
		var db any
		if v := q.Get("db"); v != "" {
			if len(v) > 128 {
				writeErr(w, http.StatusBadRequest, errors.New("db must be a database name of at most 128 characters"))
				return
			}
			db = v
		}
		s.multi(w, r, []part{
			{"meta", `SELECT $1::int AS secs, 'pg_stat_statements' AS source`, []any{secs}},
			{"trend", `SELECT * FROM pgvigil.stmt_trend($1, $2, $3, $4, $5, $6)`, []any{id, n, db, from, to, secs}},
		})
	case shape != "":
		if !trendShapeRE.MatchString(shape) {
			writeErr(w, http.StatusBadRequest, errors.New("shape must be a shape key (16 or 32 lower-case hex digits)"))
			return
		}
		minMS := 0
		if v := q.Get("min"); v != "" {
			if minMS, err = strconv.Atoi(v); err != nil || minMS < 0 || minMS > 86400000 {
				writeErr(w, http.StatusBadRequest, errors.New("min must be 0..86400000 milliseconds"))
				return
			}
		}
		s.multi(w, r, []part{
			{"meta", `SELECT $1::int AS secs, 'slow events' AS source`, []any{secs}},
			{"trend", `SELECT * FROM pgvigil.slow_trend($1, $2, $3, $4, $5, $6)`, []any{id, shape, from, to, secs, float64(minMS)}},
		})
	default:
		writeErr(w, http.StatusBadRequest, errors.New("queryid or shape names the statement"))
	}
}
