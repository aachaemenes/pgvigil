package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
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

// MSSQLBlitzPlan asks the repository whether an instance's weekly sp_Blitz is due at at - the run's own start, the
// instant the run is stored under, so the question and the stored time share one clock (review-22 bzstore SF2).
func (r *Repo) MSSQLBlitzPlan(ctx context.Context, instanceID int, at time.Time) (BlitzPlan, error) {
	var p BlitzPlan
	var raw *string
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_mssql_blitz_plan($1, $2)::text`, instanceID, at).Scan(&raw); err != nil {
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
