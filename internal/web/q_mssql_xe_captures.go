package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// The optional Extended Events captures of a SQL Server instance (task 411): waits over a threshold, query warnings,
// page splits and cache misses counted, module runs over a threshold; the slow capture's trend by login, program,
// host or database; the loss of the deadlock and blocked-process ring buffers in the window. It reads 0162's tables
// and 0065's slow events and state; the settings are written through import_mssql_xe_capture_config (0152's doors).
//
// GET /api/mssql/xecaptures?instance=<id>[&from=&to=][&part=][&by=login|program|host|database][&bucket=hour|day]
// [&plan_hash=0x...][&install_id=main][&form=server|rds|cloudsql|azuresqlmi|azuresqldb][&text=full|normalized|none]
// (a SQL Server instance only; text defaults to the instance's query_text, and under none stays none):
//
//	state            each capture's session: not installed, stopped, running; what the last read found; its loss
//	waits_by_type    the window's waits per type and category: count, total, average and longest (ms)
//	waits_series     per hour of the window, the waited ms per category (the chart)
//	waits_top        the 10 statements (by plan hash) with the longest average wait, with a statement
//	waits            the newest 500 waits of the window
//	plan_text        with plan_hash: that plan's newest statement text the captures kept (waits, then slow events)
//	warnings_by_event  the window's warnings per event
//	warnings_top     the 200 largest keys (event, database, plan hash) of the window with their newest sample
//	warning_counts   page_split and sp_cache_miss in the window (the event_counter's differences), a restart said
//	modules          the newest 500 module runs of the window
//	trend            the slow capture's workload per hour or day by login, program, host or database (SQLMonitor)
//	lost             the deadlock and blocked-process captures' LAST loss when it falls in the window (mssql_xe_state
//	                 keeps the last one only: an earlier loss in a window is not kept, and the page says so)
//	settings         the value in force per key and where it was set; config the live rows and the last attempts
//	script, drop     the script that makes the four sessions with these settings, and the one that drops them
//	writable, reason whether the settings can be edited on this server, and why not
//	text_policy      the instance's statement-text policy (the script's default)
//
// POST /api/mssql/xecaptures/config: one edit {op add | end, scope, tag, instance_id, key, value, note, config_id}.

const sqlXCState = `SELECT capture, state, state_since, session_name, target, buffer_kb, new_events, dropped_events, lost_events, lost_at,
       note, snapshot_at FROM pgvigil.mssql_xe_capture_state WHERE instance_id = $1 ORDER BY capture`

const sqlXCWaitsByType = `SELECT coalesce(wait_type, '(none)') AS wait_type, coalesce(category, '(none)') AS category, count(*) AS waits,
       sum(duration_ms) AS total_ms, round(avg(duration_ms), 1) AS avg_ms, max(duration_ms) AS max_ms, sum(signal_ms) AS signal_ms
  FROM pgvigil.mssql_xe_waits WHERE instance_id = $1 AND event_at > $2 AND event_at <= $3
 GROUP BY 1, 2 ORDER BY total_ms DESC NULLS LAST LIMIT 200`

const sqlXCWaitsSeries = `SELECT date_trunc('hour', event_at) AS snapshot_at, coalesce(category, '(none)') AS category, sum(duration_ms) AS waited_ms
  FROM pgvigil.mssql_xe_waits WHERE instance_id = $1 AND event_at > $2 AND event_at <= $3
 GROUP BY 1, 2 ORDER BY 1, 2`

const sqlXCWaitsTop = `SELECT coalesce(query_plan_hash, '(no plan hash)') AS query_plan_hash, count(*) AS waits,
       round(avg(duration_ms), 1) AS avg_ms, max(duration_ms) AS max_ms, sum(duration_ms) AS total_ms,
       (array_agg(statement ORDER BY event_at DESC) FILTER (WHERE statement IS NOT NULL))[1] AS statement,
       (array_agg(database_name ORDER BY event_at DESC))[1] AS database_name
  FROM pgvigil.mssql_xe_waits WHERE instance_id = $1 AND event_at > $2 AND event_at <= $3
 GROUP BY 1 ORDER BY avg_ms DESC NULLS LAST LIMIT 10`

