package mssql

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The last detect of each SQL Server instance, kept in the process, so RunOnce decides a collection's Applies BEFORE
// it connects: a run whose collection does not apply to the instance opens no connection (an Azure SQL Database
// skips 7 of the 12 minute collections; at 1,819 databases each skip was a connection and a detect a minute).
// Applies reads only the Info (every Applies of this package; TestCachedSkipEveryCollection), so a skip decided on a
// cached Info is the skip the fresh detect would give while the server is unchanged. Every run that connects and
// detects refreshes the entry; an entry older than detectCacheTTL is not used (the run connects and detects again).
// The bound is what an instance on which EVERY collection skips waits for its next connect (an Azure SQL Database
// whose login lacks VIEW DATABASE STATE): its 'server unreachable' and a right granted are seen up to that much later
// (docs/alerts.md); an instance where any minute collection applies connects, and refreshes the entry, every minute.
// Only a skip is decided on it: a collection that applies always connects and detects.
const detectCacheTTL = 2 * time.Minute

// connects counts Connect's calls in this process (the live test's count of connections opened).
var connects atomic.Int64

// detected is one instance's last detect and the configuration it was read under.
type detected struct {
	info       Info
	instanceID int    // the repository's instance the connecting run named
	dsn        string // the instance's dsn as configured (an env: or file: reference, or a literal string held only here)
	platform   string // the configuration's platform setting (a forced platform changes the Kind)
	at         time.Time
}

var detectCache sync.Map // instance name -> detected

// rememberDetect keeps a successful detect of the instance and the instance row it was recorded on; the pool tag and
// the linked server test tag (task 409) are left out (they are the configuration's, set at each use).
func rememberDetect(in config.Instance, info Info, instanceID int, at time.Time) {
	info.PoolTag = ""
	info.LinkedServerTest = false
	detectCache.Store(in.Name, detected{info: info, instanceID: instanceID, dsn: in.DSNRaw, platform: in.Platform, at: at})
}

// cachedDetect returns the instance's last detect when it may decide a skip at now: read under the same DSN and
// platform setting, not in the future (a clock set back) and younger than detectCacheTTL.
func cachedDetect(in config.Instance, now time.Time) (Info, int, bool) {
	v, ok := detectCache.Load(in.Name)
	if !ok {
		return Info{}, 0, false
	}
	d := v.(detected)
	if d.dsn != in.DSNRaw || d.platform != in.Platform || now.Before(d.at) || now.Sub(d.at) >= detectCacheTTL {
		return Info{}, 0, false
	}
	d.info.PoolTag = poolTag(in)
	// task 409: mssql_linkedserver_test applies by the tag (its Applies reads LinkedServerTest), so a cached skip reads
	// the tag the instance carries now, never the one of the run that was cached
	d.info.LinkedServerTest = linkedServerTest(in)
	return d.info, d.instanceID, true
}

// poolTag is the instance's tag pool:<name> (an Azure SQL Database's pool, which the pool's own view does not name).
func poolTag(in config.Instance) string {
	tag := ""
	for _, t := range in.TagPairs() {
		if t.Key == "pool" {
			tag = t.Value
		}
	}
	return tag
}

// linkedServerTest: the instance carries the tag pgvigil:linkedserver-test (LinkedServerTestTag, task 409)
func linkedServerTest(in config.Instance) bool {
	for _, t := range in.TagPairs() {
		if t.Key+":"+t.Value == LinkedServerTestTag {
			return true
		}
	}
	return false
}
