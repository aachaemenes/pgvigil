package web

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// newestFunctionText is the text of pgvigil.<name> as the migration files of this tree define it last in name order
// (../repo/sql: the order Migrate applies them in, so what a migrated store holds): from its CREATE line to the line
// that closes its body.
func newestFunctionText(t *testing.T, name string) string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join("..", "repo", "sql", "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("the migration files: %v (%d found)", err, len(files))
	}
	sort.Strings(files)
	head := regexp.MustCompile(`(?m)^CREATE OR REPLACE FUNCTION pgvigil\.` + regexp.QuoteMeta(name) + `\(`)
	for i := len(files) - 1; i >= 0; i-- {
		b, err := os.ReadFile(files[i])
		if err != nil {
			t.Fatal(err)
		}
		loc := head.FindIndex(b)
		if loc == nil {
			continue
		}
		rest := string(b[loc[0]:])
		end := regexp.MustCompile(`(?m)\$\$;[ \t]*$`).FindStringIndex(rest)
		if end == nil {
			t.Fatalf("%s: pgvigil.%s has no closing $$; line", files[i], name)
		}
		return rest[:end[1]]
	}
	t.Fatalf("no migration file defines pgvigil.%s", name)
	return ""
}

// TestRetentionRowsOfTheHAJoin: the Data Retention page reads its rows from the text of pgvigil.purge() and of the
// *_purge functions it calls (q_retention.go's purgeRules and retentionWords). Over those texts as this tree's
// migration files define them last, the HA join's tables read as the page says them: the five sample parents of 0142
// and 0143 'monthly partitions'; the role changes, the owner changes and the seeding rows 'rows older than the age'
// by their time column, judged against the age; mssql_repl_hourly a conditional rule (a year at least, as
// mssql_backup_roots_seen's 400 days), not 'kept whole'; and replication_hourly_purge among the functions purge()
// calls (0150's hours, kept by their own age). No store: the files are the text a migrated store holds, and a store
// test of the page would read whatever purge() another test left on the shared store.
func TestRetentionRowsOfTheHAJoin(t *testing.T) {
	main := newestFunctionText(t, "purge")
	srcs := []string{main}
	hours := false
	seen := map[string]bool{}
	for _, m := range reCalled.FindAllStringSubmatch(main, -1) {
		if seen[m[1]] {
			continue
		}
		seen[m[1]] = true
		hours = hours || m[1] == "replication_hourly_purge"
		srcs = append(srcs, newestFunctionText(t, m[1]))
	}
	if !hours {
		t.Errorf("purge() does not call replication_hourly_purge(): it calls %v", seen)
	}
	rules := purgeRules(srcs)
	for _, p := range []string{"mssql_repl_sample", "mssql_ag_replica_sample", "mssql_ag_dbcounter_sample", "mssql_mirroring_sample", "mssql_logrestore_sample"} {
		if words, _, _, judged := retentionWords(rules[p]); words != "monthly partitions" || !judged {
			t.Errorf("%s: the page says %q (judged %v); want monthly partitions, judged", p, words, judged)
		}
	}
	for _, c := range [][2]string{{"mssql_mirroring_role_changes", "at"}, {"mssql_fci_owner_changes", "at"}, {"mssql_ag_seeding", "snapshot_at"}} {
		if words, column, _, judged := retentionWords(rules[c[0]]); words != "rows older than the age" || column != c[1] || !judged {
			t.Errorf("%s: the page says %q by %q (judged %v); want rows older than the age by %s, judged", c[0], words, column, judged, c[1])
		}
	}
	if words, _, _, judged := retentionWords(rules["mssql_repl_hourly"]); !strings.HasPrefix(words, "rows older than the age, under conditions") || judged {
		t.Errorf("mssql_repl_hourly: the page says %q (judged %v); want a conditional rule, not judged", words, judged)
	}
}
