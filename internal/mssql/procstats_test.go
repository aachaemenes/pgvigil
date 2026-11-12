package mssql

import (
	"strings"
	"testing"
)

// The spills are the server's own column where it has one and NULL where it has none, never a 0 (0126 stores the
// NULL as 'not read on this version').
func TestProcStatsSpills(t *testing.T) {
	without := procStatsQuery(true)
	if !strings.Contains(without, "CAST(NULL AS bigint) AS spills") || strings.Contains(without, "total_spills") {
		t.Errorf("a server without total_spills must send NULL spills:\n%s", without)
	}
	for _, names := range []bool{true, false} {
		with := procStatsWithSpills(procStatsQuery(names))
		if !strings.Contains(with, "CAST(ps.total_spills AS bigint) AS spills") || strings.Contains(with, "CAST(NULL AS bigint) AS spills") {
			t.Errorf("the spills column was not put in (names %v):\n%s", names, with)
		}
	}
}
