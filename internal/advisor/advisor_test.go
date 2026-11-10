package advisor

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestExplainable(t *testing.T) {
	for _, c := range []struct {
		text    string
		version int
		ok      bool
	}{
		{"select count(*) from t where a = $1", 180000, true},
		{"select count(*) from t where a = $1", 150000, false},
		{"/* app */ SELECT * FROM t WHERE a = 5", 150000, true},
		{"with x as (delete from t returning *) select * from x", 180000, false},
		{"update t set a = 1 where b = $1", 180000, false},
		{"select 1; select 2", 180000, false},
		{"select 1;", 180000, true},
		{"/* a /* nested */ ; */ select 1", 180000, false}, // the ; the server would act on stays in the checked text
		{"-- note;\nselect 1", 180000, true},
		{"select 1 -- trailing; comment", 180000, false},
	} {
		if got := explainable(c.text, c.version) == ""; got != c.ok {
			t.Errorf("explainable(%q, %d) = %v, want %v (%s)", c.text, c.version, got, c.ok, explainable(c.text, c.version))
		}
	}
}

func TestCreateIndexShape(t *testing.T) {
	for ddl, ok := range map[string]bool{
		"CREATE INDEX ON public.t USING btree (a)":           true,
		"create index on t (a, b)":                           true,
		"CREATE INDEX ON t (a); DROP TABLE t":                false,
		"DROP INDEX x":                                       false,
		"CREATE UNIQUE INDEX ON t (a)":                       false,
		"CREATE INDEX ON public.t USING btree (a) WHERE b>0": true,
	} {
		if createIndexRE.MatchString(ddl) != ok {
			t.Errorf("%q: want %v", ddl, ok)
		}
	}
}

// TestRunLive runs the advisor against a server with pg_qualstats and hypopg (PGVIGIL_ADVISOR_DSN; scripts/proof-indexes.sh
// part B sets it on a throwaway container) and checks what the proof's header expects: ADVISOR_EXPECT_DDL is in the
// suggestions, tested on at least one statement that uses the hypothetical index with a positive gain.
func TestRunLive(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_ADVISOR_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_ADVISOR_DSN not set")
	}
	rep, err := Run(context.Background(), dsn, "", Options{MinFilter: 50})
	if err != nil {
		t.Fatal(err)
	}
	out, _ := json.MarshalIndent(rep, "", "  ")
	t.Logf("report:\n%s", out)
	if rep.Skipped != "" {
		t.Fatalf("skipped: %s", rep.Skipped)
	}
	want := os.Getenv("ADVISOR_EXPECT_DDL")
	if note := os.Getenv("ADVISOR_EXPECT_NOTE"); note != "" {
		// the login cannot plan the statements: the suggestion is there, its statements say why they were not tested
		for _, s := range rep.Suggestions {
			for _, q := range s.Queries {
				if strings.EqualFold(s.DDL, want) && strings.Contains(q.Note, note) && q.CostAfter == nil {
					return
				}
			}
		}
		t.Fatalf("%q: no statement with the note %q", want, note)
	}
	for _, s := range rep.Suggestions {
		if !strings.EqualFold(s.DDL, want) {
			continue
		}
		for _, q := range s.Queries {
			if q.Used && q.Gain != nil && *q.Gain > 0 {
				return
			}
		}
		t.Fatalf("%s: no statement uses the hypothetical index with a gain", want)
	}
	t.Fatalf("%q not suggested", want)
}
