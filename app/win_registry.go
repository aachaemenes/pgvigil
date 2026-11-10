//go:build windows

package main

import (
	"errors"
	"strings"

	"golang.org/x/sys/windows/registry"
)

const (
	policyKey = `Software\Policies\pgvigil\App` // HKLM: the administrator's (installer, Group Policy)
	userKey   = `Software\pgvigil\App`          // HKCU: the user's own (window size, choices)
	runKey    = `Software\Microsoft\Windows\CurrentVersion\Run`
	runValue  = "pgvigil"
	arpKey    = `Software\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil`
	// the WebView2 Evergreen runtime's client id (Microsoft's documented detection key)
	webview2Client = `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`
)

func readDword(root registry.Key, path, name string) *uint32 {
	k, err := registry.OpenKey(root, path, registry.QUERY_VALUE)
	if err != nil {
		return nil
	}
	defer func() { _ = k.Close() }()
	v, _, err := k.GetIntegerValue(name)
	if err != nil {
		return nil
	}
	x := uint32(v)
	return &x
}

func readString(root registry.Key, path, name string) string {
	k, err := registry.OpenKey(root, path, registry.QUERY_VALUE)
	if err != nil {
		return ""
	}
	defer func() { _ = k.Close() }()
	v, _, err := k.GetStringValue(name)
	if err != nil {
		return ""
	}
	return v
}

// readChoices reads the policy and the user's values.
func readChoices() Choices {
	return Choices{
		PolicyUpdateCheck:  readDword(registry.LOCAL_MACHINE, policyKey, "UpdateCheck"),
		PolicyUpdateFeed:   readString(registry.LOCAL_MACHINE, policyKey, "UpdateFeed"),
		PolicyAttachURL:    readString(registry.LOCAL_MACHINE, policyKey, "AttachURL"),
		PolicyRequireLogin: readDword(registry.LOCAL_MACHINE, policyKey, "RequireLogin"),
		UserUpdateCheck:    readDword(registry.CURRENT_USER, userKey, "UpdateCheck"),
		UserAttachURL:      readString(registry.CURRENT_USER, userKey, "AttachURL"),
		UserNoLogin:        readDword(registry.CURRENT_USER, userKey, "NoLogin"),
		Width:              readDword(registry.CURRENT_USER, userKey, "Width"),
		Height:             readDword(registry.CURRENT_USER, userKey, "Height"),
		Maximized:          readDword(registry.CURRENT_USER, userKey, "Maximized"),
	}
}

func writeUser(set func(k registry.Key) error) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, userKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer func() { _ = k.Close() }()
	return set(k)
}

// saveWindow keeps the window's size (the restored size when it is maximized) for the next start.
func saveWindow(width, height int, maximized bool) error {
	return writeUser(func(k registry.Key) error {
		m := uint32(0)
		if maximized {
			m = 1
		}
		if err := k.SetDWordValue("Maximized", m); err != nil {
			return err
		}
		if width < 400 || height < 300 {
			return nil
		}
		if err := k.SetDWordValue("Width", uint32(width)); err != nil {
			return err
		}
		return k.SetDWordValue("Height", uint32(height))
	})
}

func lastUpdateCheck() int64 {
	k, err := registry.OpenKey(registry.CURRENT_USER, userKey, registry.QUERY_VALUE)
	if err != nil {
		return 0
	}
	defer func() { _ = k.Close() }()
	v, _, err := k.GetIntegerValue("LastUpdateCheck")
	if err != nil {
		return 0
	}
	return int64(v)
}

func setLastUpdateCheck(unix int64) error {
	return writeUser(func(k registry.Key) error { return k.SetQWordValue("LastUpdateCheck", uint64(unix)) })
}

// runCommand is the start-at-login command line: the app in the tray.
func runCommand(exe string) string { return `"` + exe + `" -tray` }

// startAtLogin reads both Run entries: the machine's (every user, the installer's) and the user's.
func startAtLogin() (machine, user bool) {
	return readString(registry.LOCAL_MACHINE, runKey, runValue) != "", readString(registry.CURRENT_USER, runKey, runValue) != ""
}

// setRun writes or removes the Run value under root (HKCU for the user's own toggle; HKLM for the installer).
func setRun(root registry.Key, exe string, on bool) error {
	k, _, err := registry.CreateKey(root, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer func() { _ = k.Close() }()
	if on {
		return k.SetStringValue(runValue, runCommand(exe))
	}
	if err := k.DeleteValue(runValue); err != nil && !errors.Is(err, registry.ErrNotExist) {
		return err
	}
	return nil
}

// webView2Version is the installed Evergreen runtime's version ("" = none): the machine-wide
// install (32- and 64-bit views) or the per-user one.
func webView2Version() string {
	for _, p := range []struct {
		root registry.Key
		path string
	}{
		{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\` + webview2Client},
		{registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\EdgeUpdate\Clients\` + webview2Client},
		{registry.CURRENT_USER, `Software\Microsoft\EdgeUpdate\Clients\` + webview2Client},
	} {
		if v := strings.TrimSpace(readString(p.root, p.path, "pv")); v != "" && v != "0.0.0.0" {
			return v
		}
	}
	return ""
}
