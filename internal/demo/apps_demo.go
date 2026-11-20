package demo

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SeedApplications gives the demo fleet made-up applications (task 310, migration 0136): three applications, each on
// one demo instance, with a team and a person as contacts at example.com (made up; no route, so nothing is mailed),
// written through the store's own writes as the page would. The rest of the fleet's databases stay without one, so
// Admin > Applications shows its list of databases with no application. A re-seed removes the demo's applications
// first (created by 'pgvigil demo'); a repository before 0136 is left as it is.
func SeedApplications(ctx context.Context, pool *pgxpool.Pool, prefix string) error {
	var have bool
	if err := pool.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.import_app_application(timestamptz, jsonb)') IS NOT NULL`).Scan(&have); err != nil || !have {
		return err
	}
	// the demo's applications of THIS fleet (its prefix): another demo fleet's stay
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.app_applications a WHERE a.created_by = 'pgvigil demo'
	   AND NOT EXISTS (SELECT 1 FROM pgvigil.app_assignments s JOIN pgvigil.instances i ON i.instance_id = s.instance_id
	                    WHERE s.app_id = a.app_id AND NOT starts_with(i.name, $1))`, prefix); err != nil {
		return err
	}
	rows, err := pool.Query(ctx, `SELECT instance_id FROM pgvigil.instances
	 WHERE 'demo' = ANY (tags) AND starts_with(name, $1) AND is_active ORDER BY name`, prefix)
	if err != nil {
		return err
	}
	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	call := func(fn string, p map[string]any) (map[string]any, error) {
		p["ui_user"], p["client"] = "pgvigil demo", "demo seed"
		b, _ := json.Marshal(p)
		var raw []byte
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_app_`+fn+`(now(), $1::jsonb)::text`, string(b)).Scan(&raw); err != nil {
			return nil, err
		}
		var a map[string]any
		if err := json.Unmarshal(raw, &a); err != nil {
			return nil, err
		}
		if a["outcome"] != "done" {
			return nil, fmt.Errorf("%s: %v", fn, a["detail"])
		}
		return a, nil
	}
	apps := []struct {
		name, env, desc, slug string
		tier                  int
	}{
		{"Order entry", "production", "Orders from the web shop and the stores (made up for the demo)", "orders", 1},
		{"Payroll", "production", "The weekly and monthly payroll runs (made up for the demo)", "payroll", 2},
		{"Reporting", "test", "The finance team's reports (made up for the demo)", "reporting", 3},
	}
	for i, a := range apps {
		ans, err := call("application", map[string]any{"op": "add", "name": a.name, "tier": a.tier, "environment": a.env, "description": a.desc})
		if err != nil && strings.Contains(err.Error(), "exists already") {
			continue // a name someone already uses (or another demo fleet's): that application is left out
		}
		if err != nil {
			return err
		}
		id := ans["app_id"]
		if _, err := call("contact", map[string]any{"op": "add", "app_id": id, "role": "business owner", "kind": "team",
			"name": a.name + " owners", "email": a.slug + "-owners@example.com"}); err != nil {
			return err
		}
		if _, err := call("contact", map[string]any{"op": "add", "app_id": id, "role": "technical owner", "kind": "person",
			"name": "Sam Example", "email": "sam." + a.slug + "@example.com", "phone": "+1 555 0100"}); err != nil {
			return err
		}
		if i < len(ids) {
			if _, err := call("assign", map[string]any{"op": "assign", "app_id": id,
				"targets": []map[string]any{{"instance_id": ids[i], "database": nil}}}); err != nil {
				return err
			}
		}
	}
	return nil
}
