package collect

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// sessionSetsCollector is the hourly read of the settings the application's own sessions change (task 58): the
// utility rows of pg_stat_statements that begin SET, SET LOCAL or RESET, per role and database, with the setting's
// name and value parsed from the text. A plan measured in psql or pgAdmin runs under the server's and the role's
// settings; a session that ran SET enable_hashjoin = off plans under its own, and only this read shows it.
//
// The rows exist only while pg_stat_statements.track_utility is on (the default); with it off, or the extension
// absent from the connected database, the read stores one state row 'not available' with the reason, and nothing
// else (a row present is evidence; no row is inconclusive). PostgreSQL 17 and later normalize a SET's value to $1 in
// the text (SET enable_hashjoin = $1): the setting's name is still known, the value then is not, and the row says
// so. Everything read is visible to pg_monitor (pg_read_all_stats shows every role's statement text).
//
// Rows by kind:
//
//	state  status (ok | not available), reason, track_utility    (once)
//	set    dbid, datname, userid, rolname, queryid, toplevel, command (SET | SET LOCAL | RESET), setting, value,
//	       value_hidden, planner, calls (cumulative since the statistics reset), query
//
// The query column follows the instance's query_text policy (RunOnce); the value of a setting that is not a planner
// one is dropped under any policy but full (a custom setting can carry an application's data: SET app.user_id = 42).
type sessionSetsCollector struct{}

func init() { Register(sessionSetsCollector{}) }

func (sessionSetsCollector) Name() string                   { return "session_sets" }
func (sessionSetsCollector) DefaultInterval() time.Duration { return time.Hour }
func (sessionSetsCollector) Applies(platform.Info) (bool, string) {
	return true, "" // the read itself says 'not available' and why
}

func (sessionSetsCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("session_sets needs the instance config: %w", ErrSkip)
}

// sessionSetsMaxRows bounds one read: an application that sets a per-request value (SET app.tenant = 'x' on PG 16
// and older, one row per value) could otherwise send thousands of rows an hour.
const sessionSetsMaxRows = 2000

func (sessionSetsCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	notAvailable := func(reason string, tu any) []Row {
		return []Row{{"kind": "state", "status": "not available", "reason": reason, "track_utility": tu}}
	}
	if !info.HasPgStatStmts {
		return notAvailable("pg_stat_statements is not installed in the connected database", nil), nil
	}
	var tu *string
	if err := conn.QueryRow(ctx, `SELECT current_setting('pg_stat_statements.track_utility', true)`).Scan(&tu); err != nil {
		return nil, fmt.Errorf("pg_stat_statements.track_utility: %w", err)
	}
	if tu == nil {
		return notAvailable("pg_stat_statements is not loaded (shared_preload_libraries): its settings are not defined", nil), nil
	}
	if *tu != "on" {
		return notAvailable("pg_stat_statements.track_utility is off: SET and RESET statements are not recorded", *tu), nil
	}
	var schema string
	var hasToplevel bool
	err := conn.QueryRow(ctx, `
SELECT n.nspname,
       EXISTS (SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = (quote_ident(n.nspname) || '.pg_stat_statements')::regclass
                  AND a.attname = 'toplevel' AND NOT a.attisdropped)
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'pg_stat_statements'`).Scan(&schema, &hasToplevel)
	if err != nil {
		return nil, fmt.Errorf("pg_stat_statements schema: %w", err)
	}
	toplevel := "true"
	if hasToplevel {
		toplevel = "s.toplevel"
	}
	// the text filter is a first cut (leading comments allowed); parseSessionSet decides. The SETs pgvigil itself runs
	// on the instance (monitorSetupSettings) are not the application's: those settings are left out under the
	// monitor's role alone, every other SET of that role is kept, so a login the application shares with the monitor
	// still shows the application's SETs (pg_stat_statements has no application_name to tell them apart; the
	// application's own SET of one of those settings under the shared login is lost with them). Under the cap the rows
	// that name a planner setting come first: a per-request SET of a custom setting (one row per value on PG 16 and
	// older) must not push them out.
	rows, err := conn.Query(ctx, fmt.Sprintf(`
SELECT s.dbid::bigint, d.datname::text, s.userid::bigint, r.rolname::text, s.queryid, %s, s.calls, left(s.query, 2000),
       s.userid = (SELECT oid FROM pg_roles WHERE rolname = current_user) AS own
  FROM %s.pg_stat_statements s
  LEFT JOIN pg_database d ON d.oid = s.dbid
  LEFT JOIN pg_roles r ON r.oid = s.userid
 WHERE s.query ~* '^\s*(/\*.*?\*/\s*|--[^\n]*\n\s*)*(set|reset)\y' AND s.queryid IS NOT NULL
 ORDER BY (s.query ~* '(set|reset)\s+((local|session)\s+)?"?(enable_|[a-z_]*_cost\y|work_mem\y|jit\y|geqo|join_collapse_limit|from_collapse_limit|plan_cache_mode|default_statistics_target|effective_cache_size|hash_mem_multiplier|max_parallel_workers_per_gather)') DESC,
          s.calls DESC
 LIMIT %d`, toplevel, quoteIdent(schema), sessionSetsMaxRows))
	if err != nil {
		return nil, fmt.Errorf("pg_stat_statements utility rows: %w", err)
	}
	defer rows.Close()
	out := []Row{{"kind": "state", "status": "ok", "reason": nil, "track_utility": *tu}}
	for rows.Next() {
		var dbid, userid, queryid, calls int64
		var datname, rolname *string
		var top, own bool
		var query string
		if err := rows.Scan(&dbid, &datname, &userid, &rolname, &queryid, &top, &calls, &query, &own); err != nil {
			return nil, err
		}
		p, ok := parseSessionSet(query)
		if !ok || (own && monitorSetupSettings[p.Setting]) {
			continue
		}
		var value any = p.Value
		if p.Hidden || p.Command == "RESET" || (!p.Planner && in.QueryText != "" && in.QueryText != "full") {
			value = nil // an empty literal ('') is a value and is kept
		}
		out = append(out, Row{
			"kind": "set", "dbid": dbid, "datname": datname, "userid": userid, "rolname": rolname,
			"queryid": queryid, "toplevel": top, "command": p.Command, "setting": p.Setting, "value": value,
			"value_hidden": p.Hidden, "planner": p.Planner, "calls": calls, "query": query,
		})
	}
	return out, rows.Err()
}

