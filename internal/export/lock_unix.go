//go:build !windows

package export

import (
	"errors"
	"os"

	"golang.org/x/sys/unix"
)

// lockFile takes the run's lock without waiting. held true = another run has it. The lock goes with the process.
func lockFile(path string) (release func(), held bool, err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, false, err
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, true, nil
		}
		return nil, false, err
	}
	return func() { unix.Flock(int(f.Fd()), unix.LOCK_UN); f.Close() }, false, nil
}
