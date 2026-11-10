//go:build windows

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// The two tiers of the install:
//
//	pgvigil-app install [-no-autostart] [-no-update-check]      as an administrator: machine-wide
//	pgvigil-app install -user [-no-autostart] [-no-update-check] as the user: %LOCALAPPDATA%\pgvigil
//	pgvigil-app uninstall [-user] [-purge]
//
// Machine-wide: `pgvigil install` (beside the app) puts pgvigil.exe in %ProgramFiles%\pgvigil and the
// collector in the service pgvigil under its virtual account NT SERVICE\pgvigil; the app goes beside
// it; %ProgramData%\pgvigil\app\pgvigil.yaml (the UI login, readable by the machine's users) is
// written when absent; the Run entry under HKLM starts the app at every user's login; the policy key
// HKLM\Software\Policies\pgvigil\App holds UpdateCheck (1, or 0 with -no-update-check); the
// Programs and Features entry is under HKLM. Nothing else is written.
// Per user (no administrator): the app and pgvigil.exe in %LOCALAPPDATA%\pgvigil with a template
// pgvigil.yaml beside them, the Run entry and the Programs and Features entry under HKCU, no
// service. It needs the WebView2 Evergreen runtime on the machine already; without it the app has no
// window ('pgvigil serve -open' is the tier for that machine). Nothing outside %LOCALAPPDATA% and HKCU.

type exitErr struct {
	err  error
	code int
}

func (e *exitErr) Error() string { return e.err.Error() }
func (e *exitErr) ExitCode() int { return e.code }

func elevated() bool { return windows.GetCurrentProcessToken().IsElevated() }

func installFlags(name string, args []string) (user, noAuto, noUpdate, purge bool, err error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.BoolVar(&user, "user", false, "the per-user tier: %LOCALAPPDATA%\\pgvigil and HKCU only, no service")
	if name == "install" {
		fs.BoolVar(&noAuto, "no-autostart", false, "no start-at-login entry")
		fs.BoolVar(&noUpdate, "no-update-check", false, "turn the release-feed check off (machine: the policy for every user)")
	} else {
		fs.BoolVar(&purge, "purge", false, "also remove the UI configuration, the app's settings and its data")
	}
	if err = fs.Parse(args); err == nil && fs.NArg() > 0 {
		err = fmt.Errorf("%s takes flags only, got %q", name, fs.Arg(0))
	}
	if err != nil {
		err = &exitErr{err, 2}
	}
	return
}

