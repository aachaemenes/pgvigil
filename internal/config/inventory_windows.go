//go:build windows

package config

import (
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
// none elsewhere: the lead's decision), written beside its final name and renamed over it.
func writeSecret(dir, name, value string) (string, error) {
	in := []byte(value)
	var out windows.DataBlob
	if err := windows.CryptProtectData(&windows.DataBlob{Size: uint32(len(in)), Data: &in[0]}, nil, nil, 0, nil,
		windows.CRYPTPROTECT_LOCAL_MACHINE|windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return "", err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	blob := unsafe.Slice(out.Data, out.Size)
	p := filepath.Join(dir, name+".dpapi")
	tmp := p + ".new"
	if err := os.WriteFile(tmp, blob, 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, p); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	return "dpapi:" + p, nil
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
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return strings.TrimRight(string(unsafe.Slice(out.Data, out.Size)), "\r\n"), nil
}
