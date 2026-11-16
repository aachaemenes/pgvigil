package web

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

// The Security tab of a SQL Server instance (task 408): dbachecks' security checks and SQLMonitor's password-expiry
// notice over what the mssql_security collection read (migration 0159), every rule on or off at the fleet, a tag or
// the instance. It reads only 0159's tables and views and 0090's database owners; the settings are written through
// import_mssql_security_config, as the counter list's are (0152): the UI login and the actions door's audit login.
//
// GET /api/mssql/security?instance=<id>[&part=] (Server.MSSQLSecurity):
//
//	state      the collection's last run (ok, partial, skipped, error, with its note)
//	read       each part's state (read, no right, failed, off, n/a) with why and its last read
//	context    the machine name, the collector's login, Linux or not, the rights it has
//	rules      every rule: on / off and where set, its verdict (ok, hit, not read, n/a, not enabled), hits, source, departure
//	findings   the instance's security findings (the rules in force that hit)
//	hits       every hit of every rule, off ones included (what an off rule would say)
//	settings   the value in force per setting key and where it was set
//	logins     every login with its flags
//	server     login auditing, HideInstance, the collector's connection, public's server permissions, the connections by scheme
//	proxies    the Agent proxies
//	databases  every database: containment, entered by the last run, its last read
//	objects    the database objects (users, guest's CONNECT, assemblies, certificates, keys)
//	config     the live settings rows that reach this instance (fleet, its tags, itself) and the last 50 attempts
//	tags       the instance's tags (an edit's scope may be one of them)
//	writable, reason  whether the settings can be edited on this server, and why not
//
// POST /api/mssql/security/config (Server.MSSQLSecurityConfigWrite): one edit {op add | end, scope, tag, instance_id,
// key, value, note, config_id}.

const sqlSecRead = `SELECT part, status, note, snapshot_at, read_at FROM pgvigil.mssql_security_read WHERE instance_id = $1 ORDER BY part`

const sqlSecContext = `SELECT machine_name, login_name, linux, view_any_definition, alter_any_login, view_server_state, snapshot_at
  FROM pgvigil.mssql_security_context WHERE instance_id = $1`

const sqlSecRules = `SELECT rule_key, label, source, part, default_severity, departure, is_on, set_at, set_tag, config_id,
       part_status, part_note, read_at, verdict, hits
  FROM pgvigil.mssql_security_rule_state WHERE instance_id = $1 ORDER BY sort`

const sqlSecFindings = `SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_security_findings
 WHERE instance_id = $1 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, check_name, object`

const sqlSecHits = `SELECT h.rule_key, d.label, coalesce(h.severity, d.severity) AS severity, h.object, h.detail, h.at
  FROM pgvigil.mssql_security_hits h JOIN pgvigil.mssql_security_rule_defs d ON d.rule_key = h.rule_key
 WHERE h.instance_id = $1 ORDER BY d.sort, h.object LIMIT 2000`

const sqlSecSettings = `SELECT s.key, coalesce(k.label, d.label) AS label, coalesce(k.value_kind, 'rule') AS value_kind, s.value, s.set_at,
       s.set_tag, s.config_id, s.set_by, s.set_on
  FROM pgvigil.mssql_security_settings s
  LEFT JOIN pgvigil.mssql_security_setting_keys k ON k.key = s.key
  LEFT JOIN pgvigil.mssql_security_rule_defs d ON s.key = 'rule:' || d.rule_key
 WHERE s.instance_id = $1 ORDER BY (s.key LIKE 'rule:%'), coalesce(d.sort, 0), s.key`

const sqlSecLogins = `SELECT login_name, login_type, principal_id, is_original_sa, is_disabled, is_sysadmin, must_change, days_until_expiration,
       is_policy_checked, is_expiration_checked, has_session, created_at, modified_at, snapshot_at
  FROM pgvigil.mssql_security_logins WHERE instance_id = $1 AND is_present ORDER BY lower(login_name) LIMIT 5000`

// one table of the server-level facts: kind = registry | auth | perm | conn
const sqlSecServer = `
SELECT 'registry' AS kind, g.value_name AS name, g.value, g.applies, g.source AS detail, g.note, g.snapshot_at
  FROM pgvigil.mssql_security_registry g WHERE g.instance_id = $1
UNION ALL
SELECT 'auth', 'collector', a.auth_scheme, true, a.net_transport || coalesce(' from ' || a.client_address, ''), NULL, a.snapshot_at
  FROM pgvigil.mssql_security_auth a WHERE a.instance_id = $1
UNION ALL
SELECT 'perm', p.permission_name || coalesce(' ON ' || p.object_name, ''), p.state_desc, true, p.class_desc, NULL, p.snapshot_at
  FROM pgvigil.mssql_security_server_perms p WHERE p.instance_id = $1
UNION ALL
SELECT 'conn', c.auth_scheme || ' / ' || c.net_transport, c.connections::text, true, NULL, NULL, c.snapshot_at
  FROM pgvigil.mssql_security_auth_counts c WHERE c.instance_id = $1
ORDER BY 1, 2`

