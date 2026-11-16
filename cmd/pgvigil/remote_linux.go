//go:build linux

package main

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// install --remote's names on Linux (the lead's 11:4x ask; task 11's installer and the docs take the same): its own unit,
// account, config and folders, so a box can run a hub collector beside it.
const (
	remoteUnitPath = "/etc/systemd/system/pgvigil-remote.service"
	remoteBin      = "/usr/local/bin/pgvigil-remote" // its own binary (the lead's 12:2x): never the hub's
	remoteConfig   = "/etc/pgvigil-remote/pgvigil-remote.yaml"
	remoteEnvFile  = "/etc/pgvigil-remote/pgvigil-remote.env"
	remoteAccount  = "pgvigil-remote"
	remoteOutbox   = "/var/lib/pgvigil-remote/outbox"
	remoteStateDir = "/var/lib/pgvigil-remote/state"
)

// renderRemoteUnit is the remote collector's systemd unit (R14): the hub collector's hardening (renderUnit) with write
// access to its outbox and its state folder only - the file system stays read only everywhere else.
func renderRemoteUnit(bin, cfg, envFile, account, outbox, stateDir string) string {
	return fmt.Sprintf(`[Unit]
Description=pgvigil remote collector (writes interval bundles for a pgvigil hub)
Documentation=https://github.com/aachaemenes/pgvigil
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%[4]s
EnvironmentFile=%[3]s
ExecStart=%[1]s run -config %[2]s
Restart=on-failure
RestartSec=10s
RestartPreventExitStatus=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=%[5]s %[6]s
PrivateTmp=yes
PrivateDevices=yes
DevicePolicy=closed
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
RemoveIPC=yes
UMask=0077
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged

[Install]
WantedBy=multi-user.target
`, bin, cfg, envFile, account, outbox, stateDir)
}

func remoteConfigDefault() string  { return remoteConfig }
func remoteAccountDefault() string { return remoteAccount }
func remoteBinDefault() string     { return remoteBin }

func remoteFolderDefaults() (outbox, stateDir string) { return remoteOutbox, remoteStateDir }

