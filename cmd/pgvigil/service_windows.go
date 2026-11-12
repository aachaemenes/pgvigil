//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	serviceName    = "pgvigil"
	serviceAccount = `NT SERVICE\pgvigil` // the service's own virtual account: no password, no profile
	dsnFileName    = "repo.dsn"
	logFileName    = "pgvigil.log"
)

func programData() string {
	if v := os.Getenv("ProgramData"); v != "" {
		return v
	}
	return `C:\ProgramData`
}

func programFiles() string {
	if v := os.Getenv("ProgramFiles"); v != "" {
		return v
	}
	return `C:\Program Files`
}

func defaultInstallOptions() installOptions {
	return installOptions{
		Bin:    filepath.Join(programFiles(), "pgvigil", "pgvigil.exe"),
		Config: filepath.Join(programData(), "pgvigil", "pgvigil.yaml"),
		User:   serviceAccount,
	}
}

func connectSCM() (*mgr.Mgr, error) {
	m, err := mgr.Connect()
	if err != nil {
		return nil, fmt.Errorf("the service manager refused (%v): run this from an elevated PowerShell (Administrator)", err)
	}
	return m, nil
}

// waitState polls the service until it reaches want or the deadline passes.
func waitState(s *mgr.Service, want svc.State, d time.Duration) (svc.Status, error) {
	deadline := time.Now().Add(d)
	for {
		st, err := s.Query()
		if err != nil {
			return st, err
		}
		if st.State == want {
			return st, nil
		}
		if time.Now().After(deadline) {
			return st, fmt.Errorf("the service is in state %d after %s", st.State, d)
		}
		time.Sleep(300 * time.Millisecond)
	}
}

func stopIfRunning(log *slog.Logger, s *mgr.Service) error {
	st, err := s.Query()
	if err != nil {
		return err
	}
	if st.State == svc.Stopped {
		return nil
	}
	if _, err := s.Control(svc.Stop); err != nil {
		return fmt.Errorf("stop: %w", err)
	}
	if _, err := waitState(s, svc.Stopped, 30*time.Second); err != nil {
		return err
	}
	log.Info("service stopped")
	return nil
}

