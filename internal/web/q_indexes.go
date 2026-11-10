package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/advisor"
)

// The Indexes tab (task 41): GET /api/indexes?[instance=<id>] (Server.Indexes): with instance, its databases and the
// unused, redundant, duplicate and invalid indexes the hourly indexes collection found, each with its DROP line and
// undo as text; without, the fleet root (per instance the counts and the bytes). POST /api/indexes/advise
// (Server.IndexAdvisor) runs the index advisor (internal/advisor) on one database of one instance: behind the UI
// login, with the X-Pgvigil header, through the instance's monitoring login (never the actions login: it writes
// nothing), refused where the actions door is off (the demo serve has no login). The overview check feeds the
// Summary column Indexes (check_group 'indexes'): the invalid and duplicate indexes.

func init() {
	overviewChecks = append(overviewChecks, struct{ name, sql string }{"indexes", `
SELECT f.instance_id, f.severity, f.setting, f.value, f.at, f.detail
  FROM pgvigil.index_findings f
 WHERE f.severity IN ('warning', 'critical')`})
}

const sqlIndexesState = `
SELECT c.status, c.note, c.snapshot_at
  FROM pgvigil.collection_dates c
 WHERE c.instance_id = $1 AND c.collection = 'indexes'`

const sqlIndexesDatabases = `
SELECT d.dbid, d.datname, d.indexes, d.index_bytes, d.stats_since, d.is_replica, d.snapshot_at,
       (SELECT count(*) FROM pgvigil.index_state s WHERE s.instance_id = d.instance_id AND s.dbid = d.dbid AND s.is_present) AS findings
  FROM pgvigil.index_databases d
 WHERE d.instance_id = $1 AND d.is_present
 ORDER BY d.datname`

const sqlIndexesList = `
SELECT s.datname, s.problem, s.schema_name, s.table_name, s.index_name, s.access_method, s.index_bytes, s.table_bytes,
       s.idx_scan, s.covered_by, s.covered_by_def, s.index_def, s.supports_fk, s.drop_sql, s.undo_sql, s.first_seen, s.snapshot_at
  FROM pgvigil.index_state s
 WHERE s.instance_id = $1 AND s.is_present
 ORDER BY CASE s.problem WHEN 'invalid' THEN 0 WHEN 'duplicate' THEN 1 WHEN 'redundant' THEN 2 ELSE 3 END,
          s.index_bytes DESC NULLS LAST, s.datname, s.schema_name, s.index_name`

const sqlIndexesFindings = `
SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at
  FROM pgvigil.index_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.setting, f.value`

const sqlIndexesFleet = `
SELECT i.instance_id, i.name AS instance, i.platform,
       count(*) FILTER (WHERE s.problem = 'invalid') AS invalid,
       count(*) FILTER (WHERE s.problem = 'duplicate') AS duplicate,
       count(*) FILTER (WHERE s.problem = 'redundant') AS redundant,
       count(*) FILTER (WHERE s.problem = 'unused') AS unused,
       coalesce(sum(s.index_bytes) FILTER (WHERE s.problem IN ('duplicate', 'redundant', 'unused', 'invalid')), 0) AS bytes,
       (SELECT max(d.snapshot_at) FROM pgvigil.index_databases d WHERE d.instance_id = i.instance_id) AS snapshot_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.index_state s ON s.instance_id = i.instance_id AND s.is_present
 WHERE i.is_active AND EXISTS (SELECT 1 FROM pgvigil.index_databases d WHERE d.instance_id = i.instance_id)
 GROUP BY i.instance_id, i.name, i.platform
 ORDER BY i.name`

// Indexes serves /api/indexes.
func (s *Server) Indexes(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("instance") == "" {
		s.multi(w, r, []part{{"fleet", sqlIndexesFleet, nil}})
		return
	}
	id, err := strconv.Atoi(q.Get("instance"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
		return
	}
	s.multi(w, r, []part{
		{"state", sqlIndexesState, []any{id}},
		{"databases", sqlIndexesDatabases, []any{id}},
		{"indexes", sqlIndexesList, []any{id}},
		{"findings", sqlIndexesFindings, []any{id}},
	})
}

// dbNameRE bounds the database a caller may name (a catalog name, at most 63 bytes).
var dbNameRE = regexp.MustCompile(`^[^\x00]{1,63}$`)

// runAdvisor is the advisor call, a variable so the handler's tests can stand in for a server.
var runAdvisor = advisor.Run

// IndexAdvisor serves POST /api/indexes/advise {instance_id, database}.
func (s *Server) IndexAdvisor(w http.ResponseWriter, r *http.Request) {
	a := s.actions
	switch {
	case a == nil:
		writeErr(w, http.StatusForbidden, errors.New("the index advisor needs the actions door, which is off on this server"))
		return
	case r.Header.Get(loginHeader) == "":
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	case a.off != "":
		writeErr(w, http.StatusForbidden, errors.New("the index advisor is off: "+a.off))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	var in struct {
		InstanceID int    `json:"instance_id"`
		Database   string `json:"database"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	if in.InstanceID <= 0 || !dbNameRE.MatchString(in.Database) {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id and database are required"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	var name string
	if err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, in.InstanceID).Scan(&name); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", in.InstanceID))
		return
	}
	door, ok := a.doors[name]
	if !ok || strings.TrimSpace(door.Monitor) == "" {
		writeErr(w, http.StatusConflict, fmt.Errorf("instance %s is not in this server's configuration", name))
		return
	}
	rep, err := runAdvisor(ctx, door.Monitor, in.Database, advisor.Options{})
	s.log.Info("index advisor", "instance", name, "database", in.Database, "user", user, "suggestions", len(rep.Suggestions),
		"skipped", rep.Skipped, "err", err)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(rep)
}
