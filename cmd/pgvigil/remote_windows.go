//go:build windows

package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// install -remote's names on Windows (the lead's 11:5x): the service pgvigil-remote under its own virtual account, its
// config and folders under ProgramData\pgvigil-remote, so a box can run a hub collector beside it.
const (
	remoteServiceName = "pgvigil-remote"
	remoteAccountName = `NT SERVICE\pgvigil-remote`
)

func remoteDataDir() string        { return filepath.Join(programData(), "pgvigil-remote") }
func remoteConfigDefault() string  { return filepath.Join(remoteDataDir(), "pgvigil-remote.yaml") }
func remoteAccountDefault() string { return remoteAccountName }

// installRemoteService is `pgvigil install -remote` on Windows (R14): the binary, the config folder readable by SYSTEM,
// Administrators and the service account only, the remote sample config when absent, the outbox and the state folder
// from the config (absolute, two) writable by the service account only besides SYSTEM and Administrators, the service
// under its virtual account with restart on failure; started when the config is ready. Proven on dba-lab-win (task 14).
func installRemoteService(log *slog.Logger, o installOptions) error {
	dataDir := filepath.Dir(o.Config)
	if err := dedicatedFolder(dataDir, filepath.Base(o.Config)); err != nil {
		return err
	}
	m, err := connectSCM()
	if err != nil {
		return err
	}
	defer func() { _ = m.Disconnect() }()
	existing, err := m.OpenService(remoteServiceName)
	if err == nil {
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
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return err
	}
	outboxDef, stateDef := filepath.Join(remoteDataDir(), "outbox"), filepath.Join(remoteDataDir(), "state")
	wrote, err := writeIfAbsent(o.Config, remoteConfigTemplate(outboxDef, stateDef), 0o600)
	if err != nil {
		return err
	}
	log.Info(map[bool]string{true: "written", false: "kept"}[wrote], "path", o.Config)
	outbox, stateDir := outboxDef, stateDef
	if cfg, err := config.Load(o.Config); err == nil && cfg.Remote != nil {
		outbox, stateDir = cfg.Remote.Outbox, cfg.Remote.StateDir
	}
	if err := checkRemoteFolders(outbox, stateDir); err != nil {
		return err
	}
	for _, d := range []string{outbox, stateDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	cfg := mgr.Config{
		DisplayName:      "pgvigil remote collector",
		Description:      "pgvigil remote collector: reads the instances named in its configuration and writes interval bundles for a pgvigil hub.",
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
		if s, err = m.CreateService(remoteServiceName, o.Bin, cfg, "run", "-config", o.Config); err != nil {
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
	icacls := func(args ...string) error {
		out, err := exec.Command("icacls", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("icacls %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	// the config folder: read by the service only; the two folders: written by it only (SYSTEM and Administrators keep
	// full control everywhere); inheritance cut so nothing wider reaches them
	if err := icacls(dataDir, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F", o.User+":(OI)(CI)R"); err != nil {
		return err
	}
	for _, d := range []string{outbox, stateDir} {
		if err := icacls(d, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F", o.User+":(OI)(CI)M"); err != nil {
			return err
		}
	}
	if err := icacls(filepath.Dir(o.Bin), "/grant", o.User+":(OI)(CI)RX"); err != nil {
		log.Warn("the binary's folder: set the read permission by hand", "err", err)
	}
	log.Info("permissions set", "config", dataDir, "writable by the service", outbox+", "+stateDir)
	if ready, why := remoteReady(o.Config); o.NoStart || !ready {
		if !ready {
			log.Info("service installed, not started", "why", why)
		}
		fmt.Printf("the pgvigil remote collector is installed as the service %s (automatic start). Next:\n  1. %s: remote.site, remote.collector and the instances\n  2. Start-Service %s\n", remoteServiceName, o.Config, remoteServiceName)
		return nil
	}
	if err := s.Start(); err != nil {
		return fmt.Errorf("start: %w", err)
	}
	if _, err := waitState(s, svc.Running, 15*time.Second); err != nil {
		return fmt.Errorf("the remote collector's service did not come up: %v", err)
	}
	if !settledRunning(s) {
		return fmt.Errorf("the remote collector's service started and stopped again within %s", upSettleWindows)
	}
	fmt.Printf("the pgvigil remote collector is installed and running (Get-Service %s).\n", remoteServiceName)
	return nil
}
