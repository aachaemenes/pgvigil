package web

// The instances a remote collector reads (docs/remote-collector.md, migration 0329): a site owns each, its rows arrive
// in bundles, and the hub never connects to it. Every live door - an action, EXPLAIN, the planner check, the index
// advisor, a job action, Community tools, a custom report run on the instance, a histogram, a fragmentation read, a
// plan read by its handle - refuses it in one sentence naming its collector and site, and every page of it says how
// fresh its data is ('as of' the newest bundle's window end).

import "time"

// remoteDoor is one remote instance as the hub knows it from its newest loaded bundle.
type remoteDoor struct {
	Site, Collector string
	// AsOf: the newest loaded bundle's window end
	AsOf time.Time
	// Every: that bundle's window (the collector's remote.interval)
	Every time.Duration
	// ExpectedEvery: how often the site's bundles arrive (remote_sites: expected_every)
	ExpectedEvery time.Duration
}

// from is the door's words for where the instance is read: 'remote collector <c> of site <s>'.
func (r remoteDoor) from() string { return "remote collector " + r.Collector + " of site " + r.Site }

// remoteWhy is the words every live door says for a remote instance (actions.RemoteOff), or "" for any other.
func (ds *doorSet) remoteWhy(name string) string {
	return "" // OUTBOX V task 1: the red rows' stub
}