func installService(log *slog.Logger, o installOptions) error {
	m, err := connectSCM()
	if err != nil {
		return err
	}
	defer func() { _ = m.Disconnect() }()
	existing, err := m.OpenService(serviceName)
	if err == nil {
		// an upgrade: the running binary cannot be replaced while the service holds it
		if err := stopIfRunning(log, existing); err != nil {
			_ = existing.Close()
			return err
		}
	}
	if err := installBinary(log, o.Bin); err != nil {
		if existing != nil {
			_ = existing.Close()
		}
		return err
	}
	dataDir := filepath.Dir(o.Config)
	dsnFile := filepath.Join(dataDir, dsnFileName)
	logDir := filepath.Join(dataDir, "logs")
	if err := dedicatedFolder(dataDir, filepath.Base(o.Config)); err != nil {
		return err
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return err
	}
	for _, f := range []struct{ path, content string }{{o.Config, configTemplate("file:" + dsnFile)}, {dsnFile, ""}} {
		wrote, err := writeIfAbsent(f.path, f.content, 0o600)
		if err != nil {
			return err
		}
		if wrote {
			log.Info("written", "path", f.path)
		} else {
			log.Info("kept", "path", f.path)
		}
	}
	cfg := mgr.Config{
		DisplayName:      "pgvigil collector",
		Description:      "PostgreSQL monitoring collector: polls the instances named in its configuration and writes to the pgvigil repository.",
		StartType:        mgr.StartAutomatic,
		ServiceStartName: o.User,
	}
	var s *mgr.Service
	if existing != nil {
		s = existing
		c, err := s.Config()
		if err != nil {
			_ = s.Close()
			return err
		}
		c.BinaryPathName = windows.EscapeArg(o.Bin) + " run -config " + windows.EscapeArg(o.Config)
		c.DisplayName, c.Description, c.StartType, c.ServiceStartName = cfg.DisplayName, cfg.Description, cfg.StartType, cfg.ServiceStartName
		if err := s.UpdateConfig(c); err != nil {
			_ = s.Close()
			return fmt.Errorf("update service: %w", err)
		}
		log.Info("service updated", "account", o.User)
	} else {
		s, err = m.CreateService(serviceName, o.Bin, cfg, "run", "-config", o.Config)
		if err != nil {
			return fmt.Errorf("create service: %w", err)
		}
		log.Info("service created", "account", o.User)
	}
	defer func() { _ = s.Close() }()
	if err := s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}, 86400); err != nil {
		log.Warn("recovery actions not set", "err", err)
	}
	// the service reports SERVICE_STOPPED with an exit code on a runtime failure (Execute returns (true, 1)); without
	// this flag Windows runs the recovery actions only for a crash, so a repository down at boot would stay stopped.
	// A configuration error returns (false, 0): no exit code, no retry.
	if err := s.SetRecoveryActionsOnNonCrashFailures(true); err != nil {
		log.Warn("recovery on a non-crash failure not set", "err", err)
	}
	// the data folder (config, repo.dsn, log) for SYSTEM, Administrators and the service account only;
	// the binary folder readable by the service account (SIDs, not names: Administrators is localised)
	icacls := func(args ...string) {
		out, err := exec.Command("icacls", args...).CombinedOutput()
		if err != nil {
			log.Warn("icacls failed; set the permission by hand", "args", strings.Join(args, " "), "err", err, "out", strings.TrimSpace(string(out)))
		}
	}
	icacls(dataDir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F", o.User+":(OI)(CI)R")
	icacls(filepath.Dir(o.Bin), "/grant", o.User+":(OI)(CI)RX")
	// the service reads its folder and writes only under logs\ (so a deleted log is made again, and the
	// config and repo.dsn stay out of its reach)
	icacls(logDir, "/grant", o.User+":(OI)(CI)M")
	log.Info("permissions set", "data", dataDir, "readers", "SYSTEM, Administrators, "+o.User, "writable by the service", logDir)
	ready, why := configReady(o.Config, "")
	if o.NoStart || !ready {
		if !ready {
			log.Info("service installed, not started", "why", why)
		}
		fmt.Printf("pgvigil is installed as the service %s (automatic start). Next:\n  1. %s: the collector's repository connection string, one line (the owner ran migrate and roles)\n  2. %s: list the instances (each dsn as file:<path> beside it, or env:NAME set for the service), or add them later in the page (Admin > Instances)\n  3. Start-Service %s; Get-Content %s -Wait\n", serviceName, dsnFile, o.Config, serviceName, filepath.Join(logDir, logFileName))
		return nil
	}
	if err := s.Start(); err != nil {
		return fmt.Errorf("start: %w", err)
	}
	if _, err := waitState(s, svc.Running, 15*time.Second); err != nil {
		return fmt.Errorf("the service did not come up (%v); see %s", err, filepath.Join(logDir, logFileName))
	}
	fmt.Printf("pgvigil is installed and running (Get-Service %s; the log is %s).\n", serviceName, filepath.Join(logDir, logFileName))
	return nil
}

func uninstallService(log *slog.Logger, o installOptions) error {
	m, err := connectSCM()
	if err != nil {
		return err
	}
	defer func() { _ = m.Disconnect() }()
	if s, err := m.OpenService(serviceName); err == nil {
		if err := stopIfRunning(log, s); err != nil {
			_ = s.Close()
			return err
		}
		if err := s.Delete(); err != nil {
			_ = s.Close()
			return fmt.Errorf("delete service: %w", err)
		}
		_ = s.Close()
		log.Info("service removed", "name", serviceName)
	} else {
		log.Info("no service to remove", "name", serviceName)
	}
	dataDir := filepath.Dir(o.Config)
	if o.Purge {
		if err := purgeFolder(log, dataDir, filepath.Base(o.Config), dsnFileName); err != nil {
			return err
		}
		if err := os.Remove(o.Bin); err != nil && !errors.Is(err, os.ErrNotExist) {
			fmt.Printf("%s could not be removed (%v): delete it by hand once this process has exited.\n", o.Bin, err)
		} else if err := os.Remove(filepath.Dir(o.Bin)); err != nil && !errors.Is(err, os.ErrNotExist) {
			log.Info("folder kept: it still holds other files", "path", filepath.Dir(o.Bin))
		}
	} else {
		fmt.Printf("the service is gone; %s and %s are kept (pgvigil uninstall -purge removes them).\n", dataDir, filepath.Dir(o.Bin))
	}
	return nil
}

