package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// rolesCollector is the hourly roles and privileges read: every role with its attributes (pg_roles, never
// pg_authid: a password, set or not, is never read and pg_roles shows it masked), every membership with its
// grantor and its admin, inherit and set options (pg_auth_members), each database's ACL (pg_database.datacl,
// read once on the connected database: the catalog is shared), and on every connectable database (the
// per-database connections the tables collection makes, under the same cap) the schema ACLs and the default
// privileges (ALTER DEFAULT PRIVILEGES). The server's pg_hba.conf rules are read through pg_hba_file_rules when
// the login may (a superuser, or a login granted SELECT on the view); otherwise the read says it skipped them
// and why. The rules carry a checksum of their content so a change is seen between reads (the idea of
// pgMonitor's pg_hba checksum: Crunchy Data, Apache-2.0; no code taken). Nothing is installed or changed.
//
// Rows by kind:
//
//	login      name, is_super, has_pg_monitor              (once: the login the collector runs as)
//	role       name, oid, super, inherit, createrole, createdb, canlogin, replication, bypassrls,
//	           connlimit, valid_until, config               (once per role)
//	member     role, member, grantor, admin_option, inherit_option, set_option   (once per grant)
//	dbacl      datname, owner, grantee, grantor, privileges, grantable, is_default (once per database and grant)
//	dbacls     names: every database whose datacl was read (a database not listed is gone)
//	databases  names: every connectable database
//	noconnect  names: the databases the login may not connect to (their schema and default ACLs are not read)
//	db         dbid, datname                               (per database read: its schema and default ACLs are complete)
//	schemaacl  datname, schema_name, owner, grantee, grantor, privileges, grantable, is_default
//	defacl     datname, owner, schema_name, objtype, grantee, grantor, privileges, grantable
//	hba        rule_number, file_name, line_number, type, databases, users, address, netmask, auth_method, options, error
//	hba_state  status (read | skipped), note, checksum, rules
//
// A database that cannot be read gives a collector_error row and no db row, so the import keeps its last schema
// and default ACL rows as they were (not read is not "revoked"); a skipped hba read keeps the last rules.
type rolesCollector struct{}

func init() { Register(rolesCollector{}) }

