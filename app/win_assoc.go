//go:build windows

package main

import (
	"errors"
	"fmt"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// The Open with entries for .sqlplan and .xdl (AssocLines, openfiles.go): HKCU\Software\Classes for a per-user
// install, HKLM\Software\Classes machine-wide.

var (
	advapi32        = windows.NewLazySystemDLL("advapi32.dll")
	pRegSetValueExW = advapi32.NewProc("RegSetValueExW")
	pSHChangeNotify = shell32.NewProc("SHChangeNotify")
)

const (
	regNone           = 0          // REG_NONE: the registry package sets none of this type
	shcneAssocChanged = 0x08000000 // SHCNE_ASSOCCHANGED, with SHCNF_IDLIST and both items NULL
	shcnfIDList       = 0x0000
)

// setNone writes an empty REG_NONE value.
func setNone(k registry.Key, name string) error {
	p, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	if r, _, _ := pRegSetValueExW.Call(uintptr(k), uintptr(unsafe.Pointer(p)), 0, regNone, 0, 0); r != 0 {
		return syscall.Errno(r)
	}
	return nil
}

// writeAssoc writes every line of AssocLines(exe) under root, then tells Explorer the associations changed.
func writeAssoc(root registry.Key, exe string) error {
	for _, l := range AssocLines(exe) {
		k, _, err := registry.CreateKey(root, l.Key, registry.SET_VALUE)
		if err != nil {
			return fmt.Errorf("%s: %w", l.Key, err)
		}
		if l.Kind == RegNone {
			err = setNone(k, l.Name)
		} else {
			err = k.SetStringValue(l.Name, l.Value)
		}
		_ = k.Close()
		if err != nil {
			return fmt.Errorf(`%s\%s: %w`, l.Key, l.Name, err)
		}
	}
	notifyAssoc()
	return nil
}

// removeAssoc deletes pgvigil's ProgIDs and its OpenWithProgids values under root; an entry already gone is no error.
func removeAssoc(root registry.Key) error {
	keys, values := AssocRemoval()
	var errs []error
	for _, v := range values {
		k, err := registry.OpenKey(root, v.Key, registry.SET_VALUE)
		if errors.Is(err, registry.ErrNotExist) {
			continue
		}
		if err == nil {
			err = k.DeleteValue(v.Name)
			_ = k.Close()
		}
		if err != nil && !errors.Is(err, registry.ErrNotExist) {
			errs = append(errs, fmt.Errorf(`%s\%s: %w`, v.Key, v.Name, err))
		}
	}
	for _, k := range keys {
		if err := registry.DeleteKey(root, k); err != nil && !errors.Is(err, registry.ErrNotExist) {
			errs = append(errs, fmt.Errorf("%s: %w", k, err))
		}
	}
	notifyAssoc()
	return errors.Join(errs...)
}

func notifyAssoc() { _, _, _ = pSHChangeNotify.Call(shcneAssocChanged, shcnfIDList, 0, 0) }
