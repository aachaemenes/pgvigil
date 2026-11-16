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

// TestProbeFindingsShape (B24h-1c part 2; the fold's #2, #3, #13, B24h-c): the threshold keys (warning only, settable
// empty), the findings and the fold as B24h's own views, and every arm of a joined object in the join-lines file
func TestProbeFindingsShape(t *testing.T) {
	b, err := os.ReadFile("sql/0254_probe.sql")
	if err != nil {
		t.Fatalf("0254_probe.sql: %v", err)
	}
	for _, re := range []string{
		`\('round_trip_time', '(?:[^']|'')+', 'seconds', 'over', 0\.040, NULL,`,
		`\('ping_time', '(?:[^']|'')+', 'seconds', 'over', 0\.010, NULL,`,
		`(?s)CREATE OR REPLACE VIEW pgvigil\.collector_probe_findings AS.*'query round trip slow'.*'ping slow'.*'host not answering ping'`,
		`(?s)CREATE OR REPLACE VIEW pgvigil\.collector_probe_fold AS.*'network slow from this collector'`,
	} {
		if !regexp.MustCompile(re).Match(b) {
			t.Errorf("0254 does not match %s", re)
		}
	}
	j, err := os.ReadFile("../../scripts/b24h-join-lines.sql")
	if err != nil {
		t.Fatalf("scripts/b24h-join-lines.sql: %v", err)
	}
	for _, want := range []string{"pgvigil.collector_probe_findings", "'query round trip slow', 'ping slow', 'host not answering ping'",
		"scripts/b24h-join-draft-alertdue.sql", "'round_trip_time', 'ping_time'"} {
		if !regexp.MustCompile(regexp.QuoteMeta(want)).Match(j) {
			t.Errorf("the join lines lack %s", want)
		}
	}
	// line 3's terms are in the alert_due draft the join lines name (the B24h-1 fold, F9 part d): collector_probe_state
	// read once a pass, the held rows and hosts as CTEs from that read in place of the views collector_probe_held /
	// collector_probe_held_hosts
	d, err := os.ReadFile("../../scripts/b24h-join-draft-alertdue.sql")
	if err != nil {
		t.Fatalf("scripts/b24h-join-draft-alertdue.sql: %v", err)
	}
	for _, want := range []string{"FROM pgvigil.collector_probe_state", "probe_held AS MATERIALIZED (     -- B24h line 3: as collector_probe_held",
		"probe_held_hosts AS MATERIALIZED (   -- B24h line 3: as collector_probe_held_hosts"} {
		if !regexp.MustCompile(regexp.QuoteMeta(want)).Match(d) {
			t.Errorf("the alert_due draft lacks %s", want)
		}
	}
}
