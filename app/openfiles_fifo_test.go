//go:build !windows

package main

import (
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestFIFORefusedBeforeItIsOpened: a named pipe with a plan's name is refused by its kind, never opened (an open of a
// FIFO no one writes would block).
func TestFIFORefusedBeforeItIsOpened(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.sqlplan")
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Skipf("mkfifo: %v", err)
	}
	done := make(chan OpenFile, 1)
	go func() { done <- readOpen(p, MaxOpenBytes) }()
	select {
	case f := <-done:
		if !strings.Contains(f.Why, "not a regular file") {
			t.Errorf("a FIFO: %q, want 'not a regular file'", f.Why)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("readOpen blocked on a FIFO")
	}
}