const sqlXCWaits = `SELECT event_at, event_name, wait_type, category, duration_ms, signal_ms, session_id, login_name, host_name, program_name,
       database_name, query_plan_hash, statement
  FROM pgvigil.mssql_xe_waits WHERE instance_id = $1 AND event_at > $2 AND event_at <= $3
 ORDER BY event_at DESC LIMIT 500`

const sqlXCPlanText = `SELECT x.source, x.statement, x.event_at FROM (
  SELECT 'waits' AS source, statement, event_at FROM pgvigil.mssql_xe_waits
   WHERE instance_id = $1 AND query_plan_hash = $2 AND statement IS NOT NULL
  UNION ALL
  SELECT 'slow queries', statement, event_at FROM pgvigil.mssql_slow_events
   WHERE instance_id = $1 AND query_plan_hash = $2 AND statement IS NOT NULL) x
 ORDER BY x.event_at DESC LIMIT 1`

const sqlXCWarningsByEvent = `SELECT event_name, sum(events) AS events, count(DISTINCT query_plan_hash) AS plans, count(DISTINCT database_name) AS databases
  FROM pgvigil.mssql_xe_warning_hours WHERE instance_id = $1 AND hour_at > date_trunc('hour', $2::timestamptz) - interval '1 hour' AND hour_at <= $3
 GROUP BY 1 ORDER BY events DESC`

const sqlXCWarningsTop = `SELECT h.event_name, nullif(h.database_name, '') AS database_name, nullif(h.query_plan_hash, '') AS query_plan_hash,
       sum(h.events) AS events, max(s.event_at) AS last_at,
       (array_agg(s.detail ORDER BY s.event_at DESC NULLS LAST))[1] AS detail,
       (array_agg(s.statement ORDER BY s.event_at DESC NULLS LAST) FILTER (WHERE s.statement IS NOT NULL))[1] AS statement
  FROM pgvigil.mssql_xe_warning_hours h
  LEFT JOIN pgvigil.mssql_xe_warning_samples s USING (instance_id, hour_at, event_name, database_name, query_plan_hash)
 WHERE h.instance_id = $1 AND h.hour_at > date_trunc('hour', $2::timestamptz) - interval '1 hour' AND h.hour_at <= $3
 GROUP BY 1, 2, 3 ORDER BY events DESC LIMIT 200`

const sqlXCWarningCounts = `SELECT event_name, sum(delta) AS events, count(*) AS reads, bool_or(restarted) AS restarted, max(total) AS total_since_start
  FROM pgvigil.mssql_xe_warning_counts WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

const sqlXCModules = `SELECT event_at, database_name, object_name, object_type, duration_ms, row_count, session_id, login_name, host_name, program_name
  FROM pgvigil.mssql_xe_modules WHERE instance_id = $1 AND event_at > $2 AND event_at <= $3
 ORDER BY event_at DESC LIMIT 500`

const sqlXCTrend = `SELECT * FROM pgvigil.mssql_xe_slow_trend($1, $2, $3, $4, $5)`

const sqlXCLost = `SELECT capture, session_name, lost_events, lost_at, buffer_kb FROM pgvigil.mssql_xe_state
 WHERE instance_id = $1 AND capture IN ('deadlocks', 'blocked') AND lost_at > $2 AND lost_at <= $3 AND lost_events > 0 ORDER BY capture`

const sqlXCSettings = `SELECT key, label, value_kind, value, set_at, set_tag, config_id, set_by, set_on
  FROM pgvigil.mssql_xe_capture_settings WHERE instance_id = $1 ORDER BY key`

const sqlXCConfig = `
SELECT 'row' AS kind, c.config_id, c.scope, c.tag, c.instance_name, c.key, c.value, c.note, c.created_by, c.created_at,
       NULL::text AS outcome, NULL::text AS detail
  FROM pgvigil.mssql_xe_capture_config c
  JOIN pgvigil.instances i ON i.instance_id = $1
  LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
 WHERE c.ended_at IS NULL
   AND (c.scope = 'fleet' OR (c.scope = 'instance' AND c.instance_name = i.name) OR (c.scope = 'tag' AND c.tag = ANY (coalesce(t.tags, '{}'::text[]))))
