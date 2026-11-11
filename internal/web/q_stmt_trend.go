package web

import (
	"errors"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"time"
)

// A statement's trend under its row (parity2 task 121; Darling 13.8 shot 92's History): one row's figures per
// interval over the window, opened by a click on the Statements and Slow queries grids.
//
// GET /api/stmttrend?instance=<id>&[from=&to=]&(queryid=<n>[&db=<name>] | shape=<key>[&min=<ms>]) (Server.StmtTrend):
//   queryid  a pg_stat_statements row (statements_delta): calls, rows, total and mean time and the buffers (shared
//            hit / read, temp read / written) per interval, and the longest run of the same shape the server log
//            recorded in the interval (pgvigil.stmt_trend_detail, 0078; 0076's stmt_trend without the buffers)
//   shape    a slow-event shape of either engine (the slow capture on SQL Server, the server log on PostgreSQL):
//            events, failed, mean and longest duration, rows and mean CPU per interval (pgvigil.slow_trend)
//   meta     the interval in seconds and which source answered
//
// The interval is the window over about 72 points, a whole minute, at least one minute. The route is the lead's
// line in web.go.
//
// GET /api/stmtlag?instance=<id>&[from=&to=]&queryid=<n>[&db=<name>]&(lag=<secs> | at=<RFC3339>) (Server.StmtLag,
// parity3 task 125; pgwatch's Time Lag Comparison): one statement over the window, the same window one day earlier
// (the day-over-day row) and the window moved back by the chosen lag (1 h, 1 d, 7 d as 3600 / 86400 / 604800, or any
// lag up to 400 days) or to start at a chosen time (at: the lag is from - at). Each row carries the snapshots it read,
// so "no data" is told apart from "no calls" (pgvigil.stmt_lag). The route is the lead's line in web.go.

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
			{"trend", `SELECT * FROM pgvigil.stmt_trend_detail($1, $2, $3, $4, $5, $6)`, []any{id, n, db, from, to, secs}},
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

// maxLag is the furthest back a compare may look (the repository keeps 30 days by default; a longer retention
// is the operator's choice).
const maxLag = 400 * 24 * time.Hour

// queryidDB reads the statement of a request: its queryid and, optionally, its database.
func queryidDB(q map[string][]string) (int64, any, error) {
	get := func(k string) string {
		if v := q[k]; len(v) > 0 {
			return v[0]
		}
		return ""
	}
	n, err := strconv.ParseInt(get("queryid"), 10, 64)
	if err != nil {
		return 0, nil, errors.New("queryid must be a pg_stat_statements queryid (a 64-bit integer)")
	}
	var db any
	if v := get("db"); v != "" {
		if len(v) > 128 {
			return 0, nil, errors.New("db must be a database name of at most 128 characters")
		}
		db = v
	}
	return n, db, nil
}

// StmtLag serves one statement's chosen-lag compare beside the day-over-day one.
func (s *Server) StmtLag(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	n, db, err := queryidDB(q)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var lag time.Duration
	switch l, at := q.Get("lag"), q.Get("at"); {
	case l != "" && at != "":
		writeErr(w, http.StatusBadRequest, errors.New("lag and at do not go together"))
		return
	case l != "":
		secs, err := strconv.ParseInt(l, 10, 64)
		if err != nil || secs < 60 || secs > int64(maxLag/time.Second) { // compared in seconds: a huge value would overflow a Duration
			writeErr(w, http.StatusBadRequest, errors.New("lag must be whole seconds, 60 up to 400 days"))
			return
		}
		lag = time.Duration(secs) * time.Second
	case at != "":
		t, err := time.Parse(time.RFC3339, at)
		if err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("at must be an RFC 3339 time"))
			return
		}
		lag = from.Sub(t).Truncate(time.Second)
		if lag < time.Minute || lag > maxLag {
			writeErr(w, http.StatusBadRequest, errors.New("at must be at least a minute before the window's start and at most 400 days before it"))
			return
		}
	default:
		writeErr(w, http.StatusBadRequest, errors.New("lag (seconds) or at (a time) names the compared window"))
		return
	}
	lags := []float64{0, 86400, lag.Seconds()}
	s.multi(w, r, []part{
		{"lag", `SELECT * FROM pgvigil.stmt_lag($1, $2, $3, $4, $5, $6)`, []any{id, n, db, from, to, lags}},
	})
}
