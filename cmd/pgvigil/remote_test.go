package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// One remote collector per state folder: a second lock on the same folder is refused in words while the first holds
// it, and taken once it is released.
func TestRemoteLock(t *testing.T) {
	dir := t.TempDir()
	l1, err := lockStateDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockStateDir(dir); err == nil || !strings.Contains(err.Error(), "another remote collector") {
		t.Errorf("a second lock: %v", err)
	}
	l1.release()
	l2, err := lockStateDir(dir)
	if err != nil {
		t.Errorf("after the release: %v", err)
	} else {
		l2.release()
	}
}

// Retention without a push (R12): a finished bundle goes keep_days after it was written (its window's end); past
// remote.max_mb the oldest bundles go first until the outbox fits; a .part folder and a pushed marker's bundle are the
// push's business, never this sweep's.
func TestRemoteRetention(t *testing.T) {
	out := t.TempDir()
	mk := func(rel string, size int) {
		t.Helper()
		d := filepath.Join(out, filepath.FromSlash(rel))
		if err := os.MkdirAll(d, 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "manifest.json"), []byte("{}"), 0o640); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "v.ndjson.gz"), make([]byte, size), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	old := "site1/coll1/pg1/2026-11-01/0000000001-20261101T000500Z"
	mid := "site1/coll1/pg1/2026-11-15/0000000002-20261115T000500Z"
	newer := "site1/coll1/pg1/2026-11-16/0000000003-20261116T000500Z"
	mk(old, 1<<20)
	mk(mid, 3<<20)
	mk(newer, 3<<20)
	if err := os.MkdirAll(filepath.Join(out, "site1/coll1/pg1/2026-11-16/0000000004-20261116T001000Z.part"), 0o750); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 16, 1, 0, 0, 0, time.UTC)
	gone := sweepOutbox(out, 7, 64, now)
	if gone != 1 {
		t.Errorf("keep_days 7: %d went, want the 2026-11-01 one", gone)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(old))); !os.IsNotExist(err) {
		t.Errorf("the old bundle: %v", err)
	}
	gone = sweepOutbox(out, 7, 4, now) // 6 MB left over a 4 MB cap: the oldest goes
	if gone != 1 {
		t.Errorf("max_mb 4: %d went, want one", gone)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(mid))); !os.IsNotExist(err) {
		t.Errorf("the oldest over the cap: %v", err)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(newer))); err != nil {
		t.Errorf("the newest: %v", err)
	}
	if _, err := os.Stat(filepath.Join(out, "site1/coll1/pg1/2026-11-16/0000000004-20261116T001000Z.part")); err != nil {
		t.Errorf("a .part folder went: %v", err)
	}
}
