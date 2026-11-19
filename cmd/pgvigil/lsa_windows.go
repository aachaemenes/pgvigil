//go:build windows

package main

import (
	"errors"
	"fmt"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The LSA policy calls of advapi32 (golang.org/x/sys/windows has none): 'Log on as a service' for the service's
// account, granted and read back (RELNOTES L150).
var (
	modAdvapi32                   = windows.NewLazySystemDLL("advapi32.dll")
	procLsaOpenPolicy             = modAdvapi32.NewProc("LsaOpenPolicy")
	procLsaAddAccountRights       = modAdvapi32.NewProc("LsaAddAccountRights")
	procLsaEnumerateAccountRights = modAdvapi32.NewProc("LsaEnumerateAccountRights")
	procLsaFreeMemory             = modAdvapi32.NewProc("LsaFreeMemory")
	procLsaClose                  = modAdvapi32.NewProc("LsaClose")
	procLsaNtStatusToWinError     = modAdvapi32.NewProc("LsaNtStatusToWinError")
)

const (
	seServiceLogonRight      = "SeServiceLogonRight"
	policyCreateAccount      = 0x00000010
	policyLookupNames        = 0x00000800
	statusObjectNameNotFound = 0xC0000034 // the account holds no right at all
)

// lsaUnicodeString is LSA_UNICODE_STRING: lengths in bytes, no terminator counted.
type lsaUnicodeString struct {
	Length        uint16
	MaximumLength uint16
	Buffer        *uint16
}

// lsaObjectAttributes is LSA_OBJECT_ATTRIBUTES, all zero but its length (LsaOpenPolicy reads nothing else).
type lsaObjectAttributes struct {
	Length                   uint32
	RootDirectory            windows.Handle
	ObjectName               *lsaUnicodeString
	Attributes               uint32
	SecurityDescriptor       uintptr
	SecurityQualityOfService uintptr
}

func lsaString(s string) (lsaUnicodeString, error) {
	u, err := windows.UTF16FromString(s)
	if err != nil {
		return lsaUnicodeString{}, err
	}
	n := uint16((len(u) - 1) * 2)
	return lsaUnicodeString{Length: n, MaximumLength: n + 2, Buffer: &u[0]}, nil
}

// lsaErr turns an NTSTATUS into the Windows error it stands for.
func lsaErr(call string, status uintptr) error {
	if status == 0 {
		return nil
	}
	code, _, _ := procLsaNtStatusToWinError.Call(status)
	return fmt.Errorf("%s: %w", call, syscall.Errno(code))
}

// grantServiceLogon adds SeServiceLogonRight to account's rights on this host (a right already held is no error) and
// reads it back.
func grantServiceLogon(account string) error {
	sid, _, _, err := windows.LookupSID("", account)
	if err != nil {
		return fmt.Errorf("the account %s: %w", account, err)
	}
	var oa lsaObjectAttributes
	oa.Length = uint32(unsafe.Sizeof(oa))
	var policy windows.Handle
	st, _, _ := procLsaOpenPolicy.Call(0, uintptr(unsafe.Pointer(&oa)), policyCreateAccount|policyLookupNames, uintptr(unsafe.Pointer(&policy)))
	if err := lsaErr("LsaOpenPolicy", st); err != nil {
		return err
	}
	defer func() { _, _, _ = procLsaClose.Call(uintptr(policy)) }()
	right, err := lsaString(seServiceLogonRight)
	if err != nil {
		return err
	}
	st, _, _ = procLsaAddAccountRights.Call(uintptr(policy), uintptr(unsafe.Pointer(sid)), uintptr(unsafe.Pointer(&right)), 1)
	if err := lsaErr("LsaAddAccountRights", st); err != nil {
		return err
	}
	held, err := holdsRight(policy, sid, seServiceLogonRight)
	if err != nil {
		return err
	}
	if !held {
		return errors.New("LsaAddAccountRights returned success, yet the account's rights do not list " + seServiceLogonRight)
	}
	return nil
}

// holdsRight reads the account's rights and says whether name is among them.
func holdsRight(policy windows.Handle, sid *windows.SID, name string) (bool, error) {
	var rights *lsaUnicodeString
	var n uint32
	st, _, _ := procLsaEnumerateAccountRights.Call(uintptr(policy), uintptr(unsafe.Pointer(sid)), uintptr(unsafe.Pointer(&rights)), uintptr(unsafe.Pointer(&n)))
	if st == statusObjectNameNotFound {
		return false, nil
	}
	if err := lsaErr("LsaEnumerateAccountRights", st); err != nil {
		return false, err
	}
	defer func() { _, _, _ = procLsaFreeMemory.Call(uintptr(unsafe.Pointer(rights))) }()
	for _, r := range unsafe.Slice(rights, n) {
		if windows.UTF16ToString(unsafe.Slice(r.Buffer, r.Length/2)) == name {
			return true, nil
		}
	}
	return false, nil
}
