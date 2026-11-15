package mssql

import (
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The last detect of each SQL Server instance, kept in the process, so RunOnce decides a collection's Applies BEFORE
// it connects: a run whose collection does not apply to the instance opens no connection (an Azure SQL Database
// skips 7 of the 12 minute collections; at 1,819 databases each skip was a connection and a detect a minute).
// Applies reads only the Info (every Applies of this package), so a skip decided on a cached Info is the skip the
// fresh detect would give while the server is unchanged. Every run that connects and detects refreshes the entry; an
// entry older than detectCacheTTL is not used (the run connects and detects again), so a right granted, a tier
// changed or an upgrade is seen at the next connecting run of the instance (each minute where one minute collection
// applies) and after detectCacheTTL at the latest. Only a skip is decided on it: a collection that applies always
// connects and detects.
const detectCacheTTL = 10 * time.Minute

// detected is one instance's last detect and the configuration it was read under.
type detected struct {
	info     Info
	dsn      string // the instance's DSN as configured (its env: or file: reference, never the resolved secret)
	platform string // the configuration's platform setting (a forced platform changes the Kind)
	at       time.Time
}

var detectCache sync.Map // instance name -> detected

// rememberDetect keeps a successful detect of the instance; the pool tag is left out (it is the configuration's, set at each use).
func rememberDetect(in config.Instance, info Info, at time.Time) {
	info.PoolTag = ""
	detectCache.Store(in.Name, detected{info: info, dsn: in.DSNRaw, platform: in.Platform, at: at})
}

// cachedDetect returns the instance's last detect when it may decide a skip at now: read under the same DSN and
// platform setting, not in the future (a clock set back) and younger than detectCacheTTL.
func cachedDetect(in config.Instance, now time.Time) (Info, bool) {
	v, ok := detectCache.Load(in.Name)
	if !ok {
		return Info{}, false
	}
	d := v.(detected)
	if d.dsn != in.DSNRaw || d.platform != in.Platform || now.Before(d.at) || now.Sub(d.at) >= detectCacheTTL {
		return Info{}, false
	}
	d.info.PoolTag = poolTag(in)
	return d.info, true
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
