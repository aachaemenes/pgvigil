//go:build !windows

package main

import (
	"fmt"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
)

// judgeCtx is what one run of the part reads once: the group the service's account belongs to (the installed unit's
// User=, else the configuration folder's own group - the installer's), the one a group bit may serve.
type judgeCtx struct {
	gid       uint32
	groupName string
	known     bool
	warn      string
}

func newJudgeCtx(dir string) *judgeCtx {
	c := &judgeCtx{}
	if acct := unitAccount(); acct != "" {
		if u, err := user.Lookup(acct); err == nil {
			if g, err := strconv.ParseUint(u.Gid, 10, 32); err == nil {
				c.gid, c.known = uint32(g), true
			}
		}
	}
	if !c.known {
		if st, err := os.Stat(dir); err == nil {
			if sys, ok := st.Sys().(*syscall.Stat_t); ok {
				c.gid, c.known = sys.Gid, true
			}
		}
	}
	c.groupName = groupName(c.gid)
	return c
}

func groupName(gid uint32) string {
	if g, err := user.LookupGroupId(strconv.FormatUint(uint64(gid), 10)); err == nil {
		return g.Name
	}
	return strconv.FormatUint(uint64(gid), 10)
}

// judgeHost judges one path by its mode (judgeMode) - a link by its target's, both named, and the fix on the target
// (a link's own mode means nothing) - then by what the mode alone does not show: the repository owner's credential
// readable by a group, a group bit for a group that is not the service's, a POSIX access list (its getfacl line).
func judgeHost(p secretPath, c *judgeCtx) (string, string, error) {
	st, err := os.Lstat(p.Path)
	if err != nil {
		return "", "", err
	}
	path, lead := p.Path, ""
	if st.Mode()&fs.ModeSymlink != 0 {
		target, err := filepath.EvalSymlinks(p.Path)
		if err != nil {
			return "", "", fmt.Errorf("a link whose target is not read: %w", err)
		}
		if st, err = os.Stat(target); err != nil {
			return "", "", err
		}
		path, lead = target, p.Path+" is a link to "+target+": "
	}
	isDir := st.IsDir()
	level, words := judgeMode(path, st.Mode(), isDir)
	perm := st.Mode().Perm()
	if level != "FAIL" && p.OwnerOnly && perm&0o070 != 0 {
		level, words = "FAIL", fmt.Sprintf("%s is open to its group (mode %04o): it holds the repository owner's credential, root's alone: chmod 0600 %s", path, perm, path)
	}
	if level != "FAIL" && perm&0o040 != 0 && c.known {
		if sys, ok := st.Sys().(*syscall.Stat_t); ok && sys.Gid != c.gid {
			level, words = "FAIL", fmt.Sprintf("%s is readable by its group %s, not the service's %s: chgrp %s %s", path, groupName(sys.Gid), c.groupName, c.groupName, path)
		}
	}
	if level == "OK" && hasPosixACL(path, isDir) {
		level, words = "WARN", fmt.Sprintf("%s carries a POSIX access list its mode does not show (an account may read it through it): getfacl %s", path, path)
	}
	if level != "OK" {
		words = lead + words
	}
	return level, words, nil
}
