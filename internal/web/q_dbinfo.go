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
// Every part reads a 0046 read function, never a table, with one exception: the side tree's `part=databases` (task 65) reads
// the four columns it shows from pgvigil.databases itself, in dbinfo()'s order, so a folder open does not pay for the
// page's growth aggregate and per-database reads (the join review of 0a46d48 measured the whole function per open).

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
	// the database size series alone (the Storage tab's days selector) reads up to a year; the page 31 days
	longest := maxWindow
	if r.URL.Query().Get("part") == "db_series" {
		longest = maxSeriesWindow
	}
	id, from, to, err := paramsMax(r, true, longest)
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
	dbSQL := `SELECT * FROM pgvigil.dbinfo($1)`
	if r.URL.Query().Get("part") == "databases" {
		// the side tree's folder: the columns it shows, in dbinfo()'s order, from the table alone
		dbSQL = `SELECT dbid, datname, is_present, is_template FROM pgvigil.databases
		          WHERE instance_id = $1 ORDER BY is_present DESC, is_template, size_bytes DESC NULLS LAST, datname`
	}
	s.multiPart(w, r, []part{
		{"databases", dbSQL, []any{id}},
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

// The busiest tables and the database changes (task 127; pgwatch's Tables Overview, DBA Dash's New Databases and
// Deleted Databases). Routes, wired in Handler:
//   GET /api/tables/top?instance=<id>[&from=..&to=..][&n=5..50] -> s.TablesTop: the top n tables by sequential scans,
//       inserts, updates and deletes over the window (pgvigil.table_activity_top; each row carries its four ranks),
//       the window cut to its last tablesTopMaxWindow (meta.from_at says where it starts).
//   GET /api/dbchanges[?instance=<id>][&days=1..366] -> s.DBChanges: the databases created and dropped in the last
//       days (default 30), both engines, newest first (pgvigil.database_changes); no instance = the fleet.

// tablesTopMaxWindow: table_activity_top orders every read of the window per table; 1,000 tables read every 5 minutes
// take about 3 s over 7 days and 25 s over 31 (past the pool's statement timeout), so a longer range is cut.
const tablesTopMaxWindow = 7 * 24 * time.Hour

// TablesTop is one instance's busiest tables over the window.
func (s *Server) TablesTop(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	n := 10
	if v := r.URL.Query().Get("n"); v != "" {
		if n, err = strconv.Atoi(v); err != nil || n < 1 || n > 50 {
			writeErr(w, http.StatusBadRequest, errors.New("n must be 1 to 50"))
			return
		}
	}
	if to.Sub(from) > tablesTopMaxWindow {
		from = to.Add(-tablesTopMaxWindow)
	}
	s.multi(w, r, []part{
		{"tables", `SELECT * FROM pgvigil.table_activity_top($1, $2, $3, $4)`, []any{id, from, to, n}},
		{"meta", `
SELECT $4::int AS n, $2::timestamptz AS from_at, $3::timestamptz AS to_at,
       (SELECT count(DISTINCT a.snapshot_at) FROM pgvigil.table_activity a
         WHERE a.instance_id = $1 AND a.snapshot_at > $2 AND a.snapshot_at <= $3) AS reads,
       (SELECT max(a.snapshot_at) FROM pgvigil.table_activity a
         WHERE a.instance_id = $1 AND a.snapshot_at <= $3 AND a.snapshot_at > $3 - interval '1 day') AS last_read`,
			[]any{id, from, to, n}},
	})
}

// DBChanges is the databases created and dropped in the last days, one instance's or the fleet's.
func (s *Server) DBChanges(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var inst *int
	if v := q.Get("instance"); v != "" {
		id, err := strconv.Atoi(v)
		if err != nil || id <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
			return
		}
		inst = &id
	}
	days := 30
	if v := q.Get("days"); v != "" {
		d, err := strconv.Atoi(v)
		if err != nil || d < 1 || d > 366 {
			writeErr(w, http.StatusBadRequest, errors.New("days must be 1 to 366"))
			return
		}
		days = d
	}
	s.multi(w, r, []part{
		{"changes", `SELECT * FROM pgvigil.database_changes($1, $2)`, []any{days, inst}},
		{"meta", `SELECT $1::int AS days`, []any{days}},
	})
}
