package mssql

import (
	"strings"
	"testing"
)

// Each read kept apart sends rows of its own kind, so the import tells them apart and a 'skip' row names the read.
func TestMemoryApartReadsSendTheirKind(t *testing.T) {
	seen := map[string]bool{}
	for _, a := range memoryApart {
		if seen[a.name] {
			t.Errorf("read %q listed twice", a.name)
		}
		seen[a.name] = true
		if !strings.Contains(a.query, "'"+a.name+"' AS kind") {
			t.Errorf("read %q does not send kind %q", a.name, a.name)
		}
	}
	for _, want := range []string{"rmon", "cache", "plantype", "mgrant", "rgroup", "rpool"} {
		if !seen[want] {
			t.Errorf("read %q missing", want)
		}
	}
}

// The ported reads keep their sources' filters (sp_PressureDetector's cache exclusions, the resource monitor ring
// buffer, the collector's own session left out of the grants) and sp_BlitzFirst 45's TokenAndPermUserStore.
func TestMemoryReadsKeepTheirSourcesFilters(t *testing.T) {
	for _, c := range []struct{ name, query, want string }{
		{"cache", memoryCacheSQL, "N'msdb', N'model_replicatedmaster', N'model_msdb', N'model', N'master', N'mssqlsystemresource'"},
		{"cache", memoryCacheSQL, "HAVING SUM(domcc.pages_in_use_kb) / 1024. / 1024. > 0"},
		{"rmon", memoryRmonSQL, "N'RING_BUFFER_RESOURCE_MONITOR'"},
		{"mgrant", memoryGrantQuerySQL, "WHERE g.session_id <> @@SPID"},
		{"mgrant", memoryGrantQuerySQL, "g.query_cost"},
		{"totals", memoryTotalsSQL, "type = N'USERSTORE_TOKENPERM' AND name = N'TokenAndPermUserStore'"},
		{"totals", memoryTotalsSQL, "type = N'MEMORYCLERK_XTP'"},
		{"counters", memoryCounterSQL, "N'Maximum Workspace Memory (KB)'"},
	} {
		if !strings.Contains(c.query, c.want) {
			t.Errorf("%s: %q not in the read", c.name, c.want)
		}
	}
}
