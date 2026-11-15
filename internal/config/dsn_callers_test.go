package config

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// Every file that reads an instance's dsn (in.DSN()) and connects with it applies the instance's password_secret
// (task B24e): a new caller fails here until it is checked and named below (the fill: collect.dialWithSecret,
// mssql.readSecret, the actions doors' Secret, secrets.PGWithSecret), or named as one that never dials.
func TestEveryInstanceDSNCallerIsKnown(t *testing.T) {
	known := map[string]string{
		"internal/collect/collect.go":    "Connect: dialWithSecret",
		"internal/collect/amcheck.go":    "a per-database connect: connectCounted",
		"internal/collect/extensions.go": "a per-database connect: connectCounted",
		"internal/collect/functions.go":  "a per-database connect: connectCounted",
		"internal/collect/indexes.go":    "a per-database connect: connectCounted",
		"internal/collect/roles.go":      "a per-database connect: connectCounted",
		"internal/collect/schema.go":     "a per-database connect: connectCounted",
		"internal/collect/tables.go":     "a per-database connect: connectCounted",
		"internal/collect/vacuum.go":     "a per-database connect: connectCounted",
		"internal/collect/secret.go":     "reads the dsn's user as written: no dial",
		"internal/collect/rolechange.go": "the Patroni REST host from the dsn: no database dial",
		"internal/mssql/mssql.go":        "Connect: readSecret",
		// task 390a (rel-b24p's merge): the Entra sign-in of the dsn for Resource Manager's token, no database dial
		// (password_secret refuses a fedauth= dsn: validatePasswordSecret)
		"internal/mssql/failovergroups.go": "ARMToken: the dsn's Entra identity, no dial",
		"internal/actions/actions.go":      "DoorsFromConfig: the door's Secret",
		"internal/config/config.go":        "validatePasswordSecret: no dial",
		"cmd/pgvigil/serve.go":             "the SQL Server door's Secret",
	}
	root := filepath.Join("..", "..")
	use := regexp.MustCompile(`\bin\.DSN\(\)`)
	var found []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && (d.Name() == "node_modules" || d.Name() == ".git" || d.Name() == "web") {
			return filepath.SkipDir
		}
		if d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if use.Match(b) {
			rel, _ := filepath.Rel(root, p)
			found = append(found, filepath.ToSlash(rel))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(found)
	for _, f := range found {
		if _, ok := known[f]; !ok {
			t.Errorf("%s reads an instance's dsn: does it apply password_secret? (name it in this test once it does, or once it never dials)", f)
		}
	}
	if len(found) == 0 {
		t.Fatal("no caller found: the walk read nothing")
	}
}
