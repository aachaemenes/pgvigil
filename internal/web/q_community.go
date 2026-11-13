package web

// Community tools (task 170, task 93 (a); DBA Dash's Community Tools): a page that runs a community procedure a DBA
// INSTALLED on a SQL Server instance and shows its result sets in pgvigil's grid - sp_WhoIsActive, the First Responder
// Kit, Erik Darling's procedures - with each procedure's own parameters as a form (read from sys.parameters of the
// installed copy, described from its @help where it has one); Glenn Berry's diagnostic queries from the DBA's own copy
// of his script (pgvigil ships none of their text: the page reads the file the DBA picks, the server cuts it at his
// "(Query n) (name)" lines and runs the query the DBA picks); and on a PostgreSQL instance pgvigil's own diagnostic
// reads (written after the ideas of the tools docs/customreports.md names).
//
//	GET  /api/community?instance=N&database=D   the tools for the instance's engine, each with its state before any
//	     [&fresh=1]                             click (ready, a note, what it lacks and how to get it, not checked, a
//	                                            demo instance), the form values it presets, and the instance's log;
//	                                            the checks answer within 5 s and are kept 60 s (fresh=1: again)
//	POST /api/community/params                  {instance_id, tool, database}: the procedure's parameters, its @help
//	                                            result sets and the parameters pgvigil leaves out (a run of @help = 1 is
//	                                            audited like any run)
//	POST /api/community/run                     {instance_id, tool, database, params, timeout_secs, text, query_name}
//	POST /api/community/glenn/parse             {text: the script}: its queries {n, name, about, text}
//
// pgvigil never installs a procedure: a missing one says where to get it. A run goes through the instance's read
// login (SQL Server: refused for a sysadmin; PostgreSQL: the monitoring login, refused for a superuser or a member of
// the server file and program roles), under the run's timeout (at most 60 s) and a 2 s lock timeout, and is written to
// pgvigil.custom_report_log (op community_run, community_help) before the answer; behind the UI login and the
// X-Pgvigil header like the custom reports (customReportsOff). A procedure's parameters that write a table (the First
// Responder Kit's @Output*Name, Erik Darling's @log_*, sp_WhoIsActive's @destination_table and @return_schema) and its
// OUTPUT parameters are left out of the form and refused in a run: pgvigil reads, it never writes through a procedure.
// A community procedure runs as itself (no transaction around it: several of them refuse one, and a read login has
// nothing to roll back); a Glenn Berry query and a PostgreSQL read run inside a transaction rolled back, as a custom
// report does.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	mssqldb "github.com/microsoft/go-mssqldb"
)

// communityTool is one entry of the catalogue.
type communityTool struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Group       string `json:"group"`
	Engine      string `json:"engine"` // sqlserver | postgres
	Kind        string `json:"kind"`   // proc | script | query
	URL         string `json:"url"`
	Description string `json:"description"`
	Help        string `json:"help,omitempty"` // the procedure's help parameter, "" = none
	// a PostgreSQL read: its SQL and its parameters (pgvigil's own)
	SQL    string        `json:"-"`
	Params []reportParam `json:"params,omitempty"`
}

const (
	urlWhoIsActive = "https://github.com/amachanic/sp_whoisactive"
	urlFRK         = "https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit"
	urlDarling     = "https://github.com/erikdarlingdata/DarlingData"
	urlGlenn       = "https://glennsqlperformance.com/resources/"
)

func dflt(s string) *string { return &s }

var communityTools = []communityTool{
	{ID: "sp_WhoIsActive", Name: "sp_WhoIsActive", Group: "sp_WhoIsActive", Engine: "sqlserver", Kind: "proc", URL: urlWhoIsActive, Help: "@help",
		Description: "What runs now: each request with its statement, waits, blocking, tempdb and plan."},
	{ID: "sp_Blitz", Name: "sp_Blitz", Group: "First Responder Kit", Engine: "sqlserver", Kind: "proc", URL: urlFRK, Help: "@Help",
		Description: "The server's health check: a prioritized list of configuration and reliability findings."},
	{ID: "sp_BlitzFirst", Name: "sp_BlitzFirst", Group: "First Responder Kit", Engine: "sqlserver", Kind: "proc", URL: urlFRK, Help: "@Help",
		Description: "Why the server is slow right now: waits, file IO and perfmon counters over a few seconds."},
	{ID: "sp_BlitzCache", Name: "sp_BlitzCache", Group: "First Responder Kit", Engine: "sqlserver", Kind: "proc", URL: urlFRK, Help: "@Help",
		Description: "The plan cache's most expensive queries with the warnings of their plans."},
	{ID: "sp_BlitzIndex", Name: "sp_BlitzIndex", Group: "First Responder Kit", Engine: "sqlserver", Kind: "proc", URL: urlFRK, Help: "@Help",
		Description: "A database's index design: missing, unused, duplicate and over-wide indexes."},
	{ID: "sp_BlitzLock", Name: "sp_BlitzLock", Group: "First Responder Kit", Engine: "sqlserver", Kind: "proc", URL: urlFRK, Help: "@Help",
		Description: "The deadlocks system_health (or an Extended Events file) recorded, analysed."},
	{ID: "sp_BlitzWho", Name: "sp_BlitzWho", Group: "First Responder Kit", Engine: "sqlserver", Kind: "proc", URL: urlFRK, Help: "@Help",
		Description: "What runs now, the First Responder Kit's way."},
	{ID: "sp_PressureDetector", Name: "sp_PressureDetector", Group: "Darling Data", Engine: "sqlserver", Kind: "proc", URL: urlDarling, Help: "@help",
		Description: "CPU and memory pressure: waits, memory grants, schedulers and the queries behind them."},
	{ID: "sp_QuickieStore", Name: "sp_QuickieStore", Group: "Darling Data", Engine: "sqlserver", Kind: "proc", URL: urlDarling, Help: "@help",
		Description: "Query Store's top queries by a metric over a window, with their plans and waits."},
	{ID: "sp_HumanEventsBlockViewer", Name: "sp_HumanEventsBlockViewer", Group: "Darling Data", Engine: "sqlserver", Kind: "proc", URL: urlDarling, Help: "@help",
		Description: "The blocked-process reports an Extended Events session captured, as blocking chains."},
	{ID: "sp_HealthParser", Name: "sp_HealthParser", Group: "Darling Data", Engine: "sqlserver", Kind: "proc", URL: urlDarling, Help: "@help",
		Description: "The system_health session read: waits, CPU, memory, IO, locking and deadlock events."},
	{ID: "sp_LogHunter", Name: "sp_LogHunter", Group: "Darling Data", Engine: "sqlserver", Kind: "proc", URL: urlDarling, Help: "@help",
		Description: "The error log searched for the messages that matter, archives included."},
	{ID: "sp_IndexCleanup", Name: "sp_IndexCleanup", Group: "Darling Data", Engine: "sqlserver", Kind: "proc", URL: urlDarling, Help: "@help",
		Description: "Unused and duplicate indexes with the script to remove or merge them (shown, never run)."},
	{ID: "glenn_berry", Name: "SQL Server Diagnostic Queries", Group: "Glenn Berry", Engine: "sqlserver", Kind: "script", URL: urlGlenn,
		Description: "Glenn Berry's diagnostic queries from your own copy of his script for the server's version: pick the file, then a query."},

	{ID: "pg_running", Name: "Running now", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "Every session that is not idle: its state, wait, blocking pids, how long, and the statement.",
		Params:      []reportParam{{Name: "min_secs", Type: "number", Label: "running at least (seconds)", Default: dflt("0")}},
		SQL: `SELECT a.pid, a.usename AS "user", a.datname AS database, a.application_name, a.client_addr::text AS client, a.state,
       a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid) AS blocked_by,
       round(extract(epoch FROM now() - a.query_start)::numeric, 1) AS running_secs,
       round(extract(epoch FROM now() - a.xact_start)::numeric, 1) AS xact_secs, a.backend_type, left(a.query, 4000) AS query
  FROM pg_stat_activity a
 WHERE a.state IS DISTINCT FROM 'idle' AND a.pid <> pg_backend_pid()
   AND coalesce(extract(epoch FROM now() - a.query_start), 0) >= coalesce(@min_secs::float8, 0)
 ORDER BY a.query_start NULLS LAST`},
	{ID: "pg_blocking", Name: "Blocking tree", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "Who blocks whom now: each blocked session with its blockers, and the heads (blocking, not blocked) first.",
		SQL: `WITH b AS (SELECT a.pid, pg_blocking_pids(a.pid) AS blocked_by FROM pg_stat_activity a),
     heads AS (SELECT DISTINCT unnest(blocked_by) AS pid FROM b)
SELECT a.pid, CASE WHEN cardinality(b.blocked_by) = 0 THEN 'head' ELSE 'blocked' END AS role, b.blocked_by,
       (SELECT count(*) FROM b x WHERE a.pid = ANY (x.blocked_by)) AS blocks, a.usename AS "user", a.datname AS database,
       a.state, a.wait_event_type, a.wait_event, round(extract(epoch FROM now() - a.xact_start)::numeric, 1) AS xact_secs,
       left(a.query, 4000) AS query
  FROM pg_stat_activity a JOIN b USING (pid)
 WHERE cardinality(b.blocked_by) > 0 OR a.pid IN (SELECT pid FROM heads)
 ORDER BY cardinality(b.blocked_by), a.xact_start NULLS LAST`},
	{ID: "pg_top_statements", Name: "Top statements", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "pg_stat_statements' statements by total time since its last reset (the extension in this database).",
		Params:      []reportParam{{Name: "top", Type: "int", Label: "rows", Default: dflt("50")}},
		SQL: `SELECT s.queryid, r.rolname AS "user", d.datname AS database, s.calls, round(s.total_exec_time::numeric, 1) AS total_ms,
       round(s.mean_exec_time::numeric, 2) AS mean_ms, s.rows, s.shared_blks_read, s.shared_blks_hit, s.temp_blks_written,
       left(s.query, 4000) AS query
  FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid LEFT JOIN pg_database d ON d.oid = s.dbid
 ORDER BY s.total_exec_time DESC LIMIT coalesce(@top, 50)`},
	{ID: "pg_table_sizes", Name: "Largest tables", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "This database's largest tables: the table, its indexes and its TOAST, with live and dead rows.",
		Params:      []reportParam{{Name: "top", Type: "int", Label: "rows", Default: dflt("50")}},
		SQL: `SELECT n.nspname AS schema, c.relname AS "table", pg_total_relation_size(c.oid) AS total_bytes,
       pg_relation_size(c.oid) AS heap_bytes, pg_indexes_size(c.oid) AS index_bytes,
       coalesce(pg_total_relation_size(c.reltoastrelid), 0) AS toast_bytes, s.n_live_tup AS live_rows, s.n_dead_tup AS dead_rows,
       s.last_autovacuum, s.last_autoanalyze
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
 WHERE c.relkind IN ('r', 'p', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_toast'
 ORDER BY pg_total_relation_size(c.oid) DESC LIMIT coalesce(@top, 50)`},
	{ID: "pg_unused_indexes", Name: "Unused indexes", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "Indexes of this database never scanned since the statistics reset, not behind a constraint, the largest first.",
		SQL: `SELECT s.schemaname AS schema, s.relname AS "table", s.indexrelname AS index, pg_relation_size(s.indexrelid) AS index_bytes,
       s.idx_scan, (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()) AS stats_reset
  FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
 WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
   AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = s.indexrelid)
 ORDER BY pg_relation_size(s.indexrelid) DESC`},
	{ID: "pg_duplicate_indexes", Name: "Duplicate indexes", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "Indexes of this database with the same table, columns, operator classes, expressions and predicate.",
		SQL: `SELECT n.nspname AS schema, t.relname AS "table", array_agg(x.relname ORDER BY x.relname) AS indexes,
       sum(pg_relation_size(x.oid)) AS total_bytes
  FROM pg_index i JOIN pg_class x ON x.oid = i.indexrelid JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
 GROUP BY n.nspname, t.relname, i.indrelid, i.indkey::text, i.indclass::text, i.indcollation::text,
          coalesce(pg_get_expr(i.indexprs, i.indrelid), ''), coalesce(pg_get_expr(i.indpred, i.indrelid), '')
HAVING count(*) > 1
 ORDER BY sum(pg_relation_size(x.oid)) DESC`},
	{ID: "pg_invalid_indexes", Name: "Invalid indexes", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "Indexes of this database left invalid (a failed CREATE INDEX CONCURRENTLY): written to, never used.",
		SQL: `SELECT n.nspname AS schema, t.relname AS "table", x.relname AS index, pg_relation_size(x.oid) AS index_bytes,
       pg_get_indexdef(x.oid) AS definition
  FROM pg_index i JOIN pg_class x ON x.oid = i.indexrelid JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE NOT i.indisvalid ORDER BY 1, 2, 3`},
	{ID: "pg_xmin_horizon", Name: "What holds back vacuum", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "The oldest transaction horizons: sessions, replication slots and prepared transactions, the oldest first.",
		SQL: `SELECT 'session' AS holder, a.pid::text AS name, a.usename AS "user", a.datname AS database, age(a.backend_xmin) AS xmin_age,
       a.xact_start AS since, a.state
  FROM pg_stat_activity a WHERE a.backend_xmin IS NOT NULL
UNION ALL
SELECT 'replication slot', s.slot_name, NULL, s.database, greatest(age(s.xmin), age(s.catalog_xmin)), NULL,
       CASE WHEN s.active THEN 'active' ELSE 'inactive' END
  FROM pg_replication_slots s WHERE s.xmin IS NOT NULL OR s.catalog_xmin IS NOT NULL
UNION ALL
SELECT 'prepared transaction', p.gid, p.owner, p.database, age(p.transaction), p.prepared, NULL
  FROM pg_prepared_xacts p
 ORDER BY xmin_age DESC NULLS LAST`},
	{ID: "pg_settings_changed", Name: "Settings changed", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "Every setting not at its built-in default, where it was set, and those waiting for a restart.",
		SQL: `SELECT name, setting, unit, boot_val, source, sourcefile, sourceline, pending_restart, short_desc
  FROM pg_settings WHERE source NOT IN ('default', 'override') OR pending_restart ORDER BY pending_restart DESC, name`},
	{ID: "pg_sequences", Name: "Sequences near their end", Group: "pgvigil reads", Engine: "postgres", Kind: "query",
		Description: "This database's sequences by the share of their range used (a sequence the login cannot read shows no value).",
		Params:      []reportParam{{Name: "min_pct", Type: "number", Label: "used at least (%)", Default: dflt("50")}},
		SQL: `SELECT schemaname AS schema, sequencename AS sequence, data_type::text, last_value, max_value, increment_by, cycle,
       round(100.0 * (last_value - min_value) / nullif(max_value - min_value, 0), 2) AS used_pct
  FROM pg_sequences
 WHERE last_value IS NULL OR 100.0 * (last_value - min_value) / nullif(max_value - min_value, 0) >= coalesce(@min_pct::float8, 0)
 ORDER BY used_pct DESC NULLS LAST`},
}

