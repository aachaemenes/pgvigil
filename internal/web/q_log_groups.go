package web

import (
	"errors"
	"net/http"
	"regexp"

	"github.com/aachaemenes/pgvigil/internal/logparse"
)

// The server log's events grouped by message (parity3 task 126; pgBadger's Events tab, Most Frequent Errors/Events,
// and its Temp Files tab's largest files): what pgvigil's two log readers stored for one instance over the window.
//
// GET /api/logs/groups?instance=<id>&[from=&to=]&[level=LOG|WARNING|ERROR|FATAL|PANIC] (Server.LogGroups):
//
//	groups      one row per kind, level and message shape (the most events first, at most 500): group_key, kind,
//	            level, message, stored (false: read before 0079, the shape taken from the stored detail, or none),
//	            events, first_at, last_at, databases, users
//	totals      events, groups, max_per_group (pgBadger's key values)
//	levels      the grouped events per level
//	temp_files  the largest single temporary files the log recorded (log_temp_files): time, size, path, database,
//	            user, client, pid and the statement where the log has it, the largest first (at most 50)
//	temp_total  files, bytes and the largest, over the window
//
// GET /api/logs/groups/rows?<the same>&key=<group_key> (Server.LogGroupRows): the raw events of one group, newest
// first (at most 200), and the group's count.
//
// Slow statements, auto_explain plans, checkpoint lines and temp files are not grouped here: the Slow queries page,
// the plans, the IO page's checkpoints and the temp file list above carry them. The routes are the lead's lines in
// web.go.

// logGroupMessageKinds are the kinds whose stored detail starts with the server's own message: a row of such a kind
// read before 0079 stored a shape is grouped by the shape of its detail's first line.
var logGroupMessageKinds = func() []string {
	out := []string{string(logparse.AuthFail)}
	for _, k := range logparse.AllKinds() {
		if logparse.DetailIsMessage(k) {
			out = append(out, string(k))
		}
	}
	return out
}()

// sqlLogGroupBase: the grouped events of the window; $1 instance, $2 from, $3 to, $4 the message kinds, $5 a level
// (NULL = every level). A row read before 0079 has no level: the kinds that are logged at one level only take it.
const sqlLogGroupBase = `
WITH e AS (
  SELECT e.snapshot_at, e.kind, e.pid, e.client, e.usename, e.datname, e.statement, e.detail, e.source, e.duration_ms,
         coalesce(e.level, CASE WHEN e.kind IN ('lock_wait', 'checkpoint_frequent') THEN 'LOG'
                                WHEN e.kind IN ('deadlock', 'serialization_failure', 'timeout', 'canceled') THEN 'ERROR'
                                WHEN e.kind = 'auth_fail' THEN 'FATAL' END) AS lvl,
         coalesce(e.message, CASE WHEN e.kind = 'deadlock' THEN 'deadlock detected'
                                  WHEN e.kind = ANY($4::text[]) AND e.detail IS NOT NULL
                                  THEN pgvigil.log_message_shape(split_part(e.detail, E'\n', 1)) END) AS msg,
         e.message IS NOT NULL AS stored
    FROM pgvigil.log_events e
   WHERE e.instance_id = $1 AND e.snapshot_at > $2 AND e.snapshot_at <= $3
     AND e.kind NOT IN ('slow', 'plan', 'checkpoint', 'temp_file')
),
g AS (
  SELECT e.*, md5(e.kind || '|' || coalesce(e.lvl, '') || '|' || coalesce(e.msg, '')) AS group_key
    FROM e
   WHERE $5::text IS NULL OR e.lvl = $5
)`

const sqlLogGroups = sqlLogGroupBase + `
SELECT g.group_key, g.kind, g.lvl AS level, g.msg AS message, bool_and(g.stored) AS stored, count(*) AS events,
       min(g.snapshot_at) AS first_at, max(g.snapshot_at) AS last_at,
       left(string_agg(DISTINCT g.datname, ', '), 200) AS databases, left(string_agg(DISTINCT g.usename, ', '), 200) AS users
  FROM g
 GROUP BY g.group_key, g.kind, g.lvl, g.msg
 ORDER BY count(*) DESC, max(g.snapshot_at) DESC
 LIMIT 500`

