//go:build linux

package main

import "golang.org/x/sys/unix"

// hasPosixACL says whether path carries a POSIX access list (a folder its default list for new files too): with one,
// the group bits show the list's mask, not who reads.
func hasPosixACL(path string, dir bool) bool {
	names := []string{"system.posix_acl_access"}
	if dir {
		names = append(names, "system.posix_acl_default")
	}
	for _, name := range names {
		if n, err := unix.Getxattr(path, name, nil); err == nil && n > 0 {
			return true
		}
	}
	return false
}
