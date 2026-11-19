//go:build !unix

package pgkrb

import "os"

// fileNumber is 0 where a FileInfo carries no file number (Windows): the version is the time and the size there
func fileNumber(os.FileInfo) uint64 { return 0 }
