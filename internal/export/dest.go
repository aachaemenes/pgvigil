package export

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Destination is where a repository's files go. A key is relative to the repository's own folder there
// (<prefix>/<name>/): "<table>/<file>.parquet", "_manifests/<manifest>.json". The data goes up first and the
// manifest last: a manifest means every file it lists is whole, and a file no manifest lists is an unfinished run.
type Destination interface {
	// Upload stores a finished local file under key, replacing what was there.
	Upload(ctx context.Context, key, local string) error
	// Put stores a small object (a manifest, a marker). onlyNew: refuse with errExists when the key is already there
	// (a manifest is written once; a second writer is another run on the same destination).
	Put(ctx context.Context, key string, body []byte, onlyNew bool) error
	// Get reads a small object; errAbsent when there is none.
	Get(ctx context.Context, key string) ([]byte, error)
	// Delete removes an object; one that is not there is no error.
	Delete(ctx context.Context, key string) error
	// List returns the keys that start with prefix, sorted.
	List(ctx context.Context, prefix string) ([]string, error)
	// String names the place for a line of output, without a secret.
	String() string
}

var (
	errAbsent = errors.New("no such object")
	errExists = errors.New("the object is already there")
)

// folder is a destination on a file system. Every object is written beside its place as <name>.tmp and renamed.
type folder struct{ root string }

// NewFolder is the folder destination: root is the repository's own folder (<path>/<name>).
func NewFolder(root string) Destination { return &folder{root: root} }

func (d *folder) String() string { return "folder " + d.root }

func (d *folder) path(key string) string { return filepath.Join(d.root, filepath.FromSlash(key)) }

func (d *folder) Upload(_ context.Context, key, local string) error {
	in, err := os.Open(local)
	if err != nil {
		return err
	}
	defer in.Close()
	return d.write(key, in)
}

func (d *folder) Put(_ context.Context, key string, body []byte, onlyNew bool) error {
	if !onlyNew {
		return d.write(key, strings.NewReader(string(body)))
	}
	// written beside its place under a name of its own, then linked into place: a link fails when the name exists
	side := key + ".new"
	if err := d.write(side, strings.NewReader(string(body))); err != nil {
		return err
	}
	defer os.Remove(d.path(side))
	if err := os.Link(d.path(side), d.path(key)); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return errExists
		}
		return err
	}
	return nil
}

func (d *folder) write(key string, r io.Reader) error {
	p := d.path(key)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp := p + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func (d *folder) Get(_ context.Context, key string) ([]byte, error) {
	b, err := os.ReadFile(d.path(key))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, errAbsent
	}
	return b, err
}

func (d *folder) Delete(_ context.Context, key string) error {
	err := os.Remove(d.path(key))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}

func (d *folder) List(_ context.Context, prefix string) ([]string, error) {
	var keys []string
	// the folder to walk: the prefix itself when it names one ("" is the root, "_manifests/"), else the folder its
	// last part sits in ("_manifests/prod__2026" walks _manifests); never above the root
	dir := d.root
	if i := strings.LastIndex(prefix, "/"); i >= 0 {
		dir = d.path(prefix[:i])
	}
	err := filepath.WalkDir(dir, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return fs.SkipAll
			}
			return err
		}
		if e.IsDir() || strings.HasSuffix(p, ".tmp") || strings.HasSuffix(p, ".new") {
			return nil
		}
		rel, err := filepath.Rel(d.root, p)
		if err != nil {
			return err
		}
		if k := filepath.ToSlash(rel); strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
		return nil
	})
	sort.Strings(keys)
	return keys, err
}

// CheckDestination tries on the destination everything a run does there: a manifest written where none is, a
// second one refused, the list, the read back, the removal. A place that takes a plain write and fails one of
// these (a folder on a file system without hard links, a store that ignores If-None-Match, a bucket that may not
// be listed) would pass a lesser check and fail every run.
func CheckDestination(ctx context.Context, d Destination) error {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	key := "_manifests/_check_" + hex.EncodeToString(b)
	body := []byte("pgvigil export -check\n")
	fail := func(what string, err error) error {
		_ = d.Delete(ctx, key)
		return fmt.Errorf("the destination (%s) %s: %w", d, what, err)
	}
	if err := d.Put(ctx, key, body, true); err != nil {
		return fail("cannot be written", err)
	}
	switch err := d.Put(ctx, key, []byte("a second writer\n"), true); {
	case err == nil:
		return fail("lets a second manifest replace the first", errors.New("a write that must be refused where the object exists was taken"))
	case !errors.Is(err, errExists):
		return fail("cannot refuse a second manifest", err)
	}
	keys, err := d.List(ctx, "_manifests/")
	if err != nil {
		return fail("cannot be listed", err)
	}
	found := false
	for _, k := range keys {
		found = found || k == key
	}
	if !found {
		return fail("does not list what was written", errors.New("the check object is not in the list"))
	}
	if got, err := d.Get(ctx, key); err != nil || string(got) != string(body) {
		if err == nil {
			err = errors.New("another body came back")
		}
		return fail("does not give back what was written", err)
	}
	if err := d.Delete(ctx, key); err != nil {
		return fmt.Errorf("the destination (%s) took the check object and will not give it up: %w", d, err)
	}
	return nil
}