// pgvigilService runs the scheduler under the service control manager.
type pgvigilService struct {
	args []string
	log  *slog.Logger
}

func (p *pgvigilService) Execute(_ []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runScheduler(ctx, p.log, p.args) }()
	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case err := <-done:
			changes <- svc.Status{State: svc.StopPending}
			if err != nil {
				var ec interface{ ExitCode() int }
				if errors.As(err, &ec) && ec.ExitCode() == 3 {
					p.log.Error("configuration error; the service stops and is not retried until the config is fixed and it is started again", "err", err)
					return false, 0
				}
				p.log.Error("pgvigil failed", "err", err)
				return true, 1
			}
			return false, 0
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				changes <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending}
				cancel()
				select {
				case e := <-done:
					if e != nil {
						p.log.Warn("the scheduler ended with an error while stopping", "err", e)
					}
				case <-time.After(30 * time.Second):
					p.log.Warn("the scheduler did not stop within 30 s")
				}
				p.log.Info("service stopped")
				return false, 0
			}
		}
	}
}

// flagValue reads -name v or -name=v out of a flag list without parsing the rest.
func flagValue(args []string, name string) string {
	for i := 0; i < len(args); i++ {
		if args[i] == name && i+1 < len(args) {
			return args[i+1]
		}
		if strings.HasPrefix(args[i], name+"=") {
			return args[i][len(name)+1:]
		}
	}
	return ""
}

// maybeRunAsService: under the service control manager `pgvigil run` has no console, so its log goes
// to pgvigil.log beside the config and the scheduler runs inside the service handler.
func maybeRunAsService(args []string) (bool, int) {
	isSvc, err := svc.IsWindowsService()
	if err != nil || !isSvc || len(args) == 0 || args[0] != "run" {
		return false, 0
	}
	logPath := filepath.Join(programData(), "pgvigil", "logs", logFileName)
	if cfgPath := flagValue(args[1:], "-config"); cfgPath != "" {
		logPath = filepath.Join(filepath.Dir(cfgPath), "logs", logFileName)
	}
	_ = os.MkdirAll(filepath.Dir(logPath), 0o755)
	w := io.Writer(io.Discard)
	if f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
		defer func() { _ = f.Close() }()
		w = f
	}
	log := slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: slog.LevelInfo}))
	log.Info("service starting", "version", version)
	if err := svc.Run(serviceName, &pgvigilService{args: args[1:], log: log}); err != nil {
		log.Error("service run failed", "err", err)
		return true, 1
	}
	return true, 0
}

// replaceFile renames tmp over dst; the service was stopped first, so the old binary is not held.
func replaceFile(tmp, dst string) error { return os.Rename(tmp, dst) }

// --- install -upgrade on Windows (install.go's runUpgrade); not seen on Windows yet: unit tests and vet only

func init() {
	upgradeHooksOf = &upgradeHooks{
		installed:     installedServiceConfig,
		stop:          stopInstalled,
		start:         startInstalled,
		others:        otherProcessesWindows,
		freeBytes:     freeBytesWindows,
		dumpDir:       filepath.Join(programData(), "pgvigil-backups"),
		secureDumpDir: secureDirWindows,
		secureDumpFile: func(file string) error {
			// the file alone for SYSTEM and Administrators: a folder the operator named keeps its own permissions
			out, err := exec.Command("icacls", file, "/inheritance:r", "/grant:r", "*S-1-5-18:F", "*S-1-5-32-544:F").CombinedOutput()
			if err != nil {
				return fmt.Errorf("icacls: %v: %s", err, strings.TrimSpace(string(out)))
			}
			return nil
		},
		privileged: func() error {
			if !windows.GetCurrentProcessToken().IsElevated() {
				return errors.New("the upgrade needs an elevated prompt (Run as administrator)")
			}
			return nil
		},
		previous: func(bin string) string {
			return strings.TrimSuffix(bin, filepath.Ext(bin)) + ".previous" + filepath.Ext(bin)
		},
		ready: func(o installOptions) (bool, string) { return configReady(o.Config, "") },
	}
}