const sqlLogGroupTotals = sqlLogGroupBase + `
SELECT count(*) AS events, count(DISTINCT g.group_key) AS groups,
       (SELECT max(n) FROM (SELECT count(*) AS n FROM g GROUP BY g.group_key) x) AS max_per_group
  FROM g`

const sqlLogGroupLevels = sqlLogGroupBase + `
SELECT coalesce(g.lvl, 'unknown') AS level, count(*) AS events
  FROM g
 GROUP BY 1
 ORDER BY CASE coalesce(g.lvl, 'unknown') WHEN 'PANIC' THEN 1 WHEN 'FATAL' THEN 2 WHEN 'ERROR' THEN 3 WHEN 'WARNING' THEN 4 WHEN 'LOG' THEN 5 ELSE 6 END`

// $6 the group's key
const sqlLogGroupRows = sqlLogGroupBase + `
SELECT g.snapshot_at AS at, g.kind, g.lvl AS level, g.pid, g.datname, g.usename, g.client, g.duration_ms,
       left(g.detail, 2000) AS detail, left(g.statement, 2000) AS statement, g.source
  FROM g
 WHERE g.group_key = $6
 ORDER BY g.snapshot_at DESC
 LIMIT 200`

const sqlLogGroupRowCount = sqlLogGroupBase + `
SELECT count(*) AS matched, least(count(*), 200) AS shown FROM g WHERE g.group_key = $6`

// sqlLogTempFiles: the largest single temporary files of the window ($1 instance, $2 from, $3 to); the size and the
// path are the server's own line ('temporary file: path "...", size N').
const sqlLogTempFiles = `
SELECT * FROM (
  SELECT e.snapshot_at AS at, (substring(e.detail FROM 'size (\d+)'))::bigint AS size_bytes,
         substring(e.detail FROM 'path "([^"]+)"') AS path, e.datname, e.usename, e.client, e.pid,
         left(e.statement, 2000) AS statement
    FROM pgvigil.log_events e
   WHERE e.instance_id = $1 AND e.snapshot_at > $2 AND e.snapshot_at <= $3 AND e.kind = 'temp_file') t
 ORDER BY t.size_bytes DESC NULLS LAST, t.at DESC
 LIMIT 50`

const sqlLogTempTotal = `
SELECT count(*) AS files, sum((substring(e.detail FROM 'size (\d+)'))::bigint) AS bytes,
       max((substring(e.detail FROM 'size (\d+)'))::bigint) AS largest
  FROM pgvigil.log_events e
 WHERE e.instance_id = $1 AND e.snapshot_at > $2 AND e.snapshot_at <= $3 AND e.kind = 'temp_file'`

var logLevels = map[string]bool{"LOG": true, "WARNING": true, "ERROR": true, "FATAL": true, "PANIC": true}

var groupKeyRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

// logGroupArgs reads the shared parameters: the instance, the window and the level.
func logGroupArgs(r *http.Request) ([]any, error) {
	id, from, to, err := params(r, true)
	if err != nil {
		return nil, err
	}
	var level any
	if v := r.URL.Query().Get("level"); v != "" {
		if !logLevels[v] {
			return nil, errors.New("level must be one of LOG, WARNING, ERROR, FATAL, PANIC")
		}
		level = v
	}
	return []any{id, from, to, logGroupMessageKinds, level}, nil
}

// LogGroups serves the Logs page's grouped view.
func (s *Server) LogGroups(w http.ResponseWriter, r *http.Request) {
	args, err := logGroupArgs(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	win := args[:3]
	s.multi(w, r, []part{
		{"groups", sqlLogGroups, args},
		{"totals", sqlLogGroupTotals, args},
		{"levels", sqlLogGroupLevels, args},
		{"temp_files", sqlLogTempFiles, win},
		{"temp_total", sqlLogTempTotal, win},
	})
}

// LogGroupRows serves the raw events of one group.
func (s *Server) LogGroupRows(w http.ResponseWriter, r *http.Request) {
	args, err := logGroupArgs(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	key := r.URL.Query().Get("key")
	if !groupKeyRE.MatchString(key) {
		writeErr(w, http.StatusBadRequest, errors.New("key must be a group_key (32 hex characters)"))
		return
	}
	args = append(args, key)
	s.multi(w, r, []part{
		{"events", sqlLogGroupRows, args},
		{"meta", sqlLogGroupRowCount, args},
	})
}
