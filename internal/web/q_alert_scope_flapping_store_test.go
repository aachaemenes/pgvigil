package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAlertScopeFlappingOnAStore: GET /api/alertscope's flapping part on a store. pgvigil.alert_rules and
// pgvigil.alert_rule_state both carry instance_id, so a join of the two leaves two instance_id columns on its left, and
// an instances join USING (instance_id) after it is refused when the statement is parsed (SQLSTATE 42702) - on every
// store, whatever it holds, and so is every GET /api/alertscope with no part (it reads them all). Read twice: the
// handler with part=flapping (200, a flapping part), and the statement inside a transaction that plants one flapping
// series of an instance rule (its row: the rule's name and its instance's name), rolled back.
func TestAlertScopeFlappingOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := &Server{pool: pool, log: discardLog()}
	w := httptest.NewRecorder()
	s.AlertScope(w, httptest.NewRequest(http.MethodGet, "/api/alertscope?part=flapping", nil))
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	if _, ok := out["flapping"]; w.Code != http.StatusOK || !ok {
		t.Errorf("GET /api/alertscope?part=flapping: %d %.300s", w.Code, w.Body.String())
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	name := fmt.Sprintf("flapping-%d", time.Now().UnixNano())
	var inst int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`, name).Scan(&inst); err != nil {
		t.Fatal(err)
	}
	// an instance rule carries its own instance_id, as the rules page writes one: the column the join met twice
	var rule int64
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.alert_rules (name, metric, op, warning, scope, instance_id, instance_name, created_by, created_at)
		VALUES ('flapping row', 'cpu_pct', 'above', 80, 'instance', $1, $2, 'test', now()) RETURNING rule_id`, inst, name).Scan(&rule); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.alert_rule_state (instance_id, metric, rule_id, state, since, evaluated_at, flapping_since)
		VALUES ($1, 'cpu_pct', $2, 'warning', now(), now(), now() - interval '10 minutes')`, inst, rule); err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(ctx, sqlAlertFlapping)
	if err != nil {
		t.Fatalf("the flapping part on a store with a flapping series: %v", err)
	}
	defer rows.Close()
	cols := rows.FieldDescriptions()
	found := 0
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			t.Fatal(err)
		}
		row := map[string]any{}
		for i, c := range cols {
			row[c.Name] = vals[i]
		}
		if fmt.Sprint(row["rule_id"]) != fmt.Sprint(rule) {
			continue
		}
		found++
		if row["instance"] != name || row["rule_name"] != "flapping row" || row["metric"] != "cpu_pct" {
			t.Errorf("the planted series reads instance %v, rule %v, metric %v (want %s, flapping row, cpu_pct)", row["instance"], row["rule_name"], row["metric"], name)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("the flapping part on a store with a flapping series: %v", err)
	}
	if found != 1 {
		t.Errorf("the planted flapping series: %d rows, want 1", found)
	}
}
