package web

import (
	"regexp"
	"strings"
	"testing"
)

// TestCollectorLoadProbeColumns (B24h-1e; H6): the Collector page's load grid carries the query round trip over the
// hour and the host's probe - its method, rounds and answers in the hour, the answered average and longest, when it
// last answered (the page words a host that never answered or stopped while connections open)
func TestCollectorLoadProbeColumns(t *testing.T) {
	for _, c := range []string{"rt_avg_s", "rt_max_s", "probe_method", "probe_rounds_1h", "probe_answered_1h", "probe_avg_s", "probe_max_s", "probe_last_answered"} {
		if !regexp.MustCompile(`AS ` + c + `\b`).MatchString(sqlCollectorLoad) {
			t.Errorf("sqlCollectorLoad has no column %s", c)
		}
	}
	for _, src := range []string{"l.rt_ms_sum", "pgvigil.collector_probe_host"} {
		if !strings.Contains(sqlCollectorLoad, src) {
			t.Errorf("sqlCollectorLoad does not read %s", src)
		}
	}
}