UNION ALL
SELECT 'log', l.config_id, l.payload->>'scope', l.payload->>'tag', l.payload->>'instance_name', l.payload->>'key', l.payload->>'value',
       NULL, l.ui_user, l.at, l.outcome, l.detail
  FROM (SELECT * FROM pgvigil.mssql_xe_capture_config_log ORDER BY at DESC LIMIT 50) l
ORDER BY 1 DESC, 10 DESC`

var xcPlanHashRE = regexp.MustCompile(`^0x[0-9A-Fa-f]{16}$`)

// MSSQLXECaptures is GET /api/mssql/xecaptures.
func (s *Server) MSSQLXECaptures(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// a SQL Server instance only: another engine's id gets no script built on the defaults
	var name, engine string
	if err := s.pool.QueryRow(r.Context(), `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name, &engine); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	if engine != "sqlserver" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %d is not a SQL Server instance", id))
		return
	}
	q := r.URL.Query()
	by := q.Get("by")
	if by == "" {
		by = "login"
	}
	bucket := q.Get("bucket")
	if bucket == "" {
		bucket = "hour"
	}
	if by != "login" && by != "program" && by != "host" && by != "database" {
		writeErr(w, http.StatusBadRequest, errors.New("by must be login, program, host or database"))
		return
	}
	if bucket != "hour" && bucket != "day" {
		writeErr(w, http.StatusBadRequest, errors.New("bucket must be hour or day"))
		return
	}
	parts := []part{
		{"state", sqlXCState, []any{id}},
		{"waits_by_type", sqlXCWaitsByType, []any{id, from, to}},
		{"waits_series", sqlXCWaitsSeries, []any{id, from, to}},
		{"waits_top", sqlXCWaitsTop, []any{id, from, to}},
		{"waits", sqlXCWaits, []any{id, from, to}},
		{"warnings_by_event", sqlXCWarningsByEvent, []any{id, from, to}},
		{"warnings_top", sqlXCWarningsTop, []any{id, from, to}},
		{"warning_counts", sqlXCWarningCounts, []any{id, from, to}},
		{"modules", sqlXCModules, []any{id, from, to}},
		{"trend", sqlXCTrend, []any{id, from, to, bucket, by}},
		{"lost", sqlXCLost, []any{id, from, to}},
		{"settings", sqlXCSettings, []any{id}},
		{"config", sqlXCConfig, []any{id}},
	}
	if h := q.Get("plan_hash"); h != "" {
		if !xcPlanHashRE.MatchString(h) {
			writeErr(w, http.StatusBadRequest, errors.New("plan_hash is 0x and 16 hex digits"))
			return
		}
		parts = append(parts, part{"plan_text", sqlXCPlanText, []any{id, h}})
	}
	ps, err := onlyPart(r, append(parts, part{"script", "", nil}))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{}
	// the instance's statement-text policy: the script's default, and the page's select starts there
	policy := s.doorsNow().queryText(name)
	out["text_policy"] = policy
	why := s.xeCaptureConfigOff()
	out["writable"] = why == ""
	if why != "" {
		out["reason"] = why
	}
	for _, p := range ps {
		if p.name == "script" {
			sc, drop, err := s.xeCapturesScript(r.Context(), id, q.Get("install_id"), q.Get("form"), q.Get("text"), policy)
			if err != nil {
				writeErr(w, http.StatusBadRequest, err)
				return
			}
			out["script"], out["drop"] = sc, drop
			continue
		}
		t, err := s.query(r.Context(), p.sql, p.args...)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("%s: %w", p.name, err))
			return
		}
		out[p.name] = t
	}
	s.reply(w, r, out, nil)
}

