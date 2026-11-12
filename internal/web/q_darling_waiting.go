package web

import (
	"errors"
	"net/http"
	"strings"
	"time"
)

// The waiting-tasks API (task 177, darling-open D01; migration 0112). The join wires the route in Handler:
//   GET /api/waiting?instance=N[&from=..&to=..][&at=<RFC 3339>][&wait=<wait type>][&part=...] -> s.Waiting
// A SQL Server instance's parts: snapshots (each read of the range: tasks, sessions, THREADPOOL, the longest wait),
// tasks (one read's waiting tasks: the newest read at or before at, else at or before the range's end; wait narrows
// to one wait type),
// bytype (the range's wait types over the stored reads). A PostgreSQL instance's: pg (the waiting backends of one
// running-queries sample, the same at and wait rules; wait is '<type>:<event>' or the event) and pgbytype. Each read
// returns no row for the other engine, so the page asks for its engine's parts only.

// waitingWait reads wait=: a wait type or a PostgreSQL '<type>:<event>', 1..120 characters of [A-Za-z0-9_:].
func waitingWait(r *http.Request) (*string, error) {
	v := r.URL.Query().Get("wait")
	if v == "" {
		return nil, nil
	}
	if len(v) > 120 || strings.Trim(v, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_:") != "" {
		return nil, errors.New("wait must be a wait type (letters, digits, '_' and ':')")
	}
	return &v, nil
}

// Waiting is the Waiting tasks tab of either engine.
func (s *Server) Waiting(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	wait, err := waitingWait(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var at *time.Time
	if v := r.URL.Query().Get("at"); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("at must be an RFC 3339 time"))
			return
		}
		at = &t
	} else {
		at = &to // no read named: the newest read of the range, never one after it
	}
	s.multiPart(w, r, []part{
		{"snapshots", `SELECT * FROM pgvigil.mssql_waiting_snapshots($1, $2, $3)`, []any{id, from, to}},
		{"tasks", `SELECT * FROM pgvigil.mssql_waiting_at($1, $2, $3)`, []any{id, at, wait}},
		{"bytype", `SELECT * FROM pgvigil.mssql_waiting_by_type($1, $2, $3)`, []any{id, from, to}},
		{"pg", `SELECT * FROM pgvigil.pg_waiting_at($1, $2, $3)`, []any{id, at, wait}},
		{"pgbytype", `SELECT * FROM pgvigil.pg_waiting_by_type($1, $2, $3)`, []any{id, from, to}},
	})
}
