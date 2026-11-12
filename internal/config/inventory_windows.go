//go:build windows

package config

import (
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

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