func runInstall(args []string) error {
	user, noAuto, noUpdate, _, err := installFlags("install", args)
	if err != nil {
		return err
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	srcServe := filepath.Join(filepath.Dir(self), "pgvigil.exe")
	if !exists(srcServe) {
		return fmt.Errorf("pgvigil.exe must sit beside %s (the release zip holds both)", self)
	}
	if user {
		return installUser(self, srcServe, noAuto, noUpdate)
	}
	if !elevated() {
		return &exitErr{errors.New("the machine-wide install needs an elevated prompt (Run as administrator); a standard user installs for themselves with: pgvigil-app install -user"), 3}
	}
	return installMachine(self, srcServe, noAuto, noUpdate)
}

func installMachine(self, srcServe string, noAuto, noUpdate bool) error {
	dst := filepath.Join(os.Getenv("ProgramFiles"), "pgvigil")
	// the collector: pgvigil.exe to Program Files, the service under its virtual account
	cmd := exec.Command(srcServe, "install")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("pgvigil install (the collector service): %w", err)
	}
	app := filepath.Join(dst, "pgvigil-app.exe")
	if err := placeFile(self, app); err != nil {
		return err
	}
	fmt.Println("app:", app)
	// the UI configuration every user's app reads: SYSTEM and Administrators write, Users read
	uiDir := filepath.Join(os.Getenv("ProgramData"), "pgvigil", "app")
	if err := os.MkdirAll(uiDir, 0o755); err != nil {
		return err
	}
	if err := icacls(uiDir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F", "*S-1-5-32-545:(OI)(CI)RX"); err != nil {
		return err
	}
	if wrote, err := writeIfAbsent(filepath.Join(uiDir, UIConfigName), ConfigTemplate()); err != nil {
		return err
	} else if wrote {
		fmt.Println("written:", filepath.Join(uiDir, UIConfigName), "(fill in the repository login the UI reads with)")
	} else {
		fmt.Println("kept:", filepath.Join(uiDir, UIConfigName))
	}
	if err := setRun(registry.LOCAL_MACHINE, app, !noAuto); err != nil {
		return fmt.Errorf("start at login: %w", err)
	}
	fmt.Println("start at login for every user:", !noAuto)
	pk, _, err := registry.CreateKey(registry.LOCAL_MACHINE, policyKey, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("policy key: %w", err)
	}
	on := uint32(1)
	if noUpdate {
		on = 0
	}
	err = pk.SetDWordValue("UpdateCheck", on)
	_ = pk.Close()
	if err != nil {
		return fmt.Errorf("policy UpdateCheck: %w", err)
	}
	fmt.Printf("update check (HKLM\\%s UpdateCheck): %d\n", policyKey, on)
	if err := writeARP(registry.LOCAL_MACHINE, dst, app, `"`+app+`" uninstall`); err != nil {
		return err
	}
	fmt.Println("pgvigil is installed for every user. Next: the repository login in", filepath.Join(uiDir, UIConfigName), "and the collector's in", filepath.Join(os.Getenv("ProgramData"), "pgvigil"))
	return nil
}

func installUser(self, srcServe string, noAuto, noUpdate bool) error {
	if v := webView2Version(); v == "" {
		return &exitErr{errors.New("the WebView2 Evergreen runtime is not on this machine, and installing it needs an administrator: use 'pgvigil serve -open' (the browser tier) or ask for the machine-wide install"), 3}
	}
	dst := appDir()
	if err := os.MkdirAll(dst, 0o700); err != nil {
		return err
	}
	app := filepath.Join(dst, "pgvigil-app.exe")
	if err := placeFile(self, app); err != nil {
		return err
	}
	if err := placeFile(srcServe, filepath.Join(dst, "pgvigil.exe")); err != nil {
		return err
	}
	fmt.Println("app:", app)
	cfg := filepath.Join(dst, UIConfigName)
	if wrote, err := writeIfAbsent(cfg, ConfigTemplate()); err != nil {
		return err
	} else if wrote {
		fmt.Println("written:", cfg, "(fill in the repository login the UI reads with)")
	} else {
		fmt.Println("kept:", cfg)
	}
	if err := setRun(registry.CURRENT_USER, app, !noAuto); err != nil {
		return fmt.Errorf("start at login: %w", err)
	}
	fmt.Println("start at login:", !noAuto)
	if noUpdate {
		if err := writeUser(func(k registry.Key) error { return k.SetDWordValue("UpdateCheck", 0) }); err != nil {
			return err
		}
		fmt.Println("update check: off")
	}
	if err := writeARP(registry.CURRENT_USER, dst, app, `"`+app+`" uninstall -user`); err != nil {
		return err
	}
	fmt.Println("pgvigil is installed for", os.Getenv("USERNAME"), "in", dst)
	return nil
}