func (rolesCollector) Name() string                   { return "roles" }
func (rolesCollector) DefaultInterval() time.Duration { return time.Hour }
func (rolesCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (rolesCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("roles needs the instance config: %w", ErrSkip)
}

// rolesLoginSQL is the collector's own login and whether it holds pg_monitor (a superuser holds every role).
const rolesLoginSQL = `
SELECT 'login' AS kind, current_user::text AS name,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS is_super,
       pg_has_role(current_user, 'pg_monitor', 'USAGE') AS has_pg_monitor`

// rolesRolesSQL lists every role. rolconfig (ALTER ROLE ... SET) keeps its names; the value of a setting whose name
// says pass, secret, token or key, or that carries a password= keyword or a URL with a user and password, is masked
// before it leaves the server.
const rolesRolesSQL = `
SELECT 'role' AS kind, r.rolname::text AS name, r.oid::bigint AS oid, r.rolsuper AS super, r.rolinherit AS inherit,
       r.rolcreaterole AS createrole, r.rolcreatedb AS createdb, r.rolcanlogin AS canlogin,
       r.rolreplication AS replication, r.rolbypassrls AS bypassrls, r.rolconnlimit AS connlimit,
       r.rolvaliduntil AS valid_until,
       ARRAY(SELECT CASE WHEN split_part(c, '=', 1) ~* '(pass|secret|token|key)' OR c ~* 'password\s*=' OR c ~ '://[^:/@\s]+:[^@\s]+@'
                         THEN split_part(c, '=', 1) || '=********' ELSE c END
               FROM unnest(r.rolconfig) c) AS config
  FROM pg_roles r
 ORDER BY r.rolname`

// rolesMembersSQL lists every membership grant; inherit_option and set_option exist from PostgreSQL 16 (before,
// a member inherits by its own rolinherit and SET ROLE is always allowed: NULL here).
const rolesMembersSQL = `
SELECT 'member' AS kind, r.rolname::text AS role, m.rolname::text AS member, g.rolname::text AS grantor,
       a.admin_option, %s AS inherit_option, %s AS set_option
  FROM pg_auth_members a
  JOIN pg_roles r ON r.oid = a.roleid
  JOIN pg_roles m ON m.oid = a.member
  LEFT JOIN pg_roles g ON g.oid = a.grantor
 ORDER BY 3, 2, 4`

// rolesDatabaseACLSQL explodes each database's ACL (the default one, owner and PUBLIC, when datacl is NULL), one
// row per grantee and grantor: the privileges as a sorted list, the ones held WITH GRANT OPTION apart.
const rolesDatabaseACLSQL = `
SELECT 'dbacl' AS kind, d.datname::text AS datname, pg_get_userbyid(d.datdba)::text AS owner,
       CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END AS grantee,
       pg_get_userbyid(x.grantor)::text AS grantor,
       string_agg(x.privilege_type, ',' ORDER BY x.privilege_type) AS privileges,
       coalesce(string_agg(x.privilege_type, ',' ORDER BY x.privilege_type) FILTER (WHERE x.is_grantable), '') AS grantable,
       d.datacl IS NULL AS is_default
  FROM pg_database d CROSS JOIN LATERAL aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) x
 WHERE d.datallowconn AND NOT d.datistemplate
 GROUP BY d.datname, d.datdba, d.datacl IS NULL, x.grantee, x.grantor
 ORDER BY 2, 4, 5`

const rolesDatabaseNamesSQL = `
SELECT coalesce(array_agg(d.datname::text ORDER BY d.datname), '{}') FROM pg_database d WHERE d.datallowconn AND NOT d.datistemplate`

// rolesSchemaACLSQL is one database's schema ACLs (the system schemas left out), the default one when nspacl is NULL.
const rolesSchemaACLSQL = `
SELECT 'schemaacl' AS kind, current_database()::text AS datname, n.nspname::text AS schema_name,
       pg_get_userbyid(n.nspowner)::text AS owner,
       CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END AS grantee,
       pg_get_userbyid(x.grantor)::text AS grantor,
       string_agg(x.privilege_type, ',' ORDER BY x.privilege_type) AS privileges,
       coalesce(string_agg(x.privilege_type, ',' ORDER BY x.privilege_type) FILTER (WHERE x.is_grantable), '') AS grantable,
       n.nspacl IS NULL AS is_default
  FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) x
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND n.nspname !~ '^pg_(toast_)?temp_'
 GROUP BY n.nspname, n.nspowner, n.nspacl IS NULL, x.grantee, x.grantor
 ORDER BY 3, 5, 6`

// rolesDefaultACLSQL is one database's ALTER DEFAULT PRIVILEGES entries: whose new objects (owner), in which schema
// (NULL: every schema), of which type, and what each grantee gets.
const rolesDefaultACLSQL = `
SELECT 'defacl' AS kind, current_database()::text AS datname, pg_get_userbyid(a.defaclrole)::text AS owner,
       n.nspname::text AS schema_name,
       CASE a.defaclobjtype WHEN 'r' THEN 'table' WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'function'
                            WHEN 'T' THEN 'type' WHEN 'n' THEN 'schema' WHEN 'L' THEN 'large object'
                            ELSE a.defaclobjtype::text END AS objtype,
       CASE WHEN x.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee)::text END AS grantee,
       pg_get_userbyid(x.grantor)::text AS grantor,
       string_agg(x.privilege_type, ',' ORDER BY x.privilege_type) AS privileges,
       coalesce(string_agg(x.privilege_type, ',' ORDER BY x.privilege_type) FILTER (WHERE x.is_grantable), '') AS grantable
  FROM pg_default_acl a LEFT JOIN pg_namespace n ON n.oid = a.defaclnamespace
  CROSS JOIN LATERAL aclexplode(a.defaclacl) x
 GROUP BY a.defaclrole, n.nspname, a.defaclobjtype, x.grantee, x.grantor
 ORDER BY 3, 4 NULLS FIRST, 5, 6`

// rolesHBAPrivSQL says whether this login may read pg_hba_file_rules (by default a superuser only).
const rolesHBAPrivSQL = `
SELECT has_table_privilege('pg_catalog.pg_hba_file_rules', 'SELECT')
       AND has_function_privilege('pg_catalog.pg_hba_file_rules()', 'EXECUTE')`

// rolesHBASQL reads the rules in the order the server applies them; the line with an error has error set and
// no rule fields. The column set is the one PostgreSQL 15+ has (rule_number, file_name); an older server's
// view lacks them and the read substitutes NULL. The options column carries an LDAP bind password
// (ldapbindpasswd=) and RADIUS secrets (radiussecrets=) in clear: their values are masked here. Every row carries
// the checksum of the whole read (one statement, so the rules and the checksum come from one file state): the md5
// of each rule's fields, masked options included, in the order the server applies them, line numbers left out, so a
// change of a rule, its order or its options changes it and a comment or a blank line does not.
const rolesHBASQL = `
WITH h AS (
  SELECT %s AS rule_number, %s AS file_name, h.line_number, h.type, h.database AS databases, h.user_name AS users,
         h.address, h.netmask, h.auth_method,
         CASE WHEN h.options IS NOT NULL THEN
           ARRAY(SELECT regexp_replace(o, '^(ldapbindpasswd|radiussecrets?)=.*$', '\1=********') FROM unnest(h.options) o) END AS options,
         h.error
    FROM pg_hba_file_rules h
)
SELECT 'hba' AS kind, h.*,
       md5(coalesce(string_agg(concat_ws('|', h.file_name, h.type, h.databases::text, h.users::text, h.address, h.netmask,
                                         h.auth_method, h.options::text, h.error), E'\n')
                    OVER (ORDER BY h.file_name, h.line_number ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING), '')) AS checksum
  FROM h
 ORDER BY h.file_name, h.line_number`

// RunInstance reads the cluster-wide catalogs on conn, then the schema and default ACLs of conn's database and
// of every other connectable database (its own short connection), up to tablesMaxDatabases.
func (rolesCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	out := []Row{}
	inh, set := "NULL::boolean", "NULL::boolean"
	if cols, err := viewColumns(ctx, conn, "pg_catalog.pg_auth_members"); err != nil {
		return nil, err
	} else if cols["inherit_option"] && cols["set_option"] {
		inh, set = "a.inherit_option", "a.set_option"
	}
	for _, q := range []string{rolesLoginSQL, rolesRolesSQL, fmt.Sprintf(rolesMembersSQL, inh, set), rolesDatabaseACLSQL} {
		rows, err := rolesQuery(ctx, conn, q)
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
	}
	var aclNames []string
	if err := conn.QueryRow(ctx, rolesDatabaseNamesSQL).Scan(&aclNames); err != nil {
		return nil, fmt.Errorf("databases: %w", err)
	}
	out = append(out, Row{"kind": "dbacls", "names": aclNames})

	hba, err := rolesHBA(ctx, conn)
	if err != nil {
		return nil, err
	}
	out = append(out, hba...)

	dbs, err := tablesDatabases(ctx, conn)
	if err != nil {
		return nil, err
	}
	names := make([]string, len(dbs))
	copy(names, dbs)
	out = append(out, Row{"kind": "databases", "names": names})
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	// a database the login may not connect to keeps its last schema and default ACLs; the read names it (a
	// platform's own database, rdsadmin on RDS, is one on every read, so it is not a collector error)
	connectable := map[string]bool{}
	for _, d := range dbs {
		connectable[d] = true
	}
	unreadable := []string{}
	for _, d := range aclNames {
		if !connectable[d] {
			unreadable = append(unreadable, d)
		}
	}
	out = append(out, Row{"kind": "noconnect", "names": unreadable})
	if len(dbs) > tablesMaxDatabases {
		out = append(out, Row{"kind": "collector_error", "source": "roles",
			"message": fmt.Sprintf("%d databases: the first %d by name are read (tablesMaxDatabases)", len(dbs), tablesMaxDatabases)})
		dbs = dbs[:tablesMaxDatabases]
	}
	for _, db := range dbs {
		var rows []Row
		if db == cur {
			rows, err = rolesReadDB(ctx, conn)
		} else {
			rows, err = rolesReadOther(ctx, in, db)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, Row{"kind": "collector_error", "source": "roles:" + db, "message": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}

// rolesQuery runs one read and returns its rows as maps.
func rolesQuery(ctx context.Context, conn *pgx.Conn, sql string, args ...any) ([]Row, error) {
	r, err := conn.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return rowsToMaps(r)
}

// md5Empty is md5(”): the checksum of a file with no rules.
const md5Empty = "d41d8cd98f00b204e9800998ecf8427e"

// rolesHBA reads pg_hba_file_rules when the login may, and always returns the hba_state row: read with the
// checksum (rolesHBASQL) and the rule count, or skipped with the reason.
func rolesHBA(ctx context.Context, conn *pgx.Conn) ([]Row, error) {
	var ok bool
	if err := conn.QueryRow(ctx, rolesHBAPrivSQL).Scan(&ok); err != nil {
		return nil, fmt.Errorf("pg_hba_file_rules privilege: %w", err)
	}
	if !ok {
		return []Row{{"kind": "hba_state", "status": "skipped",
			"note": "pg_hba_file_rules is readable by a superuser only (or a login granted SELECT on it): the monitoring login is neither, so the hba rules are not read"}}, nil
	}
	cols, err := viewColumns(ctx, conn, "pg_catalog.pg_hba_file_rules")
	if err != nil {
		return nil, err
	}
	rn, fn := "NULL::int", "NULL::text"
	if cols["rule_number"] {
		rn = "h.rule_number"
	}
	if cols["file_name"] {
		fn = "h.file_name"
	}
	rows, err := rolesQuery(ctx, conn, fmt.Sprintf(rolesHBASQL, rn, fn))
	if err != nil {
		// a privilege granted on the view but a file the server cannot parse, or a platform that blocks the
		// function: the read goes on without the rules
		return []Row{{"kind": "hba_state", "status": "skipped", "note": "pg_hba_file_rules: " + err.Error()}}, nil
	}
	sum := md5Empty
	for _, r := range rows {
		if v, ok := r["checksum"].(string); ok {
			sum = v
		}
		delete(r, "checksum")
	}
	return append(rows, Row{"kind": "hba_state", "status": "read", "note": "", "checksum": sum, "rules": len(rows)}), nil
}

// rolesReadDB reads one database's schema ACLs and default privileges, led by its db row (the read is complete).
func rolesReadDB(ctx context.Context, conn *pgx.Conn) ([]Row, error) {
	var dbid int64
	var datname string
	if err := conn.QueryRow(ctx, `SELECT oid::bigint, datname::text FROM pg_database WHERE datname = current_database()`).Scan(&dbid, &datname); err != nil {
		return nil, fmt.Errorf("database: %w", err)
	}
	out := []Row{{"kind": "db", "dbid": dbid, "datname": datname}}
	for _, q := range []struct{ name, sql string }{{"schema ACLs", rolesSchemaACLSQL}, {"default privileges", rolesDefaultACLSQL}} {
		rows, err := rolesQuery(ctx, conn, q.sql)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", q.name, err)
		}
		out = append(out, rows...)
	}
	return out, nil
}

// rolesReadOther connects to another database with the instance's DSN and the collector's session settings,
// reads it, and closes the connection.
func rolesReadOther(ctx context.Context, in config.Instance, db string) ([]Row, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("dsn %q resolved to an empty string", in.DSNRaw)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.Database = db
	conn, err := connectCounted(ctx, in.Name, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		return nil, fmt.Errorf("session setup: %w", err)
	}
	return rolesReadDB(ctx, conn)
}
