package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// TestUninstallKnowsEveryGroupRole (AGENTROLE, the lead's uninstall row): 'uninstall -drop-repository' drops the
// cluster-wide group roles the migrations make, so its list holds every one of them and nothing else - read here from
// the migration files themselves (every 'CREATE ROLE pgvigil_<name> NOLOGIN', in file order), not from a second hand
// list. A group a migration adds and the list lacks would be left on the server after an uninstall.
func TestUninstallKnowsEveryGroupRole(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "..", "internal", "repo", "sql", "*.sql"))
	if err != nil || len(files) < 100 {
		t.Fatalf("the migration files: %d found, %v", len(files), err)
	}
	re := regexp.MustCompile(`CREATE ROLE (pgvigil_[a-z_]+) NOLOGIN`)
	var made []string
	where := map[string]string{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range re.FindAllStringSubmatch(string(b), -1) {
			if _, seen := where[m[1]]; !seen {
				where[m[1]] = filepath.Base(f)
				made = append(made, m[1])
			}
		}
	}
	got := pgvigilGroups()
	var missing, extra []string
	for _, g := range made {
		if !slices.Contains(got, g) {
			missing = append(missing, fmt.Sprintf("%s (%s)", g, where[g]))
		}
	}
	for _, g := range got {
		if _, ok := where[g]; !ok {
			extra = append(extra, g)
		}
	}
	if len(missing) > 0 {
		t.Errorf("uninstall -drop-repository leaves the group role(s) the migrations make: %s", strings.Join(missing, ", "))
	}
	if len(extra) > 0 {
		t.Errorf("uninstall's group roles no migration makes: %s", strings.Join(extra, ", "))
	}
	if !slices.Equal(got, made) {
		t.Errorf("uninstall's group roles %v, want the migrations' in their order %v", got, made)
	}
}
