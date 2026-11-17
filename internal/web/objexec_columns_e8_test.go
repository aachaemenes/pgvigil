package web

import (
	"os"
	"strings"
	"testing"
)

// TestObjectExecutionGridColumnsE8 (control audit E8; DBA Dash's ObjectExecutionSummary.cs L120-160 column order):
// the Object Execution grid shows CPU (ms/sec) between total CPU and avg CPU, and the averages of physical reads,
// logical reads and writes beside their totals - all four returned by part=objects (objCols) and not shown.
func TestObjectExecutionGridColumnsE8(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_objexec.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	order := []string{"key: 'cpu_ms', label: 'total CPU (sec)'", "key: 'cpu_ms_sec', label: 'CPU (ms/sec)'", "key: 'avg_cpu_ms', label: 'avg CPU (ms)'",
		"key: 'physical_reads', label: 'physical reads'", "key: 'avg_physical_reads', label: 'avg physical reads'",
		"key: 'logical_reads', label: 'logical reads'", "key: 'avg_logical_reads', label: 'avg logical reads'",
		"key: 'logical_writes', label: 'writes'", "key: 'avg_logical_writes', label: 'avg writes'"}
	at := 0
	for _, w := range order {
		i := strings.Index(src[at:], w)
		if i < 0 {
			t.Errorf("mssql_objexec.ts: %s missing or out of DBA Dash's order", w)
			continue
		}
		at += i + len(w)
	}
}
