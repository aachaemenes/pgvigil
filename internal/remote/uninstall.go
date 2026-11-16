package remote

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
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

// refuseLink holds dir to a real folder: a link (an outbox or a state folder pointing elsewhere) is refused, never
// followed, so a purge never reaches the link's target unnamed. A missing dir is os.ErrNotExist.
func refuseLink(dir, what string) error {
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("the %s %s is a link: give the folder it points to", what, dir)
	}
	if !fi.IsDir() {
		return fmt.Errorf("the %s %s is not a folder", what, dir)
	}
	return nil
}

var dayRE = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)

// dayFolders are the outbox's day folders of the layout, each level by its own rule (site and collector a name, the
// instance key a key, the day yyyy-mm-dd); anything else is not walked. A read error is returned, never skipped.
func dayFolders(outbox string) ([]string, error) {
	var days []string
	sites, err := os.ReadDir(outbox)
	if err != nil {
		return nil, err
	}
	for _, st := range sites {
		if !st.IsDir() || !format.ValidName(st.Name()) {
			continue
		}
		sd := filepath.Join(outbox, st.Name())
		colls, err := os.ReadDir(sd)
		if err != nil {
			return nil, err
		}
		for _, co := range colls {
			if !co.IsDir() || !format.ValidName(co.Name()) {
				continue
			}
			cd := filepath.Join(sd, co.Name())
			keys, err := os.ReadDir(cd)
			if err != nil {
				return nil, err
			}
			for _, k := range keys {
				if !k.IsDir() {
					continue
				}
				if _, err := format.InstanceName(k.Name()); err != nil {
					continue
				}
				kd := filepath.Join(cd, k.Name())
				ds, err := os.ReadDir(kd)
				if err != nil {
					return nil, err
				}
				for _, d := range ds {
					if d.IsDir() && dayRE.MatchString(d.Name()) {
						days = append(days, filepath.Join(kd, d.Name()))
					}
				}
			}
		}
	}
	return days, nil
}

// leafRef reads a day folder's entry name as a bundle of the layout (its whole path from the outbox must parse).
func leafRef(outbox, day, name string) (format.Ref, bool) {
	rel, err := filepath.Rel(outbox, filepath.Join(day, name))
	if err != nil {
		return format.Ref{}, false
	}
	ref, err := format.ParseDir(filepath.ToSlash(rel))
	return ref, err == nil
}

// OutboxHolds counts the outbox's finished bundles with no .pushed marker beside them (a pushed bundle reached its
// container; any other may not have left the site yet) and the newest one's window end. A missing outbox holds none;
// a link or a folder that cannot be read is an error, never a count of 0.
func OutboxHolds(outbox string) (n int, newest time.Time, err error) {
	if err := refuseLink(outbox, "outbox"); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, time.Time{}, nil
		}
		return 0, time.Time{}, err
	}
	days, err := dayFolders(outbox)
	if err != nil {
		return 0, time.Time{}, err
	}
	for _, d := range days {
		entries, err := os.ReadDir(d)
		if err != nil {
			return 0, time.Time{}, err
		}
		names := map[string]bool{}
		for _, e := range entries {
			names[e.Name()] = true
		}
		for _, e := range entries {
			if !e.IsDir() || strings.HasSuffix(e.Name(), format.PartExt) || names[e.Name()+pushedExt] {
				continue
			}
			ref, ok := leafRef(outbox, d, e.Name())
			if !ok {
				continue
			}
			if _, err := os.Stat(filepath.Join(d, e.Name(), format.ManifestFile)); err != nil {
				if errors.Is(err, os.ErrNotExist) {
					continue
				}
				return 0, time.Time{}, err
			}
			n++
			if ref.End.After(newest) {
				newest = ref.End
			}
		}
	}
	return n, newest, nil
}

// PurgeOutbox removes the layout's bundles, their .pushed markers and their .part folders, then each layout folder on
// the path of something removed once it is empty, then the outbox when empty; nothing outside the layout is touched
// (an empty folder of someone else's, a folder named *.part elsewhere): whatever is left is returned by path.
func PurgeOutbox(outbox string) (removed int, kept []string, err error) {
	if err := refuseLink(outbox, "outbox"); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return 0, nil, nil
		}
		return 0, nil, err
	}
	days, err := dayFolders(outbox)
	if err != nil {
		return 0, nil, err
	}
	touched := map[string]bool{}
	for _, d := range days {
		entries, err := os.ReadDir(d)
		if err != nil {
			return removed, nil, err
		}
		for _, e := range entries {
			name, p := e.Name(), filepath.Join(d, e.Name())
			switch {
			case e.IsDir() && strings.HasSuffix(name, format.PartExt):
				if _, ok := leafRef(outbox, d, strings.TrimSuffix(name, format.PartExt)); !ok {
					continue
				}
			case e.IsDir():
				if _, ok := leafRef(outbox, d, name); !ok {
					continue
				}
				removed++
			case e.Type().IsRegular() && strings.HasSuffix(name, pushedExt):
				if _, ok := leafRef(outbox, d, strings.TrimSuffix(name, pushedExt)); !ok {
					continue
				}
			default:
				continue
			}
			if err := os.RemoveAll(p); err != nil {
				return removed, nil, err
			}
			touched[d] = true
		}
	}
	var dirs []string
	seen := map[string]bool{}
	for d := range touched {
		for p := d; p != outbox && strings.HasPrefix(p, outbox+string(filepath.Separator)); p = filepath.Dir(p) {
			if !seen[p] {
				seen[p] = true
				dirs = append(dirs, p)
			}
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, d := range dirs {
		_ = os.Remove(d) // only an empty folder goes
	}
	if err := os.Remove(outbox); err == nil || errors.Is(err, os.ErrNotExist) {
		return removed, nil, nil
	}
	_ = filepath.WalkDir(outbox, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == outbox {
			return nil
		}
		if d.IsDir() {
			if ents, rerr := os.ReadDir(p); rerr == nil && len(ents) == 0 {
				kept = append(kept, p)
			}
			return nil
		}
		kept = append(kept, p)
		return nil
	})
	sort.Strings(kept)
	return removed, kept, nil
}

// PurgeState removes StateFiles from the state folder and then the folder when it is empty; anything else is kept, and
// its names returned. A link is refused.
func PurgeState(dir string) (kept []string, err error) {
	if err := refuseLink(dir, "state folder"); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
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