// sessionSet is one parsed SET, SET LOCAL or RESET.
type sessionSet struct {
	Command string // SET | SET LOCAL | RESET
	Setting string // lower case; 'all' for RESET ALL
	Value   string // as written, quotes removed, comments dropped; empty for RESET or a hidden value
	Hidden  bool   // the value carries a $n (pg_stat_statements on PostgreSQL 17 and later normalizes it)
	Planner bool
}

// monitorSetupSettings are the settings pgvigil itself SETs on a monitored instance: its session setup (collect.go's
// sessionSetup, read from that text so the two cannot drift), the index read's search_path (indexes.go) and the
// Explain action's plan_cache_mode (plans/explain.go; its statement_timeout is the setup's). Under the monitor's role
// these rows are its own, not the application's. TestMonitorSetupSettings scans the sources for any other SET.
var monitorSetupSettings = func() map[string]bool {
	m := map[string]bool{"search_path": true, "plan_cache_mode": true}
	for _, stmt := range strings.Split(sessionSetup, ";") {
		if p, ok := parseSessionSet(stmt); ok {
			m[p.Setting] = true
		}
	}
	return m
}()

// stripComments drops the comments of one statement text (a leading hint, a trailing note, a sqlcommenter suffix):
// -- to the end of its line and /* */ (nested, as the server reads them), each replaced by a space; a marker inside a
// quoted value ('a -- b') or a quoted name ("x/*y*/") is text and stays. An E'...' string's backslash escapes and a
// $$...$$ string are not read as quoting here (a marker inside them is dropped): a setting's value in those forms
// has not been seen, and the earlier regexp did the same.
func stripComments(text string) string {
	var b strings.Builder
	b.Grow(len(text))
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == '\'' || c == '"':
			j := i + 1
			for j < len(text) {
				if text[j] == c {
					if j+1 < len(text) && text[j+1] == c { // a doubled quote inside the literal
						j += 2
						continue
					}
					break
				}
				j++
			}
			if j < len(text) {
				j++ // the closing quote
			}
			b.WriteString(text[i:j])
			i = j
		case c == '-' && i+1 < len(text) && text[i+1] == '-':
			j := strings.IndexByte(text[i:], '\n')
			if j < 0 {
				j = len(text) - i
			}
			b.WriteByte(' ')
			i += j
		case c == '/' && i+1 < len(text) && text[i+1] == '*':
			depth, j := 1, i+2
			for j < len(text) && depth > 0 {
				switch {
				case text[j] == '/' && j+1 < len(text) && text[j+1] == '*':
					depth++
					j += 2
				case text[j] == '*' && j+1 < len(text) && text[j+1] == '/':
					depth--
					j += 2
				default:
					j++
				}
			}
			b.WriteByte(' ')
			i = j
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}

