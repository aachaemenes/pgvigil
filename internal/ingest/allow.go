package ingest

import (
	"strings"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// neverReachablePrefix: the import functions a bundle may never call (R9) - the collector's own health, the alerts,
// the actions' log, the DBA Dash door, the remote ledgers and the SQL Server cursor the hub keeps itself (0329's
// import_remote_batch refuses the same)
var neverReachablePrefix = []string{"mssql_cursor", "collector_", "alert_", "actions_log", "dbadash_", "remote_"}

// AllowList is the views a bundle may carry: every collection a collector hands to its store's Import - the
// registries' (collect.Names, mssql.Names) and the one constant name at a call site (ag.go's hadr thresholds) -
// less the never-reachable ones. allow_test.go holds it to the call sites.
func AllowList() map[string]bool {
	out := map[string]bool{}
	for _, n := range append(append(collect.Names(), mssql.Names()...), mssql.Prefix+"hadr_thresholds") {
		if !neverReachableName(n) {
			out[n] = true
		}
	}
	return out
}

func neverReachableName(n string) bool {
	for _, p := range neverReachablePrefix {
		if n == p || strings.HasSuffix(p, "_") && strings.HasPrefix(n, p) {
			return true
		}
	}
	return false
}
