package web

import (
	"sync/atomic"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// keepPageIntervals stores m as WatchPageIntervals does after a read (tests only).
func keepPageIntervals(s *Server, m map[string]map[string]int) {
	p := &atomic.Pointer[map[string]map[string]int]{}
	p.Store(&m)
	pageIntervalSets.Store(s.self(), p)
}

// TestPageIntervalMap: pgvigil mcp's stale check gets each page instance's own intervals - the
// merged list's instances that are not the file's, each by the rule it is given; a file instance keeps the file's.
func TestPageIntervalMap(t *testing.T) {
	all := []config.Instance{{Name: "pgfile", Engine: config.EnginePostgres}, {Name: "p-a", Engine: config.EnginePostgres,
		Schedules: map[string]config.Duration{"activity": {}}}}
	rule := func(in config.Instance) map[string]int {
		if d, ok := in.Schedules["activity"]; ok {
			return map[string]int{"activity": int(d.Seconds())}
		}
		return map[string]int{"activity": 60}
	}
	m := pageIntervalMap(all, map[string]bool{"pgfile": true}, rule)
	if len(m) != 1 || len(m["p-a"]) != 1 || m["p-a"]["activity"] != 0 {
		t.Errorf("the map: %v (want p-a alone, activity 0)", m)
	}
	s := &Server{log: discardLog()}
	t.Cleanup(func() { pageIntervalSets.Delete(s) })
	if got := s.pageIntervalsNow(); got != nil {
		t.Errorf("no watcher: %v, want nil", got)
	}
	keepPageIntervals(s, m)
	if got := s.pageIntervalsNow(); got["p-a"]["activity"] != 0 || len(got) != 1 {
		t.Errorf("after a read: %v", got)
	}
}
