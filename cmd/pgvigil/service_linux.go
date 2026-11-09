//go:build linux

package main

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	unitPath = "/etc/systemd/system/pgvigil.service"
	envName  = "pgvigil.env"
)

func defaultInstallOptions() installOptions {
	return installOptions{Bin: "/usr/local/bin/pgvigil", Config: "/etc/pgvigil/pgvigil.yaml", User: "pgvigil"}
}

// renderUnit is the systemd unit for the given paths and account. The collector writes nothing on
// the host (its logs go to the journal through stderr), so the file system is read only to it.
func renderUnit(bin, cfg, envFile, account string) string {
	return fmt.Sprintf(`[Unit]
Description=pgvigil PostgreSQL monitoring collector
Documentation=https://github.com/aachaemenes/pgvigil
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%[4]s
Group=%[4]s
EnvironmentFile=%[3]s
ExecStart=%[1]s run -config %[2]s
Restart=on-failure
RestartSec=10s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes

[Install]
WantedBy=multi-user.target
`, bin, cfg, envFile, account)
}

const envTemplate = `# Environment of the pgvigil service (read by systemd, never by a shell: no quotes needed, no expansion).
# The repository login of the collector: 'pgvigil roles' prints its CREATE ROLE; the owner runs migrate.
PGVIGIL_REPO_DSN=
# One line per monitored instance named in pgvigil.yaml as env:NAME, for example:
# PROD_WRITER_DSN=host=db.example.internal port=5432 user=pgvigil dbname=postgres sslmode=require
`

func systemdRunning() bool {
	st, err := os.Stat("/run/systemd/system")
	return err == nil && st.IsDir()
}

