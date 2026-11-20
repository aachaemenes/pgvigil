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

// Every file that reads an instance's dsn (in.DSN()) or a door's monitoring string (.Monitor) and connects with it
// applies the instance's password_secret (task B24e; the doors' Monitor dials of internal/web among them):
// a new caller fails here until it is checked and named below (the fill: collect.dialWithSecret, mssql.readSecret /
// OpenRead, secrets.FillPG on the parsed config with the door's Secret), or named as one that never dials.
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
		// task 390a: the Entra sign-in of the dsn for Resource Manager's token, no database dial
		// (password_secret refuses a fedauth= dsn: validatePasswordSecret)
		"internal/mssql/failovergroups.go":  "ARMToken: the dsn's Entra identity, no dial",
		"internal/mssql/actions.go":         "openMonitor: OpenRead with the door's Secret; Actions is the actions login's",
		"internal/actions/actions.go":       "DoorsFromConfig: the door's Secret; connect: secrets.FillPG",
		"internal/actions/explain.go":       "plans.Connect with the door's Secret",
		"internal/collect/jobs_actions.go":  "jobConn: secrets.FillPG with the door's Secret",
		"internal/config/config.go":         "validatePasswordSecret: no dial",
		"cmd/pgvigil/serve.go":              "the SQL Server door's Secret",
		"internal/web/actions.go":           "superusers: secrets.FillPG with the door's Secret",
		"internal/web/q_indexes.go":         "advisor.Run with the door's Secret",
		"internal/web/q_plans.go":           "plans.Explain / plans.Hypo with the door's Secret; L121 an emptiness check",
		"internal/web/q_instances_admin.go": "testConfigured: testConnectionList with the door's Secret",
		"internal/web/doorset.go":           "readLogin refuses a Secret door in words; the rest copies or checks strings",
		// four callers met password_secret first here
		"internal/collect/logical.go":      "an emptiness check; each other database read through onDatabase: connectCounted",
		"internal/collect/patroni.go":      "the Patroni REST host from the dsn: no database dial",
		"internal/mssql/backup_history.go": "openBackupFilePool: readSecret, the secret's login and password on the file check's pool",
		"internal/mssql/verify_backup.go":  "the verify's read-login checks and watch: openMonitor with the door's Secret",
	}
	root := filepath.Join("..", "..")
	use := regexp.MustCompile(`\bin\.DSN\(\)|\.Monitor\b`)
	var found []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && (d.Name() == "node_modules" || d.Name() == ".git" || filepath.Clean(p) == filepath.Join(root, "web")) {
			return filepath.SkipDir // the top-level web/ (TypeScript) alone: internal/web is Go and is read
		}
		// the go tool's own rule for ./...: a directory whose name starts with '.' or '_', or named testdata, holds
		// no package of the build (an untracked copy of old sources there is not a caller)
		if d.IsDir() && p != root && (strings.HasPrefix(d.Name(), ".") || strings.HasPrefix(d.Name(), "_") || d.Name() == "testdata") {
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