// installedServiceConfig reads the binary, the config and the account from the service's own definition
// (BinaryPathName = "<bin>" run -config "<config>", ServiceStartName).
func installedServiceConfig() (installOptions, bool, error) {
	m, err := connectSCM()
	if err != nil {
		return installOptions{}, false, err
	}
	defer func() { _ = m.Disconnect() }()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return installOptions{}, false, nil
	}
	defer func() { _ = s.Close() }()
	c, err := s.Config()
	if err != nil {
		return installOptions{}, false, err
	}
	return parseBinaryPathName(c.BinaryPathName, c.ServiceStartName)
}

func parseBinaryPathName(cmdline, account string) (installOptions, bool, error) {
	args, err := windows.DecomposeCommandLine(cmdline)
	if err != nil {
		return installOptions{}, false, fmt.Errorf("the service's command line %q: %w", cmdline, err)
	}
	if len(args) < 4 || args[1] != "run" || args[2] != "-config" {
		return installOptions{}, false, fmt.Errorf("the service's command line %q is not <binary> run -config <file>: not the installer's service", cmdline)
	}
	return installOptions{Bin: args[0], Config: args[3], User: account}, true, nil
}

func stopInstalled(log *slog.Logger) error {
	m, err := connectSCM()
	if err != nil {
		return err
	}
	defer func() { _ = m.Disconnect() }()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return err
	}
	defer func() { _ = s.Close() }()
	return stopIfRunning(log, s)
}

func startInstalled(_ *slog.Logger) error {
	m, err := connectSCM()
	if err != nil {
		return err
	}
	defer func() { _ = m.Disconnect() }()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return err
	}
	defer func() { _ = s.Close() }()
	if err := s.Start(); err != nil {
		return err
	}
	_, err = waitState(s, svc.Running, 15*time.Second)
	return err
}

// otherProcessesWindows lists the processes whose image is bin, but the service's own and this one.
func otherProcessesWindows(bin string) ([]string, error) {
	var servicePID uint32
	if m, err := connectSCM(); err == nil {
		if s, err := m.OpenService(serviceName); err == nil {
			if st, err := s.Query(); err == nil {
				servicePID = st.ProcessId
			}
			_ = s.Close()
		}
		_ = m.Disconnect()
	}
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer func() { _ = windows.CloseHandle(snap) }()
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	var out []string
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		pid := e.ProcessID
		if pid == 0 || pid == servicePID || pid == uint32(os.Getpid()) {
			continue
		}
		h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
		if err != nil {
			continue
		}
		buf := make([]uint16, windows.MAX_LONG_PATH)
		n := uint32(len(buf))
		qerr := windows.QueryFullProcessImageName(h, 0, &buf[0], &n)
		_ = windows.CloseHandle(h)
		if qerr != nil {
			continue
		}
		if strings.EqualFold(filepath.Clean(windows.UTF16ToString(buf[:n])), filepath.Clean(bin)) {
			out = append(out, fmt.Sprintf("pid %d: %s", pid, windows.UTF16ToString(e.ExeFile[:])))
		}
	}
	return out, nil
}

func freeBytesWindows(dir string) (uint64, error) {
	p, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return 0, err
	}
	var free, total, totalFree uint64
	if err := windows.GetDiskFreeSpaceEx(p, &free, &total, &totalFree); err != nil {
		return 0, err
	}
	return free, nil
}

