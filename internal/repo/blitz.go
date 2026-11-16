package repo

import (
	"context"
	"encoding/json"
	"fmt"
)

// BlitzPlan is the collector's question before a weekly sp_Blitz run (B20-2; 0273's import_mssql_blitz_plan): the
// due rule's state ('due', 'not due' or 'off') and its words, the database sp_Blitz is looked for in, and the timeout
// of sp_Blitz's statement in seconds.
type BlitzPlan struct {
	State    string `json:"state"`
	Why      string `json:"why"`
	ProcDB   string `json:"proc_db"`
	TimeoutS int    `json:"timeout_s"`
}

// MSSQLBlitzPlan asks the repository whether an instance's weekly sp_Blitz is due now.
func (r *Repo) MSSQLBlitzPlan(ctx context.Context, instanceID int) (BlitzPlan, error) {
	var p BlitzPlan
	var raw *string
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_mssql_blitz_plan($1)::text`, instanceID).Scan(&raw); err != nil {
		return p, fmt.Errorf("import_mssql_blitz_plan: %w", err)
	}
	if raw == nil {
		return p, fmt.Errorf("import_mssql_blitz_plan answered nothing for instance %d", instanceID)
	}
	if err := json.Unmarshal([]byte(*raw), &p); err != nil {
		return p, fmt.Errorf("import_mssql_blitz_plan answered %q: %w", *raw, err)
	}
	return p, nil
}
