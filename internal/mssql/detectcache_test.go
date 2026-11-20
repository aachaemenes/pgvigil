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
	if _, _, ok := cachedDetect(in, at); ok {
		t.Fatal("an instance never detected has a cached detect")
	}
	rememberDetect(in, Info{Kind: KindAzureDB, ServiceObjective: "S0", PoolTag: "stale"}, 41, at)
	cases := []struct {
		what string
		in   config.Instance
		now  time.Time
		ok   bool
	}{
		{"fresh", in, at.Add(time.Minute), true},
		// the bound an instance on which every collection skips waits for its next connect (docs/alerts.md): 2 minutes
		{"two minutes on", in, at.Add(2 * time.Minute), false},
		{"just under the bound", in, at.Add(detectCacheTTL - time.Second), true},
		{"at the bound", in, at.Add(detectCacheTTL), false},
		{"the clock set back", in, at.Add(-time.Second), false},
		{"another DSN", config.Instance{Name: in.Name, Engine: in.Engine, DSNRaw: "env:B", Platform: in.Platform}, at.Add(time.Minute), false},
		{"a forced platform", config.Instance{Name: in.Name, Engine: in.Engine, DSNRaw: in.DSNRaw, Platform: "onprem"}, at.Add(time.Minute), false},
	}
	for _, c := range cases {
		info, id, ok := cachedDetect(c.in, c.now)
		if ok != c.ok {
			t.Errorf("%s: cached = %v, want %v", c.what, ok, c.ok)
		}
		if ok && id != 41 {
			t.Errorf("%s: instance %d, want the connecting run's 41", c.what, id)
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
	if info, _, ok := cachedDetect(untagged, at.Add(time.Minute)); !ok || info.PoolTag != "" {
		t.Errorf("an untagged instance: %+v %v, want no pool tag (the detect's own is never kept)", info, ok)
	}
	// a newer detect replaces the older: the skip follows the server as it is now
	rememberDetect(in, Info{Kind: KindAzureDB, ServiceObjective: "S3"}, 42, at.Add(2*time.Minute))
	if info, id, ok := cachedDetect(in, at.Add(3*time.Minute)); !ok || info.ServiceObjective != "S3" || id != 42 {
		t.Errorf("after a newer detect: %+v %v, want S3 and fresh", info, ok)
	}
}

// Every collection gives the same Applies answer on the cached detect as on the fresh one, for each Kind with the
// login's rights on and off and with and without a pool tag or the linked server test tag (Applies reads only the
// Info; the cache keeps the detect's Info and sets both tags from the configuration: task 409's
// mssql_linkedserver_test applies by the tag).
func TestCachedSkipEveryCollection(t *testing.T) {
	at := time.Now()
	for _, kind := range []Kind{KindServer, KindRDS, KindAzureDB, KindAzureMI, KindCloudSQL} {
		for _, rights := range []bool{false, true} {
			for _, tags := range [][]string{nil, {"pool:x"}, {LinkedServerTestTag}} {
				in := config.Instance{Name: "cache-every", Engine: config.EngineSQLServer, DSNRaw: "env:A", Tags: tags}
				fresh := Info{Kind: kind, Major: 16, VersionNum: 160000, EngineEdition: 3, HADREnabled: rights,
					ViewServerState: rights, ViewAnyDefinition: rights, MsdbAccess: rights, ViewDatabaseState: rights,
					ServerStateRead: rights, ServiceObjective: "S3"}
				if kind == KindAzureDB {
					fresh.EngineEdition = 5
				}
				rememberDetect(in, fresh, 7, at)
				cached, _, ok := cachedDetect(in, at.Add(time.Second))
				if !ok {
					t.Fatal("no cached detect")
				}
				fresh.PoolTag = poolTag(in)
				fresh.LinkedServerTest = linkedServerTest(in)
				for _, c := range All() {
					a1, w1 := c.Applies(fresh)
					a2, w2 := c.Applies(cached)
					if a1 != a2 || w1 != w2 {
						t.Errorf("%s on %s (rights %v, tags %v): fresh %v %q, cached %v %q", c.Name(), kind, rights, tags, a1, w1, a2, w2)
					}
				}
			}
		}
	}
	detectCache.Delete("cache-every")
}
