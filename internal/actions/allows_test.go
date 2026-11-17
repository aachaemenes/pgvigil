package actions

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// Task 7b (review-29 N9): a PostgreSQL instance's door carries its actions: list, so save_table is off unless named.
func TestDoorCarriesTheActionsList(t *testing.T) {
	cfg := &config.Config{Instances: []config.Instance{
		{Name: "pg-save", DSNRaw: "host=a", ActionsDSNRaw: "host=a user=act", Actions: []string{"save_table"}},
		{Name: "pg-plain", DSNRaw: "host=b", ActionsDSNRaw: "host=b user=act"},
	}}
	ds := DoorsFromConfig(cfg)
	if !ds["pg-save"].Allows("save_table") {
		t.Errorf("pg-save names save_table: Allows(save_table) = false")
	}
	if ds["pg-save"].Allows("job_start") {
		t.Errorf("pg-save does not name job_start: Allows(job_start) = true")
	}
	if ds["pg-plain"].Allows("save_table") {
		t.Errorf("pg-plain names nothing: Allows(save_table) = true")
	}
}
