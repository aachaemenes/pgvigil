package remote

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// putBundle lays a finished bundle (its folder with a manifest) or, with part, an open one in the outbox.
func putBundle(t *testing.T, outbox string, seq uint64, end time.Time, part bool) string {
	t.Helper()
	dir := filepath.Join(outbox, filepath.FromSlash(format.Ref{Site: "site1", Collector: "c1", InstanceKey: format.InstanceKey("SQL01"), Seq: seq, End: end}.Dir()))
	if part {
		dir += format.PartExt
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, format.ManifestFile), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// uninstall -remote -purge's guard counts the bundles the site may not have carried yet: finished, no .pushed marker.
// A pushed bundle, an open (.part) one and a missing outbox count none; the newest is the latest window end.
func TestOutboxHolds(t *testing.T) {
	outbox := filepath.Join(t.TempDir(), "outbox")
	if n, _, err := OutboxHolds(outbox); n != 0 || err != nil {
		t.Errorf("a missing outbox: %d %v", n, err)
	}
	t0 := time.Date(2026, 11, 16, 10, 0, 0, 0, time.UTC)
	putBundle(t, outbox, 1, t0, false)
	newest := putBundle(t, outbox, 2, t0.Add(5*time.Minute), false)
	pushed := putBundle(t, outbox, 3, t0.Add(10*time.Minute), false)
	if err := os.WriteFile(pushed+pushedExt, []byte(t0.Format(time.RFC3339)), 0o600); err != nil {
		t.Fatal(err)
	}
	putBundle(t, outbox, 4, t0.Add(15*time.Minute), true)
	n, at, err := OutboxHolds(outbox)
	if err != nil || n != 2 || !at.Equal(t0.Add(5*time.Minute)) {
		t.Errorf("two not pushed (newest %s), one pushed, one open: got %d, newest %s, %v", filepath.Base(newest), n, at, err)
	}
}

// -purge leaves no bundle, marker or open folder, and no empty layout folder; a file of someone else's in the outbox
// keeps it and is named.
func TestPurgeOutbox(t *testing.T) {
	root := t.TempDir()
	outbox := filepath.Join(root, "outbox")
	t0 := time.Date(2026, 11, 16, 10, 0, 0, 0, time.UTC)
	putBundle(t, outbox, 1, t0, false)
	b2 := putBundle(t, outbox, 2, t0.Add(5*time.Minute), false)
	if err := os.WriteFile(b2+pushedExt, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	putBundle(t, outbox, 3, t0.Add(10*time.Minute), true)
	removed, kept, err := PurgeOutbox(outbox)
	if err != nil || removed != 2 || len(kept) != 0 {
		t.Errorf("two bundles and an open one: removed %d, kept %v, %v", removed, kept, err)
	}
	if _, err := os.Stat(outbox); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the outbox is still there (%v)", err)
	}

	other := filepath.Join(root, "shared")
	putBundle(t, other, 1, t0, false)
	if err := os.WriteFile(filepath.Join(other, "notes.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	removed, kept, err = PurgeOutbox(other)
	if err != nil || removed != 1 || !slices.Equal(kept, []string{filepath.Join(other, "notes.txt")}) {
		t.Errorf("a shared folder: removed %d, kept %v, %v", removed, kept, err)
	}
	if _, err := os.Stat(filepath.Join(other, "notes.txt")); err != nil {
		t.Errorf("someone else's file went: %v", err)
	}
	if _, err := os.Stat(filepath.Join(other, "site1")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the empty layout folder is still there (%v)", err)
	}
}

// -purge removes the state folder's own files and the folder; a file of someone else's keeps it and is named.
func TestPurgeState(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, f := range StateFiles {
		if err := os.WriteFile(filepath.Join(dir, f), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if kept, err := PurgeState(dir); err != nil || len(kept) != 0 {
		t.Errorf("the collector's own files: kept %v, %v", kept, err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the state folder is still there (%v)", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"state.json", "keep.me"} {
		if err := os.WriteFile(filepath.Join(dir, f), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if kept, err := PurgeState(dir); err != nil || !slices.Equal(kept, []string{"keep.me"}) {
		t.Errorf("a state folder with someone else's file: kept %v, %v", kept, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "state.json")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("state.json is still there (%v)", err)
	}
}