func systemctl(args ...string) (string, error) {
	var out bytes.Buffer
	cmd := exec.Command("systemctl", args...)
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

// ensureAccount looks the service account up and creates it as a system user without a home or a
// login shell when missing (useradd, else busybox adduser). It returns its uid and gid.
func ensureAccount(log *slog.Logger, name string) (int, int, error) {
	u, err := user.Lookup(name)
	if err != nil {
		var unknown user.UnknownUserError
		if !errors.As(err, &unknown) {
			return 0, 0, err
		}
		var out []byte
		if _, lookErr := exec.LookPath("useradd"); lookErr == nil {
			out, err = exec.Command("useradd", "--system", "--no-create-home", "--user-group", "--shell", "/usr/sbin/nologin", name).CombinedOutput()
		} else if _, lookErr := exec.LookPath("adduser"); lookErr == nil {
			out, err = exec.Command("adduser", "-S", "-D", "-H", "-s", "/sbin/nologin", name).CombinedOutput()
		} else {
			return 0, 0, fmt.Errorf("no useradd or adduser on this system: create the account %q (a system user, no login) and run install again, or name an existing one with -user", name)
		}
		if err != nil {
			return 0, 0, fmt.Errorf("creating the account %q: %v: %s", name, err, strings.TrimSpace(string(out)))
		}
		log.Info("service account created", "user", name)
		if u, err = user.Lookup(name); err != nil {
			return 0, 0, err
		}
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return 0, 0, err
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return 0, 0, err
	}
	return uid, gid, nil
}

func installService(log *slog.Logger, o installOptions) error {
	if os.Geteuid() != 0 {
		return errors.New("install needs root: run it with sudo")
	}
	_, gid, err := ensureAccount(log, o.User)
	if err != nil {
		return err
	}
	if err := installBinary(log, o.Bin); err != nil {
		return err
	}
	cfgDir := filepath.Dir(o.Config)
	envFile := filepath.Join(cfgDir, envName)
	if err := os.MkdirAll(cfgDir, 0o750); err != nil {
		return err
	}
	if err := os.Chown(cfgDir, 0, gid); err != nil {
		return fmt.Errorf("chown %s: %w", cfgDir, err)
	}
	if err := os.Chmod(cfgDir, 0o750); err != nil {
		return err
	}
	for _, f := range []struct{ path, content string }{{o.Config, configTemplate("env:PGVIGIL_REPO_DSN")}, {envFile, envTemplate}} {
		wrote, err := writeIfAbsent(f.path, f.content, 0o640)
		if err != nil {
			return err
		}
		if err := os.Chown(f.path, 0, gid); err != nil {
			return fmt.Errorf("chown %s: %w", f.path, err)
		}
		if wrote {
			log.Info("written", "path", f.path)
		} else {
			log.Info("kept", "path", f.path)
		}
	}
	if err := writeFile(unitPath, renderUnit(o.Bin, o.Config, envFile, o.User), 0o644); err != nil {
		return err
	}
	log.Info("unit written", "path", unitPath)
	if !systemdRunning() {
		fmt.Printf("systemd is not running here: the unit is written; start the collector with\n  %s run -config %s\nafter editing %s and %s.\n", o.Bin, o.Config, o.Config, envFile)
		return nil
	}
	if out, err := systemctl("daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %v: %s", err, out)
	}
	if out, err := systemctl("enable", "pgvigil.service"); err != nil {
		return fmt.Errorf("systemctl enable: %v: %s", err, out)
	}
	ready, why := configNamesAnInstance(o.Config)
	if o.NoStart || !ready {
		if !ready {
			log.Info("service enabled, not started", "why", why)
		}
		fmt.Printf("pgvigil is installed and enabled. Next:\n  1. %s: the repository login in PGVIGIL_REPO_DSN and one line per monitored instance\n  2. %s: list the instances\n  3. systemctl start pgvigil && systemctl status pgvigil\n", envFile, o.Config)
		return nil
	}
	if out, err := systemctl("restart", "pgvigil.service"); err != nil {
		return fmt.Errorf("systemctl restart: %v: %s", err, out)
	}
	for i := 0; i < 10; i++ {
		time.Sleep(500 * time.Millisecond)
		state, _ := systemctl("is-active", "pgvigil.service")
		if state == "active" {
			fmt.Printf("pgvigil is installed and running (systemctl status pgvigil; journalctl -u pgvigil -f).\n")
			return nil
		}
		if state == "failed" {
			break
		}
	}
	out, _ := systemctl("status", "--no-pager", "-n", "10", "pgvigil.service")
	return fmt.Errorf("the service did not come up:\n%s", out)
}

func uninstallService(log *slog.Logger, o installOptions) error {
	if os.Geteuid() != 0 {
		return errors.New("uninstall needs root: run it with sudo")
	}
	if systemdRunning() {
		if out, err := systemctl("disable", "--now", "pgvigil.service"); err != nil {
			log.Warn("systemctl disable --now", "err", err, "out", out)
		}
	}
	if err := os.Remove(unitPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	log.Info("unit removed", "path", unitPath)
	if systemdRunning() {
		_, _ = systemctl("daemon-reload")
		_, _ = systemctl("reset-failed", "pgvigil.service")
	}
	if o.Purge {
		cfgDir := filepath.Dir(o.Config)
		if err := os.RemoveAll(cfgDir); err != nil {
			return err
		}
		if err := os.Remove(o.Bin); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		log.Info("removed", "config", cfgDir, "binary", o.Bin)
	} else {
		fmt.Printf("the service is gone; %s and %s are kept (pgvigil uninstall -purge removes them).\n", filepath.Dir(o.Config), o.Bin)
	}
	fmt.Printf("the account %s is kept; remove it with: userdel %s\n", o.User, o.User)
	return nil
}

// maybeRunAsService: Linux services are plain processes under systemd; nothing to wrap.
func maybeRunAsService(_ []string) (bool, int) { return false, 0 }

// replaceFile renames tmp over dst (atomic on one file system).
func replaceFile(tmp, dst string) error { return os.Rename(tmp, dst) }

// writeFile replaces path with content (mode on creation); used for the unit the installer owns.
func writeFile(path, content string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), mode)
}
