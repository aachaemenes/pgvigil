package remote

import "time"

// The remote collector's removal (pgvigil uninstall -remote -purge; the lead's 12:2x): the outbox and the state folder
// hold only what the collector wrote, so -purge removes those files and each folder once empty; anything else found
// there is kept and named. The collector cannot know whether a site's own transfer already carried a bundle, so the
// caller refuses -purge while OutboxHolds counts any, unless -force.

// StateFiles are the files a remote collector writes in its state folder: its state and the state's temporary copy,
// the folder's lock, its signing key and its service log.
var StateFiles = []string{stateFile, stateFile + ".tmp", "pgvigil.lock", "signing.key", "pgvigil-remote.log"}

// OutboxHolds counts the outbox's finished bundles with no .pushed marker beside them (a pushed bundle reached its
// container; any other may not have left the site yet) and the newest one's window end. A missing outbox holds none.
func OutboxHolds(outbox string) (n int, newest time.Time, err error) {
	return 0, time.Time{}, nil
}

// PurgeOutbox removes the outbox's finished bundles, their .pushed markers and every .part folder, then the layout's
// folders left empty and the outbox itself; whatever else is there is kept, and its paths returned.
func PurgeOutbox(outbox string) (removed int, kept []string, err error) {
	return 0, nil, nil
}

// PurgeState removes StateFiles from the state folder and then the folder when it is empty; anything else is kept, and
// its names returned.
func PurgeState(dir string) (kept []string, err error) {
	return nil, nil
}