func runUninstall(args []string) error {
	user, _, _, purge, err := installFlags("uninstall", args)
	if err != nil {
		return err
	}
	stopRunningApp() // this session's app and the serve it started hold the files
	if user {
		dst := appDir()
		var left []string
		for _, f := range append([]string{"pgvigil.exe"}, oldCopies(dst)...) {
			if err := os.Remove(filepath.Join(dst, filepath.Base(f))); err != nil && !errors.Is(err, os.ErrNotExist) {
				left = append(left, filepath.Join(dst, filepath.Base(f)))
			}
		}
		if purge {
			for _, f := range []string{UIConfigName, "app.log", "app.log.1"} {
				_ = os.Remove(filepath.Join(dst, f))
			}
			_ = os.RemoveAll(filepath.Join(dst, "WebView2"))
		}
		if len(left) > 0 { // the entries stay: the uninstall can be run again once the files are free
			return &exitErr{fmt.Errorf("not removed (in use: quit pgvigil and run the uninstall again): %s", strings.Join(left, ", ")), 1}
		}
		_ = setRun(registry.CURRENT_USER, "", false)
		if purge {
			_ = registry.DeleteKey(registry.CURRENT_USER, userKey)
			_ = registry.DeleteKey(registry.CURRENT_USER, `Software\pgvigil`)
		}
		_ = registry.DeleteKey(registry.CURRENT_USER, arpKey) // last: the entry stays while anything failed
		removeSelfLater(filepath.Join(dst, "pgvigil-app.exe"), dst)
		fmt.Println("pgvigil is uninstalled for", os.Getenv("USERNAME"))
		return nil
	}
	if !elevated() {
		return &exitErr{errors.New("the machine-wide uninstall needs an elevated prompt; a per-user install: pgvigil-app uninstall -user"), 3}
	}
	dst := filepath.Join(os.Getenv("ProgramFiles"), "pgvigil")
	if exe := filepath.Join(dst, "pgvigil.exe"); exists(exe) {
		a := []string{"uninstall"}
		if purge {
			a = append(a, "-purge")
		}
		cmd := exec.Command(exe, a...)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil { // nothing else is removed yet: the uninstall can be run again
			return fmt.Errorf("pgvigil uninstall (the collector service): %w", err)
		}
	}
	_ = setRun(registry.LOCAL_MACHINE, "", false)
	if purge {
		_ = os.RemoveAll(filepath.Join(os.Getenv("ProgramData"), "pgvigil", "app"))
		_ = registry.DeleteKey(registry.LOCAL_MACHINE, policyKey)
		_ = registry.DeleteKey(registry.LOCAL_MACHINE, `Software\Policies\pgvigil`)
		_ = os.Remove(filepath.Join(os.Getenv("ProgramData"), "pgvigil")) // when the collector's purge left it empty
	}
	// pgvigil uninstall cannot delete its own running binary: once it has exited, the app does; a file
	// another session's serve still holds goes at the next restart
	for _, f := range append([]string{"pgvigil.exe"}, oldCopies(dst)...) {
		removeOrAtRestart(filepath.Join(dst, filepath.Base(f)))
	}
	_ = registry.DeleteKey(registry.LOCAL_MACHINE, arpKey) // last
	removeSelfLater(filepath.Join(dst, "pgvigil-app.exe"), dst)
	fmt.Println("pgvigil is uninstalled for every user (another session's running app keeps its window until it quits)")
	return nil
}

// stopRunningApp asks this session's app to quit and waits (15 s at most) for its process to end,
// so the serve it started has stopped and the files are free.
func stopRunningApp() {
	h := findApp()
	if h == 0 {
		return
	}
	var pid uint32
	_, _, _ = pGetWindowThreadProcessID.Call(h, uintptr(unsafe.Pointer(&pid)))
	var ph windows.Handle
	if pid != 0 {
		ph, _ = windows.OpenProcess(windows.SYNCHRONIZE, false, pid)
	}
	_, _, _ = pPostMessageW.Call(h, wmQuit, 0, 0)
	if ph != 0 {
		_, _ = windows.WaitForSingleObject(ph, 15000)
		_ = windows.CloseHandle(ph)
	}
}

// oldCopies are the files placeFile moved aside (name.old-<n>) in dir.
func oldCopies(dir string) []string {
	m, _ := filepath.Glob(filepath.Join(dir, "*.old-*"))
	return m
}