func findTool(id string) *communityTool {
	for i := range communityTools {
		if communityTools[i].ID == id {
			return &communityTools[i]
		}
	}
	return nil
}

// writeParam: a procedure parameter that makes it write a table (or return a schema for one), or send what it read to
// a service outside the server (sp_BlitzCache's @AI... calls sp_invoke_external_rest_endpoint); pgvigil leaves it out.
// The First Responder Kit's @Output...DatabaseName / SchemaName / TableName / ServerName, @LogMessage... (sp_BlitzFirst
// INSERTs the message) and @WriteBackupsToDatabaseName; Erik Darling's @log_...; sp_WhoIsActive's @destination_table and
// @return_schema.
var writeParam = regexp.MustCompile(`(?i)^@(output_?(database|schema|table|server)|log_|logmessage|ai[a-z]*$|writebackups|destination_table|return_schema|delete_retention)`)

// msQuote is QUOTENAME of one part.
func msQuote(s string) string { return "[" + strings.ReplaceAll(s, "]", "]]") + "]" }

// communityDB checks the database a request names ("" = the engine's default: master on SQL Server, the login's own
// database on PostgreSQL).
func communityDB(s string) (string, error) {
	s = strings.TrimSpace(s)
	if len(s) > 128 || strings.ContainsAny(s, "\x00\r\n") {
		return "", errors.New("database is a database name of at most 128 characters")
	}
	return s, nil
}

// msDB is the SQL Server database a procedure is looked for in: the request's, default master.
func msDB(s string) string {
	if s == "" {
		return "master"
	}
	return s
}

// procParam is one parameter of an installed procedure.
type procParam struct {
	Name      string `json:"name"`
	Type      string `json:"type"`
	MaxLength int    `json:"max_length"`
	Help      string `json:"help,omitempty"`
}

// readProcParams reads the procedure's parameters in db (the OUTPUT ones, the writing ones and its help switch apart).
func readProcParams(ctx context.Context, conn *sql.Conn, db, proc, help string) (params []procParam, left []string, found bool, err error) {
	q := `SELECT p.name, TYPE_NAME(p.user_type_id), CAST(p.max_length AS int), CAST(p.is_output AS int)
  FROM ` + msQuote(db) + `.sys.parameters p WHERE p.object_id = OBJECT_ID(@obj, 'P') ORDER BY p.parameter_id`
	var id sql.NullInt64
	if err := conn.QueryRowContext(ctx, `SELECT OBJECT_ID(@obj, 'P')`, sql.Named("obj", msQuote(db)+".[dbo]."+msQuote(proc))).Scan(&id); err != nil {
		return nil, nil, false, err
	}
	if !id.Valid {
		return nil, nil, false, nil
	}
	rows, err := conn.QueryContext(ctx, q, sql.Named("obj", msQuote(db)+".[dbo]."+msQuote(proc)))
	if err != nil {
		return nil, nil, true, err
	}
	defer func() { _ = rows.Close() }()
	params, left = []procParam{}, []string{}
	for rows.Next() {
		var p procParam
		var out int
		if err := rows.Scan(&p.Name, &p.Type, &p.MaxLength, &out); err != nil {
			return nil, nil, true, err
		}
		if out == 1 || writeParam.MatchString(p.Name) || (help != "" && strings.EqualFold(p.Name, help)) {
			left = append(left, p.Name)
			continue
		}
		params = append(params, p)
	}
	return params, left, true, rows.Err()
}

