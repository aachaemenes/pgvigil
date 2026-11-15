package repo

import (
	"os"
	"regexp"
	"testing"
)

// TestProbeMigration (B24h-1c; the B24h fold's B24h-d, #5; the lead's 03:3x join-file rule): 0254 creates B24h's own
// objects and adds collector_load's three round-trip columns; it re-creates nothing made below 0190
func TestProbeMigration(t *testing.T) {
	b, err := os.ReadFile("sql/0254_probe.sql")
	if err != nil {
		t.Fatalf("0254_probe.sql: %v", err)
	}
	for _, re := range []string{
		`ALTER TABLE pgvigil\.collector_load\s+ADD COLUMN IF NOT EXISTS rt_count int NOT NULL DEFAULT 0`,
		`ADD COLUMN IF NOT EXISTS rt_ms_sum bigint NOT NULL DEFAULT 0`,
		`ADD COLUMN IF NOT EXISTS rt_ms_max int NOT NULL DEFAULT 0`,
		`CREATE TABLE IF NOT EXISTS pgvigil\.collector_probe \(`,
		`method\s+text NOT NULL CHECK \(method IN \('icmp', 'tcp'\)\)`,
		`answered\s+int,`,
		`PRIMARY KEY \(minute, collector_id, address\)`,
		`CREATE TABLE IF NOT EXISTS pgvigil\.collector_probe_host \(`,
		`PRIMARY KEY \(collector_id, address\)`,
		`CREATE OR REPLACE FUNCTION pgvigil\.import_collector_probe\(p_collector text, p_minute timestamptz, p_beat jsonb\)`,
		`rt_ms_sum = l\.rt_ms_sum \+ x\.rt_ms_sum`,
		`rt_ms_max = greatest\(l\.rt_ms_max, x\.rt_ms_max\)`,
		`ON CONFLICT \(minute, collector_id, address\) DO UPDATE`,
		`first_probed = least\(h\.first_probed, EXCLUDED\.first_probed\)`,
		`last_answered = greatest\(h\.last_answered, EXCLUDED\.last_answered\)`,
	} {
		if !regexp.MustCompile(re).Match(b) {
			t.Errorf("0254 does not match %s", re)
		}
	}
	// nothing made below 0190 is re-created here (its arms go to scripts/b24h-join-lines.sql)
	for _, re := range []string{`(?i)CREATE OR REPLACE (VIEW|FUNCTION) pgvigil\.(findings|alert_due|purge|import_collector_beat|collector_shared_cause|import_pg_threshold)\b`} {
		if regexp.MustCompile(re).Match(b) {
			t.Errorf("0254 re-creates a joined object (%s)", re)
		}
	}
}
