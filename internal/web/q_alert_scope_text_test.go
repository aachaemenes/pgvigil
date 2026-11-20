package web

import (
	"strings"
	"testing"
)

// TestAlertScopeFindingTextTagged: every part of GET /api/alertscope that returns a finding's check and value carries
// the tags the findings route reads them by - the value '"value@fvalue"', the check '"setting@fcheck"' and the row's
// instance ('@inst', named or not) - so a check that quotes a statement (a blocked-process head's text, textnow's
// list) follows the instance's query_text policy NOW (textread.go). The history and the held sends returned the value
// untagged: proof-text-now's walk read 'LEAK /api/alertscope [fleet]: 2 strings, mssql_blocked_reports.blocking_statement'
// under none, normalized and mixed (the LAST run's j16d2, 65083820), once 52a624bf made the route answer 200.
func TestAlertScopeFindingTextTagged(t *testing.T) {
	for _, c := range []struct{ part, sql string }{
		{"held", sqlAlertHeld},
		{"history", sqlFindingsHistory},
		{"alerts", sqlInstanceAlerts},
	} {
		for _, want := range []string{`"value@fvalue"`, `"setting@fcheck"`, `@inst"`} {
			if !strings.Contains(c.sql, want) {
				t.Errorf("GET /api/alertscope part=%s: its SQL lacks the tag %s - a finding's value would leave the query_text policy", c.part, want)
			}
		}
	}
}
