//go:build !windows

package main

import (
	"context"
	"io"
	"log/slog"
	"testing"
)

// task B24n, proof row P7: off Windows the store's flags and the grant are refused with their sentence.
func TestStoreWindowsOnly(t *testing.T) {
	if _, err := storeServerTLS(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)), `LocalMachine\My`, "ab", ""); err != errStoreWindowsOnly {
		t.Errorf("storeServerTLS: %v", err)
	}
	if err := grantKeyAccess(`LocalMachine\My`, "ab", "u", io.Discard, io.Discard); err != errStoreWindowsOnly {
		t.Errorf("grantKeyAccess: %v", err)
	}
}
