//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
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
	ready, why := configNamesAnInstance(o.Config)
	if o.NoStart || !ready {
		if !ready {
			log.Info("service installed, not started", "why", why)
		}
		fmt.Printf("pgvigil is installed as the service %s (automatic start). Next:\n  1. %s: the collector's repository connection string, one line (the owner ran migrate and roles)\n  2. %s: list the instances (each dsn as file:<path> beside it, or env:NAME set for the service)\n  3. Start-Service %s; Get-Content %s -Wait\n", serviceName, dsnFile, o.Config, serviceName, filepath.Join(logDir, logFileName))
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
