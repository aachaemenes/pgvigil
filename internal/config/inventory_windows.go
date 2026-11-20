//go:build windows

package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// prepareDir (Windows): the folder's access list is protected (nothing inherited from ProgramData, where the local
// Users may read) and grants full control to SYSTEM, the Administrators and the account serve runs as only; the
// files in it inherit that list. DPAPI at machine scope lets any process of the machine unseal a blob it can read,
// so the access list is what keeps the other local accounts out.
func prepareDir(dir string) error {
	tu, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + tu.User.Sid.String() + ")")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}

// writeSecret (Windows): the value sealed with DPAPI at machine scope (any process of this machine can open it,
// none elsewhere), written beside its final name and renamed over it.
func writeSecret(dir, name, value string) (string, error) {
	p := filepath.Join(dir, name+".dpapi")
	if err := SealDPAPIAt(p, value); err != nil {
		return "", err
	}
	return "dpapi:" + p, nil
}

// SealDPAPIAt writes value sealed with DPAPI at machine scope to exactly path, beside it first and renamed over it
// ('pgvigil config import' puts a moved secret back where the references name it, RELNOTES L155).
func SealDPAPIAt(path, value string) error {
	if value == "" {
		return errors.New("nothing to seal")
	}
	in := []byte(value)
	var out windows.DataBlob
	if err := windows.CryptProtectData(&windows.DataBlob{Size: uint32(len(in)), Data: &in[0]}, nil, nil, 0, nil,
		windows.CRYPTPROTECT_LOCAL_MACHINE|windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return err
	}
	defer func() { _, _ = windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data))) }()
	blob := unsafe.Slice(out.Data, out.Size)
	tmp := path + ".new"
	if err := os.WriteFile(tmp, blob, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// ResolveDPAPI opens a dpapi: reference's blob.
func ResolveDPAPI(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if len(b) == 0 {
		return "", os.ErrInvalid
	}
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(&windows.DataBlob{Size: uint32(len(b)), Data: &b[0]}, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return "", err
	}
	defer func() { _, _ = windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data))) }()
	return strings.TrimRight(string(unsafe.Slice(out.Data, out.Size)), "\r\n"), nil
}

// ownedLikeParent (Windows): nothing to do - a folder or file made under the configuration's folder inherits its
// access list (the installer's: SYSTEM, the Administrators and the service's own account).
func ownedLikeParent(string) error { return nil }

// OwnLikeFolder gives path its folder's owner and the installer's mode (ownedLikeParent); on Windows a new file
// inherits its folder's access list, so nothing is done.
func OwnLikeFolder(path string) error { return ownedLikeParent(path) }

func knownAccount(account string) error {
	if _, _, err := LookupAccount(account); err != nil {
		return fmt.Errorf("the account %s: %w", account, err)
	}
	return nil
}

// prepareDirAs (Windows): prepareDir's protected list with the named account's SID in place of this process's.
func prepareDirAs(dir, account string) error {
	sid, _, err := LookupAccount(account)
	if err != nil {
		return fmt.Errorf("the account %s: %w", account, err)
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;" + sid.String() + ")")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}

// ownFileAs (Windows): nothing - the file inherits the folder's list.
func ownFileAs(string, string) error { return nil }

// sealAccess (Windows; rn-l9 B1): a sealed secret's folder gets a protected list - SYSTEM and the Administrators full,
// the installed service's account read (account; "" = none installed: the first two alone) - never the list of
// wherever the folder sits (an elevated prompt starts in System32, whose list lets every local account read); a file
// under it takes that list by inheritance.
func sealAccess(path, _ string, account string) error {
	st, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return nil
	}
	sddl := "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
	if account != "" {
		sid, _, err := LookupAccount(account)
		if err != nil {
			return fmt.Errorf("the service's account %s: %w", account, err)
		}
		sddl += "(A;OICI;FR;;;" + sid.String() + ")"
	}
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}
