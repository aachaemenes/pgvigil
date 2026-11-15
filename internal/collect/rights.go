package collect

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// The rights pgvigil's monitoring login needs on a PostgreSQL server (the ServiceConfig takes, ST2; the twin of
// internal/mssql/rights.go): each right with the collectors' own check, what needs it and the statement that gives
// it. ReadRights asks the server, as that login, which it holds; the statements of the missing ones are PRINTED for
// an administrator to run - pgvigil never grants anything.
//
// Held in step with the collectors by TestRightsCatalogueNamesEveryCheck: a pg_has_role or has_*_privilege the
// package's statements ask about is named here or among the listed exceptions. The exceptions say what the catalogue
// does not cover: an extension's own functions (its collection's skip names the GRANT), the actions and custom
// doors' checks, and privileges read as data about the server's objects.

// Right is one right of the catalogue.
type Right struct {
	Key  string
	Name string
	// Core: without it most collections read nothing; else it is one feature's own.
	Core bool
	For  string
	// Check is a SQL expression: true held, false missing, NULL = the thing it is about is not on this server.
	Check string
	// Null is the state a NULL answer means ("" = missing).
	Null string
	// Grant is the statement that gives it; {role} is the login as quote_ident writes it, {login} its plain name.
	Grant string
	// Checks are the collectors' literals this right covers.
	Checks []string
	// On: "" the right applies; any other text = listed as 'not on this server' with that reason.
	On func(platform.Info) string
}

func everywhere(platform.Info) string { return "" }

// selfManaged: a right only a superuser of a self-managed server can give.
func selfManaged(i platform.Info) string {
	if i.Kind.Managed() {
		return "a managed platform has no superuser to give it; its log and its host come through the platform's own doors"
	}
	return ""
}

// Rights is the catalogue, in the page's order: the core rights first.
var Rights = []Right{
	{Key: "pg_monitor", Name: "pg_monitor", Core: true,
		For:   "every statistics view and setting: activity, statements, replication, sizes, settings (pg_read_all_stats, pg_read_all_settings, pg_stat_scan_tables)",
		Check: "pg_has_role(current_user, 'pg_monitor', 'USAGE')",
		Grant: "GRANT pg_monitor TO {role};",
		Checks: []string{"pg_has_role(current_user, 'pg_monitor', 'USAGE')", "pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')",
			"pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')"},
		On: everywhere},
	{Key: "connect", Name: "CONNECT on every database", Core: true,
		For:    "each database's own reads: its tables, indexes, schema and bloat",
		Check:  "NOT EXISTS (SELECT 1 FROM pg_database d WHERE d.datallowconn AND NOT d.datistemplate AND NOT has_database_privilege(d.datname, 'CONNECT'))",
		Grant:  "GRANT CONNECT ON DATABASE {database} TO {role};",
		Checks: []string{"has_database_privilege(d.datname, 'CONNECT')"},
		On:     everywhere},
	{Key: "server_log_list", Name: "EXECUTE on pg_ls_logdir()",
		For:    "the server log's files listed (Slow queries, the log and the pgaudit reads); pg_monitor gives it",
		Check:  "has_function_privilege('pg_catalog.pg_ls_logdir()', 'EXECUTE')",
		Grant:  "GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_logdir() TO {role};",
		Checks: []string{"has_function_privilege('pg_catalog.pg_ls_logdir()"},
		On:     selfManaged},
	{Key: "server_log_read", Name: "the server log's read door (public.pgvigil_read_log)",
		For:    "the server log's content on a self-managed server (Slow queries): a function a superuser creates, which serves only the files pg_ls_logdir() lists",
		Check:  "coalesce((" + serverlogDoorFind + "), '') <> '' OR has_function_privilege('" + serverlogReadFn + "', 'EXECUTE')",
		Grant:  "-- run as a superuser of that server\n" + strings.ReplaceAll(ServerlogDoorSQL, "<login>", "{role}"),
		Checks: []string{"has_function_privilege(p.oid, 'EXECUTE')", "has_function_privilege($1, 'EXECUTE')"},
		On:     selfManaged},
	{Key: "hba_rules", Name: "SELECT on pg_hba_file_rules",
		For:    "pg_hba.conf's rules on the Roles page (a superuser's by default)",
		Check:  "has_table_privilege('pg_catalog.pg_hba_file_rules', 'SELECT') AND has_function_privilege('pg_catalog.pg_hba_file_rules()', 'EXECUTE')",
		Grant:  "GRANT SELECT ON pg_catalog.pg_hba_file_rules TO {role};\nGRANT EXECUTE ON FUNCTION pg_catalog.pg_hba_file_rules() TO {role};",
		Checks: []string{"has_table_privilege('pg_catalog.pg_hba_file_rules', 'SELECT')", "has_function_privilege('pg_catalog.pg_hba_file_rules()"},
		On:     selfManaged},
}

