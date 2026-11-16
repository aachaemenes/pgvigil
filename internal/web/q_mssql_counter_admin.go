package web

// The SQL Server counter list (task 401, B3). GET /api/mssql/counteradmin?[instance=N][&from=&to=][&part=...] reads
// 0152's store:
//
//	config     Admin's live rows (fleet, tag, instance) with who made them and when
//	defaults   the list a new instance starts with, each with the rows it answers and what reads it
//	log        the last 200 attempts from this page, done or refused
//	layers     (instance) every word on every counter for that instance - the defaults, pgvigil.yaml's lines as its
//	           collector last handed them over, Admin's rows - and the level that wins
//	catalog    (instance) every counter that server has (mssql_counter_catalog, read once a day); without an
//	           instance, every counter any server has, with how many servers have it
//	absent     (instance) the listed counters the newest read did not have, and why
//	histogram  (instance) the Batch Resp Statistics buckets over the window
//
// POST /api/mssql/counteradmin {op add | end, scope, tag, instance_id, object, counter, inst, action, kind, note,
// config_id} writes one row the way alert rules are written (q_alert_rules.go): the UI login, the X-Pgvigil header and
// the actions door's audit pool; pgvigil.import_mssql_counter_config writes the row and its log line, a refused attempt
// included (a removal of a counter a page or a rule reads is refused there with what reads it).

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

const sqlCounterConfig = `SELECT c.config_id, c.scope, c.tag, c.instance_name, c.object, c.counter, c.inst, c.action, c.kind, c.note,
       c.replaces, c.created_by, c.created_at
  FROM pgvigil.mssql_counter_config c WHERE c.ended_at IS NULL
 ORDER BY CASE c.scope WHEN 'fleet' THEN 1 WHEN 'tag' THEN 2 ELSE 3 END, c.tag, c.instance_name, c.object, c.counter, c.inst`

const sqlCounterDefaults = `SELECT d.object, d.counter, d.inst, d.kind, d.used_by, d.source, pgvigil.mssql_counter_scope(d.object) AS scope
  FROM pgvigil.mssql_counter_defaults d ORDER BY d.object, d.counter, d.inst`

const sqlCounterLog = `SELECT l.at, l.ui_user, l.op, l.config_id, l.outcome, l.detail, l.payload->>'object' AS object,
       l.payload->>'counter' AS counter, l.payload->>'action' AS action, l.payload->>'scope' AS scope
  FROM pgvigil.mssql_counter_config_log l ORDER BY l.at DESC LIMIT 200`

// the winning word per counter first, then the words it beat
// (0152's mssql_counter_layers_won: the list's own rule, ties and blocked removals included)
const sqlCounterLayers = `WITH l AS (SELECT x.* FROM pgvigil.mssql_counter_layers_won($1, pgvigil.mssql_counter_yaml_of($1)) x)
SELECT l.object, l.counter, l.inst, l.action, l.kind, l.level, l.source, l.config_id, l.used_by, l.wins, l.blocked,
       pgvigil.mssql_counter_scope(l.object) AS scope,
       (SELECT y.read_at FROM pgvigil.mssql_counter_yaml y WHERE y.instance_id = $1) AS yaml_read_at
  FROM l ORDER BY l.object, l.counter, l.inst, l.level DESC`

const sqlCounterCatalogOne = `SELECT k.object, k.counter, k.cntr_type, k.instances, k.first_instance, k.last_instance, k.read_at
  FROM pgvigil.mssql_counter_catalog k WHERE k.instance_id = $1 ORDER BY k.object, k.counter`

const sqlCounterCatalogAll = `SELECT k.object, k.counter, min(k.cntr_type) AS cntr_type, count(*) AS servers, max(k.read_at) AS read_at
  FROM pgvigil.mssql_counter_catalog k JOIN pgvigil.instances i ON i.instance_id = k.instance_id AND i.is_active
 GROUP BY k.object, k.counter ORDER BY k.object, k.counter`

// MSSQLCounterAdmin is GET /api/mssql/counteradmin.
func (s *Server) MSSQLCounterAdmin(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id := 0
	if v := q.Get("instance"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 || n > math.MaxInt32 {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %q is not an instance id", v))
			return
		}
		id = n
	}
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	parts := []part{
		{"config", sqlCounterConfig, nil},
		{"defaults", sqlCounterDefaults, nil},
		{"log", sqlCounterLog, nil},
	}
	if id > 0 {
		parts = append(parts,
			part{"layers", sqlCounterLayers, []any{id}},
			part{"catalog", sqlCounterCatalogOne, []any{id}},
			part{"absent", `SELECT * FROM pgvigil.mssql_counter_absent($1, pgvigil.mssql_counter_yaml_of($1))`, []any{id}},
			part{"histogram", `SELECT * FROM pgvigil.mssql_counter_histogram($1, $2, $3)`, []any{id, from, to}})
	} else {
		parts = append(parts, part{"catalog", sqlCounterCatalogAll, nil})
	}
	ps, err := onlyPart(r, parts)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{}
	why := s.counterAdminOff()
	out["writable"] = why == ""
	if why != "" {
		out["reason"] = why
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

// counterAdminOff says why the counter list cannot be edited here, "" when it can: like alert rules it rides the UI
// login and the actions door's audit login.
func (s *Server) counterAdminOff() string {
	switch {
	case s.demo != nil:
		return "the counter list is read by the collector, which pgvigil demo -serve does not run: editing it needs pgvigil serve with a signed-in user"
	case s.auth == nil:
		return "the counter list is edited behind the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "counter list edits are off on this server (no actions door)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "the counter list is written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "the counter list is written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// counterEdit is the body of POST /api/mssql/counteradmin.
type counterEdit struct {
	Op         string `json:"op"`
	Scope      string `json:"scope"`
	Tag        string `json:"tag"`
	InstanceID int64  `json:"instance_id"`
	Object     string `json:"object"`
	Counter    string `json:"counter"`
	Inst       string `json:"inst"`
	Action     string `json:"action"`
	Kind       string `json:"kind"`
	Note       string `json:"note"`
	ConfigID   int64  `json:"config_id"`
}

// MSSQLCounterAdminWrite is POST /api/mssql/counteradmin: one row added (a live row of the same counter and scope is
// ended and replaced) or ended.
func (s *Server) MSSQLCounterAdminWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.counterAdminOff(); why != "" {
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
	var in counterEdit
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
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		pay["scope"], pay["tag"], pay["object"], pay["counter"], pay["inst"] = in.Scope, in.Tag, in.Object, in.Counter, in.Inst
		pay["action"], pay["kind"], pay["note"] = in.Action, in.Kind, in.Note
		if in.Scope == "instance" {
			if in.InstanceID <= 0 || in.InstanceID > math.MaxInt32 {
				writeErr(w, http.StatusBadRequest, errors.New("an instance row names its instance_id"))
				return
			}
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
	// the write outlives a client that hangs up (its log row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_mssql_counter_config($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("counter list: not written", "op", in.Op, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_mssql_counter_config answered %q", out))
		return
	}
	s.log.Info("counter list: attempt", "op", in.Op, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "config_id": res.ConfigID}
	if code != http.StatusOK {
		o["error"] = res.Detail // the page's post throws b.error: a refusal shows its reason (review part 3, finding 1)
	}
	_ = json.NewEncoder(w).Encode(o)
}
