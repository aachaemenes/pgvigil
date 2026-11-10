package web

import (
	"errors"
	"net/http"
	"regexp"
	"strconv"
)

// The drill-down API (task 48; DBADash's per-object pages), every part a 0047 read function. The routes are wired
// in Handler:
//   GET /api/drill/db?instance=<id>&db=<dbid>[&from&to]                -> s.DrillDB
//   GET /api/drill/table?instance=<id>&db=<dbid>&rel=<relid>[&from&to] -> s.DrillTable
//   GET /api/drill/job?instance=<id>&scheduler=<s>&job=<id>[&from&to]  -> s.DrillJob
//   GET /api/drill/index?instance=<id>&db=<dbid>&idx=<indexrelid>      -> s.DrillIndex
// The time range bounds the statements, slow queries, vacuum runs and job runs; the size charts reach back at least
// seven days (seriesWindow, q_dbinfo.go).

// drillN is how many statements and slow shapes a drill page lists.
const drillN = 20

// oidParam reads a required oid parameter (positive, at most 2^32-1).
func oidParam(r *http.Request, name string) (int64, error) {
	n, err := strconv.ParseInt(r.URL.Query().Get(name), 10, 64)
	if err != nil || n <= 0 || n > 1<<32-1 {
		return 0, errors.New(name + " must be an oid")
	}
	return n, nil
}

// DrillDB is the database page: its facts, size history, tables, extensions, ACLs, jobs, slow queries and statements.
func (s *Server) DrillDB(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := oidParam(r, "db")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	sfrom, bucket := seriesWindow(from, to)
	s.multiPart(w, r, []part{
		{"facts", `SELECT * FROM pgvigil.dbinfo($1, $2)`, []any{id, db}},
		{"series", `SELECT * FROM pgvigil.drill_db_series($1, $2, $3, $4, $5)`, []any{id, db, sfrom, to, bucket}},
		{"tables", `SELECT * FROM pgvigil.drill_db_tables($1, $2)`, []any{id, db}},
		{"extensions", `SELECT * FROM pgvigil.drill_db_extensions($1, $2)`, []any{id, db}},
		{"acl", `SELECT * FROM pgvigil.drill_db_acl($1, $2)`, []any{id, db}},
		{"jobs", `SELECT scheduler, job_id, job_name, schedule, active, next_run, last_status, last_start, last_duration_secs, last_running,
       runs_7d, failures_7d, fail_streak, missed, over_average FROM pgvigil.drill_db_jobs($1, $2)`, []any{id, db}},
		{"slow", `SELECT * FROM pgvigil.drill_db_slow($1, $2, $3, $4, $5)`, []any{id, db, from, to, drillN}},
		{"statements", `SELECT * FROM pgvigil.drill_statements($1, $2, $3, $4, $5)`, []any{id, db, from, to, drillN}},
		{"series_meta", `SELECT $1::timestamptz AS from_at, $2::timestamptz AS to_at, $3::int AS bucket_secs`, []any{sfrom, to, bucket}},
	})
}

// DrillTable is the table page: its row, size and row history, vacuum and analyze runs, checks, indexes and the
// statements that name it.
func (s *Server) DrillTable(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := oidParam(r, "db")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	rel, err := oidParam(r, "rel")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	sfrom, bucket := seriesWindow(from, to)
	s.multi(w, r, []part{
		{"table", `SELECT * FROM pgvigil.drill_table($1, $2, $3)`, []any{id, db, rel}},
		{"series", `SELECT * FROM pgvigil.drill_table_series($1, $2, $3, $4, $5, $6)`, []any{id, db, rel, sfrom, to, bucket}},
		{"vacuum", `SELECT * FROM pgvigil.drill_table_vacuum($1, $2, $3, $4, $5)`, []any{id, db, rel, from, to}},
		{"checks", `SELECT * FROM pgvigil.drill_table_checks($1, $2, $3)`, []any{id, db, rel}},
		{"indexes", `SELECT * FROM pgvigil.drill_table_indexes($1, $2, $3)`, []any{id, db, rel}},
		{"statements", `SELECT * FROM pgvigil.drill_table_statements($1, $2, $3, $4, $5, $6)`, []any{id, db, rel, from, to, drillN}},
		{"series_meta", `SELECT $1::timestamptz AS from_at, $2::timestamptz AS to_at, $3::int AS bucket_secs`, []any{sfrom, to, bucket}},
	})
}

// schedulerRe is the scheduler names the jobs collection writes (pg_cron, pgagent, and room for another plain name).
var schedulerRe = regexp.MustCompile(`^[a-z_]{1,32}$`)

// DrillJob is the job page: its report row (command, schedule, next run, the 7- and 30-day figures) and its runs.
func (s *Server) DrillJob(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	sched := r.URL.Query().Get("scheduler")
	if !schedulerRe.MatchString(sched) {
		writeErr(w, http.StatusBadRequest, errors.New("scheduler must be a scheduler name (pg_cron, pgagent)"))
		return
	}
	job, err := strconv.ParseInt(r.URL.Query().Get("job"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, errors.New("job must be a job id"))
		return
	}
	s.multi(w, r, []part{
		{"job", `SELECT * FROM pgvigil.drill_job($1, $2, $3)`, []any{id, sched, job}},
		{"runs", `SELECT * FROM pgvigil.drill_job_runs($1, $2, $3, $4, $5)`, []any{id, sched, job, from, to}},
	})
}

// DrillIndex is the index page: its definition, size and usage, each problem the indexes collection found with the
// finding's text, and the DROP and undo lines as text (pgvigil never runs them).
func (s *Server) DrillIndex(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := oidParam(r, "db")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	idx, err := oidParam(r, "idx")
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"index", `SELECT * FROM pgvigil.drill_index($1, $2, $3)`, []any{id, db, idx}},
	})
}