// helpText reads parameter descriptions out of @help's result sets: a column named like a parameter name and one
// named like a description, matched case-blind on the parameter's name with or without its @. The parameter cell's
// first word is the name (sp_WhoIsActive writes the whole declaration: the name, its type and its default), and a row with an empty
// parameter cell carries on the description of the row before it (sp_WhoIsActive wraps a description over rows).
func helpText(sets []resultSet) map[string]string {
	out := map[string]string{}
	for _, s := range sets {
		pc, dc := -1, -1
		for i, c := range s.Columns {
			l := strings.ToLower(c)
			switch {
			case pc < 0 && strings.Contains(l, "param"):
				pc = i
			case dc < 0 && strings.Contains(l, "desc"):
				dc = i
			}
		}
		if pc < 0 || dc < 0 {
			continue
		}
		last := ""
		for _, r := range s.Rows {
			if pc >= len(r) || dc >= len(r) {
				continue
			}
			n, _ := r[pc].(string)
			d, _ := r[dc].(string)
			d = strings.TrimSpace(d)
			if f := strings.Fields(n); len(f) > 0 {
				n = strings.ToLower(strings.TrimPrefix(strings.TrimRight(f[0], ","), "@"))
			} else {
				n = ""
			}
			switch {
			case n == "" && last != "" && d != "":
				out[last] = strings.TrimSpace(out[last] + " " + d)
			case n != "" && reportParamName.MatchString(n):
				last = n
				if d != "" {
					out[n] = d
				}
			default:
				last = "" // a separator row ("-----")
			}
		}
	}
	return out
}

// msArg types a form value by the parameter's SQL Server type; "" = not passed (the procedure's default).
func msArg(p procParam, v string) (any, error) {
	v = strings.TrimSpace(v)
	switch strings.ToLower(p.Type) {
	case "int", "bigint", "smallint", "tinyint":
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("%s is %s: %q is not a whole number", p.Name, p.Type, v)
		}
		return n, nil
	case "bit":
		switch strings.ToLower(v) {
		case "1", "true", "yes", "on":
			return true, nil
		case "0", "false", "no", "off":
			return false, nil
		}
		return nil, fmt.Errorf("%s is bit: %q is not 1 or 0", p.Name, v)
	case "float", "real":
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			return nil, fmt.Errorf("%s is %s: %q is not a number", p.Name, p.Type, v)
		}
		return f, nil
	}
	return v, nil // the server converts the text to the parameter's type (a date, a decimal, a uniqueidentifier)
}

