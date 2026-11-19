//go:build unix

package pgkrb

import (
	"os"
	"syscall"
)

// fileNumber is the file's inode: a new file renamed over the cache has another one
func fileNumber(st os.FileInfo) uint64 {
	if s, ok := st.Sys().(*syscall.Stat_t); ok {
		return uint64(s.Ino)
	}
	return 0
}