var (
	setSpace = regexp.MustCompile(`\s+`)
	// SET [SESSION | LOCAL] name {= | TO} value; a name is an identifier, a quoted one, or a qualified pair
	setAssign = regexp.MustCompile(`(?is)^set\s+(?:(session|local)\s+)?("(?:[^"]|"")+"|[a-z_][a-z0-9_$]*(?:\.[a-z_][a-z0-9_$]*)?)\s*(?:=|\bto\b)\s*(.*?)\s*;?\s*$`)
	// SET [SESSION | LOCAL] TIME ZONE value, SCHEMA value, NAMES value: the three spellings of timezone, search_path and client_encoding
	setSpecial = regexp.MustCompile(`(?is)^set\s+(?:(session|local)\s+)?(time\s+zone|schema|names)\s+(.*?)\s*;?\s*$`)
	resetCmd   = regexp.MustCompile(`(?is)^reset\s+("(?:[^"]|"")+"|[a-z_][a-z0-9_$]*(?:\.[a-z_][a-z0-9_$]*)?)\s*;?\s*$`)
	paramRef   = regexp.MustCompile(`\$\d+`)
)

// parseSessionSet reads one pg_stat_statements text. SET TRANSACTION, SET SESSION CHARACTERISTICS, SET CONSTRAINTS,
// SET ROLE, SET SESSION AUTHORIZATION and anything else that is not a setting change give false. SET x TO DEFAULT is
// a RESET (it restores the role's or the server's value).
func parseSessionSet(text string) (sessionSet, bool) {
	s := strings.TrimSpace(stripComments(text))
	if m := resetCmd.FindStringSubmatch(s); m != nil {
		name := unquoteIdent(m[1])
		if name == "session" || name == "role" { // RESET SESSION AUTHORIZATION is not a setting (and does not match), RESET ROLE neither
			return sessionSet{}, false
		}
		return sessionSet{Command: "RESET", Setting: name, Planner: isPlannerSetting(name)}, true
	}
	if m := setSpecial.FindStringSubmatch(s); m != nil {
		name := map[string]string{"time zone": "timezone", "schema": "search_path", "names": "client_encoding"}[strings.ToLower(setSpace.ReplaceAllString(m[2], " "))]
		return newSessionSet(m[1], name, m[3]), true
	}
	if m := setAssign.FindStringSubmatch(s); m != nil {
		name := unquoteIdent(m[2])
		switch name {
		case "transaction", "constraints", "role", "session":
			return sessionSet{}, false
		}
		return newSessionSet(m[1], name, m[3]), true
	}
	return sessionSet{}, false
}

func newSessionSet(scope, name, raw string) sessionSet {
	p := sessionSet{Command: "SET", Setting: name, Planner: isPlannerSetting(name)}
	if strings.EqualFold(scope, "local") {
		p.Command = "SET LOCAL"
	}
	v := strings.TrimSpace(raw)
	if strings.EqualFold(v, "default") {
		return sessionSet{Command: "RESET", Setting: name, Planner: p.Planner}
	}
	if paramRef.MatchString(v) {
		p.Hidden = true // the value, or part of it, is a $n: not known
		return p
	}
	if len(v) >= 2 && v[0] == '\'' && v[len(v)-1] == '\'' && !strings.Contains(v, ",") {
		v = strings.ReplaceAll(v[1:len(v)-1], "''", "'")
	}
	p.Value = v
	return p
}

// unquoteIdent: a setting's name, lower case (the server matches setting names without regard to case, quoted or not)
func unquoteIdent(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		s = strings.ReplaceAll(s[1:len(s)-1], `""`, `"`)
	}
	return strings.ToLower(s)
}

// isPlannerSetting: the settings that change a plan (task 58's list, settled; the lead added the last three on
// 2026-11-09): enable_*, *_cost, work_mem, jit, join_collapse_limit, from_collapse_limit, geqo*, plan_cache_mode,
// default_statistics_target, effective_cache_size, hash_mem_multiplier, max_parallel_workers_per_gather. search_path is
// not one (it changes which table a name means, not how a plan is made).
func isPlannerSetting(name string) bool {
	switch name {
	case "work_mem", "jit", "join_collapse_limit", "from_collapse_limit", "plan_cache_mode", "default_statistics_target",
		"effective_cache_size", "hash_mem_multiplier", "max_parallel_workers_per_gather":
		return true
	}
	return strings.HasPrefix(name, "enable_") || strings.HasSuffix(name, "_cost") || strings.HasPrefix(name, "geqo")
}
