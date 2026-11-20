//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// the access mask bits that let an account read a file's content
const readMask = 0x1 | windows.GENERIC_READ | windows.GENERIC_ALL

// judgeHost judges one path by its access list (judgeACL): SYSTEM, the Administrators and the installed service's
// account may read it, no one else. Inherit-only entries apply to children, not to the path.
func judgeHost(path string, _ bool) (string, string, error) {
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return "", "", err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return "", "", err
	}
	if dacl == nil {
		return "FAIL", path + " has no access list at all (every account may read it): run 'pgvigil install' again, or icacls \"" + path + "\" /inheritance:r /grant:r *S-1-5-18:F *S-1-5-32-544:F", nil
	}
	var readers []aclReader
	for i := uint16(0); i < dacl.AceCount; i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, uint32(i), &ace); err != nil {
			return "", "", err
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 || uint32(ace.Mask)&readMask == 0 {
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		name := sid.String()
		if acct, dom, _, err := sid.LookupAccount(""); err == nil {
			name = dom + `\` + acct
		}
		readers = append(readers, aclReader{SID: sid.String(), Name: name})
	}
	level, words := judgeACL(path, readers, allowedReaders())
	return level, words, nil
}

// allowedReaders: SYSTEM, the Administrators, and the account the installed service runs as.
func allowedReaders() map[string]bool {
	allowed := map[string]bool{"S-1-5-18": true, "S-1-5-32-544": true}
	if acct, found := installedAccount(); found {
		if sid, _, err := config.LookupAccount(acct); err == nil {
			allowed[sid.String()] = true
		}
	}
	return allowed
}