// placeFile copies src to dst; a dst that runs (another session's app) is moved aside first:
// Windows lets a running program be renamed, not overwritten.
func placeFile(src, dst string) error {
	if a, err := filepath.Abs(src); err == nil {
		if b, err := filepath.Abs(dst); err == nil && strings.EqualFold(a, b) {
			return nil
		}
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	tmp := dst + ".new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	for _, o := range oldCopies(filepath.Dir(dst)) { // earlier copies, once nothing runs them
		_ = os.Remove(o)
	}
	if exists(dst) {
		if err := os.Remove(dst); err != nil {
			if err := os.Rename(dst, fmt.Sprintf("%s.old-%d", dst, time.Now().UnixNano())); err != nil {
				_ = os.Remove(tmp)
				return fmt.Errorf("replace %s: %w", dst, err)
			}
		}
	}
	return os.Rename(tmp, dst)
}

func writeIfAbsent(p, content string) (bool, error) {
	f, err := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if errors.Is(err, os.ErrExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	_, err = f.WriteString(strings.ReplaceAll(content, "\n", "\r\n"))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err == nil, err
}

func icacls(args ...string) error {
	out, err := exec.Command(filepath.Join(system32(), "icacls.exe"), args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("icacls %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func writeARP(root registry.Key, dir, app, uninstall string) error {
	k, _, err := registry.CreateKey(root, arpKey, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("programs and features: %w", err)
	}
	defer func() { _ = k.Close() }()
	for n, v := range map[string]string{"DisplayName": "pgvigil", "DisplayVersion": version, "Publisher": "pgvigil",
		"InstallLocation": dir, "DisplayIcon": app, "UninstallString": uninstall, "URLInfoAbout": "https://github.com/aachaemenes/pgvigil"} {
		if err := k.SetStringValue(n, v); err != nil {
			return err
		}
	}
	for n, v := range map[string]uint32{"NoModify": 1, "NoRepair": 1} {
		if err := k.SetDWordValue(n, v); err != nil {
			return err
		}
	}
	return nil
}

// removeSelfLater deletes the app's own file (and its folder when empty) once this process has
// exited: a running program cannot delete itself. A hidden cmd waits two seconds, then deletes.
func removeSelfLater(exe, dir string) {
	if !exists(exe) {
		return
	}
	self, _ := os.Executable()
	if !strings.EqualFold(filepath.Clean(self), filepath.Clean(exe)) {
		// another copy runs it (another user's app on a shared host): removed at the next restart
		removeOrAtRestart(exe)
		if err := os.Remove(dir); err != nil && !errors.Is(err, os.ErrNotExist) && elevated() {
			_ = windows.MoveFileEx(u16(dir), nil, windows.MOVEFILE_DELAY_UNTIL_REBOOT) // after the file, once empty
		}
		return
	}
	// the command line is given whole: cmd.exe does not read Go's backslash-escaped quotes; every
	// program by its System32 path, never through PATH (an install runs elevated)
	sys := system32()
	c := exec.Command(filepath.Join(sys, "cmd.exe"))
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow,
		CmdLine: `"` + filepath.Join(sys, "cmd.exe") + `" /d /c ""` + filepath.Join(sys, "PING.EXE") + `" -n 3 127.0.0.1 >nul & del /f /q "` + exe + `" & rmdir "` + dir + `" 2>nul"`}
	_ = c.Start()
}

// removeOrAtRestart deletes p; a file in use goes at the next restart (elevated), else it is named.
func removeOrAtRestart(p string) {
	err := os.Remove(p)
	if err == nil || errors.Is(err, os.ErrNotExist) {
		return
	}
	if elevated() {
		if err := windows.MoveFileEx(u16(p), nil, windows.MOVEFILE_DELAY_UNTIL_REBOOT); err == nil {
			fmt.Println("in use, removed at the next restart:", p)
			return
		}
	}
	fmt.Println("not removed (in use):", p, err)
}

// system32 is %SystemRoot%\System32, from the system, not from the environment.
func system32() string {
	if d, err := windows.GetSystemDirectory(); err == nil && d != "" {
		return d
	}
	return `C:\Windows\System32`
}
