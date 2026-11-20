//go:build windows

package config

import "golang.org/x/sys/windows"

// LookupAccount resolves a service account's name (LookupName's forms: '.\user' as this computer's user) to its SID
// and its SID_NAME_USE.
func LookupAccount(account string) (*windows.SID, uint32, error) {
	cn, _ := windows.ComputerName()
	sid, _, use, err := windows.LookupSID("", LookupName(account, cn))
	return sid, use, err
}
