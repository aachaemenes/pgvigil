//go:build windows

package main

import (
	"errors"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// the access mask bits that let an account read a file's content, and those that let it change the file, its list or
// its owner (an account that may rewrite the list may then read)
const (
	readMask  = 0x1 | windows.GENERIC_READ | windows.GENERIC_ALL
	writeMask = 0x2 | 0x4 | windows.WRITE_DAC | windows.WRITE_OWNER | windows.GENERIC_WRITE | windows.GENERIC_ALL
)

// judgeCtx is what one run of the part reads once: the allowed readers (SYSTEM, the Administrators, the installed
// service's account) and why the service's account could not be told (warn).
type judgeCtx struct {
	allowed map[string]bool
	warn    string
}

func newJudgeCtx(string) *judgeCtx {
	c := &judgeCtx{allowed: map[string]bool{"S-1-5-18": true, "S-1-5-32-544": true}}
	if acct, found := installedAccount(); found {
		if sid, _, err := config.LookupAccount(acct); err == nil {
			c.allowed[sid.String()] = true
		} else {
			c.warn = "the service's account " + acct + " does not resolve here (" + err.Error() + "): its own grants cannot be told from another account's, so none is offered for removal"
		}
	}
	return c
}

// judgeHost judges one path by its access list (judgeDACL).
func judgeHost(p secretPath, c *judgeCtx) (string, string, error) {
	sd, err := windows.GetNamedSecurityInfo(p.Path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return "", "", err
	}
	var dacl *windows.ACL
	if sd != nil {
		if dacl, _, err = sd.DACL(); err != nil && !errors.Is(err, windows.ERROR_OBJECT_NOT_FOUND) {
			return "", "", err
		}
	}
	level, words := judgeDACL(p, dacl, c.allowed)
	return level, words, nil
}

// judgeDACL judges a path's list: none at all (no descriptor, no list, a NULL list) lets every account read it - its
// fix is the installer's, which also grants the service's account; else judgeACL over its entries (aclReaders).
func judgeDACL(p secretPath, dacl *windows.ACL, allowed map[string]bool) (string, string) {
	if dacl == nil {
		return "FAIL", p.Path + " has no access list at all (every account may read it):" + fixLines([]string{"run 'pgvigil install' again: it re-applies the folder's protected list, the service's account in it"})
	}
	return judgeACL(p.Path, aclReaders(dacl, p.Dir), allowed, p.Page)
}

// aclReaders are a list's allow entries that let an account read: inherit-only entries apply to the children, so on a
// folder those files inherit (object-inherit) count as its rule for the files written there later; an account denied
// read by its own entry is not a reader; a name without a domain (a well-known SID) is the name alone.
func aclReaders(dacl *windows.ACL, dir bool) []aclReader {
	denied := map[string]bool{}
	var readers []aclReader
	for i := uint16(0); i < dacl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, uint32(i), &ace); err != nil {
			continue
		}
		flags := ace.Header.AceFlags
		if flags&windows.INHERIT_ONLY_ACE != 0 && (!dir || flags&windows.OBJECT_INHERIT_ACE == 0) {
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		mask := uint32(ace.Mask)
		switch ace.Header.AceType {
		case windows.ACCESS_DENIED_ACE_TYPE:
			if mask&readMask != 0 {
				denied[sid.String()] = true
			}
			continue
		case windows.ACCESS_ALLOWED_ACE_TYPE:
		default:
			continue
		}
		if mask&readMask == 0 {
			continue
		}
		r := aclReader{SID: sid.String(), Name: sid.String(), Write: mask&writeMask != 0, Inherited: flags&windows.INHERITED_ACE != 0}
		if acct, dom, _, err := sid.LookupAccount(""); err == nil {
			r.Resolved = true
			r.Name = acct
			if dom != "" {
				r.Name = dom + `\` + acct
			}
		}
		readers = append(readers, r)
	}
	out := readers[:0]
	for _, r := range readers {
		if !denied[r.SID] {
			out = append(out, r)
		}
	}
	return out
}
