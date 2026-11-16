package remote

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/export"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// fakeDest records each upload's key in order and fails the keys failOn names (each once, or always).
type fakeDest struct {
	mu      sync.Mutex
	keys    []string
	failOn  map[string]int // key -> failures left (-1: always)
	uploads map[string][]byte
}

func (f *fakeDest) Upload(_ context.Context, key, local string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if n, ok := f.failOn[key]; ok && n != 0 {
		if n > 0 {
			f.failOn[key] = n - 1
		}
		return errors.New("upload refused (fake)")
	}
	b, err := os.ReadFile(local)
	if err != nil {
		return err
	}
	if f.uploads == nil {
		f.uploads = map[string][]byte{}
	}
	f.keys = append(f.keys, key)
	f.uploads[key] = b
	return nil
}
func (f *fakeDest) Put(context.Context, string, []byte, bool) error {
	return errors.New("the push never Puts")
}
func (f *fakeDest) Get(context.Context, string) ([]byte, error) {
	return nil, errors.New("the push never reads")
}
func (f *fakeDest) Delete(context.Context, string) error { return errors.New("the push never deletes") }
func (f *fakeDest) List(context.Context, string) ([]string, error) {
	return nil, errors.New("the push never lists")
}
func (f *fakeDest) String() string { return "fake" }

var _ export.Destination = (*fakeDest)(nil)

// closedBundles writes n bundles of one instance (seq 1..n) into outbox, each with a view file.
func closedBundles(t *testing.T, outbox string, n int) []format.Ref {
	t.Helper()
	var refs []format.Ref
	for i := 1; i <= n; i++ {
		o := opts(outbox)
		o.Seq = uint64(i)
		o.From, o.To = t0.Add(time.Duration(i-1)*5*time.Minute), t0.Add(time.Duration(i)*5*time.Minute)
		b, err := OpenBundle(o)
		if err != nil {
			t.Fatal(err)
		}
		if err := b.AddBatch("mssql_jobs", o.From.Add(time.Minute), []map[string]any{{"kind": "cursor", "last_history_id": int64(i)}}); err != nil {
			t.Fatal(err)
		}
		ref, err := b.Close(o.To, nil, nil, format.Heartbeat{Host: "h", Started: t0, At: o.To})
		if err != nil {
			t.Fatal(err)
		}
		refs = append(refs, ref)
	}
	return refs
}

// Each finished bundle is uploaded at its own layout under the destination's root, every file before manifest.json
// (a poller that finds the manifest finds the bundle whole), bundles in seq order; a pushed bundle has its marker and is
// not uploaded again.
func TestPushOrderManifestLast(t *testing.T) {
	ctx := context.Background()
	out := t.TempDir()
	refs := closedBundles(t, out, 2)
	f := &fakeDest{}
	p := newPusher(f, out, 7)
	n, err := p.Round(ctx, t1)
	if err != nil || n != 2 {
		t.Fatalf("round: %d %v", n, err)
	}
	for i, ref := range refs {
		var mine []string
		for _, k := range f.keys {
			if strings.HasPrefix(k, ref.Dir()+"/") {
				mine = append(mine, strings.TrimPrefix(k, ref.Dir()+"/"))
			}
		}
		if len(mine) != 3 || mine[len(mine)-1] != format.ManifestFile {
			t.Errorf("bundle %d's uploads: %v (the manifest last)", i+1, mine)
		}
		if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(ref.Dir())) + pushedExt); err != nil {
			t.Errorf("bundle %d's marker: %v", i+1, err)
		}
	}
	if !strings.HasPrefix(f.keys[0], refs[0].Dir()+"/") || !strings.HasPrefix(f.keys[len(f.keys)-1], refs[1].Dir()+"/") {
		t.Errorf("seq order: %v", f.keys)
	}
	before := len(f.keys)
	if n, err := p.Round(ctx, t1); err != nil || n != 0 || len(f.keys) != before {
		t.Errorf("a second round pushed again: %d %v (%d uploads)", n, err, len(f.keys)-before)
	}
}

