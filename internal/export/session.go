package export

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// RefusedError is a configuration or a login the export will not run with. Exit 3: a service manager must not
// retry it.
type RefusedError struct{ msg string }

func (e *RefusedError) Error() string { return e.msg }

// ExitCode is the house code of a configuration error.
func (e *RefusedError) ExitCode() int { return 3 }

func refused(format string, a ...any) error { return &RefusedError{fmt.Sprintf(format, a...)} }

// AppName is the application_name of every session the export opens.
const AppName = "pgvigil-export"

// connect opens one session of the export's login. Every session is read only from its first statement, with its
// own timeouts and no parallel workers: the export must not be the statement that hurts the repository. Behind
// PgBouncer each of these startup settings must be in its track_extra_parameters.
func connect(ctx context.Context, dsn string, timeout time.Duration) (*pgx.Conn, error) {
	if strings.TrimSpace(dsn) == "" {
		return nil, refused("export.dsn resolves to nothing: fill in the environment variable or the file it names")
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, refused("export.dsn does not parse as a connection string") // the parser's message can carry the dsn
	}
	rp := cfg.RuntimeParams
	rp["application_name"] = AppName
	rp["default_transaction_read_only"] = "on"
	rp["statement_timeout"] = strconv.FormatInt(timeout.Milliseconds(), 10)
	rp["lock_timeout"] = "5000"
	rp["work_mem"] = "16MB"
	rp["max_parallel_workers_per_gather"] = "0"
	rp["plan_cache_mode"] = "force_custom_plan" // each window's bounds planned as values: the partitions pruned at plan time
	rp["jit"] = "off"
	rp["TimeZone"] = "UTC"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("the export's login cannot connect to the repository: %w", err)
	}
	return conn, nil
}

// connectDoor opens the short session that writes the export's own row through export_run_record / export_off. It
// is the one session that is not read only, and it runs nothing but those two calls.
func connectDoor(ctx context.Context, dsn string) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, refused("export.dsn does not parse as a connection string")
	}
	rp := cfg.RuntimeParams
	rp["application_name"] = AppName
	rp["statement_timeout"] = "15000"
	rp["lock_timeout"] = "5000"
	rp["TimeZone"] = "UTC"
	return pgx.ConnectConfig(ctx, cfg)
}

// guardSQL asks, as the export's own login, whether that login could write to the repository:
//   - a superuser, one that bypasses row security, or one that may create roles (it could grant itself one that writes);
//   - every role it is a MEMBER of (one it may switch to, not only one it inherits) but itself and the two read roles;
//   - a write privilege on a table of the schema, on the whole table or on any column of it;
//   - a privilege on a sequence of the schema beyond the read roles' own (nextval and setval change it);
//   - CREATE on the schema;
//   - EXECUTE on a function of the schema that the read roles do not hold (an import function granted to it by hand).
//
// Everything is found through the catalogs.
const guardSQL = `/* pgvigil-export:guard */
WITH ns AS (SELECT to_regnamespace('pgvigil')::oid AS oid),
     readers AS (SELECT oid FROM pg_roles WHERE rolname IN ('pgvigil_reader', 'pgvigil_exporter'))
SELECT session_user::text, r.rolsuper, r.rolbypassrls, r.rolcreaterole,
       coalesce((SELECT string_agg(m.rolname::text, ', ' ORDER BY m.rolname) FROM pg_roles m
                  WHERE m.rolname <> session_user AND m.rolname NOT IN ('pgvigil_reader', 'pgvigil_exporter')
                    AND pg_has_role(session_user, m.oid, 'MEMBER')), ''),
       coalesce((SELECT string_agg(w.relname, ', ' ORDER BY w.relname)
                   FROM (SELECT c.relname::text FROM pg_class c, ns
                          WHERE c.relnamespace = ns.oid AND c.relkind IN ('r', 'p')
                            AND (has_table_privilege(session_user, c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
                                 OR has_any_column_privilege(session_user, c.oid, 'INSERT, UPDATE'))
                          ORDER BY c.relname LIMIT 5) w), ''),
       coalesce((SELECT string_agg(q.relname, ', ' ORDER BY q.relname)
                   FROM (SELECT c.relname::text FROM pg_class c, ns
                          WHERE c.relnamespace = ns.oid AND c.relkind = 'S'
                            AND has_sequence_privilege(session_user, c.oid, 'USAGE, UPDATE')
                            AND NOT EXISTS (SELECT 1 FROM readers x WHERE has_sequence_privilege(x.oid, c.oid, 'USAGE, UPDATE'))
                          ORDER BY c.relname LIMIT 5) q), ''),
       coalesce((SELECT has_schema_privilege(session_user, ns.oid, 'CREATE') FROM ns), false),
       coalesce((SELECT string_agg(f.proname, ', ' ORDER BY f.proname)
                   FROM (SELECT DISTINCT p.proname::text FROM pg_proc p, ns
                          WHERE p.pronamespace = ns.oid AND has_function_privilege(session_user, p.oid, 'EXECUTE')
                            AND NOT EXISTS (SELECT 1 FROM readers x WHERE has_function_privilege(x.oid, p.oid, 'EXECUTE'))
                          ORDER BY 1 LIMIT 5) f), ''),
       coalesce((SELECT has_schema_privilege(session_user, ns.oid, 'USAGE') FROM ns), false),
       current_setting('server_encoding')
  FROM pg_roles r WHERE r.rolname = session_user`

// guard refuses a login that could write, one that cannot read the schema, and a repository whose encoding is not
// UTF8 (the files' strings are written as the server sends them).
func guard(ctx context.Context, conn *pgx.Conn) error {
	var user, member, writes, seqs, funcs, encoding string
	var super, bypass, createrole, create, usage bool
	if err := conn.QueryRow(ctx, guardSQL).Scan(&user, &super, &bypass, &createrole, &member, &writes, &seqs, &create, &funcs, &usage, &encoding); err != nil {
		return fmt.Errorf("the export's login could not be checked: %w", err)
	}
	const rule = "the export's login is IN ROLE pgvigil_reader (or pgvigil_exporter) alone; `pgvigil roles` prints it; nothing was read or written"
	switch {
	case super:
		return refused("the export's login %s is a superuser: it could write; %s", user, rule)
	case bypass:
		return refused("the export's login %s bypasses row security; %s", user, rule)
	case member != "":
		return refused("the export's login %s is also a member of %s: it could write; %s", user, member, rule)
	case createrole:
		return refused("the export's login %s may create roles (CREATEROLE): it could grant itself a role that writes; %s", user, rule)
	case writes != "":
		return refused("the export's login %s holds a write privilege on %s (the table or a column of it); %s", user, writes, rule)
	case seqs != "":
		return refused("the export's login %s holds a privilege on the sequence %s; %s", user, seqs, rule)
	case create:
		return refused("the export's login %s holds CREATE on the schema pgvigil; %s", user, rule)
	case funcs != "":
		return refused("the export's login %s may execute %s, which the read roles may not; %s", user, funcs, rule)
	case !usage:
		return refused("the export's login %s cannot read the schema pgvigil; %s", user, rule)
	case !strings.EqualFold(encoding, "UTF8"):
		return refused("the repository's encoding is %s: the export writes UTF8 only", encoding)
	}
	return nil
}
