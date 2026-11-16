package web

import "testing"

// TestOverviewHasThePatroniChecks: Patroni's checks (0144's pg_patroni_checks: no leader, a member down, paused, a
// pending restart, the DCS not reached, the REST API not answering) are an overview check of their own, 'patroni' -
// what the Summary's Replication column and /api/overview read. 0144 leaves this line to the join.
func TestOverviewHasThePatroniChecks(t *testing.T) {
	for _, c := range overviewChecks {
		if c.name == "patroni" {
			return
		}
	}
	t.Error("no overview check is named 'patroni': a Patroni cluster without a leader shows on no Summary cell")
}
