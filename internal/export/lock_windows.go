//go:build windows

package export

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

// lockFile takes the run's lock without waiting. held true = another run has it. The lock goes with the process.
func lockFile(path string) (release func(), held bool, err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, false, err
	}
	ol := new(windows.Overlapped)
	h := windows.Handle(f.Fd())
	if err := windows.LockFileEx(h, windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, ol); err != nil {
		f.Close()
		if errors.Is(err, windows.ERROR_LOCK_VIOLATION) || errors.Is(err, windows.ERROR_IO_PENDING) {
			return nil, true, nil
		}
		return nil, false, err
	}
	return func() { windows.UnlockFileEx(h, 0, 1, 0, ol); f.Close() }, false, nil
}