// RightsExceptions are the checks the package's statements make that no right of the catalogue stands for, each with
// why (TestRightsCatalogueNamesEveryCheck).
var RightsExceptions = map[string]string{
	"has_table_privilege($1, 'SELECT')":                                "pg_buffercache's own view, where the extension is installed: pg_monitor reads it (its collection's note says so)",
	"has_function_privilege(to_regprocedure(quote_ident(n.nspname)":    "amcheck's own functions, where the extension is installed: its collection's skip prints the GRANT",
	"has_function_privilege(format('%I.pg_sys_os_info()":               "system_stats' own function, where the extension is installed: its collection's skip names it",
	"has_table_privilege('pg_catalog.pg_authid', 'SELECT')":            "the password report: a superuser's read, never asked for",
	"has_table_privilege(z.oid, 'SELECT')":                             "read as data: whether a table's statistics are readable",
	"has_table_privilege(c.oid, 'SELECT')":                             "read as data: the schema collection's objects",
	"has_schema_privilege(n.oid, 'USAGE')":                             "read as data: the schema collection's objects",
	"has_sequence_privilege(c.oid, 'SELECT')":                          "read as data: a sequence's privileges",
	"has_sequence_privilege(c.oid, 'USAGE')":                           "read as data: a sequence's privileges",
	"has_schema_privilege('public', 'public', 'CREATE')":               "read as data: whether PUBLIC may create in schema public",
	"has_schema_privilege('pgagent', 'USAGE')":                         "the actions login's (the job actions: docs)",
	"has_column_privilege('pgagent.pga_job', 'jobid', 'SELECT')":       "the actions login's (the job actions)",
	"has_column_privilege('pgagent.pga_job', 'jobnextrun', 'UPDATE')":  "the actions login's (the job actions)",
	"has_column_privilege('pgagent.pga_job', 'jobagentid', 'SELECT')":  "the actions login's (the job actions)",
	"has_column_privilege('pgagent.pga_job', 'jobenabled', 'SELECT')":  "the actions login's (the job actions)",
	"pg_has_role(current_user, 'pg_signal_backend', 'USAGE')":          "the actions login's (cancel and terminate)",
	"pg_has_role(session_user, 'pg_execute_server_program', 'MEMBER')": "a custom collection's refusal of a login that is too strong",
	"pg_has_role(session_user, 'pg_write_server_files', 'MEMBER')":     "a custom collection's refusal of a login that is too strong",
	"pg_has_role(session_user, 'pg_read_server_files', 'MEMBER')":      "a custom collection's refusal of a login that is too strong",
}

// RightState is one right as the server answered it for the login.
type RightState struct {
	Key, Name, For string
	Core           bool
	// State: held, missing, or the words of a right that does not apply here.
	State string
	// Grant is the statement for this login; "" unless the right is missing.
	Grant string
	// Databases names the databases the login cannot connect to (connect; the first 20).
	Databases []string
}

// RightsRead is what ReadRights answers.
type RightsRead struct {
	Login, Server, Platform string
	Rights                  []RightState
	// Missing counts every missing right; MissingCore the needed ones among them.
	Missing, MissingCore int
}

// rightsIdentitySQL: the login as the server names it and as quote_ident writes it, and where the server is.
const rightsIdentitySQL = `SELECT current_user::text, quote_ident(current_user)::text,
  coalesce(nullif(current_setting('cluster_name', true), ''), host(inet_server_addr()) || ':' || inet_server_port()::text, 'this server')`

