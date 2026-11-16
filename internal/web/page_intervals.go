package web

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// pageIntervalSets: per server that runs no door watcher (pgvigil mcp), each page instance's intervals as its own
// watcher last read them (ST5a's review F1: mcp judged a page instance by the file's intervals alone, so a collection
// set off or slower on the page read as stale). Serve's door set carries the same map (doorSet.Expected).
var pageIntervalSets sync.Map // *Server -> *atomic.Pointer[map[string]map[string]int]

// WatchPageIntervals reads Admin > Instances' list every `every` (at once at the start) on this server's own pool and
// keeps each merged page instance's intervals by intervals(in) for the stale check (expectedNow). pgvigil mcp calls it;
// its doors stay pgvigil.yaml's. A list that cannot be read keeps the last one (the watcher logs why).
func (s *Server) WatchPageIntervals(ctx context.Context, log *slog.Logger, cfg *config.Config, every time.Duration, intervals func(config.Instance) map[string]int) {
	p := &atomic.Pointer[map[string]map[string]int]{}
	pageIntervalSets.Store(s.self(), p)
	inFile := map[string]bool{}
	for _, in := range cfg.Instances {
		inFile[in.Name] = true
	}
	config.WatchInventoryRaw(ctx, log, poolInventory{s.pool}, nil, cfg.Instances, cfg.QueryText, cfg.MSSQLCounters, every, nil, false,
		func(all []config.Instance, _ []config.PageInstance, _ int64) {
			m := pageIntervalMap(all, inFile, intervals)
			p.Store(&m)
		})
}

// pageIntervalMap: the intervals of every instance of the merged list that is not the file's (a page instance Merge
// kept: a disabled one, or one a file entry of its name shadows, is not in the list and keeps the defaults).
func pageIntervalMap(all []config.Instance, inFile map[string]bool, intervals func(config.Instance) map[string]int) map[string]map[string]int {
	m := map[string]map[string]int{}
	for _, in := range all {
		if !inFile[in.Name] {
			m[in.Name] = intervals(in)
		}
	}
	return m
}

// pageIntervalsNow: the map WatchPageIntervals keeps for this server; nil where it does not run.
func (s *Server) pageIntervalsNow() map[string]map[string]int {
	if v, ok := pageIntervalSets.Load(s.self()); ok {
		if m := v.(*atomic.Pointer[map[string]map[string]int]).Load(); m != nil {
			return *m
		}
	}
	return nil
}
