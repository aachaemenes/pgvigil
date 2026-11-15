package mssql

import (
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The cache decides a skip only on a detect read under the same configuration and younger than detectCacheTTL;
// the pool tag is the configuration's at each use (task B2a-N1).
func TestDetectCache(t *testing.T) {
	at := time.Date(2026, 11, 14, 19, 0, 0, 0, time.UTC)
	in := config.Instance{Name: "cache-case", Engine: config.EngineSQLServer, DSNRaw: "env:A", Platform: "auto", Tags: []string{"pool:p1"}}
	detectCache.Delete(in.Name)
	t.Cleanup(func() { detectCache.Delete(in.Name) })
	if _, ok := cachedDetect(in, at); ok {
		t.Fatal("an instance never detected has a cached detect")
	}
	rememberDetect(in, Info{Kind: KindAzureDB, ServiceObjective: "S0", PoolTag: "stale"}, at)
	cases := []struct {
		what string
		in   config.Instance
		now  time.Time
		ok   bool
	}{
		{"fresh", in, at.Add(time.Minute), true},
		{"just under the bound", in, at.Add(detectCacheTTL - time.Second), true},
		{"at the bound", in, at.Add(detectCacheTTL), false},
		{"the clock set back", in, at.Add(-time.Second), false},
		{"another DSN", config.Instance{Name: in.Name, Engine: in.Engine, DSNRaw: "env:B", Platform: in.Platform}, at.Add(time.Minute), false},
		{"a forced platform", config.Instance{Name: in.Name, Engine: in.Engine, DSNRaw: in.DSNRaw, Platform: "onprem"}, at.Add(time.Minute), false},
	}
	for _, c := range cases {
		info, ok := cachedDetect(c.in, c.now)
		if ok != c.ok {
			t.Errorf("%s: cached = %v, want %v", c.what, ok, c.ok)
		}
		if ok && (info.Kind != KindAzureDB || info.ServiceObjective != "S0") {
			t.Errorf("%s: the cached detect = %+v", c.what, info)
		}
		if ok && info.PoolTag != "p1" {
			t.Errorf("%s: pool tag %q, want the configuration's p1", c.what, info.PoolTag)
		}
	}
	untagged := in
	untagged.Tags = nil
	if info, ok := cachedDetect(untagged, at.Add(time.Minute)); !ok || info.PoolTag != "" {
		t.Errorf("an untagged instance: %+v %v, want no pool tag (the detect's own is never kept)", info, ok)
	}
	// a newer detect replaces the older: the skip follows the server as it is now
	rememberDetect(in, Info{Kind: KindAzureDB, ServiceObjective: "S3"}, at.Add(2*time.Minute))
	if info, ok := cachedDetect(in, at.Add(11*time.Minute)); !ok || info.ServiceObjective != "S3" {
		t.Errorf("after a newer detect: %+v %v, want S3 and fresh", info, ok)
	}
}

// A collection skipped on the cached detect gives the reason the fresh detect gives: Applies reads only the Info.
func TestCachedSkipReason(t *testing.T) {
	c, ok := Get(Prefix + "azuredb_resources")
	if !ok {
		t.Fatal("mssql_azuredb_resources is not registered")
	}
	in := config.Instance{Name: "cache-reason", Engine: config.EngineSQLServer, DSNRaw: "env:A"}
	detectCache.Delete(in.Name)
	t.Cleanup(func() { detectCache.Delete(in.Name) })
	at := time.Now()
	fresh := Info{Kind: KindServer, ViewServerState: true}
	rememberDetect(in, fresh, at)
	cached, ok := cachedDetect(in, at.Add(time.Second))
	if !ok {
		t.Fatal("no cached detect")
	}
	a1, w1 := c.Applies(fresh)
	a2, w2 := c.Applies(cached)
	if a1 || a2 || w1 != w2 {
		t.Errorf("Applies fresh = %v %q, cached = %v %q", a1, w1, a2, w2)
	}
}
