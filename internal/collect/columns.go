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
