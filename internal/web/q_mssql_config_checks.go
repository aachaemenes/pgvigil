package web

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

// The configuration checks of a SQL Server instance (task 409, migration 0160): GET /api/mssql/config_checks is the
// Checks grid of the Configuration tab - every rule, met or not, with its value, the expected value, where that
// expectation is set and its source - and the facts behind it (the event sessions, the databases' rows, the linked
// servers with their last connection test, the parts of the hourly read and whether each collection it rests on ran).
// GET /api/mssql/config_expect is the Expected values editor's read: the kinds and keys, the live rows, the tags.
// POST /api/mssql/config_expect is one attempt of that editor. A PostgreSQL instance has no row in 0160's tables and
// gets empty parts.

// sqlConfigChecks: every rule of the instance; the deviations first.
const sqlConfigChecks = `
SELECT rule, check_name, object, value, expected, set_at, source, status, detail, at
  FROM pgvigil.mssql_config_checks_of($1)
 ORDER BY CASE status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'info' THEN 3 WHEN 'ok' THEN 4
                      WHEN 'not read' THEN 5 WHEN 'not applicable' THEN 6 ELSE 7 END, check_name, object`

const sqlConfigCheckParts = `SELECT part, is_read, note, snapshot_at FROM pgvigil.mssql_confcheck_part WHERE instance_id = $1 ORDER BY part`

const sqlConfigCheckFacts = `SELECT key, value, snapshot_at FROM pgvigil.mssql_confcheck_fact WHERE instance_id = $1 ORDER BY key`

const sqlConfigCheckXE = `
SELECT session_name, autostart, running, snapshot_at FROM pgvigil.mssql_xe_session_state WHERE instance_id = $1 ORDER BY session_name`

const sqlConfigCheckDatabases = `
SELECT database_name, state, read_only, in_standby, recovery_model, query_store, secondary_role, scoped_maxdop, scoped_note, snapshot_at
  FROM pgvigil.mssql_db_confcheck WHERE instance_id = $1 ORDER BY database_name`

// sqlConfigCheckLinked: each linked server with who is mapped there and its last connection test.
const sqlConfigCheckLinked = `
SELECT l.name, l.product, l.provider, l.data_source, l.catalog, l.rpc_out, l.data_access, l.connect_timeout, l.query_timeout,
       l.modified_at, l.logins, l.logins_read, l.snapshot_at,
       t.outcome, t.error_number, t.error_message, t.seconds, t.note AS test_note, t.tested_at, t.first_failed_at
  FROM pgvigil.mssql_linked_server l
  LEFT JOIN pgvigil.mssql_linked_server_test t ON t.instance_id = l.instance_id AND t.name = l.name
 WHERE l.instance_id = $1
 ORDER BY l.name`

// sqlConfigCheckRuns: each collection the checks rest on, with its newest run, its outcome and note, and status 'off'
// where the instance's configuration switches it off ($2: the server's expected intervals, 0 = disabled there).
const sqlConfigCheckRuns = `
SELECT w.collection, d.snapshot_at,
       CASE WHEN ($2::jsonb -> 'instances' -> i.name ->> w.collection)::int = 0 THEN 'off' ELSE d.status END AS status, d.note
  FROM (VALUES ('mssql_confcheck'), ('mssql_linkedserver_test'), ('mssql_instance'), ('mssql_services'), ('mssql_traceflags'),
               ('mssql_checks'), ('mssql_jobs'), ('mssql_properties')) w (collection)
  CROSS JOIN (SELECT name FROM pgvigil.instances WHERE instance_id = $1) i
  LEFT JOIN pgvigil.collection_dates d ON d.instance_id = $1 AND d.collection = w.collection`

// MSSQLConfigChecks is GET /api/mssql/config_checks?instance=N[&part=...].
func (s *Server) MSSQLConfigChecks(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	exp, err := json.Marshal(s.expected)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	s.multiPart(w, r, []part{
		{"checks", sqlConfigChecks, []any{id}},
		{"parts", sqlConfigCheckParts, []any{id}},
		{"facts", sqlConfigCheckFacts, []any{id}},
		{"xe", sqlConfigCheckXE, []any{id}},
		{"databases", sqlConfigCheckDatabases, []any{id}},
		{"linked", sqlConfigCheckLinked, []any{id}},
		{"runs", sqlConfigCheckRuns, []any{id, string(exp)}},
	})
}