// communityInstance is an instance's name and engine.
func (s *Server) communityInstance(ctx context.Context, id int) (name, engine string, err error) {
	err = s.pool.QueryRow(ctx, `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name, &engine)
	return name, engine, err
}

const sqlCommunityLog = `
SELECT log_id, at, ui_user, client, op, tool, instance, outcome, detail, rows, duration_ms, statement
  FROM pgvigil.custom_report_log WHERE op IN ('community_run', 'community_help') AND instance_id = $1
 ORDER BY at DESC, log_id DESC LIMIT 100`

type toolState struct {
	communityTool
	Installed *bool  `json:"installed"`
	Where     string `json:"where,omitempty"`
	// the tool's state here, said before any click: ready | note (it runs, a note beside it) | needs (off: what it
	// lacks) | not_checked (off: a check failed or ran out of time) | demo (off: a demo instance has no server)
	State string     `json:"state"`
	On    bool       `json:"on"`
	Needs []toolNeed `json:"needs"`
	// form values the page fills in before the click (a parameter's name with its @): the run the procedure's own
	// defaults would make is one it declines or one that reads nothing here
	Preset map[string]string `json:"preset,omitempty"`
}

// toolNeed is one thing a tool lacks before it can run here, in the page's words: what is missing and the way to get
// it. A hard need keeps the tool off (its words beside it and as its description); a note sits beside a tool that
// still runs. How is a field of its own (a GRANT line, a configuration key, the login's name): what to ask the
// administrator of the server for, never a statement pgvigil runs.
type toolNeed struct {
	What   string     `json:"what"`
	How    string     `json:"how,omitempty"`
	Hard   bool       `json:"hard"`
	State  string     `json:"state"`            // needs | note | not_checked | demo
	Source string     `json:"source,omitempty"` // server | configuration | repository | live: where the fact was read
	ReadAt *time.Time `json:"read_at,omitempty"`
}

func hardNeed(what, how, source string) toolNeed {
	return toolNeed{What: what, How: how, Hard: true, State: "needs", Source: source}
}

func noteNeed(what, how, source string) toolNeed {
	return toolNeed{What: what, How: how, State: "note", Source: source}
}

// notChecked: a check that failed, was refused or ran out of time; the tool stays off (never ready on a guess).
func notChecked(what string) toolNeed {
	return toolNeed{What: "not checked: " + what, Hard: true, State: "not_checked", Source: "live"}
}

// communityOff is what this server lacks for any community tool to run, with the way to get it; nil = nothing.
func (s *Server) communityOff() *toolNeed {
	w := s.communityOffWords()
	if w == "" {
		return nil
	}
	how := "the repository dsn of the configuration, a login in pgvigil_collector (docs/customreports.md); serve's log names why it did not connect"
	switch {
	case s.auth == nil:
		how = "run pgvigil serve with the configuration file and without -no-login, and add a user with 'pgvigil user add <name>' (pgvigil demo -serve has no login)"
	case s.actions == nil:
		how = "serve with the configuration file: its repository dsn is the actions door's audit login (docs/customreports.md)"
	}
	n := hardNeed(w, how, "server")
	return &n
}

// communityOffWords is serverOff in the Community tools page's words, "" = nothing missing.
func (s *Server) communityOffWords() string {
	if w := s.serverOff(); w != "" {
		return "Running a tool needs " + w + "."
	}
	return ""
}

// checkBudget: the GET waits this long for the checks of one instance and database (a var for the unit tests only)
var checkBudget = 5 * time.Second

const (
	checkKeep = 60 * time.Second // their answer is kept this long
	checkMax  = 30 * time.Second // a check that outlives the GET ends in the background within this
)

// communityCheck is what the checks of one instance and database found.
type communityCheck struct {
	At        time.Time
	DB        string                       // the database the tools are looked for in (SQL Server: master by default)
	Inst      []toolNeed                   // what stops every tool here
	Tools     map[string][]toolNeed        // each tool's own needs and notes
	Installed map[string]bool              // SQL Server: the procedures found in DB (nil = not read)
	Preset    map[string]map[string]string // each tool's form values
}

type checkKey struct {
	s  *Server
	id int
	db string
}

type checkEntry struct {
	done  chan struct{} // closed once res and end are set
	res   *communityCheck
	start time.Time // monotonic, as end: a clock step never stretches the keep
	end   time.Time
	seen  bool // a GET was answered with res (under communityCache's lock)
}

// communityCache keeps each instance's and database's checks checkKeep; one check at a time per instance and database.
var communityCache = struct {
	sync.Mutex
	m map[checkKey]*checkEntry
}{m: map[checkKey]*checkEntry{}}

// checkRunMax bounds the checks running at once (each holds a connection to a monitored instance): a GET that would
// start one more is answered 'not checked'.
const checkRunMax = 16

// checks answers the checks of an instance and database within checkBudget: a kept answer younger than checkKeep,
// the answer of the check already running, or a new check's. fresh (Look again) starts a new check unless the kept
// answer was never shown (a check that outlived an earlier GET's budget: its answer is the one Look again was asked
// for). A check that outlives the budget gives 'not checked' now and keeps its own answer for the next view when it
// ends; a second check never starts while one runs.
func (s *Server) checks(ctx context.Context, k checkKey, name string, fresh bool, run func(context.Context) *communityCheck) *communityCheck {
	communityCache.Lock()
	e := communityCache.m[k]
	start := e == nil
	if e != nil {
		select {
		case <-e.done:
			start = time.Since(e.end) > checkKeep || (fresh && e.seen)
		default: // running: its answer, never a second check of the same instance - unless it outlived its own cap
			start = time.Since(e.start) > checkMax+checkBudget
		}
	}
	if start {
		running := 0
		for key, x := range communityCache.m {
			select {
			case <-x.done:
				if time.Since(x.end) > checkKeep {
					delete(communityCache.m, key)
				}
			default:
				if time.Since(x.start) <= checkMax+checkBudget {
					running++
				}
			}
		}
		if running >= checkRunMax {
			communityCache.Unlock()
			return &communityCheck{At: time.Now().UTC(), DB: k.db, Tools: map[string][]toolNeed{},
				Inst: []toolNeed{notChecked(fmt.Sprintf("pgvigil is running %d checks of community tools already: Look again in a moment", running))}}
		}
		e = &checkEntry{done: make(chan struct{}), start: time.Now()}
		communityCache.m[k] = e
		go func(e *checkEntry) {
			cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), checkMax)
			defer cancel()
			var res *communityCheck
			defer func() {
				// a check that breaks says so on the page and never takes the server down with it
				if p := recover(); p != nil {
					s.log.Error("community tools: a check broke", "instance", name, "panic", p)
					res = &communityCheck{DB: k.db, Tools: map[string][]toolNeed{}, Inst: []toolNeed{notChecked(fmt.Sprintf("the checks of %s broke (%v): serve's log has it", name, p))}}
				}
				e.end = time.Now()
				res.At = e.end.UTC()
				e.res = res
				close(e.done)
			}()
			res = run(cctx)
		}(e)
	}
	communityCache.Unlock()
	t := time.NewTimer(checkBudget)
	defer t.Stop()
	select {
	case <-e.done:
		communityCache.Lock()
		e.seen = true
		communityCache.Unlock()
		return e.res
	case <-t.C:
	case <-ctx.Done():
	}
	return &communityCheck{At: time.Now().UTC(), DB: k.db, Tools: map[string][]toolNeed{},
		Inst: []toolNeed{notChecked(fmt.Sprintf("the checks of %s took over %d s; they go on in the background: Look again in a moment", name, int(checkBudget/time.Second)))}}
}

// frkProcs are the First Responder Kit's procedures (8.34, 2026-07-02) sp_Blitz's version check runs when they are
// installed beside it (its FRKComponents list), looked for with the tools.
var frkProcs = []string{"sp_Blitz", "sp_BlitzBackups", "sp_BlitzCache", "sp_BlitzFirst", "sp_BlitzIndex", "sp_BlitzLock", "sp_BlitzWho", "sp_DatabaseRestore", "sp_ineachdb"}

// sibling is a procedure a tool runs itself. Hard: a run with the form's defaults fails without EXECUTE on it (each
// pair decided by a run with the right revoked: scripts/proof-customreports.sh part N); otherwise a note.
type sibling struct {
	Proc string
	Hard bool
	How  string // where the tool runs it
}

// toolSiblings: First Responder Kit 8.34 (2026-07-02), read from its source: sp_Blitz's version check runs each FRK
// procedure installed beside it with @VersionCheckMode = 1 and its database checks run sp_ineachdb; sp_BlitzFirst runs
// sp_BlitzWho and sp_BlitzCache, sp_BlitzIndex runs sp_BlitzCache. DarlingData's tools (*.11, 2026-11-01) run none.
var toolSiblings = map[string][]sibling{
	"sp_Blitz": {
		{"sp_BlitzBackups", true, "its version check"}, {"sp_BlitzCache", true, "its version check"},
		{"sp_BlitzFirst", true, "its version check"}, {"sp_BlitzIndex", true, "its version check"},
		{"sp_BlitzLock", true, "its version check"}, {"sp_BlitzWho", true, "its version check"},
		{"sp_DatabaseRestore", true, "its version check"}, {"sp_ineachdb", true, "its version check and its database checks"},
	},
	"sp_BlitzFirst": {{"sp_BlitzWho", false, "with @ExpertMode or an output table"}, {"sp_BlitzCache", false, "with @ExpertMode or an output table"}},
	"sp_BlitzIndex": {{"sp_BlitzCache", false, "for its sp_BlitzCache sort"}},
}

const sessionKeeper = "keeper_HumanEvents_blocking" // sp_HumanEventsBlockViewer's default @session_name

// grantLine is what to ask for so user (the login's user in db, "" = none there) may EXECUTE proc in db.
func grantLine(db, user, login, proc string) string {
	s := "USE " + msQuote(db) + "; "
	if user == "" {
		s += "CREATE USER " + msQuote(login) + " FOR LOGIN " + msQuote(login) + "; "
		user = login
	}
	return s + "GRANT EXECUTE ON " + proc + " TO " + msQuote(user) + ";"
}

// msChecks reads on the instance's read login what the SQL Server tools need: the login's own rights, the server's
// state and its settings live; the databases with Query Store on from the repository when a collection holds them
// (their read's time beside them). A read that fails leaves the tools it decides 'not checked', off.
func (s *Server) msChecks(ctx context.Context, id int, name, dsn, db string) *communityCheck {
	c := &communityCheck{DB: msDB(db), Tools: map[string][]toolNeed{}, Preset: map[string]map[string]string{}}
	add := func(tool string, n toolNeed) { c.Tools[tool] = append(c.Tools[tool], n) }
	procTools := []string{}
	for _, t := range communityTools {
		if t.Engine == "sqlserver" && t.Kind == "proc" {
			procTools = append(procTools, t.Name)
		}
	}
	allTools := func(n toolNeed) {
		for _, p := range procTools {
			add(p, n)
		}
	}
	dbc, conn, why, err := openMS(ctx, dsn, "pgvigil-community")
	if err != nil {
		c.Inst = append(c.Inst, notChecked("the connection to "+name+" on its read login failed: "+err.Error()))
		return c
	}
	if why != "" { // a sysadmin: openMS closed the connection itself and hands back none
		c.Inst = append(c.Inst, hardNeed(why, "give the instance a read login that is not a sysadmin (docs/sqlserver.md)", "live"))
		return c
	}
	defer func() { _ = conn.Close(); _ = dbc.Close() }()
	var edition, major int
	var current, login string
	if err := conn.QueryRowContext(ctx, `SELECT CAST(SERVERPROPERTY('EngineEdition') AS int),
       CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), 4) AS int), DB_NAME(), SUSER_SNAME()`).Scan(&edition, &major, &current, &login); err != nil {
		allTools(notChecked("reading the edition and version of " + name + " failed: " + err.Error()))
		return c
	}
	azure := edition == 5
	if azure { // Azure SQL Database refuses a three-part name (Msg 40515): the database the connection opens
		c.DB = current
	}
	// the kits' procedures in DB, EXECUTE on each for this login, and the login's user there
	seen, names := map[string]bool{}, []string{}
	for _, p := range append(append([]string{}, procTools...), frkProcs...) {
		if !seen[p] {
			seen[p] = true
			names = append(names, "N'"+p+"'") // the catalogue's own names: letters and _ only
		}
	}
	from := msQuote(c.DB) + ".sys.procedures AS p JOIN " + msQuote(c.DB) + ".sys.schemas AS s ON s.schema_id = p.schema_id"
	obj := "N'" + strings.ReplaceAll(msQuote(c.DB), "'", "''") + ".[dbo].' + QUOTENAME(p.name)"
	user := "(SELECT name FROM " + msQuote(c.DB) + ".sys.database_principals WHERE sid = SUSER_SID())"
	if azure {
		from, obj, user = "sys.procedures AS p JOIN sys.schemas AS s ON s.schema_id = p.schema_id", "N'[dbo].' + QUOTENAME(p.name)", "USER_NAME()"
	}
	q := `SELECT p.name, ISNULL(HAS_PERMS_BY_NAME(` + obj + `, N'OBJECT', N'EXECUTE'), 0), ISNULL(` + user + `, N'')
  FROM ` + from + ` WHERE s.name = N'dbo' AND p.name IN (` + strings.Join(names, ", ") + `)`
	installed, canExec, dbUser := map[string]bool{}, map[string]bool{}, ""
	rows, err := conn.QueryContext(ctx, q)
	if err == nil {
		for rows.Next() {
			var n, u string
			var x int
			if err = rows.Scan(&n, &x, &u); err != nil {
				break
			}
			installed[strings.ToLower(n)], canExec[strings.ToLower(n)], dbUser = true, x == 1, u
		}
		if err == nil {
			err = rows.Err()
		}
		_ = rows.Close()
	}
	if err != nil {
		allTools(notChecked("reading the procedures of " + c.DB + " failed: " + err.Error()))
		return c
	}
	c.Installed = installed
	for _, t := range communityTools {
		if t.Engine != "sqlserver" || t.Kind != "proc" {
			continue
		}
		key := strings.ToLower(t.Name)
		switch {
		case !installed[key]:
			add(t.Name, hardNeed(t.Name+" is not in "+c.DB+" as the read login sees it: name the database it is installed in above, or install it from "+t.URL+" (pgvigil never installs one); a login without EXECUTE or VIEW DEFINITION on a procedure does not see it", "", "live"))
		case !canExec[key]:
			add(t.Name, hardNeed("EXECUTE on "+c.DB+".dbo."+t.Name+" for the read login "+login+": it has none", grantLine(c.DB, dbUser, login, "dbo."+msQuote(t.Name)), "live"))
		}
		for _, sb := range toolSiblings[t.Name] {
			k := strings.ToLower(sb.Proc)
			if !installed[k] || canExec[k] {
				continue
			}
			what := t.Name + " runs " + sb.Proc + " (" + sb.How + ") and the read login " + login + " has no EXECUTE on it"
			if sb.Hard {
				add(t.Name, hardNeed(what+": a run fails there", grantLine(c.DB, dbUser, login, "dbo."+msQuote(sb.Proc)), "live"))
			} else {
				add(t.Name, noteNeed(what+": a run that reaches it fails", grantLine(c.DB, dbUser, login, "dbo."+msQuote(sb.Proc)), "live"))
			}
		}
	}
	// sp_BlitzCache cannot run from a database below compatibility level 130: its own check refuses there (frk 8.34
	// L14536), and in 8.34 its OPENJSON does not even compile there first (Msg 102, L19554: the mssql sandbox at 120)
	if installed["sp_blitzcache"] {
		var compat int
		if err := conn.QueryRowContext(ctx, `SELECT ISNULL((SELECT CONVERT(int, compatibility_level) FROM sys.databases WHERE name = @p1), -1)`, c.DB).Scan(&compat); err != nil {
			add("sp_BlitzCache", notChecked("reading the compatibility level of "+c.DB+" failed: "+err.Error()))
		} else if compat >= 0 && compat < 130 {
			add("sp_BlitzCache", hardNeed("sp_BlitzCache cannot run from a database below compatibility level 130: "+c.DB+" is at "+strconv.Itoa(compat),
				"install sp_BlitzCache in master (the kit's own advice), or raise "+c.DB+"'s compatibility level", "live"))
		}
	}
	if azure {
		add("sp_LogHunter", hardNeed("sp_LogHunter does not run on Azure SQL Database: the procedure refuses the platform", "", "live"))
		add("sp_HealthParser", hardNeed("sp_HealthParser does not run on Azure SQL Database: the procedure refuses the platform", "", "live"))
		add("sp_HumanEventsBlockViewer", notChecked("the blocked process report's sessions are not read on Azure SQL Database"))
		add("sp_IndexCleanup", noteNeed("on Azure SQL Database sp_IndexCleanup refuses @get_all_databases: name a database in @database_name", "", "live"))
		return c
	}
	if major > 0 && major < 11 {
		for _, p := range []string{"sp_IndexCleanup", "sp_BlitzLock"} {
			add(p, hardNeed(p+" needs SQL Server 2012 or later; "+name+" is version "+strconv.Itoa(major), "", "live"))
		}
	}
	if major > 0 && major < 13 { // sp_BlitzCache prints 'doesn't work on versions of SQL prior to 2016' and returns nothing
		add("sp_BlitzCache", hardNeed("sp_BlitzCache needs SQL Server 2016 or later; "+name+" is version "+strconv.Itoa(major), "", "live"))
	}
	// the server's rights and settings, live: what this login may read, and what it reaches
	var canRead, rds, secAdmin, viewState, viewErrorLog, reach, liveThreshold int
	var masterUser, firstUserDB string
	err = conn.QueryRowContext(ctx, `SELECT ISNULL(HAS_PERMS_BY_NAME(N'master.dbo.xp_readerrorlog', N'OBJECT', N'EXECUTE'), 0),
       CASE WHEN OBJECT_ID(N'rdsadmin.dbo.rds_read_error_log', N'P') IS NULL THEN 0 ELSE 1 END,
       ISNULL((SELECT TOP (1) name FROM master.sys.database_principals WHERE sid = SUSER_SID()), N''),
       ISNULL(IS_SRVROLEMEMBER(N'securityadmin'), 0),
       ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW SERVER STATE'), 0), ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, N'VIEW ANY ERROR LOG'), 0),
       (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4 AND state = 0 AND is_read_only = 0 AND is_in_standby = 0 AND HAS_DBACCESS(name) = 1),
       ISNULL((SELECT CONVERT(int, c.value_in_use) FROM sys.configurations AS c WHERE c.name = N'blocked process threshold (s)'), -1),
       ISNULL((SELECT TOP (1) name FROM sys.databases WHERE database_id > 4 AND state = 0 AND is_read_only = 0 AND is_in_standby = 0 AND HAS_DBACCESS(name) = 1 ORDER BY name), N'')`).Scan(
		&canRead, &rds, &masterUser, &secAdmin, &viewState, &viewErrorLog, &reach, &liveThreshold, &firstUserDB)
	if err != nil {
		for _, p := range []string{"sp_LogHunter", "sp_IndexCleanup", "sp_HumanEventsBlockViewer", "sp_QuickieStore"} {
			add(p, notChecked("reading the read login's rights on "+name+" failed: "+err.Error()))
		}
		return c
	}
	// sp_LogHunter's own test (HAS_PERMS_BY_NAME, NULL as no; Amazon RDS's reader excepted)
	switch {
	case canRead == 0 && rds == 0:
		add("sp_LogHunter", hardNeed("EXECUTE on xp_readerrorlog for the read login "+login+": sp_LogHunter reads the error log through it and refuses without it",
			grantLine("master", masterUser, login, "sys.xp_readerrorlog"), "live"))
	// the archived logs are listed through sp_enumerrorlogs: securityadmin, and from SQL Server 2022 VIEW SERVER STATE or
	// VIEW ANY ERROR LOG (the mssql sandbox, 16.0: either lists them, neither is refused 27219)
	case rds == 0 && secAdmin == 0 && !(major >= 16 && (viewState == 1 || viewErrorLog == 1)):
		way := "securityadmin"
		if major >= 16 {
			way = "VIEW SERVER STATE, VIEW ANY ERROR LOG or securityadmin"
		}
		add("sp_LogHunter", noteNeed("reads the current error log only: the archived logs are listed through sp_enumerrorlogs, which needs "+way, "", "live"))
	}
	switch {
	case reach == 0:
		add("sp_IndexCleanup", hardNeed("a user database the read login can reach: "+name+" has none online, writable and not in standby with access for "+login+" (sp_IndexCleanup skips read-only and standby databases)",
			"give the read login access to the databases to check (CONNECT ANY DATABASE, or a user in each)", "live"))
	case isSystemDB(c.DB):
		// its own default reads the database it is installed in and skips a system database: a default click from
		// there is always declined ('No valid databases found to process.')
		c.Preset["sp_IndexCleanup"] = map[string]string{"@database_name": firstUserDB}
		add("sp_IndexCleanup", noteNeed("sp_IndexCleanup's own default reads the database it is installed in ("+c.DB+"), a system database it skips: the form reads "+firstUserDB+"; @get_all_databases = 1 reads every database the login reaches", "", "live"))
	}
	s.blockViewerPreset(ctx, conn, c, id, liveThreshold, add)
	s.quickieStorePreset(ctx, conn, c, id, name, add)
	return c
}

// isSystemDB: the four system databases (and Amazon RDS's rdsadmin), which sp_IndexCleanup skips.
func isSystemDB(db string) bool {
	switch strings.ToLower(db) {
	case "master", "model", "msdb", "tempdb", "rdsadmin":
		return true
	}
	return false
}

// blockViewerPreset: sp_HumanEventsBlockViewer's form follows what exists, so a click with it is never one the
// procedure declines: the blocked process report off (threshold 0) or no running session capturing it = system_health
// with a note; its default session running = its own default; another running session capturing it = that one.
func (s *Server) blockViewerPreset(ctx context.Context, conn *sql.Conn, c *communityCheck, id, liveThreshold int, add func(string, toolNeed)) {
	const tool = "sp_HumanEventsBlockViewer"
	// the live value read with the login's rights wins (the collection reads it hourly: a change since would turn the
	// preset into a declined click); the repository's only when the live read found none
	threshold, src := liveThreshold, "live"
	var readAt *time.Time
	var v int64
	var at time.Time
	if threshold < 0 && s.pool.QueryRow(ctx, `SELECT value_in_use, snapshot_at FROM pgvigil.mssql_config
 WHERE instance_id = $1 AND name = 'blocked process threshold (s)' AND is_present AND value_in_use IS NOT NULL`, id).Scan(&v, &at) == nil {
		threshold, src, readAt = int(v), "repository", &at
	}
	if threshold < 0 {
		add(tool, notChecked("the blocked process threshold could not be read"))
		return
	}
	const health = "system_health holds only the blocking sp_server_diagnostics recorded in it (the procedure calls it 'the lousy version')"
	if threshold == 0 {
		c.Preset[tool] = map[string]string{"@session_name": "system_health"}
		n := noteNeed("the blocked process report is off on this server (blocked process threshold 0): the form reads system_health, and "+health,
			"a DBA turns it on: EXECUTE sys.sp_configure 'show advanced options', 1; EXECUTE sys.sp_configure 'blocked process threshold', 5; RECONFIGURE; and runs a session that captures the blocked process report", src)
		n.ReadAt = readAt
		add(tool, n)
		return
	}
	rows, err := conn.QueryContext(ctx, `SELECT ses.name, CASE WHEN EXISTS (SELECT 1 FROM sys.server_event_session_events AS e
         WHERE e.event_session_id = ses.event_session_id AND e.name = N'blocked_process_report') THEN 1 ELSE 0 END
  FROM sys.server_event_sessions AS ses JOIN sys.dm_xe_sessions AS dxs ON dxs.name = ses.name
 WHERE dxs.create_time IS NOT NULL ORDER BY ses.name`)
	keeper, other := false, ""
	if err == nil {
		for rows.Next() {
			var n string
			var bpr int
			if err = rows.Scan(&n, &bpr); err != nil {
				break
			}
			switch {
			case n == sessionKeeper:
				keeper = true
			case bpr == 1 && other == "" && !strings.EqualFold(n, "system_health"):
				other = n
			}
		}
		if err == nil {
			err = rows.Err()
		}
		_ = rows.Close()
	}
	switch {
	case err != nil:
		add(tool, notChecked("reading the running Extended Events sessions failed: "+err.Error()))
	case keeper: // the procedure's own default
	case other != "":
		c.Preset[tool] = map[string]string{"@session_name": other}
		add(tool, noteNeed(sessionKeeper+" (the procedure's default session) is not running: the form reads "+other+", a running session that captures the blocked process report", "", "live"))
	default:
		c.Preset[tool] = map[string]string{"@session_name": "system_health"}
		add(tool, noteNeed("no running session captures the blocked process report: name one in @session_name or ask the DBA to create one; until then the form reads system_health, and "+health,
			"a DBA creates and starts a session with the event sqlserver.blocked_process_report (sp_HumanEvents @event_type = 'blocking', @keep_alive = 1 makes "+sessionKeeper+")", "live"))
	}
}

// quickieStorePreset: sp_QuickieStore reads Query Store of one database (its own by default: where it is installed,
// where Query Store is never on in master); the form names a database where it is on, from the repository's read.
func (s *Server) quickieStorePreset(ctx context.Context, conn *sql.Conn, c *communityCheck, id int, name string, add func(string, toolNeed)) {
	const tool = "sp_QuickieStore"
	var on []string
	var readAt *time.Time
	var stores int
	var last *time.Time
	src := "repository"
	if err := s.pool.QueryRow(ctx, `SELECT count(*), max(snapshot_at) FROM pgvigil.mssql_qs_store WHERE instance_id = $1`, id).Scan(&stores, &last); err == nil && stores > 0 {
		readAt = last
		rows, err := s.pool.Query(ctx, `SELECT database_name FROM pgvigil.mssql_qs_store
 WHERE instance_id = $1 AND actual_state IN ('READ_WRITE', 'READ_ONLY') AND database_name NOT IN ('master', 'model', 'msdb', 'tempdb')
 ORDER BY database_name`, id)
		if err == nil {
			on, err = pgx.CollectRows(rows, pgx.RowTo[string])
		}
		if err != nil {
			add(tool, noteNeed("where Query Store is on was not read: "+err.Error(), "", "repository"))
			return
		}
	} else {
		src = "live"
		rows, err := conn.QueryContext(ctx, `SELECT name FROM sys.databases WHERE is_query_store_on = 1 AND state = 0 AND database_id > 4 ORDER BY name`)
		if err == nil {
			for rows.Next() {
				var n string
				if err = rows.Scan(&n); err != nil {
					break
				}
				on = append(on, n)
			}
			if err == nil {
				err = rows.Err()
			}
			_ = rows.Close()
		}
		if err != nil {
			add(tool, noteNeed("where Query Store is on was not read: "+err.Error(), "", "live"))
			return
		}
	}
	for _, d := range on {
		if strings.EqualFold(d, c.DB) {
			return
		}
	}
	var n toolNeed
	if len(on) == 0 {
		n = noteNeed("Query Store is on in no database of "+name+": sp_QuickieStore answers 'Query Store not enabled'", "a DBA turns it on per database: ALTER DATABASE [<db>] SET QUERY_STORE = ON;", src)
	} else {
		c.Preset[tool] = map[string]string{"@database_name": on[0]}
		n = noteNeed("Query Store is on in "+strings.Join(on, ", ")+", not in "+c.DB+": the form reads "+on[0], "", src)
	}
	n.ReadAt = readAt
	add(tool, n)
}

// pgChecks connects as the monitoring login to the database a run would use (read-only, as a run does) and reads
// what the reads need: a login a run would refuse (a superuser or a server-file role) is the instance's need; Top
// statements needs pg_stat_statements created in that database (pg_extension, schema-qualified), its view readable
// (42501) and its library loaded at start (55000, met only by running its function), and pg_read_all_stats for other
// users' text. A failed read is 'not checked'.
func (s *Server) pgChecks(ctx context.Context, name, dsn, db string) *communityCheck {
	c := &communityCheck{DB: db, Tools: map[string][]toolNeed{}, Preset: map[string]map[string]string{}}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		c.Inst = append(c.Inst, hardNeed("the monitoring login's dsn for "+name+" does not parse", "correct the instance's dsn in the configuration file", "configuration"))
		return c
	}
	if db != "" {
		cfg.Database = db
	}
	cfg.ConnectTimeout = checkBudget
	cfg.RuntimeParams["application_name"] = "pgvigil-community"
	cfg.RuntimeParams["default_transaction_read_only"] = "on"
	cfg.RuntimeParams["statement_timeout"] = "4000"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		c.Inst = append(c.Inst, notChecked("the connection to "+name+" on its monitoring login failed: "+err.Error()))
		return c
	}
	// the close and the rollback have their own deadline: a server that hangs between statements never holds the
	// check's goroutine and its socket past it
	defer func() {
		cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), checkBudget)
		defer cancel()
		_ = conn.Close(cctx)
	}()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		c.Inst = append(c.Inst, notChecked("a read-only transaction on "+name+" failed: "+err.Error()))
		return c
	}
	defer func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), checkBudget)
		defer cancel()
		_ = tx.Rollback(rctx)
	}()
	why, err := pgRefusal(ctx, tx)
	if err != nil {
		c.Inst = append(c.Inst, notChecked(err.Error()))
		return c
	}
	if why != "" {
		c.Inst = append(c.Inst, hardNeed("a monitoring login a run accepts: "+why, "give the instance a login in pg_monitor without those roles", "live"))
		return c
	}
	const tool = "pg_top_statements"
	var cur string
	var stats bool
	var schema *string
	if err := tx.QueryRow(ctx, `SELECT current_database(), pg_has_role(current_user, 'pg_read_all_stats', 'USAGE'),
       (SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_stat_statements')`).Scan(&cur, &stats, &schema); err != nil {
		c.Tools[tool] = []toolNeed{notChecked("reading the extensions of " + name + " failed: " + err.Error())}
		return c
	}
	c.DB = cur
	ask := "ask a superuser-class role (superuser, rds_superuser, azure_pg_admin, cloudsqlsuperuser) to run CREATE EXTENSION pg_stat_statements; in " + cur + " (the monitoring login cannot)"
	if schema == nil {
		c.Tools[tool] = []toolNeed{hardNeed("pg_stat_statements is not created in the database "+cur, ask, "live")}
		return c
	}
	// two probes: the view with LIMIT 0 meets its SELECT right (42501) without running its function; the function
	// itself, one row, meets the library not loaded at start (55000), which a LIMIT 0 read of the view never runs into
	_, err = tx.Exec(ctx, `SAVEPOINT pgvigil_probe`)
	if err == nil {
		_, err = tx.Exec(ctx, `SELECT 1 FROM `+pgx.Identifier{*schema, "pg_stat_statements"}.Sanitize()+` LIMIT 0`)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `SELECT 1 FROM `+pgx.Identifier{*schema, "pg_stat_statements"}.Sanitize()+`(false) LIMIT 1`)
	}
	var pe *pgconn.PgError
	switch {
	case err == nil:
	case errors.As(err, &pe) && pe.Code == "55000":
		c.Tools[tool] = []toolNeed{hardNeed("pg_stat_statements is created in "+cur+" but not loaded: "+pe.Message,
			"ask the DBA to add pg_stat_statements to shared_preload_libraries and restart the server (Amazon RDS: the DB parameter group; Azure flexible server: azure.extensions and shared_preload_libraries, then a restart)", "live")}
		return c
	case errors.As(err, &pe) && pe.Code == "42501":
		c.Tools[tool] = []toolNeed{hardNeed("reading "+*schema+".pg_stat_statements is refused to the monitoring login: "+pe.Message, "GRANT SELECT ON "+pgx.Identifier{*schema, "pg_stat_statements"}.Sanitize()+" TO <the monitoring login>; (and EXECUTE on its function pg_stat_statements(boolean), PUBLIC by default)", "live")}
		return c
	default:
		c.Tools[tool] = []toolNeed{notChecked("reading " + *schema + ".pg_stat_statements failed: " + err.Error())}
		return c
	}
	if !stats {
		c.Tools[tool] = []toolNeed{noteNeed("other users' statements show no text: the monitoring login is not in pg_read_all_stats (pg_monitor holds it)", "GRANT pg_read_all_stats TO <the monitoring login>; (a DBA)", "live")}
	}
	return c
}

