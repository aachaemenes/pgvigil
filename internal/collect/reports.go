package collect

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// reportsCollector is the hourly read of what the Reports tree (task 169) shows for a PostgreSQL instance and no other
// collection reads: each database's comment (COMMENT ON DATABASE: the twin of SQL Server's database extended
// properties) and the password method of each login role (the twin of SQL Server's password policy columns).
//
//	comments   pg_database with shobj_description - any login (the shared catalog)
//	passwords  pg_authid - a superuser, or a role granted SELECT on it (on Amazon RDS and Aurora, Azure and
//	           Cloud SQL not even by the provider's admin role). The method is worked out on the server from the
//	           stored secret's prefix (SCRAM-SHA-256$..., md5...): only the method's name leaves it, never the hash.
//	           PostgreSQL keeps no time a password was set, so there is no password age to read: the report shows the
//	           expiry (rolvaliduntil, read by the roles collection) and this method.
//
// Rows: part (part, status read | no right | failed, note); dbread (database_name) and db_property (database_name,
// property 'comment', value) per database; password (role_name, method) per login role.
type reportsCollector struct{}

func init() { Register(reportsCollector{}) }

func (reportsCollector) Name() string                   { return "reports" }
func (reportsCollector) DefaultInterval() time.Duration { return time.Hour }
func (reportsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

const reportsCommentsSQL = `
SELECT d.datname::text AS database_name, shobj_description(d.oid, 'pg_database') AS value
  FROM pg_database d
 WHERE NOT d.datistemplate
 ORDER BY d.datname`

// may the login read pg_authid: a superuser, or a role granted SELECT on it
const reportsSuperSQL = `SELECT has_table_privilege('pg_catalog.pg_authid', 'SELECT')`

const reportsPasswordsSQL = `
SELECT a.rolname::text AS role_name,
       CASE WHEN a.rolpassword IS NULL THEN 'none'
            WHEN a.rolpassword LIKE 'SCRAM-SHA-256$%' THEN 'scram-sha-256'
            WHEN a.rolpassword ~ '^md5[0-9a-f]{32}$' THEN 'md5'
            ELSE 'other' END AS method
  FROM pg_authid a
 WHERE a.rolcanlogin
 ORDER BY 1`

func (reportsCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	var out []Row
	part := func(name, status, note string) {
		out = append(out, Row{"kind": "part", "part": name, "status": status, "note": note})
		if status == "failed" {
			out = append(out, Row{"kind": "collector_error", "source": name, "message": note})
		}
	}
	if rows, err := conn.Query(ctx, reportsCommentsSQL); err != nil {
		part("comments", "failed", "pg_database: "+err.Error())
	} else {
		var got []Row
		for rows.Next() {
			var db string
			var v *string
			if err := rows.Scan(&db, &v); err != nil {
				rows.Close()
				return nil, err
			}
			// dbread: this database's comment was read; dbname: the server lists it (a database no longer listed has
			// its stored comment marked gone)
			got = append(got, Row{"kind": "dbread", "database_name": db}, Row{"kind": "dbname", "database_name": db})
			if v != nil && *v != "" {
				got = append(got, Row{"kind": "db_property", "database_name": db, "property": "comment", "value": *v})
			}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			part("comments", "failed", "pg_database: "+err.Error())
		} else {
			out = append(out, got...)
			part("comments", "read", "")
		}
	}

	var super bool
	if err := conn.QueryRow(ctx, reportsSuperSQL).Scan(&super); err != nil {
		part("passwords", "failed", "pg_roles: "+err.Error())
		return out, nil
	}
	if !super {
		// not a failure: pg_authid is a superuser's (or a role granted SELECT on it), and a monitoring login should be neither
		part("passwords", "no right", "pg_authid is readable by a superuser (or a role granted SELECT on it) only: the password method of each role was not read")
		return out, nil
	}
	rows, err := conn.Query(ctx, reportsPasswordsSQL)
	if err != nil {
		part("passwords", "failed", "pg_authid: "+err.Error())
		return out, nil
	}
	var got []Row
	for rows.Next() {
		var role, method string
		if err := rows.Scan(&role, &method); err != nil {
			rows.Close()
			return nil, err
		}
		got = append(got, Row{"kind": "password", "role_name": role, "method": method})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		part("passwords", "failed", "pg_authid: "+err.Error())
		return out, nil
	}
	out = append(out, got...)
	part("passwords", "read", "")
	return out, nil
}
