package remote

// cursorSource is one source (or source prefix) a collector asks before it reads, and how a remote collector answers
// it. scan_test.go holds the table both ways: every cursor(ctx, <source>) call of internal/collect, internal/mssql and
// internal/engines resolves to an entry here, every entry to a call; every current SQL function writing a cursor table
// is a writer here (rowWriters, an entry's SQL or otherWriters), every writer named here writes one. The store's reader
// answers only a source of this table: a collector source with no rule is an error in words, never a silent re-read.
type cursorSource struct {
	Name   string
	Prefix bool     // Name is a prefix: the source is Name + a database, a group, a directory, a guid
	Reader string   // the store.Reader method that asks it: log (LogCursor), mssql (MSSQLCursor), seq (MSSQLSeqCursor)
	Rule   string   // row: the batch's own {kind:'cursor', source} row (cursors.go); view:<v>: that view's rule; setting: see below
	SQL    []string // a derived source's writers (the functions its view's rule follows)
}

// Rule "setting": a value the hub's own pages set (not an import); it never reaches a remote site, whose reader answers
// it not found - for errorlog:search, no search strings (mssql_errorlog_search_set, 0091 L246-275).
var cursorSources = []cursorSource{
	// PostgreSQL (internal/collect)
	{Name: "cloudwatch:", Prefix: true, Reader: "log", Rule: "row"},
	{Name: "serverlog:", Prefix: true, Reader: "log", Rule: "row"},
	{Name: "pgaudit:", Prefix: true, Reader: "log", Rule: "row"},
	{Name: "pi", Reader: "log", Rule: "row"},
	{Name: "amcheck", Reader: "log", Rule: "view:amcheck", SQL: []string{"import_amcheck"}},
	{Name: "schema_ddl:", Prefix: true, Reader: "log", Rule: "view:schema", SQL: []string{"import_schema"}},
	// SQL Server file and event readers (internal/mssql, batch path)
	{Name: "errorlog", Reader: "mssql", Rule: "row"},
	{Name: "errorlog:search", Reader: "mssql", Rule: "setting", SQL: []string{"mssql_errorlog_search_set"}},
	{Name: "defaulttrace", Reader: "mssql", Rule: "row"},
	{Name: "syshealth", Reader: "mssql", Rule: "row"},
	{Name: "audit:", Prefix: true, Reader: "mssql", Rule: "row"},
	{Name: "pgvigil_", Prefix: true, Reader: "mssql", Rule: "row"}, // the product's own xe sessions (XESessionName)
	{Name: "system_health", Reader: "mssql", Rule: "row"},          // the system_health session's file / ring (xe.go)
	{Name: "mssql_tables", Reader: "mssql", Rule: "row"},
	{Name: "mssql_linkedserver_test", Reader: "mssql", Rule: "row"},
	{Name: "mssql_maintenance:", Prefix: true, Reader: "mssql", Rule: "row"},
	{Name: "mssql_maintenance_open:", Prefix: true, Reader: "mssql", Rule: "row"},
	{Name: "mssql_maintenance_purity:", Prefix: true, Reader: "mssql", Rule: "row"},
	{Name: "st:", Prefix: true, Reader: "mssql", Rule: "view:mssql_stats", SQL: []string{"import_mssql_stats"}},
	{Name: "ct:", Prefix: true, Reader: "mssql", Rule: "view:mssql_constraints", SQL: []string{"import_mssql_constraints"}},
	{Name: "ix:", Prefix: true, Reader: "mssql", Rule: "view:mssql_indexes", SQL: []string{"import_mssql_indexes_0092"}},
	// SQL Server one-number cursors (mssql_hadr_cursor)
	{Name: "jobs", Reader: "seq", Rule: "view:mssql_jobs", SQL: []string{"import_mssql_jobs"}},
	{Name: "jobs_mark", Reader: "seq", Rule: "view:mssql_jobs", SQL: []string{"import_mssql_jobs"}},
	{Name: "backup_sets", Reader: "seq", Rule: "view:mssql_backup_files", SQL: []string{"import_mssql_backup_files"}},
	{Name: "backup_sets_mark", Reader: "seq", Rule: "view:mssql_backup_files", SQL: []string{"import_mssql_backup_files"}},
	{Name: "backup_history", Reader: "seq", Rule: "view:mssql_backup_history", SQL: []string{"import_mssql_backup_history"}},
	{Name: "backup_history_mark", Reader: "seq", Rule: "view:mssql_backup_history", SQL: []string{"import_mssql_backup_history"}},
	{Name: "restore_history", Reader: "seq", Rule: "view:mssql_backup_history", SQL: []string{"import_mssql_backup_history"}},
	{Name: "restore_history_mark", Reader: "seq", Rule: "view:mssql_backup_history", SQL: []string{"import_mssql_backup_history"}},
	{Name: "azdb_since", Reader: "seq", Rule: "view:mssql_azuredb_resources", SQL: []string{"import_mssql_azuredb_resources"}},
	{Name: "qs_since:", Prefix: true, Reader: "seq", Rule: "view:mssql_querystore", SQL: []string{"import_mssql_querystore_0083"}},
	{Name: "qs_plan:", Prefix: true, Reader: "seq", Rule: "view:mssql_querystore", SQL: []string{"import_mssql_querystore_0083"}},
}

// rowWriters are the current functions that store a batch's own cursor rows - the generic rule of cursors.go follows
// them (the later of two log times; a SQL Server source's last row in the batch).
var rowWriters = []string{
	"import_logs", "import_pgaudit", "import_pi",
	"import_mssql_xe_base", "import_mssql_readers_base", "import_mssql_audit", "import_mssql_xe_captures",
	"import_mssql_tables", "import_mssql_linkedserver_test", "import_mssql_maintenance",
}

// otherWriters write a cursor table without a source of their own, each with why no rule follows it.
var otherWriters = map[string]string{
	"mssql_hadr_read":         "the guard rows (mssql_hadr_reads): hadrGuard keeps them as hadr_read:<view>",
	"purge":                   "the retention purge (cursors not moved within the retention, plans, a dropped database's schema_ddl): a remote collector keeps reading on from where it stopped",
	"mssql_plancache_purge":   "the retention purge of the stats and index guard rows: a kept guard refuses only a batch older than the retention",
	"mssql_index_depth_purge": "the retention purge of the constraint guard rows: as mssql_plancache_purge",
}

// sourceRule is the table's entry for a source a collector asks (an exact name, else the longest prefix).
func sourceRule(source string) (cursorSource, bool) {
	best, found := cursorSource{}, false
	for _, s := range cursorSources {
		switch {
		case !s.Prefix && s.Name == source:
			return s, true
		case s.Prefix && len(source) > len(s.Name) && source[:len(s.Name)] == s.Name && (!found || len(s.Name) > len(best.Name)):
			best, found = s, true
		}
	}
	return best, found
}
