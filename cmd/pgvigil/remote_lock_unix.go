//go:build !windows

package main

import (
	"os"

	"golang.org/x/sys/unix"
)

// lockFile takes the file's exclusive lock without waiting (flock: held per open file, released on close).
func lockFile(f *os.File) error { return unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB) }

func unlockFile(f *os.File) { _ = unix.Flock(int(f.Fd()), unix.LOCK_UN) }