// sqlConfigExpectKeys: what an expectation can be set for (the kind 'config' takes any server option's name).
const sqlConfigExpectKeys = `
SELECT kind, key, vtype, choices, takes_exclusions, default_exclusions, default_on, source, rule, label, vmin, vmax
  FROM pgvigil.mssql_config_expect_keys()
 ORDER BY kind, label`

// sqlConfigExpectInForce: what is in force for one instance, with where it was set.
const sqlConfigExpectInForce = `
SELECT kind, key, value, exclusions, set_at, set_by, set_when FROM pgvigil.mssql_config_expect_in_force($1) ORDER BY kind, key`

const sqlConfigExpectTags = `
SELECT DISTINCT t.tag FROM pgvigil.instance_tags_merged m JOIN pgvigil.instances i USING (instance_id) CROSS JOIN unnest(m.tags) t(tag)
 WHERE i.is_active AND i.engine = 'sqlserver' ORDER BY 1`

// optionalInstance reads ?instance= where a request may leave it out: 0 without it, an error for anything that is
// not a positive instance_id.
func optionalInstance(r *http.Request) (int, error) {
	v := r.URL.Query().Get("instance")
	if v == "" {
		return 0, nil
	}
	id, err := strconv.Atoi(v)
	if err != nil || id <= 0 {
		return 0, errors.New("instance must be a positive instance_id")
	}
	return id, nil
}

// MSSQLConfigExpect is GET /api/mssql/config_expect[?instance=N][&part=keys|in_force|tags]. Without an instance
// the in_force part gives the root's values alone.
func (s *Server) MSSQLConfigExpect(w http.ResponseWriter, r *http.Request) {
	id, err := optionalInstance(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"keys", sqlConfigExpectKeys, nil},
		{"in_force", sqlConfigExpectInForce, []any{id}},
		{"tags", sqlConfigExpectTags, nil},
	})
}

// configExpectMaxBody is the largest attempt read: the function's largest legal one (2,000 databases left out of up to
// 128 characters each, or a list of 500 names of up to 200) fits with room for its quoting.
const configExpectMaxBody = 320 << 10

// configExpectFields are the fields of an editor attempt the function reads; anything else in the body is left out.
var configExpectFields = []string{"op", "level", "instance_id", "tag", "kind", "key", "value", "exclusions"}

// configExpectPayload builds import_mssql_config_expect's payload from an attempt's body: the listed fields as sent
// (a value may be a number, a text or a list), with the signed-in user and its client.
func configExpectPayload(in map[string]any, user, client string) map[string]any {
	pay := map[string]any{"ui_user": user, "client": client}
	for _, k := range configExpectFields {
		if v, ok := in[k]; ok && v != nil {
			// the instance as the text the door and the function both read (a number is sent as its digits)
			if f, isNum := v.(float64); isNum && k == "instance_id" {
				v = strconv.FormatFloat(f, 'f', -1, 64)
			}
			pay[k] = v
		}
	}
	return pay
}

// MSSQLConfigExpectWrite is POST /api/mssql/config_expect: one attempt of the Expected values editor (set a level's
// expectation for a kind and key, or make the level inherit). The function checks every value and answers done or
// refused; a refused attempt is 409 with its reason. The same doors as the threshold writes: the X-Pgvigil header, a
// signed-in user, the actions configuration's audit login; the row keeps who set it and who ended it.
func (s *Server) MSSQLConfigExpectWrite(w http.ResponseWriter, r *http.Request) {
	seat, ok := s.seat(w, r, strings.Replace(s.ackOff(), "acknowledgements", "expected values", 1))
	if !ok {
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, configExpectMaxBody+1))
	if err != nil || len(raw) > configExpectMaxBody {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 320 KB"))
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
	pay := configExpectPayload(in, seat.user, seat.client)
	b, _ := json.Marshal(pay)
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	pool, ok := seat.poolFor(wctx, w, scopeOfLevel(doorConfigExpect, pay))
	if !ok {
		return
	}
	var out []byte
	if err := pool.QueryRow(wctx, `SELECT pgvigil.import_mssql_config_expect($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("config expectation: not written", "user", seat.user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res struct {
		Outcome  string `json:"outcome"`
		Detail   string `json:"detail"`
		ExpectID *int64 `json:"expect_id"`
		Error    string `json:"error,omitempty"` // a refusal's reason, where the UI's post() reads an error
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_mssql_config_expect answered %q", out))
		return
	}
	s.log.Info("config expectation: attempt", "op", pay["op"], "level", pay["level"], "kind", pay["kind"], "key", pay["key"],
		"user", seat.user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
		res.Error = "refused: " + res.Detail
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(res)
}
