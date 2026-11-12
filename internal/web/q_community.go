package web

// Community tools (task 170, task 93 (a); DBA Dash's Community Tools): a page that runs a community procedure a DBA
// INSTALLED on a SQL Server instance and shows its result sets in pgvigil's grid - sp_WhoIsActive, the First Responder
// Kit, Erik Darling's procedures - with each procedure's own parameters as a form (read from sys.parameters of the
// installed copy, described from its @help where it has one); Glenn Berry's diagnostic queries from the DBA's own copy
// of his script (pgvigil ships none of their text: the page reads the file the DBA picks, the server cuts it at his
// "(Query n) (name)" lines and runs the query the DBA picks); and on a PostgreSQL instance pgvigil's own diagnostic
// reads (written after the ideas of the tools docs/customreports.md names).
//
//	GET  /api/community?instance=N&database=D   the tools for the instance's engine, each with installed (SQL Server:
//	                                            the procedure in database D, default master), and the instance's log
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
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
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
}

// Community is GET /api/community?instance=N&database=D.
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
	out := struct {
		Enabled  bool        `json:"enabled"`
		Reason   string      `json:"reason,omitempty"`
		Instance string      `json:"instance"`
		Engine   string      `json:"engine"`
		Database string      `json:"database,omitempty"`
		Error    string      `json:"error,omitempty"`
		Tools    []toolState `json:"tools"`
		Log      *table      `json:"log"`
	}{Instance: name, Engine: engine, Tools: []toolState{}}
	out.Reason = s.customReportsOff()
	for _, t := range communityTools {
		if t.Engine == engine {
			out.Tools = append(out.Tools, toolState{communityTool: t})
		}
	}
	switch {
	case engine == "sqlserver":
		db = msDB(db)
		out.Database = db
		dsn := s.msDoorDSN(name)
		if dsn == "" {
			out.Reason = firstNonEmpty(out.Reason, "instance "+name+" has no read login configured on this server")
			break
		}
		dbc, conn, why, err := openMS(ctx, dsn, "pgvigil-community")
		if err != nil || why != "" {
			out.Reason = firstNonEmpty(out.Reason, why)
			if err != nil {
				out.Error = err.Error()
			}
			break
		}
		names := []string{}
		for _, t := range out.Tools {
			if t.Kind == "proc" {
				names = append(names, "N'"+t.Name+"'") // the catalogue's own names: letters and _ only
			}
		}
		found := map[string]bool{}
		rows, err := conn.QueryContext(ctx, `SELECT name FROM `+msQuote(db)+`.sys.procedures WHERE name IN (`+strings.Join(names, ", ")+`)`)
		if err == nil {
			for rows.Next() {
				var n string
				if rows.Scan(&n) == nil {
					found[strings.ToLower(n)] = true
				}
			}
			err = rows.Err()
			_ = rows.Close()
		}
		_ = conn.Close()
		_ = dbc.Close()
		if err != nil {
			out.Error = "the procedures of " + db + " could not be read: " + err.Error()
			break
		}
		for i := range out.Tools {
			if out.Tools[i].Kind == "proc" {
				yes := found[strings.ToLower(out.Tools[i].Name)]
				out.Tools[i].Installed = &yes
				if yes {
					out.Tools[i].Where = db + ".dbo"
				}
			}
		}
	case s.pgDoorDSN(name) == "":
		out.Reason = firstNonEmpty(out.Reason, "instance "+name+" has no monitoring login configured on this server")
	}
	out.Enabled = out.Reason == ""
	out.Log, err = s.query(ctx, sqlCommunityLog, id)
	s.reply(w, r, out, err)
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
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
	user, raw, ok := s.reportGate(w, r, 256<<10)
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
	_, raw, ok := s.reportGate(w, r, 6<<20)
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