// removeRemoteService is uninstall -remote's service part on Linux: pgvigil-remote.service stopped, disabled and its
// unit removed - never pgvigil.service; the account stays (named), as the hub's uninstall leaves its own.
func removeRemoteService(log *slog.Logger) error {
	if os.Geteuid() != 0 {
		return errors.New("uninstall needs root: run it with sudo")
	}
	unit := filepath.Base(remoteUnitPath)
	if systemdRunning() {
		if out, err := systemctl("disable", "--now", unit); err != nil {
			log.Warn("systemctl disable --now", "unit", unit, "err", err, "out", out)
		}
	}
	if err := os.Remove(remoteUnitPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	log.Info("unit removed", "path", remoteUnitPath)
	if systemdRunning() {
		_, _ = systemctl("daemon-reload")
		_, _ = systemctl("reset-failed", unit)
	}
	fmt.Printf("the account %s is kept; remove it with: userdel %s\n", remoteAccount, remoteAccount)
	return nil
}

// installRemoteService is `pgvigil install -remote` on Linux (R14): the account, the binary, the config folder with the
// remote sample config and the env file when absent, the outbox and the state folder from the config (absolute, never
// under /home) owned by the account, the unit with write access to those two only; started when the config is ready.
func installRemoteService(log *slog.Logger, o installOptions) error {
	if os.Geteuid() != 0 {
		return errors.New("install needs root: run it with sudo")
	}
	cfgDir := filepath.Dir(o.Config)
	envFile := filepath.Join(cfgDir, strings.TrimSuffix(filepath.Base(o.Config), filepath.Ext(o.Config))+".env")
	if err := dedicatedFolder(cfgDir, filepath.Base(o.Config)); err != nil {
		return err
	}
	uid, gid, err := ensureAccount(log, o.User)
	if err != nil {
		return err
	}
	if err := installBinary(log, o.Bin); err != nil {
		return err
	}
	if err := os.MkdirAll(cfgDir, 0o750); err != nil {
		return err
	}
	if err := os.Chown(cfgDir, 0, gid); err != nil {
		return fmt.Errorf("chown %s: %w", cfgDir, err)
	}
	if err := os.Chmod(cfgDir, 0o750); err != nil {
		return err
	}
	for _, f := range []struct{ path, content string }{{o.Config, remoteConfigTemplate(remoteOutbox, remoteStateDir)},
		{envFile, "# Environment of the pgvigil remote collector (read by systemd): one line per instance the config names by env:NAME\n"}} {
		wrote, err := writeIfAbsent(f.path, f.content, 0o640)
		if err != nil {
			return err
		}
		if err := os.Chown(f.path, 0, gid); err != nil {
			return fmt.Errorf("chown %s: %w", f.path, err)
		}
		log.Info(map[bool]string{true: "written", false: "kept"}[wrote], "path", f.path)
	}
	outbox, stateDir := remoteOutbox, remoteStateDir
	if cfg, err := config.Load(o.Config); err == nil && cfg.Remote != nil {
		outbox, stateDir = cfg.Remote.Outbox, cfg.Remote.StateDir
	}
	if err := checkRemoteFolders(outbox, stateDir); err != nil {
		return err
	}
	if err := makeRemoteFolders(outbox, stateDir, uid, gid); err != nil {
		return err
	}
	if err := writeFile(remoteUnitPath, renderRemoteUnit(o.Bin, o.Config, envFile, o.User, outbox, stateDir), 0o644); err != nil {
		return err
	}
	log.Info("unit written", "path", remoteUnitPath)
	unit := filepath.Base(remoteUnitPath)
	if !systemdRunning() {
		fmt.Printf("systemd is not running here: the unit is written; start the remote collector with\n  %s run -config %s\n", o.Bin, o.Config)
		return nil
	}
	if out, err := systemctl("daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %v: %s", err, out)
	}
	if out, err := systemctl("enable", unit); err != nil {
		return fmt.Errorf("systemctl enable: %v: %s", err, out)
	}
	if ready, why := remoteReady(o.Config); o.NoStart || !ready {
		if !ready {
			log.Info("service enabled, not started", "why", why)
		}
		fmt.Printf("the pgvigil remote collector is installed and enabled. Next:\n  1. %s: remote.site, remote.collector and the instances\n  2. %s: one line per instance the config names by env:\n  3. systemctl start %s && systemctl status %s\n", o.Config, envFile, unit, unit)
		return nil
	}
	if out, err := systemctl("restart", unit); err != nil {
		return fmt.Errorf("systemctl restart: %v: %s", err, out)
	}
	for waited := time.Duration(0); waited < upSettle; waited += upStep {
		time.Sleep(upStep)
		if state, _ := systemctl("is-active", unit); state != "active" {
			out, _ := systemctl("status", "--no-pager", "-n", "10", unit)
			return fmt.Errorf("the remote collector did not stay running:\n%s", out)
		}
	}
	fmt.Printf("the pgvigil remote collector is installed and running (systemctl status %s; journalctl -u %s -f).\n", unit, unit)
	return nil
}

// makeRemoteFolders makes the outbox (0750) and the state folder (0700), owned by the service account; a parent it has
// to make (/var/lib/pgvigil-remote) is made 0755 so the account reaches its own folders - an existing parent is left
// as it is.
func makeRemoteFolders(outbox, stateDir string, uid, gid int) error {
	for _, d := range []struct {
		path string
		mode os.FileMode
	}{{outbox, 0o750}, {stateDir, 0o700}} {
		if err := makeParents(filepath.Dir(d.path)); err != nil {
			return err
		}
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return err
		}
		if err := os.Chown(d.path, uid, gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
		if err := os.Chmod(d.path, d.mode); err != nil {
			return err
		}
	}
	return nil
}

// makeParents makes each missing folder of dir, outermost first, 0755 whatever the umask; existing ones are untouched.
func makeParents(dir string) error {
	var missing []string
	for p := filepath.Clean(dir); ; p = filepath.Dir(p) {
		if _, err := os.Stat(p); err == nil {
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		missing = append(missing, p)
		if filepath.Dir(p) == p {
			break
		}
	}
	for i := len(missing) - 1; i >= 0; i-- {
		if err := os.Mkdir(missing[i], 0o755); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		if err := os.Chmod(missing[i], 0o755); err != nil {
			return err
		}
	}
	return nil
}
