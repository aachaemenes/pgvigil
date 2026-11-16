package repo

import (
	"context"
	"fmt"
	"time"
)

// MSSQLSchemaDue asks pgvigil.import_mssql_schema_due (0267) which databases of a SQL Server instance the schema
// collection reads whole on this pass, and why; payload is the collector's {now, no_trace, dbs}, the reply its JSON.
func (r *Repo) MSSQLSchemaDue(ctx context.Context, instanceID int, snapshotAt time.Time, payload []byte) ([]byte, error) {
	var out string
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_mssql_schema_due($1, $2, $3::jsonb)::text`, instanceID, snapshotAt, string(payload)).Scan(&out); err != nil {
		return nil, fmt.Errorf("import_mssql_schema_due: %w", err)
	}
	return []byte(out), nil
}
