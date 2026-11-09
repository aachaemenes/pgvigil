package collect

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// viewColumns returns the column names of a relation (a catalog view, an
// extension view), so a collection can adapt its SELECT to what this server
// version and extension version actually expose instead of guessing from
// server_version_num.
func viewColumns(ctx context.Context, conn *pgx.Conn, relation string) (map[string]bool, error) {
	rows, err := conn.Query(ctx, `SELECT a.attname FROM pg_attribute a WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped`, relation)
	if err != nil {
		return nil, fmt.Errorf("columns of %s: %w", relation, err)
	}
	defer rows.Close()
	cols := map[string]bool{}
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		cols[c] = true
	}
	return cols, rows.Err()
}

// col returns "<alias>.<name>" when the column exists, else a typed NULL, so
// the result always carries the same column set for the repository.
func col(cols map[string]bool, alias, name, typ string) string {
	if cols[name] {
		return alias + "." + name
	}
	return "NULL::" + typ
}

// maskSQL wraps a query-text expression so a password literal never leaves the
// target: CREATE/ALTER ROLE|USER ... PASSWORD '...', IDENTIFIED BY '...', and a
// connection-string password=... inside the text. pg_stat_statements normalises
// constants in DML but keeps utility statements verbatim, so this applies to
// pg_stat_activity.query and pg_stat_statements.query alike.
func maskSQL(expr string) string {
	return `regexp_replace(regexp_replace(` + expr +
		`, '((PASSWORD|IDENTIFIED\s+BY)\s+)(''(?:[^'']|'''')*''|E''(?:[^'']|'''')*''|\$[0-9]+)', '\1''<masked>''', 'gi')` +
		`, '(password|passfile|sslkey|sslpassword|pwd)=\S+', '\1=<masked>', 'gi')`
}
