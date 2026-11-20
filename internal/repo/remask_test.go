package repo

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/jobmask"
)

// TestGoStepsNameEmbeddedFiles: every Go step belongs to a migration this binary carries (a renamed file would
// otherwise lose its step without a word).
func TestGoStepsNameEmbeddedFiles(t *testing.T) {
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, n := range names {
		have[n] = true
	}
	for n := range goSteps {
		if !have[n] {
			t.Errorf("the Go step of %s names no embedded migration", n)
		}
	}
}

// TestRemaskValue: a text column masked again; a jsonb value's strings masked, its numbers written back as they were,
// its keys kept; a value with nothing to mask returned as read, unchanged.
func TestRemaskValue(t *testing.T) {
	got, changed, err := remaskValue(`ALTER LOGIN a WITH PASSWORD = '<masked>'pw1'', CHECK_POLICY = OFF`, false, false)
	if err != nil || !changed || strings.Contains(got, "pw1") {
		t.Errorf("text: %q, %v, %v", got, changed, err)
	}
	in := `{"name": "j", "n": 12345678901234567890, "steps": {"step 01": {"command": "EXECUTE dbo.DatabaseBackup @EncryptionKey = N'k1'", "retry": 3}}}`
	got, changed, err = remaskValue(in, true, false)
	if err != nil || !changed || strings.Contains(got, "k1") || !strings.Contains(got, "12345678901234567890") {
		t.Fatalf("jsonb: %q, %v, %v", got, changed, err)
	}
	var doc struct {
		Name  string
		Steps map[string]map[string]any
	}
	if err := json.Unmarshal([]byte(got), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Name != "j" || doc.Steps["step 01"]["command"] != "EXECUTE dbo.DatabaseBackup @EncryptionKey = '<masked>'" {
		t.Errorf("jsonb decoded: %+v", doc)
	}
	plain := `{"a": "plain", "b": [1, 2.50]}`
	if got, changed, err := remaskValue(plain, true, false); err != nil || changed || got != plain {
		t.Errorf("nothing to mask: %q, %v, %v", got, changed, err)
	}
}

// TestRemaskLockOrder: 0272 locks every table its step masks, in the order the imports write them (0094: import_jobs
// writes jobs, job_runs, then job_versions; import_mssql_jobs mssql_job_runs, mssql_jobs, then job_versions), so a
// collector's import running when the migrate starts waits for it instead of deadlocking with it;
// the pg_cron / pgAgent tables are masked again too.
func TestRemaskLockOrder(t *testing.T) {
	b, err := migrations.ReadFile("sql/0272_job_text_masked_again.sql")
	if err != nil {
		t.Fatal(err)
	}
	var locked []string
	for _, l := range strings.Split(string(b), "\n") {
		if rest, ok := strings.CutPrefix(l, "LOCK TABLE "); ok {
			names, _, _ := strings.Cut(rest, " IN ")
			for _, n := range strings.Split(names, ",") {
				locked = append(locked, strings.TrimPrefix(strings.TrimSpace(n), "pgvigil."))
			}
		}
	}
	want := []string{"jobs", "job_runs", "mssql_job_runs", "mssql_jobs", "job_versions"}
	if strings.Join(locked, ",") != strings.Join(want, ",") {
		t.Errorf("0272 locks %v, want %v", locked, want)
	}
	masked := map[string]bool{}
	for _, rt := range remaskTables {
		masked[rt.table] = true
	}
	for _, n := range want {
		if !masked[n] {
			t.Errorf("the step does not mask %s again", n)
		}
	}
	if len(masked) != len(want) {
		t.Errorf("the step masks %d tables, 0272 locks %d", len(masked), len(want))
	}
}

// TestRemaskPrefilterQuotes: the prefilter rides in the cursor's query as a $re$-quoted literal.
func TestRemaskPrefilterQuotes(t *testing.T) {
	if strings.Contains(jobmask.Prefilter, "$re$") {
		t.Fatal("jobmask.Prefilter holds $re$")
	}
}
