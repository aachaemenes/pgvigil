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

// The procedures' extremes (D421): min and max of CPU, duration, logical and physical reads, writes and spills since
// the plan was cached - the server's own column where it has one, NULL where it has none, with and without the names.
func TestProcStatsExtremes(t *testing.T) {
	cols := map[string]string{
		"min_worker_us": "min_worker_time", "max_worker_us": "max_worker_time",
		"min_elapsed_us": "min_elapsed_time", "max_elapsed_us": "max_elapsed_time",
		"min_logical_reads": "min_logical_reads", "max_logical_reads": "max_logical_reads",
		"min_physical_reads": "min_physical_reads", "max_physical_reads": "max_physical_reads",
		"min_logical_writes": "min_logical_writes", "max_logical_writes": "max_logical_writes",
		"min_spills": "min_spills", "max_spills": "max_spills",
	}
	all, sp1 := map[string]bool{"total_spills": true}, map[string]bool{}
	for _, col := range cols {
		all[col] = true
		if col != "min_spills" && col != "max_spills" {
			sp1[col] = true
		}
	}
	for _, names := range []bool{true, false} {
		without := procStatsWithExtremes(procStatsQuery(names), map[string]bool{})
		with := procStatsWithExtremes(procStatsWithSpills(procStatsQuery(names)), all)
		mixed := procStatsWithExtremes(procStatsQuery(names), sp1)
		for key, col := range cols {
			null, own := "CAST(NULL AS bigint) AS "+key, "CAST(ps."+col+" AS bigint) AS "+key
			if !strings.Contains(without, null) || strings.Contains(without, "ps."+col+" ") {
				t.Errorf("%s (names %v): a server without %s must send NULL and not read it", key, names, col)
			}
			if !strings.Contains(with, own) || strings.Contains(with, null) {
				t.Errorf("%s (names %v): a server with %s must send its own column", key, names, col)
			}
			wantNull := key == "min_spills" || key == "max_spills"
			if strings.Contains(mixed, null) != wantNull || strings.Contains(mixed, own) == wantNull {
				t.Errorf("%s (names %v) on 2016 SP1: NULL form %v, want %v", key, names, strings.Contains(mixed, null), wantNull)
			}
		}
		if !strings.Contains(with, "CAST(ps.total_spills AS bigint) AS spills") {
			t.Errorf("the spills total was lost beside the extremes (names %v)", names)
		}
		for name, q := range map[string]string{"none": without, "all": with, "2016 SP1": mixed} {
			if strings.Contains(q, "{{") {
				t.Errorf("a token was left unfilled (%s, names %v)", name, names)
			}
		}
	}
}
