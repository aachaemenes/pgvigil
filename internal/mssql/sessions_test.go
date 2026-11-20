package mssql

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestSessionsWaiting: the waiting tasks summed over the wait types that are not benign (waits.go), the longest wait
// taken from those alone: a WAITFOR of an hour is no one waiting on the server.
func TestSessionsWaiting(t *testing.T) {
	rows := []collect.Row{
		{"wait_type": "LCK_M_X", "tasks": int64(2), "longest_ms": int64(4000)},
		{"wait_type": "WAITFOR", "tasks": int64(1), "longest_ms": int64(3600000)},
		{"wait_type": "PAGEIOLATCH_SH", "tasks": int32(3), "longest_ms": int64(120)},
		{"wait_type": "SLEEP_TASK", "tasks": int64(9), "longest_ms": int64(900000)},
	}
	tasks, longest := sessionsWaiting(rows)
	if tasks != 5 || longest != 4000 {
		t.Fatalf("waiting tasks %d, longest %d ms; want 5 and 4000", tasks, longest)
	}
	if tasks, longest := sessionsWaiting(nil); tasks != 0 || longest != 0 {
		t.Fatalf("no waits: %d, %d", tasks, longest)
	}
}

// TestSessionsCollector: the name, a minute's interval, and the same doors as activity.go (not Azure SQL Database,
// VIEW SERVER STATE).
func TestSessionsCollector(t *testing.T) {
	c := sessionsCollector{}
	if c.Name() != "mssql_sessions" || c.DefaultInterval().Seconds() != 60 {
		t.Fatalf("%s every %v", c.Name(), c.DefaultInterval())
	}
	if ok, why := c.Applies(Info{Kind: KindAzureDB, ViewServerState: true}); ok || why == "" {
		t.Fatalf("Azure SQL Database: %v %q", ok, why)
	}
	if ok, why := c.Applies(Info{ViewServerState: false}); ok || why == "" {
		t.Fatalf("no VIEW SERVER STATE: %v %q", ok, why)
	}
	if ok, _ := c.Applies(Info{ViewServerState: true}); !ok {
		t.Fatal("a server with VIEW SERVER STATE refused")
	}
}
