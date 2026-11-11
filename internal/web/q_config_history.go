package web

// Job scripts and configuration history in DBA Dash's shape (task 154; migration 0094). Every read here is one
// function of 0094; this file is the HTTP side only.
//
//	GET  /api/config/changes[?instance=N]    changes: pgvigil.config_change_log - every setting change with the old
//	                                         value's valid from / to, both engines; without instance, the fleet's
//	GET  /api/mssql/config/fleet             pivot: pgvigil.mssql_config_pivot - sys.configurations of every active
//	                                         SQL Server instance, a row per instance and option, the odd value marked
//	GET  /api/mssql/traceflags[?instance=N]  flags, history, read: the trace flags on, each flag's added / removed
//	                                         history and the last read
//	GET  /api/jobs/thresholds?instance=N     levels: the live thresholds at the root, the instance and its jobs;
//	                                         status: every job judged against the row in force; writable, reason
//	POST /api/jobs/thresholds                {op: set | inherit, level, instance_id, job_name, <thresholds>}: one
//	                                         attempt through pgvigil.import_job_threshold, the way of q_ack.go (the UI
//	                                         login, the X-Pgvigil header, the actions door's audit pool)
//
// The job's script rides on /api/jobs/history's changes part (q_jobs_history.go: v.script).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// optInstance is ?instance= as an id, nil when it is not given.
func optInstance(r *http.Request) (*int, error) {
	v := r.URL.Query().Get("instance")
	if v == "" {
		return nil, nil
	}
	id, err := strconv.Atoi(v)
	if err != nil || id <= 0 {
		return nil, errors.New("instance must be a positive instance_id")
	}
	return &id, nil
}

// ConfigChanges is GET /api/config/changes.
func (s *Server) ConfigChanges(w http.ResponseWriter, r *http.Request) {
	id, err := optInstance(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{{"changes", `SELECT * FROM pgvigil.config_change_log($1)`, []any{id}}})
}

// MSSQLConfigFleet is GET /api/mssql/config/fleet.
func (s *Server) MSSQLConfigFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{{"pivot", `SELECT * FROM pgvigil.mssql_config_pivot()`, nil}})
}

// MSSQLTraceFlags is GET /api/mssql/traceflags.
func (s *Server) MSSQLTraceFlags(w http.ResponseWriter, r *http.Request) {
	id, err := optInstance(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"flags", `SELECT * FROM pgvigil.mssql_trace_flags_now($1)`, []any{id}},
		{"history", `SELECT * FROM pgvigil.mssql_trace_flag_log($1)`, []any{id}},
		{"read", `SELECT x.instance_id, x.first_read_at, x.snapshot_at FROM pgvigil.mssql_trace_flags_read x
 WHERE $1::int IS NULL OR x.instance_id = $1`, []any{id}},
	})
}

// JobThresholds is GET /api/jobs/thresholds.
func (s *Server) JobThresholds(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ps, err := onlyPart(r, []part{
		{"levels", `SELECT * FROM pgvigil.job_threshold_levels($1)`, []any{id}},
		{"status", `SELECT * FROM pgvigil.job_status($1)`, []any{id}},
	})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{}
	why := s.ackOff()
	out["writable"] = why == ""
	if why != "" {
		out["reason"] = strings.Replace(why, "acknowledgements", "thresholds", 1)
	}
	for _, p := range ps {
		t, err := s.query(r.Context(), p.sql, p.args...)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("%s: %w", p.name, err))
			return
		}
		out[p.name] = t
	}
	s.reply(w, r, out, nil)
}

// jobThresholdKeys are the thresholds import_job_threshold takes (0094's columns).
var jobThresholdKeys = []string{"fail_24h_warn", "fail_24h_crit", "fail_7d_warn", "fail_7d_crit", "step_fail_24h_warn",
	"step_fail_24h_crit", "step_fail_7d_warn", "step_fail_7d_crit", "since_fail_warn_min", "since_fail_crit_min",
	"since_ok_warn_min", "since_ok_crit_min"}

// JobThresholdWrite is POST /api/jobs/thresholds: one attempt to set a level's thresholds or to make it inherit.
// The function checks every value and answers done or refused; a refused attempt is 409 with its reason.
func (s *Server) JobThresholdWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.ackOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(strings.Replace(why, "acknowledgements", "thresholds", 1)))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 8193))
	if err != nil || len(raw) > 8192 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 8 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	// only the named keys travel on; who and from where are the server's to say
	pay := map[string]any{"ui_user": user, "client": clientIP(r)}
	for _, k := range append([]string{"op", "level", "instance_id", "job_name", "last_fail_is"}, jobThresholdKeys...) {
		if v, ok := in[k]; ok && v != nil {
			pay[k] = v
		}
	}
	b, _ := json.Marshal(pay)
	var res struct {
		Outcome     string `json:"outcome"`
		Detail      string `json:"detail"`
		ThresholdID *int64 `json:"threshold_id"`
	}
	var out []byte
	// the write outlives a client that hangs up, never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_job_threshold($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("job threshold: not written", "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_job_threshold answered %q", out))
		return
	}
	s.log.Info("job threshold: attempt", "op", pay["op"], "level", pay["level"], "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "threshold_id": res.ThresholdID}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(o)
}
