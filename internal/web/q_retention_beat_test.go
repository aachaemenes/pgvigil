package web

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The Data Retention page's words for the tables the collector's beats trim themselves (the lead's 11-15 17:4x (c),
// RETENTION FORM (i) at 18:1x): the page reads the beat functions' installed text as it reads purge()'s, so its words
// follow the functions. Unit rows over the migrations' own text - a function's body as its file writes it is what
// pg_proc.prosrc holds once installed.

// sqlBody: the body of pgvigil.<name> in internal/repo/sql/<file> (between its first two $$).
func sqlBody(t *testing.T, file, name string) string {
	t.Helper()
	b, err := os.ReadFile("../repo/sql/" + file)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "FUNCTION pgvigil."+name+"(")
	if i < 0 {
		t.Fatalf("%s: no function pgvigil.%s", file, name)
	}
	j := strings.Index(s[i:], "$$")
	if j < 0 {
		t.Fatalf("%s: pgvigil.%s has no $$ body", file, name)
	}
	start := i + j + 2
	k := strings.Index(s[start:], "$$")
	if k < 0 {
		t.Fatalf("%s: pgvigil.%s's body never ends", file, name)
	}
	return s[start : start+k]
}

// TestRetentionReadsTheBeatsTrimsOnText (RETENTION row 1, red first): the beat functions' text - 0121's
// import_collector_beat and collector_trim, 0254's import_collector_probe - gives each table they trim ONE rule in the
// page's words with its fixed age and its time column, never judged against the purge age: collector_beats (at),
// collector_runs / collector_load / collector_probe (minute, by collector_trim), collector_spells (an expression: no
// column), collector_instances (seen_at), collector_streaks (last_run_at, with its conditions), collector_heartbeat
// (beat_at); a beat's delete of its own late rows (minute = p_minute) is no rule. Then every '8 days' in the three texts
// changed to '9 days': the words follow (a page that kept '8 days' fails here). RED on q_retention.go as it was: those
// deletes read as 'rows older than the age, under conditions (see purge())', collector_trim's tables as its parity line.
func TestRetentionReadsTheBeatsTrimsOnText(t *testing.T) {
	srcs := []string{
		sqlBody(t, "0121_collector_health.sql", "import_collector_beat"),
		sqlBody(t, "0121_collector_health.sql", "collector_trim"),
		sqlBody(t, "0254_probe.sql", "import_collector_probe"),
	}
	want := map[string]string{"collector_beats": "at", "collector_runs": "minute", "collector_load": "minute", "collector_probe": "minute",
		"collector_spells": "", "collector_instances": "seen_at", "collector_streaks": "last_run_at", "collector_heartbeat": "beat_at"}
	streaks := "rows older than %s days that collector_instances no longer names, under conditions, whatever the age"
	for _, days := range []string{"8", "9"} {
		texts := make([]string, len(srcs))
		for i, s := range srcs {
			texts[i] = strings.ReplaceAll(s, "interval '8 days'", "interval '"+days+" days'")
		}
		rules := purgeRules(texts)
		var got []string
		for tbl := range rules {
			got = append(got, tbl)
		}
		sort.Strings(got)
		if len(got) != len(want) {
			t.Errorf("at %s days: rules for %v, want the %d tables the beats trim", days, got, len(want))
		}
		for tbl, col := range want {
			words, column, _, judged := retentionWords(rules[tbl])
			if !strings.Contains(words, "older than "+days+" days") || strings.Contains(words, "rules:") || column != col || judged {
				t.Errorf("at %s days, %s: words %q, column %q, judged %v; want one rule 'older than %s days', column %q, not judged",
					days, tbl, words, column, judged, days, col)
			}
			// the conditions said (the review of RETENTION #1: the delete takes only the beating host's rows)
			if w := fmt.Sprintf(streaks, days); tbl == "collector_streaks" && words != w {
				t.Errorf("at %s days, collector_streaks: %q, want %q", days, words, w)
			}
		}
	}
}

// TestRetentionPurgeWordsKeptOnText (RETENTION row 2, a regression row - PASS before and after): purge()'s own text
// (0190) and the *_purge functions it calls (each defined once) keep their words - an age rule, an 'absent' rule, a
// 'no longer names' rule - every table a DELETE of theirs names keeps a rule (none dropped as a call's own rows: the
// review of RETENTION #3), and none reads a fixed age.
func TestRetentionPurgeWordsKeptOnText(t *testing.T) {
	srcs := []string{sqlBody(t, "0190_join_release2.sql", "purge"), sqlBody(t, "0064_mssql_running.sql", "mssql_running_purge"),
		sqlBody(t, "0084_mssql_reads.sql", "mssql_reads_purge"), sqlBody(t, "0092_mssql_plancache_indexes.sql", "mssql_plancache_purge"),
		sqlBody(t, "0157_qs_plans.sql", "mssql_qs_plans_purge"), sqlBody(t, "0139_job_stats_hourly.sql", "job_stats_hourly_purge")}
	rules := purgeRules(srcs)
	named := 0
	for _, src := range srcs {
		for _, m := range regexp.MustCompile(`(?i)DELETE\s+FROM\s+pgvigil\.([a-z_][a-z0-9_]*)`).FindAllStringSubmatch(src, -1) {
			named++
			if rules[m[1]] == nil {
				t.Errorf("%s: a DELETE of the purge functions names it, and it has no rule", m[1])
			}
		}
	}
	if named < 40 {
		t.Errorf("the purge functions' text names %d DELETEs, want 40 or more (a body not found whole?)", named)
	}
	for tbl, want := range map[string]string{
		"job_runs":                 "rows older than the age",
		"dms_table_stats":          "rows absent longer than the age",
		"statements_monitor_total": "rows statements_current no longer names",
	} {
		if words, _, _, _ := retentionWords(rules[tbl]); words != want {
			t.Errorf("%s: %q, want %q", tbl, words, want)
		}
	}
	for tbl, r := range rules {
		if words, _, _, _ := retentionWords(r); strings.Contains(words, " days") {
			t.Errorf("%s: %q - a purge() rule read as a fixed age", tbl, words)
		}
	}
}