// secureDirWindows makes dir for SYSTEM and Administrators only (SIDs: Administrators is localised), inheritance cut, so
// ProgramData's Users read does not reach a dump that holds password hashes and statement text.
func secureDirWindows(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	out, err := exec.Command("icacls", dir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F").CombinedOutput()
	if err != nil {
		return fmt.Errorf("icacls: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// --- uninstall -all on Windows (install.go's runUninstallAll). Not seen on Windows by this project's proofs yet.

// The app's registry names, as app/win_registry.go writes them (kept equal by hand: the app is its own module).
const (
	appPolicyKey = `Software\Policies\pgvigil` // HKLM, with the subkey App
	appUserKey   = `Software\pgvigil`          // HKCU, with the subkey App
	appRunKey    = `Software\Microsoft\Windows\CurrentVersion\Run`
	appRunValue  = "pgvigil"
	appARPKey    = `Software\Microsoft\Windows\CurrentVersion\Uninstall\pgvigil`
	machineEnv   = `SYSTEM\CurrentControlSet\Control\Session Manager\Environment`
)

func init() {
	uninstallHooksOf = &uninstallHooks{
		privileged: func() error {
			if !windows.GetCurrentProcessToken().IsElevated() {
				return errors.New("uninstall -all needs an elevated prompt (Run as administrator)")
			}
			return nil
		},
		running: func() bool {
			m, err := connectSCM()
			if err != nil {
				return false
			}
			defer func() { _ = m.Disconnect() }()
			s, err := m.OpenService(serviceName)
			if err != nil {
				return false
			}
			defer func() { _ = s.Close() }()
			st, err := s.Query()
			return err == nil && st.State != svc.Stopped
		},
		items: windowsItems,
		repoDSN: func(inst installOptions) string {
			b, err := os.ReadFile(filepath.Join(filepath.Dir(inst.Config), dsnFileName))
			if err != nil {
				return ""
			}
			line, _, _ := strings.Cut(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
			return strings.TrimSpace(line)
		},
	}
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// removeNowOrAtRestart deletes p; a file in use (this running binary, an app another session runs) is handed to
// MoveFileEx to go at the next restart and named.
func removeNowOrAtRestart(p string) error {
	err := os.Remove(p)
	if err == nil || errors.Is(err, os.ErrNotExist) {
		return nil
	}
	name, perr := windows.UTF16PtrFromString(p)
	if perr != nil {
		return err
	}
	if merr := windows.MoveFileEx(name, nil, windows.MOVEFILE_DELAY_UNTIL_REBOOT); merr != nil {
		return fmt.Errorf("%v; and at the next restart: %v", err, merr)
	}
	fmt.Printf("  %s is in use: it goes at the next restart\n", p)
	return nil
}

// stopProcessesUnder ends the processes whose image lies in dir (this user's app and the serve it started hold their
// files while they run) and names them.
func stopProcessesUnder(dir string) []string {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer func() { _ = windows.CloseHandle(snap) }()
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	prefix := strings.ToLower(filepath.Clean(dir)) + `\`
	var ended []string
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		pid := e.ProcessID
		if pid == 0 || pid == uint32(os.Getpid()) {
			continue
		}
		h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, pid)
		if err != nil {
			continue
		}
		buf := make([]uint16, windows.MAX_LONG_PATH)
		n := uint32(len(buf))
		if windows.QueryFullProcessImageName(h, 0, &buf[0], &n) == nil && strings.HasPrefix(strings.ToLower(windows.UTF16ToString(buf[:n])), prefix) {
			if windows.TerminateProcess(h, 1) == nil {
				_, _ = windows.WaitForSingleObject(h, 5000)
				ended = append(ended, fmt.Sprintf("pid %d %s", pid, windows.UTF16ToString(e.ExeFile[:])))
			}
		}
		_ = windows.CloseHandle(h)
	}
	return ended
}

// removeTreeNowOrAtRestart removes dir; what is still locked (the WebView2 data of an app another process holds) goes
// at the next restart through MoveFileEx, deepest first, and is named.
func removeTreeNowOrAtRestart(dir string) error {
	if err := os.RemoveAll(dir); err == nil {
		return nil
	}
	var paths []string
	_ = filepath.WalkDir(dir, func(p string, _ fs.DirEntry, err error) error {
		if err == nil {
			paths = append(paths, p)
		}
		return nil
	})
	slices.Reverse(paths) // WalkDir lists a folder before its contents
	for _, p := range paths {
		name, err := windows.UTF16PtrFromString(p)
		if err != nil {
			return err
		}
		if err := windows.MoveFileEx(name, nil, windows.MOVEFILE_DELAY_UNTIL_REBOOT); err != nil {
			return fmt.Errorf("%s is in use and cannot go at the next restart either: %v", p, err)
		}
	}
	fmt.Printf("  %s is in use: what is left of it goes at the next restart\n", dir)
	return nil
}

func regValue(root registry.Key, key, name string) bool {
	k, err := registry.OpenKey(root, key, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer func() { _ = k.Close() }()
	_, _, err = k.GetValue(name, nil)
	return err == nil
}

func regKey(root registry.Key, key string) bool {
	k, err := registry.OpenKey(root, key, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	_ = k.Close()
	return true
}

// deleteTree deletes key and its subkeys (registry.DeleteKey takes a key without subkeys only).
func deleteTree(root registry.Key, key string) error {
	k, err := registry.OpenKey(root, key, registry.ENUMERATE_SUB_KEYS)
	if err != nil {
		if errors.Is(err, registry.ErrNotExist) {
			return nil
		}
		return err
	}
	subs, err := k.ReadSubKeyNames(-1)
	_ = k.Close()
	if err != nil {
		return err
	}
	for _, s := range subs {
		if err := deleteTree(root, key+`\`+s); err != nil {
			return err
		}
	}
	if err := registry.DeleteKey(root, key); err != nil && !errors.Is(err, registry.ErrNotExist) {
		return err
	}
	return nil
}

// windowsItems lists everything of pgvigil on this machine after the repository, in the order uninstall -all removes
// it: the app (machine-wide, then this user's), start at login, Programs and Features, the policy keys, the machine PATH
// entry, the service, the binaries and the configuration.
func windowsItems(inst installOptions, found bool) []removal {
	binDir := filepath.Dir(inst.Bin)
	cfgDir := filepath.Dir(inst.Config)
	var items []removal
	// the app always installs to %ProgramFiles%\pgvigil (app/win_install.go), whatever -bin the collector took
	appHome := filepath.Join(programFiles(), "pgvigil")
	apps, _ := filepath.Glob(filepath.Join(appHome, "pgvigil-app.exe*"))
	olds, _ := filepath.Glob(filepath.Join(appHome, "*.old-*"))
	appFiles := append(apps, olds...)
	items = append(items, removal{what: "the app, machine-wide (" + filepath.Join(appHome, "pgvigil-app.exe") + " and its old copies)", present: len(appFiles) > 0, remove: func() error {
		for _, f := range appFiles {
			if err := removeNowOrAtRestart(f); err != nil {
				return err
			}
		}
		return nil
	}})
	uiDir := filepath.Join(programData(), "pgvigil", "app")
	items = append(items, removal{what: "the app's configuration folder " + uiDir, present: exists(uiDir), remove: func() error { return os.RemoveAll(uiDir) }})
	mine := ""
	if d := os.Getenv("LOCALAPPDATA"); d != "" {
		mine = filepath.Join(d, "pgvigil")
		items = append(items, removal{what: "this user's app " + mine, present: exists(mine), remove: func() error {
			// the running app (start at login is the default) and the serve it started hold the folder's files
			if ended := stopProcessesUnder(mine); len(ended) > 0 {
				fmt.Printf("  ended this user's running app: %s\n", strings.Join(ended, ", "))
			}
			return removeTreeNowOrAtRestart(mine)
		}})
	}
	if profiles, err := filepath.Glob(filepath.Join(os.Getenv("SystemDrive")+`\`, "Users", "*", "AppData", "Local", "pgvigil")); err == nil {
		for _, p := range profiles {
			if !strings.EqualFold(p, mine) {
				items = append(items, removal{what: "another user's app " + p, present: true, kept: "its keys live in that user's own registry hive: that user runs pgvigil-app uninstall -user"})
			}
		}
	}
	for _, r := range []struct {
		root registry.Key
		name string
	}{{registry.LOCAL_MACHINE, "HKLM"}, {registry.CURRENT_USER, "HKCU"}} {
		root := r.root
		items = append(items,
			removal{what: "start at login (" + r.name + `\` + appRunKey + " " + appRunValue + ")", present: regValue(root, appRunKey, appRunValue), remove: func() error {
				k, err := registry.OpenKey(root, appRunKey, registry.SET_VALUE)
				if err != nil {
					return err
				}
				defer func() { _ = k.Close() }()
				if err := k.DeleteValue(appRunValue); err != nil && !errors.Is(err, registry.ErrNotExist) {
					return err
				}
				return nil
			}},
			removal{what: "the Programs and Features entry (" + r.name + `\` + appARPKey + ")", present: regKey(root, appARPKey), remove: func() error { return deleteTree(root, appARPKey) }},
		)
	}
	items = append(items,
		removal{what: `the policy keys (HKLM\` + appPolicyKey + ")", present: regKey(registry.LOCAL_MACHINE, appPolicyKey), remove: func() error { return deleteTree(registry.LOCAL_MACHINE, appPolicyKey) }},
		removal{what: `this user's app settings (HKCU\` + appUserKey + ")", present: regKey(registry.CURRENT_USER, appUserKey), remove: func() error { return deleteTree(registry.CURRENT_USER, appUserKey) }},
	)
	pathHas := false
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, machineEnv, registry.QUERY_VALUE); err == nil {
		if v, _, err := k.GetStringValue("Path"); err == nil {
			_, pathHas = pathWithout(v, binDir)
		}
		_ = k.Close()
	}
	items = append(items, removal{what: "the machine PATH entry " + binDir, present: pathHas, remove: func() error {
		k, err := registry.OpenKey(registry.LOCAL_MACHINE, machineEnv, registry.QUERY_VALUE|registry.SET_VALUE)
		if err != nil {
			return err
		}
		defer func() { _ = k.Close() }()
		v, typ, err := k.GetStringValue("Path")
		if err != nil {
			return err
		}
		nv, _ := pathWithout(v, binDir)
		if typ == registry.EXPAND_SZ {
			return k.SetExpandStringValue("Path", nv)
		}
		return k.SetStringValue("Path", nv)
	}})
	// a service deleted earlier that a handle still holds (services.msc) is marked for deletion: pending, not to remove
	pending := ""
	if found {
		if m, err := connectSCM(); err == nil {
			if s, err := m.OpenService(serviceName); err == nil {
				if err := windows.ChangeServiceConfig(s.Handle, windows.SERVICE_NO_CHANGE, windows.SERVICE_NO_CHANGE, windows.SERVICE_NO_CHANGE, nil, nil, nil, nil, nil, nil, nil); errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE) {
					pending = "pending: marked for deletion, it goes when the last handle to it closes (services.msc, or a restart)"
				}
				_ = s.Close()
			}
			_ = m.Disconnect()
		}
	}
	items = append(items, removal{what: "the service " + serviceName + " (its virtual account " + serviceAccount + " ends with it)", present: found, kept: pending, remove: func() error {
		m, err := connectSCM()
		if err != nil {
			return err
		}
		defer func() { _ = m.Disconnect() }()
		s, err := m.OpenService(serviceName)
		if err != nil {
			return nil
		}
		defer func() { _ = s.Close() }()
		if err := stopIfRunning(slog.New(slog.DiscardHandler), s); err != nil {
			return err
		}
		if err := s.Delete(); err != nil {
			if errors.Is(err, windows.ERROR_SERVICE_MARKED_FOR_DELETE) {
				return &keptErr{"pending: marked for deletion, it goes when the last handle to it closes (services.msc, or a restart)"}
			}
			return fmt.Errorf("delete service: %w", err)
		}
		return nil
	}})
	prev := upgradeHooksOf.previous(inst.Bin)
	binFolder := removal{what: "the binary folder " + binDir, present: exists(binDir), remove: func() error { return removeNowOrAtRestart(binDir) }}
	binOwn := []string{filepath.Base(inst.Bin), filepath.Base(prev)}
	for _, f := range appFiles {
		binOwn = append(binOwn, filepath.Base(f))
	}
	if other := foreignFiles(binDir, binOwn...); len(other) > 0 {
		binFolder.kept = "it holds files the installer did not write (" + strings.Join(other, ", ") + ")"
	}
	// the installer writes the configuration, repo.dsn and the logs folder; the app's own subfolder goes above
	cfgOwn := []string{filepath.Base(inst.Config), dsnFileName, "logs", "app"}
	cfgFolder := removal{what: "the configuration folder " + cfgDir + " (the configuration, " + dsnFileName + ", the logs)", present: exists(cfgDir), remove: func() error {
		_ = os.RemoveAll(filepath.Join(cfgDir, "logs"))
		return removeFolder(cfgDir, cfgOwn...)
	}}
	if other := foreignFiles(cfgDir, cfgOwn...); len(other) > 0 {
		cfgFolder.kept = "it holds files the installer did not write (" + strings.Join(other, ", ") + ")"
	}
	items = append(items,
		removal{what: "the binary " + inst.Bin, present: exists(inst.Bin), remove: func() error { return removeNowOrAtRestart(inst.Bin) }},
		removal{what: "the previous binary " + prev, present: exists(prev), remove: func() error { return removeNowOrAtRestart(prev) }},
		binFolder,
		cfgFolder,
		removal{what: "the bundled Windows store (not in this release: nothing to look for)"},
	)
	if d := filepath.Join(programData(), "pgvigil-backups"); exists(d) {
		items = append(items, removal{what: "the dump folder " + d, present: true, kept: "the repository's dumps: yours to keep or delete"})
	}
	return items
}