const sqlSecProxies = `SELECT proxy_name, enabled, credential_name, public_granted, snapshot_at
  FROM pgvigil.mssql_security_proxies WHERE instance_id = $1 AND is_present ORDER BY proxy_name`

const sqlSecDatabases = `SELECT database_name, containment, entered, read_at, note, snapshot_at
  FROM pgvigil.mssql_security_db WHERE instance_id = $1 AND is_present ORDER BY database_name`

const sqlSecObjects = `SELECT database_name, object_kind, object_name, object_type, authentication_type, has_login, has_connect, detail,
       key_length, expires_at, cert_use, snapshot_at
  FROM pgvigil.mssql_security_db_objects WHERE instance_id = $1 ORDER BY database_name, object_kind, object_name LIMIT 5000`

// the live rows that reach the instance (its own, its tags', the fleet's) and the last attempts of the page
const sqlSecConfig = `
SELECT 'row' AS kind, c.config_id, c.scope, c.tag, c.instance_name, c.key, c.value, c.note, c.created_by, c.created_at,
       NULL::text AS outcome, NULL::text AS detail
  FROM pgvigil.mssql_security_config c
  JOIN pgvigil.instances i ON i.instance_id = $1
  LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
 WHERE c.ended_at IS NULL
   AND (c.scope = 'fleet' OR (c.scope = 'instance' AND c.instance_name = i.name) OR (c.scope = 'tag' AND c.tag = ANY (coalesce(t.tags, '{}'::text[]))))
UNION ALL
SELECT 'log', l.config_id, l.payload->>'scope', l.payload->>'tag', l.payload->>'instance_name', l.payload->>'key', l.payload->>'value',
       NULL, l.ui_user, l.at, l.outcome, l.detail
  FROM (SELECT * FROM pgvigil.mssql_security_config_log ORDER BY at DESC LIMIT 50) l
ORDER BY 1 DESC, 10 DESC`

// MSSQLSecurity is GET /api/mssql/security.
func (s *Server) MSSQLSecurity(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ps, err := onlyPart(r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_security", "mssql_checks"}}},
		{"read", sqlSecRead, []any{id}},
		{"context", sqlSecContext, []any{id}},
		{"rules", sqlSecRules, []any{id}},
		{"findings", sqlSecFindings, []any{id}},
		{"hits", sqlSecHits, []any{id}},
		{"settings", sqlSecSettings, []any{id}},
		{"logins", sqlSecLogins, []any{id}},
		{"server", sqlSecServer, []any{id}},
		{"proxies", sqlSecProxies, []any{id}},
		{"databases", sqlSecDatabases, []any{id}},
		{"objects", sqlSecObjects, []any{id}},
		{"config", sqlSecConfig, []any{id}},
		{"tags", `SELECT unnest(t.tags) AS tag FROM pgvigil.instance_tags_merged t WHERE t.instance_id = $1 ORDER BY 1`, []any{id}},
	})
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// writable / reason: whether the settings can be edited here, and why not (the counter list's API, 0152)
	out := map[string]any{}
	why := s.securityConfigOff()
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

// securityConfigOff says why the security settings cannot be edited here, "" when they can (the counter list's doors).
func (s *Server) securityConfigOff() string {
	switch {
	case s.demo != nil:
		return "the security settings are read by the collector, which pgvigil demo -serve does not run: editing them needs pgvigil serve with a signed-in user"
	case s.auth == nil:
		return "the security settings are edited behind the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "security setting edits are off on this server (no actions door)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "the security settings are written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "the security settings are written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// securityEdit is the body of POST /api/mssql/security/config.
type securityEdit struct {
	Op         string `json:"op"`
	Scope      string `json:"scope"`
	Tag        string `json:"tag"`
	InstanceID int64  `json:"instance_id"`
	Key        string `json:"key"`
	Value      string `json:"value"`
	Note       string `json:"note"`
	ConfigID   int64  `json:"config_id"`
}

// MSSQLSecurityConfigWrite is POST /api/mssql/security/config: one setting added at a scope (a live row of the same
// key and scope is ended and replaced) or ended (the scope inherits again).
func (s *Server) MSSQLSecurityConfigWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.securityConfigOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
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
	// the write outlives a client that hangs up (its log row is kept), never the 15 s
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_mssql_security_config($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("security settings: not written", "op", in.Op, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_mssql_security_config answered %q", out))
		return
	}
	s.log.Info("security settings: attempt", "op", in.Op, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]any{"outcome": res.Outcome, "detail": res.Detail, "config_id": res.ConfigID})
}