// Pushed into a real destination (a folder here, the same interface as Azure Blob), the bundle verifies whole at its
// layout under the root: the hub's drop reader finds what the outbox held.
func TestPushIntoAFolderVerifies(t *testing.T) {
	ctx := context.Background()
	out, drop := t.TempDir(), t.TempDir()
	refs := closedBundles(t, out, 1)
	if n, err := newPusher(export.NewFolder(drop), out, 7).Round(ctx, t1); err != nil || n != 1 {
		t.Fatalf("round: %d %v", n, err)
	}
	dir := filepath.Join(drop, filepath.FromSlash(refs[0].Dir()))
	m, err := format.DecodeManifest(read(t, filepath.Join(dir, format.ManifestFile)))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Matches(refs[0]); err != nil {
		t.Fatal(err)
	}
	if err := format.Verify(os.DirFS(dir), m, 1<<20); err != nil {
		t.Errorf("the pushed bundle: %v", err)
	}
}

// A failure stops the round: the failed bundle has no marker, the later ones are not tried; the next round pushes from
// the failed one on. A failure that clears within the round's retries is no failure.
func TestPushStopsAtFailure(t *testing.T) {
	ctx := context.Background()
	out := t.TempDir()
	refs := closedBundles(t, out, 2)
	sums := refs[0].Dir() + "/" + format.SumsFile
	f := &fakeDest{failOn: map[string]int{sums: -1}}
	p := newPusher(f, out, 7)
	if n, err := p.Round(ctx, t1); err == nil || n != 0 || !strings.Contains(err.Error(), refs[0].Dir()) {
		t.Fatalf("a failing upload: %d %v", n, err)
	}
	for _, k := range f.keys {
		if strings.HasPrefix(k, refs[1].Dir()+"/") || strings.HasSuffix(k, format.ManifestFile) {
			t.Errorf("uploaded past the failure: %s", k)
		}
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(refs[0].Dir())) + pushedExt); err == nil {
		t.Errorf("a marker for a bundle that failed")
	}
	f.failOn[sums] = 2 // two more failures, then it goes through within the round's three tries
	if n, err := p.Round(ctx, t1); err != nil || n != 2 {
		t.Errorf("the next round: %d %v", n, err)
	}
}

// keep_days counts from the push (the marker's time): a pushed bundle older than that goes with its marker; a bundle
// never pushed stays whatever its age; a .part folder and a stray file are neither pushed nor removed.
func TestPushPrune(t *testing.T) {
	ctx := context.Background()
	out := t.TempDir()
	refs := closedBundles(t, out, 2)
	if err := os.MkdirAll(filepath.Join(out, "site1", "coll1", "HOST%5CINST", "2026-11-16", "0000000009-20261116T190000Z"+format.PartExt), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, "site1", "note.txt"), []byte("x"), 0o640); err != nil {
		t.Fatal(err)
	}
	f := &fakeDest{failOn: map[string]int{refs[1].Dir() + "/" + format.ManifestFile: -1}}
	p := newPusher(f, out, 7)
	if n, err := p.Round(ctx, t1); err == nil || n != 1 {
		t.Fatalf("the first round: %d %v", n, err)
	}
	for _, k := range f.keys {
		if strings.Contains(k, format.PartExt) || strings.Contains(k, "note.txt") {
			t.Errorf("uploaded %s", k)
		}
	}
	if n := p.Prune(t1.Add(6 * 24 * time.Hour)); n != 0 {
		t.Errorf("pruned %d within keep_days", n)
	}
	if n := p.Prune(t1.Add(8 * 24 * time.Hour)); n != 1 {
		t.Errorf("pruned %d after keep_days, want the pushed one", n)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(refs[0].Dir()))); !os.IsNotExist(err) {
		t.Errorf("the pushed bundle is still there: %v", err)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(refs[0].Dir())) + pushedExt); !os.IsNotExist(err) {
		t.Errorf("its marker is still there: %v", err)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(refs[1].Dir()))); err != nil {
		t.Errorf("the bundle never pushed went: %v", err)
	}
}
