package web

import (
	"errors"
	"net/http"
	"strconv"
	"time"
)

// The Database info API (task 37; DBADash's Database tab). The routes are wired in Handler:
//   GET /api/dbinfo?instance=<id>[&db=<dbid>][&from=..&to=..] -> s.DBInfo: every database's facts, the tablespaces,
//       the size history of the largest databases and tables (db narrows the tables to one database).
//   GET /api/dbinfo/fleet -> s.DBInfoFleet: the fleet's databases and tables that grew the most over 7 and 30 days.
// Every part reads a 0046 read function, never a table.

// dbinfoMinWindow is the shortest span the size charts draw: the sizes are read hourly, so a shorter range would
// hold one or two points; the reply says which window it used (series_meta).
const dbinfoMinWindow = 7 * 24 * time.Hour

// dbinfoSeriesN is how many databases and tables the size charts carry.
const dbinfoSeriesN = 8

// optDBID reads the optional db=<dbid> (an oid: positive, at most 2^32-1).
func optDBID(r *http.Request) (*int64, error) {
	v := r.URL.Query().Get("db")
	if v == "" {
		return nil, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n <= 0 || n > 1<<32-1 {
		return nil, errors.New("db must be a database oid")
	}
	return &n, nil
}

// seriesWindow widens a window shorter than dbinfoMinWindow back from its end, and picks a bucket of about 300
// points, never finer than the hourly collection.
func seriesWindow(from, to time.Time) (time.Time, int) {
	if to.Sub(from) < dbinfoMinWindow {
		from = to.Add(-dbinfoMinWindow)
	}
	bucket := int(to.Sub(from).Seconds()) / 300
	if bucket < 3600 {
		bucket = 3600
	}
	return from, bucket
}

// DBInfo is one instance's Database info tab.
func (s *Server) DBInfo(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := optDBID(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	sfrom, bucket := seriesWindow(from, to)
	s.multiPart(w, r, []part{
		{"databases", `SELECT * FROM pgvigil.dbinfo($1)`, []any{id}},
		{"tablespaces", `SELECT * FROM pgvigil.dbinfo_tablespaces($1)`, []any{id}},
		{"db_series", `SELECT * FROM pgvigil.database_size_series($1, $2, $3, $4, $5)`, []any{id, sfrom, to, bucket, dbinfoSeriesN}},
		{"table_series", `SELECT * FROM pgvigil.table_size_series($1, $2, $3, $4, $5, $6)`, []any{id, db, sfrom, to, bucket, dbinfoSeriesN}},
		{"series_meta", `SELECT $1::timestamptz AS from_at, $2::timestamptz AS to_at, $3::int AS bucket_secs`, []any{sfrom, to, bucket}},
	})
}

// DBInfoFleet is the fleet's top growers.
func (s *Server) DBInfoFleet(w http.ResponseWriter, r *http.Request) {
	s.multi(w, r, []part{
		{"databases", `SELECT * FROM pgvigil.fleet_database_growers(50)`, nil},
		{"tables", `SELECT * FROM pgvigil.fleet_table_growers(50)`, nil},
	})
}
