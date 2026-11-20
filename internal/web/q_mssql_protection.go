package web

// The backup ages per tag or database (task 405, PerformanceMonitor 3.13.0's Changed 46). GET /api/mssql/protection
// [?instance=N] reads 0156's store:
//
//	overrides  Admin's live rows (tag or database) with who made them and when
//	log        the last 200 attempts, done or refused
//	limits     (instance) each database's full backup hours and log backup minutes as the backup judging uses them,
//	           with where each comes from (a database row, pgvigil.yaml, a tag, the default)
//
// POST /api/mssql/protection {op add | end, scope tag | database, tag, instance_id, database_name,
// full_backup_hours, log_backup_minutes, note, override_id} writes one row the way the counter list is written
// (q_mssql_counter_admin.go): the UI login, the X-Pgvigil header and the actions door's audit pool;
// pgvigil.import_mssql_protection_override writes the row and its log line, a refused attempt included. An
// instance's own ages stay in pgvigil.yaml's mssql_thresholds.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const sqlProtectionOverrides = `SELECT o.override_id, o.scope, o.tag, o.instance_name, o.database_name, o.full_backup_hours,
       o.log_backup_minutes, o.note, o.replaces, o.created_by, o.created_at
  FROM pgvigil.mssql_protection_overrides o WHERE o.ended_at IS NULL
 ORDER BY o.scope DESC, o.tag, o.instance_name, o.database_name`

const sqlProtectionLog = `SELECT l.at, l.ui_user, l.op, l.override_id, l.outcome, l.detail, l.payload->>'scope' AS scope,
       l.payload->>'tag' AS tag, l.payload->>'instance_name' AS instance_name, l.payload->>'database_name' AS database_name
  FROM pgvigil.mssql_protection_override_log l ORDER BY l.at DESC LIMIT 200`

const sqlProtectionLimits = `SELECT b.database_name, b.full_backup_hours, b.full_hours_from, b.log_backup_minutes, b.log_minutes_from,
       b.full_status, b.log_status, b.not_judged
  FROM pgvigil.mssql_backup_judged b WHERE b.instance_id = $1 ORDER BY b.database_name`

// MSSQLProtection is GET /api/mssql/protection.
func (s *Server) MSSQLProtection(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{}
	why := s.protectionOff()
	out["writable"] = why == ""
	if why != "" {
		out["reason"] = why
	}
	type part struct {
		name string
		sql  string
		args []any
	}
	ps := []part{{"overrides", sqlProtectionOverrides, nil}, {"log", sqlProtectionLog, nil}}
	if v := r.URL.Query().Get("instance"); v != "" {
		id, err := strconv.Atoi(v)
		if err != nil || id <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive number"))
			return
		}
		ps = append(ps, part{"limits", sqlProtectionLimits, []any{id}})
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

// protectionOff says why the backup ages cannot be edited here, "" when they can (the counter list's doors).
func (s *Server) protectionOff() string {
	switch {
	case s.demo != nil:
		return "the backup ages are edited on a pgvigil serve with a signed-in user, not on pgvigil demo -serve"
	case s.auth == nil:
		return "the backup ages are edited behind the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "backup age edits are off on this server (no actions door)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "the backup ages are written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "the backup ages are written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// protectionEdit is the body of POST /api/mssql/protection; an age is a JSON number or null (not set).
type protectionEdit struct {
	Op               string   `json:"op"`
	Scope            string   `json:"scope"`
	Tag              string   `json:"tag"`
	InstanceID       int64    `json:"instance_id"`
	DatabaseName     string   `json:"database_name"`
	FullBackupHours  *float64 `json:"full_backup_hours"`
	LogBackupMinutes *float64 `json:"log_backup_minutes"`
	Note             string   `json:"note"`
	OverrideID       int64    `json:"override_id"`
}

// MSSQLProtectionWrite is POST /api/mssql/protection: one row added (a live row for the same target is ended and
// replaced) or ended.
func (s *Server) MSSQLProtectionWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.protectionOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	if err != nil || len(raw) > 4096 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 4 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in protectionEdit
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	pay := map[string]any{"op": in.Op, "ui_user": user, "client": clientIP(r)}
	switch in.Op {
	case "end":
		if in.OverrideID <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("override_id is required to end a row"))
			return
		}
		pay["override_id"] = strconv.FormatInt(in.OverrideID, 10)
	case "add":
		pay["scope"], pay["tag"], pay["database_name"], pay["note"] = in.Scope, in.Tag, in.DatabaseName, in.Note
		// the store reads an age as text (0 or more, up to 3 decimals): a number goes over as its shortest form
		for k, v := range map[string]*float64{"full_backup_hours": in.FullBackupHours, "log_backup_minutes": in.LogBackupMinutes} {
			if v != nil {
				pay[k] = strconv.FormatFloat(*v, 'f', -1, 64)
			}
		}
		if in.Scope == "database" {
			if in.InstanceID <= 0 || in.InstanceID > math.MaxInt32 {
				writeErr(w, http.StatusBadRequest, errors.New("a database row names its instance_id"))
				return
			}
			ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
			defer cancel()
			var name string
			err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1 AND is_active AND engine = 'sqlserver'`, in.InstanceID).Scan(&name)
			if errors.Is(err, pgx.ErrNoRows) {
				writeErr(w, http.StatusBadRequest, fmt.Errorf("no active SQL Server instance %d", in.InstanceID))
				return
			}
			if err != nil {
				writeErr(w, http.StatusInternalServerError, fmt.Errorf("the instance could not be read: %v", err))
				return
			}
			pay["instance_name"] = name
		}
	default:
		writeErr(w, http.StatusBadRequest, errors.New("op must be add or end"))
		return
	}
	b, _ := json.Marshal(pay)
	var res struct {
		Outcome    string `json:"outcome"`
		Detail     string `json:"detail"`
		OverrideID *int64 `json:"override_id"`
	}
	var out []byte
	// the write outlives a client that hangs up (its log row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_mssql_protection_override($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("backup ages: not written", "op", in.Op, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_mssql_protection_override answered %q", out))
		return
	}
	s.log.Info("backup ages: attempt", "op", in.Op, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]any{"outcome": res.Outcome, "detail": res.Detail, "override_id": res.OverrideID})
}