// xeCapturesScript writes the instance's script with the settings in force (the install id main and the server form
// unless the request names others) and the instance's statement-text policy: a request may narrow it to none, never
// widen it (under query_text none the script never captures the text: pass F14).
func (s *Server) xeCapturesScript(ctx context.Context, id int, installID, form, text, policy string) (string, string, error) {
	if installID == "" {
		installID = "main"
	}
	if form == "" {
		form = mssql.XEFormServer
	}
	if text == "" {
		text = policy
	}
	if text != "full" && text != "none" && text != "normalized" {
		return "", "", errors.New("text must be full, normalized or none")
	}
	if policy == "none" {
		text = "none"
	}
	var raw []byte
	if err := s.pool.QueryRow(ctx, `SELECT pgvigil.mssql_xe_capture_settings_json($1)::text`, id).Scan(&raw); err != nil {
		return "", "", fmt.Errorf("the settings: %w", err)
	}
	var js struct {
		WaitMS      *int     `json:"wait_ms"`
		ModuleMS    *int     `json:"module_ms"`
		AppExclude  []string `json:"app_exclude"`
		ProcExclude []string `json:"proc_exclude"`
	}
	set := mssql.DefaultXECaptureSettings()
	if err := json.Unmarshal(raw, &js); err == nil {
		if js.WaitMS != nil {
			set.WaitMS = *js.WaitMS
		}
		if js.ModuleMS != nil {
			set.ModuleMS = *js.ModuleMS
		}
		if js.AppExclude != nil {
			set.AppExclude = js.AppExclude
		}
		if js.ProcExclude != nil {
			set.ProcExclude = js.ProcExclude
		}
	}
	sc, err := mssql.XECapturesScript(installID, form, text, nil, set)
	if err != nil {
		return "", "", err
	}
	drop, err := mssql.XECapturesDropScript(installID, form, nil)
	return sc, drop, err
}

// xeCaptureConfigOff says why the capture settings cannot be edited here, "" when they can (the counter list's doors).
func (s *Server) xeCaptureConfigOff() string {
	switch {
	case s.demo != nil:
		return "the capture settings are read by the collector, which pgvigil demo -serve does not run: editing them needs pgvigil serve with a signed-in user"
	case s.auth == nil:
		return "the capture settings are edited behind the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "capture setting edits are off on this server (no actions door)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "the capture settings are written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "the capture settings are written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// MSSQLXECapturesConfigWrite is POST /api/mssql/xecaptures/config (the body as the security settings' write).
func (s *Server) MSSQLXECapturesConfigWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.xeCaptureConfigOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 16385))
	if err != nil || len(raw) > 16384 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 16 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in securityEdit
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	pay := map[string]any{"op": in.Op, "ui_user": user, "client": clientIP(r)}
	switch in.Op {
	case "end":
		if in.ConfigID <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("config_id is required to end a row"))
			return
		}
		pay["config_id"] = strconv.FormatInt(in.ConfigID, 10)
	case "add":
		pay["scope"], pay["tag"], pay["key"], pay["value"], pay["note"] = in.Scope, in.Tag, in.Key, in.Value, in.Note
		if in.Scope == "instance" {
			if in.InstanceID <= 0 || in.InstanceID > math.MaxInt32 {
				writeErr(w, http.StatusBadRequest, errors.New("an instance row names its instance_id"))
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
		Outcome  string `json:"outcome"`
		Detail   string `json:"detail"`
		ConfigID *int64 `json:"config_id"`
	}
	var out []byte
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_mssql_xe_capture_config($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("capture settings: not written", "op", in.Op, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_mssql_xe_capture_config answered %q", out))
		return
	}
	s.log.Info("capture settings: attempt", "op", in.Op, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]any{"outcome": res.Outcome, "detail": res.Detail, "config_id": res.ConfigID})
}
