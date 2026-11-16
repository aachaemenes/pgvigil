package remote

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

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
	if _, err := os.Stat(outbox); errors.Is(err, os.ErrNotExist) {
		return 0, time.Time{}, nil
	}
	bundles, err := finishedBundles(outbox)
	if err != nil {
		return 0, time.Time{}, err
	}
	for _, b := range bundles {
		if _, err := os.Stat(b.dir + pushedExt); err == nil {
			continue
		}
		n++
		if b.ref.End.After(newest) {
			newest = b.ref.End
		}
	}
	return n, newest, nil
}

// PurgeOutbox removes the outbox's finished bundles, their .pushed markers and every .part folder, then the layout's
// folders left empty and the outbox itself; whatever else is there is kept, and its paths returned.
func PurgeOutbox(outbox string) (removed int, kept []string, err error) {
	if _, err := os.Stat(outbox); errors.Is(err, os.ErrNotExist) {
		return 0, nil, nil
	}
	bundles, err := finishedBundles(outbox)
	if err != nil {
		return 0, nil, err
	}
	for _, b := range bundles {
		if err := os.RemoveAll(b.dir); err != nil {
			return removed, nil, err
		}
		if err := os.Remove(b.dir + pushedExt); err != nil && !errors.Is(err, os.ErrNotExist) {
			return removed, nil, err
		}
		removed++
	}
	if _, err := CleanParts(outbox); err != nil {
		return removed, nil, err
	}
	// a marker whose bundle is already gone (the cap removed it) is the collector's too
	markers, _ := filepath.Glob(filepath.Join(outbox, "*", "*", "*", "*", "*"+pushedExt))
	for _, m := range markers {
		if rel, err := filepath.Rel(outbox, strings.TrimSuffix(m, pushedExt)); err == nil {
			if _, err := format.ParseDir(filepath.ToSlash(rel)); err == nil {
				_ = os.Remove(m)
			}
		}
	}
	// the layout's folders (site / collector / instance key / day), deepest first, once empty; then the outbox
	var dirs []string
	_ = filepath.WalkDir(outbox, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() && p != outbox {
			dirs = append(dirs, p)
		}
		return nil
	})
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, d := range dirs {
		_ = os.Remove(d) // only an empty folder goes
	}
	if err := os.Remove(outbox); err == nil || errors.Is(err, os.ErrNotExist) {
		return removed, nil, nil
	}
	_ = filepath.WalkDir(outbox, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			kept = append(kept, p)
		}
		return nil
	})
	return removed, kept, nil
}

// PurgeState removes StateFiles from the state folder and then the folder when it is empty; anything else is kept, and
// its names returned.
func PurgeState(dir string) (kept []string, err error) {
	if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	for _, f := range StateFiles {
		if err := os.Remove(filepath.Join(dir, f)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	if err := os.Remove(dir); err == nil || errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		kept = append(kept, e.Name())
	}
	slices.Sort(kept)
	return kept, nil
}