// Community is GET /api/community?instance=N&database=D[&fresh=1].
func (s *Server) Community(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	db, err := communityDB(r.URL.Query().Get("database"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	name, engine, err := s.communityInstance(ctx, id)
	if err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	var demo bool
	if err := s.pool.QueryRow(ctx, `SELECT 'demo' = ANY (tags) FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&demo); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	out := struct {
		Enabled  bool        `json:"enabled"`
		Reason   string      `json:"reason,omitempty"`
		Instance string      `json:"instance"`
		Engine   string      `json:"engine"`
		Database string      `json:"database,omitempty"`
		Demo     bool        `json:"demo"`
		Tools    []toolState `json:"tools"`
		Log      *table      `json:"log"`
		// what every tool here lacks before it can run (the server's state, the instance's login), with the way to get it
		Needs     []toolNeed `json:"needs"`
		CheckedAt *time.Time `json:"checked_at,omitempty"`
	}{Instance: name, Engine: engine, Tools: []toolState{}, Needs: []toolNeed{}}
	for _, t := range communityTools {
		if t.Engine == engine {
			out.Tools = append(out.Tools, toolState{communityTool: t, Needs: []toolNeed{}})
		}
	}
	door := s.pgDoorDSN(name)
	if engine == "sqlserver" {
		door = s.msDoorDSN(name)
		out.Database = msDB(db)
	}
	var c *communityCheck
	switch {
	case demo && door == "":
		// a demo instance: invented by pgvigil demo, no server behind it (its tag and no login; never the process)
		out.Demo = true
		out.Needs = append(out.Needs, toolNeed{What: name + " is a demo instance: pgvigil demo invented its data and no server stands behind it, so no tool runs here.",
			How: "on a real install each tool runs on the instance's read login (docs/customreports.md)", Hard: true, State: "demo", Source: "repository"})
	case door == "":
		// the server's own state first: without the UI login no door is kept for a PostgreSQL instance either, so the
		// configuration line would be false there (the actions door keeps the logins only behind the login)
		if n := s.communityOff(); n != nil {
			out.Needs = append(out.Needs, *n)
			break
		}
		login := "read login"
		if engine == "postgres" {
			login = "monitoring login"
		}
		out.Needs = append(out.Needs, hardNeed("a "+login+" for "+name+": this server holds none for it (pgvigil serve takes each instance's login from its configuration file)",
			"give the instance a dsn in the configuration file with a login that is not a sysadmin or superuser, and serve with that file (docs/sqlserver.md, docs/configuration.md)", "configuration"))
	default:
		if n := s.communityOff(); n != nil {
			out.Needs = append(out.Needs, *n)
		}
		// the cache's database is the one the checks read: on SQL Server '' (the default) and master are one entry
		kdb := db
		if engine == "sqlserver" {
			kdb = msDB(db)
		}
		c = s.checks(ctx, checkKey{s, id, kdb}, name, r.URL.Query().Get("fresh") == "1", func(cctx context.Context) *communityCheck {
			if engine == "sqlserver" {
				return s.msChecks(cctx, id, name, door, db)
			}
			return s.pgChecks(cctx, name, door, db)
		})
		at := c.At
		out.CheckedAt = &at
		out.Needs = append(out.Needs, c.Inst...)
		if c.DB != "" {
			out.Database = c.DB
		}
	}
	for i := range out.Tools {
		t := &out.Tools[i]
		if c != nil {
			if n := c.Tools[t.ID]; n != nil { // a procedure's id is its name
				t.Needs = n
			}
			if c.Installed != nil && t.Kind == "proc" {
				yes := c.Installed[strings.ToLower(t.Name)]
				t.Installed = &yes
				if yes {
					t.Where = out.Database + ".dbo"
				}
			}
			t.Preset = c.Preset[t.ID]
		}
		t.State = "ready"
		for _, n := range append(append([]toolNeed{}, out.Needs...), t.Needs...) {
			if n.Hard {
				t.State = n.State
				break
			}
			if n.State == "note" {
				t.State = "note"
			}
		}
		t.On = t.State == "ready" || t.State == "note"
	}
	for _, n := range out.Needs {
		if n.Hard {
			out.Reason = n.What
			break
		}
	}
	out.Enabled = out.Reason == ""
	out.Log, err = s.query(ctx, sqlCommunityLog, id)
	s.reply(w, r, out, err)
}

type communityBody struct {
	InstanceID  int               `json:"instance_id"`
	Tool        string            `json:"tool"`
	Database    string            `json:"database"`
	Params      map[string]string `json:"params"`
	TimeoutSecs int               `json:"timeout_secs"`
	Text        string            `json:"text"`
	QueryName   string            `json:"query_name"`
}

// communityGate is a POST's shared part: the gate, the body, the tool, the instance of the tool's engine.
func (s *Server) communityGate(w http.ResponseWriter, r *http.Request) (in communityBody, user, name string, t *communityTool, ok bool) {
	user, raw, ok := s.gate(w, r, 256<<10, s.communityOffWords)
	if !ok {
		return in, "", "", nil, false
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return in, "", "", nil, false
	}
	if t = findTool(in.Tool); t == nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("no community tool %q", in.Tool))
		return in, "", "", nil, false
	}
	var engine string
	var err error
	if name, engine, err = s.communityInstance(r.Context(), in.InstanceID); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", in.InstanceID))
		return in, "", "", nil, false
	}
	if engine != t.Engine {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("%s is a %s tool and instance %s is %s", t.Name, t.Engine, name, engine))
		return in, "", "", nil, false
	}
	if in.Database, err = communityDB(in.Database); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return in, "", "", nil, false
	}
	if in.TimeoutSecs == 0 {
		in.TimeoutSecs = 60
	}
	if in.TimeoutSecs < 1 || in.TimeoutSecs > 60 {
		writeErr(w, http.StatusBadRequest, errors.New("timeout_secs is 1 to 60"))
		return in, "", "", nil, false
	}
	return in, user, name, t, true
}

// CommunityParams is POST /api/community/params: an installed procedure's form.
func (s *Server) CommunityParams(w http.ResponseWriter, r *http.Request) {
	in, user, name, t, ok := s.communityGate(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), runBudget)
	defer cancel()
	out := struct {
		Tool      string        `json:"tool"`
		Installed bool          `json:"installed"`
		Params    []procParam   `json:"params"`
		Left      []string      `json:"left_out"`
		HelpSets  []resultSet   `json:"help_sets"`
		HelpError string        `json:"help_error,omitempty"`
		Static    []reportParam `json:"static_params,omitempty"`
	}{Tool: t.ID, Params: []procParam{}, Left: []string{}, HelpSets: []resultSet{}}
	if t.Kind != "proc" {
		out.Installed, out.Static = true, t.Params
		s.reply(w, r, out, nil)
		return
	}
	if err := s.mayAudit(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err)
		return
	}
	dbc, conn, why, err := openMS(ctx, s.msDoorDSN(name), "pgvigil-community")
	if why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return
	}
	if err != nil {
		writeErr(w, http.StatusBadGateway, err)
		return
	}
	defer func() { _ = conn.Close(); _ = dbc.Close() }()
	in.Database = msDB(in.Database)
	params, left, found, err := readProcParams(ctx, conn, in.Database, t.Name, t.Help)
	if err != nil {
		writeErr(w, http.StatusBadGateway, fmt.Errorf("the parameters of %s could not be read: %v", t.Name, err))
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, fmt.Errorf("%s is not installed in %s on %s: pgvigil never installs it; get it from %s", t.Name, in.Database, name, t.URL))
		return
	}
	out.Installed, out.Params, out.Left = true, params, left
	if t.Help != "" {
		stmt := "EXEC " + msQuote(in.Database) + ".[dbo]." + msQuote(t.Name) + " " + t.Help + " = 1"
		t0 := time.Now()
		hctx, hcancel := context.WithTimeout(ctx, 30*time.Second)
		rows, err := conn.QueryContext(hctx, stmt)
		var sets []resultSet
		if err == nil {
			sets, err = readMS(rows, 2000, &sizer{}, hcancel)
		}
		hcancel()
		run := instanceRun{Instance: name}
		run.finish(t0, sets, "", err)
		if err != nil {
			out.HelpError = err.Error()
		}
		out.HelpSets = run.Sets
		descs := helpText(run.Sets)
		for i := range out.Params {
			out.Params[i].Help = descs[strings.ToLower(strings.TrimPrefix(out.Params[i].Name, "@"))]
		}
		actx, acancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
		defer acancel()
		if err := s.auditRun(actx, map[string]any{"op": "community_help", "ui_user": user, "client": clientIP(r), "tool": t.ID,
			"instance_id": in.InstanceID, "instance": name, "outcome": run.Outcome, "detail": run.Error, "rows": run.Rows,
			"duration_ms": run.DurationMS, "statement": stmt}); err != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the run's audit row could not be written (%v): its rows are withheld", err))
			return
		}
	}
	s.reply(w, r, out, nil)
}

// CommunityRun is POST /api/community/run.
func (s *Server) CommunityRun(w http.ResponseWriter, r *http.Request) {
	in, user, name, t, ok := s.communityGate(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), runBudget)
	defer cancel()
	if err := s.mayAudit(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err)
		return
	}
	timeout := time.Duration(in.TimeoutSecs) * time.Second
	run := instanceRun{InstanceID: in.InstanceID, Instance: name, Engine: t.Engine}
	t0 := time.Now()
	var stmt string
	switch t.Kind {
	case "query":
		dsn := s.pgDoorDSN(name)
		if dsn == "" {
			run.finish(t0, nil, "instance "+name+" has no monitoring login configured on this server", nil)
			break
		}
		cfg, err := pgx.ParseConfig(dsn)
		if err != nil {
			run.finish(t0, nil, "", errors.New("the monitoring dsn does not parse"))
			break
		}
		// a database other than the login's own: the same login on that database
		if in.Database != "" {
			cfg.Database = in.Database
		}
		args := pgx.NamedArgs{}
		for _, p := range t.Params {
			v := in.Params[p.Name]
			x, err := paramValue(p, &v)
			if err != nil {
				s.refuseRun(w, r, map[string]any{"op": "community_run", "ui_user": user, "client": clientIP(r), "tool": t.ID,
					"instance_id": in.InstanceID, "instance": name, "params": map[string]any{"values": in.Params, "database": in.Database}},
					fmt.Errorf("parameter %s %w", p.Name, err))
				return
			}
			args[p.Name] = x
		}
		stmt = t.SQL
		if t.ID == "pg_top_statements" {
			// the view in the schema the extension was created in, whatever the login's search path
			schema, err := pgExtSchema(ctx, cfg, "pg_stat_statements")
			if err != nil {
				run.finish(t0, nil, "", err)
				break
			}
			if schema == "" {
				run.finish(t0, nil, "pg_stat_statements is not created in this database: a superuser-class role runs CREATE EXTENSION pg_stat_statements there", nil)
				break
			}
			stmt = strings.Replace(stmt, "FROM pg_stat_statements s", "FROM "+pgx.Identifier{schema, "pg_stat_statements"}.Sanitize()+" s", 1)
		}
		sets, why, err := runPG(ctx, cfg, stmt, args, timeout, 5000)
		run.finish(t0, sets, why, err)
	case "script":
		text := strings.TrimSpace(in.Text)
		if text == "" || len(text) > 128<<10 {
			s.refuseRun(w, r, map[string]any{"op": "community_run", "ui_user": user, "client": clientIP(r), "tool": t.ID,
				"instance_id": in.InstanceID, "instance": name, "report_name": in.QueryName}, errors.New("text is the query to run, 1 to 128 KB (pick a query of the script)"))
			return
		}
		stmt = text
		if in.Database != "" {
			stmt = "USE " + msQuote(in.Database) + ";\n" + text
		}
		sets, why, err := runMS(ctx, s.msDoorDSN(name), stmt, nil, timeout, 5000, true)
		run.finish(t0, sets, why, err)
	default:
		dsn := s.msDoorDSN(name)
		db, conn, why, err := openMS(ctx, dsn, "pgvigil-community")
		if err != nil || why != "" {
			run.finish(t0, nil, why, err)
			break
		}
		in.Database = msDB(in.Database)
		params, _, found, err := readProcParams(ctx, conn, in.Database, t.Name, t.Help)
		switch {
		case err != nil:
			run.finish(t0, nil, "", fmt.Errorf("the parameters of %s could not be read: %v", t.Name, err))
		case !found:
			run.finish(t0, nil, fmt.Sprintf("%s is not installed in %s on %s: pgvigil never installs it; get it from %s", t.Name, in.Database, name, t.URL), nil)
		}
		if run.Outcome != "" {
			_ = conn.Close()
			_ = db.Close()
			break
		}
		byName := map[string]procParam{}
		for _, p := range params {
			byName[strings.ToLower(strings.TrimPrefix(p.Name, "@"))] = p
		}
		keys := make([]string, 0, len(in.Params))
		for k := range in.Params {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var b strings.Builder
		b.WriteString("EXEC " + msQuote(in.Database) + ".[dbo]." + msQuote(t.Name))
		var args []any
		var bad error
		for _, k := range keys {
			v := in.Params[k]
			if strings.TrimSpace(v) == "" {
				continue
			}
			key := strings.ToLower(strings.TrimPrefix(k, "@"))
			p, ok := byName[key]
			if !ok {
				bad = fmt.Errorf("%s has no parameter @%s pgvigil passes (a parameter that writes a table, an OUTPUT one and @help are left out)", t.Name, key)
				break
			}
			x, err := msArg(p, v)
			if err != nil {
				bad = err
				break
			}
			pn := "p" + strconv.Itoa(len(args)+1)
			if len(args) > 0 {
				b.WriteString(",")
			}
			b.WriteString(" " + p.Name + " = @" + pn)
			args = append(args, sql.Named(pn, x))
		}
		if bad != nil {
			_ = conn.Close()
			_ = db.Close()
			s.refuseRun(w, r, map[string]any{"op": "community_run", "ui_user": user, "client": clientIP(r), "tool": t.ID,
				"instance_id": in.InstanceID, "instance": name, "statement": b.String(), "params": map[string]any{"values": in.Params, "database": in.Database}}, bad)
			return
		}
		stmt = b.String()
		rctx, rcancel := context.WithTimeout(ctx, timeout)
		rows, err := conn.QueryContext(rctx, stmt, args...)
		var sets []resultSet
		if err == nil {
			sets, err = readMS(rows, 5000, &sizer{}, rcancel)
		}
		rcancel()
		_ = conn.Close()
		_ = db.Close()
		run.finish(t0, sets, "", err)
		// the procedure looked at this server and said no in one of its own listed messages, before any result set:
		// still a failed run in the audit (the statement reached the server), drawn as a note
		var me mssqldb.Error
		if errors.As(err, &me) && len(sets) == 0 && declinedBy(t.Name, me) {
			run.Declined = true
			run.Error = fmt.Sprintf("%s declined: %s (msg %d, severity %d)", t.Name, strings.TrimSpace(me.Message), me.Number, me.Class)
		}
	}
	run.Statement = stmt
	actx, acancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
	defer acancel()
	if err := s.auditRun(actx, map[string]any{"op": "community_run", "ui_user": user, "client": clientIP(r), "tool": t.ID,
		"report_name": in.QueryName, "instance_id": in.InstanceID, "instance": name, "outcome": run.Outcome, "detail": run.Error,
		"rows": run.Rows, "duration_ms": run.DurationMS, "statement": stmt, "params": map[string]any{"values": in.Params, "database": in.Database}}); err != nil {
		s.log.Error("community tool: the run's audit row was not written", "tool", t.ID, "instance", name, "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the run's audit row could not be written (%v): its rows are withheld", err))
		return
	}
	s.log.Info("community tool: run", "tool", t.ID, "instance", name, "user", user, "outcome", run.Outcome)
	s.reply(w, r, struct {
		Tool  string        `json:"tool"`
		RanAt time.Time     `json:"ran_at"`
		Runs  []instanceRun `json:"runs"`
	}{t.ID, time.Now().UTC(), []instanceRun{run}}, nil)
}

// declineMsg is one of a procedure's own refusal messages: its text starts with prefix and ends with suffix (a
// message with a %s in its middle).
type declineMsg struct{ prefix, suffix string }

// declines are each kit's own refusal messages, exact from its source with the kit's version beside them: the
// procedure looked at this server (a right, a setting, the platform, nothing to read) and said no before it returned
// anything. Matched only with message 50000 and when no result set was read, only in a procedure's run; anything else
// is a failed run - every RAISERROR with a string is message 50000, and sp_BlitzIndex re-raises any error it catches
// that way (a lock timeout, a deadlock, a permission error inside it stays an error).
var declines = map[string][]declineMsg{
	// DarlingData sp_LogHunter 3.11 (2026-11-01)
	"sp_LogHunter": {{"Current user does not have EXECUTE permission on xp_readerrorlog", ""}, {"This will not run on Azure SQL DB", ""}},
	// DarlingData sp_HumanEventsBlockViewer 5.11 (2026-11-01)
	"sp_HumanEventsBlockViewer": {
		{"Unless you want to use the lousy version in system_health, the blocked process report needs to be enabled", ""},
		{"A session with the name ", "does not exist or is not currently active."},
	},
	// DarlingData sp_IndexCleanup 2.11 (2026-11-01)
	"sp_IndexCleanup": {{"No valid databases found to process.", ""}, {"This procedure requires SQL Server 2012", ""}, {"@get_all_databases is not supported on Azure SQL Database", ""}},
	// DarlingData sp_HealthParser 3.11 (2026-11-01)
	"sp_HealthParser": {{"This won't work in Azure", ""}},
	// DarlingData sp_QuickieStore 6.11 (2026-11-01)
	"sp_QuickieStore": {{"Not all Azure offerings are supported", ""}},
}

// declinedBy: proc's run ended in one of its own listed refusals.
func declinedBy(proc string, me mssqldb.Error) bool {
	if me.Number != 50000 {
		return false
	}
	m := strings.TrimSpace(me.Message)
	for _, d := range declines[proc] {
		if strings.HasPrefix(m, d.prefix) && strings.HasSuffix(m, d.suffix) {
			return true
		}
	}
	return false
}

// pgExtSchema is the schema extension ext was created in, in cfg's database ("" = not created there).
func pgExtSchema(ctx context.Context, cfg *pgx.ConnConfig, ext string) (string, error) {
	cfg = cfg.Copy()
	cfg.ConnectTimeout = 10 * time.Second
	cfg.RuntimeParams["application_name"] = "pgvigil-community"
	cfg.RuntimeParams["default_transaction_read_only"] = "on"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return "", err
	}
	defer func() { _ = conn.Close(context.WithoutCancel(ctx)) }()
	var schema string
	err = conn.QueryRow(ctx, `SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = $1`, ext).Scan(&schema)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return schema, err
}

// glennQuery is one query of a Glenn Berry diagnostic script.
type glennQuery struct {
	N     int    `json:"n"`
	Name  string `json:"name"`
	About string `json:"about"`
	Text  string `json:"text"`
}

var (
	glennMarker = regexp.MustCompile(`^\s*--(.*?)\(Query\s+(\d+)\)\s*\(([^)]*)\)`)
	glennEnd    = regexp.MustCompile(`^\s*-{6,}\s*$`)
	glennGo     = regexp.MustCompile(`(?i)^\s*GO\s*(--.*)?$`)
)

// parseGlenn cuts a diagnostic script at its "-- <what> (Query n) (name)" lines: each query is the text from the line
// after its marker to the next "------" line (or the next marker), its GO lines and trailing comment lines dropped. A
// file that is not UTF-8 is read as Windows-1252's ASCII range with the rest kept as Latin-1 (the scripts are saved
// that way).
func parseGlenn(b []byte) []glennQuery {
	text := string(b)
	if !utf8.Valid(b) {
		rs := make([]rune, len(b))
		for i, c := range b {
			rs[i] = rune(c)
		}
		text = string(rs)
	}
	text = strings.TrimPrefix(text, "\ufeff")
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	var out []glennQuery
	var cur *glennQuery
	var body []string
	flush := func() {
		if cur == nil {
			return
		}
		for len(body) > 0 {
			l := strings.TrimSpace(body[len(body)-1])
			if l == "" || strings.HasPrefix(l, "--") {
				body = body[:len(body)-1]
				continue
			}
			break
		}
		cur.Text = strings.TrimSpace(strings.Join(body, "\n"))
		if cur.Text != "" {
			out = append(out, *cur)
		}
		cur, body = nil, nil
	}
	for _, l := range lines {
		if m := glennMarker.FindStringSubmatch(l); m != nil {
			flush()
			n, _ := strconv.Atoi(m[2])
			cur = &glennQuery{N: n, Name: strings.TrimSpace(m[3]), About: strings.TrimSpace(m[1])}
			continue
		}
		if cur == nil {
			continue
		}
		if glennEnd.MatchString(l) {
			flush()
			continue
		}
		if glennGo.MatchString(l) {
			continue
		}
		body = append(body, l)
	}
	flush()
	if out == nil {
		out = []glennQuery{}
	}
	return out
}

// CommunityGlennParse is POST /api/community/glenn/parse: the script's text in, its queries out. Nothing is stored and
// nothing is run.
func (s *Server) CommunityGlennParse(w http.ResponseWriter, r *http.Request) {
	_, raw, ok := s.gate(w, r, 6<<20, s.communityOffWords)
	if !ok {
		return
	}
	// the page sends {"text": the file}; a bare text body is read as it is
	var in struct {
		Text *string `json:"text"`
	}
	if json.Unmarshal(raw, &in) == nil && in.Text != nil {
		raw = []byte(*in.Text)
	}
	qs := parseGlenn(raw)
	if len(qs) == 0 {
		writeErr(w, http.StatusBadRequest, errors.New("the file holds no '(Query n) (name)' lines: it is not one of Glenn Berry's diagnostic query scripts"))
		return
	}
	s.reply(w, r, struct {
		Queries []glennQuery `json:"queries"`
	}{qs}, nil)
}