// rightsNoConnectSQL: the databases the login cannot connect to, as quote_ident writes them.
const rightsNoConnectSQL = `SELECT quote_ident(d.datname)::text FROM pg_database d
 WHERE d.datallowconn AND NOT d.datistemplate AND NOT has_database_privilege(d.datname, 'CONNECT') ORDER BY d.datname LIMIT 21`

// rightsSQL is the one statement that asks every right that applies: a column per right, by its key.
func rightsSQL(apply []Right) string {
	cols := make([]string, 0, len(apply))
	for _, r := range apply {
		cols = append(cols, "("+r.Check+")::boolean AS "+r.Key)
	}
	return "SELECT " + strings.Join(cols, ",\n  ")
}

// ReadRights asks the server, as the connection's login, which rights of the catalogue it holds. It reads only.
func ReadRights(ctx context.Context, conn *pgx.Conn, forced string) (RightsRead, error) {
	info, err := platform.Detect(ctx, conn, forced)
	if err != nil {
		return RightsRead{}, err
	}
	var out RightsRead
	var role string
	if err := conn.QueryRow(ctx, rightsIdentitySQL).Scan(&out.Login, &role, &out.Server); err != nil {
		return RightsRead{}, err
	}
	out.Platform = string(info.Kind)
	var apply []Right
	states := map[string]string{}
	for _, r := range Rights {
		if on := r.On(info); on != "" {
			states[r.Key] = "not on this server: " + on
			continue
		}
		apply = append(apply, r)
	}
	answers := map[string]*bool{}
	if len(apply) > 0 {
		vals := make([]*bool, len(apply))
		ptrs := make([]any, len(apply))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := conn.QueryRow(ctx, rightsSQL(apply)).Scan(ptrs...); err != nil {
			return RightsRead{}, fmt.Errorf("the rights: %w", err)
		}
		for i, r := range apply {
			answers[r.Key] = vals[i]
		}
	}
	for _, r := range Rights {
		st := RightState{Key: r.Key, Name: r.Name, For: r.For, Core: r.Core}
		if why, off := states[r.Key]; off {
			st.State = why
			out.Rights = append(out.Rights, st)
			continue
		}
		a := answers[r.Key]
		switch {
		case a != nil && *a:
			st.State = "held"
		case a == nil && r.Null != "":
			st.State = r.Null
		default:
			st.State = "missing"
			out.Missing++
			if r.Core {
				out.MissingCore++
			}
			grant := strings.ReplaceAll(strings.ReplaceAll(r.Grant, "{role}", role), "{login}", out.Login)
			if r.Key == "connect" {
				st.Databases = rightsNoConnect(ctx, conn)
				var lines []string
				for i, d := range st.Databases {
					if i == 20 {
						break
					}
					lines = append(lines, strings.ReplaceAll(grant, "{database}", d))
				}
				grant = strings.Join(lines, "\n")
			}
			st.Grant = grant
		}
		out.Rights = append(out.Rights, st)
	}
	return out, nil
}

// rightsNoConnect names the databases the login cannot connect to (nil when the read fails: the row still says missing).
func rightsNoConnect(ctx context.Context, conn *pgx.Conn) []string {
	rows, err := conn.Query(ctx, rightsNoConnectSQL)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if rows.Scan(&n) == nil {
			out = append(out, n)
		}
	}
	return out
}

// Script is the printed script of the missing rights: a comment head that says whose it is and that pgvigil ran
// nothing, then each missing right's statement under a comment naming it. "" when nothing is missing.
func (r RightsRead) Script(at string) string {
	if r.Missing == 0 {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "-- pgvigil: the rights its monitoring login %s lacks on %s (read %s).\n", r.Login, r.Server, at)
	b.WriteString("-- Run it as an administrator of that server. pgvigil did not run it and never does.\n")
	for _, s := range r.Rights {
		if s.State != "missing" {
			continue
		}
		kind := "optional"
		if s.Core {
			kind = "needed"
		}
		fmt.Fprintf(&b, "\n-- %s (%s): %s\n", s.Name, kind, s.For)
		if len(s.Databases) > 20 {
			b.WriteString("-- the first 20 databases are named; the login cannot connect to more\n")
		}
		if s.Grant != "" {
			b.WriteString(s.Grant + "\n")
		}
	}
	return b.String()
}
