package main

import (
	"strings"
	"testing"
)

// C13 / B9d: 'pgvigil mssql-agent-alerts' prints the script (-print), its drop twin (-print -drop), and refuses
// anything else without printing a line of T-SQL.
func TestMSSQLAgentAlertsCommand(t *testing.T) {
	run := func(args ...string) (string, error) {
		var b strings.Builder
		err := mssqlAgentAlerts(&b, args)
		return b.String(), err
	}
	out, err := run("-print", "-operator", "dba team", "-email", "dba@example.com", "-ag")
	if err != nil || !strings.Contains(out, "DECLARE @operator sysname = N'dba team';") || !strings.Contains(out, "DECLARE @include_ag bit = 1;") {
		t.Fatalf("-print with an operator: %v\n%.300s", err, out)
	}
	if out, err := run("-print", "-drop"); err != nil || !strings.Contains(out, "sp_delete_alert") || strings.Contains(out, "sp_add_alert") {
		t.Fatalf("-print -drop: %v\n%.300s", err, out)
	}
	for name, args := range map[string][]string{
		"no -print":                      {},
		"-drop alone":                    {"-drop"},
		"-drop with an operator":         {"-print", "-drop", "-operator", "x"},
		"an address without an operator": {"-print", "-email", "a@b.c"},
		"a stray word":                   {"-print", "now"},
		"an unknown flag":                {"-print", "-force"},
	} {
		if out, err := run(args...); err == nil || out != "" {
			t.Errorf("%s: err %v, printed %d bytes", name, err, len(out))
		}
	}
}
