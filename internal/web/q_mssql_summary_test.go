package web

import (
	"strings"
	"testing"
)

// TestSummaryCollectPre0166: the Summary's collect part in both forms - every placeholder filled; the form for a
// repository before 0166 never names collection_health_summary (its absence would fail the whole reply) and says so
// in ch_missing; the 0166 form joins it once
func TestSummaryCollectPre0166(t *testing.T) {
	for name, q := range map[string]string{"0166": sqlSummaryCollect, "pre-0166": sqlSummaryCollectPre0166} {
		if strings.Contains(q, "{ch") {
			t.Errorf("%s: a placeholder left: %s", name, q)
		}
		for _, col := range []string{"ch_level", "ch_n", "ch_detail", "ch_all_na", "ch_missing", "age_min_secs", "stale", "detail"} {
			if !strings.Contains(q, " AS "+col) {
				t.Errorf("%s: no column %s", name, col)
			}
		}
		if strings.Contains(q, "errors_24h") || strings.Contains(q, " AS failing") {
			t.Errorf("%s: the old Collection Errors columns are still read (no reader since B6.1)", name)
		}
	}
	if n := strings.Count(sqlSummaryCollect, "collection_health_summary("); n != 1 {
		t.Errorf("the 0166 form names collection_health_summary %d times, want 1", n)
	}
	if strings.Contains(sqlSummaryCollectPre0166, "collection_health_summary") || !strings.Contains(sqlSummaryCollectPre0166, "true AS ch_missing") {
		t.Errorf("the pre-0166 form: %s", sqlSummaryCollectPre0166)
	}
}

// TestSummaryCollectNoFailedLines: the collect part's detail holds the stale lines the Snapshot Age cell shows and
// nothing else - the failing collections are Collection Health's (ch_detail, which honours the acknowledgement of the
// collector errors itself), so the part reads no acknowledgement and lists no failed run
func TestSummaryCollectNoFailedLines(t *testing.T) {
	for _, bad := range []string{"the last run failed", "collector errors", "pgvigil.acks", "acked"} {
		if strings.Contains(sqlSummaryCollectBase, bad) {
			t.Errorf("the collect part still holds %q", bad)
		}
	}
}
